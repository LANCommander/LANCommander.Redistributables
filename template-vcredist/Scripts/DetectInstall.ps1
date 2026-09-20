# Reports whether the selected REDIST_NAME runtimes are already present, and at
# least as new as the build this package carries.
#
# Working directory: {InstallDir}\.lancommander\{RedistributableId}\
#
# Fast by construction: two registry reads per architecture and no network. The
# engine gives this script ten seconds.

$ErrorActionPreference = 'Stop'

# The registry stores a v-prefixed version such as "v14.51.36247.00" while the
# manifest carries the installer's file version "14.51.36247.0". Neither the
# prefix nor the component count is consistent across versions, and a three-part
# [version] has Revision -1 which sorts below 0, so both sides are reduced to
# major.minor.build before comparison.
function Get-RuntimeVersion {
    param([string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    $match = [regex]::Match($Value, '(\d+)\.(\d+)\.(\d+)')

    if (-not $match.Success) { return $null }

    return [version]::new([int] $match.Groups[1].Value, [int] $match.Groups[2].Value, [int] $match.Groups[3].Value)
}

# Anything unexpected means "not installed" rather than an error. A detection
# script that throws inside its timeout tells the operator nothing useful, and
# attempting an install that turns out to be redundant is harmless -- the installer
# itself reports 1638 and the Install script treats that as success.
$Return = $false

try {
    # The cmdlet writes a non-terminating error when the game manifest has no entry
    # for this redistributable. Both is the right answer in that case -- it is never
    # wrong, only occasionally more than necessary -- so the lookup is not allowed to
    # fail the script.
    $options = Get-RedistributableOptions -Path $InstallDirectory -Id $GameManifest.Id `
        -Name 'REDIST_NAME' -ErrorAction SilentlyContinue

    $architecture = if ($options -and $options.Architecture) { ([string] $options.Architecture).ToLowerInvariant() } else { 'both' }

    if ($architecture -eq 'auto') {
        $executable = $GameManifest.Actions |
            Where-Object { $_.IsPrimaryAction } |
            Select-Object -First 1 -ExpandProperty Path

        if ($executable) { $executable = $executable.Replace('{InstallDir}', $InstallDirectory) }

        # Unreadable executable falls back to both rather than guessing. A wrong
        # guess here silently skips the runtime the game actually needs.
        $architecture = 'both'

        if ($executable -and (Test-Path -LiteralPath $executable)) {
            $stream = [System.IO.File]::OpenRead($executable)

            try {
                $reader = [System.IO.BinaryReader]::new($stream)
                $stream.Position = 0x3C
                $stream.Position = $reader.ReadInt32() + 4
                $machine = $reader.ReadUInt16()

                # 0x8664 x64, 0xAA64 ARM64 -- Microsoft's x64 package carries the
                # ARM64 binaries too, so both map to x64. 0x014C is x86, and is
                # also what a managed AnyCPU executable reports even though it runs
                # 64-bit; those games should be set to Both explicitly.
                $architecture = if ($machine -eq 0x8664 -or $machine -eq 0xAA64) { 'x64' } else { 'x86' }
            }
            finally {
                $stream.Dispose()
            }
        }
    }

    $required = switch ($architecture) {
        'x86' { @('x86') }
        'x64' { @('x64') }
        default { @('x86', 'x64') }
    }

    # Null when the manifest carries no version, which degrades this to a presence
    # check rather than failing detection outright.
    $wanted = Get-RuntimeVersion -Value $RedistributableManifest.Version

    $satisfied = $true

    foreach ($arch in $required) {
        # 64-bit PowerShell sees the x64 runtime under the native path and the x86
        # one under WOW6432Node; 32-bit PowerShell is redirected and sees the
        # reverse. Probing both covers either host.
        $entry = $null

        foreach ($root in @(
            'HKLM:\SOFTWARE\UPSTREAM_RUNTIMES_SUBKEY',
            'HKLM:\SOFTWARE\WOW6432Node\UPSTREAM_RUNTIMES_SUBKEY'
        )) {
            $candidate = Get-ItemProperty -Path (Join-Path $root $arch) -ErrorAction SilentlyContinue

            if ($candidate -and $candidate.Installed -eq 1) { $entry = $candidate; break }
        }

        if (-not $entry) {
            Write-Host "REDIST_NAME ($arch) is not installed"
            $satisfied = $false
            break
        }

        $installed = Get-RuntimeVersion -Value ([string] $entry.Version)

        if ($wanted -and (-not $installed -or $installed -lt $wanted)) {
            Write-Host "REDIST_NAME ($arch) is $($entry.Version), older than the packaged $($RedistributableManifest.Version)"
            $satisfied = $false
            break
        }
    }

    $Return = $satisfied
}
catch {
    Write-Host "REDIST_NAME detection failed, assuming not installed: $($_.Exception.Message)"
    $Return = $false
}
