# Returns $true when REDIST_NAME is already installed, which skips the download
# and the Install script entirely.
#
# Hard 10 second timeout -- a slow check is treated as "not installed", so keep it
# to a registry probe or a file existence test. No network calls.
#
# Working directory: {InstallDir}\.lancommander\{RedistributableId}\
# (note: NOT the Files\ subdirectory -- the archive may not be downloaded yet)

$Return = Test-Path "$env:SystemRoot\System32\REPLACE_ME.dll"
