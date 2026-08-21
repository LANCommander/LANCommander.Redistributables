BeforeDiscovery {
    # -Skip: is evaluated during discovery, so this cannot live in BeforeAll.
    # A local LANCommander checkout makes the strict round-trip offline and fast.
    $script:SdkPath = if ($env:LANCOMMANDER_SDK_PATH) {
        $env:LANCOMMANDER_SDK_PATH
    }
    else {
        Join-Path $PSScriptRoot '../../LANCommander/LANCommander.SDK'
    }

    $script:HasSdk = Test-Path -LiteralPath $script:SdkPath
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../module/LANCommander.Redistributables') -Force
    Import-Module powershell-yaml

    $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) "lcx-pkg-tests-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $script:Temp -Force | Out-Null

    $script:SdkPath = if ($env:LANCOMMANDER_SDK_PATH) {
        $env:LANCOMMANDER_SDK_PATH
    }
    else {
        Join-Path $PSScriptRoot '../../LANCommander/LANCommander.SDK'
    }

    function New-TestRepository {
        param([hashtable] $Overrides = @{})

        $root = Join-Path $script:Temp ([guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $root 'Scripts') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'payload/sub') -Force | Out-Null

        Set-Content -Path (Join-Path $root 'redistributable.yml') -Encoding utf8 -Value @'
Id: 3f6d1c9e-8b2a-4d51-9c07-1e5a7b3f2d84
Name: TestRedist
Description: Fixture.
Notes: Upstream (c) Example. MIT licensed.
Source:
  Mode: vendored
ConfigPaths:
  - app.ini
Scripts:
  DetectInstall: 6a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d
  Install:
    Id: 7b2c3d4e-5f6a-4b7c-8d9e-0f1a2b3c4d5e
    Platforms: Windows
'@

        Set-Content -Path (Join-Path $root 'app.ini') -Encoding utf8 -Value "[General]`nMode = fast`nLevel = 3`n"
        Set-Content -Path (Join-Path $root 'Scripts/DetectInstall.ps1') -Encoding utf8 -Value '$Return = Test-Path "$InstallDirectory\marker.txt"'
        Set-Content -Path (Join-Path $root 'Scripts/Install.ps1') -Encoding utf8 -Value "#Requires -RunAsAdministrator`n`nCopy-Item .\* `$InstallDirectory -Recurse -Force`n`$Return = 0"
        Set-Content -Path (Join-Path $root 'payload/readme.txt') -Encoding utf8 -Value 'payload file'
        Set-Content -Path (Join-Path $root 'payload/sub/lib.dll') -Encoding utf8 -Value 'fake binary content'

        return $root
    }

    function Build-TestPackage {
        param([string] $Root, [string] $Version = '2.86')

        $definition = Get-RedistributableDefinition -Path $Root
        $output = Join-Path $script:Temp "$([guid]::NewGuid()).lcx"

        Update-OptionSchemaFile -RepositoryPath $Root | Out-Null

        return New-LcxPackage -Definition $definition -Version $Version `
            -PayloadPath (Join-Path $Root 'payload') `
            -ScriptsPath (Join-Path $Root 'Scripts') `
            -OptionSchemaPath (Join-Path $Root 'OptionSchema.yml') `
            -OutputPath $output
    }

    function Get-EntryNames {
        param([string] $Path)

        $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try { return @($zip.Entries | ForEach-Object { $_.FullName }) } finally { $zip.Dispose() }
    }

    function Get-EntryText {
        param([string] $Path, [string] $Entry)

        $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try {
            $stream = $zip.GetEntry($Entry).Open()
            $reader = [System.IO.StreamReader]::new($stream)
            try { return $reader.ReadToEnd() } finally { $reader.Dispose(); $stream.Dispose() }
        }
        finally {
            $zip.Dispose()
        }
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Get-RedistributableDefinition' {
    It 'accepts both the bare-GUID and mapping forms of a script entry' {
        $definition = Get-RedistributableDefinition -Path (New-TestRepository)

        $definition['Scripts']['DetectInstall']['Id'] | Should -Be '6a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d'
        $definition['Scripts']['Install']['Platforms'] | Should -Be 'Windows'
    }

    It 'rejects two scripts sharing a GUID' {
        # They would collide on the same Scripts/{id} entry and one would vanish.
        $root = New-TestRepository
        $shared = '6a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d'
        Set-Content -Path (Join-Path $root 'redistributable.yml') -Encoding utf8 -Value @"
Id: 3f6d1c9e-8b2a-4d51-9c07-1e5a7b3f2d84
Name: TestRedist
Scripts:
  DetectInstall: $shared
  Install: $shared
"@

        { Get-RedistributableDefinition -Path $root } | Should -Throw '*share GUID*'
    }

    It 'rejects an empty or malformed Id' {
        $root = New-TestRepository
        Set-Content -Path (Join-Path $root 'redistributable.yml') -Encoding utf8 -Value "Id: not-a-guid`nName: X`n"

        { Get-RedistributableDefinition -Path $root } | Should -Throw '*must be a GUID*'
    }

    It 'rejects an unknown script type' {
        $root = New-TestRepository
        Set-Content -Path (Join-Path $root 'redistributable.yml') -Encoding utf8 -Value @'
Id: 3f6d1c9e-8b2a-4d51-9c07-1e5a7b3f2d84
Name: X
Scripts:
  Nonsense: 6a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d
'@

        { Get-RedistributableDefinition -Path $root } | Should -Throw '*Unknown script type*'
    }

    It 'rejects an invalid Source.Mode' {
        $root = New-TestRepository
        Set-Content -Path (Join-Path $root 'redistributable.yml') -Encoding utf8 -Value @'
Id: 3f6d1c9e-8b2a-4d51-9c07-1e5a7b3f2d84
Name: X
Source:
  Mode: sideways
'@

        { Get-RedistributableDefinition -Path $root } | Should -Throw '*Source.Mode*'
    }
}

Describe 'New-LcxPackage' {
    BeforeAll {
        $script:Root = New-TestRepository
        $script:Package = Build-TestPackage -Root $script:Root
        $script:Entries = Get-EntryNames -Path $script:Package.Path
    }

    It 'writes Manifest.yml at the archive root with exactly that casing' {
        # ImportContext compares entry keys ordinally against ManifestHelper.ManifestFilename.
        $script:Entries | Should -Contain 'Manifest.yml'
    }

    It 'writes one archive entry and one entry per script' {
        @($script:Entries | Where-Object { $_ -like 'Archives/*' }).Count | Should -Be 1
        @($script:Entries | Where-Object { $_ -like 'Scripts/*' }).Count | Should -Be 2
    }

    It 'names script entries after their stable GUIDs' {
        $script:Entries | Should -Contain 'Scripts/6a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d'
        $script:Entries | Should -Contain 'Scripts/7b2c3d4e-5f6a-4b7c-8d9e-0f1a2b3c4d5e'
    }

    It 'produces a manifest with a Name and no Title, so it duck-types as a redistributable' {
        $manifest = ConvertFrom-Yaml -Ordered -Yaml (Get-EntryText -Path $script:Package.Path -Entry 'Manifest.yml')

        $manifest['Name'] | Should -Be 'TestRedist'
        $manifest.Contains('Title') | Should -BeFalse
        $manifest['Version'] | Should -Be '2.86'
    }

    It 'stores payload paths relative to the payload root inside the inner archive' {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($script:Package.Path)

        try {
            $entry = $zip.Entries | Where-Object { $_.FullName -like 'Archives/*' }
            $buffer = [System.IO.MemoryStream]::new()
            $stream = $entry.Open()
            try { $stream.CopyTo($buffer) } finally { $stream.Dispose() }
            $buffer.Position = 0

            $inner = [System.IO.Compression.ZipArchive]::new($buffer)
            try {
                $names = @($inner.Entries | ForEach-Object { $_.FullName })
                $names | Should -Contain 'readme.txt'
                $names | Should -Contain 'sub/lib.dll'
            }
            finally {
                $inner.Dispose()
            }
        }
        finally {
            $zip.Dispose()
        }
    }

    It 'records RequiresAdmin and strips the directive from the packed script' {
        # ScriptHelper.GetScriptContents re-adds it on the client.
        $manifest = ConvertFrom-Yaml -Ordered -Yaml (Get-EntryText -Path $script:Package.Path -Entry 'Manifest.yml')
        $install = @($manifest['Scripts']) | Where-Object { $_['Type'] -eq 'Install' }

        $install['RequiresAdmin'] | Should -BeTrue
        $install['Platforms'] | Should -Be 'Windows'

        $contents = Get-EntryText -Path $script:Package.Path -Entry 'Scripts/7b2c3d4e-5f6a-4b7c-8d9e-0f1a2b3c4d5e'
        $contents | Should -Not -Match '#Requires'
    }

    It 'reports accurate archive sizes' {
        $manifest = ConvertFrom-Yaml -Ordered -Yaml (Get-EntryText -Path $script:Package.Path -Entry 'Manifest.yml')
        $archive = @($manifest['Archives'])[0]

        # 'payload file' (12) + 'fake binary content' (19), plus a newline each.
        [long] $archive['UncompressedSize'] | Should -BeGreaterThan 25
        [long] $archive['CompressedSize'] | Should -BeGreaterThan 0
    }

    It 'embeds the OptionSchema as a string' {
        $manifest = ConvertFrom-Yaml -Ordered -Yaml (Get-EntryText -Path $script:Package.Path -Entry 'Manifest.yml')

        $manifest['OptionSchema'] | Should -BeOfType [string]
        $manifest['OptionSchema'] | Should -Match 'Mode'
    }

    It 'derives the same archive GUID when the same version is rebuilt' {
        # A random GUID would create a duplicate archive record on every re-import.
        $again = Build-TestPackage -Root $script:Root -Version '2.86'
        $again.ArchiveId | Should -Be $script:Package.ArchiveId
    }

    It 'derives a different archive GUID for a different version' {
        $next = Build-TestPackage -Root $script:Root -Version '2.87'
        $next.ArchiveId | Should -Not -Be $script:Package.ArchiveId
    }

    It 'sanitises a non-semver version into a usable git tag but keeps it raw in the manifest' {
        $package = Build-TestPackage -Root $script:Root -Version 'June 2010'
        $manifest = ConvertFrom-Yaml -Ordered -Yaml (Get-EntryText -Path $package.Path -Entry 'Manifest.yml')

        $package.Tag | Should -Be 'vJune-2010'
        $manifest['Version'] | Should -Be 'June 2010'
    }

    It 'builds an archive-less package when there is no payload' {
        # RedistributableClient.InstallAsync still runs Install with no archives.
        $definition = Get-RedistributableDefinition -Path $script:Root
        $output = Join-Path $script:Temp "noarchive-$([guid]::NewGuid()).lcx"

        $package = New-LcxPackage -Definition $definition -Version '1.0' `
            -ScriptsPath (Join-Path $script:Root 'Scripts') -OutputPath $output

        $package.ArchiveId | Should -BeNullOrEmpty
        @(Get-EntryNames -Path $output | Where-Object { $_ -like 'Archives/*' }).Count | Should -Be 0
    }

    It 'fails when a declared script has no file on disk' {
        $root = New-TestRepository
        Remove-Item (Join-Path $root 'Scripts/Install.ps1')
        $definition = Get-RedistributableDefinition -Path $root

        { New-LcxPackage -Definition $definition -Version '1.0' `
            -ScriptsPath (Join-Path $root 'Scripts') `
            -OutputPath (Join-Path $script:Temp 'fail.lcx') } | Should -Throw '*Install.ps1 is missing*'
    }
}

Describe 'Test-LcxPackage' {
    It 'accepts a well-formed package' {
        $package = Build-TestPackage -Root (New-TestRepository)
        (Test-LcxPackage -Path $package.Path).IsValid | Should -BeTrue
    }

    It 'rejects a package whose manifest entry is misnamed' {
        $source = (Build-TestPackage -Root (New-TestRepository)).Path
        $broken = Join-Path $script:Temp "broken-$([guid]::NewGuid()).lcx"

        $inStream = [System.IO.Compression.ZipFile]::OpenRead($source)
        $outStream = [System.IO.File]::Create($broken)
        $out = [System.IO.Compression.ZipArchive]::new($outStream, [System.IO.Compression.ZipArchiveMode]::Create)

        try {
            foreach ($entry in $inStream.Entries) {
                $name = if ($entry.FullName -eq 'Manifest.yml') { 'manifest.yaml' } else { $entry.FullName }
                $new = $out.CreateEntry($name)
                $src = $entry.Open(); $dst = $new.Open()
                try { $src.CopyTo($dst) } finally { $src.Dispose(); $dst.Dispose() }
            }
        }
        finally {
            $out.Dispose(); $outStream.Dispose(); $inStream.Dispose()
        }

        $result = Test-LcxPackage -Path $broken

        $result.IsValid | Should -BeFalse
        $result.Errors -join ' ' | Should -Match "requires exactly 'Manifest.yml'"
    }

    It 'round-trips through the real SDK model types' -Skip:(-not $script:HasSdk) {
        $package = Build-TestPackage -Root (New-TestRepository)
        $result = Test-LcxPackage -Path $package.Path -Strict -SdkSourcePath $script:SdkPath

        $result.Errors -join ' ' | Should -BeNullOrEmpty
        $result.IsValid | Should -BeTrue
    }
}

Describe 'Update-OptionSchemaFile' {
    It 'writes a schema and reports it as up to date on a second run' {
        $root = New-TestRepository

        $first = Update-OptionSchemaFile -RepositoryPath $root
        $first.IsUpToDate | Should -BeFalse
        Test-Path (Join-Path $root 'OptionSchema.yml') | Should -BeTrue

        $second = Update-OptionSchemaFile -RepositoryPath $root
        $second.IsUpToDate | Should -BeTrue
    }

    It 'detects a stale committed schema without writing when -Check is set' {
        $root = New-TestRepository
        Update-OptionSchemaFile -RepositoryPath $root | Out-Null

        Add-Content -Path (Join-Path $root 'app.ini') -Value 'Extra = 9'

        $before = Get-Content (Join-Path $root 'OptionSchema.yml') -Raw
        $result = Update-OptionSchemaFile -RepositoryPath $root -Check

        $result.IsUpToDate | Should -BeFalse
        $result.Report.Added | Should -Contain 'General.Extra'
        Get-Content (Join-Path $root 'OptionSchema.yml') -Raw | Should -BeExactly $before
    }

    It 'produces a readable markdown change report' {
        $root = New-TestRepository
        Update-OptionSchemaFile -RepositoryPath $root | Out-Null
        Add-Content -Path (Join-Path $root 'app.ini') -Value 'Extra = 9'

        $result = Update-OptionSchemaFile -RepositoryPath $root -Check
        $markdown = Export-OptionSchemaFile -Report $result.Report -Version '2.87'

        $markdown | Should -Match 'Upstream version'
        $markdown | Should -Match 'General.Extra'
    }
}

Describe 'Test-RedistributableLicense' {
    BeforeAll {
        $script:Policy = Join-Path $PSScriptRoot '../policy/licenses.yml'

        function New-LicensedPayload {
            param([string] $Text)

            $path = Join-Path $script:Temp ([guid]::NewGuid())
            New-Item -ItemType Directory -Path $path -Force | Out-Null
            Set-Content -Path (Join-Path $path 'LICENSE') -Encoding utf8 -Value $Text

            return $path
        }
    }

    It 'permits redistribution of an MIT payload' {
        $payload = New-LicensedPayload 'Permission is hereby granted, free of charge, to any person obtaining a copy of this software'
        $result = Test-RedistributableLicense -PayloadPath $payload -PolicyPath $script:Policy

        $result.License | Should -Be 'MIT'
        $result.Redistribute | Should -Be 'yes'
        $result.RecommendedSourceMode | Should -BeNullOrEmpty
        $result.RequiresHumanReview | Should -BeFalse
    }

    It 'forces Source.Mode none when redistribution is prohibited' {
        $payload = New-LicensedPayload 'This software may not be redistributed in any form.'
        $result = Test-RedistributableLicense -PayloadPath $payload -PolicyPath $script:Policy

        $result.Redistribute | Should -Be 'no'
        $result.RecommendedSourceMode | Should -Be 'none'
    }

    It 'prioritises a redistribution ban over a permissive-looking disclaimer in the same file' {
        $payload = New-LicensedPayload @'
This software is provided 'as-is', without any express or implied warranty.
However, redistribution is prohibited without written permission.
'@
        $result = Test-RedistributableLicense -PayloadPath $payload -PolicyPath $script:Policy

        $result.Redistribute | Should -Be 'no'
    }

    It 'flags freeware terms for human review without changing the packaging mode' {
        $payload = New-LicensedPayload 'This tool is free for personal use only.'
        $result = Test-RedistributableLicense -PayloadPath $payload -PolicyPath $script:Policy

        $result.Redistribute | Should -Be 'conditional'
        $result.RequiresHumanReview | Should -BeTrue
        $result.RecommendedSourceMode | Should -BeNullOrEmpty
    }

    It 'defaults to conditional when no license text is present at all' {
        $payload = Join-Path $script:Temp ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $payload -Force | Out-Null

        $result = Test-RedistributableLicense -PayloadPath $payload -PolicyPath $script:Policy

        $result.Redistribute | Should -Be 'conditional'
        $result.License | Should -Be 'Unknown'
    }

    It 'records the obligations attached to a matched license' {
        $payload = New-LicensedPayload 'Licensed under the Apache License, Version 2.0'
        $result = Test-RedistributableLicense -PayloadPath $payload -PolicyPath $script:Policy

        $result.License | Should -Be 'Apache-2.0'
        $result.Obligations.Count | Should -BeGreaterThan 0
    }

    It 'does not mistake GPL for LGPL because of the cross-reference in its closing notes' {
        # GPLv3's "How to Apply These Terms" says to use the GNU Lesser General
        # Public License instead for a library. Signatures are matched with
        # whitespace collapsed, so that sentence -- wrapped across lines in the
        # real file -- used to match a bare LGPL signature and classify every
        # GPLv3 payload as LGPL.
        $payload = New-LicensedPayload @'
                    GNU GENERAL PUBLIC LICENSE
                       Version 3, 29 June 2007

  ...you may consider it more useful to permit linking proprietary
applications with the library. If this is what you want to do, use the GNU
Lesser General Public License instead of this License.
'@
        $result = Test-RedistributableLicense -PayloadPath $payload -PolicyPath $script:Policy

        $result.License | Should -Be 'GPL'
    }

    It 'recognises the LGPL under both of its titles, over the ordinary GPL it references' {
        # An LGPL text names the ordinary GPL throughout, so it must outrank it.
        # Before v2.1 the LGPL was called the Library General Public License,
        # which is what OpenAL Soft ships.
        foreach ($title in @('GNU LESSER GENERAL PUBLIC LICENSE Version 2.1, February 1999',
                             'GNU LIBRARY GENERAL PUBLIC LICENSE Version 2, June 1991')) {
            $payload = New-LicensedPayload "$title`n`nThis license, the GNU General Public License, applies to..."
            $result = Test-RedistributableLicense -PayloadPath $payload -PolicyPath $script:Policy

            $result.License | Should -Be 'LGPL'
        }
    }
}

Describe 'Resolve-UpstreamVersion' {
    It 'returns a pinned version for the static resolver' {
        $result = Resolve-UpstreamVersion -Resolver static -Version '2.86' -Url 'https://example.com/f.zip'

        $result.Version | Should -Be '2.86'
        $result.DownloadUrl | Should -Be 'https://example.com/f.zip'
    }

    It 'requires a version for the static resolver' {
        { Resolve-UpstreamVersion -Resolver static } | Should -Throw '*requires -Version*'
    }

    It 'requires a pattern for the html resolver' {
        { Resolve-UpstreamVersion -Resolver html -Url 'https://example.com' } | Should -Throw '*requires -Pattern*'
    }

    It 'rejects a repository reference it cannot parse' {
        { Resolve-UpstreamVersion -Resolver github-release -Url 'not a repo' } | Should -Throw '*owner/name*'
    }
}

Describe 'Test-RedistributableLicense - bundling prohibitions' {
    BeforeAll {
        $script:PolicyPath = Join-Path $PSScriptRoot '../policy/licenses.yml'
    }

    It 'blocks bundling when upstream forbids inclusion in launchers' {
        # dgVoodoo2's real terms. Redistribution is allowed, but bundling into a
        # launcher for use across multiple applications -- exactly what an .LCX in
        # a redistributable library does -- is not.
        $payload = Join-Path $script:Temp ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $payload -Force | Out-Null
        Set-Content -Path (Join-Path $payload 'LICENSE') -Encoding utf8 -Value @'
You can freely ship your game or game mod with individual dgVoodoo files included.
If you want to host or re-distribute dgVoodoo as a standalone component for any
reason then you must provide the full .zip package. You cannot bundle dgVoodoo
inside launchers or frameworks, for general use across multiple applications.
'@

        $result = Test-RedistributableLicense -PayloadPath $payload -PolicyPath $script:PolicyPath

        $result.License | Should -Be 'Proprietary-NoBundling'
        $result.Redistribute | Should -Be 'no'
        $result.RecommendedSourceMode | Should -Be 'none'
    }
}

Describe 'Get-RedistributableDefinition - repository name' {
    It 'derives a filename-safe repository name from a display name with spaces' {
        # "OpenAL Soft" is the display name; the release asset cannot carry a space.
        $root = New-TestRepository
        Set-Content -Path (Join-Path $root 'redistributable.yml') -Encoding utf8 -Value @'
Id: 3f6d1c9e-8b2a-4d51-9c07-1e5a7b3f2d84
Name: OpenAL Soft
'@

        (Get-RedistributableDefinition -Path $root).RepositoryName | Should -Be 'OpenALSoft'
    }

    It 'honours an explicit RepositoryName' {
        $root = New-TestRepository
        Set-Content -Path (Join-Path $root 'redistributable.yml') -Encoding utf8 -Value @'
Id: 3f6d1c9e-8b2a-4d51-9c07-1e5a7b3f2d84
Name: Visual C++ 2015-2022
RepositoryName: VisualCpp
'@

        (Get-RedistributableDefinition -Path $root).RepositoryName | Should -Be 'VisualCpp'
    }
}
