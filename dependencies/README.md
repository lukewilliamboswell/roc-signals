# Platform dependency artifacts

Dependency recipes are reviewed source. Compiled dependency archives are release
assets, identified by a consumer lock containing their SHA-256, byte length,
producer source commit, source ref, and signing workflow. A dependency release
version is independent of the platform and compiler release versions.

`musl.json` pins the upstream source revision and Zig toolchain used to produce
Linux musl startup and libc inputs. The pinned revision is a post-1.2.6 snapshot;
the revision, rather than the upstream VERSION file alone, identifies its fixes.
The producer builds baseline x86-64 and AArch64 code. It includes no Signals host
or application code, and does not consume existing platform target directories.

`windows-imports.json` pins the MinGW definition and license bytes distributed
with Zig. Its producer generates `advapi32.lib` without building the Signals
engine or Rust host. It also excludes `signals.res`, which describes our own
application manifest and belongs to the host build. A Windows-native probe links
against only the candidate ADVAPI32 import library and Zig's KERNEL32 imports,
then calls an imported function before publication. The Windows dependency
workflow has a separate release tag and signing identity from musl.

`freetype.json` pins the upstream FreeType source archive and explicitly requires
zlib, bzip2, PNG, HarfBuzz, and Brotli support. Its Linux producer uses the Ubuntu
container digest and authenticated package snapshot in `linux/Dockerfile` for
build tools and headers. A checksum-pinned Zig 0.16.0 distribution compiles the C
source for baseline x86-64 with a glibc 2.39 target. Compilation then runs without
network access in a clean container. The artifact records the complete installed package versions, builder
image identity, recipe and probe hashes, source identity, and license notices.
Two clean builds must produce identical archives, and each extracted candidate
must parse and render the expected bitmap glyph before it can be published.

The FreeType shared object is a link input. Its SONAME remains
`libfreetype.so.6`, which the operating system resolves at application runtime;
publishing this artifact does not freeze the runtime font stack. Producer support
alone does not adopt a library: consumption requires a separately reviewed lock
update and integration tests. Other Linux GUI link inputs remain outside this
producer's scope.

Every archive contains `dependency.json`, its exact target files, and license
notices. The manifest records upstream identity, producer/recipe hashes, compiler
configuration, and every payload file's size and digest. Tar metadata and paths
are normalized. Release CI compares independent build directories and executes a
test linked against the extracted inputs on each supported architecture.

The consumer verifies signed GitHub build provenance against the locked repository,
workflow, main ref, and exact source commit before extraction. It performs these
checks on cache hits too. A cache miss downloads the same locked release; it never
silently compiles a substitute. Archive links, duplicate paths, undeclared files,
foreign targets, hash mismatches, and incomplete downloads are errors. Extraction
and materialization publish only complete directories, leaving a failed destination
absent so the caller can retry safely.

Normal host changes do not change the dependency recipe or lock. Update a dependency
through its own tested release and a reviewed lock update. Compiler updates must
not change dependency identities implicitly. Keep the previous releases available
for consumers pinned to them; a security replacement receives a new identity.

For commands and release operation, see the
[contributor guide](../www/content/docs/contributing.md#dependency-artifact-releases).

## Coverage and remaining boundaries

The artifact contract above applies to dependencies selected in the root
`dependencies.lock.json`. It is not a provenance claim for every native GUI
input or for historical platform releases.

| Input | Build and consumption boundary | Remaining gap |
| --- | --- | --- |
| musl libc and startup objects | Independent source build, native candidate tests, reproducibility check, immutable release, and verified consumer lock | Dependency updates still require a deliberate release and lock review. |
| Windows ADVAPI32 import library | Independent generation from pinned MinGW definitions, native candidate test, and verified release consumption | This describes the import library, not the Windows system DLL supplied by the operating system. |
| Linux GUI shared libraries and startup objects | `build_gui.py` copies the build machine's installed inputs | No independent pinned producer, signed dependency receipt, or verified bundle admission yet; recorded local paths do not establish provenance. |
| macOS framework and system link stubs | `build_gui.py` copies the selected Xcode SDK's stubs and records SDK identifiers | No independently versioned, verified SDK artifact yet. SDK origin and redistribution rights must be established; proprietary SDK stubs cannot be described as an open-source build. |
| Rust crates embedded in the GUI host | Cargo uses the reviewed lockfile and CI caches compiled dependencies; cross-crate release LTO is disabled | The cache is not a separately released dependency artifact. Generic Rust code can be instantiated in the host, so separating it into a reusable binary requires an explicit ABI and compatibility policy. |
| Prebuilt GUI host target directories | The bundler accepts host archives supplied as target directories | Those host bytes are not yet bound to an expected source commit and verified producer identity at admission. A signed dependency library does not establish the host's provenance. |

Host-owned engine objects, `libhost.a`/`host.lib`, and the Windows application
resource remain platform build outputs. Changing their source should not change
external dependency identities. A dependency recipe or toolchain change must
produce a new dependency release before consumers adopt it.

An attestation identifies who produced particular bytes and from which workflow
and source revision. The pinned upstream inputs, recipe review, candidate tests,
and immutable release are separate controls; an attestation alone does not prove
that an ambient system library was built from reviewed source.
