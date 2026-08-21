# LANCommander.Redistributables

A library of **redistributables** for [LANCommander][lc] — the runtimes, libraries
and compatibility shims that games need in order to run.

Each redistributable lives in its own repository under this organisation, named
`LANCommander.Redistributables.{Name}`, tracks its upstream project, and publishes
an importable `.LCX` package as a GitHub release versioned to match upstream.

This repository is the hub: it holds the shared packaging module, the reusable CI
workflows every redistributable calls, the licence policy, and the skill that
scaffolds new ones. Each redistributable repository is registered here as a
submodule so this directory doubles as a workspace.

```
git clone --recurse-submodules https://github.com/LANCommander/LANCommander.Redistributables.git
```

[lc]: https://github.com/LANCommander/LANCommander

## Why

Redistributables used to be built by hand inside a running server: upload a ZIP,
hand-write the detect and install scripts, hand-author an option schema in the
admin UI. Nothing was versioned, nothing was shared between servers, and when an
upstream tool added a config option the schema quietly went stale.

Here, each redistributable is a repository with a scheduled job watching upstream.
When a new version appears, the option schema is regenerated from the tool's own
config file and a pull request is opened describing exactly which options changed.
Merging it publishes a new release.

## Using a redistributable

Download `redistributable.lcx` from any redistributable's latest release and
import it through your server's **Redistributables** page, or:

```
LANCommander.Launcher.CLI Import --Path redistributable.lcx --Type Redistributable
```

Because the identifiers in each package are stable across releases, re-importing a
newer version **updates** the existing entry instead of creating a duplicate.
Every package also ships a `Package` script, so a server can import once and then
keep itself updated from that repository's releases on its own.

## Adding a redistributable

Use the skill:

```
/new-redistributable dgVoodoo2
```

It researches the upstream project, audits its licence, scaffolds the repository,
writes the scripts and the option curation, creates the GitHub repository, and
verifies the first release end to end. See
[`.claude/skills/new-redistributable/SKILL.md`](.claude/skills/new-redistributable/SKILL.md).

## How a redistributable repository is laid out

| File | Purpose |
|---|---|
| `redistributable.yml` | Identity, payload source, config paths, stable script GUIDs |
| `source.ps1` | Resolves and downloads the upstream release |
| `Schema.Overlay.yml` | Hand-written curation: names, descriptions, choices, grouping |
| `OptionSchema.yml` | Generated from the upstream config, then curated. Never hand-edited |
| `Scripts/*.ps1` | Up to eight scripts, from `DetectInstall` through `RunWrapper` |
| `LICENSES/` | Upstream attribution and licence text |

`template/` is the skeleton these are created from.

## How option schemas stay current

The problem this library exists to solve is schema rot: upstream adds a config
option and the schema silently stops describing reality.

The parsers are generic over the **format**, never over the redistributable. An INI
parser enumerates whatever keys an INI file contains, so a new upstream option
appears in the schema on the next scheduled run with no code change anywhere. Two
declarative escape hatches keep unusual conventions out of code as well:
`ChoiceCommentPattern` harvests valid values from the comments above each key —
which is how tools like dgVoodoo2 document their options — and `Parser: custom`
hands off to a repository-local script for formats nothing else handles.

Everything a parser cannot infer lives in `Schema.Overlay.yml`, keyed by option
path. The generated half is disposable and rebuilt wholesale; the overlay is
purely additive. There is no three-way merge, so curation cannot be lost and
nothing ever conflicts. An option upstream adds that the overlay does not mention
still ships — it just ships uncurated, and the pull request lists it so someone
can describe it.

`OptionSchema.yml` is treated like a lockfile: the build regenerates it and fails
if the committed copy differs, so the schema in the repository always matches the
schema in the published package.

## The module

`module/LANCommander.Redistributables` is a PowerShell module. It is what CI runs,
and what you can run locally to reproduce a build exactly.

| Command | |
|---|---|
| `Invoke-RedistributableBuild` | The whole build: resolve, regenerate, pack, validate |
| `Resolve-RedistributablePayload` | Obtains the payload and version for any source mode |
| `Update-OptionSchemaFile` | Rebuilds `OptionSchema.yml` from config plus overlay |
| `ConvertTo-OptionSchema` | Parses config files into a schema |
| `Merge-SchemaOverlay` | Applies curation and reports what changed |
| `New-LcxPackage` | Builds the `.LCX` |
| `Test-LcxPackage` | Validates a package, `-Strict` against the real SDK types |
| `Test-OptionSchema` | Validates a schema against the SDK model and authoring rules |
| `Test-RedistributableLicense` | Decides whether a payload may be redistributed |
| `Resolve-UpstreamVersion` | GitHub-release, HTML-scrape and static resolvers |

Build a redistributable locally:

```powershell
Import-Module ./module/LANCommander.Redistributables
Invoke-RedistributableBuild -RepositoryPath ../LANCommander.Redistributables.dgVoodoo2 -Strict
```

### Validation

`Test-LcxPackage -Strict` compiles the actual model sources from `LANCommander.SDK`
and round-trips the package through them — the real `ManifestHelper` deserialiser
configuration, the real `OptionSchema` type, the real `GetFlattenedOptions` and
`GetDefaultAsString`. It is the only way to be certain a server will accept a
package rather than merely believing it will.

The sources are compiled rather than consumed from the published NuGet package,
because `LANCommander.SDK` on nuget.org is not restorable — it depends on
`LANCommander.Steam`, which was never published. Compiling the handful of model
files against YamlDotNet alone is cheaper anyway, and validates against what is on
the SDK's `main` branch today rather than a pinned package that may have drifted.

Point `LANCOMMANDER_SDK_PATH` at a local `LANCommander.SDK` directory to run it
offline; otherwise the sources are fetched from GitHub.

## The `.LCX` format

An `.LCX` is a plain ZIP:

```
Manifest.yml        redistributable metadata, with the option schema embedded
Archives/{guid}     an inner ZIP of the payload
Scripts/{guid}      one entry per PowerShell script
```

Two details matter and are easy to get wrong. The manifest entry must be named
exactly `Manifest.yml` — the format documentation says `manifest.yaml`, which the
importer does not accept. And the manifest is duck-typed on import: the
`Redistributable` branch is chosen only when `Name` is populated and `Title` is
absent.

## Licensing

The module, workflows, templates and documentation here are MIT licensed.

Each redistributable repository is also MIT for what we authored, but the payload
it redistributes is not ours and stays under its own terms — recorded in that
repository's `LICENSES/NOTICE.md`, with the upstream licence packed inside the
payload so it travels with the binaries.

Before any payload is published, `Test-RedistributableLicense` checks it against
[`policy/licenses.yml`](policy/licenses.yml). Where redistribution is not
permitted, the redistributable is built with no archive at all and its Install
script fetches from the vendor on the client instead — nothing is republished and
the redistributable still works.

If you hold copyright in something packaged here and would rather it were not
redistributed, open an issue and we will switch that package to client-side
download.

## Contributing

```powershell
Install-Module powershell-yaml, Pester -Scope CurrentUser
Invoke-Pester -Path ./tests
Invoke-ScriptAnalyzer -Path ./module -Recurse -Severity Error, Warning
```

Both run in CI on Linux and Windows, since redistributable payloads are frequently
Windows-only while builds may run on either.
