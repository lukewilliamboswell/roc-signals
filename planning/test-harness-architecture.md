# Built-in test harness: target architecture and migration plan

## Context

PR #99 made window scenarios `(scenario ...)` specs parsed by the engine's spec parser, so tests and scenarios now share one grammar. Stepping back, the harness still spells several concepts in more than one place by hand, and each of those is where adding a platform capability (network tasks, clipboard, notifications, IME, drag, theming/layout APIs) or a host (real browser, Windows/macOS window runs, OS automation) will hurt:

- **Step decoding is two parsers.** Each S-expression form is re-serialized into a legacy line grammar and re-parsed (`src/spec/spec_parser.zig` `appendDecodedForm` → `writeLegacy*` → `parseTestSpec`). The result is a flat `SpecCommand` whose `expected_text` carries 12 meanings and whose fields are back-patched ~20 times. Adding a step touches the enum, the desugarer, the line parser, the runner switch, the pre-mount switch in `src/native_host.zig`, and the Rust decoder.
- **Task shapes are hand-written four times.** `protocol/native-protocol.json` records task kind ids and names only; request/result frame shapes live separately in `src/native_files_codec.zig`, `crates/gpui-host/src/effects.rs`, `platform-gui/Files.roc`, and `src/spec/file_fixtures.zig`.
- **Two locator resolvers with different rules.** Zig (`native_host.zig` `tryFindElementByLocator`, `sim_dom.zig`) honours role and fails any ambiguity; Rust (`script.rs` `resolve*`) discards role and applies layered preference. The same locator can mean different things in a test and a scenario.
- **Scenarios sleep.** 76 `(wait ms)` steps totalling ~41 s plus a 900 ms startup settle and 150 ms per step; tests tick deterministically.
- **Two result pipelines.** Tests use the strict `spec-result/v2` protocol, a thread pool, sharding, timeout policy, fault campaigns and the known-failures ledger; scenarios use an ad hoc report file, a serial loop, a hardcoded 180 s timeout, and their own `:diagnostic` mechanism.
- **Implicit runner contract.** `Runner(comptime Ctx)` needs ~40 duck-typed functions defined only by the single `SpecRunnerCtx`; `benchmark.Runner` duplicates step logic with a second Ctx.
- **Evidence gaps and CI gaps.** The bounds probe cannot see dialogs or scrolled regions; captures are macOS-only; Windows and macOS CI run no scenarios; `scripts/ci_changes.py` does not select the gui job for `src/signals/` changes.

Decisions already taken with the user: the engine owns the one resolver (every host exports a semantic-tree snapshot); known-open defects are marked in the spec file with a `:skip` header carrying a reason and an issue link, which the driver reports rather than chokes on.

The intended outcome: adding a capability is one manifest entry, one typed step variant, and one Ctx function; adding a host is one Ctx plus one snapshot exporter; nothing crosses a language boundary by convention alone; and every phase lands on green CI with a proof that meaning did not change.

## Target architecture (summary)

1. **One typed command model.** `Step = union(enum)` with a payload struct per variant, `Locator = union(enum)`, arena-owned `Spec {form, name, setup: Setup, scenario: ?Scenario, skip: ?Skip, commands}`. A comptime capability table (`semantic | window_only | both`) replaces `isWindowOnly` and the Rust refusal list.
2. **One decoder.** S-expression → `Step` directly; the line grammar and `writeLegacy*` are deleted. Shared argument helpers (`string`, `symbol`, `unsigned`, `boolean`, `locator`, keyword lookup) live in one module used by steps and fixtures.
3. **Manifest-driven task shapes.** `protocol/native-protocol.json` schema 2 adds per-kind `request`/`result` field lists (types `text{max}`, `path`, `u64`, `bool`, `enum{values}`, `list{of,max}`, `hex_sha256`, plus named `rules`). `scripts/generate_protocol.py` renders codec validators, fixture forms, Rust frame tables, Roc frame-order constants and docs; path validation and cross-field rules stay hand-written Zig registered by name.
4. **One semantic tree, one resolver.** `src/spec/semantic_tree.zig` defines `Node {id, parent, order, role, tag, name, label, text, value, test_id, state, bounds?, history?, update_count?}` and `resolve(tree, locator, intent)` with one intent-aware preference rule. The display-free host builds the tree from `sim_dom`; the GPUI host hands the engine an overlay (bounds, focus, undo depth) over the ABI and asks it to resolve.
5. **Deterministic time in scenarios.** `signals_pending_work()` bitmask from the engine, `(settle :timeout ms)` and `(wait-for <assertion> :timeout ms)` steps; `(wait ms)` remains an explicit wall-clock escape that the parser warns about. Tests keep `tick-interval` only.
6. **One result protocol and one driver.** `spec-result/v3` emitted by both hosts (adds `form`, `host {kind, system, frame, window}`, `steps`, `evidence`, `warnings`, `skip`); `spec_driver.run_suite` gains a `Worker` abstraction so `gui_scenarios.py` is a thin CLI. Window workers stay serial per display (compositor focus is global); parallelism comes from `--shard`.
7. **`:skip` on any form.** `(test "name" :skip "reason" :issue "https://github.com/.../issues/N" ...)`; also `:on (linux client-frame)` to scope it. A skipped spec is still executed; its outcome is reported as `skipped` with reason and link and does not fail the run; a skipped spec that passes fails the run with "remove the :skip". The known-failures ledger stays as is for the native/wasm suites; `:skip` is the mechanism for spec-level defects on both forms.
8. **Explicit Ctx contract.** `src/spec/ctx.zig` verifies required declarations at instantiation using the pattern in `src/signals/engine_contract.zig`, with all-or-nothing capability groups (`environment`, `window`, `measured`). `benchmark.Runner` reuses `spec_runner.dispatch`.
9. **Evidence tiers.** Semantic (test) → structural window (scenario tree snapshot goldens) → layout (bounds goldens; probe extended to dialogs and scrolled regions) → image capture (attached, never asserted; Linux and Windows backends) → future OS-automation worker exporting the same tree shape.

## Phases

Each phase is one reviewable PR series, leaves CI green, and names its proof. Order follows the dependency graph: 0 → 1 → 2a → 2b → {3, 4} → 5 → 6 → 7 → 8 → 9.

### Phase 0 — Hygiene and baseline (no meaning change)
- `scripts/ci_changes.py`: `src/signals/`, `src/spec/`, `src/sim_dom.zig`, `src/native_host.zig`, `protocol/` select `gui` too; test in `scripts/test_ci_changes.py`.
- `scripts/gui_scenarios.py`: print total and per-scenario wall time.
- Record baselines in the PR: native suite worker/wall time (`spec_driver.print_summary`), Linux gui job minutes, scenario wall total, `spec_parser.zig` LOC.
- Proof: unit tests; CI selection test.

### Phase 1 — Proof harness before touching the parser
- `spec_parser.writeCanonical(writer, spec)`: one deterministic line per command printing every field.
- Extend the "all checked-in S-expression specs parse" test (`spec_parser.zig` ~line 1262) into a golden comparison against `test/spec-decode.golden` (regenerated only via an explicit build step, reviewed in diff).
- Pin the ABI vocabulary: Zig test over `std.meta.tags(SpecCommandType)` and a Rust test in `script.rs` asserting the same set of window-visible kinds.
- Proof: the golden; existing parser tests round-trip.

### Phase 2a — Direct decoder, same `SpecCommand`
- Replace `appendDecodedForm`'s re-serialization with head-dispatch decoding of `sexpr.Expr`; promote `file_fixtures.zig` helpers (`string`, `symbol`, `unsigned`, `field`, `oneOf`) to `src/spec/sexpr_args.zig`; delete `parseTestSpec`, `splitTrailing*`, `splitTwoQuoted`, `writeLegacy*`, `dupeUnescapedQuoted`; move line-grammar unit tests to S-expression literals.
- Decision to record: decode strings uniformly (today `local-storage`, `navigate`, `expect-document-title`, task names use `dupePlain` while others unescape). Grep the corpus first; if no line changes, the golden does not move.
- No runtime flag and no dual parser; the golden is the oracle.
- Proof: golden unchanged (or only the declared lines); `zig build test`; `test.py native gui fault bench`; all 29 scenarios.

### Phase 2b — Typed payloads
- New `src/spec/command.zig`: `Locator`, `Step` union with per-variant payload structs, `Setup`, `Skip`, `Spec` with arena ownership; capability table.
- `spec_runner.Runner.run` switches exhaustively on `Step`; `native_host.applyPreMountSpecCommands` takes `Setup`; `file_fixtures.parse` returns `TaskSettlement {name, payload, admitted_kinds}`.
- ABI: replace the one-field-per-payload `RawCommand` with `RawStep {kind, line, col, locator_kind, locator_role, locator_name, locator_value, args}` plus `signals_scenario_arg(step, index, *RawArg)` where args are reflected from the payload struct (`inline for` over `std.meta.fields`), so new variants need no ABI change. `bridge.rs` reads named args; `script.rs::decode` looks them up by name.
- Add `zig build spec-manifest` emitting `steps.json` (kind, capability, arg names/types) and a Rust test that every window-visible kind is decoded and vice versa.
- Proof: golden unchanged; Rust/Zig vocabulary tests; suites green. Measure "files touched to add a step" with a throwaway dummy step.

### Phase 3 — Explicit Ctx contract; merge benchmark step logic
- `src/spec/ctx.zig` `assertCtx(comptime Ctx)` using `src/signals/engine_contract.zig`; capability groups declared as a `capabilities` struct on the Ctx instead of scattered `@hasDecl`.
- Refactor the runner switch into `dispatch(comptime Ctx, host, roc_host, step) StepOutcome` with typed `unsupported` outcomes.
- `src/bench/benchmark.zig` calls `spec_runner.dispatch` with a `BenchmarkCtx {capabilities.measured = true}`; delete its duplicated click/pointer/key logic and `BenchmarkDomElement`.
- Proof: `zig build test`; `test.py bench` CSV byte-compared on a sample.
- Status 2026-09-11: the contract module and capability groups landed (`src/spec/ctx.zig`, applied to `SpecRunnerCtx`). The benchmark step merge is deferred: the benchmark's measured dispatch threads a stats record through every step, so sharing the runner's dispatch needs the measurement hook redesigned first. It stays on this phase's list.

### Phase 4 — Manifest-driven task schemas
- `protocol/native-protocol.json` schema 2: per task kind `codec`, `request[]`, `result {ok[], err[]}`, `fixture` alias, `rules[]`, `hosts[]`. `generate_protocol.py` validation fails on a kind without shapes.
- Generated: `TaskSchema` tables and `SchemaTag` byte arrays in `src/signals/native_protocol_gen.zig` (removing hand-spelled arrays in `src/signals/boundary.zig`); a generic validator replacing `src/native_files_codec.zig` (`native_task_codec.zig`) with `rules` hooks in a comptime name→fn map; `src/spec/task_fixtures_gen.zig` replacing the nine hand-written forms (existing `resolve-file-*` names kept as aliases); Rust `TaskSchema` consts in `protocol_gen.rs` consumed by `effects.rs` and a test that each request reads exactly the manifest's frame count; a marked section in `platform-gui/Files.roc` with frame-order constants (domain decoders stay hand-written); docs tables.
- Proof: `generate_protocol.py --check`; existing fixture golden strings in `file_fixtures.zig` byte-identical; Phase 1 golden unchanged; `test.py native gui`.
- Status 2026-09-11: landed the manifest shapes (schema 2), the generated Zig `task_schemas` table and `requestFrames`, the Rust `REQUEST_FRAMES` table with a decoder test, the docs tables and the add-a-task-kind procedure, the manifest-driven fixture encoder replacing the nine hand-written forms, and the native host's arity and rule dispatch from the table. Not yet generated: the `SchemaTag` byte arrays in `boundary.zig`, a fully generic request validator (the count check is table-driven; the log-cursor and assets validators stay hand-written behind manifest-named rules), and a Roc frame-order section in `Files.roc`.

### Phase 5 — One result protocol, one driver, `:skip`
- Parser: `:skip "reason" :issue "url"` (+ optional `:on (...)`) on `test` and `scenario`; `:issue` required; remove `:diagnostic`/`:on` from `Scenario` and `RawScenario`. Convert the one existing diagnostic (`examples-gui/counter/specs/minimum-window-layout.scm`) to `:skip` with a GUI-35 issue link.
- `spec-result/v3`: shared Zig JSON writer used by `writeSpecJsonResult` and, through `signals_scenario_result_json`, by the GPUI host (which prints v3 to stdout and still writes the report file). Status gains `skipped`; failure gains `line`, `observed`; adds `form`, `host`, `steps`, `evidence`, `warnings`, `skip {reason, issue}`.
- `scripts/spec_driver.py`: `Worker` protocol (`NativeWorker`, `WindowWorker` wrapping capture/hold), v3 validation, `PROTOCOL` bump, skip ratchet ("skipped spec passed: remove the :skip"), glob filter and `--shard` for scenarios, `timeout_overrides` from a `[scenarios]` table in `benchmarks.toml`; `print_summary` gains form and evidence columns. `scripts/gui_scenarios.py` becomes a thin CLI.
- CI: `gui-windows` and `gui-macos` run `minici gui-scenarios --no-capture` (sharded if minutes bite).
- Docs: `contributing.md`, `testing.md`.
- Proof: identical pass/fail/skip set for the 29 scenarios; `test_gui_scenarios.py`, `test_spec_driver.py`; three-OS gui matrix green.

### Phase 6 — Deterministic time in scenarios
- Engine export `signals_pending_work() -> u32` `{effects_queued, timers_due, tasks_in_flight, render_dirty}` beside `signals_effect_next`/`signals_timer_next`.
- Steps `(settle :timeout ms)` and `(wait-for <assertion> :timeout ms)` (window-only); the GPUI loop evaluates after each painted frame. Replace the 900 ms startup sleep and 150 ms per-step sleep in `lib.rs` with settle; convert `(wait n)` in the 29 scenarios; parser warns on remaining `(wait ms)` into `warnings[]`.
- Proof: same verdicts over 5 repeated runs (`--repeat` in the driver); scenario wall time target under 10 s from ~56 s.

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
- Phase 2a/2b are the big-bang; the Phase 1 golden and the vocabulary tests are the guard, and each lands alone.
- ABI grows (`scenario_arg`, `resolve`, `pending_work`, `result_json`): bump `protocol_version` once per touching phase; keep `signals_scenario_*` names stable so `gui-host.lock.json` churn is small.
- Phase 6 may expose scenarios that passed only through slack; mark with `:skip` and an issue rather than re-adding sleeps.
- Phase 7 changes ambiguity semantics for scenarios; the count-based visible rule and the conformance fixture keep the existing 29 green.

## Verification (end to end, per phase)
- `zig build test`, `cargo test -p signals-gpui-host` (with `LIBRARY_PATH=platform-gui/targets/<target>`), `python3 -m unittest discover -s scripts -p "test_*.py"`.
- `python3 scripts/test.py native gui fault bench --roc-bin <pinned nightly>`; `python3 scripts/generate_protocol.py --check`.
- `python3 scripts/gui_scenarios.py --directory .test-out/gui --no-capture` on the desktop compositor and `python3 scripts/minici gui-scenarios` under Weston; three-OS CI matrix.
- Per-phase measurements recorded in the PR: suite times, gui job minutes, scenario wall and flake rate, `spec_parser.zig` LOC, `test/spec-decode.golden` diff size (zero unless declared), files touched to add a dummy step.
