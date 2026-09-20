# LANCommander.Redistributables.REDIST_REPOSITORY

Automatically built LANCommander redistributable import package (`.LCX`) for the
[REDIST_NAME](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist).

REDIST_DESCRIPTION

Both architectures are bundled. 64-bit Windows needs the x86 runtime too, because
most games of this era are 32-bit — see [Options](#options).

> **Read [`LICENSES/NOTICE.md`](LICENSES/NOTICE.md) before relying on this
> package.** Microsoft's terms for the standalone redistributable do not grant
> redistribution rights, and bundling the installers here is a deliberate decision
> taken with that in view rather than a permission we hold.

## Install it

Download the `.lcx` asset from the [latest release][latest] and import it
through your LANCommander server's **Redistributables** page, or from the CLI:

```
LANCommander.Launcher.CLI Import --Path LANCommander.Redistributables.REDIST_REPOSITORY-v<version>.lcx --Type Redistributable
```

Then assign it to the games that need it, either from the game's
**Redistributables** field or from this redistributable's **Games** field.

Re-importing a newer release **updates** the existing entry rather than creating a
second one, because the identifiers in `redistributable.yml` are stable across
releases.

Alternatively, import once and let it update itself: the package ships a
`Package` script, which a LANCommander server runs on a schedule to pull new
versions straight from this repository's releases.

[latest]: https://github.com/LANCommander/LANCommander.Redistributables.REDIST_REPOSITORY/releases/latest

## What is in the package

| Path | |
|---|---|
| `Manifest.yml` | Redistributable metadata, including the embedded option schema |
| `Archives/{guid}` | A ZIP of the installers and `LICENSE.txt`, extracted into the game's `.lancommander` metadata directory |
| `Scripts/{guid}` | One entry per PowerShell script |

## Options

| Option | Type | Default | Description |
|---|---|---|---|
| `Architecture` | choice — `both`, `auto`, `x86`, `x64` | `both` | Which runtime to install. Leave this at **Both** unless you have a reason not to: 64-bit Windows needs the x86 runtime as well, because most games of this era are 32-bit, and a 64-bit machine with only the x64 runtime still fails to launch them. **Match the game executable** reads the executable's PE header and installs only the runtime it needs — but note that a .NET AnyCPU executable reports as 32-bit there even though it runs 64-bit, so set those to **Both**. |

Administrators can override this per game from the game's **Redistributables**
page. Values resolve as schema default, then per-game value, then per-action
override.

## How this repository works

| File | Purpose |
|---|---|
| `redistributable.yml` | Identity, download links, stable script GUIDs |
| `source.ps1` | Downloads both installers and reads the version off the PE resource |
| `Schema.Overlay.yml` | The whole option schema, written by hand — there is no config file to parse |
| `OptionSchema.yml` | Built from the overlay. Do not edit by hand |
| `Scripts/*.ps1` | Client-side and server-side scripts |
| `LICENSES/` | Upstream attribution and license text |

`OptionSchema.yml` is generated, and the build fails if the committed copy does
not match what the overlay produces. To regenerate it locally:

```powershell
Import-Module <path-to>/LANCommander.Redistributables/module/LANCommander.Redistributables
Invoke-RedistributableBuild -RepositoryPath . -UpdateSchema
```

### How detection and install work

`DetectInstall` reads `Version` and `Installed` from
`HKLM\SOFTWARE\UPSTREAM_RUNTIMES_SUBKEY\{x86,x64}` — and the `WOW6432Node` mirror,
since which of the two is visible depends on the bitness of the host PowerShell.
It reports "installed" only when every selected architecture is present *and* at
least as new as the build this package carries, because Microsoft's installer
refuses to downgrade and returns an error when a newer runtime is already present.

`Install` runs each installer with `UPSTREAM_INSTALL_ARGS_DISPLAY` and treats
`1638` (a newer version is already installed, also seen as `0x80070666`), `3010`
and `1641` (reboot pending or initiated) as success alongside `0`.

`Uninstall` deliberately does nothing. The runtime is shared machine-wide and
other software depends on it.

## Licensing

The scripts and workflows here are MIT licensed. The redistributed payload is not
ours — see [`LICENSES/NOTICE.md`](LICENSES/NOTICE.md) for attribution, the full
terms, and the reasoning behind how this package is distributed.
