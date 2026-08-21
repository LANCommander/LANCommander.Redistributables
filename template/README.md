# LANCommander.Redistributables.REDIST_NAME

Automatically built LANCommander redistributable import package (`.LCX`) for
[UPSTREAM_NAME](UPSTREAM_URL).

REDIST_DESCRIPTION

## Install it

Download `redistributable.lcx` from the [latest release][latest] and import it
through your LANCommander server's **Redistributables** page, or from the CLI:

```
LANCommander.Launcher.CLI Import --Path redistributable.lcx --Type Redistributable
```

Then assign it to the games that need it, either from the game's
**Redistributables** field or from this redistributable's **Games** field.

Re-importing a newer release **updates** the existing entry rather than creating a
second one, because the identifiers in `redistributable.yml` are stable across
releases.

Alternatively, import once and let it update itself: the package ships a
`Package` script, which a LANCommander server runs on a schedule to pull new
versions straight from this repository's releases.

[latest]: https://github.com/LANCommander/LANCommander.Redistributables.REDIST_NAME/releases/latest

## What is in the package

| Path | |
|---|---|
| `Manifest.yml` | Redistributable metadata, including the embedded option schema |
| `Archives/{guid}` | A ZIP of the payload, extracted into the game's `.lancommander` metadata directory |
| `Scripts/{guid}` | One entry per PowerShell script |

## Options

REDIST_OPTIONS_TABLE

Administrators can override any of these per game from the game's
**Redistributables** page. Values resolve as schema default, then per-game value,
then per-action override.

## How this repository works

| File | Purpose |
|---|---|
| `redistributable.yml` | Identity, payload source, config paths, stable script GUIDs |
| `source.ps1` | Resolves and downloads the upstream release |
| `Schema.Overlay.yml` | Hand-written curation: names, descriptions, choices, grouping |
| `OptionSchema.yml` | Generated from the upstream config, then curated. Do not edit by hand |
| `Scripts/*.ps1` | Client-side and server-side scripts |
| `LICENSES/` | Upstream attribution and license text |

`OptionSchema.yml` is generated, and the build fails if the committed copy does
not match what the upstream config produces. To regenerate it locally:

```powershell
Import-Module <path-to>/LANCommander.Redistributables/module/LANCommander.Redistributables
Invoke-RedistributableBuild -RepositoryPath . -UpdateSchema
```

Edit `Schema.Overlay.yml` to change how an option is presented; never edit
`OptionSchema.yml`, since the next rebuild overwrites it.

### Staying current

A scheduled workflow checks UPSTREAM_NAME for new versions. When one appears it
re-parses the config, regenerates the option schema through the overlay, and opens
a pull request listing exactly which options were added, removed or had their
defaults change. Merging that pull request publishes the release.

Options that upstream adds are picked up automatically and ship uncurated; the
pull request calls them out so a description can be written for them.

## Licensing

The scripts and workflows here are MIT licensed. The redistributed payload is not
ours — see [`LICENSES/NOTICE.md`](LICENSES/NOTICE.md) for attribution and terms.
