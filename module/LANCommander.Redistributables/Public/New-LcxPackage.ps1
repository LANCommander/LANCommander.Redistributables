<#
.SYNOPSIS
    Builds a LANCommander redistributable import package (.LCX).
.DESCRIPTION
    An .LCX is a plain ZIP laid out as:

        Manifest.yml            the redistributable manifest, PascalCase YAML
        Archives/{guid}         an inner ZIP holding the payload files
        Scripts/{guid}          raw PowerShell, one entry per script

    The layout follows LcxBuilderService in LANCommander.Packager, with three
    deliberate differences:

    1. The archive GUID is derived from the redistributable Id and the version
       rather than being random, so rebuilding a version is idempotent. A random
       GUID would create a fresh archive record on every re-import.
    2. CompressedSize is measured from the entry itself. LcxBuilderService reads
       outputStream.Position, which is an absolute offset rather than a delta and
       therefore overstates the size.
    3. A leading '#Requires -RunAsAdministrator' is stripped from packed script
       bodies and recorded as RequiresAdmin on the manifest instead. ScriptHelper
       .GetScriptContents re-adds the directive on the client, so leaving it in
       would duplicate it.

    On import the manifest is duck-typed: ImportContext picks the Redistributable
    branch when Name is non-empty and Title is absent. Name is therefore required.
.PARAMETER Definition
    Parsed redistributable.yml, from Get-RedistributableDefinition.
.PARAMETER Version
    The raw upstream version string. Stored verbatim on the manifest and the
    archive; only git tags get sanitised.
.PARAMETER PayloadPath
    Directory whose contents become the inner archive. Omit for script-only
    redistributables -- the SDK still runs Install when there are no archives.
.PARAMETER ScriptsPath
    Directory holding the .ps1 files named after their script type.
.PARAMETER OptionSchemaPath
    Built OptionSchema.yml. Its contents are embedded verbatim as a string.
.PARAMETER OutputPath
    Destination .lcx file.
#>
function New-LcxPackage {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Definition,
        [Parameter(Mandatory)][string] $Version,
        [string] $PayloadPath,
        [string] $ScriptsPath,
        [string] $OptionSchemaPath,
        [Parameter(Mandatory)][string] $OutputPath,
        [System.IO.Compression.CompressionLevel] $CompressionLevel = [System.IO.Compression.CompressionLevel]::Optimal
    )

    Initialize-YamlSupport

    if ([string]::IsNullOrWhiteSpace($Version)) {
        throw 'A version is required -- it becomes Archive.Version, which is how the server determines the installed version'
    }

    $redistributableId = [guid]::Parse([string] $Definition['Id'])
    $name = [string] $Definition['Name']

    $manifest = [ordered] @{
        ManifestVersion = '1.0.0'
        Id              = $redistributableId.ToString()
        Name            = $name
        Version         = $Version
    }

    foreach ($field in @('Description', 'Notes')) {
        if ($Definition.Contains($field) -and $Definition[$field]) {
            $manifest[$field] = ([string] $Definition[$field]).Trim()
        }
    }

    if ($OptionSchemaPath -and (Test-Path -LiteralPath $OptionSchemaPath)) {
        $schemaYaml = Get-Content -LiteralPath $OptionSchemaPath -Raw -Encoding UTF8

        if (-not [string]::IsNullOrWhiteSpace($schemaYaml)) {
            # OptionSchema is a raw YAML string nested inside the manifest YAML.
            $manifest['OptionSchema'] = $schemaYaml
        }
    }

    $now = [DateTime]::UtcNow
    $manifest['ReleasedOn'] = $now.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
    $manifest['CreatedOn'] = $manifest['ReleasedOn']
    $manifest['CreatedBy'] = 'LANCommander.Redistributables'
    $manifest['UpdatedOn'] = $manifest['ReleasedOn']
    $manifest['UpdatedBy'] = 'LANCommander.Redistributables'

    $scripts = Get-PackagedScript -Definition $Definition -ScriptsPath $ScriptsPath

    if (-not $PSCmdlet.ShouldProcess($OutputPath, 'Build LCX package')) { return }

    $outputDirectory = Split-Path -Parent $OutputPath
    if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory)) {
        $null = New-Item -ItemType Directory -Path $outputDirectory -Force
    }

    if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force }

    $archiveEntries = @()
    $stream = [System.IO.File]::Create($OutputPath)

    try {
        $zip = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Create)

        try {
            if ($PayloadPath -and (Test-Path -LiteralPath $PayloadPath)) {
                $files = @(Get-ChildItem -LiteralPath $PayloadPath -Recurse -File)

                if ($files.Count -eq 0) {
                    Write-Warning "Payload directory '$PayloadPath' is empty; building an archive-less package"
                }
                else {
                    # Deterministic so that rebuilding a version matches the existing
                    # archive record rather than creating a duplicate.
                    $archiveId = New-DeterministicGuid -InputString "$redistributableId|$Version"

                    $sizes = Add-PayloadArchive -Zip $zip -ArchiveId $archiveId -PayloadPath $PayloadPath -Files $files -CompressionLevel $CompressionLevel

                    $archiveEntries += [ordered] @{
                        Id               = $archiveId.ToString()
                        ObjectKey        = $archiveId.ToString()
                        Version          = $Version
                        CompressedSize   = $sizes.CompressedSize
                        UncompressedSize = $sizes.UncompressedSize
                        CreatedOn        = $manifest['CreatedOn']
                        CreatedBy        = 'LANCommander.Redistributables'
                    }

                    Write-Verbose "Packed $($files.Count) payload file(s), $($sizes.UncompressedSize) bytes uncompressed"
                }
            }
            elseif ($PayloadPath) {
                Write-Warning "Payload path '$PayloadPath' does not exist; building an archive-less package"
            }

            $manifest['Archives'] = @($archiveEntries)

            $manifestScripts = @()

            foreach ($script in $scripts) {
                # Stored uncompressed, matching how the Packager writes scripts.
                $entry = $zip.CreateEntry("Scripts/$($script.Id)", [System.IO.Compression.CompressionLevel]::NoCompression)
                $entryStream = $entry.Open()

                try {
                    $writer = [System.IO.StreamWriter]::new($entryStream, [System.Text.UTF8Encoding]::new($false))
                    try { $writer.Write($script.Contents) } finally { $writer.Dispose() }
                }
                finally {
                    $entryStream.Dispose()
                }

                $manifestEntry = [ordered] @{
                    Id            = $script.Id
                    Type          = $script.Type
                    Name          = $script.Name
                    RequiresAdmin = $script.RequiresAdmin
                    CreatedOn     = $manifest['CreatedOn']
                    CreatedBy     = 'LANCommander.Redistributables'
                }

                if ($script.Description) { $manifestEntry['Description'] = $script.Description }
                if ($script.Platforms) { $manifestEntry['Platforms'] = $script.Platforms }

                $manifestScripts += $manifestEntry
            }

            $manifest['Scripts'] = @($manifestScripts)

            $yaml = ConvertTo-Yaml -Data $manifest

            $manifestEntryZip = $zip.CreateEntry('Manifest.yml', [System.IO.Compression.CompressionLevel]::NoCompression)
            $manifestStream = $manifestEntryZip.Open()

            try {
                $writer = [System.IO.StreamWriter]::new($manifestStream, [System.Text.UTF8Encoding]::new($false))
                try { $writer.Write($yaml) } finally { $writer.Dispose() }
            }
            finally {
                $manifestStream.Dispose()
            }
        }
        finally {
            $zip.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }

    Write-Verbose "Wrote $OutputPath"

    return [pscustomobject] @{
        Path        = (Resolve-Path -LiteralPath $OutputPath).Path
        Version     = $Version
        Tag         = 'v' + (ConvertTo-VersionTag -Version $Version)
        ArchiveId   = if ($archiveEntries.Count -gt 0) { $archiveEntries[0]['Id'] } else { $null }
        ScriptCount = $scripts.Count
        Manifest    = $manifest
    }
}

<#
.SYNOPSIS
    Writes the payload into an inner ZIP entry and reports its sizes.
.DESCRIPTION
    The inner archive is built to a temp file first, for two reasons. It gives an
    exact CompressedSize -- the server stores this entry verbatim as the archive
    file, so the entry's own length is the number that matters, and it cannot be
    read back out of a ZipArchive opened in Create mode. It also keeps the payload
    off the heap for large redistributables.

    Compression is applied to the inner archive; the outer entry is stored. The
    inner content is already compressed, so deflating it a second time costs CPU
    for effectively no saving.
#>
function Add-PayloadArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.IO.Compression.ZipArchive] $Zip,
        [Parameter(Mandatory)][guid] $ArchiveId,
        [Parameter(Mandatory)][string] $PayloadPath,
        [Parameter(Mandatory)][object[]] $Files,
        [Parameter(Mandatory)][System.IO.Compression.CompressionLevel] $CompressionLevel
    )

    $root = (Resolve-Path -LiteralPath $PayloadPath).Path
    $uncompressed = 0L
    $temp = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "lcx-payload-$([guid]::NewGuid()).zip")

    try {
        $tempStream = [System.IO.File]::Create($temp)

        try {
            $inner = [System.IO.Compression.ZipArchive]::new($tempStream, [System.IO.Compression.ZipArchiveMode]::Create)

            try {
                foreach ($file in $Files) {
                    # Paths inside the inner archive are relative to the payload root,
                    # because the client extracts it straight into the redistributable's
                    # Files/ metadata directory.
                    $relative = [System.IO.Path]::GetRelativePath($root, $file.FullName).Replace('\', '/')

                    $innerEntry = $inner.CreateEntry($relative, $CompressionLevel)
                    $innerStream = $innerEntry.Open()

                    try {
                        $source = [System.IO.File]::OpenRead($file.FullName)
                        try {
                            $source.CopyTo($innerStream)
                            $uncompressed += $source.Length
                        }
                        finally {
                            $source.Dispose()
                        }
                    }
                    finally {
                        $innerStream.Dispose()
                    }
                }
            }
            finally {
                $inner.Dispose()
            }
        }
        finally {
            $tempStream.Dispose()
        }

        $compressed = (Get-Item -LiteralPath $temp).Length

        $entry = $Zip.CreateEntry("Archives/$ArchiveId", [System.IO.Compression.CompressionLevel]::NoCompression)
        $entryStream = $entry.Open()

        try {
            $source = [System.IO.File]::OpenRead($temp)
            try { $source.CopyTo($entryStream) } finally { $source.Dispose() }
        }
        finally {
            $entryStream.Dispose()
        }

        return [pscustomobject] @{
            CompressedSize   = [long] $compressed
            UncompressedSize = $uncompressed
        }
    }
    finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

<#
.SYNOPSIS
    Loads each declared script from disk and prepares it for packing.
#>
function Get-PackagedScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Definition,
        [string] $ScriptsPath
    )

    $declared = $Definition['Scripts']
    if (-not $declared -or $declared.Count -eq 0) { return @() }

    if (-not $ScriptsPath -or -not (Test-Path -LiteralPath $ScriptsPath)) {
        throw "redistributable.yml declares $($declared.Count) script(s) but '$ScriptsPath' does not exist"
    }

    $results = @()

    foreach ($type in $declared.Keys) {
        $entry = $declared[$type]
        $file = Join-Path $ScriptsPath "$type.ps1"

        if (-not (Test-Path -LiteralPath $file)) {
            throw "Script '$type' is declared in redistributable.yml but $file is missing"
        }

        $contents = Get-Content -LiteralPath $file -Raw -Encoding UTF8

        if ([string]::IsNullOrWhiteSpace($contents)) {
            throw "Script '$type' at $file is empty"
        }

        $requiresAdmin = $false

        if ($contents -match '(?im)^\s*#Requires\s+-RunAsAdministrator\s*$') {
            $requiresAdmin = $true
            # Strip it: ScriptHelper.GetScriptContents prepends the directive on the
            # client whenever RequiresAdmin is set.
            $contents = ($contents -replace '(?im)^\s*#Requires\s+-RunAsAdministrator\s*\r?\n?', '').TrimStart()
        }

        if ($entry.Contains('RequiresAdmin')) { $requiresAdmin = [bool] $entry['RequiresAdmin'] }

        $results += [pscustomobject] @{
            Id            = [string] $entry['Id']
            Type          = [string] $type
            Name          = if ($entry.Contains('Name') -and $entry['Name']) { [string] $entry['Name'] } else { [string] $type }
            Description   = if ($entry.Contains('Description')) { [string] $entry['Description'] } else { $null }
            Platforms     = if ($entry.Contains('Platforms')) { [string] $entry['Platforms'] } else { $null }
            RequiresAdmin = $requiresAdmin
            Contents      = $contents
        }
    }

    return $results
}
