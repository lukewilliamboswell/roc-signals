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
