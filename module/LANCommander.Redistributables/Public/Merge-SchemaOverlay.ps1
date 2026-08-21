<#
.SYNOPSIS
    Layers hand-written curation over a machine-generated OptionSchema.
.DESCRIPTION
    The generated schema is disposable and rebuilt wholesale on every run; the
    overlay is the durable, hand-written half. Keeping them separate means there is
    never a three-way merge to resolve and curation cannot be lost when upstream
    reshuffles its config.

    Overlay shape (Schema.Overlay.yml):

        CommandTemplate: <passed through to the schema root, shims only>
        GuestPlatforms:  <passed through>
        DisplayName:     <passed through>

        Groups:                     # optional regrouping of generated paths
          Rendering:
            Description: Renderer configuration
            Include: [DirectX.Resolution, DirectX.Antialiasing*]

        Options:                    # per-option curation, keyed by generated dot-path
          DirectX.Resolution:
            DisplayName: Resolution
            Description: Output resolution used by the wrapper
            Type: choice
            Choices: [unforced, max]
            PinDefault: true        # freeze Default at its previously committed value
          GAMEID:                   # an entry declaring a Type is authored outright,
            Type: string            # even when nothing generated it
            IsEnvironmentVariable: true

        Exclude: [Debug.*]          # drop entirely, glob-matched

    Anything the overlay does not mention passes through untouched, so a newly
    added upstream option ships uncurated rather than being dropped. Those are
    surfaced in the report so a human can describe them later.

    An overlay entry whose path the generated schema does not contain is either an
    option authored from scratch or a typo, and the Type is what tells the two
    apart. With a Type it becomes an option and is listed under Authored; without
    one it is listed under StaleCuration and dropped, as before. That is what lets
    a shim with no config file at all -- umu-launcher, which is configured purely
    through environment variables -- own its entire schema from the overlay.

    Two different path spaces are in play and the distinction matters. Curation,
    exclusion and grouping are keyed by the GENERATED path, which is where the
    parser found the option. Added, Removed and DefaultChanged are reported in
    FINAL paths, after grouping, because that is what an administrator sees and
    what per-game option values are stored against. Comparing across the two
    spaces would make every grouped option look added and removed on every run.

    Note: moving an option between groups changes its final path, so regrouping an
    option that servers have already configured orphans those stored values.
.PARAMETER Schema
    Generated schema from ConvertTo-OptionSchema.
.PARAMETER Overlay
    Parsed Schema.Overlay.yml. May be empty.
.PARAMETER PreviousSchema
    The previously committed OptionSchema.yml, used to resolve PinDefault and to
    report what changed.
.OUTPUTS
    A hashtable with Schema (the curated result) and Report (the change summary).
#>
function Merge-SchemaOverlay {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Schema,
        [System.Collections.IDictionary] $Overlay,
        [System.Collections.IDictionary] $PreviousSchema
    )

    if (-not $Overlay) { $Overlay = [ordered] @{} }

    $generated = ConvertTo-FlatSchema -Schema $Schema
    $previous = if ($PreviousSchema) { ConvertTo-FlatSchema -Schema $PreviousSchema } else { [ordered] @{} }

    $curation = if ($Overlay.Contains('Options') -and $Overlay['Options']) { $Overlay['Options'] } else { [ordered] @{} }
    $exclude = if ($Overlay.Contains('Exclude') -and $Overlay['Exclude']) { @($Overlay['Exclude']) } else { @() }

    $report = [ordered] @{
        Added          = [System.Collections.Generic.List[string]]::new()
        Removed        = [System.Collections.Generic.List[string]]::new()
        DefaultChanged = [System.Collections.Generic.List[string]]::new()
        Excluded       = [System.Collections.Generic.List[string]]::new()
        Uncurated      = [System.Collections.Generic.List[string]]::new()
        Authored       = [System.Collections.Generic.List[string]]::new()
        StaleCuration  = [System.Collections.Generic.List[string]]::new()
    }

    # --- Drop excluded options -----------------------------------------------
    $included = [ordered] @{}

    foreach ($path in $generated.Keys) {
        if (Test-PathAgainstGlob -Path $path -Globs $exclude) {
            $report.Excluded.Add($path)
            continue
        }

        $included[$path] = $generated[$path]
    }

    # --- Materialise options the overlay authors outright --------------------
    # An overlay entry that declares a Type is not curation of a generated option,
    # it IS the option. That is the whole schema for a shim with no config file to
    # parse: umu-launcher configures itself through environment variables alone,
    # so every one of its options is hand-written in the overlay.
    #
    # An entry WITHOUT a Type is still curation, and is still reported as stale
    # when nothing matches it, so a mistyped path is caught rather than quietly
    # becoming an orphaned option nobody asked for.
    #
    # Authored paths are appended after the generated ones, in overlay order, so
    # the emitted document stays byte-identical between runs.
    foreach ($path in $curation.Keys) {
        if ($generated.Contains($path)) { continue }

        $authored = $curation[$path]

        $declaresType = $authored -is [System.Collections.IDictionary] -and
            $authored.Contains('Type') -and
            -not [string]::IsNullOrWhiteSpace([string] $authored['Type'])

        if (-not $declaresType) {
            $report.StaleCuration.Add($path)
            continue
        }

        if (Test-PathAgainstGlob -Path $path -Globs $exclude) {
            $report.Excluded.Add($path)
            continue
        }

        # Seeded empty: the curation loop below layers the overlay over it, which
        # is the same code path a generated option takes.
        $included[$path] = [ordered] @{}
        $report.Authored.Add($path)
    }

    # --- Work out where each option will end up before curating it -----------
    # PinDefault has to look the option up in the previous schema by its final
    # path, so the mapping has to exist before defaults are resolved.
    $pathMap = Get-FinalPathMap -Paths @($included.Keys) -Overlay $Overlay

    # --- Apply curation -------------------------------------------------------
    $curated = [ordered] @{}

    foreach ($path in $included.Keys) {
        $leaf = Copy-OrderedDictionary -Source $included[$path]
        $finalPath = $pathMap[$path]
        $overrides = if ($curation.Contains($path)) { $curation[$path] } else { $null }

        if ($overrides) {
            foreach ($key in $overrides.Keys) {
                if ($key -eq 'PinDefault') { continue }
                $leaf[$key] = $overrides[$key]
            }

            $pinned = $overrides.Contains('PinDefault') -and [bool] $overrides['PinDefault']

            if ($pinned -and -not $overrides.Contains('Default')) {
                if ($previous.Contains($finalPath) -and $previous[$finalPath].Contains('Default')) {
                    $leaf['Default'] = $previous[$finalPath]['Default']
                }
                else {
                    Write-Warning "PinDefault is set on '$path' but there is no previously committed default to pin to"
                }
            }
        }
        else {
            $report.Uncurated.Add($path)
        }

        # A 'choice' with no Choices would fail validation, so fall back rather
        # than emitting something the server will reject.
        if ($leaf['Type'] -eq 'choice' -and -not $leaf.Contains('Choices')) {
            Write-Warning "Option '$path' is type 'choice' with no Choices; falling back to 'string'"
            $leaf['Type'] = 'string'
        }

        $curated[$path] = Format-OptionLeaf -Leaf $leaf
    }

    # --- Assemble the result --------------------------------------------------
    $result = [ordered] @{}

    foreach ($rootKey in @('CommandTemplate', 'GuestPlatforms', 'DisplayName')) {
        if ($Overlay.Contains($rootKey) -and $Overlay[$rootKey]) {
            $result[$rootKey] = $Overlay[$rootKey]
        }
    }

    $result['Options'] = Build-CuratedTree -Curated $curated -PathMap $pathMap -Overlay $Overlay

    # --- Compare final against final -----------------------------------------
    $final = ConvertTo-FlatSchema -Schema $result

    foreach ($path in $final.Keys) {
        if (-not $previous.Contains($path)) {
            $report.Added.Add($path)
            continue
        }

        $before = if ($previous[$path].Contains('Default')) { $previous[$path]['Default'] | Out-String } else { '' }
        $after = if ($final[$path].Contains('Default')) { $final[$path]['Default'] | Out-String } else { '' }

        if ($before -ne $after) { $report.DefaultChanged.Add($path) }
    }

    foreach ($path in $previous.Keys) {
        if (-not $final.Contains($path)) { $report.Removed.Add($path) }
    }

    return @{ Schema = $result; Report = $report }
}

<#
.SYNOPSIS
    Maps each generated option path to the path it will occupy after grouping.
.DESCRIPTION
    A group claims the first option matching each of its Include globs and hosts it
    under the group's own key. Options no group claims keep their generated path.
#>
function Get-FinalPathMap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Paths,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Overlay
    )

    $map = [ordered] @{}
    $groups = if ($Overlay.Contains('Groups') -and $Overlay['Groups']) { $Overlay['Groups'] } else { [ordered] @{} }

    $claimed = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($groupName in $groups.Keys) {
        $definition = $groups[$groupName]
        $includes = if ($definition -and $definition.Contains('Include')) { @($definition['Include']) } else { @() }
        $groupKey = ConvertTo-OptionKey -Key ([string] $groupName)
        $taken = [System.Collections.Generic.HashSet[string]]::new()

        foreach ($path in $Paths) {
            if ($claimed.Contains($path)) { continue }
            if (-not (Test-PathAgainstGlob -Path $path -Globs $includes)) { continue }

            $leafKey = ($path -split '\.')[-1]

            if (-not $taken.Add($leafKey)) {
                Write-Warning "Group '$groupName' already contains '$leafKey'; leaving '$path' where it was"
                continue
            }

            $map[$path] = "$groupKey.$leafKey"
            [void] $claimed.Add($path)
        }
    }

    foreach ($path in $Paths) {
        if (-not $map.Contains($path)) { $map[$path] = $path }
    }

    return $map
}

<#
.SYNOPSIS
    Rebuilds the nested Options tree from curated leaves and their final paths.
#>
function Build-CuratedTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Curated,
        [Parameter(Mandatory)][System.Collections.IDictionary] $PathMap,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Overlay
    )

    $groups = if ($Overlay.Contains('Groups') -and $Overlay['Groups']) { $Overlay['Groups'] } else { [ordered] @{} }
    $tree = [ordered] @{}

    # Declared groups come first and in overlay order, so the curated structure
    # leads rather than trailing after whatever the parser happened to emit.
    foreach ($groupName in $groups.Keys) {
        $groupKey = ConvertTo-OptionKey -Key ([string] $groupName)
        $definition = $groups[$groupName]

        $members = @($Curated.Keys | Where-Object { $PathMap[$_] -like "$groupKey.*" })

        if ($members.Count -eq 0) {
            Write-Warning "Group '$groupName' matched no options; omitting it"
            continue
        }

        $node = [ordered] @{}

        foreach ($key in @('DisplayName', 'Description')) {
            if ($definition -and $definition.Contains($key) -and $definition[$key]) {
                $node[$key] = $definition[$key]
            }
        }

        $children = [ordered] @{}

        foreach ($path in $members) {
            $children[($PathMap[$path] -split '\.')[-1]] = $Curated[$path]
        }

        $node['Options'] = $children
        $tree[$groupKey] = $node
    }

    foreach ($path in $Curated.Keys) {
        $finalPath = $PathMap[$path]

        # Already placed by a group.
        if ($finalPath -ne $path) { continue }

        $segments = @($finalPath -split '\.')
        $cursor = $tree

        for ($i = 0; $i -lt $segments.Count - 1; $i++) {
            $segment = $segments[$i]

            if (-not $cursor.Contains($segment)) {
                $cursor[$segment] = [ordered] @{ Options = [ordered] @{} }
            }
            elseif (-not $cursor[$segment].Contains('Options')) {
                $cursor[$segment]['Options'] = [ordered] @{}
            }

            $cursor = $cursor[$segment]['Options']
        }

        $cursor[$segments[-1]] = $Curated[$path]
    }

    return $tree
}

<#
.SYNOPSIS
    Flattens a nested schema to dot-path -> leaf definition.
.DESCRIPTION
    Mirrors OptionSchema.GetFlattenedOptions: leaves are nodes carrying a Type,
    and list options are treated as leaves because their Fields describe per-item
    shape rather than sibling options.
#>
function ConvertTo-FlatSchema {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Schema)

    $flat = [ordered] @{}
    $options = if ($Schema.Contains('Options')) { $Schema['Options'] } else { $Schema }

    if ($options) { Read-SchemaNode -Node $options -Prefix '' -Flat $flat }

    return $flat
}

function Read-SchemaNode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Node,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Prefix,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Flat
    )

    foreach ($key in $Node.Keys) {
        $definition = $Node[$key]
        if ($definition -isnot [System.Collections.IDictionary]) { continue }

        $path = if ($Prefix) { "$Prefix.$key" } else { [string] $key }
        $type = if ($definition.Contains('Type')) { [string] $definition['Type'] } else { '' }

        if ($type) { $Flat[$path] = $definition }

        $isList = $type -and $type.ToLowerInvariant() -eq 'list'

        if (-not $isList -and $definition.Contains('Options') -and $definition['Options']) {
            Read-SchemaNode -Node $definition['Options'] -Prefix $path -Flat $Flat
        }
    }
}

<#
.SYNOPSIS
    Orders leaf fields canonically and drops empty ones, so diffs stay stable.
#>
function Format-OptionLeaf {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Leaf)

    $order = @(
        'Type', 'DisplayName', 'Description', 'Default', 'Required',
        'IsEnvironmentVariable', 'Choices', 'ItemType', 'Fields', 'MinItems', 'MaxItems'
    )

    $result = [ordered] @{}

    foreach ($key in $order) {
        if (-not $Leaf.Contains($key)) { continue }

        $value = $Leaf[$key]

        if ($null -eq $value) { continue }
        if ($value -is [string] -and $value -eq '') { continue }
        # Required and IsEnvironmentVariable are omitted when false, per the
        # authoring rules in generate-redist-options/SKILL.md.
        if ($value -is [bool] -and -not $value) { continue }

        # Scalar defaults are always emitted as strings. OptionDefinition.Default is
        # typed as object and GetDefaultAsString() calls ToString() on it, so a YAML
        # boolean would resolve to .NET's "False" rather than "false" and break every
        # script comparing against the lowercase form. List defaults stay sequences.
        if ($key -eq 'Default' -and $value -isnot [string]) {
            $isSequence = $value -is [System.Collections.IEnumerable] -and $value -isnot [string]

            if (-not $isSequence) {
                $value = if ($value -is [bool]) { $value.ToString().ToLowerInvariant() } else { [string] $value }
            }
        }

        $result[$key] = $value
    }

    foreach ($key in $Leaf.Keys) {
        if ($order -notcontains $key -and $key -ne 'Options') { $result[$key] = $Leaf[$key] }
    }

    return $result
}

<#
.SYNOPSIS
    Tests a dot-path against a set of globs. '*' matches within a path segment
    and across separators, so 'Debug.*' claims everything under Debug.
#>
function Test-PathAgainstGlob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [AllowEmptyCollection()][string[]] $Globs
    )

    if (-not $Globs) { return $false }

    foreach ($glob in $Globs) {
        if ([string]::IsNullOrWhiteSpace($glob)) { continue }
        if ($Path -like $glob) { return $true }
    }

    return $false
}

<#
.SYNOPSIS
    Shallow-copies an ordered dictionary so curation never mutates the source.
#>
function Copy-OrderedDictionary {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Source)

    $copy = [ordered] @{}
    foreach ($key in $Source.Keys) { $copy[$key] = $Source[$key] }

    return $copy
}
