# Attribution and licensing

This repository contains two separately licensed things. Keeping them distinct
matters, because only one of them is ours to license.

## What we authored

The packaging scripts, workflows, option schema, curation overlay and
documentation in this repository are copyright (c) 2026 LANCommander and are
released under the MIT License, in `LICENSE`.

## What we redistribute

The published `.LCX` package contains UPSTREAM_INSTALLER_FILENAMES, which we did
not author and do not license. Those files remain under their own terms:

| | |
|---|---|
| Project | REDIST_NAME |
| Homepage | https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist |
| Copyright | (c) Microsoft Corporation |
| License | UPSTREAM_LICENSE_TITLE |

The full terms are in `UPSTREAM-LICENSE.txt`, extracted verbatim from the document
Microsoft publishes at UPSTREAM_LICENSE_URL. `source.ps1` also copies them into the
payload as `LICENSE.txt`, so they reach the machine the runtime is installed on
rather than only living here.

### Why this payload is distributed the way it is

Read this before relying on the package. It does not describe a grant, because
there is not one.

<!--
  Quote the actual prohibition from the version you are packaging, verbatim. Do
  not copy the v14 wording blindly -- Microsoft has revised these terms and the
  older per-year packages carry different text. The v14 terms (EULA ID
  Cpp_v14_ENU.1033, 1 October 2025) say under Scope of License that you may not:

    share, publish, rent, lease, or otherwise distribute the software or any of
    its code; or

    provide the software as a stand-alone offering or combined with any of your
    applications for others to use, or transfer the software or these license
    terms to any third party.

  Whatever the version you are packaging says, the redistribution right commonly
  cited for the Visual C++ runtime is granted by the VISUAL STUDIO license terms,
  to licensed Visual Studio users shipping the runtime WITH THEIR OWN PROGRAM. It
  is not granted by the terms on the standalone download, and a redistributables
  library is not "your program". Say so here plainly rather than implying
  otherwise.

  If the version you are packaging turns out to carry a genuine Distributable Code
  grant that covers this use, say that instead -- and delete this whole section's
  hedging rather than leaving a warning that does not apply.
-->

UPSTREAM_REDISTRIBUTION_NOTE

We have bundled the installers anyway, as a deliberate decision taken with the
above in view, because a LAN party is the case where a client cannot be assumed to
have an internet connection at install time. The files are carried byte-for-byte
under their original filenames — nothing here repacks, extracts, patches or
renames them, and the license text travels with them — but that is a mitigation,
not a permission.

### If you would rather we did not

If you are at Microsoft, or anyone else with standing here, open an issue and we
will switch this package to `Source.Mode: none` without argument. The packaging
module already supports it and `LANCommander.Redistributables.dgVoodoo2` is a
working example: the `.LCX` then ships scripts only, and the runtime is fetched
from Microsoft rather than from us.

The registry detection, architecture option, exit-code handling and update
workflow in this repository are all ours and are unaffected by that change. Only
where the bytes come from would differ.
