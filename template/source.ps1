<#
.SYNOPSIS
    Resolves and downloads the upstream release for REDIST_NAME.
.DESCRIPTION
    The one genuinely bespoke file in a redistributable repository.

    Contract:
      -CheckOnly            write the upstream version to stdout and exit.
      -OutputPath <dir>     download and extract the payload there, then emit a
                            JSON object with Version and optionally Changelog.

    Emit the RAW upstream version. It is stored verbatim on the manifest and the
    archive; only the git tag is sanitised. Upstream versions are often not semver
    ('June 2010' is a real DirectX version), and rewriting them makes the published
    version stop matching what upstream calls it.

    Only files that belong in the client's install directory should end up in
    $OutputPath -- the inner archive is extracted straight into the redistributable's
    Files/ metadata directory, so upstream documentation and samples are just noise.
    Keep the upstream license file, though: it has to travel with the binaries.
#>
[CmdletBinding(DefaultParameterSetName = 'Download')]
param(
    [Parameter(ParameterSetName = 'Check')][switch] $CheckOnly,
    [Parameter(ParameterSetName = 'Download', Mandatory)][string] $OutputPath
)

$ErrorActionPreference = 'Stop'

$definition = Get-RedistributableDefinition -Path $PSScriptRoot
$source = $definition['Source']

# Resolve-UpstreamVersion covers the two common shapes: a GitHub releases feed and
# a scraped download page. Replace this call outright if upstream needs something
# else -- all that matters is that $upstream ends up with Version and DownloadUrl.
$upstream = Resolve-UpstreamVersion -Resolver ([string] $source['Resolver']) -Url ([string] $source['Url'])

if ($CheckOnly) {
    Write-Output $upstream.Version
    return
}

if (-not $upstream.DownloadUrl) {
    throw 'No download URL was resolved; set AssetPattern or resolve it explicitly here'
}

$archive = Join-Path ([System.IO.Path]::GetTempPath()) "REDIST_NAME-$($upstream.Version).zip"

Write-Verbose "Downloading $($upstream.DownloadUrl)"
Invoke-WebRequest -Uri $upstream.DownloadUrl -OutFile $archive -MaximumRetryCount 3 -RetryIntervalSec 5

$extracted = Join-Path ([System.IO.Path]::GetTempPath()) "REDIST_NAME-extract-$([guid]::NewGuid())"
Expand-Archive -Path $archive -DestinationPath $extracted -Force

# Copy only what the client needs. Narrow this to the specific subdirectory the
# redistributable installs -- most upstream archives carry far more than that.
Copy-Item -Path (Join-Path $extracted '*') -Destination $OutputPath -Recurse -Force

# The upstream license travels with the binaries.
$license = Join-Path $PSScriptRoot 'LICENSES/UPSTREAM-LICENSE.txt'
if (Test-Path $license) {
    Copy-Item -Path $license -Destination (Join-Path $OutputPath 'LICENSE.txt') -Force
}

Remove-Item $archive, $extracted -Recurse -Force -ErrorAction SilentlyContinue

@{
    Version   = $upstream.Version
    Changelog = $upstream.Changelog
} | ConvertTo-Json -Compress | Write-Output
