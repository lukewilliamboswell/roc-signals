# Third-Party Licenses

The native spec runner links runtime archives built and selected by the Zig
release pinned in `Blueprint.roc`. Three examples depend on Plume and load
Plotly in the page; the fuzz targets and the repository's scripts depend on
packages the compiler fetches, none of them copied into the repository. One Roc
utility is derived from basic-webserver. The documentation site serves font
files that are kept in it.

## musl and Zig runtime archives

The native spec runner (`platform/main.roc` built for `x64musl`) links
`rcrt1.o` and `libc.a` (musl, MIT License), and `libzigc.a` and
`libcompiler_rt.a` from Zig's runtime sources. `scripts/src/PlatformTest.roc`
builds a static PIE probe with the pinned Zig, copies the exact link inputs
selected by Zig into `platform/targets/x64musl/`, and ships those inputs in the
platform release bundle. They are not taken from a roc-fuzz release. The source
notices accompany the Zig distribution, including its `LICENSE` (MIT License)
and `lib/libc/musl/COPYRIGHT`.

The bundle also ships the spec runner's host for the other systems, each a
static library the pinned Zig builds from `platform/host/spec.zig` with
`-fcompiler-rt` (`PlatformTest.spec_hosts`): `targets/arm64mac/libhost.a`
and `targets/x64mac/libhost.a` (members `spec_zcu.o` and `compiler_rt.o`)
and `targets/x64win/host.lib` (`spec_zcu.obj` and `compiler_rt.obj`).
`compiler_rt` is Zig's compiler runtime, under Zig's `LICENSE` (MIT
License); some of its routines are ported from musl, as their source files
say, under musl's MIT License (`lib/libc/musl/COPYRIGHT`). The rest of each
library is this repository's code. The macOS hosts link no C library of
their own: the Roc linker supplies the system's libSystem when an app is
built. `targets/x64win/kernel32.lib` is an import library that `zig
dlltool` makes from this repository's `platform/host/kernel32.def`; it
holds only the names of the kernel32.dll functions the host imports, and
the Windows host links no C runtime. `targets/wasm32/host.wasm` is the object
`zig build-obj` makes from `platform/host/host.zig` for `wasm32-freestanding`,
with no C library.

## URL utility

`platform/Url.roc` derives from [basic-webserver](https://github.com/roc-lang/basic-webserver),
Copyright © 2023 Richard Feldman and subsequent Roc authors, under the
Universal Permissive License (UPL), Version 1.0 in that repository's `LICENSE`.
Its parsing tests retain the source note for cases drawn from web-platform-tests.

## IBM Plex fonts

The documentation site serves IBM Plex Sans and IBM Plex Mono (Copyright ©
2017 IBM Corp. with Reserved Font Name "Plex", SIL Open Font License 1.1)
from `www/static/fonts/`: the Latin subsets of the weights the site uses, as
packaged by Fontsource 5.3.0 (`@fontsource/ibm-plex-sans`,
`@fontsource/ibm-plex-mono`). The license is `www/static/fonts/LICENSE.txt`.
Nothing outside the site uses them.

## Example dependencies

The Status Page, Log Explorer and Million-Row Explorer examples
(`examples/{status-page,log-explorer,million-row-explorer}/main.roc`), and so
the examples archive and the documentation site that serve them, build their
charts with [Plume 0.6.0](https://github.com/lukewilliamboswell/plume/releases/tag/0.6.0),
pinned by bundle URL. Copyright © 2025 Luke Boswell and subsequent authors
(<https://github.com/lukewilliamboswell/plume/graphs/contributors>); Universal
Permissive License (UPL), Version 1.0. The compiler fetches it; its source is
not copied into this repository.

Those three example pages load [plotly.js 4.2.0](https://github.com/plotly/plotly.js)
from `https://cdn.plot.ly/plotly-4.2.0.min.js`, pinned with a subresource
integrity hash in `www/data/examples.toml`. Copyright (c) 2016-2024 Plotly
Technologies Inc.; MIT License. The browser fetches it from the CDN; it is not
copied into this repository, the examples archive or the site.

## Fuzz and tooling dependencies

These are fetched by the compiler when the fuzz targets or the scripts under
`scripts/` are built, and are not part of the platform bundle, the examples
archive or the site:

- [roc-fuzz 0.6.2](https://github.com/lukewilliamboswell/roc-fuzz/releases/tag/0.6.2),
  the platform of every fuzz target. Copyright (c) 2023 Brendan Hansknecht,
  Copyright (c) 2026 Luke Boswell; MIT License.
- [basic-cli 0.28.1](https://github.com/roc-lang/basic-cli/releases/tag/0.28.1),
  the scripts' platform. Copyright © 2022 Richard Feldman and subsequent
  basic-cli authors; UPL Version 1.0.
- [roc-lang/http 1.0.0](https://github.com/roc-lang/http/releases/tag/1.0.0),
  used by the scripts. Copyright © 2025 Richard Feldman and subsequent Roc
  authors; UPL Version 1.0.
- [roc-blueprint 0.13.0](https://github.com/lukewilliamboswell/roc-blueprint/releases/tag/0.13.0),
  which evaluates `Blueprint.roc`. Copyright © 2026 Luke Boswell and
  subsequent authors; UPL Version 1.0.

## Internal Roc dependencies

[roc-parser 6.0.0-rc.3](https://github.com/lukewilliamboswell/roc-parser/releases/tag/6.0.0-rc.3)
is pinned by package URL in the platform and tooling. Copyright © 2023 Luke Boswell and subsequent authors; Universal
Permissive License (UPL), Version 1.0. Its LICENSE accompanies that package.

Protocol consumer metadata and worker payloads are encoded with
[roc-cbor 0.6.3](https://github.com/lukewilliamboswell/roc-cbor/releases/tag/0.6.3),
pinned by its content-addressed bundle URL in both platform roots and the
`wire` fuzz target. Copyright
© 2026 Heorhii Bulakh and subsequent roc-cbor authors
(<https://github.com/Karakatiza666/roc-cbor/graphs/contributors>); Universal
Permissive License (UPL), Version 1.0. The compiler fetches this dependency;
its source is not copied into this repository. The package files retain the
copyright notice and UPL reference; the complete license is in the upstream
repository's `LICENSE`.

The native keyboard oracle uses roc-lang/unicode 4.3.3, pinned by bundle URL
in both platform roots. Copyright © 2019 Richard Feldman and subsequent Roc
authors; UPL Version 1.0. Its Unicode 17 data is covered by the Unicode License
V3 reproduced below. The browser uses its own Unicode category implementation;
this repository contains no copied keyboard classification ranges.

UNICODE LICENSE V3

COPYRIGHT AND PERMISSION NOTICE

Copyright © 1991-2026 Unicode, Inc.

NOTICE TO USER: Carefully read the following legal agreement. BY
DOWNLOADING, INSTALLING, COPYING OR OTHERWISE USING DATA FILES, AND/OR
SOFTWARE, YOU UNEQUIVOCALLY ACCEPT, AND AGREE TO BE BOUND BY, ALL OF THE
TERMS AND CONDITIONS OF THIS AGREEMENT. IF YOU DO NOT AGREE, DO NOT
DOWNLOAD, INSTALL, COPY, DISTRIBUTE OR USE THE DATA FILES OR SOFTWARE.

Permission is hereby granted, free of charge, to any person obtaining a
copy of data files and any associated documentation (the "Data Files") or
software and any associated documentation (the "Software") to deal in the
Data Files or Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, and/or sell
copies of the Data Files or Software, and to permit persons to whom the
Data Files or Software are furnished to do so, provided that either (a)
this copyright and permission notice appear with all copies of the Data
Files or Software, or (b) this copyright and permission notice appear in
associated Documentation.

THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
THIRD PARTY RIGHTS.

IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS INCLUDED IN THIS NOTICE
BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR CONSEQUENTIAL DAMAGES,
OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS,
WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THE DATA
FILES OR SOFTWARE.

Except as contained in this notice, the name of a copyright holder shall
not be used in advertising or otherwise to promote the sale, use or other
dealings in these Data Files or Software without prior written
authorization of the copyright holder.
