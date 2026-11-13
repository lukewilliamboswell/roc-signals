# Third-Party Licenses

This project links runtime archives from roc-fuzz's release into the native
spec runner. Its fuzz targets are roc-fuzz apps that depend on that release
as their platform; nothing of roc-fuzz is copied into the repository. The
documentation site serves font files that are kept in it.

## musl and Zig runtime archives

The native spec runner (`platform/main.roc` built for `x64musl`) links
`crt1.o` and `libc.a` (musl, MIT License) and `libzigc.a` and
`libcompiler_rt.a` (Zig, MIT License; compiler-rt under the Apache License
2.0 with LLVM Exceptions), taken from the roc-fuzz 0.6.0 release bundle
(https://github.com/lukewilliamboswell/roc-fuzz, MIT License) by
`scripts/src/PlatformTest.roc` into `platform/targets/x64musl/` and shipped
in this platform's release bundle. Their notices are those the roc-fuzz
release bundle carries.

## IBM Plex fonts

The documentation site serves IBM Plex Sans and IBM Plex Mono (Copyright ©
2017 IBM Corp. with Reserved Font Name "Plex", SIL Open Font License 1.1)
from `www/static/fonts/`: the Latin subsets of the weights the site uses, as
packaged by Fontsource 5.3.0 (`@fontsource/ibm-plex-sans`,
`@fontsource/ibm-plex-mono`). The license is `www/static/fonts/LICENSE.txt`.
Nothing outside the site uses them.

## Unicode keyboard classification data

The keyboard matchers in `platform/runtime.mjs` and `platform/Dom.roc`
contain punctuation and symbol ranges derived from Unicode 18.0.0
[`UnicodeData.txt`](https://www.unicode.org/Public/18.0.0/ucd/UnicodeData.txt),
SHA-256 `0736451de439ae7baf1425136617da495e09ee5afbe6e394374db7009ea08950`.
The notice below also accompanies those tables in distributed source.

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
