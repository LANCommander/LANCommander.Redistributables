# Server-side. Runs on a schedule so a LANCommander server that imported this
# package once keeps itself updated from this repository's releases, with no
# further imports.
#
# Hand the result back with New-Package -Path <a DIRECTORY to be archived>
# -Version <string> [-Changelog <string>]. Path and Version are mandatory, and the
# server runs this in a runspace with no host, so a bare New-Package cannot prompt
# for them -- it fails to bind, and the operator sees only "the package script did
# not return a result".
# Returning nothing means "no new package required", which is the normal result.
#
# Available: $Redistributable (the SDK model, including its current Version) and
# $LatestArchivePath.

$repository = 'LANCommander/LANCommander.Redistributables.REDIST_NAME'

$release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repository/releases/latest" -Headers @{
    'Accept'     = 'application/vnd.github+json'
    'User-Agent' = 'LANCommander'
}

$version = ([string] $release.tag_name) -replace '^v', ''

# Nothing to do when the server already has this version.
if ($version -eq $Redistributable.Version) {
    return
}

$asset = $release.assets | Where-Object { $_.name -like '*.lcx' } | Select-Object -First 1

if (-not $asset) {
    throw "Release $($release.tag_name) has no .lcx asset"
}

# GetTempPath rather than $env:TEMP, which only exists on Windows -- this script
# runs on the server, which may be either.
$temp = [System.IO.Path]::GetTempPath()

$staging = New-Item -ItemType Directory -Force -Path (Join-Path $temp "REDIST_NAME-$version")
$package = Join-Path $temp "REDIST_NAME-$version.lcx"
$payload = Join-Path $temp "REDIST_NAME-$version-payload.zip"

Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $package

# Windows PowerShell does not load the compression assembly on its own.
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
}

# An .lcx is a ZIP whose payload is a single inner ZIP under Archives/, already
# laid out relative to the payload root. Pull that out rather than shipping a
# second copy of the same bytes as a separate release asset.
$lcx = [System.IO.Compression.ZipFile]::OpenRead($package)

try {
    $entry = $lcx.Entries | Where-Object { $_.FullName -like 'Archives/*' } | Select-Object -First 1

    # A script-only redistributable carries no archive, so there is nothing to
    # repackage even though the version moved.
    if (-not $entry) { return }

    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $payload, $true)
}
finally {
    $lcx.Dispose()
}

Expand-Archive -Path $payload -DestinationPath $staging -Force
Remove-Item $package, $payload -Force

$Return = New-Package -Path $staging.FullName -Version $version -Changelog $release.body
