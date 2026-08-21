# Wraps the launch of the game executable. Only for compatibility shims that need
# more than a CommandTemplate can express -- DLL injection, a bespoke environment,
# a supervising process.
#
# If a plain 'wrapper {exe} {args}' invocation is enough, delete this script and
# set CommandTemplate in Schema.Overlay.yml instead; the launcher applies that
# with no PowerShell involved.
#
# Working directory: {InstallDir}\.lancommander\{RedistributableId}\
# Available: $ExecutablePath, $Arguments, $WorkingDirectory, $InstallDirectory, $GameManifest
#
# Return $true when this script launched the process, so the launcher does not
# also start it.

$options = Get-RedistributableOptions -Path $InstallDirectory -Id $GameManifest.Id -Name 'REDIST_NAME'

$process = Start-Process -FilePath $ExecutablePath -ArgumentList $Arguments -WorkingDirectory $WorkingDirectory -PassThru

$Return = $null -ne $process
