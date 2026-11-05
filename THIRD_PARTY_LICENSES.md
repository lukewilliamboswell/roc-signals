# Third-Party Licenses

This project adapts the roc-fuzz platform for its native test platform.

## roc-fuzz

Files: `platform/Arbitrary.roc`, `platform/Binary.roc`, `platform/Fuzz.roc`,
`platform/Target.roc` and `platform/test.roc` (adapted), and the release
inputs `platform/test-targets/*` fetched by `scripts/build_platform_test.roc`.

The test platform is the roc-fuzz 0.5.0 platform
(https://github.com/lukewilliamboswell/roc-fuzz), licensed under the MIT
License. See [`platform/LICENSE-roc-fuzz`](platform/LICENSE-roc-fuzz) for its
full text. Its release bundle carries the notices of the LLVM libFuzzer,
libc++, libc++abi, libunwind and compiler-rt, musl and Zig runtime inputs it
links.
