# Roc-owned reactive engine spike

Temporary spike tree for the experiment described in `planning/roc-engine-spike.md`.
Results: `planning/roc-engine-results.md`; evidence per phase: `planning/roc-engine-evidence/`.
Not part of the product surface; remove or fold into the real platform before merging to main.

- `platform/`: pure Roc engine (`Engine.roc`), platform `main.roc`, Zig Wasm host, `runtime.mjs`.
- `src/`: DOM oracle (`Dom.roc`), spec replay (`Spec.roc`), helpers.
- `apps/`: ports of form-builder, kanban-board, data-grid, markdown-editor (specs replayed).
- `jfb/`: js-framework-benchmark adapters used for the official run.
- `tools/`, `scripts/`: build, timing, fuzz and size scripts (paths still point at the
  scratch layout they were run from).

Toolchain: Roc nightly-2026-11-03-34bd006, Zig 0.16.0.
Upstream issues: roc-lang/roc#12835 #12836 #12841 #12846 #12847 #12848.
