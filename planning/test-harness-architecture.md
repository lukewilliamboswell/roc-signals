# Built-in test harness: target architecture and migration plan

## Scope

This plan covers future parser, resolver, scenario timing, and result-protocol
work. Each phase must first verify the current implementation and remove
requirements already satisfied; the sequence is not a mandate to rebuild
existing mechanisms.

Semantic SCM tests must remain human-readable and first-order. Manual effect
mode selects a pending occurrence and executes its entire Roc closure using
ordinary hosted-service stubs. Occurrence ordering expresses races; the spec
does not model coroutine stacks, suspension points, threads, or fetch promises.
Real overlap and shutdown belong in focused native/browser executor tests.
Typed fixture work should describe hosted service inputs and results, not
task-kind routing or a second execution model.

These improvements are independent of the browser-effect refactor unless a
specific shipping blocker requires a narrowly scoped change.

## Target architecture (summary)

1. **One typed command model.** `Step = union(enum)` with a payload struct per variant, `Locator = union(enum)`, arena-owned `Spec {form, name, setup: Setup, scenario: ?Scenario, skip: ?Skip, commands}`. A comptime capability table (`semantic | window_only | both`) replaces `isWindowOnly` and the Rust refusal list.
2. **One decoder.** Extend the direct S-expression decoder to produce typed `Step` values. Shared argument helpers (`string`, `symbol`, `unsigned`, `boolean`, `locator`, keyword lookup) live in one module used by steps and fixtures.
3. **Typed hosted-service fixtures.** Describe ordinary service inputs and results with the same validation as the hosted boundary. No task-kind manifest or coroutine simulator is required; any further schema generation needs its own demonstrated duplication problem.
4. **One semantic tree, one resolver.** `src/spec/semantic_tree.zig` defines `Node {id, parent, order, role, tag, name, label, text, value, test_id, state, bounds?, history?, update_count?}` and `resolve(tree, locator, intent)` with one intent-aware preference rule. The display-free host builds the tree from `sim_dom`; the GPUI host hands the engine an overlay (bounds, focus, undo depth) over the ABI and asks it to resolve.
5. **Deterministic time in scenarios.** `signals_pending_work()` bitmask from the engine, `(settle :timeout ms)` and `(wait-for <assertion> :timeout ms)` steps; `(wait ms)` remains an explicit wall-clock escape that the parser warns about. Tests keep `tick-interval` only.
6. **One result protocol and one driver.** `spec-result/v3` emitted by both hosts (adds `form`, `host {kind, system, frame, window}`, `steps`, `evidence`, `warnings`, `skip`); `spec_driver.run_suite` gains a `Worker` abstraction so `gui_scenarios.py` is a thin CLI. Window workers stay serial per display (compositor focus is global); parallelism comes from `--shard`.
7. **`:skip` on any form.** `(test "name" :skip "reason" :issue "https://github.com/.../issues/N" ...)`; also `:on (linux client-frame)` to scope it. A skipped spec is still executed; its outcome is reported as `skipped` with reason and link and does not fail the run; a skipped spec that passes fails the run with "remove the :skip". The known-failures ledger stays as is for the native/wasm suites; `:skip` is the mechanism for spec-level defects on both forms.
8. **Explicit Ctx contract.** `src/spec/ctx.zig` verifies required declarations at instantiation using the pattern in `src/signals/engine_contract.zig`, with all-or-nothing capability groups (`environment`, `window`, `measured`). `benchmark.Runner` reuses `spec_runner.dispatch`.
9. **Evidence tiers.** Semantic (test) → structural window (scenario tree snapshot goldens) → layout (bounds goldens; probe extended to dialogs and scrolled regions) → image capture (attached, never asserted; Linux and Windows backends) → future OS-automation worker exporting the same tree shape.

## Work sequence

Preserve the existing direct S-expression decoder, canonical spec golden, and
window-vocabulary tests as regression guards. Record fresh suite timings and
scenario counts in the implementing PR rather than relying on a fixed baseline
in this plan.

Typed payloads precede shared dispatch; result-protocol work precedes scenario
settling and evidence integration. Resolver work can proceed independently once
its cross-host conformance fixtures exist. Authoring conveniences come last.

### Shared argument helpers

Consolidate duplicated argument validation only where steps and service fixtures
have the same contract. Audit escapes and source locations before moving helpers;
keep the canonical golden unchanged unless an explicit semantic change is intended.

### Phase 2b — Typed payloads
- New `src/spec/command.zig`: `Locator`, `Step` union with per-variant payload structs, `Setup`, `Skip`, `Spec` with arena ownership; capability table.
- `spec_runner.Runner.run` switches exhaustively on `Step`; `native_host.applyPreMountSpecCommands` takes `Setup`. Preserve the existing typed `file_fixtures.Fixture {label, stub}` boundary; no task settlement or admitted-kind transport is needed.
- ABI: replace the one-field-per-payload `RawCommand` with `RawStep {kind, line, col, locator_kind, locator_role, locator_name, locator_value, args}` plus `signals_scenario_arg(step, index, *RawArg)` where args are reflected from the payload struct (`inline for` over `std.meta.fields`), so new variants need no ABI change. `bridge.rs` reads named args; `script.rs::decode` looks them up by name.
- Add `zig build spec-manifest` emitting `steps.json` (kind, capability, arg names/types) and a Rust test that every window-visible kind is decoded and vice versa.
- Proof: golden unchanged; Rust/Zig vocabulary tests; suites green. Measure "files touched to add a step" with a throwaway dummy step.

### Phase 3 — Explicit Ctx contract; merge benchmark step logic
- `src/spec/ctx.zig` `assertCtx(comptime Ctx)` using `src/signals/engine_contract.zig`; capability groups declared as a `capabilities` struct on the Ctx instead of scattered `@hasDecl`.
- Refactor the runner switch into `dispatch(comptime Ctx, host, roc_host, step) StepOutcome` with typed `unsupported` outcomes.
- `src/bench/benchmark.zig` calls `spec_runner.dispatch` with a `BenchmarkCtx {capabilities.measured = true}`; delete its duplicated click/pointer/key logic and `BenchmarkDomElement`.
- Proof: `zig build test`; `test.py bench` CSV byte-compared on a sample.
- Status 2026-09-11: the contract module and capability groups landed (`src/spec/ctx.zig`, applied to `SpecRunnerCtx`). The benchmark step merge is deferred: the benchmark's measured dispatch threads a stats record through every step, so sharing the runner's dispatch needs the measurement hook redesigned first. It stays on this phase's list.

### Phase 5 — One result protocol, one driver, `:skip`
- Parser: `:skip "reason" :issue "url"` (+ optional `:on (...)`) on `test` and `scenario`; `:issue` required; remove `:diagnostic`/`:on` from `Scenario` and `RawScenario`. Convert the one existing diagnostic (`examples-gui/counter/specs/minimum-window-layout.scm`) to `:skip` with a GUI-35 issue link.
- `spec-result/v3`: shared Zig JSON writer used by `writeSpecJsonResult` and, through `signals_scenario_result_json`, by the GPUI host (which prints v3 to stdout and still writes the report file). Status gains `skipped`; failure gains `line`, `observed`; adds `form`, `host`, `steps`, `evidence`, `warnings`, `skip {reason, issue}`.
- `scripts/spec_driver.py`: `Worker` protocol (`NativeWorker`, `WindowWorker` wrapping capture/hold), v3 validation, `PROTOCOL` bump, skip ratchet ("skipped spec passed: remove the :skip"), glob filter and `--shard` for scenarios, `timeout_overrides` from a `[scenarios]` table in `benchmarks.toml`; `print_summary` gains form and evidence columns. `scripts/gui_scenarios.py` becomes a thin CLI.
- CI: `gui-windows` and `gui-macos` run `minici gui-scenarios --no-capture` (sharded if minutes bite).
- Docs: `contributing.md`, `testing.md`.
- Proof: identical pass/fail/skip set for the maintained scenarios; `test_gui_scenarios.py`, `test_spec_driver.py`; three-OS gui matrix green.

### Phase 6 — Deterministic time in scenarios
- Engine export `signals_pending_work() -> u32` `{effects_queued, effects_running, timers_due, render_dirty}` beside the effect and timer handoff exports. This is a proposed window-settling observation, not a semantic-spec simulation of running effects.
- Steps `(settle :timeout ms)` and `(wait-for <assertion> :timeout ms)` (window-only); the GPUI loop evaluates after each painted frame. Replace the 900 ms startup sleep and 150 ms per-step sleep in `lib.rs` with settle; convert `(wait n)` in the maintained scenarios; parser warns on remaining `(wait ms)` into `warnings[]`.
- Proof: same verdicts over 5 repeated runs (`--repeat` in the driver); measure scenario wall time against a freshly recorded baseline and set a justified budget.

### Phase 7 — Engine-owned resolver and semantic tree
- `src/spec/semantic_tree.zig`: `Node`, `Tree`, `resolve(tree, locator, intent)` with the single rule (intent narrows: click → activatable; value → editable; state → interactive; observe → none; direct name beats child text; zero → none, one → unique, more → ambiguous everywhere; `expect-visible`/`expect-absent` become count-based). Port the eight Rust resolver tests to Zig.
- Display-free host: `HostEnv.semanticTree()` from `dom_elements`; delete `findElementByLocator`/`countElementsByLocator` and `sim_dom.matchesLocator*` (move `accessibleName`).
- GPUI host: `signals_scenario_resolve(locator_index, intent, overlay, len, *RawResolution)`; `control_frame` becomes `overlay_frame` (bounds from `probe.rs`, focus, undo depth); delete `script.rs` `Locator`, `resolve*`, `Control.matches`; `check` operates on node ids.
- Paired conformance fixture under `test/gui/presentation/` (button with child caption, duplicate labels, container vs button) run as both test and scenario.
- Proof: conformance fixture; all scenarios; `cargo test`; `zig build test`.

### Phase 8 — Evidence tiers
- Probe: record dialog bounds from the dialog's render layer (`crates/gpui-host/src/dialog.rs`) with a layer tag; record scrolled-region content bounds and scroll offset so `expect-onscreen` versus a new `expect-reachable` is expressible.
- Tree snapshots as goldens (`specs/goldens/<scenario>/<name>.tree.json`, `--update-goldens`); layout goldens (bounds per test id, 1 px rounding, `:tolerance`).
- `scripts/gui_capture.py`: Linux backend on the private Weston display (`gui_smoke.wayland`), Windows backend via `PrintWindow`; captures attached in `evidence.captures`, never asserted.
- Proof: goldens for the existing scenarios; captures present in CI artifacts on three OSes.

### Phase 9 — Authoring (optional, after the above)
- `specs/_defaults.scm` `(defaults (setup ...) (fixtures ...))` and `(define-steps name ...)` / `(include name)` expanded at parse time with origin tracking, so one process still runs one fully expanded spec and fault replays stay exact; `--host-dump-spec` prints the expansion.
- Proof: dedupe a few `examples-web/conduit` specs; driver output unchanged.

## Non-goals
- Sharing one process across specs (breaks fault campaigns, leak checks, entropy determinism).
- A runtime flag to pick parsers, or keeping the line grammar as an input format.
- Merging the three element *structs*; only the tree snapshot and the resolver are unified.
- Asserting on pixels.

## Risks
- Typed payloads change ownership and ABI boundaries; use the existing canonical golden and vocabulary tests as guards, and land that phase separately.
- ABI grows (`scenario_arg`, `resolve`, `pending_work`, `result_json`): bump `protocol_version` once per touching phase; keep `signals_scenario_*` names stable so `gui-host.lock.json` churn is small.
- Phase 6 may expose scenarios that passed only through slack; mark with `:skip` and an issue rather than re-adding sleeps.
- Phase 7 changes ambiguity semantics for scenarios; the count-based visible rule and the conformance fixture keep the maintained scenarios green.

## Verification (end to end, per phase)
- `zig build test`, `cargo test -p signals-gpui-host` (with `LIBRARY_PATH=platform-gui/targets/<target>`), `python3 -m unittest discover -s scripts -p "test_*.py"`.
- `python3 scripts/test.py native gui fault bench --roc-bin <pinned nightly>`; `python3 scripts/generate_protocol.py --check`.
- `python3 scripts/gui_scenarios.py --directory .test-out/gui --no-capture` on the desktop compositor and `python3 scripts/minici gui-scenarios` under Weston; three-OS CI matrix.
- Per-phase measurements recorded in the PR: suite times, gui job minutes, scenario wall and flake rate, `spec_parser.zig` LOC, `test/spec-decode.golden` diff size (zero unless declared), files touched to add a dummy step.
