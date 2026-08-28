//! Model-based fuzzing for signal propagation and scheduling.
//!
//! # Why this target exists
//!
//! design.md, "Propagation algorithm (push-based, glitch-free, value-pruned)",
//! specifies four steps: set the source and push it on a queue keyed by
//! topological rank; pop in increasing rank order; stop when the recomputed
//! value is `is_eq` to the cached one; otherwise cache and enqueue dependents.
//! Rank ordering is what makes a diamond (`a->b`, `a->c`, `(b,c)->d`) recompute
//! `d` exactly once after both `b` and `c` settle.
//!
//! "Exactly once" is a property of the *schedule*, not of any single function,
//! so it is invisible to a test that checks one graph shape. The failures worth
//! finding need a particular fan-out, a particular set of simultaneously dirty
//! sources, and a particular update order to line up. That is a search problem,
//! which is what this target turns it into.
//!
//! # What is generated
//!
//! A valid acyclic graph, then a sequence of updates:
//!
//!  1. **The DAG.** Sources, then derived nodes built only from already-emitted
//!     nodes, which makes acyclicity structural rather than checked. The shape
//!     is steered toward the cases that break scheduling: wide fan-out, diamonds,
//!     long chains, and shared subexpressions reachable by several paths.
//!  2. **Transforms.** Identity, addition, parity, saturating counters, and -
//!     load-bearing - transforms that map distinct inputs onto equal outputs, so
//!     equality cutoffs actually fire mid-graph instead of only at the leaves.
//!  3. **Updates.** Batches of one or more simultaneously dirty sources, since a
//!     single dirty source cannot expose a glitch. The same batch is also
//!     replayed with the sources listed in a different order: rank ordering means
//!     the result must not depend on that order, and a dependence on it is
//!     precisely the glitch this design forbids.
//!
//! # The reference model
//!
//! A deliberately slow evaluator: after each batch it recomputes every node in
//! topological order from the source values, with no caching and no pruning. It
//! is quadratic and obviously correct, which is the point - it shares no code
//! with the engine, so agreement is evidence rather than a tautology.
//!
//! # Oracles
//!
//!  - **Value agreement.** Every cached node equals the reference result. Read
//!    through `Record.cachedSlot`, or `PreparedCacheUpdates.readSlot` inside a
//!    transaction, which returns the provisional slot when one is staged.
//!  - **One evaluation per generation.** `Record.last_dirty_generation` /
//!    `last_dirty_changed` stamp each record. The transactional overlay already
//!    panics with "prepared signal result memoized twice" from
//!    `rememberResultAssumeCapacity`, so this oracle is partly self-enforcing;
//!    the target adds the counting form, asserting `derived_calls_into_roc` grew
//!    by at most the number of nodes reachable from the dirty set.
//!  - **Cutoffs prune.** When a transform maps a changed input to an equal
//!    output, `propagation_prunes` must increase and nodes downstream of the cut
//!    must not be evaluated at all. Asserting the counter alone is not enough: a
//!    prune that still recurses would keep the counter honest while doing the
//!    work anyway, so the downstream `derived_calls_into_roc` delta is asserted
//!    to be zero.
//!  - **Work is proportional to the changed set.** design.md's Complexity
//!    Discipline budgets non-structural propagation at O(C + fanout). The target
//!    derives a bound from the generated graph and the changed set and asserts
//!    `derived_calls_into_roc` stays under it - the check that catches an O(N)
//!    scan hiding beneath a correct answer.
//!  - **Order independence.** Permuting the dirty source list within a batch
//!    yields identical values, identical commands, and identical counters.
//!  - **Determinism.** Replaying the whole input from a fresh engine produces
//!    byte-for-byte identical render commands.
//!  - **Abort leaves no trace.** A prepared transaction that is not committed
//!    must leave `dirty_signal_generation` and every cache slot untouched;
//!    `prepareRoots` computes the next generation locally and only publishes it
//!    in `commitSourceCaches`.
//!
//! # Seams
//!
//! Two paths exist and both are driven, because they must agree. The direct path
//! is `propagateDirtyActiveSignals` -> `propagateDirtyActiveSignalRecordIds` ->
//! `evalDirtyHostSignalRecord`. The production path is transactional:
//! `PreparedSourceTransaction.prepare`/`prepareMany` -> `prepareRoots` ->
//! `prepareChangedActiveSignalRecordIds`, then `commitPreparedDirtySignalCaches`.
//! Sources are dirtied through `tryDispatchStateValue` and friends; there is no
//! separate mark-dirty call.
//!
//! Two traps for whoever implements this. The slice returned by
//! `propagateDirtyActiveSignalRecordIds` borrows engine scratch and is invalid
//! after the next propagation, so the model must copy it. And
//! `DirtyRecordQueue.generation` is a visited-set epoch, unrelated to
//! `dirty_signal_generation`; asserting against the wrong one produces a target
//! that passes for the wrong reason.
//!
//! Equality is a Roc-supplied `eq` callable on the value capability, never a
//! memcmp, so the harness must allocate real erased callables for clone, drop,
//! and eq. `engine.zig`'s test "prepared dirty evaluator reads provisional source
//! through derived map" is the closest existing harness and is the intended
//! skeleton to build from.
//!
//! To replay a crash:
//!   python3 scripts/fuzz.py repro propagation <crash-file> --verbose

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
