# Roc nightly maintenance

Compiler upgrades are maintainer-reviewed pull requests. The source of truth is the agreed `roc:` header pin across the roots in `.github/roc-nightly.json`; the local toolchain validates those roots before testing.

Install the selected exact official nightly and set `ROC_BIN` to its executable. Run `blueprint run hosted` for the source gate and `blueprint run minici` for the locally reproducible CI areas. Preserve failing diagnostics and link compiler issues in an upgrade draft. Keep the release workflow's existing admission checks until their reviewed replacement is ready.

The retired privileged pin updater no longer runs. Source CI and a successful pin update do not establish compatibility of an already published release. The shared published-release suite migration is tracked in [#158](https://github.com/lukewilliamboswell/roc-signals/issues/158).
