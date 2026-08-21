<#
.SYNOPSIS
    Resolves a redistributable's payload and version, whatever its source mode.
.DESCRIPTION
    Keeps the mode-specific branching in one place so the workflows do not have to
    care how a given redistributable obtains its files.

    download  Runs the repository's source.ps1, which downloads and extracts the
              upstream release into a staging directory and reports the version.
    vendored  Uses the committed Files/ directory. The version comes from
              LastKnownVersion in redistributable.yml.
    none      No payload at all. The package ships scripts only and the files are
              fetched from the vendor after import. This is the mode used when the
              upstream license does not permit redistribution.

              source.ps1 is still useful here: it tracks the upstream version, and
              with -RefreshReference it refreshes the committed Reference/ config
              the option schema is generated from. Neither path ever returns a
              PayloadPath, so nothing can be bundled by accident.

    source.ps1 contract:
      -CheckOnly              write the version to stdout and exit
      -OutputPath <dir>       download and extract there, then emit a JSON object
                              with Version and optionally Changelog
.PARAMETER RepositoryPath
    Root of the redistributable repository.
.PARAMETER StagingPath
    Where a download-mode payload should be extracted. Defaults to a temp directory.
.PARAMETER CheckOnly
    Resolve the version without downloading anything.
.PARAMETER RefreshReference
    Only meaningful in 'none' mode. Lets source.ps1 refresh the repository's
    committed Reference/ directory -- the config a redistributable that ships no
    payload still needs in order to generate an option schema.

    This is how the scheduled upstream check picks up options added upstream. It
    is deliberately opt-in and Invoke-RedistributableBuild never passes it, so a
    build can never acquire files it is not allowed to publish.
.OUTPUTS
    An object with Version, Changelog, PayloadPath and Mode.
#>
function Resolve-RedistributablePayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RepositoryPath,
        [string] $StagingPath,
        [switch] $CheckOnly,
        [switch] $RefreshReference
    )

    $definition = Get-RedistributableDefinition -Path $RepositoryPath
    $mode = [string] $definition['Source']['Mode']
    $sourceScript = Join-Path $RepositoryPath 'source.ps1'

    switch ($mode) {
        'download' {
            if (-not (Test-Path -LiteralPath $sourceScript)) {
                throw "Source.Mode is 'download' but $sourceScript does not exist"
            }

            if ($CheckOnly) {
                $version = (& $sourceScript -CheckOnly | Select-Object -Last 1)

                if ([string]::IsNullOrWhiteSpace($version)) {
                    throw 'source.ps1 -CheckOnly produced no version'
                }

                return [pscustomobject] @{
                    Version     = ([string] $version).Trim()
                    Changelog   = $null
                    PayloadPath = $null
                    Mode        = $mode
                }
            }

            if (-not $StagingPath) {
                $StagingPath = Join-Path ([System.IO.Path]::GetTempPath()) "lcx-payload-$([guid]::NewGuid())"
            }

            if (-not (Test-Path -LiteralPath $StagingPath)) {
                $null = New-Item -ItemType Directory -Path $StagingPath -Force
            }

            $output = & $sourceScript -OutputPath $StagingPath

            # The script may log freely; the contract is that the last JSON object
            # it writes is the result.
            $json = @($output) | Where-Object { $_ -is [string] -and $_.TrimStart().StartsWith('{') } | Select-Object -Last 1

            if (-not $json) {
                throw 'source.ps1 did not emit a JSON result object with a Version'
            }

            $result = $json | ConvertFrom-Json

            if ([string]::IsNullOrWhiteSpace($result.Version)) {
                throw 'source.ps1 emitted a result with no Version'
            }

            if (-not @(Get-ChildItem -LiteralPath $StagingPath -Recurse -File -ErrorAction SilentlyContinue)) {
                throw "source.ps1 completed but '$StagingPath' is empty"
            }

            return [pscustomobject] @{
                Version     = ([string] $result.Version).Trim()
                Changelog   = $result.Changelog
                PayloadPath = $StagingPath
                Mode        = $mode
            }
        }

        'vendored' {
            $files = Join-Path $RepositoryPath 'Files'

            if (-not (Test-Path -LiteralPath $files)) {
                throw "Source.Mode is 'vendored' but $files does not exist"
            }

            $version = [string] $definition['LastKnownVersion']

            if ([string]::IsNullOrWhiteSpace($version)) {
                throw "Source.Mode is 'vendored' so LastKnownVersion in redistributable.yml is the version; it is empty"
            }

            return [pscustomobject] @{
                Version     = $version.Trim()
                Changelog   = $null
                PayloadPath = $files
                Mode        = $mode
            }
        }

        'none' {
            $hasSource = Test-Path -LiteralPath $sourceScript

            # PayloadPath stays null in every branch below. That is the guarantee
            # this mode exists to make: when the upstream license forbids
            # redistribution there must be no way for a build to end up with
            # bundleable files, however it was invoked.

            if ($CheckOnly -and $hasSource) {
                # Mirror 'download'. LastKnownVersion is what a *build* pins to, so
                # letting it answer here too would make the scheduled upstream check
                # compare a value against itself and never see upstream move.
                $version = [string] (& $sourceScript -CheckOnly | Select-Object -Last 1)

                if ([string]::IsNullOrWhiteSpace($version)) {
                    throw 'source.ps1 -CheckOnly produced no version'
                }

                return [pscustomobject] @{
                    Version     = $version.Trim()
                    Changelog   = $null
                    PayloadPath = $null
                    Mode        = $mode
                }
            }

            if ($RefreshReference -and $hasSource) {
                # source.ps1 writes the reference config straight into the
                # repository, because unlike a payload it is a committed artefact:
                # it is the only thing the option schema can be generated from, and
                # the upstream-update pull request has to carry it.
                $reference = Join-Path $RepositoryPath 'Reference'

                if (-not (Test-Path -LiteralPath $reference)) {
                    $null = New-Item -ItemType Directory -Path $reference -Force
                }

                $output = & $sourceScript -OutputPath $reference

                $json = @($output) | Where-Object { $_ -is [string] -and $_.TrimStart().StartsWith('{') } | Select-Object -Last 1

                if (-not $json) {
                    throw 'source.ps1 did not emit a JSON result object with a Version'
                }

                $result = $json | ConvertFrom-Json

                if ([string]::IsNullOrWhiteSpace($result.Version)) {
                    throw 'source.ps1 emitted a result with no Version'
                }

                return [pscustomobject] @{
                    Version     = ([string] $result.Version).Trim()
                    Changelog   = $result.Changelog
                    PayloadPath = $null
                    Mode        = $mode
                }
            }

            $version = [string] $definition['LastKnownVersion']

            if ([string]::IsNullOrWhiteSpace($version) -and $hasSource) {
                # Even with nothing to bundle, source.ps1 can still track the
                # upstream version so releases stay aligned with it.
                $version = [string] (& $sourceScript -CheckOnly | Select-Object -Last 1)
            }

            if ([string]::IsNullOrWhiteSpace($version)) {
                throw "Source.Mode is 'none' but neither LastKnownVersion nor source.ps1 -CheckOnly provided a version"
            }

            return [pscustomobject] @{
                Version     = $version.Trim()
                Changelog   = $null
                PayloadPath = $null
                Mode        = $mode
            }
        }
    }
}
