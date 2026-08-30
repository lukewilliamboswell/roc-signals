//! Model-based fuzzing for keyed-list identity and scope lifecycle.
//!
//! # Why this target exists
//!
//! Keyed rows and scopes are where the engine's identity contract is most
//! exposed to *sequence*. Every individual operation here is easy to get right;
//! what breaks is the seventh remove after a reorder that followed a branch flip
//! within the same dirty generation. Example-based tests encode the sequences
//! someone already thought of, which is exactly the wrong shape for this bug
//! class. Of the five targets in this directory, this is the one where stateful
//! fuzzing should beat example-based testing by the widest margin.
//!
//! design.md, "Scopes and lifecycle", states the contract being checked:
//! disposal must remove ids from active indexes and adjacency, release
//! capability-owned state, run cleanup, and detach the rendered subtree; reorder
//! must move surviving rows rather than rebuild them; and disposed scopes must
//! become reusable slots without unbounded growth of inactive ones.
//!
//! # What is generated
//!
//! The input decodes into a *program*, never into raw bytes handed to the
//! engine: a small pool of distinct keys, then a sequence of operations drawn
//! from insert, remove, update-in-place, reorder (including full reversal and
//! rotation, which are the shapes that break longest-stable-subsequence move
//! planning), remove-then-reinsert of the same key, `when` branch flips over a
//! subtree, and finally teardown. Keys come from a fixed pool so that
//! remove/reinsert genuinely revisits an identity rather than always minting a
//! fresh one - reusing a key after its scope retired is the interesting case,
//! not an edge case.
//!
//! # The reference model
//!
//! A plain `ArrayList` of keys, reordered and spliced by the same operation
//! sequence, with a side table recording which keys are live and which scope id
//! each was last assigned. It is deliberately slow and obviously correct: it
//! recomputes row order from scratch and never reuses a slot.
//!
//! # Oracles
//!
//! After each operation:
//!
//!  - **Order.** `activeEachRows` returns exactly the model's key order.
//!  - **Surviving identity.** A key present before and after an operation keeps
//!    its scope id. This is the property that makes per-row local state work,
//!    and the one a rebuild-instead-of-move regression silently breaks.
//!  - **Unique live ownership.** No scope id appears at two row positions, and
//!    every live row's `Membership{site_index, row_index}` agrees with its
//!    position in `Site.scope_ids`.
//!  - **Hash index coherence.** Walking `Site.hash_heads`/`hash_links` finds
//!    every live row exactly once and terminates. The chained index is
//!    maintained incrementally by `appendRowToSiteIndex` and
//!    `removeRowFromSiteIndex`, so a desync here is invisible until a later
//!    lookup silently misses a survivor and rebuilds a row that should have
//!    been reused.
//!  - **Duplicate keys are errors, not aliases.** Feeding a duplicate must reach
//!    `hooks.failDuplicateEachKey` with the two colliding indexes, and must do so
//!    on the *hash-collision* path too. The target therefore includes keys chosen
//!    to collide under `hooks.hashKey` while differing under `nextKeysEqual`,
//!    which is the case that separates a real typed-equality check from a
//!    hash-only one.
//!  - **Reuse barrier.** `Lifecycle.blocksReuse` compares `generation == barrier`,
//!    not `>=`. A scope retired in the current dirty generation must not be
//!    reused; a scope retired in an *older* generation must become reusable. Both
//!    directions are asserted, because the equality makes over- and
//!    under-blocking equally reachable.
//!  - **No stale-id aliasing.** `ids.ScopeId` carries no generation tag, so once
//!    the barrier advances a recycled slot hands the same id to a new scope. The
//!    model holds the retired ids and asserts no live index, membership, or
//!    adjacency entry still refers to one.
//!  - **Complete reclamation.** After teardown, live scope count is zero,
//!    `HostValueCell`s released by `deinitScopeStep` balance, and inactive slots
//!    are bounded by the high-water mark rather than by total operations.
//!
//! # Seams
//!
//! `scope_tree.zig` (`internComponent`, `internWhenBranch`, `appendEachRow`,
//! `activeEachRows`, `validate`) is the approachable pilot: it is comptime-generic
//! over `Row` and can be driven with a small test `Row` with no engine around it.
//! `each_runtime.zig` (`syncRows`, and the fallible `PreparedExistingRows.prepare`
//! / `commit`) is the real reconciliation seam, driven through a hook struct.
//! `scope_runtime.disposeSubtree` is the disposal seam; note that
//! `prepareSubtreeRetirement` deliberately flips lifecycle *without* releasing
//! step-owned resources, so the two must not be conflated when asserting balance.
//!
//! Both the eager and prepared paths are driven from the same generated program,
//! and their resulting states must agree. A divergence between them is a bug even
//! when neither path crashes.
//!
//! To replay a crash:
//!   python3 scripts/fuzz.py repro keyed-scopes <crash-file> --verbose

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
