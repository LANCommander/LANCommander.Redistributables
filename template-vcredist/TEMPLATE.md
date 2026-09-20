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
| `UPSTREAM_INSTALL_ARGS` | PowerShell array literal of silent-install switches. Not applicable to an IExpress package -- see 2005, below | `'/install', '/quiet', '/norestart'` |
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
| 2005 | **nothing**, as 2008. Confirmed while building `VisualCppV8` on a machine carrying 8.0.61001 (x86) and 8.0.61000 (x64). Detect through the uninstall registry -- but the entries are NOT shaped like 2008's; see below |

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

**2005 needs the same approach and almost none of the same code.** Both versions
lack a `VC` key and both are read out of the uninstall registry, which is where the
similarity stops. Verified while building `VisualCppV8`:

- **The version is not in the display name.** A 2005 entry is named
  `Microsoft Visual C++ 2005 Redistributable`, full stop -- no architecture, no
  version. V9's rule that the name is authoritative and `DisplayVersion` the fallback
  is *exactly inverted* here, and inheriting its comment makes a false statement.
- **`DisplayVersion` is complete rather than truncated**, because a 2005
  `ProductVersion` is only three fields to begin with (`8.0.61001`). There is nothing
  to reconstruct.
- **Only the non-x86 architectures are labelled.** x64 is
  `... Redistributable (x64)`; x86 carries no suffix at all. Anchor the pattern at
  both ends or an x64 entry falls through and is counted as x86.
- Multiple entries per architecture is normal here too. The test machine carried
  three x86 entries at once: 8.0.56336 (SP1), 8.0.59193 (ATL update) and 8.0.61001
  (MFC update), each under its own product code.

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

2005 is three components on both sides and so needs neither treatment, but
`VisualCppV8` keeps V9's four-part helper anyway -- the missing-component-reads-as-0
rule is what stops a three-part value sorting below an identical four-part one, and
the two repositories are easier to read against each other sharing it.

**A version that differs per architecture.** 2005 is the only version in this family
where the architectures are not shipped at the same number: the x86 package is
`8.0.61001` and the x64 package is `8.0.61000`, permanently, and they install
identical runtime assemblies (`8.0.50727.6195`). Only the MSI `ProductVersion`
differs.

That matters because the manifest carries **one** version and `DetectInstall`
compares it against every selected architecture. Stamp the higher one and a fully
patched x64 machine reports as out of date forever, failing detection and
reinstalling on every launch. **Stamp the lowest version across architectures**, set
`Source.VersionFrom` to that architecture, and say in a comment that it is not the
arbitrary choice it is everywhere else. Replace the sibling repositories'
"architectures disagree, one link must be stale" warning with an assertion of the
expected per-architecture values, or it fires on every build.

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

**Install switches, and the 2005 package's are not switches at all.** v14 and the
2012/2013 packages are Burn bundles and take
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

**2005 takes neither pair, and cannot be installed in one call.** It predates the
Visual Studio setup engine as well as Burn: it is a bare IExpress container --
Microsoft's generic `wextract` stub -- holding exactly `vcredist.msi` and
`vcredis1.cab`, with no setup shell at all. Its embedded `RUNPROGRAM` is literally
`msiexec /i vcredist.msi`.

The IExpress way to install silently, and what Microsoft's own winget manifest for
the package uses, is to override that command:

```
vcredist_x86.exe /q:a /c:"msiexec /i vcredist.msi /quiet /norestart"
```

It installs correctly and it is still wrong, because **`wextract` discards the exit
code**. Verified against the real package: `/q:a /c:"cmd.exe /c exit 1234"` returns
`0`. Every failed install would be reported to the operator as a success, and `1638`
-- the routine "already present" answer for a family whose packages stack rather than
upgrade -- would be indistinguishable from a clean install. PowerShell's
`Start-Process` also mangles the embedded quotes in a `/c:` argument, which points
the same way for a smaller reason.

`VisualCppV8` therefore does it in two visible steps, which is the only way to see a
real exit code:

```powershell
vcredist_<arch>.exe /q /c /t:"<scratch>"          # extract only, installs nothing
msiexec /i "<scratch>credist.msi" /quiet /norestart
```

That is exactly what the container does unaided, with `/quiet /norestart` added.
Windows Installer's codes come through intact -- a deliberately missing package
returned `1619`. So for an IExpress version `UPSTREAM_INSTALL_ARGS` is not a
PowerShell array literal; there is no single call to put arguments on.

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

**2005 is worse than 2008 here, and in a way that is easy to miss.** Its PE version
is not a stale Visual C++ build; it is `6.00.2900.2180 (xpsp_sp2_rtm.040803-2158)` --
the file version of `wextract.exe`, the generic IExpress stub from Windows XP SP2 --
and it is *identical for both architectures* because it is literally the same stub.
Nothing about it looks like a Visual C++ version, so it is unlikely to survive
review; the danger is assuming the PE route works because it worked for V10-V14 and
never printing the value.

`VisualCppV8` reads `ProductVersion` out of `vcredist.msi`, and note the filename:
2008 and 2010 wrap a `vc_red.msi` and take the setup engine's `/x:` switch, which
2005 does not have. Unpack with wextract's own `/q /c /t:"<dir>"` instead. The same
three COM traps below apply unchanged, and so does the quoted-path one -- `/t:` is
just as silent about an unquoted path containing a space as `/x:` is.

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

**2005 has been checked and is the thinnest of all, in two separate ways.**

First, extraction. It is *not* like 2008 despite also predating Burn: **2005 ships no
licence file anywhere.** The IExpress cab holds only `vcredist.msi` and
`vcredis1.cab`, and the MSI has no `Control` table, no licence in `Binary`, and no
EULA among its files. The text lives in the **IExpress header**, as the `LICENSE`
field `wextract` renders in its acceptance dialog. It is CP1252 with CRLF endings,
4,985 bytes, running from `MICROSOFT SOFTWARE LICENSE TERMS` to the NUL before the
container's `RUNPROGRAM` string, and is byte-identical across both packages
(SHA-256 `A6A59B01EA2A0C5135111466BD459D39999ADEE68445520B60D9211A80D2E1A5`). Read it
straight out of the executable; there is nothing to unpack. Titled *MICROSOFT SOFTWARE
LICENSE TERMS -- MICROSOFT VISUAL C++ 2005 RUNTIME LIBRARIES*, no Distributable Code
section, same *Scope of License* ban, and -- like 2008 and 2010 -- **no EULAID**.

Second, the grant. `/visualstudio/releases/2005/2005-redistribution-vs` 404s as
expected, but so does **the Visual C++ 2005 deployment page itself**:
`previous-versions/visualstudio/visual-studio-2005/ms235299(v=vs.80)` is gone under
every plausible path. For 2008 and 2010 at least the signpost survives. For 2005 the
only surviving one is the *2008* page -- and its apparent year error, which
`VisualCppV9`'s `NOTICE.md` correctly records as a defect, is **correct for 2005**.
Quote it verbatim for both packages and let the two `NOTICE.md` files disagree about
what it means; do not edit either to match the other. Note that the paragraph is
half-corrected: it sends you to the 2008 media for `EULA.txt` and to
`Program Files\Microsoft Visual Studio 2005` for `Redist.txt`.

Check quotations against the live page rather than from memory. The current
`redistributing-visual-cpp-files` topic does *not* say "if you have a validly licensed
copy of Visual Studio, you may copy and distribute..." -- that is the 2012/2013 REDIST
list wording. It says distribution "is limited to licensed Visual Studio users and is
subject to Microsoft Software License Terms."

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

**2005 has been built, and the family is now complete.** That advice --
`DetectInstall.ps1` from `VisualCppV9`, the other three from `VisualCppV11` -- was
the right starting point and not much more than that. What it got wrong is recorded
above, and is worth reading before assuming any future derivation is a values-only
copy:

- `DetectInstall.ps1` kept V9's shape and inverted its central rule; the display name
  carries no version for 2005 and `DisplayVersion` is the only source.
- `Install.ps1` could not keep V11's shape at all, because there is no single call to
  put switches on.
- `source.ps1` kept V9's COM code and changed the unpack switch and the MSI filename.
- Only `Uninstall.ps1` and `Package.ps1` were close to values-only.

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
