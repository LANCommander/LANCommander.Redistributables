# Runs after the game exits. Only needed when BeforeStart changed something in the
# game directory that should not persist between sessions.
#
# Delete this script unless there is genuinely something to restore.
#
# Working directory: {InstallDir}\.lancommander\{RedistributableId}\Files\
# Available: $InstallDirectory, $GameManifest, $PlayerAlias

$Return = 0
