#Requires -RunAsAdministrator

# Reverses Install. Runs when the game that pulled in this redistributable is
# uninstalled.
#
# Working directory: {InstallDir}\.lancommander\{RedistributableId}\Files\
#
# Be conservative: other installed games may still depend on this runtime. Prefer
# removing only what this redistributable placed, and leave shared system runtimes
# (DirectX, VC++) alone entirely -- for those, a no-op returning 0 is correct.

$Return = 0
