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
The root `dependencies.lock.json` pins the released musl archives that the web
platform's `x64musl` and `arm64musl` targets link against.

The web platform's prebuilt native and Wasm hosts are published the same way by
`.github/workflows/web-hosts.yml` and pinned by `web-host.lock.json`. Those host
archives are platform build outputs rather than external dependencies: each
records a committed-source fingerprint and payload hashes, and the producer runs
the Roc checks, Roc tests, native specs and Wasm mounts against the exact outputs
it packages. Host publication currently does not require a second build
comparison.

Every archive contains `dependency.json`, its exact target files, and license
notices. External dependency manifests record upstream identity, producer/recipe
hashes, compiler configuration, and every payload file's size and digest. Tar
metadata and paths are normalized. External dependency release CI compares
independent build directories and executes a test linked against the extracted
inputs on each supported architecture.

The consumer verifies the archive size and SHA-256 recorded in the reviewed lock
before extraction, including on cache hits. A cache miss downloads the same locked
release; it never silently compiles a substitute. This makes routine consumption
independent of GitHub's online attestation service. Archive links, duplicate paths,
undeclared files, foreign targets, hash mismatches, and incomplete downloads are
errors. Extraction and materialization publish only complete directories, leaving
a failed destination absent so the caller can retry safely.

Normal host changes do not change the dependency recipe or lock. Update a dependency
through its own tested release and a reviewed lock update. Compiler updates must
not change dependency identities implicitly. Keep the previous releases available
for consumers pinned to them; a security replacement receives a new identity.

For commands and release operation, see the
[contributor guide](../www/content/docs/contributing.md#dependency-artifact-releases).

## Coverage and remaining boundaries

The artifact contract above applies to the inputs selected in the root
`dependencies.lock.json` and `web-host.lock.json`. It is not a provenance claim
for historical platform releases.

| Input | Build and consumption boundary | Remaining gap |
| --- | --- | --- |
| musl libc and startup objects | Independent source build, native candidate tests, reproducibility check, immutable release, and verified consumer lock | Dependency updates still require a deliberate release and lock review. |
| Prebuilt web hosts (`libhost.a`, `host.wasm`) | The bundler verifies the host-release lock, producer provenance, exact five-target inventory, and committed host source compatibility before staging extracted bytes | Host releases supply no external link inputs; the musl targets take those from the dependency lock. |

Host-owned engine objects and the web `libhost.a` and `host.wasm` remain platform
build outputs. Changing their source should not change external dependency
identities. A dependency recipe or toolchain change must produce a new dependency
release before consumers adopt it.

An attestation identifies who produced particular bytes and from which workflow
and source revision. The pinned upstream inputs, recipe review, candidate tests,
and immutable release are separate controls; an attestation alone does not prove
that an ambient system library was built from reviewed source. Producer workflows
publish attestations for users who want that provenance evidence; the repository's
reviewed content hashes are the trust anchor used by ordinary consumers.

## Producer CI selection

Ordinary platform, host, engine, example, consumer-lock and documentation changes
reuse released dependencies; they do not select the dependency producer workflow.
The musl producer's pull-request filter in `.github/workflows/dependencies.yml`
names its recipe, probe, producer and tests, the shared archive, admission and
publication helpers they import, and the workflow itself. Publication remains a
separate manual dispatch on main.
