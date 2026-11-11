# Third-Party Licenses

This project links runtime archives from roc-fuzz's release into the native
spec runner. Its fuzz targets are roc-fuzz apps that depend on that release
as their platform; nothing of roc-fuzz is copied into the repository.

## musl and Zig runtime archives

The native spec runner (`platform/main.roc` built for `x64musl`) links
`crt1.o` and `libc.a` (musl, MIT License) and `libzigc.a` and
`libcompiler_rt.a` (Zig, MIT License; compiler-rt under the Apache License
2.0 with LLVM Exceptions), taken from the roc-fuzz 0.6.0 release bundle
(https://github.com/lukewilliamboswell/roc-fuzz, MIT License) by
`scripts/src/PlatformTest.roc` into `platform/targets/x64musl/` and shipped
in this platform's release bundle. Their notices are those the roc-fuzz
release bundle carries.
