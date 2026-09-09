# Supplemental upstream crate notices

Some published crates omit the license files present in their source repository.
`manifest.json` records original notices from the exact Git revision identified
by each crate's `.cargo_vcs_info.json`. Each record binds the crate archive hash,
source revision, upstream URL, and retained notice hash. Shared notice bytes are
stored once in `texts/`; no copyright names or dates are synthesized.

The notice collector checks the crate archive against `Cargo.lock`, reads its
original revision metadata, and refuses supplements for a different revision or
different crate archive. Collection uses the retained local files and does not
fetch upstream content. Updating a crate does not implicitly authorize reusing
an older notice record.

These supplements are part of the host-source fingerprint. They support notice
review but are not a complete license inventory for the combined host. Packages
without notice files, notices embedded in source comments, and toolchain/runtime
notices still require their own accounting. Optional source retention preserves
all selected original crate archives without clearing unresolved notice cases.

`toolchains.json` pins official Rust compiler distributions for their
standard-library copyright report and license texts, and the original Zig source
distribution for its license and source-level notices. These are notice-review
inputs, not a declaration of the components linked into a host. The toolchain
collector verifies the distribution hashes and retains exact notice bytes.
Contributor commands are documented in `www/content/docs/contributing.md`.

`review.json` selects original source files and upstream declarations for crates
whose published archives lack standalone notice files. Every selection binds the
crate checksum, available published Git revision, and selected file hashes.
`declarations/` preserves the selected upstream texts; source files are recovered
from verified crate archives instead of copied into this repository. The
collector's `--review` option regenerates this evidence separately from notice
files and does not change `missing_notice_files`.

The review categories describe evidence, not publication permission:

- `original_source_notices` identifies original license or copyright comments.
- `original_license_reference` identifies an original declaration that refers
  to standard license terms without reproducing their complete text.
- `metadata_only_in_reviewed_archive` identifies a publisher's Cargo license
  declaration without additional notice text found in that archive.
- `upstream_apple_sdk_caveat` preserves the upstream repository's explicit
  discussion of its SDK-derived code. This requires separate consideration from
  other targets and does not turn a macOS question into a Linux or Windows rule.

Absence of a standalone file is not, by itself, a reason to refuse publication.
Payload composition must retain original notices and declarations, label any
separately supplied standard terms as such, and account for the selected target's
dependencies without inventing copyright attribution.
