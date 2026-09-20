---
name: new-redistributable
description: Scaffold and publish a new LANCommander redistributable repository, from upstream research and license audit through to a verified GitHub release
user_invocable: true
---

# New LANCommander Redistributable

You are creating a new repository under the `LANCommander` organisation that
packages a third-party runtime, library or compatibility shim as an importable
LANCommander `.LCX`, and keeps it in sync with its upstream project.

Invoked as `/new-redistributable <name>`, for example `/new-redistributable dgVoodoo2`.

## Before you start

Work from the hub repository (`LANCommander/LANCommander.Redistributables`,
normally cloned to `D:\Repositories\LANCommander.Redistributables`). Import the
shared module first — every step below uses it:

```powershell
Import-Module ./module/LANCommander.Redistributables -Force
```

Two skills in the LANCommander repository are the authoritative content specs.
Read them when you reach the relevant step rather than reproducing their rules
here:

- `.claude/skills/generate-redist-options/SKILL.md` — option schema authoring
- `.claude/skills/generate-redist-install-script/SKILL.md` — script types, available
  variables, working directories, `$Return` conventions, cmdlets

## Step 1 — Gather

Establish, asking the user via AskUserQuestion for anything you cannot determine:

- **Name** — the repository suffix. Match how upstream capitalises the product
  (`dgVoodoo2`, not `DgVoodoo2`).
- **Upstream project URL**.
- **What it is** — a runtime installer (DirectX, VC++, OpenAL) or a compatibility
  shim that wraps game execution (WINE, umu-launcher, dgVoodoo2). This decides
  whether there is a `CommandTemplate` and which scripts apply.
- **Which games need it**, for the README.

## Step 2 — Research upstream

Use WebFetch on the project page and, where relevant, the GitHub releases API.
Establish:

- How the latest version is discoverable — a GitHub releases feed, or a version
  string on a download page that a regex can extract.
- The download URL, and whether it is stable across versions.
- What the archive contains, and which subset actually belongs on a client. Most
  upstream archives carry documentation and samples that should not be packaged.
- Whether it ships a config file, and in what format.
- How to detect an existing installation — a registry key, or a file in System32.

Record the exact version string format. Do not normalise it: `2.86` and
`June 2010` are both real, and the manifest carries the raw string.

## Step 3 — Audit the licence (do this before creating anything)

This is a hard gate. Publishing a redistributable means republishing someone
else's binaries, so the terms have to be checked first.

Download the upstream archive to a temporary directory and run:

```powershell
$verdict = Test-RedistributableLicense -PayloadPath ./tmp-payload
```

Then act on the verdict:

| `Redistribute` | What to do |
|---|---|
| `yes` | Proceed. Record the obligations in `LICENSES/NOTICE.md`. |
| `conditional` | **Stop.** Show the user the licence text and `$verdict.Evidence`, and ask whether to bundle the payload or fall back to client-side download. Do not decide this yourself. |
| `no` | Set `Source.Mode: none`. The package ships scripts only and the Install script downloads from the vendor on the client. Say so plainly in the README. |

`Source.Mode: none` is a genuine option, not a failure — `RedistributableClient.InstallAsync`
runs the Install script even when there are no archives.

Always write `LICENSES/UPSTREAM-LICENSE.txt` with the verbatim upstream licence and
fill in `LICENSES/NOTICE.md`. The repository's own `LICENSE` is MIT and covers only
what we authored; `NOTICE.md` is what makes that boundary explicit.

## Step 4 — Scaffold

Copy `template/` to `D:\Repositories\LANCommander.Redistributables\LANCommander.Redistributables.<Name>`
and replace every `REDIST_*` and `UPSTREAM_*` placeholder.

For a Visual C++ runtime, copy `template-vcredist/` instead and follow its
`TEMPLATE.md`. It is a working package with the version-specific values lifted out,
so it already carries the registry detection, exit-code handling and architecture
option described under [Runtime installers](#runtime-installers).

Generate the stable GUIDs — one for the redistributable, one per script:

```powershell
[guid]::NewGuid().ToString()
```

**These are generated once and never change.** `RedistributableImporter` matches on
`r.Id == record.Id || r.Name == record.Name`, so a regenerated GUID makes every
future release import as a brand new redistributable instead of updating the
existing one, and servers accumulate a duplicate per release. Say this in your
summary to the user so nobody "tidies" them later.

## Step 5 — Write `source.ps1`

Fill in the template against the real upstream. Use `Resolve-UpstreamVersion` where
one of its resolvers fits; write something bespoke where it does not. Verify it
works before going further:

```powershell
./source.ps1 -CheckOnly
./source.ps1 -OutputPath ./tmp-payload
```

Narrow the copy step to just the files a client needs.

## Step 6 — Write the scripts

Follow `generate-redist-install-script/SKILL.md`. Generate the widest applicable
set and delete the rest of the template's scripts along with their entries in
`redistributable.yml`.

| Script | Include it when |
|---|---|
| `DetectInstall` | Always. Fast — 10 second timeout, no network. |
| `Install` | Always. |
| `Uninstall` | Always. For a shared system runtime, a no-op returning 0 is the correct implementation — other games may still need it. |
| `Package` | Always. This is what lets a server that imported the package once keep itself updated from the repository's releases. |
| `BeforeStart` | The redistributable has options that must be written into a config file at launch. |
| `AfterStop` | `BeforeStart` changed something that must be restored. |
| `NameChange` | The tool stores the player alias somewhere. |
| `RunWrapper` | A shim needing more than a `CommandTemplate` — injection, bespoke environment. If a plain `wrapper {exe} {args}` suffices, use `CommandTemplate` instead and skip this. |

Set `Platforms` on any script that is OS-specific. Leaving it unset means "runs
everywhere", which `EnvironmentHelper.SupportsCurrentRuntime` short-circuits on.

Add `#Requires -RunAsAdministrator` where elevation is genuinely needed; it is
detected at packaging time and recorded on the manifest.

## Step 7 — Curate the option schema

Skip this entirely for a plain runtime installer — those have no options; delete
`Schema.Overlay.yml`.

Otherwise, **parse first, then curate**. Generate the raw schema so you are
curating real option paths rather than guessed ones:

```powershell
Update-OptionSchemaFile -RepositoryPath . -PayloadPath ./tmp-payload
```

Read the generated `OptionSchema.yml`, then write `Schema.Overlay.yml` following
`generate-redist-options/SKILL.md`. This is the step where you add what a parser
cannot infer:

- Real descriptions. If the config documents an option in a comment, the parser
  already captured it — improve on it rather than restating it.
- `choice` types with genuine `Choices`, from the upstream documentation.
- `DisplayName` wherever the raw key would puzzle an administrator.
- Sensible `Groups`. Settle these now: regrouping later changes an option's
  dot-path, and per-game values are stored keyed by that path.
- `CommandTemplate`, `GuestPlatforms` and `DisplayName` at the root, for shims only.
- `Exclude` for options that are debug-only or would break a client if changed.

If the config documents its valid values in comments, set `ChoiceCommentPattern` in
`redistributable.yml` instead of hand-writing every choice list — it harvests them
generically, and keeps working when upstream adds more.

Then rebuild and confirm it is clean:

```powershell
Update-OptionSchemaFile -RepositoryPath .
Test-OptionSchema -Path ./OptionSchema.yml
```

## Step 8 — Build and validate locally

Never push before this passes:

```powershell
Invoke-RedistributableBuild -RepositoryPath . -UpdateSchema -Strict
```

`-Strict` compiles the real SDK model sources and round-trips the package through
them, which is the only way to be sure the server will accept it. Set
`LANCOMMANDER_SDK_PATH` to a local `LANCommander.SDK` directory to keep it offline.

## Step 9 — Create or adopt the repository

Check first — some of these repositories already exist as empty placeholders:

```powershell
gh repo view LANCommander/LANCommander.Redistributables.<Name>
```

If it exists, push to it. If not:

```powershell
gh repo create LANCommander/LANCommander.Redistributables.<Name> --public --license mit `
  --description "Automatically built LANCommander redistributable import package (.LCX) for <Name>"
```

Keep that description wording — it is the convention across the org.

Commit, push, then register it in the hub as a submodule:

```powershell
git -C <hub> submodule add https://github.com/LANCommander/LANCommander.Redistributables.<Name>.git LANCommander.Redistributables.<Name>
```

Confirm **Settings → Actions → General → Allow GitHub Actions to create and
approve pull requests** is enabled. Without it the scheduled upstream check fails
at the point where it opens its pull request. Tell the user if you cannot verify it.

## Step 10 — Write the README

Fill in the template. Generate the options table from the built `OptionSchema.yml`
rather than by hand. State the upstream licence and, if the payload is not
bundled, why.

## Step 11 — Verify end to end

```powershell
gh run watch --repo LANCommander/LANCommander.Redistributables.<Name>
gh release view --repo LANCommander/LANCommander.Redistributables.<Name>
```

Download the published `.lcx` and validate the artefact that actually shipped, not
just the one you built locally. The release carries a single versioned asset named
`LANCommander.Redistributables.<Name>-v<tag>.lcx` -- there is no fixed-name copy, so
let `gh` resolve it:

```powershell
gh release download --repo LANCommander/LANCommander.Redistributables.<Name> --pattern '*.lcx' --dir ./tmp-release
Test-LcxPackage -Path (Get-ChildItem ./tmp-release/*.lcx).FullName -Strict
```

Report to the user: the repository URL, the release, the resolved upstream version,
which scripts shipped, how many options the schema exposes, the licence verdict and
whether the payload is bundled or fetched on the client.

## Runtime installers

A runtime installer — DirectX, Visual C++, .NET, PhysX — behaves differently enough
from a shim that the defaults elsewhere in this skill need adjusting. What follows
was established building `LANCommander.Redistributables.VisualCppV14`.

**Detect on version, not presence.** These installers refuse to downgrade: run one
over a newer build and it returns an error rather than doing nothing. So
`DetectInstall` has to answer "is a runtime at least this new installed", which
means comparing against `$RedistributableManifest.Version` — injected for
`DetectInstall`, `Install` and `Uninstall` alike, see
`ScriptClient.Redistributables.cs`.

Normalise before comparing. Vendors write their own format into the registry:
Microsoft stores `v14.51.36247.00` while the manifest carries the installer's file
version `14.51.36247.0`. Those are the same build, but `[version]'14.51.36247'` has
Revision `-1`, which sorts *below* `.0` — compare them raw and detection never
succeeds. Reduce both sides to major.minor.build.

**Probe both registry views.** A 32-bit component's key lives under
`WOW6432Node`, a 64-bit component's under the native path, and which one your
PowerShell can see depends on its own bitness. For the Visual C++ v14 runtime on a
64-bit host, `...\VC\Runtimes\x64` exists natively while `...\x86` exists *only*
under `WOW6432Node`. Check both roots for every architecture.

**Treat "already newer" and "reboot pending" as success.** For a Microsoft
installer that is `1638` (sometimes surfacing as the HRESULT `0x80070666`), `3010`
and `1641`, alongside `0`. Returning any of those as a failure makes an already
satisfied machine look broken to the operator.

**`Uninstall` is a no-op returning 0.** A system runtime is shared with software
LANCommander did not install and cannot enumerate. Removing it because one game was
uninstalled breaks the rest. Say so in the script, or someone will "fix" it.

**No `CommandTemplate` and no `GuestPlatforms`.** Those belong to shims that wrap a
launch command. A runtime installer has neither.

**It may still have options** — the skill says to delete `Schema.Overlay.yml` for a
plain runtime installer, and that holds when there is genuinely nothing to choose.
But an option that is *ours* rather than upstream's is legitimate: which
architecture to install is the obvious one. There is no config file to parse, so
author it from the overlay, exactly as `UmuLauncher` does. `both` is the right
default for architecture — 64-bit Windows needs the 32-bit runtime too, because
most older games are 32-bit.

**Detecting architecture from the game.** Read the PE machine field of the primary
action's executable: `0x8664` x64, `0xAA64` ARM64, `0x014C` x86. There is a worked
copy in `LANCommander.Redistributables.OpenALSoft/Scripts/Install.ps1`. Fall back to
installing everything when the executable cannot be read, and note that a .NET
AnyCPU executable reports `0x014C` even though it runs 64-bit.

**Versions with no version.** Microsoft publishes no version number or release feed
for the v14 redistributable; their documented answer is to read **File version** off
the downloaded installer. `[System.Diagnostics.FileVersionInfo]::GetVersionInfo()`
parses the PE resource directly rather than asking the OS, so it works on the Linux
build runner too. If a vendor ever needs Windows tooling to resolve a version, both
caller workflows take a `runs_on` input.

## Things that will bite you

- **Regenerating GUIDs on an existing redistributable.** Every release then imports
  as a duplicate. The GUIDs in `redistributable.yml` are permanent.
- **Rewriting the upstream version.** The manifest carries it verbatim; only the git
  tag is sanitised. Do not turn `June 2010` into `2010.06`.
- **Hand-editing `OptionSchema.yml`.** It is generated. Edit `Schema.Overlay.yml`.
- **Naming the manifest `manifest.yaml`.** The LCX documentation says this and it is
  wrong — the importer requires exactly `Manifest.yml`. The packer handles it; just
  do not "fix" it.
- **Assuming `0`/`1` means boolean.** The parser leaves those as `int` deliberately.
  Force `Type: bool` from the overlay when you know better.
- **Unquoted booleans in the overlay.** `Default: false` resolves to .NET's `"False"`,
  not `"false"`. Validation catches it; quote them.
