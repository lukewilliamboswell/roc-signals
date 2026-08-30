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
//! them. Capabilities are `HostValueCapabilityHandle{clone, drop, eq}` built
//! from real erased callables allocated with `abi.rocErasedCallableAllocate` -
//! not stack pointers or boxed `U64` stand-ins, which do not exercise the
//! refcount paths at all. Each edge additionally owns a `CapabilitySplit`
//! callable, which is a separate argument rather than a fourth capability
//! field. Callables are distinct per edge and per role, and each carries its
//! edge index in its capture, so a call routed to the wrong one is observable
//! rather than accidentally harmless.
//!
//! The values are real Roc boxes holding `{ magic, edge, tag }`. Carrying the
//! owning edge *inside the payload* is what makes mis-routing detectable
//! independently of the bookkeeping under test: every callable checks that the
//! payload it was handed belongs to the edge it was compiled for, so a routing
//! bug is caught even when the capability check that should have prevented it
//! is itself the defect.
//!
//! The split callable frees the box it consumes and returns two freshly
//! allocated halves. That is deliberate. A split that increfs and returns the
//! same pointer twice makes "store `split.keep` back into the cell" invisible,
//! because the stale pointer keeps working. Freeing the input means a cell that
//! kept its old pointer is a use-after-free the debug allocator reports, and a
//! half nobody releases is a leak it reports.
//!
//! Operations: register a value, read it back through a split, read it back
//! through a capability, take it either way, clone it, probe retired handles,
//! re-assert a capability, stress frame nesting, and drive a `HostValueCell`
//! through equality, incoming-drop, clone, and replace before tearing it down.
//! They interleave across edges, so a value belonging to one capability is
//! repeatedly offered to operations parameterized by another.
//!
//! # Oracles
//!
//!  - **Valid routing never fails.** Every operation presenting the owning
//!    capability succeeds, and the payload read back carries the edge and tag
//!    that were stored.
//!  - **Invalid routing is rejected before the call.** Presenting a foreign
//!    capability yields `Error.CapabilityMismatch`, operating outside an active
//!    frame yields `Error.InactiveCapability`, and re-owning a cell yields
//!    `Error.ConflictingCapability`. All are checked by `assertCapability` /
//!    `assertCapabilityActive` ahead of any app-compiled callable, so the
//!    oracle is not merely "an error came back" but "no callable was entered at
//!    all": every callable counts its own invocations, and a refused operation
//!    must not move that total.
//!  - **A refusal changes nothing.** A refused take must leave the take epoch
//!    where it was and the cell still readable through its real owner.
//!  - **The split-and-replace law holds.** `getWithSplit` must produce an
//!    independently owned value *and* leave an independently owned value in the
//!    cell, so the model splits twice in a row and releases both halves.
//!    Because the split frees its input, a cell left holding the pre-split
//!    pointer fails as a use-after-free rather than passing as an untracked
//!    borrow.
//!  - **Ownership balances.** `closure_retains` equals `closure_releases`.
//!    Only `retained_values.zig` moves these counters and it moves them by
//!    three per capability, once per callable, so an off-by-one in fan-out
//!    shows as a non-multiple of three; both facts are asserted, per cell round
//!    trip as well as at the end.
//!  - **Every callable reaches refcount zero.** Teardown requires the number of
//!    generated callables that fell to zero to equal the number allocated. This
//!    is the sharpest refcount oracle: a retain that is never released leaves a
//!    callable alive, which no balance of *counters* would reveal.
//!  - **The registry drains.** `liveCount()` and `hasLiveValues()` report empty
//!    after teardown, and `assertReleased` reports no `UnconsumedHandle` for
//!    any handle the run ever created. `takeEpoch` / `assertTakenAfter` pin
//!    *when* a handle was consumed, which catches a value released by the wrong
//!    owner at the right time.
//!  - **Handle generations retire.** Every handle the run retires is probed
//!    again later: it must be rejected rather than silently resolving to the
//!    new occupant of its slot, and taking it twice must fail.
//!  - **Clone postconditions.** `clone` must not return the source handle, must
//!    preserve the capability, must leave the source readable and unchanged,
//!    and must produce a cell that is independently droppable.
//!  - **Frames balance.** `ActiveCapabilityStack` is a fixed 64-frame,
//!    128-capability stack that panics on overflow and underflow. The generator
//!    drives nesting up to those limits without crossing them, since a
//!    push/pop leak that is invisible at depth two is fatal at depth sixty, and
//!    the program as a whole must end at depth zero.
//!  - **Nothing leaks.** The run allocates through a debug allocator whose
//!    teardown is checked, so every oracle above sits on an allocator that also
//!    reports double frees and use-after-free.
//!
//! # Seams
//!
//! `host_value_registry.zig` owns the split-and-replace law: `getWithSplit`,
//! `getWithCapability`, `take`, `takeWithCapability`, `takeWithSplit`, `clone`,
//! `setCapability`, plus `liveCount` / `assertReleased` for teardown.
//! `retained_values.zig` owns the cell: `HostValueCell.initRetained`,
//! `cloneRetained`, `valueEquals`, `valueEqualsIncoming`, `dropIncoming`,
//! `replaceValue`, `deinit`. `erased_calls.zig` funnels every invocation
//! through one private `callErasedCallable`, which panics on a null payload.
//! `host_values.zig` supplies `RegistryOps` and `ActiveCapabilityStack`, the
//! adapter the real hosts hand the registry, so this target drives the same ops
//! the engine does rather than a stand-in.
//!
//! One structural note that shapes the model: roles in `callable_roles.zig` are
//! distinct Zig types, so mis-routing a `CapabilityDrop` where a `CapabilityEq`
//! is expected is a *compile* error, not a runtime one. Comptime already covers
//! role confusion, and `engine_contract.zig` verifies the ops signatures. This
//! target therefore aims at what comptime cannot see: which *value* is paired
//! with which capability instance at runtime. Generating role confusion would
//! be generating programs that do not compile, so the fuzzer does not try.
//!
//! # Deliberately out of scope
//!
//! Allocation failure. The registry reports `OutOfMemory`, but the callables
//! here allocate through the Roc host, whose out-of-memory path terminates the
//! process by design, so a fault would be indistinguishable from a crash. Fault
//! placement against ownership transitions belongs to the `structural` target,
//! which owns the fault-sweep machinery.
//!
//! `MissingCapability` - a value stored with no capability at all - is not
//! generated. The engine opens and closes that window inside a single
//! store-then-set sequence, so a program that held a value there would be
//! modelling a state the host cannot be in.
//!
//! Generation *saturation*, where a slot's generation reaches `maxInt(u32)` and
//! the slot must retire permanently rather than wrap, is not reachable from
//! generated input: it takes four billion stores into one slot. It is covered
//! by a direct unit test in `host_value_registry.zig`, which can reach in and
//! set the generation. What is reachable here, and is checked, is that ordinary
//! reuse retires the handles that came before it.
//!
//! To replay a crash:
//!   python3 scripts/fuzz.py repro ownership <crash-file> --verbose

const std = @import("std");
const signals = @import("signals");
const FuzzReader = @import("FuzzReader.zig");

const abi = signals.abi;
const hv = signals.host_values;
const erased_calls = signals.erased_calls;
const retained_values = signals.retained_values;
const registry_mod = signals.host_value_registry;
const HostValue = hv.HostValue;
const Capability = hv.HostValueCapabilityHandle;
const CapabilitySplit = signals.callable_roles.CapabilitySplit;
const RegistryError = registry_mod.Error;
const Registry = registry_mod.Registry(Capability);
const RegistryOps = hv.RegistryOps();
const RuntimeMetrics = signals.engine_metrics.RuntimeMetrics;
const HostValueCell = retained_values.HostValueCell;

/// Edges a program may route among. Two is the minimum for a foreign
/// capability to exist at all; four gives the generator room to present a
/// capability that is neither the owner's nor the one used a moment ago.
const max_edges: u8 = 4;
/// Operations one program runs. Long enough for a per-step imbalance to
/// compound before teardown, short enough to stay fast under AFL++.
const max_ops: u8 = 32;
/// Live registry handles the model tracks. Past this the generator stops
/// storing rather than growing, so a program cannot spend itself on stores.
const max_live: u8 = 16;
/// Retired handles kept for stale-generation probes.
const max_retired: u8 = 48;
/// Frames the nesting stress may hold at once. `ActiveCapabilityStack` panics
/// at 64 frames, and panicking is its documented contract, so the generator
/// drives up to the limit without crossing it.
const max_stress_frames: usize = 60;

/// Marks a live payload. A callable handed a box whose magic is wrong is
/// looking at freed or foreign memory, which is exactly the failure this target
/// exists to make loud rather than silent.
const payload_magic: u64 = 0x4f574e5f56414c31;

/// The boxed value an edge owns. `edge` travels in the payload so a callable
/// can check what it was handed against the edge it was built for, without
/// consulting the bookkeeping under test.
const Payload = extern struct {
    magic: u64,
    edge: u64,
    tag: u64,
};

/// Capture handed to every generated callable: which world it belongs to and
/// which edge it speaks for.
const CallableCapture = extern struct {
    world: usize,
    edge: u64,
};

/// Roles a generated callable plays, counted separately so an assertion can
/// name the callable a mis-route entered.
const Role = enum(u8) { clone, drop, eq, split };

const role_count = @typeInfo(Role).@"enum".fields.len;

/// One generated operation. Indices are reduced modulo the live set at
/// execution time, so a decoded program stays valid however far the model has
/// shrunk since the operation was drawn.
const Op = struct {
    kind: Kind,
    /// The live handle this operation targets, before reduction.
    target: u8,
    /// The edge whose capability this operation presents.
    presented_edge: u8,
    /// A second live handle, for equality comparisons.
    other: u8,
    tag: u8,
    /// Which optional stages a cell round trip performs.
    flags: u8,
    depth: u8,

    const Kind = enum(u8) {
        register,
        get_with_split,
        get_without_frame,
        get_with_capability,
        take_with_capability,
        take_with_split,
        clone,
        cell_round_trip,
        stale_probe,
        reassert_capability,
        frame_stress,
    };
};

const Program = struct {
    edge_count: u8,
    op_count: u8,
    ops: [max_ops]Op,

    fn opsSlice(self: *const Program) []const Op {
        return self.ops[0..self.op_count];
    }
};

/// A registry handle the model believes is live, and what it should contain.
const Live = struct {
    value: HostValue,
    edge: u8,
    tag: u64,
};

const Edge = struct {
    cap: Capability,
    split: CapabilitySplit,
};

/// Fixed-capacity list used for the model's live and retired sets.
///
/// Both sets are bounded by design - the generator refuses to grow past them
/// rather than allocating - so a capacity-checked array keeps the model itself
/// free of allocation failures the oracles would then have to reason about.
fn Bounded(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        items: [capacity]T = undefined,
        len: usize = 0,

        fn append(self: *Self, item: T) void {
            if (self.len == capacity) @panic("fuzz model exceeded its own bound");
            self.items[self.len] = item;
            self.len += 1;
        }

        /// Appends while the list has room, and otherwise drops the item.
        fn appendIfRoom(self: *Self, item: T) void {
            if (self.len == capacity) return;
            self.append(item);
        }

        fn get(self: *const Self, index: usize) T {
            return self.items[index];
        }

        fn slice(self: *const Self) []const T {
            return self.items[0..self.len];
        }

        fn swapRemove(self: *Self, index: usize) void {
            self.len -= 1;
            self.items[index] = self.items[self.len];
        }
    };
}

/// Everything one run owns. Callables reach it through their capture, which is
/// how an app-compiled thunk reaches host state in the real hosts too.
const World = struct {
    gpa: std.mem.Allocator,
    roc_host: *abi.RocHost,
    registry: Registry,
    active: hv.ActiveCapabilityStack,
    metrics: RuntimeMetrics,

    edges: [max_edges]Edge,
    edge_count: u8,

    /// Invocations of each generated callable, by edge and role. A refused
    /// operation must leave every entry untouched.
    entries: [max_edges][role_count]u64,
    /// Generated callables whose refcount reached zero. Teardown requires one
    /// per callable the run allocated.
    callable_drops: u64,

    live: Bounded(Live, max_live),
    retired: Bounded(HostValue, max_retired),

    fn ops(self: *World) RegistryOps {
        return .{ .roc_host = self.roc_host, .active_capabilities = &self.active };
    }

    fn totalEntries(self: *const World) u64 {
        var total: u64 = 0;
        for (self.entries[0..self.edge_count]) |edge| {
            for (edge) |count| total += count;
        }
        return total;
    }

    fn recordEntry(self: *World, edge: u64, role: Role) void {
        self.entries[@intCast(edge)][@intFromEnum(role)] += 1;
    }

    /// Records a handle the run has finished with, so later probes can require
    /// the registry to keep rejecting it.
    ///
    /// The list is bounded and silently stops growing: it exists to give the
    /// stale-generation oracle material, not to be an exhaustive ledger.
    fn retire(self: *World, value: HostValue) void {
        self.retired.appendIfRoom(value);
    }
};

/// Context `retained_values.zig` calls back into for capability frames and
/// value cloning. The real hosts supply the same three operations.
const CellCtx = struct {
    world: *World,

    /// Pushes the capability frame that authorizes an erased call's arguments.
    pub fn pushHostValueCapabilities(self: CellCtx, caps: []const Capability) void {
        self.world.active.push(caps);
    }

    /// Pops the frame opened for a completed erased call.
    pub fn popHostValueCapabilities(self: CellCtx) void {
        self.world.active.pop();
    }

    /// Clones an opaque value through the capability that owns it.
    pub fn cloneHostValue(self: CellCtx, value: HostValue) HostValue {
        return self.world.registry.clone(self.world.gpa, value, self.world.ops()) catch |err|
            std.debug.panic("cloning a cell's own value failed: {s}", .{@errorName(err)});
    }
};

/// AFL++ persistent-mode initialization hook; every run builds its own world.
pub export fn zig_fuzz_init() void {}

/// AFL++ persistent-mode entry point.
pub export fn zig_fuzz_test(buf: [*]u8, len: isize) void {
    zig_fuzz_test_inner(buf, len, false);
}

/// Runs one fuzz input, printing the generated program when `debug` is set.
pub fn zig_fuzz_test_inner(buf: [*]u8, len: isize, debug: bool) void {
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer if (gpa_impl.deinit() == .leak) @panic("ownership fuzz target leaked memory");
    const gpa = gpa_impl.allocator();

    var reader = FuzzReader.init(buf[0..@intCast(len)]);
    const program = generateProgram(&reader);
    if (debug) printProgram(program);

    var env = abi.RocEnv{ .allocator = gpa, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&env);

    var world = World{
        .gpa = gpa,
        .roc_host = &roc_host,
        .registry = .{},
        .active = .{},
        .metrics = signals.engine_metrics.zeroRuntimeMetrics(),
        .edges = undefined,
        .edge_count = program.edge_count,
        .entries = std.mem.zeroes([max_edges][role_count]u64),
        .callable_drops = 0,
        .live = .{},
        .retired = .{},
    };
    defer world.registry.deinit(gpa);

    for (0..program.edge_count) |index| world.edges[index] = makeEdge(&world, index);

    for (program.opsSlice()) |op| runOp(&world, op);
    if (world.active.hasActiveFrame()) @panic("the program left a capability frame open");
    if (world.active.capability_len != 0) @panic("the program left capabilities on the active stack");
    teardown(&world, debug);
}

// ---------------------------------------------------------------------------
// Generation
// ---------------------------------------------------------------------------

/// Decodes one byte string into a routing program over a set of edges.
///
/// The first operation is always a store. Every other kind needs a live value
/// to route, so spending fuzzer entropy on rediscovering that would waste it.
fn generateProgram(reader: *FuzzReader) Program {
    var program = Program{
        .edge_count = reader.intRangeAtMost(u8, 2, max_edges),
        .op_count = 1,
        .ops = undefined,
    };

    program.ops[0] = .{
        .kind = .register,
        .target = 0,
        .presented_edge = reader.readByte(),
        .other = 0,
        .tag = reader.readByte(),
        .flags = 0,
        .depth = 0,
    };

    const extra = reader.intRangeAtMost(u8, 0, max_ops - 1);
    while (program.op_count < extra + 1) {
        program.ops[program.op_count] = .{
            .kind = @enumFromInt(reader.intRangeLessThan(u8, 0, @typeInfo(Op.Kind).@"enum".fields.len)),
            .target = reader.readByte(),
            .presented_edge = reader.readByte(),
            .other = reader.readByte(),
            .tag = reader.readByte(),
            .flags = reader.readByte(),
            .depth = reader.readByte(),
        };
        program.op_count += 1;
    }

    return program;
}

fn printProgram(program: Program) void {
    std.debug.print("edges: {d}, operations: {d}\n", .{ program.edge_count, program.op_count });
    for (program.opsSlice(), 0..) |op, index| {
        std.debug.print(
            "  {d:>3}: {s} target={d} edge={d} other={d} tag={d} flags=0x{x:0>2} depth={d}\n",
            .{ index, @tagName(op.kind), op.target, op.presented_edge, op.other, op.tag, op.flags, op.depth },
        );
    }
}

// ---------------------------------------------------------------------------
// Edges, boxes, and the generated callables
// ---------------------------------------------------------------------------

fn makeEdge(world: *World, edge: usize) Edge {
    return .{
        .cap = .{
            .clone = allocateCallable(world, edge, &cloneCallable),
            .drop = allocateCallable(world, edge, &dropCallable),
            .eq = allocateCallable(world, edge, &eqCallable),
        },
        .split = CapabilitySplit.fromAbi(allocateCallable(world, edge, &splitCallable)),
    };
}

/// Allocates one real erased callable with an inline capture naming its edge.
///
/// These go through `abi.rocErasedCallableAllocate` rather than pointing at
/// stack memory precisely so that `increfErasedCallable` and
/// `decrefErasedCallable` operate on a real refcount, which is the path the
/// capability retain/release oracles depend on.
fn allocateCallable(world: *World, edge: usize, callable_fn: abi.RocErasedCallableFn) abi.RocErasedCallable {
    const callable = abi.rocErasedCallableAllocate(world.roc_host, callable_fn, null, @sizeOf(CallableCapture));
    capturePtr(abi.rocErasedCallableCapturePtr(callable)).* = .{
        .world = @intFromPtr(world),
        .edge = edge,
    };
    return callable;
}

fn capturePtr(capture: ?[*]u8) *CallableCapture {
    return @ptrCast(@alignCast(capture orelse @panic("a generated callable was invoked without its capture")));
}

fn argsAs(comptime T: type, args: ?[*]const u8) *align(1) const T {
    return @ptrCast(args orelse @panic("a generated callable was invoked without arguments"));
}

fn writeResult(comptime T: type, ret: ?[*]u8, value: T) void {
    @as(*align(1) T, @ptrCast(ret orelse @panic("a generated callable was invoked without a result slot"))).* = value;
}

fn allocatePayload(world: *World, edge: u8, tag: u64) abi.RocBox {
    const box: *Payload = @ptrCast(@alignCast(abi.allocateBox(@sizeOf(Payload), @alignOf(Payload), false, world.roc_host)));
    box.* = .{ .magic = payload_magic, .edge = edge, .tag = tag };
    return @ptrCast(box);
}

fn readPayload(box: abi.RocBox) Payload {
    const payload: *const Payload = @ptrCast(@alignCast(box orelse @panic("the registry produced a null box")));
    if (payload.magic != payload_magic) @panic("the registry produced a box that is not a live payload");
    return payload.*;
}

fn freeBox(world: *World, box: abi.RocBox) void {
    abi.decrefBox(box, world.roc_host);
}

/// Checks that a callable was handed a payload belonging to its own edge.
///
/// This states confined erasure at the payload rather than at the handle, so it
/// still holds when the capability check that should have prevented the
/// mis-route is itself the defect.
fn assertOwnedPayload(payload: Payload, edge: u64, role: Role) void {
    if (payload.edge != edge) std.debug.panic(
        "edge {d}'s {s} callable was handed a payload owned by edge {d}",
        .{ edge, @tagName(role), payload.edge },
    );
}

/// Checks that the frame authorizing this call really names this edge.
fn assertEdgeIsActive(world: *World, edge: u64, role: Role) void {
    if (!world.active.contains(world.edges[@intCast(edge)].cap)) std.debug.panic(
        "edge {d}'s {s} callable ran without its capability in an active frame",
        .{ edge, @tagName(role) },
    );
}

/// Splits one box into two independently owned halves.
///
/// The input allocation is freed rather than aliased, so a caller that keeps
/// the pre-split pointer commits a use-after-free the allocator reports rather
/// than a borrow that happens to keep working.
fn splitCallable(_: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const cap = capturePtr(capture);
    const world: *World = @ptrFromInt(cap.world);
    const call_args = argsAs(erased_calls.ErasedRocBoxUnaryArgs, args);

    const payload = readPayload(call_args.arg0);
    assertOwnedPayload(payload, cap.edge, .split);
    world.recordEntry(cap.edge, .split);

    const keep = allocatePayload(world, @intCast(payload.edge), payload.tag);
    const out = allocatePayload(world, @intCast(payload.edge), payload.tag);
    freeBox(world, call_args.arg0);

    writeResult(erased_calls.RocBoxPair, ret, .{ .keep = keep, .out = out });
}

/// Clones a retained value the way the native host does: take an independently
/// owned half through the split, then store it under the source's capability.
fn cloneCallable(_: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const cap = capturePtr(capture);
    const world: *World = @ptrFromInt(cap.world);
    const call_args = argsAs(erased_calls.ErasedHostValueUnaryArgs, args);
    const value = HostValue.fromRaw(call_args.arg0);

    assertEdgeIsActive(world, cap.edge, .clone);
    world.recordEntry(cap.edge, .clone);

    const box = world.registry.getWithSplit(value, world.edges[@intCast(cap.edge)].split, world.ops()) catch |err|
        std.debug.panic("clone could not split its own value: {s}", .{@errorName(err)});
    assertOwnedPayload(readPayload(box), cap.edge, .clone);

    const cloned = world.registry.storeRetainedExistingCapability(world.gpa, box, value, world.ops()) catch |err|
        std.debug.panic("clone could not store its result: {s}", .{@errorName(err)});
    writeResult(HostValue, ret, cloned);
}

/// Releases a retained value along with the registry cell holding it.
fn dropCallable(_: *abi.RocHost, _: ?[*]u8, args: ?[*]const u8, capture: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const cap = capturePtr(capture);
    const world: *World = @ptrFromInt(cap.world);
    const call_args = argsAs(erased_calls.ErasedHostValueUnaryArgs, args);
    const value = HostValue.fromRaw(call_args.arg0);

    assertEdgeIsActive(world, cap.edge, .drop);
    world.recordEntry(cap.edge, .drop);

    const box = world.registry.take(value, world.ops()) catch |err|
        std.debug.panic("drop could not take its own value: {s}", .{@errorName(err)});
    assertOwnedPayload(readPayload(box), cap.edge, .drop);
    freeBox(world, box);
    world.retire(value);
}

/// Compares two retained values through the left value's capability.
///
/// Only the left operand belongs to this edge. The right one arrives from
/// whatever cell is being compared against, so its payload is read but never
/// claimed as this edge's.
fn eqCallable(_: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const cap = capturePtr(capture);
    const world: *World = @ptrFromInt(cap.world);
    const call_args = argsAs(erased_calls.ErasedHostValueBinaryArgs, args);

    assertEdgeIsActive(world, cap.edge, .eq);
    world.recordEntry(cap.edge, .eq);

    const left = peekPayload(world, HostValue.fromRaw(call_args.arg0));
    assertOwnedPayload(left, cap.edge, .eq);
    const right = peekPayload(world, HostValue.fromRaw(call_args.arg1));

    writeResult(bool, ret, left.edge == right.edge and left.tag == right.tag);
}

/// Reads a value's payload without consuming the cell, through the split-and-
/// replace law: the produced half is released here and the kept half stays.
fn peekPayload(world: *World, value: HostValue) Payload {
    const owner = (world.registry.capability(value) catch |err|
        std.debug.panic("a comparison operand had no resolvable capability: {s}", .{@errorName(err)})) orelse
        @panic("a comparison operand carried no capability");

    const box = world.registry.getWithSplit(value, splitForCapability(world, owner), world.ops()) catch |err|
        std.debug.panic("a comparison operand could not be split: {s}", .{@errorName(err)});
    defer freeBox(world, box);
    return readPayload(box);
}

fn splitForCapability(world: *World, cap: Capability) CapabilitySplit {
    for (world.edges[0..world.edge_count]) |edge| {
        if (hv.hostValueCapabilitiesMatch(edge.cap, cap)) return edge.split;
    }
    @panic("a registry cell carried a capability no edge owns");
}

/// Releases one generated callable, counting the release that frees it.
///
/// The count is taken here rather than in an `on_drop` hook because a hook
/// receives its own capture while the callable is mid-free, and reading the
/// world pointer back out of memory that is being torn down is exactly the kind
/// of aliasing this target is supposed to detect rather than commit.
fn releaseCallable(world: *World, callable: abi.RocErasedCallable) void {
    if (refcountOf(callable) == 1) world.callable_drops += 1;
    abi.decrefErasedCallable(callable, world.roc_host);
}

fn refcountOf(callable: abi.RocErasedCallable) isize {
    const data = callable orelse return 0;
    const rc: *const isize = @ptrFromInt(@intFromPtr(data) - @sizeOf(isize));
    return rc.*;
}

// ---------------------------------------------------------------------------
// Execution
// ---------------------------------------------------------------------------

fn runOp(world: *World, op: Op) void {
    switch (op.kind) {
        .register => runRegister(world, op),
        .get_with_split => runGetWithSplit(world, op),
        .get_without_frame => runGetWithoutFrame(world, op),
        .get_with_capability => runGetWithCapability(world, op),
        .take_with_capability => runTakeWithCapability(world, op),
        .take_with_split => runTakeWithSplit(world, op),
        .clone => runClone(world, op),
        .cell_round_trip => runCellRoundTrip(world, op),
        .stale_probe => runStaleProbe(world),
        .reassert_capability => runReassertCapability(world, op),
        .frame_stress => runFrameStress(world, op),
    }
}

fn edgeIndex(world: *const World, raw: u8) u8 {
    return raw % world.edge_count;
}

/// Picks a live handle, or reports that the model holds none.
fn liveIndex(world: *const World, raw: u8) ?usize {
    if (world.live.len == 0) return null;
    return raw % world.live.len;
}

fn registerValue(world: *World, edge: u8, tag: u64) HostValue {
    const box = allocatePayload(world, edge, tag);
    return world.registry.storeRetainedCapability(world.gpa, box, world.edges[edge].cap, world.ops()) catch |err|
        std.debug.panic("storing a value with its own capability failed: {s}", .{@errorName(err)});
}

fn runRegister(world: *World, op: Op) void {
    if (world.live.len == max_live) return;
    const edge = edgeIndex(world, op.presented_edge);
    const tag: u64 = op.tag;
    const value = registerValue(world, edge, tag);

    // A freshly stored value must report exactly the capability it was given,
    // and refuse every other edge's before any callable could see it.
    world.registry.assertCapability(value, world.edges[edge].cap, world.ops()) catch |err|
        std.debug.panic("a value rejected the capability it was stored with: {s}", .{@errorName(err)});
    assertForeignCapabilitiesRejected(world, value, edge);

    world.live.append(.{ .value = value, .edge = edge, .tag = tag });
}

fn assertForeignCapabilitiesRejected(world: *World, value: HostValue, owner: u8) void {
    for (0..world.edge_count) |candidate| {
        if (candidate == owner) continue;
        const before = world.totalEntries();
        const result = world.registry.assertCapability(value, world.edges[candidate].cap, world.ops());
        expectError(result, RegistryError.CapabilityMismatch, "assertCapability with a foreign capability");
        if (world.totalEntries() != before) @panic("a refused capability check still entered a callable");
    }
}

/// Reads a value back inside a frame naming some edge's capability.
///
/// The owning edge must succeed and hand back the stored payload twice running,
/// which is the split-and-replace law; any other edge must be refused before
/// the split callable runs.
fn runGetWithSplit(world: *World, op: Op) void {
    const index = liveIndex(world, op.target) orelse return;
    const live = world.live.get(index);
    const presented = edgeIndex(world, op.presented_edge);

    const caps = [_]Capability{world.edges[presented].cap};
    world.active.push(&caps);
    defer world.active.pop();

    const before = world.totalEntries();
    const result = world.registry.getWithSplit(live.value, world.edges[presented].split, world.ops());
    if (presented != live.edge) {
        expectError(result, RegistryError.InactiveCapability, "getWithSplit under a foreign frame");
        if (world.totalEntries() != before) @panic("a refused split-get still entered a callable");
        return;
    }

    const box = result catch |err|
        std.debug.panic("split-get through the owning capability failed: {s}", .{@errorName(err)});
    assertPayloadMatches(readPayload(box), live, "split-get");
    freeBox(world, box);

    // The law's other half: the cell must still hold an independently owned
    // value, so an immediate second split must succeed the same way.
    const again = world.registry.getWithSplit(live.value, world.edges[presented].split, world.ops()) catch |err|
        std.debug.panic("a cell did not survive its own split: {s}", .{@errorName(err)});
    assertPayloadMatches(readPayload(again), live, "second split-get");
    freeBox(world, again);
}

/// Outside any frame no capability is active, so every split-get is refused.
fn runGetWithoutFrame(world: *World, op: Op) void {
    const index = liveIndex(world, op.target) orelse return;
    const live = world.live.get(index);
    if (world.active.hasActiveFrame()) @panic("a previous operation leaked a capability frame");

    const before = world.totalEntries();
    const result = world.registry.getWithSplit(live.value, world.edges[live.edge].split, world.ops());
    expectError(result, RegistryError.InactiveCapability, "getWithSplit outside any frame");
    if (world.totalEntries() != before) @panic("a frameless split-get still entered a callable");
}

/// Reads a value back by presenting a capability rather than a frame.
///
/// This path clones and then takes, so a success also proves the clone
/// postconditions: the intermediate cell existed, held the same payload, and
/// drained.
fn runGetWithCapability(world: *World, op: Op) void {
    const index = liveIndex(world, op.target) orelse return;
    const live = world.live.get(index);
    const presented = edgeIndex(world, op.presented_edge);

    const before = world.totalEntries();
    const result = world.registry.getWithCapability(world.gpa, live.value, world.edges[presented].cap, world.ops());
    if (presented == live.edge) {
        const box = result catch |err|
            std.debug.panic("get through the owning capability failed: {s}", .{@errorName(err)});
        assertPayloadMatches(readPayload(box), live, "capability get");
        freeBox(world, box);
    } else {
        expectError(result, RegistryError.CapabilityMismatch, "getWithCapability with a foreign capability");
        if (world.totalEntries() != before) @panic("a refused capability get still entered a callable");
    }
}

/// Consumes a value by presenting a capability.
///
/// A successful take must move the registry's take epoch past the handle and
/// leave `assertReleased` satisfied. A refused one must leave the epoch and the
/// cell exactly as they were, which the model proves by reading the cell again
/// through its real owner.
fn runTakeWithCapability(world: *World, op: Op) void {
    const index = liveIndex(world, op.target) orelse return;
    const live = world.live.get(index);
    const presented = edgeIndex(world, op.presented_edge);

    const epoch = world.registry.takeEpoch();
    const before = world.totalEntries();
    const result = world.registry.takeWithCapability(live.value, world.edges[presented].cap, world.ops());
    if (presented == live.edge) {
        const box = result catch |err|
            std.debug.panic("take through the owning capability failed: {s}", .{@errorName(err)});
        assertPayloadMatches(readPayload(box), live, "capability take");
        freeBox(world, box);
        assertConsumed(world, live.value, epoch);
        removeLive(world, index);
    } else {
        expectError(result, RegistryError.CapabilityMismatch, "takeWithCapability with a foreign capability");
        if (world.totalEntries() != before) @panic("a refused capability take still entered a callable");
        if (world.registry.takeEpoch() != epoch) @panic("a refused take advanced the registry take epoch");
        world.registry.assertCapability(live.value, world.edges[live.edge].cap, world.ops()) catch |err|
            std.debug.panic("a refused take disturbed the cell it refused: {s}", .{@errorName(err)});
    }
}

/// Consumes a value from inside a frame, the shape a capability thunk uses.
fn runTakeWithSplit(world: *World, op: Op) void {
    const index = liveIndex(world, op.target) orelse return;
    const live = world.live.get(index);
    const presented = edgeIndex(world, op.presented_edge);

    const caps = [_]Capability{world.edges[presented].cap};
    world.active.push(&caps);
    defer world.active.pop();

    const epoch = world.registry.takeEpoch();
    const result = world.registry.takeWithSplit(live.value, world.edges[presented].split, world.ops());
    if (presented == live.edge) {
        const box = result catch |err|
            std.debug.panic("take through an active frame failed: {s}", .{@errorName(err)});
        assertPayloadMatches(readPayload(box), live, "split take");
        freeBox(world, box);
        assertConsumed(world, live.value, epoch);
        removeLive(world, index);
    } else {
        expectError(result, RegistryError.InactiveCapability, "takeWithSplit under a foreign frame");
        if (world.registry.takeEpoch() != epoch) @panic("a refused take advanced the registry take epoch");
    }
}

/// A consumed handle must be reported released, and pinned to *this* take.
fn assertConsumed(world: *World, value: HostValue, epoch: u64) void {
    world.registry.assertReleased(value) catch |err|
        std.debug.panic("a consumed handle was not reported released: {s}", .{@errorName(err)});
    world.registry.assertTakenAfter(value, epoch) catch |err|
        std.debug.panic("a consumed handle was not taken during its own operation: {s}", .{@errorName(err)});
    world.retire(value);
}

/// Clones a value and checks that the clone is a second, equal, independently
/// owned cell rather than the source under another name.
fn runClone(world: *World, op: Op) void {
    if (world.live.len == max_live) return;
    const index = liveIndex(world, op.target) orelse return;
    const live = world.live.get(index);

    const cloned = world.registry.clone(world.gpa, live.value, world.ops()) catch |err|
        std.debug.panic("cloning an owned value failed: {s}", .{@errorName(err)});
    if (cloned == live.value) @panic("clone returned the source handle");

    world.registry.assertCapability(cloned, world.edges[live.edge].cap, world.ops()) catch |err|
        std.debug.panic("a clone did not inherit its source's capability: {s}", .{@errorName(err)});

    // The source must be untouched: still readable, and still holding what it
    // held before the clone.
    const caps = [_]Capability{world.edges[live.edge].cap};
    world.active.push(&caps);
    const box = world.registry.getWithSplit(live.value, world.edges[live.edge].split, world.ops()) catch |err|
        std.debug.panic("a cloned source became unreadable: {s}", .{@errorName(err)});
    world.active.pop();
    assertPayloadMatches(readPayload(box), live, "cloned source");
    freeBox(world, box);

    world.live.append(.{ .value = cloned, .edge = live.edge, .tag = live.tag });
}

/// Drives one `HostValueCell` through the operations `retained_values.zig`
/// exposes, then tears it down.
///
/// The cell takes over the targeted handle, so every stage below consumes or
/// replaces registry ownership rather than borrowing it, and the sequence as a
/// whole must leave the closure counters balanced and moving per callable.
fn runCellRoundTrip(world: *World, op: Op) void {
    const index = liveIndex(world, op.target) orelse return;
    const live = world.live.get(index);
    removeLive(world, index);

    const ctx = CellCtx{ .world = world };
    const retains_before = world.metrics.closure_retains;
    const releases_before = world.metrics.closure_releases;

    var cell = HostValueCell.initRetained(live.value, world.edges[live.edge].cap, &world.metrics);

    if (op.flags & 1 != 0) assertCellEquality(world, &cell, live, op);
    if (op.flags & 2 != 0) assertCellDropsIncoming(world, &cell, live, op);
    if (op.flags & 4 != 0) assertCellClones(world, &cell);
    if (op.flags & 8 != 0) replaceCellValue(world, &cell, live, op);

    cell.deinit(ctx, world.roc_host, &world.metrics);

    const retains = world.metrics.closure_retains - retains_before;
    const releases = world.metrics.closure_releases - releases_before;
    if (retains != releases) std.debug.panic(
        "a cell round trip retained {d} closures and released {d}",
        .{ retains, releases },
    );
    // Capability retain and release move the counters once per callable, so a
    // fan-out that lost or gained a callable shows as a non-multiple of three
    // even when the two totals still agree.
    if (retains % 3 != 0) std.debug.panic("closure retains moved by {d}, which is not per-callable", .{retains});
}

/// Equality must agree with the model: same edge and tag, or not equal.
fn assertCellEquality(world: *World, cell: *HostValueCell, live: Live, op: Op) void {
    const other_index = liveIndex(world, op.other) orelse return;
    const other = world.live.get(other_index);
    const ctx = CellCtx{ .world = world };

    const expected = other.edge == live.edge and other.tag == live.tag;
    // A comparison against a value from another edge needs that edge's
    // capability in the frame too, or the operand could not be read at all.
    const actual = if (other.edge == live.edge)
        cell.valueEquals(ctx, world.roc_host, other.value)
    else
        cell.valueEqualsIncoming(ctx, world.roc_host, other.value, world.edges[other.edge].cap);
    if (actual != expected) std.debug.panic(
        "capability equality said {} for a pair the model calls {}",
        .{ actual, expected },
    );
}

/// An incoming value the cell refuses must be released through the cell's own
/// capability, draining its registry cell and leaving the cell itself alone.
fn assertCellDropsIncoming(world: *World, cell: *HostValueCell, live: Live, op: Op) void {
    const ctx = CellCtx{ .world = world };
    const incoming = registerValue(world, live.edge, op.tag);
    const before = world.registry.liveCount();

    cell.dropIncoming(ctx, world.roc_host, incoming);

    if (world.registry.liveCount() + 1 != before) @panic("dropping an incoming value did not drain its registry cell");
    world.registry.assertReleased(incoming) catch |err|
        std.debug.panic("a dropped incoming value kept its registry cell: {s}", .{@errorName(err)});
}

/// A cloned cell is a second owner: it holds its own value and its own
/// capability reference, and tearing it down must not disturb the original.
fn assertCellClones(world: *World, cell: *HostValueCell) void {
    const ctx = CellCtx{ .world = world };
    var cloned = cell.cloneRetained(ctx, &world.metrics);
    if (cloned.value == cell.value) @panic("a cloned cell shares the original's handle");
    if (!cloned.valueEquals(ctx, world.roc_host, cell.value)) @panic("a cloned cell is not equal to its source");

    cloned.deinit(ctx, world.roc_host, &world.metrics);

    if (!cell.valueEquals(ctx, world.roc_host, cell.value)) @panic("tearing down a clone disturbed its source");
}

/// Replacing a cell's value must release the displaced one exactly once.
fn replaceCellValue(world: *World, cell: *HostValueCell, live: Live, op: Op) void {
    const ctx = CellCtx{ .world = world };
    const displaced = cell.value;
    const replacement = registerValue(world, live.edge, op.tag);

    cell.replaceValue(ctx, world.roc_host, replacement);

    if (cell.value != replacement) @panic("replaceValue did not adopt the incoming value");
    world.registry.assertReleased(displaced) catch |err|
        std.debug.panic("a displaced cell value kept its registry cell: {s}", .{@errorName(err)});
}

/// Every handle the run has retired must stay retired.
///
/// Slots are reused, so a handle whose generation stopped being checked would
/// resolve to whatever now occupies its index. The oracle is that resolution
/// *fails*, not merely that the value read back differs.
fn runStaleProbe(world: *World) void {
    for (world.retired.slice()) |stale| {
        if (world.registry.capability(stale)) |_| {
            @panic("a retired handle resolved to a live registry cell");
        } else |_| {}

        const before = world.totalEntries();
        if (world.registry.take(stale, world.ops())) |_| {
            @panic("a retired handle was taken a second time");
        } else |_| {}
        if (world.totalEntries() != before) @panic("a refused stale take still entered a callable");
    }
}

/// Re-asserting a capability on a cell that already owns one.
///
/// The owner's own capability is a no-op that must not take a second reference;
/// any other must be refused as `ConflictingCapability` rather than quietly
/// re-owning the cell under different operations.
fn runReassertCapability(world: *World, op: Op) void {
    const index = liveIndex(world, op.target) orelse return;
    const live = world.live.get(index);
    const presented = edgeIndex(world, op.presented_edge);

    const result = world.registry.setCapability(live.value, world.edges[presented].cap, world.ops());
    if (presented == live.edge) {
        result catch |err| std.debug.panic("a cell rejected its own capability: {s}", .{@errorName(err)});
    } else {
        expectError(result, RegistryError.ConflictingCapability, "setCapability with a foreign capability");
    }
}

/// Drives the fixed capability stack toward its documented limits.
///
/// Sixty frames is deliberate: a push/pop leak that is invisible at depth two
/// is fatal at depth sixty, and the stack panics past sixty-four, so the
/// generator stops one step short rather than asserting on a panic.
fn runFrameStress(world: *World, op: Op) void {
    const base_frames = world.active.frame_len;
    const base_capabilities = world.active.capability_len;
    const requested = op.depth % max_stress_frames;

    var pushed: usize = 0;
    while (pushed < requested and world.active.frame_len < max_stress_frames) : (pushed += 1) {
        const edge = edgeIndex(world, @intCast(pushed % world.edge_count));
        const caps = [_]Capability{world.edges[edge].cap};
        world.active.push(&caps);
        if (!world.active.hasActiveFrame()) @panic("the capability stack reported no frame after a push");
        if (!world.active.contains(world.edges[edge].cap)) @panic("a pushed capability is not active");
    }

    for (0..pushed) |_| world.active.pop();
    if (world.active.frame_len != base_frames) @panic("capability frames did not unwind to their starting depth");
    if (world.active.capability_len != base_capabilities) @panic("capabilities outlived the frames that pushed them");
}

fn assertPayloadMatches(payload: Payload, live: Live, what: []const u8) void {
    if (payload.edge != live.edge or payload.tag != live.tag) std.debug.panic(
        "{s} produced edge {d} tag {d} where the model stored edge {d} tag {d}",
        .{ what, payload.edge, payload.tag, live.edge, live.tag },
    );
}

fn removeLive(world: *World, index: usize) void {
    world.live.swapRemove(index);
}

fn expectError(result: anytype, expected: RegistryError, what: []const u8) void {
    if (result) |_| {
        std.debug.panic("{s} succeeded where {s} was required", .{ what, @errorName(expected) });
    } else |err| if (err != expected) std.debug.panic(
        "{s} failed with {s} rather than {s}",
        .{ what, @errorName(err), @errorName(expected) },
    );
}

// ---------------------------------------------------------------------------
// Teardown
// ---------------------------------------------------------------------------

/// Drains the world and checks every end-state invariant.
fn teardown(world: *World, debug: bool) void {
    while (world.live.len != 0) {
        const index = world.live.len - 1;
        const live = world.live.get(index);
        removeLive(world, index);
        const box = world.registry.takeWithCapability(live.value, world.edges[live.edge].cap, world.ops()) catch |err|
            std.debug.panic("teardown could not take a live value: {s}", .{@errorName(err)});
        assertPayloadMatches(readPayload(box), live, "teardown take");
        freeBox(world, box);
        world.retire(live.value);
    }

    if (world.registry.liveCount() != 0) @panic("the registry still owns values after teardown");
    if (world.registry.hasLiveValues()) @panic("the registry reports live values after teardown");

    for (world.retired.slice()) |value| {
        world.registry.assertReleased(value) catch |err| switch (err) {
            // A slot whose generation has moved on reports the handle released
            // under a different name; only an unconsumed handle is a leak.
            RegistryError.ReleasedHandle, RegistryError.InvalidHandle => {},
            else => std.debug.panic("a handle survived teardown: {s}", .{@errorName(err)}),
        };
    }

    for (world.edges[0..world.edge_count]) |edge| {
        releaseCallable(world, edge.cap.clone);
        releaseCallable(world, edge.cap.drop);
        releaseCallable(world, edge.cap.eq);
        releaseCallable(world, edge.split.toAbi());
    }

    const expected_drops = @as(u64, world.edge_count) * role_count;
    if (world.callable_drops != expected_drops) std.debug.panic(
        "{d} of {d} generated callables reached refcount zero",
        .{ world.callable_drops, expected_drops },
    );

    if (world.metrics.closure_retains != world.metrics.closure_releases) std.debug.panic(
        "closure retains {d} does not equal closure releases {d}",
        .{ world.metrics.closure_retains, world.metrics.closure_releases },
    );

    if (debug) std.debug.print(
        "callable entries: {d}, closure retains/releases: {d}, callables freed: {d}\n",
        .{ world.totalEntries(), world.metrics.closure_retains, world.callable_drops },
    );
}
