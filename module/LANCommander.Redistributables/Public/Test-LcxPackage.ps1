<#
.SYNOPSIS
    Validates a built .LCX package.
.DESCRIPTION
    Two levels.

    The default structural pass is pure PowerShell and checks the things
    ImportContext and the importers depend on: Manifest.yml present at the archive
    root under exactly that name, a non-empty Name so the manifest duck-types to
    Redistributable rather than Game, and an Archives/{id} or Scripts/{id} entry
    backing every record the manifest references.

    -Strict additionally round-trips the package through the real SDK. This is the
    only way to be certain the server will accept it: it deserialises Manifest.yml
    with ManifestHelper and parses OptionSchema with the same YamlDotNet
    configuration the server uses, rather than with our approximation of it.

    The strict check runs out of process. LANCommander.SDK depends on
    Microsoft.PowerShell.SDK, so Add-Type-ing it into a live pwsh session would
    load a second System.Management.Automation alongside the running one. The
    validator project is generated into a temp directory on demand, so there is no
    checked-in .NET project to keep in sync.
.PARAMETER Path
    The .lcx file to validate.
.PARAMETER Strict
    Also round-trip through the real SDK model types. Requires the .NET SDK.
.PARAMETER SdkSourcePath
    A local LANCommander.SDK directory to take the model sources from. Defaults to
    $env:LANCOMMANDER_SDK_PATH, then to fetching them from GitHub.
.PARAMETER SdkRef
    Git ref to fetch the model sources from when no local path is available.
#>
function Test-LcxPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string] $Path,
        [switch] $Strict,
        [string] $SdkSourcePath = $env:LANCOMMANDER_SDK_PATH,
        [string] $SdkRef = 'main',
        [string] $TargetFramework = 'net10.0'
    )

    Initialize-YamlSupport

    $errors = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    if (-not (Test-Path -LiteralPath $Path)) {
        $errors.Add("Package not found: $Path")
        return New-ValidationResult -Errors $errors -Warnings $warnings
    }

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $zip = [System.IO.Compression.ZipFile]::OpenRead($resolved)

    try {
        $names = @($zip.Entries | ForEach-Object { $_.FullName })

        # ImportContext compares entry keys with ordinal equality against
        # ManifestHelper.ManifestFilename, so the casing has to be exact.
        if ($names -notcontains 'Manifest.yml') {
            $near = $names | Where-Object { $_ -ieq 'Manifest.yml' -or $_ -ilike '*manifest.y*ml' }

            if ($near) {
                $errors.Add("Manifest entry is named '$($near -join ', ')' but the importer requires exactly 'Manifest.yml'")
            }
            else {
                $errors.Add("Package has no Manifest.yml at the archive root")
            }

            return New-ValidationResult -Errors $errors -Warnings $warnings
        }

        $manifestYaml = Read-ZipEntryText -Zip $zip -EntryName 'Manifest.yml'

        try {
            $manifest = ConvertFrom-Yaml -Yaml $manifestYaml -Ordered
        }
        catch {
            $errors.Add("Manifest.yml is not valid YAML: $($_.Exception.Message)")
            return New-ValidationResult -Errors $errors -Warnings $warnings
        }

        if (-not $manifest.Contains('Name') -or [string]::IsNullOrWhiteSpace([string] $manifest['Name'])) {
            # ImportContext tries Game first and only falls through to
            # Redistributable when Name is populated.
            $errors.Add('Manifest has no Name; the importer would not recognise this as a redistributable')
        }

        if ($manifest.Contains('Title') -and $manifest['Title']) {
            $errors.Add('Manifest has a Title, which makes the importer treat it as a Game rather than a Redistributable')
        }

        if (-not $manifest.Contains('Id') -or [string]::IsNullOrWhiteSpace([string] $manifest['Id'])) {
            $errors.Add('Manifest has no Id; without a stable Id every import creates a duplicate redistributable')
        }

        if (-not $manifest.Contains('Version') -or [string]::IsNullOrWhiteSpace([string] $manifest['Version'])) {
            $warnings.Add('Manifest has no Version')
        }

        foreach ($archive in @($manifest['Archives'])) {
            if (-not $archive) { continue }

            $id = [string] $archive['Id']

            if ($names -notcontains "Archives/$id") {
                $errors.Add("Manifest references archive $id but Archives/$id is missing from the package")
            }

            if ([string]::IsNullOrWhiteSpace([string] $archive['Version'])) {
                # RedistributableService derives the redistributable's version from
                # the newest archive, so a blank one leaves it unversioned.
                $errors.Add("Archive $id has no Version")
            }
        }

        $scriptTypes = @()

        foreach ($script in @($manifest['Scripts'])) {
            if (-not $script) { continue }

            $id = [string] $script['Id']
            $scriptTypes += [string] $script['Type']

            if ($names -notcontains "Scripts/$id") {
                $errors.Add("Manifest references script $id but Scripts/$id is missing from the package")
            }
        }

        foreach ($expected in @('DetectInstall', 'Install')) {
            if ($scriptTypes -notcontains $expected) {
                $warnings.Add("Package has no $expected script")
            }
        }

        if ($manifest.Contains('OptionSchema') -and $manifest['OptionSchema']) {
            $schemaResult = try {
                $parsed = ConvertFrom-Yaml -Yaml ([string] $manifest['OptionSchema']) -Ordered
                Test-OptionSchema -Schema $parsed
            }
            catch {
                $errors.Add("Embedded OptionSchema is not valid YAML: $($_.Exception.Message)")
                $null
            }

            if ($schemaResult) {
                foreach ($item in $schemaResult.Errors) { $errors.Add("OptionSchema: $item") }
                foreach ($item in $schemaResult.Warnings) { $warnings.Add("OptionSchema: $item") }
            }
        }
    }
    finally {
        $zip.Dispose()
    }

    if ($Strict) {
        $strictResult = Invoke-SdkValidation -Path $resolved -SdkSourcePath $SdkSourcePath -SdkRef $SdkRef -TargetFramework $TargetFramework

        foreach ($item in $strictResult.Errors) { $errors.Add("SDK: $item") }
        foreach ($item in $strictResult.Warnings) { $warnings.Add("SDK: $item") }
    }

    return New-ValidationResult -Errors $errors -Warnings $warnings
}

<#
.SYNOPSIS
    Round-trips a package through the real SDK model types in a throwaway project.
.DESCRIPTION
    The model sources are compiled from LANCommander.SDK directly rather than
    consumed from the published NuGet package. LANCommander.SDK on nuget.org is not
    restorable -- it depends on LANCommander.Steam, which has never been published --
    and even if it were, it drags in Microsoft.PowerShell.SDK and 60-odd other
    packages to validate a handful of POCOs.

    Compiling the model files against YamlDotNet alone is both far cheaper and
    strictly better: it validates against whatever is on the SDK's main branch today
    rather than against a pinned package that may already have drifted.

    The deserialiser configuration is reproduced from ManifestHelper.Deserialize and
    from the three places the server builds an OptionSchema deserialiser
    (CompatibilityResolver, ProcessExecutionContext, Get-RedistributableOptions).
    Those methods cannot be compiled here because they pull in the whole client
    stack, so this is the one part that is replicated rather than borrowed. It is
    four lines and has been stable since the compatibility-options work landed.
#>
function Invoke-SdkValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [AllowEmptyString()][string] $SdkSourcePath,
        [Parameter(Mandatory)][string] $SdkRef,
        [Parameter(Mandatory)][string] $TargetFramework
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        $warnings.Add('dotnet was not found on PATH; skipping the strict round-trip')
        return [pscustomobject] @{ Errors = $errors; Warnings = $warnings }
    }

    # Only the files that define the manifest and option-schema contract.
    $modelFiles = @(
        'Enums/RuntimePlatform.cs'
        'Enums/ScriptType.cs'
        'Models/OptionSchema.cs'
        'Models/Manifest/BaseModel.cs'
        'Models/Manifest/IKeyedModel.cs'
        'Models/Manifest/BaseManifest.cs'
        'Models/Manifest/Archive.cs'
        'Models/Manifest/Script.cs'
        'Models/Manifest/Redistributable.cs'
    )

    $projectDir = Join-Path ([System.IO.Path]::GetTempPath()) "lcx-validate-$([guid]::NewGuid())"
    $modelDir = Join-Path $projectDir 'Sdk'
    $null = New-Item -ItemType Directory -Path $modelDir -Force

    try {
        foreach ($file in $modelFiles) {
            $flatName = ($file -replace '[/\\]', '_')
            $destination = Join-Path $modelDir $flatName

            if ($SdkSourcePath -and (Test-Path -LiteralPath (Join-Path $SdkSourcePath $file))) {
                Copy-Item -LiteralPath (Join-Path $SdkSourcePath $file) -Destination $destination -Force
            }
            else {
                $uri = "https://raw.githubusercontent.com/LANCommander/LANCommander/$SdkRef/LANCommander.SDK/$file"

                try {
                    Invoke-WebRequest -Uri $uri -OutFile $destination -UseBasicParsing -MaximumRetryCount 3 -RetryIntervalSec 3
                }
                catch {
                    $errors.Add("Could not obtain SDK model source '$file': $($_.Exception.Message)")
                    return [pscustomobject] @{ Errors = $errors; Warnings = $warnings }
                }
            }
        }

        # BaseManifest.cs carries an unused 'using LANCommander.SDK.Helpers', which
        # is a compile error unless the namespace exists somewhere.
        Set-Content -Path (Join-Path $modelDir 'NamespaceStubs.cs') -Encoding utf8 -Value @'
namespace LANCommander.SDK.Helpers { internal static class NamespaceStub { } }
'@

        Set-Content -Path (Join-Path $projectDir 'Validator.csproj') -Encoding utf8 -Value @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>$TargetFramework</TargetFramework>
    <Nullable>disable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <AssemblyName>Validator</AssemblyName>
    <InvariantGlobalization>true</InvariantGlobalization>
    <NoWarn>`$(NoWarn);CS0618;CS8981</NoWarn>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="YamlDotNet" Version="16.3.0" />
  </ItemGroup>
</Project>
"@

        Set-Content -Path (Join-Path $projectDir 'Program.cs') -Encoding utf8 -Value (Get-SdkValidatorSource)

        Push-Location $projectDir

        try {
            $output = & dotnet run --configuration Release -- $Path 2>&1
            $exitCode = $LASTEXITCODE
        }
        finally {
            Pop-Location
        }

        $json = $output | Where-Object { $_ -is [string] -and $_.TrimStart().StartsWith('{') } | Select-Object -Last 1

        if (-not $json) {
            $errors.Add("Validator produced no result (exit $exitCode): $($output | Select-Object -Last 12 | Out-String)")
            return [pscustomobject] @{ Errors = $errors; Warnings = $warnings }
        }

        $result = $json | ConvertFrom-Json

        foreach ($item in @($result.Errors)) { $errors.Add([string] $item) }
        foreach ($item in @($result.Warnings)) { $warnings.Add([string] $item) }

        if ($result.OptionCount -ge 0) {
            Write-Verbose "SDK flattened $($result.OptionCount) option(s) from the embedded schema"
        }
    }
    catch {
        $errors.Add("Strict validation failed: $($_.Exception.Message)")
    }
    finally {
        Remove-Item -LiteralPath $projectDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    return [pscustomobject] @{ Errors = $errors; Warnings = $warnings }
}

<#
.SYNOPSIS
    The C# validator source. Kept here so the hub has no checked-in .NET project.
#>
function Get-SdkValidatorSource {
    return @'
using System.IO.Compression;
using System.Text.Json;
using LANCommander.SDK.Models;
using LANCommander.SDK.Models.Manifest;
using YamlDotNet.Serialization;
using YamlDotNet.Serialization.NamingConventions;

var errors = new List<string>();
var warnings = new List<string>();
var optionCount = -1;

// Reproduced from ManifestHelper.Deserialize.
static T DeserializeManifest<T>(string yaml)
{
    var deserializer = new DeserializerBuilder()
        .IgnoreUnmatchedProperties()
        .WithNamingConvention(new PascalCaseNamingConvention())
        .Build();

    return deserializer.Deserialize<T>(yaml);
}

try
{
    using var zip = ZipFile.OpenRead(args[0]);

    // ManifestHelper.ManifestFilename. Ordinal comparison, so casing matters.
    var entry = zip.GetEntry("Manifest.yml");

    if (entry is null)
    {
        errors.Add("No Manifest.yml entry");
    }
    else
    {
        string yaml;
        using (var reader = new StreamReader(entry.Open()))
            yaml = reader.ReadToEnd();

        Redistributable redistributable;

        try
        {
            redistributable = DeserializeManifest<Redistributable>(yaml);
        }
        catch (Exception ex)
        {
            errors.Add($"Manifest failed to deserialise as Manifest.Redistributable: {ex.Message}");
            goto done;
        }

        // ImportContext tries Game first and only reaches the Redistributable
        // branch when Name is populated.
        if (string.IsNullOrWhiteSpace(redistributable.Name))
            errors.Add("Manifest.Name is empty; the importer would not select the redistributable branch");

        if (redistributable.Id == Guid.Empty)
            errors.Add("Manifest.Id is the empty GUID; every import would create a duplicate");

        if (redistributable.IsLegacyManifest())
            warnings.Add("ManifestVersion is empty, so the importer treats this as a legacy manifest");

        foreach (var archive in redistributable.Archives ?? new List<Archive>())
        {
            if (zip.GetEntry($"Archives/{archive.Id}") is null)
                errors.Add($"Archives/{archive.Id} is referenced by the manifest but missing");

            if (string.IsNullOrWhiteSpace(archive.Version))
                errors.Add($"Archive {archive.Id} has no Version");
        }

        foreach (var script in redistributable.Scripts ?? new List<Script>())
        {
            if (zip.GetEntry($"Scripts/{script.Id}") is null)
                errors.Add($"Scripts/{script.Id} is referenced by the manifest but missing");
        }

        if (!string.IsNullOrWhiteSpace(redistributable.OptionSchema))
        {
            // The deserialiser the server builds in CompatibilityResolver,
            // ProcessExecutionContext and Get-RedistributableOptions.
            var deserializer = new DeserializerBuilder()
                .WithNamingConvention(PascalCaseNamingConvention.Instance)
                .WithTypeConverter(new OptionChoiceYamlConverter())
                .IgnoreUnmatchedProperties()
                .Build();

            try
            {
                var schema = deserializer.Deserialize<OptionSchema>(redistributable.OptionSchema);
                var flattened = schema.GetFlattenedOptions();
                optionCount = flattened.Count;

                foreach (var kvp in flattened)
                {
                    // What per-game storage and Get-RedistributableOptions call.
                    var resolved = kvp.Value.GetDefaultAsString();

                    if (kvp.Key.Split('.').Any(string.IsNullOrWhiteSpace))
                        errors.Add($"Flattened option key '{kvp.Key}' has an empty segment");

                    if (kvp.Value.IsList && kvp.Value.IsEnvironmentVariable)
                        warnings.Add($"Option '{kvp.Key}' is a list marked as an environment variable; it is skipped at launch");

                    // A bool Default round-trips to .NET's "True"/"False" rather
                    // than the lowercase form scripts compare against.
                    if (kvp.Value.Default is bool)
                        errors.Add($"Option '{kvp.Key}' has an unquoted boolean Default; it resolves as '{resolved}'");
                }

                if (optionCount == 0)
                    warnings.Add("OptionSchema flattened to zero options");
            }
            catch (Exception ex)
            {
                errors.Add($"OptionSchema failed to deserialise: {ex.Message}");
            }
        }
    }
}
catch (Exception ex)
{
    errors.Add($"Validator threw: {ex.Message}");
}

done:
Console.WriteLine(JsonSerializer.Serialize(new { Errors = errors, Warnings = warnings, OptionCount = optionCount }));
return errors.Count == 0 ? 0 : 1;
'@
}

<#
.SYNOPSIS
    Reads a zip entry as UTF-8 text.
#>
function Read-ZipEntryText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.IO.Compression.ZipArchive] $Zip,
        [Parameter(Mandatory)][string] $EntryName
    )

    $entry = $Zip.GetEntry($EntryName)
    if (-not $entry) { throw "Entry not found: $EntryName" }

    $stream = $entry.Open()

    try {
        $reader = [System.IO.StreamReader]::new($stream)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    finally {
        $stream.Dispose()
    }
}
