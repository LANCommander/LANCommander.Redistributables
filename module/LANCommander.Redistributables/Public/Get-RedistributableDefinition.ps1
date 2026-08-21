<#
.SYNOPSIS
    Reads and validates a redistributable.yml definition.
.DESCRIPTION
    Central entry point for everything that needs a redistributable's metadata:
    the packer, the upstream checker and the schema builder all start here.

    The stable identifiers are the important part. Id and every entry under
    Scripts are generated once when the repository is scaffolded and must never
    change, because RedistributableImporter matches incoming records on
    "r.Id == record.Id || r.Name == record.Name". A regenerated GUID would make
    every published release import as a brand new redistributable instead of
    updating the existing one.
.PARAMETER Path
    Repository root, or a direct path to redistributable.yml.
#>
function Get-RedistributableDefinition {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)

    $file = if (Test-Path -LiteralPath $Path -PathType Container) {
        Join-Path $Path 'redistributable.yml'
    }
    else {
        $Path
    }

    if (-not (Test-Path -LiteralPath $file)) {
        throw "No redistributable.yml found at '$file'"
    }

    $definition = Import-YamlFile -Path $file

    foreach ($required in @('Id', 'Name')) {
        if (-not $definition.Contains($required) -or [string]::IsNullOrWhiteSpace([string] $definition[$required])) {
            throw "redistributable.yml is missing required field '$required'"
        }
    }

    $parsedId = [guid]::Empty
    if (-not [guid]::TryParse([string] $definition['Id'], [ref] $parsedId)) {
        throw "redistributable.yml has an invalid Id '$($definition['Id'])' -- it must be a GUID"
    }

    if ($parsedId -eq [guid]::Empty) {
        throw 'redistributable.yml Id must not be the empty GUID'
    }

    # Name is a display name and may contain spaces ("OpenAL Soft"); the repository
    # name cannot. Derive one when it is not stated explicitly, since it determines
    # the release asset filenames.
    if (-not $definition.Contains('RepositoryName') -or [string]::IsNullOrWhiteSpace([string] $definition['RepositoryName'])) {
        $definition['RepositoryName'] = ([string] $definition['Name']) -replace '[^A-Za-z0-9._-]', ''
    }

    # Normalise Source so callers never have to null-check it.
    $source = if ($definition.Contains('Source') -and $definition['Source']) { $definition['Source'] } else { [ordered] @{} }

    if (-not $source.Contains('Mode') -or -not $source['Mode']) { $source['Mode'] = 'vendored' }

    $mode = [string] $source['Mode']

    if ($mode -notin @('download', 'vendored', 'none')) {
        throw "Source.Mode must be one of download, vendored, none -- got '$mode'"
    }

    if ($mode -eq 'download' -and -not $source.Contains('Url')) {
        Write-Warning 'Source.Mode is download but no Url is set; source.ps1 must resolve it on its own'
    }

    $definition['Source'] = $source

    $scripts = if ($definition.Contains('Scripts') -and $definition['Scripts']) { $definition['Scripts'] } else { [ordered] @{} }
    $known = @(
        'Install', 'Uninstall', 'NameChange', 'KeyChange', 'SaveUpload', 'SaveDownload',
        'DetectInstall', 'BeforeStart', 'AfterStop', 'GameStarted', 'GameStopped',
        'UserRegistration', 'UserLogin', 'ApplicationStart', 'Package', 'RunWrapper'
    )

    $seen = @{}
    $normalized = [ordered] @{}
    $validPlatforms = @('None', 'Windows', 'Linux', 'macOS')

    foreach ($type in @($scripts.Keys)) {
        if ($known -notcontains $type) {
            throw "Unknown script type '$type' in redistributable.yml. Valid types: $($known -join ', ')"
        }

        # A script entry is either a bare GUID or a mapping carrying the GUID plus
        # manifest metadata. The bare form keeps simple redistributables terse.
        $entry = $scripts[$type]

        $normalizedEntry = if ($entry -is [System.Collections.IDictionary]) {
            $copy = [ordered] @{}
            foreach ($key in $entry.Keys) { $copy[$key] = $entry[$key] }
            $copy
        }
        else {
            [ordered] @{ Id = [string] $entry }
        }

        $scriptId = [guid]::Empty
        if (-not [guid]::TryParse([string] $normalizedEntry['Id'], [ref] $scriptId) -or $scriptId -eq [guid]::Empty) {
            throw "Script '$type' has an invalid or empty GUID in redistributable.yml"
        }

        # Two scripts sharing a GUID would collide on the same Scripts/{id} archive
        # entry, silently dropping one of them.
        if ($seen.ContainsKey($scriptId)) {
            throw "Scripts '$type' and '$($seen[$scriptId])' share GUID $scriptId; every script needs its own"
        }

        $seen[$scriptId] = $type

        # RuntimePlatform is a [Flags] enum where None (the default) means "runs
        # anywhere" -- EnvironmentHelper.SupportsCurrentRuntime short-circuits on it.
        # So an unset Platforms is correct for cross-platform scripts.
        if ($normalizedEntry.Contains('Platforms') -and $normalizedEntry['Platforms']) {
            $flags = @([string] $normalizedEntry['Platforms'] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

            foreach ($flag in $flags) {
                if ($validPlatforms -notcontains $flag) {
                    throw "Script '$type' declares unknown platform '$flag'. Valid values: $($validPlatforms -join ', ')"
                }
            }

            $normalizedEntry['Platforms'] = $flags -join ', '
        }

        $normalizedEntry['Id'] = $scriptId.ToString()
        $normalized[$type] = $normalizedEntry
    }

    foreach ($required in @('DetectInstall', 'Install')) {
        if (-not $normalized.Contains($required)) {
            Write-Warning "No $required script is defined. Redistributables are expected to ship both DetectInstall and Install."
        }
    }

    $definition['Scripts'] = $normalized

    return $definition
}
