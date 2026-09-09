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

Every archive contains `dependency.json`, its exact target files, and license
notices. The manifest records upstream identity, producer/recipe hashes, compiler
configuration, and every payload file's size and digest. Tar metadata and paths
are normalized. Release CI compares independent build directories and executes a
test linked against the extracted libc and startup object on each architecture.

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
