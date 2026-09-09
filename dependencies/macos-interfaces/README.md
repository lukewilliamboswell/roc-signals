# Generated macOS linker interfaces

`scripts/build_macos_stubs.py` writes minimal TBD YAML files for interoperability
between the compiled GUI host and macOS. It reads
[`interfaces.json`](interfaces.json), the reviewed catalog of symbols selected
for the compiled GUI host. Each symbol record links its interface source; each
library record identifies its install path and supporting references.

The generator reads the catalog and compiled host archives. It writes symbol
names, library paths, and the target architecture, together with a manifest
binding the outputs to the exact archive, catalog, and generator hashes. It
reads no Apple SDK headers, TBDs, or framework binaries. The GUI build and
platform bundler both use this generator.

Symbol names reach the host archives through GPUI and community-maintained FFI
bindings. Those upstream declarations can themselves originate in Apple headers.
The catalog retains the exact names needed for binary linkage as interoperability
facts; the generator does not reproduce the declarations, comments, or
implementation code from those headers.

The output uses Apple's TAPI text-based stub format, with the `!tapi-tbd` YAML
tag and `tbd-version: 4`. The format is openly implemented by
[LLVM's TextAPI reader and writer](https://www.llvm.org/docs/doxygen/TextStub_8cpp_source.html).
Our generator writes the format's target, install-name, and symbol fields directly
from the catalog.

Apple's publicly available developer documentation supplies most interface
references. The catalog also identifies open-source declarations used for runtime ABI symbols and GPUI's
additional framework imports. [`PROVENANCE.md`](PROVENANCE.md) accompanies the
generated files.

Source references establish where an interface is declared; they do not imply
that every selected symbol is a supported public API. In particular, GPUI's
`CGSMainConnectionID` and `CGSSetWindowBackgroundBlurRadius` declarations are
private API dependencies. Their compatibility remains an upstream host concern.

The final application link occurs during `roc build` or the compilation step of
`roc run`. The generated TBDs supply linking metadata; macOS supplies the actual
implementations when the executable runs.

## Archive source inventory

[sources.md](sources.md) provides one row for every symbol in the inspected Rust
host archive's external-reference inventory. [sources.json](sources.json) retains
the archive and inventory hashes, verified URLs, precise C identifiers,
documented module names, retrieval timestamps, and response hashes. This broader
inventory includes unused archive members; `interfaces.json` is the selected
catalog consumed by the generator.

## Reading the ledger

- `documented_api`: an Apple API page's precise C identifier matches the symbol
  after removing the Mach-O leading underscore. The documentation's module name
  is recorded without assuming it is the runtime library's install name.
- `documented_manpage`: Apple's archived manual page names the exact function in
  its synopsis. A mention in related documentation alone does not qualify.
- `project_callback`: a Signals callback supplied outside the Rust archive.
- `unresolved`: this collection did not establish an exact reference. This does
  not prove documentation cannot exist elsewhere. Checked candidate URLs and
  retrieval errors remain visible in the JSON.

The inventory is conservative: it includes references from archive members that
may not survive final linking. It is neither a list of exclusively public APIs
nor the final application's import table. It also does not capture Objective-C
class names looked up dynamically instead of referenced as linker symbols.
The selected catalog records library paths separately. Final linking and native
execution validate the generated interfaces against the selected host archives.

## Maintain the catalog

Use the Rust toolchain that built the host so its LLVM reader understands any
bundled bitcode. From the repository root:

```sh
rustup component add llvm-tools-preview
TOOLCHAINS=Metal cargo build --locked -p signals-gpui-host --release -j 2
python3 scripts/audit_macos_archive.py target/release/libsignals_gpui_host.a --output /tmp/rust-host-imports.json
python3 scripts/build_macos_stubs.py \
  --archives platform-gui/targets/arm64mac \
  --output /tmp/macos-interfaces
python3 -m unittest scripts/test_macos_archive_audit.py scripts/test_macos_stubs.py
```

The committed records were assembled using automated documentation retrieval
and source review. Generation is offline: it reads the committed catalog and
compiled archives, with no documentation downloads. Catalog updates require
reviewing the cited interface declarations and library ownership. For interfaces
outside the developer documentation, record the exact open-source declaration,
revision, and library evidence, as the existing runtime and GPUI records do.

The Rust host uses community-maintained FFI crates and GPUI's framework
declarations. The separate archive audit inspects compiled imports; the interface
generator reads source records and hashes the archives. Building the upstream
host has its own native toolchain requirements.

Regenerate and review the ledger when adopting different host archive bytes.
For a released platform, also inventory the matching engine and validate final
links with the supported Roc compiler. Archive hashes, rather than a platform
version label alone, identify the inputs actually inspected.

## Bundle admission

Mac interfaces are host-owned generated outputs. Local and `--no-build` macOS
bundling requires native Apple Silicon: the bundler links all maintained examples
with the pinned Roc compiler and executes their semantic specs before creating
an archive. A changed host is revalidated even when the catalog is unchanged.
The bundled `validation.json` identifies the compiler and successful example
counts and binds the interface manifest, including host, catalog, generator,
and output hashes. Cross-platform aggregation of a future signed Mac host will
need a separately verified matching validation receipt; it is not currently
accepted by this native admission path.

Mac CI builds the optimized host with Rust 1.95.0, performs this admission, then
serves the resulting archive over HTTP and builds all six examples with a fresh
Roc package cache. The HTTP check executes their native semantic specs too.
This evidence covers generated interfaces; it does not remove the separate Mac
host notice eligibility and publication gates.
