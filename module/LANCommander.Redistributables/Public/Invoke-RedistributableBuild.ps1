<#
.SYNOPSIS
    Runs the full build for a redistributable repository: resolve, rebuild, pack, validate.
.DESCRIPTION
    The single command the build workflow calls. Having it here rather than as a
    sequence of workflow steps means the same build can be run locally, verbatim,
    before anything is pushed.

    The committed OptionSchema.yml is treated like a lockfile. The build regenerates
    it from the upstream config and fails if the result differs from what is
    committed, so the schema in the repository always matches the schema in the
    published package. Pass -UpdateSchema to rewrite it instead of failing, which
    is what the scheduled upstream job does.
.PARAMETER RepositoryPath
    Root of the redistributable repository.
.PARAMETER OutputDirectory
    Where to write the .lcx and payload.zip.
.PARAMETER UpdateSchema
    Rewrite OptionSchema.yml rather than failing when it is stale.
.PARAMETER Strict
    Run the SDK round-trip as part of validation.
.OUTPUTS
    An object with Package, Version, Tag, SchemaResult and Assets.
#>
function Invoke-RedistributableBuild {
    # Write-Host is deliberate. This is build progress that should always be
    # visible in a CI log without callers having to opt in, and the function
    # returns a result object -- writing progress to the output stream would
    # become part of that return value.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RepositoryPath,
        [string] $OutputDirectory = './.build',
        [switch] $UpdateSchema,
        [switch] $Strict,
        [string] $SdkSourcePath = $env:LANCOMMANDER_SDK_PATH
    )

    $definition = Get-RedistributableDefinition -Path $RepositoryPath
    $name = [string] $definition['Name']

    Write-Host "==> Resolving payload for $name"
    $payload = Resolve-RedistributablePayload -RepositoryPath $RepositoryPath
    Write-Host "    mode=$($payload.Mode) version=$($payload.Version)"

    Write-Host '==> Rebuilding OptionSchema.yml'
    $schema = Update-OptionSchemaFile -RepositoryPath $RepositoryPath -PayloadPath $payload.PayloadPath -Check:(-not $UpdateSchema)

    if ($schema.Path) {
        if (-not $schema.IsUpToDate -and -not $UpdateSchema) {
            $report = Export-OptionSchemaFile -Report $schema.Report -Version $payload.Version

            throw @"
OptionSchema.yml is out of date with the upstream config.

Run this locally and commit the result:
    Invoke-RedistributableBuild -RepositoryPath . -UpdateSchema

$report
"@
        }

        if ($schema.Validation -and -not $schema.Validation.IsValid) {
            foreach ($item in $schema.Validation.Errors) { Write-Host "    ERROR: $item" }
            throw 'OptionSchema.yml failed validation'
        }

        foreach ($item in @($schema.Validation.Warnings)) { Write-Warning $item }
    }

    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
    }

    $tag = ConvertTo-VersionTag -Version $payload.Version

    # RepositoryName, not Name -- the display name may contain spaces, which have
    # no business in a release asset filename.
    $repositoryName = "LANCommander.Redistributables.$($definition['RepositoryName'])"
    $lcxPath = Join-Path $OutputDirectory "$repositoryName-v$tag.lcx"

    Write-Host "==> Packing $lcxPath"
    $package = New-LcxPackage -Definition $definition -Version $payload.Version `
        -PayloadPath $payload.PayloadPath `
        -ScriptsPath (Join-Path $RepositoryPath 'Scripts') `
        -OptionSchemaPath (Join-Path $RepositoryPath 'OptionSchema.yml') `
        -OutputPath $lcxPath

    Write-Host '==> Validating package'
    $validation = Test-LcxPackage -Path $package.Path -Strict:$Strict -SdkSourcePath $SdkSourcePath

    foreach ($item in $validation.Warnings) { Write-Warning $item }

    if (-not $validation.IsValid) {
        foreach ($item in $validation.Errors) { Write-Host "    ERROR: $item" }
        throw 'The built package failed validation'
    }

    $assets = @($package.Path)

    # A fixed-name copy so consumers can use /releases/latest/download/redistributable.lcx
    # without knowing the version.
    $stable = Join-Path $OutputDirectory 'redistributable.lcx'
    Copy-Item -LiteralPath $package.Path -Destination $stable -Force
    $assets += $stable

    # A plain payload zip, which is what a server-side Package script consumes --
    # it returns a directory of files, not an .lcx.
    if ($payload.PayloadPath) {
        $payloadZip = Join-Path $OutputDirectory 'payload.zip'

        if (Test-Path -LiteralPath $payloadZip) { Remove-Item -LiteralPath $payloadZip -Force }

        Compress-Archive -Path (Join-Path $payload.PayloadPath '*') -DestinationPath $payloadZip -CompressionLevel Optimal
        $assets += $payloadZip
    }

    Write-Host "==> Built $repositoryName v$($payload.Version)"

    return [pscustomobject] @{
        Package      = $package
        Version      = $payload.Version
        Tag          = "v$tag"
        Changelog    = $payload.Changelog
        SchemaResult = $schema
        Assets       = $assets
        Name         = $name
        Repository   = $repositoryName
    }
}
