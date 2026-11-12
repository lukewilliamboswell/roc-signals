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
