# Runs when the player changes their alias. Only relevant when this
# redistributable stores the player name somewhere -- an overlay nickname, a
# config field, a master-server registration.
#
# Delete this script unless that applies.
#
# Working directory: {InstallDir}\.lancommander\{RedistributableId}\Files\
# Available: $OldPlayerAlias, $NewPlayerAlias, $InstallDirectory, $GameManifest

$Return = 0
