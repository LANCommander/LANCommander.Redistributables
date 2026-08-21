<#
.SYNOPSIS
    Validates an OptionSchema document against the SDK model and authoring rules.
.DESCRIPTION
    Pure PowerShell, so it runs in a fraction of a second and needs no .NET SDK.
    Checks two classes of problem:

    Structural -- things the SDK would silently mis-handle. Group nodes must carry
    Options and no Type; leaf nodes must carry a valid Type; a 'choice' needs
    Choices; list options need a coherent scalar/composite shape.

    Authoring -- the rules in generate-redist-options/SKILL.md. Keys must be
    PascalCase and free of spaces, dots and dashes, because nested options are
    flattened into dot-notation keys and a dot inside a key would corrupt the path.
    IsEnvironmentVariable is meaningless on a list, since environment variables
    are scalar; ProcessExecutionContext skips those with a warning.

    Use Test-LcxPackage -Strict for the authoritative check -- it round-trips
    through the real YamlDotNet configuration the server uses.
.PARAMETER Path
    OptionSchema.yml to validate.
.PARAMETER Schema
    An already-parsed schema, for validating in-memory results.
.OUTPUTS
    An object with IsValid, Errors and Warnings.
#>
function Test-OptionSchema {
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path', Position = 0)][string] $Path,
        [Parameter(Mandatory, ParameterSetName = 'Object')][System.Collections.IDictionary] $Schema
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        if (-not (Test-Path -LiteralPath $Path)) {
            $errors.Add("OptionSchema file not found: $Path")
            return New-ValidationResult -Errors $errors -Warnings $warnings
        }

        try {
            $Schema = Import-YamlFile -Path $Path
        }
        catch {
            $errors.Add("OptionSchema is not valid YAML: $($_.Exception.Message)")
            return New-ValidationResult -Errors $errors -Warnings $warnings
        }
    }

    if (-not $Schema -or $Schema.Count -eq 0) {
        $warnings.Add('OptionSchema is empty; the redistributable will have no configurable options')
        return New-ValidationResult -Errors $errors -Warnings $warnings
    }

    $validPlatforms = @('None', 'Windows', 'Linux', 'macOS')

    if ($Schema.Contains('GuestPlatforms') -and $Schema['GuestPlatforms']) {
        foreach ($flag in ([string] $Schema['GuestPlatforms'] -split ',')) {
            if ($validPlatforms -notcontains $flag.Trim()) {
                $errors.Add("GuestPlatforms contains unknown platform '$($flag.Trim())'")
            }
        }
    }

    if ($Schema.Contains('CommandTemplate') -and $Schema['CommandTemplate']) {
        $template = [string] $Schema['CommandTemplate']

        if ($template -notmatch '\{exe\}') {
            $warnings.Add("CommandTemplate does not contain {exe}; the game executable will not be substituted in")
        }
    }
    elseif ($Schema.Contains('GuestPlatforms') -and $Schema['GuestPlatforms'] -and $Schema['GuestPlatforms'] -ne 'None') {
        # CompatibilityResolver only treats a redistributable as a shim when it can
        # actually wrap execution.
        $warnings.Add('GuestPlatforms is set without a CommandTemplate; this only applies to compatibility shims')
    }

    $options = if ($Schema.Contains('Options')) { $Schema['Options'] } else { $null }

    if (-not $options -or $options.Count -eq 0) {
        $warnings.Add('OptionSchema declares no Options')
        return New-ValidationResult -Errors $errors -Warnings $warnings
    }

    Test-SchemaNode -Node $options -Prefix '' -Errors $errors -Warnings $warnings

    return New-ValidationResult -Errors $errors -Warnings $warnings
}

function Test-SchemaNode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Node,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Prefix,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]] $Errors,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]] $Warnings
    )

    $validTypes = @('string', 'bool', 'int', 'choice', 'list')

    foreach ($key in $Node.Keys) {
        $name = [string] $key
        $path = if ($Prefix) { "$Prefix.$name" } else { $name }
        $definition = $Node[$key]

        # A dot inside a key would be indistinguishable from a nesting separator
        # once GetFlattenedOptions builds the dot-notation path.
        if ($name -notmatch '^[A-Za-z0-9_]+$') {
            $Errors.Add("Option key '$path' contains characters other than letters, digits and underscores")
        }
        elseif ($name -cmatch '^[a-z]') {
            $Warnings.Add("Option key '$path' is not PascalCase")
        }

        if ($definition -isnot [System.Collections.IDictionary]) {
            $Errors.Add("Option '$path' is not a mapping")
            continue
        }

        $type = if ($definition.Contains('Type')) { [string] $definition['Type'] } else { '' }
        $hasChildren = $definition.Contains('Options') -and $definition['Options'] -and $definition['Options'].Count -gt 0

        if (-not $type) {
            if (-not $hasChildren) {
                $Errors.Add("Option '$path' has neither a Type nor child Options, so it is neither a leaf nor a group")
            }
            else {
                Test-SchemaNode -Node $definition['Options'] -Prefix $path -Errors $Errors -Warnings $Warnings
            }

            continue
        }

        if ($validTypes -notcontains $type.ToLowerInvariant()) {
            $Errors.Add("Option '$path' has unknown Type '$type'. Valid types: $($validTypes -join ', ')")
            continue
        }

        $isList = $type.ToLowerInvariant() -eq 'list'

        if ($type.ToLowerInvariant() -eq 'choice') {
            $choices = if ($definition.Contains('Choices')) { @($definition['Choices']) } else { @() }

            if ($choices.Count -eq 0) {
                $Errors.Add("Option '$path' is Type 'choice' but declares no Choices")
            }
            elseif ($definition.Contains('Default') -and $definition['Default']) {
                $values = foreach ($choice in $choices) {
                    if ($choice -is [System.Collections.IDictionary]) { [string] $choice['Value'] } else { [string] $choice }
                }

                if ($values -notcontains [string] $definition['Default']) {
                    $Warnings.Add("Option '$path' has Default '$($definition['Default'])' which is not among its Choices")
                }
            }
        }

        if ($isList) {
            $composite = $definition.Contains('Fields') -and $definition['Fields'] -and $definition['Fields'].Count -gt 0

            if (-not $composite -and -not $definition.Contains('ItemType')) {
                $Warnings.Add("Option '$path' is a scalar list without an ItemType; it will default to string")
            }

            if ($composite -and $definition.Contains('ItemType')) {
                $Warnings.Add("Option '$path' declares both Fields and ItemType; Fields makes it composite and ItemType is ignored")
            }

            if ($definition.Contains('IsEnvironmentVariable') -and [bool] $definition['IsEnvironmentVariable']) {
                # ProcessExecutionContext explicitly skips list options when setting
                # environment variables, because env vars are scalar.
                $Errors.Add("Option '$path' is a list with IsEnvironmentVariable set; that is ignored at launch. Read it via Get-RedistributableOptions instead.")
            }

            foreach ($bound in @('MinItems', 'MaxItems')) {
                if ($definition.Contains($bound) -and $null -ne $definition[$bound]) {
                    $parsed = 0
                    if (-not [int]::TryParse([string] $definition[$bound], [ref] $parsed)) {
                        $Errors.Add("Option '$path' has a non-numeric $bound")
                    }
                }
            }

            if ($definition.Contains('MinItems') -and $definition.Contains('MaxItems')) {
                $min = 0; $max = 0

                if ([int]::TryParse([string] $definition['MinItems'], [ref] $min) -and
                    [int]::TryParse([string] $definition['MaxItems'], [ref] $max) -and $min -gt $max) {
                    $Errors.Add("Option '$path' has MinItems ($min) greater than MaxItems ($max)")
                }
            }
        }

        if ($definition.Contains('Default') -and $definition['Default'] -is [bool]) {
            # OptionDefinition.Default is object and GetDefaultAsString() calls
            # ToString(), which yields .NET's "True"/"False" rather than the
            # lowercase form every script compares against.
            $Errors.Add("Option '$path' has an unquoted boolean Default; quote it so it resolves as 'true'/'false' rather than 'True'/'False'")
        }

        # A list treats its Fields as per-item shape, so its Options are not
        # sibling options and are not flattened.
        if (-not $isList -and $hasChildren) {
            $Warnings.Add("Option '$path' has both a Type and child Options; the children will still be flattened but this is usually a mistake")
            Test-SchemaNode -Node $definition['Options'] -Prefix $path -Errors $Errors -Warnings $Warnings
        }
    }
}

function New-ValidationResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]] $Errors,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]] $Warnings
    )

    return [pscustomobject] @{
        IsValid  = $Errors.Count -eq 0
        Errors   = $Errors.ToArray()
        Warnings = $Warnings.ToArray()
    }
}
