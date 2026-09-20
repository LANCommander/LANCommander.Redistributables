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
| `UPSTREAM_VERSION` | `LastKnownVersion`, four-part file version of the x64 installer | `14.51.36247.0` |
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
| 2008 and 2005 | no such key — detect through the uninstall registry or the WinSxS assembly instead |

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
changes no code, but do not assume symmetry when deriving 2008 or 2005.

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
Visual Studio setup-engine bootstrapper wrapping `vc_red.msi` — and take
`/q /norestart`. Running the wrong one gives you a visible installer UI during a
silent install, or a usage dialog that never returns.

You can check this without installing anything. The pre-Burn bootstrapper's switch
table is a wide-string list inside the `SetupEngine.dll` it carries; for 2010 it
reads `CEIPconsent chainingpackage createlayout lcid log msioptions norestart
passive showfinalerror pipe promptrestart q repair serialdownload uninstall
parameterfolder NoSetupVersionCheck uninstallpatch quiet nosplashscreen ? h help`:

```powershell
7z x vcredist_x86.exe -otmp-eula
python -c "import re;d=open('tmp-eula/SetupEngine.dll','rb').read().decode('utf-16-le','ignore');print([m for m in re.findall(r'(?i)[a-z? ]{40,}', d) if 'norestart' in m.lower()])"
```

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
visible. Expect 2008 and 2005 to be at least as thin.

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
