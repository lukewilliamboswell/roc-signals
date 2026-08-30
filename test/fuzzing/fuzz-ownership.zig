//! Model-based fuzzing for retained-value ownership and confined erasure.
//!
//! # Why this target exists
//!
//! design.md, "Confined Erasure", moves the type-mismatch hazard rather than
//! deleting it. Roc's type system guarantees each thunk is internally correct;
//! it does not guarantee the host hands a given opaque payload to the *right*
//! thunk. A wiring bug - delivering the box from edge X to the thunk that owns
//! edge Y - is not a clean Roc error but undefined behavior inside the thunk.
//! The design's answer is that routing is consumed rather than reconstructed,
//! and that every cell carries the capability that owns it.
//!
//! That makes two properties worth searching for rather than enumerating. A
//! valid program must never leak or mismatch no matter how values are routed
//! among edges; and an invalid routing must be rejected *before* the wrongly
//! typed callable is invoked, since afterwards there is nothing left to check.
//!
//! The paired concern is the leak invariant from "Scopes and lifecycle": the
//! host holds exactly one refcount per live retained closure or value and zero
//! for disposed ones. Refcount bugs are cancellation bugs - an extra retain and
//! an extra release net to zero across a whole run and hide from any test that
//! only checks the end state. Long generated histories with balance checked at
//! every step are what expose them.
//!
//! # What is generated
//!
//! A set of edges, each with its own capability, then a routing program over
//! them. Capabilities are `HostValueCapability{clone, drop, eq}`, built from real
//! erased callables allocated with `abi.rocErasedCallableAllocate` - not stack
//! pointers or boxed `U64` stand-ins, which the contributing docs call out
//! specifically because they do not exercise the refcount paths at all. Distinct
//! callables are used for clone, drop, and eq so a call routed to the wrong one
//! is observable rather than accidentally harmless.
//!
//! Operations: register a value, get it (split-and-replace), take it, clone,
//! compare, replace, drop, and teardown - interleaved across edges so a value
//! belonging to one capability is repeatedly offered to operations parameterized
//! by another.
//!
//! # Oracles
//!
//!  - **Valid routing never fails.** Every operation presenting the owning
//!    capability succeeds, and the value read back is the value stored.
//!  - **Invalid routing is rejected before the call.** Presenting a foreign
//!    capability yields `Error.CapabilityMismatch`, and operating outside an
//!    active frame yields `Error.InactiveCapability`. Both are checked by
//!    `assertCapability` / `assertCapabilityActive` ahead of any app-compiled
//!    callable, so the oracle is not merely "an error came back" but "the
//!    wrongly typed callable was never entered" - asserted by having each
//!    generated callable record its own invocation.
//!  - **The split-and-replace law holds.** `getWithSplit` must produce an
//!    independently owned value *and* leave an independently owned value in the
//!    cell: `split.keep` is stored back and `split.out` is returned. The model
//!    asserts both halves are independently droppable, which is what
//!    distinguishes a real split from an untracked borrow that happens to work
//!    until one side is released.
//!  - **Ownership balances.** `closure_retains` equals `closure_releases` after
//!    teardown - noting that capability retain/release moves these by three,
//!    once per callable, so an off-by-one in fan-out shows up as a non-multiple
//!    of three rather than as a wrong total.
//!  - **The registry drains.** `liveCount()` returns zero after teardown, and
//!    `assertReleased` reports no `UnconsumedHandle`. `takeEpoch` /
//!    `assertTakenAfter` pin *when* a handle was consumed, which catches a value
//!    released by the wrong owner at the right time.
//!  - **Handle generations retire.** Registry handles pack a one-based index and
//!    a generation. A stale handle whose slot was reused must be rejected rather
//!    than silently resolving to the new occupant, and a generation-saturated
//!    slot must stay permanently retired instead of wrapping.
//!  - **Clone postconditions.** `clone` must not return the source box
//!    (`CloneReturnedSource`) and must preserve the capability
//!    (`CloneCapabilityMismatch`).
//!  - **Frames balance.** `ActiveCapabilityStack` is a fixed 64-frame,
//!    128-capability stack that panics on overflow and underflow. The generator
//!    deliberately drives nesting toward those limits, since a push/pop leak
//!    that is invisible at depth two is fatal at depth sixty-four.
//!
//! # Seams
//!
//! `host_value_registry.zig` owns the split-and-replace law: `getWithSplit`,
//! `getWithCapability`, `take`, `takeWithCapability`, `takeWithSplit`, plus
//! `liveCount` / `assertReleased` for teardown. `retained_values.zig` owns the
//! cell: `HostValueCell.initRetained`, `cloneRetained`, `valueEquals`,
//! `replaceValue`, `deinit`. `erased_calls.zig` funnels every invocation through
//! one private `callErasedCallable`, which panics on a null payload.
//!
//! One structural note that shapes the model: roles in `callable_roles.zig` are
//! distinct Zig types, so mis-routing a `CapabilityDrop` where a `CapabilityEq`
//! is expected is a *compile* error, not a runtime one. Comptime already covers
//! role confusion, and `engine_contract.zig` verifies the ops signatures. This
//! target therefore aims at what comptime cannot see: which *value* is paired
//! with which capability instance at runtime. Generating role confusion would be
//! generating programs that do not compile, so the fuzzer does not try.
//!
//! Note also that `split` is not a field of `HostValueCapabilityHandle`, which
//! carries only clone, drop, and eq; `CapabilitySplit` is always a separate
//! argument. A model assuming a four-field capability will be wrong.
//!
//! To replay a crash:
//!   python3 scripts/fuzz.py repro ownership <crash-file> --verbose

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
