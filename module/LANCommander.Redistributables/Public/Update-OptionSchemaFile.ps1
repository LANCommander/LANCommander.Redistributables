<#
.SYNOPSIS
    Rebuilds a redistributable's OptionSchema.yml from its upstream config.
.DESCRIPTION
    The single entry point used by both workflows. Parses every path listed under
    ConfigPaths, layers Schema.Overlay.yml over the result, validates, and writes
    OptionSchema.yml.

    The output is deterministic: given the same config and overlay it produces a
    byte-identical file. That is what lets the build assert the committed schema is
    up to date, and what keeps the scheduled upstream PRs free of spurious diffs.

    ConfigPaths are resolved against the payload first and then the repository, so
    a redistributable can either ship a config in its payload or keep a reference
    copy in the repo for redistributables whose config is generated at runtime.
.PARAMETER RepositoryPath
    Root of the redistributable repository.
.PARAMETER PayloadPath
    Extracted upstream payload, when there is one.
.PARAMETER Check
    Do not write. Report whether the committed file is already up to date. Exits
    the pipeline with IsUpToDate false when it is not.
.OUTPUTS
    An object with Schema, Report, IsUpToDate, Validation and Path.
#>
function Update-OptionSchemaFile {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $RepositoryPath,
        [string] $PayloadPath,
        [switch] $Check
    )

    Initialize-YamlSupport

    $definition = Get-RedistributableDefinition -Path $RepositoryPath

    $schemaPath = Join-Path $RepositoryPath 'OptionSchema.yml'
    $overlayPath = Join-Path $RepositoryPath 'Schema.Overlay.yml'

    $configPaths = if ($definition.Contains('ConfigPaths')) { @($definition['ConfigPaths']) } else { @() }

    if ($configPaths.Count -eq 0) {
        Write-Verbose 'No ConfigPaths declared; this redistributable has no generated options'

        # An overlay can still stand alone -- a shim may define only a
        # CommandTemplate and a couple of hand-written options.
        if (-not (Test-Path -LiteralPath $overlayPath)) {
            return [pscustomobject] @{
                Schema     = $null
                Report     = $null
                IsUpToDate = $true
                Validation = $null
                Path       = $null
            }
        }
    }

    $resolved = @()

    foreach ($configPath in $configPaths) {
        $candidates = @()

        if ($PayloadPath) { $candidates += Join-Path $PayloadPath $configPath }
        $candidates += Join-Path $RepositoryPath $configPath

        $found = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

        if (-not $found) {
            # Upstream reorganising its layout is a real event and should surface
            # as a visible schema diff, not a hard build failure.
            Write-Warning "ConfigPath '$configPath' was not found in the payload or the repository"
            continue
        }

        $resolved += (Resolve-Path -LiteralPath $found).Path
    }

    $pattern = if ($definition.Contains('ChoiceCommentPattern')) { [string] $definition['ChoiceCommentPattern'] } else { $null }
    $format = if ($definition.Contains('ConfigFormat') -and $definition['ConfigFormat']) { [string] $definition['ConfigFormat'] } else { 'auto' }
    $customParser = Join-Path $RepositoryPath 'Parse-Config.ps1'
    $includeCommented = $definition.Contains('IncludeCommentedKeys') -and [bool] $definition['IncludeCommentedKeys']

    $generated = if ($resolved.Count -gt 0) {
        ConvertTo-OptionSchema -Path $resolved -Format $format -ChoiceCommentPattern $pattern -CustomParserPath $customParser -IncludeCommentedKeys:$includeCommented
    }
    else {
        [ordered] @{ Options = [ordered] @{} }
    }

    $overlay = if (Test-Path -LiteralPath $overlayPath) { Import-YamlFile -Path $overlayPath } else { [ordered] @{} }
    $previous = if (Test-Path -LiteralPath $schemaPath) { Import-YamlFile -Path $schemaPath } else { $null }

    $merged = Merge-SchemaOverlay -Schema $generated -Overlay $overlay -PreviousSchema $previous

    $yaml = ConvertTo-Yaml -Data $merged.Schema
    $validation = Test-OptionSchema -Schema $merged.Schema

    $existing = if (Test-Path -LiteralPath $schemaPath) { Get-Content -LiteralPath $schemaPath -Raw -Encoding UTF8 } else { $null }
    $isUpToDate = $null -ne $existing -and ($existing -replace "`r`n", "`n") -eq ($yaml -replace "`r`n", "`n")

    if (-not $Check -and -not $isUpToDate) {
        if ($PSCmdlet.ShouldProcess($schemaPath, 'Write OptionSchema.yml')) {
            Set-Content -LiteralPath $schemaPath -Value $yaml -Encoding utf8 -NoNewline
            Write-Verbose "Wrote $schemaPath"
        }
    }

    return [pscustomobject] @{
        Schema     = $merged.Schema
        Report     = $merged.Report
        IsUpToDate = $isUpToDate
        Validation = $validation
        Path       = $schemaPath
        Yaml       = $yaml
    }
}
