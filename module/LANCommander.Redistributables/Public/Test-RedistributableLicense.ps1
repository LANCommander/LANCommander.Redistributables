<#
.SYNOPSIS
    Determines whether an upstream payload may be redistributed inside an .LCX.
.DESCRIPTION
    Publishing a redistributable means republishing someone else's binaries as a
    GitHub release asset, so the upstream terms have to be checked before anything
    is packaged. This locates the license text in the payload, matches it against
    policy/licenses.yml, and returns a recommendation.

    When redistribution is not permitted the recommendation is Source.Mode 'none'
    rather than a hard failure. An archive-less redistributable is still useful:
    RedistributableClient.InstallAsync runs the Install script even when there are
    no archives, so the script can fetch from the vendor on the client at install
    time. Nothing is republished and the redistributable still works.

    This is a routing aid for packaging decisions, not legal advice. Anything that
    comes back 'conditional' is meant to stop for a human.
.PARAMETER PayloadPath
    Extracted upstream files to search for license documents.
.PARAMETER LicenseText
    License text supplied directly, when it lives on a web page rather than in the
    payload.
.PARAMETER PolicyPath
    policy/licenses.yml. Defaults to the copy shipped with the module.
.OUTPUTS
    An object with License, Redistribute, RecommendedSourceMode, Obligations,
    Evidence and LicenseFiles.
#>
function Test-RedistributableLicense {
    [CmdletBinding()]
    param(
        [string] $PayloadPath,
        [string] $LicenseText,
        [string] $PolicyPath
    )

    if (-not $PolicyPath) {
        # module/LANCommander.Redistributables/Public -> repository root
        $PolicyPath = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'policy/licenses.yml'
    }

    if (-not (Test-Path -LiteralPath $PolicyPath)) {
        throw "License policy not found at '$PolicyPath'"
    }

    $policy = Import-YamlFile -Path $PolicyPath

    $licenseFiles = @()
    $corpus = [System.Text.StringBuilder]::new()

    if ($LicenseText) { $null = $corpus.AppendLine($LicenseText) }

    if ($PayloadPath -and (Test-Path -LiteralPath $PayloadPath)) {
        # Deliberately broad: upstream projects put their terms in wildly different
        # places, and a missed license file means a wrong redistribution call.
        $patterns = @(
            'LICENSE*', 'LICENCE*', 'COPYING*', 'EULA*', 'NOTICE*',
            'COPYRIGHT*', '*license*.txt', '*license*.md', 'readme*.txt', 'readme*.md'
        )

        foreach ($pattern in $patterns) {
            foreach ($file in @(Get-ChildItem -LiteralPath $PayloadPath -Filter $pattern -Recurse -File -ErrorAction SilentlyContinue)) {
                if ($licenseFiles -contains $file.FullName) { continue }
                # Skip anything implausibly large for a license document.
                if ($file.Length -gt 1MB) { continue }

                $licenseFiles += $file.FullName
                $null = $corpus.AppendLine((Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8))
            }
        }
    }

    $text = $corpus.ToString()

    if ([string]::IsNullOrWhiteSpace($text)) {
        return New-LicenseVerdict -Policy $policy -Match $null -Evidence 'No license text was found in the payload' -LicenseFiles $licenseFiles
    }

    # Collapse whitespace so signatures survive differing line wrapping.
    $normalized = ($text -replace '\s+', ' ').ToLowerInvariant()

    # Higher Priority first: a redistribution ban must win over a permissive
    # warranty disclaimer sitting in the same file.
    $candidates = @($policy['Licenses']) | Sort-Object -Descending {
        if ($_.Contains('Priority') -and $null -ne $_['Priority']) { [int] $_['Priority'] } else { 0 }
    }

    foreach ($license in $candidates) {
        foreach ($signature in @($license['Signatures'])) {
            if ([string]::IsNullOrWhiteSpace($signature)) { continue }

            $needle = ([string] $signature -replace '\s+', ' ').ToLowerInvariant()

            if ($normalized.Contains($needle)) {
                $evidence = "Matched '$($license['Id'])' on: $signature"
                return New-LicenseVerdict -Policy $policy -Match $license -Evidence $evidence -LicenseFiles $licenseFiles
            }
        }
    }

    return New-LicenseVerdict -Policy $policy -Match $null -Evidence 'License text was found but matched no known signature' -LicenseFiles $licenseFiles
}

function New-LicenseVerdict {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Policy,
        [AllowNull()][System.Collections.IDictionary] $Match,
        [Parameter(Mandatory)][string] $Evidence,
        [AllowEmptyCollection()][string[]] $LicenseFiles
    )

    $default = $Policy['Default']

    $redistribute = if ($Match) { [string] $Match['Redistribute'] } else { [string] $default['Redistribute'] }
    $obligations = if ($Match -and $Match['Obligations']) { @($Match['Obligations']) } else { @() }

    if (-not $Match -and $default.Contains('Reason')) {
        $Evidence = "$Evidence. $($default['Reason'])"
    }

    # 'no' is the only verdict that changes the packaging shape automatically.
    # 'conditional' deliberately leaves the mode alone so the caller has to stop.
    $mode = if ($redistribute -eq 'no') { 'none' } else { $null }

    return [pscustomobject] @{
        License               = if ($Match) { [string] $Match['Id'] } else { 'Unknown' }
        LicenseName           = if ($Match) { [string] $Match['Name'] } else { 'Unrecognised' }
        Redistribute          = $redistribute
        RequiresHumanReview   = $redistribute -ne 'yes'
        RecommendedSourceMode = $mode
        Obligations           = $obligations
        Evidence              = $Evidence
        LicenseFiles          = @($LicenseFiles)
    }
}
