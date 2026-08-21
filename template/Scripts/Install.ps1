#Requires -RunAsAdministrator

# Installs REDIST_NAME. Runs only when DetectInstall returned $false.
#
# Working directory: {InstallDir}\.lancommander\{RedistributableId}\Files\
# -- the extracted contents of the archive, so relative paths work directly.
#
# Return the process exit code; 0 means success.
#
# The '#Requires -RunAsAdministrator' line above is detected at packaging time and
# recorded as RequiresAdmin on the manifest, then re-added by the client. Keep it
# only if the installation genuinely needs elevation.

$process = Start-Process -FilePath '.\setup.exe' -ArgumentList '/quiet /norestart' -Wait -PassThru

$Return = $process.ExitCode
