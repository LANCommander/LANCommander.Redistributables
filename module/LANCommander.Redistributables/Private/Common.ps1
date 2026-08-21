# Shared helpers used across the module.

$script:BoolTrue  = @('true', 'yes', 'on', 'enabled')
$script:BoolFalse = @('false', 'no', 'off', 'disabled')

<#
.SYNOPSIS
    Normalises a raw config key into something usable as a YAML option key.
.DESCRIPTION
    Mirrors ConfigToOptionSchemaService.SanitizeKey in LANCommander.Server.Services:
    spaces are stripped, dots and dashes become underscores. We additionally
    capitalise the first character so keys read as PascalCase, per the authoring
    rules in generate-redist-options/SKILL.md. Only the first character is touched,
    so conventional all-caps keys (GAMEID, PROTONPATH) survive untouched.
#>
function ConvertTo-OptionKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Key)

    $sanitized = $Key -replace ' ', '' -replace '\.', '_' -replace '-', '_'

    # Strip anything else YAML or the dot-notation flattener would choke on.
    $sanitized = $sanitized -replace '[^A-Za-z0-9_]', '_'

    if ([string]::IsNullOrEmpty($sanitized)) { return $sanitized }

    return $sanitized.Substring(0, 1).ToUpperInvariant() + $sanitized.Substring(1)
}

<#
.SYNOPSIS
    Infers an OptionSchema type from a raw config value.
.DESCRIPTION
    OptionSchema supports string, bool, int, choice and list only -- there is no
    float type. Two deliberate deviations from ConfigToOptionSchemaService.InferType:

    1. Non-integral numbers map to 'string', not 'int'. The server-side converter
       types 1.5 as 'int', which would truncate the value on round-trip.
    2. Booleans are inferred only from explicit textual forms (true/false, yes/no,
       on/off, enabled/disabled). 0 and 1 stay 'int' because the two cases are
       genuinely ambiguous in INI files, and mistyping an int as bool destroys
       values while the reverse does not. Force it from the overlay when needed.
#>
function Get-InferredOptionType {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return 'string' }

    $trimmed = $Value.Trim()

    if ($script:BoolTrue -contains $trimmed.ToLowerInvariant()) { return 'bool' }
    if ($script:BoolFalse -contains $trimmed.ToLowerInvariant()) { return 'bool' }

    [int] $parsedInt = 0
    if ([int]::TryParse($trimmed, [ref] $parsedInt)) { return 'int' }

    return 'string'
}

<#
.SYNOPSIS
    Normalises a raw config value into the canonical string form OptionSchema stores.
#>
function ConvertTo-OptionDefault {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string] $Value,
        [Parameter(Mandatory)][string] $Type
    )

    if ($null -eq $Value) { return $null }

    $trimmed = $Value.Trim()

    if ($Type -eq 'bool') {
        if ($script:BoolTrue -contains $trimmed.ToLowerInvariant()) { return 'true' }
        if ($script:BoolFalse -contains $trimmed.ToLowerInvariant()) { return 'false' }
    }

    return $trimmed
}

<#
.SYNOPSIS
    Emits a single parsed option record. All parsers return these.
#>
function New-ParsedOption {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]] $Segments,
        [AllowNull()][AllowEmptyString()][string] $Value,
        [string] $Type,
        [string[]] $Choices,
        [string] $Comment,
        [string] $Source
    )

    if (-not $Type) { $Type = Get-InferredOptionType -Value $Value }

    # A key with harvested choices is a choice option by definition.
    if ($Choices -and $Choices.Count -gt 0) { $Type = 'choice' }

    [pscustomobject] @{
        Path     = ($Segments -join '.')
        Segments = $Segments
        Type     = $Type
        Default  = ConvertTo-OptionDefault -Value $Value -Type $Type
        Choices  = $Choices
        Comment  = $Comment
        Source   = $Source
    }
}

<#
.SYNOPSIS
    Ensures powershell-yaml is loaded, installing it for the current user if absent.
#>
function Initialize-YamlSupport {
    [CmdletBinding()]
    param()

    if (Get-Module -Name powershell-yaml) { return }

    if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
        Write-Verbose 'Installing powershell-yaml for the current user'

        $repo = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue

        if ($repo -and $repo.InstallationPolicy -ne 'Trusted') {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        }

        Install-Module -Name powershell-yaml -Scope CurrentUser -Force -AllowClobber
    }

    Import-Module powershell-yaml -ErrorAction Stop
}

<#
.SYNOPSIS
    Reads a YAML file into an ordered hashtable.
#>
function Import-YamlFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)

    Initialize-YamlSupport

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "YAML file not found: $Path"
    }

    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8

    if ([string]::IsNullOrWhiteSpace($content)) { return [ordered] @{} }

    return ConvertFrom-Yaml -Yaml $content -Ordered
}

<#
.SYNOPSIS
    Derives a deterministic GUID from arbitrary input.
.DESCRIPTION
    Used for archive identifiers so that rebuilding the same version of a
    redistributable produces the same GUID. Without this, every rebuild would
    create a fresh archive record on import rather than matching the existing one.
#>
function New-DeterministicGuid {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $InputString)

    $md5 = [System.Security.Cryptography.MD5]::Create()

    try {
        $bytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($InputString))
        return [guid]::new($bytes)
    }
    finally {
        $md5.Dispose()
    }
}

<#
.SYNOPSIS
    Converts a raw upstream version string into something usable as a git ref.
.DESCRIPTION
    Upstream versions are not always semver -- 'June 2010' and '2.86' are both
    real. The manifest always carries the raw string; only the tag is sanitised.
#>
function ConvertTo-VersionTag {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Version)

    # Whitelist rather than blacklist: git ref rules forbid a long and fiddly set
    # of characters and sequences, and anything outside this set is safe to fold
    # into a dash.
    $tag = $Version.Trim() -replace '[^A-Za-z0-9._-]', '-'
    $tag = $tag -replace '-{2,}', '-'
    $tag = $tag -replace '\.{2,}', '.'
    $tag = $tag.Trim('.', '-')

    if ([string]::IsNullOrWhiteSpace($tag)) {
        throw "Version '$Version' does not sanitise to a usable git tag"
    }

    return $tag
}
