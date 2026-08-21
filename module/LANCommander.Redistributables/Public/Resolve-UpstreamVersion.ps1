<#
.SYNOPSIS
    Resolves the latest upstream version of a redistributable.
.DESCRIPTION
    Shipping the two common discovery shapes here means most redistributables need
    only a few lines in their own source.ps1 rather than a bespoke scraper.

    github-release  Reads the GitHub releases API and returns the newest tag.
    html            Fetches a page and pulls the version out with a regex.
    static          The version is pinned in redistributable.yml; useful for
                    payloads that are versioned by date or never change.

    The returned version is the RAW upstream string. It is stored verbatim on the
    manifest and archive; only git tags get sanitised, via ConvertTo-VersionTag.
    Upstream versions are frequently not semver -- 'June 2010' is a real DirectX
    redistributable version.
.PARAMETER Resolver
    Which discovery strategy to use.
.PARAMETER Url
    Repository (owner/name or full URL) for github-release, or the page to scrape
    for html.
.PARAMETER Pattern
    Regex with a named 'version' group, for the html resolver.
.PARAMETER Version
    The pinned version, for the static resolver.
.PARAMETER IncludePrerelease
    Consider GitHub prereleases. Off by default -- redistributables should track
    stable upstream builds.
.OUTPUTS
    An object with Version, DownloadUrl and Changelog. DownloadUrl may be null
    when the resolver cannot determine one; source.ps1 is then responsible for it.
#>
function Resolve-UpstreamVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('github-release', 'html', 'static')][string] $Resolver,
        [string] $Url,
        [string] $Pattern,
        [string] $Version,
        [string] $AssetPattern,
        [switch] $IncludePrerelease
    )

    switch ($Resolver) {
        'static' {
            if ([string]::IsNullOrWhiteSpace($Version)) {
                throw "Resolver 'static' requires -Version"
            }

            return [pscustomobject] @{ Version = $Version.Trim(); DownloadUrl = $Url; Changelog = $null }
        }

        'github-release' {
            if ([string]::IsNullOrWhiteSpace($Url)) {
                throw "Resolver 'github-release' requires -Url (owner/name or a github.com URL)"
            }

            $repo = $Url -replace '^https?://(www\.)?github\.com/', '' -replace '\.git$', ''
            $repo = $repo.Trim('/')

            if ($repo -notmatch '^[^/]+/[^/]+$') {
                throw "Could not derive owner/name from '$Url'"
            }

            $headers = @{ 'Accept' = 'application/vnd.github+json'; 'User-Agent' = 'LANCommander.Redistributables' }

            # A token lifts the 60/hour anonymous rate limit. GitHub Actions sets
            # GITHUB_TOKEN, so scheduled checks get the authenticated allowance.
            $token = $env:GH_TOKEN
            if (-not $token) { $token = $env:GITHUB_TOKEN }
            if ($token) { $headers['Authorization'] = "Bearer $token" }

            $endpoint = if ($IncludePrerelease) {
                "https://api.github.com/repos/$repo/releases?per_page=20"
            }
            else {
                "https://api.github.com/repos/$repo/releases/latest"
            }

            $response = Invoke-RestMethod -Uri $endpoint -Headers $headers -MaximumRetryCount 3 -RetryIntervalSec 5

            $release = if ($IncludePrerelease) {
                @($response) | Where-Object { -not $_.draft } | Select-Object -First 1
            }
            else {
                $response
            }

            if (-not $release) { throw "No releases found for $repo" }

            $asset = if ($AssetPattern) {
                @($release.assets) | Where-Object { $_.name -match $AssetPattern } | Select-Object -First 1
            }
            else {
                @($release.assets) | Select-Object -First 1
            }

            if ($AssetPattern -and -not $asset) {
                Write-Warning "No release asset matched '$AssetPattern'; source.ps1 will need to resolve the download itself"
            }

            # Strip a leading 'v' so the stored version matches how upstream talks
            # about it, not how it tags it.
            $resolvedVersion = ([string] $release.tag_name) -replace '^[vV]', ''

            return [pscustomobject] @{
                Version     = $resolvedVersion.Trim()
                DownloadUrl = if ($asset) { $asset.browser_download_url } else { $null }
                Changelog   = $release.body
            }
        }

        'html' {
            if ([string]::IsNullOrWhiteSpace($Url)) { throw "Resolver 'html' requires -Url" }
            if ([string]::IsNullOrWhiteSpace($Pattern)) { throw "Resolver 'html' requires -Pattern" }

            $response = Invoke-WebRequest -Uri $Url -MaximumRetryCount 3 -RetryIntervalSec 5 -UseBasicParsing
            $content = [string] $response.Content

            $match = [regex]::Match($content, $Pattern)

            if (-not $match.Success) {
                throw "Pattern did not match anything at $Url. Upstream may have changed its page layout."
            }

            if (-not $match.Groups['version'].Success) {
                throw "Pattern matched but exposes no 'version' named group"
            }

            $downloadUrl = $null

            if ($match.Groups['url'].Success) {
                $downloadUrl = $match.Groups['url'].Value

                # Page-relative hrefs are the norm on hand-written download pages.
                if ($downloadUrl -notmatch '^https?://') {
                    $downloadUrl = [uri]::new([uri] $Url, $downloadUrl).AbsoluteUri
                }
            }

            return [pscustomobject] @{
                Version     = $match.Groups['version'].Value.Trim()
                DownloadUrl = $downloadUrl
                Changelog   = $null
            }
        }
    }
}
