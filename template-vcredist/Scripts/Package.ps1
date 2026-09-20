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

$ErrorActionPreference = 'Stop'

$repository = 'LANCommander/LANCommander.Redistributables.REDIST_REPOSITORY'

$release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repository/releases/latest" -Headers @{
    'Accept'     = 'application/vnd.github+json'
    'User-Agent' = 'LANCommander'
}

$version = ([string] $release.tag_name) -replace '^v', ''

if ([string]::IsNullOrWhiteSpace($version)) {
    throw "The latest $repository release has no usable tag name"
}

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

# Cleared rather than reused. New-Item -Force on an existing directory is a no-op,
# so a previous failed run would otherwise leave files for Expand-Archive -Force to
# merge into rather than replace.
$stagingPath = Join-Path $temp "REDIST_REPOSITORY-$version"
Remove-Item -LiteralPath $stagingPath -Recurse -Force -ErrorAction SilentlyContinue

$staging = New-Item -ItemType Directory -Force -Path $stagingPath
$package = Join-Path $temp "REDIST_REPOSITORY-$version.lcx"
$payload = Join-Path $temp "REDIST_REPOSITORY-$version-payload.zip"

try {
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

    # Sanity check the layout before handing it over. If the payload ever changes
    # shape, this should fail here with something readable rather than on every
    # client at install time with a missing-file error.
    if (-not (Test-Path -LiteralPath (Join-Path $staging 'vc_redist.x64.exe'))) {
        throw "The downloaded package has no vc_redist.x64.exe at its root"
    }

    $Return = New-Package -Path $staging.FullName -Version $version -Changelog $release.body
}
finally {
    Remove-Item -LiteralPath $package, $payload -Force -ErrorAction SilentlyContinue
}
