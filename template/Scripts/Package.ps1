# Server-side. Runs on a schedule so a LANCommander server that imported this
# package once keeps itself updated from this repository's releases, with no
# further imports.
#
# Return an object with Path (a DIRECTORY to be archived), Version and Changelog.
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

$asset = $release.assets | Where-Object { $_.name -eq 'payload.zip' } | Select-Object -First 1

if (-not $asset) {
    throw "Release $($release.tag_name) has no payload.zip asset"
}

$staging = New-Item -ItemType Directory -Force -Path (Join-Path $env:TEMP "REDIST_NAME-$version")
$archive = Join-Path $env:TEMP "REDIST_NAME-$version.zip"

Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $archive
Expand-Archive -Path $archive -DestinationPath $staging -Force
Remove-Item $archive -Force

$Return = New-Package
$Return.Path = $staging.FullName
$Return.Version = $version
$Return.Changelog = $release.body
