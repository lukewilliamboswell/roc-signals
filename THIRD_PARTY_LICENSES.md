# Third-Party Licenses

This project vendors the roc-fuzz platform for its fuzz platform, and links
runtime archives from roc-fuzz's release into the native spec runner.

## roc-fuzz

Files: `platform/Arbitrary.roc`, `platform/Binary.roc`, `platform/Fuzz.roc`,
`platform/Target.roc` and `platform/fuzz.roc` (adapted: it also exposes the
roc-signals modules the fuzz targets drive), and the release inputs fetched
by `scripts/src/PlatformTest.roc` into `platform/fuzz-targets/*`.

These are the roc-fuzz 0.5.0 platform
(https://github.com/lukewilliamboswell/roc-fuzz), licensed under the MIT
License. See [`platform/LICENSE-roc-fuzz`](platform/LICENSE-roc-fuzz) for its
full text. Its release bundle carries the notices of the LLVM libFuzzer,
libc++, libc++abi, libunwind and compiler-rt, musl and Zig runtime inputs it
links.

The copy is vendored until roc-fuzz offers a mode a platform can embed
instead: https://github.com/lukewilliamboswell/roc-fuzz/issues/98.

## musl and Zig runtime archives

The native spec runner (`platform/main.roc` built for `x64musl`) links
`crt1.o` and `libc.a` (musl, MIT License) and `libzigc.a` and
`libcompiler_rt.a` (Zig, MIT License; compiler-rt under the Apache License
2.0 with LLVM Exceptions), taken from the same roc-fuzz 0.5.0 release bundle
into `platform/targets/x64musl/` and shipped in this platform's release
bundle. Their notices are those the roc-fuzz release bundle carries.
