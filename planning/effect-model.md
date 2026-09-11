# Effect-model follow-up work

[design.md](../design.md) defines the shared action/effect architecture.
This plan contains remaining work only. Review evidence, completed changes,
and gate results belong in the pull request, not here.

## Browser executor verification

- Audit bounded-stack execution across compiler frame shapes, including leaf
  and red-zone accesses and the main-stack lower bound. Prove that an effect
  trap prevents all subsequent Wasm entry, including suspended siblings.
- Define and test shutdown with outstanding HTTP calls, late results, and
  services that do not promptly honor abort. Establish when retained captures,
  private stacks, and result actions are released or the instance is abandoned.
- Finish the full diff review against the intended model: shared ABI changes,
  JavaScript failure and lifetime paths, example race policies, and the
  ownership invariants previously covered by removed task tests.
- Separate unrelated behavioral changes from migrations; changing the
  transport does not itself require changing application failure behavior.
- Complete the required end-to-end gates from
  [contributing.md](../www/content/docs/contributing.md), including release
  build paths, and keep the concrete remaining checklist in the implementing
  issue or pull request.
- Provision JSPI-capable Node and Binaryen explicitly in the three-platform
  release smoke workflow, then validate exact release candidates on each OS.
  Source CI provisioning alone does not establish release readiness.
- Keep semantic SCM specs human-readable and first-order: select a pending
  occurrence and run its entire closure against ordinary service stubs.
  Exercise actual suspension and concurrency in focused executor tests, not
  a coroutine simulation in the semantic harness.

Completion requires evidence for the whole affected boundary, not merely
passing happy-path examples or an oversized-frame regression.

## Ownership, admission, and work bounds

- Preflight running-effect bookkeeping before transferring a pending thunk.
  Audit both host callers of `takeNextPendingEffect` and
  `trackRunningEffect`, including allocation failure and retained-read
  ownership. This shared-engine gap is not specific to the browser executor.
- Replace or explicitly budget queue operations that scan or shift outstanding
  work: `orderedRemove(0)` when dequeuing and linear removal when finishing
  running effects can make a long drain quadratic.
- Design admission, reservation, release, saturation, and typed refusal for
  pending and running effects and queued results. A fixed browser executor
  slot limit reached after admission is not a complete admission policy.
- Define consecutive effect-feedback bounds and useful diagnostics, including
  an endless `then` chain under the synchronous spec executor.
- Add the required skipped-write counter and bounded diagnostic for effect
  results targeting retired destinations. Preserve the intended per-write
  law; missing observability is not a reason to weaken the design.
- Refine explicit cancellation and supersession only with a defined ownership
  and result-delivery contract. Until then, application state owns race policy;
  do not reintroduce implicit cancellation on scope disposal.

Prove reservation and release balance under allocation failure, saturation,
retirement, teardown, and long occurrence histories. Measure queue scaling
before claiming throughput proportional to completed work.

## Strengthen the hosted boundary

- Audit compatibility protection for the native effect handoff and primitive
  service ABI. Add version/layout validation where missing and document the
  ownership contract for next/run/done, failure, and shutdown.
- Give contract failures structured diagnostics, including missing declared
  reads, duplicate batch destinations, unsupported effect execution, and
  failed result preparation.
- Extend fault placement to worker allocation, mailbox saturation, result
  arrival during teardown, and cross-thread allocator ownership. Test that
  the UI thread never waits on a worker that needs a chooser reply.
- Check deterministic coverage for each hosted primitive, including environment
  reads, without expanding the SCM language into an execution simulator.
- Preserve tests for completion-order races, equal but distinct occurrences,
  reparenting, and retired writes across both hosts. Use focused live executor
  tests for behavior whole-closure semantic tests cannot establish.

## Separate workstreams

- [capability-api.md](capability-api.md) owns explicit authority and delegation
  at hosted-function boundaries; it must not introduce a second effect model.
- [test-harness-architecture.md](test-harness-architecture.md) owns parser,
  resolver, scenario timing, and result-protocol improvements. Undertake them
  independently unless a concrete shipping blocker requires a narrow change.
- Props APIs, shared element parity enforcement, and styling work remain
  independent API projects. Do not bundle them into effect-model convergence.

Stable laws and rationale belong in `design.md`; public behavior belongs in
maintained reference documentation; implementation and verification evidence
belongs in issues and pull requests.
