# Runs before every launch of a game assigned this redistributable. Use it to
# write the resolved option values into the tool's config file, so per-game
# settings configured in the admin UI actually take effect.
#
# Delete this script (and its entry in redistributable.yml) unless the
# redistributable has options that live in a config file.
#
# Working directory: {InstallDir}\.lancommander\{RedistributableId}\Files\
# Available: $InstallDirectory, $GameManifest, $PlayerAlias

$options = Get-RedistributableOptions -Path $InstallDirectory -Id $GameManifest.Id -Name 'REDIST_NAME'

# Option paths mirror the structure of OptionSchema.yml.
if ($options.General.OutputAPI) {
    Update-IniValue -Section 'General' -Key 'OutputAPI' -Value $options.General.OutputAPI -FilePath "$InstallDirectory\REDIST_CONFIG.conf" -UpdateOrAdd
}

$Return = 0
