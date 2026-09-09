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

`xkbcommon.json` pins the upstream keyboard-library source commit and archive.
Its separate builder uses Zig with the checked-in Meson configuration to build
both the core and X11 libraries. Meson's install step removes build-directory
runtime search paths before packaging. A self-contained keyboard-map probe runs
against the extracted candidate; publication requires identical archives from two
clean builds and includes the upstream license. XCB build inputs come from the
authenticated Ubuntu snapshot, and XCB runtime libraries and keyboard layout data
remain operating-system inputs. The root consumer lock pins the independent
release. Linux GUI builds verify it before compilation; bundles verify it again
in fresh staging and exclude both mutable development copies. Ordinary host,
engine, API, and example changes reuse these released link inputs.

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

## glibc startup and link-input producer

`glibc.json` pins the complete Zig distribution used to generate the Linux GUI
startup object, libc/libm link stubs, and `libc_nonshared.a`. These are produced
in a container with fixed build paths and private compiler caches. The container
has no network access during compilation and receives no platform target tree
or system development libraries. Its pinned Ubuntu image and authenticated
package snapshot supply Python and the operating system used by the native
probe; Zig supplies the compiler, source, and headers.

The candidate probe links explicitly against the extracted inputs and checks C
constructors and destructors, `atexit`, allocation, mathematics, and threads.
Publication requires a second clean build to produce an identical archive.
The archive includes glibc notices and LGPL terms, the bundled glibc source and
C headers, and the scripts and recipe needed to reproduce it. Glibc source
licenses and startup-file linking exceptions apply; these files are not covered
solely by Zig's MIT license. Files under `sources/glibc/` are preserved as
ordinary, hash-verified payloads, not automatically unpacked or executed by the
consumer.

The source payload keeps complete glibc sources and the five header directories
reported by the pinned compiler for `x86_64-linux-gnu.2.39`: Clang's `lib/include`
and libc's `x86-linux-gnu`, `generic-glibc`, `x86-linux-any`, and `any-linux-any`.
The producer checks that search list before building. It excludes unrelated
musl, Windows and Darwin header trees instead of redistributing their sources
without their component notices.

Original header notices remain in the source payload. Full LLVM license terms
and exceptions come from the pinned distribution's `lib/libunwind/LICENSE.TXT`.
Linux UAPI license texts and the syscall exception are retained byte-for-byte
from the Linux source revision pinned in the recipe, alongside the original
SPDX declarations and copyright notices in each header. This includes GPL 1/2,
LGPL 2/2.1, MIT and BSD-3-Clause terms. For dual-licensed UAPI declarations, the
GPL alternative with its syscall exception is selected; separately applicable
MIT and BSD notices remain applicable. These header licenses are distinct from
the generated glibc link inputs' own licenses.

The stubs retain system SONAMEs: the operating system supplies the actual glibc
implementation at runtime. This producer does not include the GCC unwinder or
adopt a consumer lock. Production consumption requires a separately reviewed
release lock and platform-header update.

## LLVM unwinder producer

`unwind.json` pins Zig's source distribution and compiler for an independently
released Linux x86-64 `libunwind.a`. This replaces a dependency on ambient GCC
unwinder packaging once a release is adopted. It is a static implementation,
whereas the glibc producer's shared-library files are runtime link stubs.

The producer builds in an offline container with private caches and fixed paths.
It extracts the candidate and links an exception/destructor probe with explicit
startup and C++ support inputs and no implicit standard libraries. CI also links
Rust's panic recovery and destructor probe against the exact extracted archive.
The private C++ support libraries are never published. A second clean container
must produce the same archive bytes before the main-only workflow can attest
and publish them.

The archive retains the complete original libunwind source tree, its full
`LICENSE.TXT` including LLVM exceptions and legacy notices, Zig's license, and
standalone reproduction inputs. The consumer lock and platform header are
reviewed separately; this producer alone does not change existing bundles.

## Coverage and remaining boundaries

The artifact contract above applies to dependencies selected in the root
`dependencies.lock.json`. It is not a provenance claim for every native GUI
input or for historical platform releases.

| Input | Build and consumption boundary | Remaining gap |
| --- | --- | --- |
| musl libc and startup objects | Independent source build, native candidate tests, reproducibility check, immutable release, and verified consumer lock | Dependency updates still require a deliberate release and lock review. |
| Windows ADVAPI32 import library | Independent generation from pinned MinGW definitions, native candidate test, and verified release consumption | This describes the import library, not the Windows system DLL supplied by the operating system. |
| Linux GUI FreeType | Independent Zig build from pinned source, native candidate tests, reproducibility checks, and verified release consumption | Supporting build libraries still come from the authenticated builder snapshot; the operating system supplies runtime font libraries. |
| Linux GUI xkbcommon and xkbcommon-X11 | Independent Zig/Meson source build, native candidate test, reproducibility check, and verified release consumption | XCB runtime libraries and keyboard layout data remain operating-system inputs; applications resolve the system SONAMEs at runtime. |
| Other Linux GUI shared libraries and startup objects | `build_gui.py` copies the build machine's installed inputs | No independent pinned producer, signed dependency receipt, or verified bundle admission yet; recorded local paths do not establish provenance. |
| macOS framework and system link stubs | `build_gui.py` copies the selected Xcode SDK's stubs and records SDK identifiers | No independently versioned, verified SDK artifact yet. SDK origin and redistribution rights must be established; proprietary SDK stubs cannot be described as an open-source build. |
| Rust crates embedded in the GUI host | Cargo uses the reviewed lockfile and CI caches compiled dependencies; cross-crate release LTO is disabled | The cache is not a separately released dependency artifact. Generic Rust code can be instantiated in the host, so separating it into a reusable binary requires an explicit ABI and compatibility policy. |
| Prebuilt GUI host target directories | The bundler accepts host archives supplied as target directories | Those host bytes are not yet bound to an expected source commit and verified producer identity at admission. A signed dependency library does not establish the host's provenance. |

Host-owned engine objects, GUI Rust host archives, web `libhost.a`, and the Windows application
resource remain platform build outputs. Changing their source should not change
external dependency identities. A dependency recipe or toolchain change must
produce a new dependency release before consumers adopt it.

An attestation identifies who produced particular bytes and from which workflow
and source revision. The pinned upstream inputs, recipe review, candidate tests,
and immutable release are separate controls; an attestation alone does not prove
that an ambient system library was built from reviewed source.

## Producer CI selection

Ordinary platform, host, engine, example, consumer-lock and documentation changes
reuse released dependencies; they do not select a dependency producer workflow.
Each producer's pull-request filter names its recipe, probe, producer and tests,
local imported helpers, and workflow. FreeType additionally names its CMake
configuration; xkbcommon names its Meson configuration and compiler adapter;
glibc names its retained license source.

The container producers build with their own recipe directory as Docker context.
Their Dockerfiles currently fetch pinned remote inputs and do not copy local
context files. Exact Dockerfile filters therefore cover the image build inputs;
the separately mounted toolchain/probe files are listed individually. When adding
a local `COPY` or `ADD`, include the newly consumed context files in that
producer's filter as part of the change.

Changes to shared archive, admission, publication or admission-test code
intentionally select all producers. Even musl's admission tests import the shared
archive writer. This validates the affected release path; publication remains a
separate manual dispatch on main. The lightweight CI selection job checks each
workflow's executed Python scripts and transitive local imports against its path
list, along with recipe/probe isolation and ordinary consumer-change examples:

```sh
python3 -m unittest discover -s scripts -p test_dependency_workflow_filters.py
```
