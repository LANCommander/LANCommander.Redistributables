#Requires -RunAsAdministrator

Copy-Item -Path ".\*" -Destination $InstallDirectory -Recurse -Force
$Return = 0
