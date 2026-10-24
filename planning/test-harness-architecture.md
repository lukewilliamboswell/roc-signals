# Built-in test harness: target architecture and migration plan

## Scope

This plan covers future parser, resolver, and result-protocol work. Each phase must first verify the current implementation and remove
requirements already satisfied; the sequence is not a mandate to rebuild
existing mechanisms.

Semantic SCM tests must remain human-readable and first-order. Manual effect
mode selects a pending occurrence and executes its entire Roc closure using
ordinary hosted-service stubs. Occurrence ordering expresses races; the spec
does not model coroutine stacks, suspension points, threads, or fetch promises.
Real overlap and shutdown belong in focused browser executor tests.
Typed fixture work should describe hosted service inputs and results, not
task-kind routing or a second execution model.

These improvements are independent of the browser-effect refactor unless a
specific shipping blocker requires a narrowly scoped change.

## Target architecture (summary)

1. **One typed command model.** `Step = union(enum)` with a payload struct per variant, `Locator = union(enum)`, arena-owned `Spec {name, setup: Setup, skip: ?Skip, commands}`.
2. **One decoder.** Extend the direct S-expression decoder to produce typed `Step` values. Shared argument helpers (`string`, `symbol`, `unsigned`, `boolean`, `locator`, keyword lookup) live in one module used by steps and fixtures.
3. **Typed hosted-service fixtures.** Describe ordinary service inputs and results with the same validation as the hosted boundary. No task-kind manifest or coroutine simulator is required; any further schema generation needs its own demonstrated duplication problem.
4. **One semantic tree, one resolver.** `src/spec/semantic_tree.zig` defines `Node {id, parent, order, role, tag, name, label, text, value, test_id, state, bounds?, history?, update_count?}` and `resolve(tree, locator, intent)` with one intent-aware preference rule. The native spec host builds the tree from `sim_dom`.
5. **One result protocol.** `spec-result/v3` adds `host`, `steps`, `warnings`, and `skip`; `spec_driver.run_suite` validates it and gains `--shard` for parallelism.
6. **`:skip` on a test.** `(test "name" :skip "reason" :issue "https://github.com/.../issues/N" ...)`. A skipped spec is still executed; its outcome is reported as `skipped` with reason and link and does not fail the run; a skipped spec that passes fails the run with "remove the :skip". The known-failures ledger stays as is for the native/wasm suites; `:skip` is the mechanism for spec-level defects.
7. **Explicit Ctx contract.** `src/spec/ctx.zig` verifies required declarations at instantiation using the pattern in `src/signals/engine_contract.zig`, with all-or-nothing capability groups (`environment`, `measured`). `benchmark.Runner` reuses `spec_runner.dispatch`.
## Work sequence

Preserve the existing direct S-expression decoder and canonical spec golden as
regression guards. Record fresh suite timings in the implementing PR rather than relying on a fixed baseline
in this plan.

Typed payloads precede shared dispatch. Resolver work can proceed independently
once its conformance fixtures exist. Authoring conveniences come last.

### Shared argument helpers

Consolidate duplicated argument validation only where steps and service fixtures
have the same contract. Audit escapes and source locations before moving helpers;
keep the canonical golden unchanged unless an explicit semantic change is intended.

### Phase 2b — Typed payloads
- New `src/spec/command.zig`: `Locator`, `Step` union with per-variant payload structs, `Setup`, `Skip`, `Spec` with arena ownership; capability table.
- `spec_runner.Runner.run` switches exhaustively on `Step`; `native_host.applyPreMountSpecCommands` takes `Setup`. Preserve the existing typed service-stub boundary; no task settlement or admitted-kind transport is needed.
- Proof: golden unchanged; suites green. Measure "files touched to add a step" with a throwaway dummy step.

### Phase 3 — Explicit Ctx contract; merge benchmark step logic
- `src/spec/ctx.zig` `assertCtx(comptime Ctx)` using `src/signals/engine_contract.zig`; capability groups declared as a `capabilities` struct on the Ctx instead of scattered `@hasDecl`.
- Refactor the runner switch into `dispatch(comptime Ctx, host, roc_host, step) StepOutcome` with typed `unsupported` outcomes.
- `src/bench/benchmark.zig` calls `spec_runner.dispatch` with a `BenchmarkCtx {capabilities.measured = true}`; delete its duplicated click/pointer/key logic and `BenchmarkDomElement`.
- Proof: `zig build test`; `test.py bench` CSV byte-compared on a sample.

### Phase 5 — One result protocol, one driver, `:skip`
- Parser: `:skip "reason" :issue "url"` on `test`; `:issue` required.
- `spec-result/v3`: one Zig JSON writer used by `writeSpecJsonResult`. Status gains `skipped`; failure gains `line`, `observed`; adds `host`, `steps`, `warnings`, `skip {reason, issue}`.
- `scripts/spec_driver.py`: v3 validation, `PROTOCOL` bump, skip ratchet ("skipped spec passed: remove the :skip"), glob filter and `--shard`.
- Docs: `contributing.md`, `testing.md`.
- Proof: identical pass/fail set for the maintained suites; `test_spec_driver.py`.

### Phase 7 — Engine-owned resolver and semantic tree
- `src/spec/semantic_tree.zig`: `Node`, `Tree`, `resolve(tree, locator, intent)` with the single rule (intent narrows: click → activatable; value → editable; state → interactive; observe → none; direct name beats child text; zero → none, one → unique, more → ambiguous everywhere; `expect-visible`/`expect-absent` become count-based).
- Native spec host: `HostEnv.semanticTree()` from `dom_elements`; delete `findElementByLocator`/`countElementsByLocator` and `sim_dom.matchesLocator*` (move `accessibleName`).
- Conformance fixture (button with child caption, duplicate labels, container vs button).
- Proof: conformance fixture; `zig build test`; native suites green.

### Phase 9 — Authoring (optional, after the above)
- `specs/_defaults.scm` `(defaults (setup ...) (fixtures ...))` and `(define-steps name ...)` / `(include name)` expanded at parse time with origin tracking, so one process still runs one fully expanded spec and fault replays stay exact; `--host-dump-spec` prints the expansion.
- Proof: dedupe a few `examples-web/conduit` specs; driver output unchanged.

## Non-goals
- Sharing one process across specs (breaks fault campaigns, leak checks, entropy determinism).
- A runtime flag to pick parsers, or keeping the line grammar as an input format.
- Merging the element *structs*; only the tree snapshot and the resolver are unified.
- Asserting on pixels.

## Risks
- Typed payloads change ownership boundaries; use the existing canonical golden as a guard, and land that phase separately.
- Phase 7 changes ambiguity semantics; the count-based visible rule and the conformance fixture keep the maintained specs green.

## Verification (end to end, per phase)
- `zig build test`, `python3 -m unittest discover -s scripts -p "test_*.py"`.
- `python3 scripts/test.py native fault bench --roc-bin <pinned nightly>`.
- Per-phase measurements recorded in the PR: suite times, `spec_parser.zig` LOC, `test/spec-decode.golden` diff size (zero unless declared), files touched to add a dummy step.
