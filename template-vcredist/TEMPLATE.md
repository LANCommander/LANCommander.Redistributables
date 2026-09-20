# Deriving a Visual C++ Redistributable repository

This scaffold is not a guess. It is `LANCommander.Redistributables.VisualCppV14`
with the version-specific values lifted out, so everything here has been built,
strict-validated and run against a real registry at least once.

`LANCommander.Redistributables.VisualCppV12` (2013) was derived from it and is the
worked example for everything below -- including the two places where following
this file blindly would have been wrong.

Delete this file from the repository you create — it documents the scaffold, not
the package.

## 1. Copy it

```powershell
$name = 'VisualCpp2013'   # the repository suffix
Copy-Item ./template-vcredist "../LANCommander.Redistributables.$name" -Recurse
Remove-Item "../LANCommander.Redistributables.$name/TEMPLATE.md"
```

## 2. Generate the GUIDs

```powershell
1..5 | ForEach-Object { [guid]::NewGuid().ToString() }
```

Five: one for `Id` and one per script. **Generate them fresh.** Never copy them
from a sibling VC++ repository — `RedistributableImporter` matches on
`r.Id == record.Id || r.Name == record.Name`, so two packages sharing an Id would
overwrite each other on every server that imported both, and regenerating an Id
later makes each release import as a duplicate rather than an update.

## 3. Replace the placeholders

| Placeholder | What it is | v14 value, for reference |
|---|---|---|
| `REDIST_ID` | The redistributable GUID | — |
| `SCRIPT_ID_DETECTINSTALL` etc. | One GUID per script, four in total | — |
| `REDIST_NAME` | Manifest `Name`, what the admin UI shows and what `Get-RedistributableOptions -Name` matches | `Visual C++ v14 Redistributable (2015-2022)` |
| `REDIST_REPOSITORY` | `RepositoryName`, used for release asset filenames | `VisualCppV14` |
| `REDIST_DESCRIPTION` | One or two sentences. Name the DLLs that go missing — that is what people search for | `MSVCP140.dll`, `VCRUNTIME140.dll` |
| `UPSTREAM_DOWNLOAD_X86` / `_X64` | Download links from the Microsoft page | `https://aka.ms/vc14/vc_redist.x86.exe` |
| `UPSTREAM_VERSION` | `LastKnownVersion`, the four-part version of the x64 package. Read from the installer's PE resource for 2010 and later; for 2008 the shell's PE version is stale and it comes from the MSI instead — see below | `14.51.36247.0` |
| `UPSTREAM_RUNTIMES_SUBKEY` | Registry subkey under `HKLM\SOFTWARE`, **without** the architecture leaf | `Microsoft\VisualStudio\14.0\VC\Runtimes` |
| `UPSTREAM_INSTALL_ARGS` | PowerShell array literal of silent-install switches | `'/install', '/quiet', '/norestart'` |
| `UPSTREAM_INSTALL_ARGS_DISPLAY` | The same switches as prose, for the README | `/install /quiet /norestart` |
| `UPSTREAM_INSTALLER_FILENAMES` | For `NOTICE.md` | `vc_redist.x86.exe` and `vc_redist.x64.exe` |
| `UPSTREAM_LICENSE_TITLE` / `UPSTREAM_LICENSE_URL` | The EULA this version carries | see below |
| `UPSTREAM_REDISTRIBUTION_NOTE` | The verbatim prohibition from *this version's* terms | see `NOTICE.md`'s comment block |

The installers are also referenced **by filename** in `Scripts/Install.ps1`
(`.\vc_redist.$arch.exe`) and in `Scripts/Package.ps1`'s layout check. Versions
before 2017 ship as `vcredist_x86.exe` / `vcredist_x64.exe` instead — if so, change
the name that `source.ps1` writes rather than the scripts, so every repository in
this family keeps the same payload layout.

## 4. The per-version facts you must actually check

Do not assume. These differ, and getting one wrong produces a package that appears
to work and silently never installs anything.

**Registry key.** The shape is not stable across versions:

| Version | Subkey under `HKLM\SOFTWARE[\WOW6432Node]` |
|---|---|
| 2015–2022 (v14) | `Microsoft\VisualStudio\14.0\VC\Runtimes\{x86,x64}` |
| 2013 | `Microsoft\VisualStudio\12.0\VC\Runtimes\{x86,x64}` |
| 2012 | `Microsoft\VisualStudio\11.0\VC\Runtimes\{x86,x64}` |
| 2010 | `Microsoft\VisualStudio\10.0\VC\VCRedist\{x86,x64}` — note `VCRedist`, not `Runtimes` |
| 2008 | **nothing.** `...\VisualStudio\9.0\VC` is absent from both registry views — confirmed while building `VisualCppV9` on a machine carrying 9.0.30729.6161 for both architectures. Detect through the uninstall registry; see below |
| 2005 | expect the same as 2008, but check |

The **value names** are stable further back than the key path is. 2010 carries the
same `Installed` DWORD and `Version` REG_SZ (`v10.0.40219.325`) the later versions
do, so `DetectInstall` needed nothing but the path swapped — verified while building
`VisualCppV10`. Do not trust the widely cited guidance here: the standard answer for
detecting 2010 (Aaron Stebner's MSDN post, and everything downstream of it)
describes an `Installed` DWORD plus `Major`/`Minor`/`Bld`/`Rbld` DWORDs and never
mentions `Version` at all. That is incomplete for the SP1 MFC Security Update build,
and following it would have you write version-composition arithmetic you do not
need. Read the key before believing any of it, including this table.

2010 does rename two of the DWORDs — `MajorVersion` and `MinorVersion`, where 11.0,
12.0 and 14.0 use `Major` and `Minor`. Nothing in the scripts reads them, so it
changes no code, but do not assume symmetry when deriving 2005.

**Detecting a version with no key at all: what 2008 needed.** `VisualCppV9` is the
worked example, and this is the only part of `DetectInstall.ps1` that cannot be
produced by swapping a path. Microsoft's documented answer for 9.0 — a fixed list of
MSI product codes passed to `MsiQueryProductState` — is unusable: the codes differ
per servicing build *and* per installer locale, as the comments on Aaron Stebner's
own article record. The uninstall registry is what works, read under both
`HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall` and its `WOW6432Node`
counterpart, matching entries named
`Microsoft Visual C++ 2008 Redistributable - {x86|x64} <version>`.

Three things make that harder than it looks, all verified:

- **The display name is authoritative for the version, not `DisplayVersion`.** The
  latter derives from MSI `ProductVersion`, which Windows Installer truncates to
  three fields — the SP1 entry reads `9.0.30729` where its name reads
  `9.0.30729.17`. Read the name and keep `DisplayVersion` as the fallback, not the
  other way round.
- **Several entries per architecture is the normal state.** 2010 and later
  major-upgrade; 2008 does not. RTM, SP1, the ATL update and the MFC update each
  keep their own uninstall entry, so take the newest per architecture rather than
  the first match. The test machine carried three x86 entries at once.
- **The architecture is in the display name**, which is what makes the match
  survive registry redirection — the x64 entries land natively and the x86 ones
  under `WOW6432Node`.

The WinSxS assembly probe this file used to offer as the alternative was considered
and rejected. `microsoft.vc90.crt` and its siblings are stamped per assembly, and
those stamps are not guaranteed to equal the package version the manifest carries,
so it risks reporting "older" forever. Matching on a display name has one weakness —
a localised installer writing a translated one — and the failure mode is benign:
nothing matches, detection reports "not installed", and `Install` puts the machine
right anyway.

**Comparing versions: three components is not always enough.** Every repository
before `VisualCppV9` reduces both sides to major.minor.build. 2008 cannot afford
that, because its entire servicing history lives in the revision field — SP1 is
`9.0.30729.17`, the ATL update `.4148`, the MFC update `.6161`. Collapsed to three,
an unpatched SP1 machine reports as satisfied and never receives MS11-025. `V9`
parses a fourth optional group and reads a missing component as `0`, which keeps the
original reason for normalising intact (a three-part `[version]` has `Revision` -1,
sorting below `.0`). Check where a version's servicing actually happens before
copying either helper.

Confirm on a machine that has the runtime installed:

```powershell
Get-ChildItem 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio' |
    ForEach-Object { Get-ChildItem (Join-Path $_.PSPath 'VC') -Recurse -ErrorAction SilentlyContinue } |
    Where-Object PSChildName -match '^(x86|x64|arm64)$' |
    ForEach-Object { $_.Name; (Get-ItemProperty $_.PSPath).Version }
```

Note which architectures appear under the native path and which only under
`WOW6432Node` — they are not symmetrical, and that is why `DetectInstall` probes
both. For v14 on a 64-bit host, `x64` exists natively but `x86` exists *only* under
`WOW6432Node`.

Do not generalise v14's layout to the older versions. On a 64-bit host **2010, 2012
and 2013 register both architectures under `WOW6432Node` and leave the native path
absent entirely** — verified on a machine carrying all three. Probing only the native
root, which looks like the obvious thing to do from v14's shape, would silently
never detect them. An empty native key is normal for these versions, not a fault,
and it is worth saying so in the README so nobody goes looking for a bug. v14 is the
exception, not the rule.

**ARM64 in the PE-header mapping.** `DetectInstall` and `Install` both map a
`0xAA64` ARM64 executable to the x64 runtime. The comment explaining why is
v14-specific: v14's x64 package genuinely contains ARM64 binaries. No older version
does, and Microsoft never shipped an ARM64 build of them at all — for those, x64 is
simply the closest thing that exists and ARM64 Windows runs it emulated. The
behaviour is right either way; copy it, but rewrite the reason or the comment
becomes a false statement about Microsoft's packaging.

**Install switches.** v14 and the 2012/2013 packages are Burn bundles and take
`/install /quiet /norestart`. The 2010 and earlier packages predate Burn — 2010 is a
Visual Studio setup-engine bootstrapper wrapping `vc_red.msi`, 2008 a plainer
self-extracting shell around the same file — and take `/q /norestart`. Confirmed for
2008 while building `VisualCppV9`; Microsoft's own guidance for it is "you only need
to use `/q`". Running the wrong one gives you a visible installer UI during a silent
install, or a usage dialog that never returns.

You can check this without installing anything. The pre-Burn bootstrapper's switch
table is a wide-string list inside the `SetupEngine.dll` it carries; for 2010 it
reads `CEIPconsent chainingpackage createlayout lcid log msioptions norestart
passive showfinalerror pipe promptrestart q repair serialdownload uninstall
parameterfolder NoSetupVersionCheck uninstallpatch quiet nosplashscreen ? h help`:

```powershell
7z x vcredist_x86.exe -otmp-eula
python -c "import re;d=open('tmp-eula/SetupEngine.dll','rb').read().decode('utf-16-le','ignore');print([m for m in re.findall(r'(?i)[a-z? ]{40,}', d) if 'norestart' in m.lower()])"
```

**Where the version actually lives.** Every repository up to `VisualCppV10` reads
the version from the PE resource of the downloaded installer, and `source.ps1` is
otherwise identical across all of them. **Do not assume that still holds.** For 2008
it does not: `vcredist_x86.exe` and `vcredist_x64.exe` are stamped `9.0.30729.5677`,
the file version of the self-extracting shell, which Microsoft left behind at the
ATL Security Update and never restamped. The package inside is `9.0.30729.6161` —
what the MSI declares, what a client records in its uninstall entry, what Microsoft's
winget manifests carry, and what the Download Center entry serves.

Nothing fails loudly if you take the shell's number. You get a package stamped with
a build that appears in no other source, and a `DetectInstall` comparing against a
version no machine will ever report. Cross-check the PE version against the
installed product's version before trusting it.

`VisualCppV9` resolves it from `vc_red.msi` instead, unpacked with the vendor's own
`/x:` switch — no 7-Zip, no third-party tooling, nothing installed. Three traps in
that route, all hit while building it:

- **`/x:` returns exit code 0 when it has extracted nothing.** A path containing a
  space silently produces no files unless the switch value is quoted
  (`'/x:"{0}"' -f $path`). Test for `vc_red.msi`, not for the exit code.
- **Hand COM a `[string]`, not what `Join-Path` returned.** `Join-Path` emits a
  `PSObject`-wrapped string, and marshalling that wrapper into
  `WindowsInstaller.Installer` fails with `DISP_E_TYPEMISMATCH` — an error that
  names nothing useful and sends you looking at the MSI. Cast it.
- **Do not test a COM object with `-not`.** It has no boolean conversion, so `-not`
  dispatches into the object and comes back with the same `DISP_E_TYPEMISMATCH`.
  Compare against `$null`.

This is a second, independent reason to pin `runs_on: windows-latest` — extraction
runs a Windows executable and the property read goes through COM — so say which
reason applies in the workflow comment rather than inheriting a sibling's.

**Side-by-side behaviour.** 2013 and earlier install alongside each other and
alongside v14 — a machine can legitimately carry five of these at once. That is
why each is its own redistributable rather than one package with a version option,
and why `Uninstall` is a no-op in all of them.

**Whether the download moves.** The v14 links are permalinks that always serve the
latest build, so its scheduled upstream check does real work. The older packages
are pinned to a fixed build and will never move; their check runs daily and always
reports no change. That is correct, not broken — leave the workflow in place rather
than deleting it, in case Microsoft reissues a security update.

**The download links themselves.** Check what an `aka.ms` short link actually
serves before trusting it. `https://aka.ms/highdpimfc2013x86` looks like the 2013
x86 link and is not one -- it redirects to Bing's unknown-short-link page, which
answers `200`. The real link is `https://aka.ms/highdpimfc2013x86enu`, with the
locale suffix. A wrong link here does not fail loudly; `source.ps1` downloads an
HTML page under a `.exe` name and the build dies much later on an unreadable PE
version.

**The license.** Fetch the terms for the version you are packaging rather than
copying `UPSTREAM-LICENSE.txt` from a sibling. Microsoft revises these, and the
differences are not cosmetic.

For v14 the document is a `.docx` behind <https://aka.ms/VCRedistLicense>; extract
its text rather than saving the rendered web page, which is JavaScript-only and
contains no license text at all.

For 2013 there is no published URL at all -- the EULA
(`EULAID: VS2013_RTM_VC.1_ENU`) ships only inside the bundle. Pull it out of the
installer:

```powershell
7z x vcredist_x64.exe -oux        # the UX container
# the Burn manifest, file "0", maps payload ids to source paths;
# look for FilePath="license.rtf" and take its SourcePath (u4 for 2013)
```

Expect the two to disagree. The 2013 standalone EULA has **no Distributable Code
section** and forbids publishing the software for others to copy, while the
Visual Studio 2013 REDIST list
(<https://learn.microsoft.com/en-us/visualstudio/releases/2013/2013-redistribution-vs>)
names `vcredist_x86.exe` and `vcredist_x64.exe` outright as distributable,
unmodified, with your program. Record both in `NOTICE.md` rather than picking the
convenient one.

**The public REDIST lists stop at 2012.** This was wrong here until `VisualCppV10`
was built, and it matters because it is the one thing that changes the shape of
`NOTICE.md` rather than just its values. `learn.microsoft.com` hosts
`/visualstudio/releases/<year>/<year>-redistribution-vs` for 2012 and 2013 and
nothing earlier -- every plausible slug for 2010 is a 404, under `/2010/` and under
its neighbours. Visual Studio 2010's documentation says why: the list is `Redist.txt`
in `..\Microsoft Visual Studio 10.0\` on a machine with VS 2010 installed, and the
terms are `Eula.txt` on the installation media
(<https://learn.microsoft.com/en-us/previous-versions/visualstudio/visual-studio-2010/ms235299(v=vs.100)>).
Neither is citable by URL.

So for 2010 and earlier you cannot open `NOTICE.md`'s grant section with a block
quote the way V11 and V12 do. Do not paper over that by quoting a list from memory or
by reusing a sibling's quotation with the year changed. `VisualCppV10` handles it by
saying outright that the evidence is thinner, citing what *is* public (the general
"licensed Visual Studio users" condition, and the 2010 docs naming
`VCRedist_x86.exe` as the intended deployment vehicle), and leaving the tension
visible.

2008 has been checked and is thinner still, in a way worth knowing before you go
looking. `/visualstudio/releases/2008/2008-redistribution-vs` is a 404 like 2010's,
and the Visual C++ 2008 deployment page that tells you where the list lives instead
— <https://learn.microsoft.com/en-us/previous-versions/visualstudio/visual-studio-2008/ms235299(v=vs.90)>
— **cites the wrong year**, pointing at "the Microsoft Software License Terms for
Visual Studio 2005" and at `Program Files\Microsoft Visual Studio 2005`, apparently
carried over from its 2005 predecessor and never corrected. That is not a
transcription slip to tidy up when you quote it; it is the state of the only public
signpost to the 2008 grant, and `VisualCppV9`'s `NOTICE.md` says so outright. Expect
2005 to be no better.

Extraction for 2008 is the easiest of the family, easier even than 2010's. It
predates Burn as 2010 does, but its EULAs are **plain UTF-16 text rather than RTF** —
one file per LCID at the root, English at `eula.1033.txt`, so no `RichTextBox`
round-trip is needed. Titled *MICROSOFT VISUAL C++ 2008 RUNTIME LIBRARIES (X86, IA64
AND X64), SERVICE PACK 1*, byte-identical across both packages, no Distributable Code
section, the same *Scope of License* ban on "publish the software for others to
copy", and — like 2010, unlike 2012 and 2013 — **no EULAID**. The installer's own
`/x:<dir> /q` gets you there without 7-Zip.

2012 has been checked and follows the same pattern: `EULAID:VS2012_RTM_VC.1_ENU`,
extracted from `license.rtf` at `u4` exactly as 2013 is, with no Distributable
Code section, against a REDIST list at
<https://learn.microsoft.com/en-us/visualstudio/releases/2012/2012-redistribution-vs>
that names the same three installers. Read each REDIST list rather than assuming it
matches its neighbour -- the 2012 Visual C++ section omits 2013's "with your
program" qualifier, which makes it marginally *stronger* for our purposes, and the
Express editions carry a narrower list that does not cover the `.exe` installers at
all. Both of those belong in `NOTICE.md`.

2010 has been checked too, and the extraction is *easier* than 2012/2013 because it
predates Burn. There is no UX container and no manifest indirection -- `7z x` on the
installer gives you the setup-engine layout directly, with one localised EULA per
LCID folder:

```powershell
7z x vcredist_x86.exe -otmp-eula     # -> Setup.exe, SetupEngine.dll, vc_red.msi,
                                     #    vc_red.cab, msp_kb2565063.msp, 1033/, ...
# the English terms are tmp-eula/1033/eula.rtf
```

It is an `.rtf`, so convert rather than copying the markup -- a
`System.Windows.Forms.RichTextBox` round-trip renders it the way V11 and V12 store
theirs, including resolving the `HYPERLINK` field in the export-restrictions clause
down to its display text. Titled *MICROSOFT VISUAL C++ 2010 RUNTIME LIBRARIES WITH
SERVICE PACK 1*, byte-identical across the x86 and x64 packages, no Distributable
Code section, and the same *Scope of License* ban on "publish the software for others
to copy". It carries **no EULAID**, unlike 2012 and 2013 -- its title is the only
identifier it has, so do not invent one for the `NOTICE.md` table.

**Filenames and the license interact.** Where a REDIST list grants the installers
*by name*, keep those names rather than normalising them. `VisualCppV12` does
exactly that: it ships `vcredist_x86.exe` / `vcredist_x64.exe` and adjusts
`source.ps1`, `Install.ps1` and `Package.ps1` to match, accepting the divergence
from the rest of the family as the smaller cost.

Where there is no list to match -- 2010 and earlier -- keep the upstream names
anyway. The positive argument is gone, but renaming a file you are relying on a
redistribution grant to carry is a change with no upside, and it keeps the payload
layout consistent with V11 and V12. Since the template ships v14's
`vc_redist.<arch>.exe` spelling, deriving a pre-2017 version is easiest by copying
those four script files from `VisualCppV11` rather than from here.

For **2005**, take `DetectInstall.ps1` from `VisualCppV9` and the other three from
`VisualCppV11`. V11's detection reads a registry key that 2005, like 2008, does not
write; V9's already carries the uninstall-registry scan and the four-part version
comparison, and should need little beyond the year in its display-name pattern —
after you have confirmed what 2005 actually writes there, which is the whole point
of this section.

## 5. Build and validate

```powershell
Import-Module ../module/LANCommander.Redistributables -Force
./source.ps1 -CheckOnly                       # the version, and nothing else, on stdout
./source.ps1 -OutputPath ./tmp-payload        # installers + LICENSE.txt, nothing else
$env:LANCOMMANDER_SDK_PATH = '<path>/LANCommander.SDK'
Invoke-RedistributableBuild -RepositoryPath . -UpdateSchema -Strict
```

Then confirm the payload is byte-identical to what Microsoft served. "Unmodified"
is a license obligation, not a nicety:

```powershell
Get-FileHash ./tmp-payload/vc_redist.x64.exe
```

Finally run the hub suite — `tests/PackageScripts.Tests.ps1` globs
`LANCommander.Redistributables.*/Scripts/Package.ps1`, so the new repository is
covered as soon as it exists:

```powershell
Invoke-Pester ../tests
```
