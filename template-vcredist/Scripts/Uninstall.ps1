# Deliberately does nothing.
#
# The Visual C++ runtime is a shared, machine-wide component. Other games in the
# library, applications LANCommander did not install, and parts of Windows itself
# all link against it. Running vc_redist.exe /uninstall because one game was
# removed would break every one of them, and there is no way from here to know
# whether anything else still needs it.
#
# Leaving a runtime installed is the correct behaviour for a system redistributable
# and matches what every other installer on Windows does. Do not "fix" this.

$Return = 0
