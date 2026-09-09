# Windows link inputs

The independently released ADVAPI32 library contains all named exports from the
pinned Zig/MinGW-w64 definition, with the original MinGW license inventory. It
contains import mappings, not the Windows implementation. Windows provides the
DLL at runtime. Extending this package requires a reviewed complete definition
for each required DLL, rather than generating a subset from one host build.

The Rust static library also contains import records from its dependencies.
An archive's DLL inventory is an upper bound on declared imports; archive
selection and dead code elimination determine which reach the final executable.
Do not use that inventory alone to declare the runtime DLL requirements or to
select a new dependency package. Ordinary object members can also contain real
Rust, C or assembly implementation code and need their own provenance and notices.

Inspect an extracted host archive without executing or modifying it:

```sh
python3 scripts/audit_windows_archive.py /path/to/signals_gpui_host.lib > host-imports.json
python3 scripts/audit_windows_archive.py /path/to/engine.lib > engine-imports.json
```

The report includes the input hash, import record counts per DLL, original COFF
linker directives and unclassified member counts. It is diagnostic evidence, not
an import-only validator, a license assessment or proof of final link closure.
Inspect the final executable's import table separately on Windows after building
all maintained examples and running their native specs.

## CRT and final application linking

Roc `nightly-2026-09-04-c125b82` calls native Windows SDK/MSVC discovery for
`x64win` before linking, and requires CRT, MSVC and kernel32 library directories.
It then adds the `kernel32`, `ntdll`, `msvcrt` and `shell32` default libraries;
`msvcprt` is additionally selected when Roc was built with Tracy support.
Supplying more explicit import libraries in the platform header does not remove
that discovery step. See the pinned compiler's
[`src/cli/linker.zig`](https://github.com/roc-lang/roc/blob/c125b82/src/cli/linker.zig).

Roc already has an `x64mingw` path that uses explicit platform runtime inputs and
suppresses default libraries. Using it would be a target/runtime migration:
MSVC-built Rust and native dependencies must be checked against the selected
MinGW CRT, including startup, allocation, TLS, panic/unwind and native library
requirements. The host archive can request additional libraries through
`.drectve` sections even when the platform header does not name them. Suppressing
those directives is not evidence that their requirements are satisfied.

Zig can compile CRT sources, but CRT startup and support archives contain
implementation code, unlike DLL import stubs. Treat such files as separate
source-built dependency inputs with their own source identity, license inventory,
reproducibility checks and native execution tests. Do not replace Microsoft's
`msvcrt.lib` with an identically named import library merely because both can be
associated with a CRT: startup objects and the intended CRT ABI also matter.

The acceptance test for an SDK-independent Windows bundle is a final `roc build`
on a machine where SDK/MSVC discovery is unavailable, followed by native example
specs and GUI execution. A successful producer cross-link or a Windows CI run
with an installed SDK does not establish that property. No Windows SDK libraries
should be copied into the independent dependency package to make that test pass.
