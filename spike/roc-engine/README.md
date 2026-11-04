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

## Phase 5: payloads, effects, Conduit

- Wasm payloads: `payload_reserve(len)` stages a Roc `List(U8)` that the next `event` moves into
  Roc. `boot_keys` + `init` pass the URL and the declared storage values. Effect results are
  events on node `0xffffffff` with handler = request id (see "Effects" in `platform/Engine.roc`).
- Effects: `Engine.watch` / `on_change` sites; awaited requests are owned by the issuing site
  (cancelled on dispose), bounded in flight (refusal is a typed `Refused` follow-up), and stale
  results are dropped and counted. `apps/effects` is the model-oracle fuzz target;
  `scripts/mutate-fx.sh` runs the mutation check.
- Browser: `scripts/browser.sh APP` replays an example's `.scm` specs in headless Chrome
  (`browser/replay.mjs`; Conduit with `HOOKS=browser/conduit-hooks.mjs`), `browser/fx-browser.mjs`
  is the effect contract test, `scripts/jfb.sh` builds and checks the jfb keyed app.
- Scripts read `scripts/env.sh`: sources from this tree, builds under `$P` in the scratch dir.
