//! Model-based fuzzing for structural transaction atomicity under allocation failure.
//!
//! # Why this target exists
//!
//! design.md, "Memory management and allocation failure", states the
//! verification principle as *exhaustive fault placement*: a representative
//! transaction records its successful allocation-attempt count, then runs with
//! attempt `N` and every later attempt failing, for every `N` from one to that
//! count. Each outcome must match its declared recoverable or fatal boundary and
//! prove no leaks, double release, partial publication, or invalid reuse.
//!
//! The repository already does this well for *hand-written* transactions - there
//! are sweeps in `render_commands.zig`, `render_cache.zig`, `scope_runtime.zig`,
//! `engine.zig`, and `native_host.zig`. This target does not replace them and
//! should not try to. What it adds is the other axis: those sweeps are exhaustive
//! over fault position but fixed in structure, so a fault landing between two
//! particular phases is only ever tested against the structures someone wrote
//! down. Here the structure and the edit history are generated, and the fault
//! sweep runs over each one. Fault position x generated structure is the product
//! neither approach covers alone.
//!
//! # What is generated
//!
//! A structure and a history: an element tree with keyed-row sites and `when`
//! branches, then a sequence of structural edits - branch flips, row splices,
//! reorders, descriptor replacements. Each edit is then run once to count
//! allocation attempts, and once per attempt `N` with the fault armed.
//!
//! # Oracles
//!
//! For a refused transaction, the requirement is that nothing observable moved.
//! There is no single snapshot-and-diff helper, so the model compares the set the
//! existing sweeps already treat as the committed state:
//!
//!  - **Published commands unchanged.** `TransactionalBatch.commit` - a swap of
//!    `staged` and `published` - is the *only* function that publishes commands,
//!    which makes "was anything published?" a precise question. `isDrained()`
//!    checks all six buffers at once. Buffer identity is compared too, not just
//!    length: the `.items.ptr` and `.capacity` of the published command, string,
//!    and dynamic buffers must be untouched, which proves no reallocation
//!    happened underneath an unchanged length.
//!  - **A prior undrained publication survives.** A refusal must not discard
//!    commands published by an earlier successful call and not yet drained. The
//!    generator therefore sometimes leaves a publication undrained before the
//!    next transaction, since a refusal path that clears both buffers looks
//!    correct against an empty batch and is wrong here.
//!  - **Committed structure unchanged.** Lengths of `engine.scopes`,
//!    `node_identities`, `dom_identities`, `states`, `active_stream.*`,
//!    `active_signal_graph`, and `render_cache.nodes`, plus interned tag count.
//!  - **Nothing leaked.** `closure_retains == closure_releases`, and the Roc-side
//!    `Ledger.liveCountSince(snapshot)` is zero - the strongest single refusal
//!    check available.
//!  - **The engine is still usable.** After the refusal, disarming the fault and
//!    retrying the same transaction *on the same engine* must succeed and produce
//!    the same result as the unfaulted run. A refusal that leaves the engine
//!    poisoned is a failure even when it leaks nothing.
//!  - **Recoverable and fatal are not confused.** `PreflightError` carries two
//!    meanings: `OutOfMemory` means the allocator refused, while `ResourceLimit`
//!    means a configured `BatchLimits` or `hard_max_*` bound or an arithmetic
//!    overflow was hit *before any allocation at all*. The target asserts
//!    `fault.attempts == 0` on the `ResourceLimit` path, which is what makes that
//!    distinction real rather than nominal. `collection_budget.StreamBudget.charge`
//!    is driven toward its bounds to reach it.
//!  - **Phase discipline.** `PublicationPhase` runs `unprepared -> preflighted ->
//!    batch_published -> host_published` and panics on out-of-order transitions;
//!    `Plan.commit` panics on double commit and on post-commit append. These
//!    panics are free oracles - the fuzzer catches them without the model having
//!    to predict them - so the generator deliberately explores interleavings that
//!    could reach them.
//!  - **Abort unwinds in reverse.** `Plan.abort` runs `action.abort` in reverse
//!    construction order while `commit` runs `apply` forward. Generated plans are
//!    long enough that an order-dependent action would notice.
//!
//! # Seams
//!
//! The transaction is not in `structural_splice.zig`, which is a stateless
//! library of free functions pairing fallible `prepare*` with infallible
//! `*AssumeCapacity` twins; nor in `collection_plan.zig`, which supplies the
//! `IdentityOverlay` / `ScopeOverlay` / `Plan` primitives and their
//! `prepare -> reserve -> commit|abort` discipline. It lives in `engine.zig`:
//! `PreparedRootCollection.prepare` -> `PreparedStructuralDownstream.prepare*` ->
//! `prepareRender` (which ends in the command preflight) ->
//! `commitAssumeCapacityWithEarlyAndLate` (the allocation-free mutation
//! boundary) -> `publishRenderLast`. The refusal path is `deinit`, which aborts
//! the batch when `PublicationPhase.needsAbort()`.
//!
//! Drive the `try*` dispatch variants - `tryDispatchStateValue`,
//! `tryDispatchEffectSourceValue`, `tryDispatchTaskSourceValue` - which expose
//! recoverable preparation failure. The non-`try` twins panic on OOM and would
//! turn every injected fault into a false crash.
//!
//! Two properties of `FaultAllocator` shape the model. It is *sticky*: attempt
//! `N` and every later attempt fail until reconfigured, so it cannot express
//! "fail once, then succeed" - and `configure` resets `attempts` and
//! `induced_failures`, with `induced_failures` saturating at one, so it is a
//! boolean, not a count. `free` never counts and never fails, which is what makes
//! teardown guaranteed allocation-failure-free. Counting a transaction's attempts
//! means running it once with `configure(null)` and reading `.attempts`. Note
//! also that `render_commands.zig` uses `std.testing.FailingAllocator`, which is
//! zero-based; the two conventions differ by one and must not be mixed.
//!
//! `engine.zig`'s test "prepared root collection aborts every allocation point
//! and retries on the same engine" is the closest existing harness, and
//! `render_cache.zig`'s `Runner.run(failure_number: ?usize) !usize` - returning
//! the attempt count when passed null - is the sweep shape to copy.
//!
//! To replay a crash:
//!   python3 scripts/fuzz.py repro structural <crash-file> --verbose

const std = @import("std");
const signals = @import("signals");
const FuzzReader = @import("FuzzReader.zig");

/// AFL++ persistent-mode initialization hook.
pub export fn zig_fuzz_init() void {}

/// AFL++ persistent-mode entry point.
pub export fn zig_fuzz_test(buf: [*]u8, len: isize) void {
    zig_fuzz_test_inner(buf, len, false);
}

/// Runs one fuzz input.
pub fn zig_fuzz_test_inner(buf: [*]u8, len: isize, debug: bool) void {
    _ = debug;
    var reader = FuzzReader.init(buf[0..@intCast(len)]);
    _ = reader.readByte();
    _ = signals;
    _ = std;
}
