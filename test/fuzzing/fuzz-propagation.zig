//! Model-based fuzzing for signal propagation and scheduling.
//!
//! # Why this target exists
//!
//! design.md, "Propagation algorithm (push-based, glitch-free, value-pruned)",
//! specifies four steps: set the source, collect its dependents in topological
//! rank order, recompute in that order, and stop where the recomputed value is
//! `is_eq` to the cached one. Rank ordering is what makes a diamond (`a->b`,
//! `a->c`, `(b,c)->d`) recompute `d` exactly once after both `b` and `c` settle.
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
//!     nodes, which makes acyclicity structural rather than checked. Inputs are
//!     drawn uniformly from every earlier node, so wide fan-out, diamonds, long
//!     chains, and shared subexpressions all fall out of small graphs.
//!  2. **Transforms.** Identity, addition, parity, saturating counters, and -
//!     load-bearing - transforms that map distinct inputs onto equal outputs
//!     (`bucket`, and the binary `left`/`right` projections that ignore one
//!     input entirely), so equality cutoffs fire mid-graph instead of only at
//!     the leaves. Values live in a small modular range, which makes accidental
//!     collisions common as well as deliberate ones.
//!  3. **Updates.** Batches of one or more simultaneously dirty sources, since a
//!     single dirty source cannot expose a glitch. The same batch is also
//!     replayed on a second engine with the sources listed in the opposite
//!     order: rank ordering means the result must not depend on that order, and
//!     a dependence on it is precisely the glitch this design forbids.
//!
//! # The reference model
//!
//! A deliberately slow evaluator: after each batch it recomputes every node in
//! emission order from the source values, with no caching and no pruning. It is
//! quadratic and obviously correct, which is the point - it shares no code with
//! the engine, so agreement is evidence rather than a tautology. From the same
//! walk it also derives the forward-reachable set of the batch's roots, which
//! node values actually moved, and therefore exactly how many transform calls
//! and how many equality cutoffs a correct engine must perform.
//!
//! # Oracles
//!
//! Because the model knows every node's value before and after a batch, most of
//! these are exact equalities rather than bounds. A bound would let a wrong
//! engine pass by doing less work than the budget; an equality does not.
//!
//!  - **Value agreement.** Every cached node equals the reference result,
//!    read through `Record.cachedSlot`.
//!  - **The dirty set is the reachable set, in rank order.** The ids
//!    `DirtyRecordQueue.collectForRoots` produces must be exactly the model's
//!    forward closure of the roots, with non-decreasing rank and no repeats.
//!    Duplicates are what a broken visited-set epoch produces, and they are
//!    invisible to any value oracle because a second evaluation is memoized.
//!  - **The changed set is exactly the set that moved.** The record ids
//!    `propagateDirtyActiveSignalRecordIds` returns must be the closure members
//!    whose value differs from the previous batch, in the order they appeared
//!    in the dirty list. Reporting a node as changed when it is not is how a
//!    missing cutoff escapes into the render layer.
//!  - **One evaluation per generation, counted exactly.**
//!    `derived_calls_into_roc` must grow by exactly the number of derived nodes
//!    in the closure with at least one changed input. Larger means a node was
//!    evaluated twice or a pruned subgraph was walked anyway; smaller means a
//!    node that should have recomputed did not. This subsumes the weaker "at
//!    most the reachable set" budget and is what makes the diamond's single
//!    recomputation of `d` an assertion rather than an aspiration.
//!  - **Cutoffs prune, counted exactly.** `propagation_prunes` must grow by
//!    exactly the number of recomputed nodes whose new value equalled the
//!    cached one, plus the batch's source updates that were equal to what the
//!    source already held. Because the derived-call count is an equality too,
//!    a prune that still recursed would fail there.
//!  - **Generation stamps.** Every closure member carries
//!    `last_dirty_generation` equal to this batch's generation, and every
//!    record stamped with it - closure member or input pulled in from outside -
//!    carries the `last_dirty_changed` the model predicts.
//!  - **Order independence.** A second engine replaying the same batches with
//!    each batch's dirty sources reversed must hold identical values and
//!    identical counters, and produce the same changed set once rank ties are
//!    normalized away by sorting.
//!  - **Determinism.** A third engine replaying the whole input from scratch
//!    must end with identical values and identical counters, which is what AFL++
//!    stability depends on.
//!  - **Nothing leaks.** Every engine runs on its own safety-checked debug
//!    allocator, which also backs the `RocEnv` the erased callables allocate
//!    from, so an unbalanced retain on a value capability is a run failure.
//!
//! # Seams
//!
//! The graph is built directly out of `signal_records.Record` values and
//! registered with `active_signal_graph.appendNode` / `appendDependentId`, then
//! driven through the engine's own scheduler and evaluator:
//! `DirtyRecordQueue.collectForRoots` -> `propagateDirtyActiveSignalRecordIds`
//! -> `evalDirtyHostSignalRecord`. Sources are dirtied the way
//! `PreparedSourceTransaction.prepareRoots` dirties them - `updateDirtySignalCache`
//! for the equality cutoff at the source, then `rememberDirtySignalResult` to
//! stamp the generation - so a source handed the value it already holds is
//! pruned and never becomes a root.
//!
//! Two traps for whoever maintains this. The slice returned by
//! `propagateDirtyActiveSignalRecordIds` borrows engine scratch and is invalid
//! after the next propagation, as is the one `collectForRoots` returns, so both
//! are copied before anything else runs. And `DirtyRecordQueue.generation` is a
//! visited-set epoch, unrelated to `dirty_signal_generation`; asserting against
//! the wrong one produces a target that passes for the wrong reason.
//!
//! Equality is a Roc-supplied `eq` callable on the value capability, never a
//! memcmp, so the harness allocates real erased callables for clone, drop, and
//! eq through `abi.rocErasedCallableAllocate`, and one more per derived node to
//! carry that node's transform and its operand in the callable's capture.
//! `engine.zig`'s test "prepared dirty evaluator reads provisional source
//! through derived map" is the closest existing harness and is the skeleton
//! this was built from.
//!
//! # Not covered
//!
//! The production path is transactional: `PreparedSourceTransaction.prepare` /
//! `prepareMany` -> `prepareRoots` -> `prepareChangedActiveSignalRecordIds`,
//! then `commitPreparedDirtySignalCaches`. Every one of those declarations is
//! file-private to `engine.zig`, so a fuzz target cannot reach them except by
//! mounting a real element tree - which needs `Elem`-level signal-expression
//! fixtures the native host does not expose. The overlay's abort-leaves-no-trace
//! property therefore stays covered only by `engine.zig`'s own tests, and this
//! target asserts the evaluator and scheduler that both paths share. Making
//! `prepareChangedActiveSignalRecordIds` and `commitPreparedDirtySignalCaches`
//! public would let the transactional half be driven here too.
//!
//! State `ref` records are also absent: resolving one needs a live host state
//! table, and the propagation properties above do not depend on where a source
//! value comes from.
//!
//! To replay a crash:
//!   python3 scripts/fuzz.py repro propagation <crash-file> --verbose

const std = @import("std");
const signals = @import("signals");
const FuzzReader = @import("FuzzReader.zig");

const abi = signals.abi;
const active_graph = signals.active_signal_graph;
const roles = signals.callable_roles;
const signal_records = signals.signal_records;
const erased_calls = signals.erased_calls;
const render = signals.render;

const HostValue = signals.host_values.HostValue;
const HostValueCapability = signals.retained_values.HostValueCapability;
const HostValueCell = signals.retained_values.HostValueCell;
const HostValueList = signals.retained_values.HostValueList;
const Record = signal_records.Record;
const Engine = signals.engine.Engine(FuzzCtx);

/// Nodes one generated graph may hold. Small graphs are the interesting ones:
/// every extra node dilutes the chance that a diamond's two arms land on the
/// same consumer, which is the shape the schedule has to get right.
const max_nodes = 20;
const max_sources = 5;
const max_batches = 6;
/// Children one `combine` node reads. Three is enough for a node whose inputs
/// change in different batches while a third never moves.
const max_combine_children = 3;
/// Values live in `1..value_modulus` so that transforms collide often and
/// equality cutoffs fire without the generator having to aim for them.
const value_modulus: u64 = 8;

// ---------------------------------------------------------------------------
// The generated program
// ---------------------------------------------------------------------------

/// What a `map` node computes. `bucket` is the load-bearing one: it maps
/// several distinct inputs onto one output, so a changed input reaches it and
/// stops there.
const UnaryOp = enum(u8) {
    identity,
    add,
    parity,
    saturating_counter,
    bucket,
};

/// What a `map2` node computes. `left` and `right` ignore one input entirely,
/// which is the sharpest cutoff shape available: a batch that dirties only the
/// ignored side must prune at this node and evaluate nothing beyond it.
const BinaryOp = enum(u8) {
    sum,
    difference,
    max,
    left,
    right,
};

/// What a `combine` node computes over its child list.
const CombineOp = enum(u8) {
    sum,
    max,
    count,
    first,
};

const NodeKind = enum(u8) { source, map, map2, combine };

const Node = struct {
    kind: NodeKind,
    /// Inputs, in the order the record reads them. Empty for a source.
    inputs: []const u8,
    unary: UnaryOp = .identity,
    binary: BinaryOp = .sum,
    combine: CombineOp = .sum,
    /// Second argument of `add`, `saturating_counter`, and `bucket`.
    operand: u64 = 0,
    /// Longest path from a source, which is the rank the active graph carries.
    rank: u64 = 0,
};

/// One update: the sources it dirties and the value each is handed.
const Batch = struct {
    sources: []const u8,
    values: []const u64,
};

const Program = struct {
    nodes: []const Node,
    source_count: usize,
    /// Value every source starts at, indexed by source node id.
    initial: []const u64,
    batches: []const Batch,
};

/// The transform's identity, handed to its erased callable through the
/// callable capture so the engine asks the generated program what a node
/// computes without the harness knowing when it will be asked.
const TransformCapture = extern struct {
    op: u8,
    operand: u64,
};

// ---------------------------------------------------------------------------
// The transforms, shared by the callables and the reference model
// ---------------------------------------------------------------------------

/// Wraps a computed result back into the generated value range.
///
/// Values are stored one above their logical value because `HostValue.invalid`
/// is zero, and a cache slot holding the invalid handle would be
/// indistinguishable from an uninitialized one.
fn encode(logical: u64) HostValue {
    return HostValue.fromRaw(@mod(logical, value_modulus) + 1);
}

fn decode(value: HostValue) u64 {
    return value.toRaw() - 1;
}

fn applyUnary(op: UnaryOp, operand: u64, input: u64) u64 {
    return switch (op) {
        .identity => input,
        .add => input + operand,
        .parity => input & 1,
        .saturating_counter => @min(input + 1, operand),
        .bucket => input / (operand + 1),
    };
}

fn applyBinary(op: BinaryOp, operand: u64, left: u64, right: u64) u64 {
    return switch (op) {
        .sum => left + right + operand,
        .difference => (left + value_modulus - @mod(right, value_modulus)) + operand,
        .max => @max(left, right),
        .left => left,
        .right => right,
    };
}

fn applyCombine(op: CombineOp, operand: u64, inputs: []const u64) u64 {
    return switch (op) {
        .sum => blk: {
            var total: u64 = operand;
            for (inputs) |input| total += input;
            break :blk total;
        },
        .max => blk: {
            var largest: u64 = 0;
            for (inputs) |input| largest = @max(largest, input);
            break :blk largest;
        },
        .count => inputs.len,
        .first => if (inputs.len == 0) operand else inputs[0],
    };
}

// ---------------------------------------------------------------------------
// The reference model
// ---------------------------------------------------------------------------

/// A whole-graph evaluation: every node's value recomputed from the sources
/// with no caching and no pruning.
const Values = struct {
    items: [max_nodes]u64 = @splat(0),
};

/// What one batch must do to the engine, derived from the graph and the model's
/// before and after values alone.
const Expected = struct {
    /// Forward closure of the batch's roots, including the roots.
    reachable: [max_nodes]bool = @splat(false),
    /// Nodes whose value moved. Only closure members can move.
    changed: [max_nodes]bool = @splat(false),
    /// Nodes the engine must hand to Roc: closure members with a changed input.
    derived_calls: u64 = 0,
    /// Recomputed nodes whose result equalled the cache, plus source updates
    /// that were equal to what the source already held.
    prunes: u64 = 0,
    /// True when every source in the batch was pruned, so no propagation runs.
    idle: bool = false,
};

/// Recomputes every node from `sources`, which holds one logical value per
/// source node id.
fn evaluate(program: Program, sources: []const u64) Values {
    var values = Values{};
    var inputs: [max_combine_children]u64 = undefined;
    for (program.nodes, 0..) |node, index| {
        values.items[index] = switch (node.kind) {
            .source => @mod(sources[index], value_modulus),
            .map => @mod(applyUnary(node.unary, node.operand, values.items[node.inputs[0]]), value_modulus),
            .map2 => @mod(applyBinary(node.binary, node.operand, values.items[node.inputs[0]], values.items[node.inputs[1]]), value_modulus),
            .combine => blk: {
                for (node.inputs, 0..) |input, slot| inputs[slot] = values.items[input];
                break :blk @mod(applyCombine(node.combine, node.operand, inputs[0..node.inputs.len]), value_modulus);
            },
        };
    }
    return values;
}

/// Derives everything a correct engine must do for one batch.
///
/// The closure is grown forward from the roots by scanning nodes in emission
/// order, which is a topological order, so one pass reaches every dependent.
fn expectationsFor(program: Program, update: Batch, before: Values, after: Values) Expected {
    var expected = Expected{};
    var roots: usize = 0;
    for (update.sources, update.values) |source, value| {
        if (@mod(value, value_modulus) == before.items[source]) {
            expected.prunes += 1;
            continue;
        }
        expected.reachable[source] = true;
        roots += 1;
    }
    if (roots == 0) {
        expected.idle = true;
        return expected;
    }

    for (program.nodes, 0..) |node, index| {
        for (node.inputs) |input| {
            if (expected.reachable[input]) expected.reachable[index] = true;
        }
    }

    for (program.nodes, 0..) |node, index| {
        if (!expected.reachable[index]) continue;
        expected.changed[index] = after.items[index] != before.items[index];
        if (node.kind == .source) continue;
        var input_changed = false;
        for (node.inputs) |input| {
            if (after.items[input] != before.items[input]) input_changed = true;
        }
        if (!input_changed) continue;
        expected.derived_calls += 1;
        if (!expected.changed[index]) expected.prunes += 1;
    }
    return expected;
}

// ---------------------------------------------------------------------------
// The engine context
// ---------------------------------------------------------------------------

/// Render sink for an engine that publishes nothing. Propagation never reaches
/// the render layer here because no descriptor is bound to any record, but the
/// engine's context contract still requires the whole sink surface.
const FuzzSink = struct {
    /// Stages a complete render-surface reset in the host command sink.
    pub fn reset(_: FuzzSink) void {}
    /// Emits the already-decided command that attaches a newly created render node.
    pub fn appendNode(_: FuzzSink, _: signals.ids.ElemId, _: signals.ids.ElemId, _: []const u8) void {}
    /// Ensures the host render surface contains the engine-selected node and tag.
    pub fn ensureNode(_: FuzzSink, _: signals.ids.ElemId, _: []const u8) void {}
    /// Emits removal of a node whose owning scope has already been disposed by the engine.
    pub fn removeNode(_: FuzzSink, _: signals.ids.ElemId) void {}
    /// Publishes the engine-selected child order for one parent.
    pub fn replaceChildren(_: FuzzSink, _: signals.ids.ElemId, _: []const signals.ids.ElemId) void {}
    /// Publishes a moves-only child reorder without rebuilding surviving row structure.
    pub fn replaceChildrenForMoves(_: FuzzSink, _: signals.ids.ElemId, _: []const signals.ids.ElemId) void {}
    /// Applies an engine-decided text field value to one render node.
    pub fn applyTextField(_: FuzzSink, _: signals.ids.ElemId, _: render.TextField, _: []const u8) void {}
    /// Applies an engine-decided custom text attribute to one render node.
    pub fn applyTextAttr(_: FuzzSink, _: signals.ids.ElemId, _: []const u8, _: []const u8) void {}
    /// Applies an engine-decided boolean field value to one render node.
    pub fn applyBoolField(_: FuzzSink, _: signals.ids.ElemId, _: render.BoolField, _: bool) void {}
    /// Clears an engine-decided text field from one render node.
    pub fn clearTextField(_: FuzzSink, _: signals.ids.ElemId, _: render.TextField) void {}
    /// Clears an engine-decided custom text attribute from one render node.
    pub fn clearTextAttr(_: FuzzSink, _: signals.ids.ElemId, _: []const u8) void {}
    /// Clears an engine-decided boolean field from one render node.
    pub fn clearBoolField(_: FuzzSink, _: signals.ids.ElemId, _: render.BoolField) void {}
    /// Publishes a validated canonical event binding selected by the engine.
    pub fn bindEvent(_: FuzzSink, _: signals.ids.ElemId, _: signals.render_sink.EventBindingKey, _: signals.render_sink.EventBinding) void {}
    /// Removes a host event registration whose engine-owned binding is no longer active.
    pub fn clearEvent(_: FuzzSink, _: signals.ids.ElemId, _: signals.render_sink.EventBindingKey) void {}
    /// Starts the bounded host registration for an engine-owned interval source.
    pub fn startInterval(_: FuzzSink, _: signals.ids.IntervalToken, _: u64) void {}
    /// Cancels the host registration for an interval whose owning scope is no longer active.
    pub fn cancelInterval(_: FuzzSink, _: signals.ids.IntervalToken) void {}
    /// Starts bounded asynchronous host work for an engine-issued task request.
    pub fn startTask(_: FuzzSink, _: signals.ids.TaskRequestId, _: []const u8, _: []const u8) void {}
    /// Cancels host work for a task request retired by engine lifecycle policy.
    pub fn cancelTask(_: FuzzSink, _: signals.ids.TaskRequestId) void {}
    /// Applies an engine-issued storage write without deriving storage semantics.
    pub fn setStorageText(_: FuzzSink, _: signals.boundary.StorageArea, _: []const u8, _: []const u8) void {}
    /// Applies an engine-issued storage removal without deriving storage semantics.
    pub fn removeStorage(_: FuzzSink, _: signals.boundary.StorageArea, _: []const u8) void {}
    /// Applies an engine-issued browser-history command without deriving routing semantics.
    pub fn navigate(_: FuzzSink, _: signals.render_sink.NavigationKind, _: signals.boundary.LocationSnapshot) void {}
    /// Applies the document title already selected by graph propagation.
    pub fn setDocumentTitle(_: FuzzSink, _: []const u8) void {}
    /// Checks that the host render surface matches the engine's committed node metadata.
    pub fn debugAssertNode(_: FuzzSink, _: signals.ids.ElemId, _: bool, _: ?[]const u8, _: ?signals.ids.ElemId, _: []const signals.ids.ElemId, _: ?signals.ids.EventId, _: ?signals.ids.EventId, _: ?signals.ids.EventId, _: ?signals.ids.EventId, _: ?signals.ids.EventId, _: ?signals.ids.EventId, _: ?signals.ids.EventId) void {}
};

/// Per-run host state the engine reaches through `FuzzCtx`.
const FuzzHost = struct {
    allocator: std.mem.Allocator,
    render_batch: render.TransactionalBatch = .{},

    /// Produces an independently owned copy through the value's app-compiled capability.
    pub fn cloneHostValue(_: *FuzzHost, value: HostValue) HostValue {
        return value;
    }

    /// Opens a checked capability frame for an app-compiled erased call.
    pub fn pushHostValueCapabilities(_: *FuzzHost, _: []const HostValueCapability) void {}

    /// Closes the current capability frame after an app-compiled erased call.
    pub fn popHostValueCapabilities(_: *FuzzHost) void {}
};

/// Minimal engine context: an allocator, a render sink that discards, and
/// identity value cloning.
///
/// Values are plain integers rather than registry handles, so a clone is the
/// value itself and a drop is a call into a real erased callable that does
/// nothing. That keeps every capability edge honest - retains and releases are
/// still counted and still routed through Roc - without a registry this target
/// has no use for.
const FuzzCtx = struct {
    pub const Handle = *FuzzHost;
    pub const RegistryOps = signals.host_values.RegistryOps();
    pub const Metrics = signals.engine.RuntimeMetrics;
    pub const Sink = FuzzSink;

    /// Creates the host's zeroed metric accumulator for a new engine operation.
    pub fn zeroMetrics() Metrics {
        return signals.engine.zeroRuntimeMetrics();
    }

    /// Returns the allocator owned by this host context for shared-engine work.
    pub fn allocator(ctx: Handle) std.mem.Allocator {
        return ctx.allocator;
    }

    /// Returns the reusable unpublished/published render command bank.
    pub fn renderCommandBatch(ctx: Handle) *render.TransactionalBatch {
        return &ctx.render_batch;
    }

    /// Produces an independently owned copy through the value's app-compiled capability.
    pub fn cloneHostValue(_: Handle, value: HostValue) HostValue {
        return value;
    }

    /// Opens a checked capability frame for an app-compiled erased call.
    pub fn pushHostValueCapabilities(_: Handle, _: []const HostValueCapability) void {}

    /// Closes the current capability frame after an app-compiled erased call.
    pub fn popHostValueCapabilities(_: Handle) void {}

    /// Resolves a state cell by dense node id without scanning the signal graph.
    pub fn stateValueByNodeId(_: Handle, _: u64) HostValue {
        return .invalid;
    }

    /// Returns the exact app-compiled capability that owns the requested state cell.
    pub fn stateCapability(_: Handle, _: u64) HostValueCapability {
        return std.mem.zeroes(HostValueCapability);
    }

    /// Materializes the mount-time browser location through the source's owning capability.
    pub fn initialLocationPayload(_: Handle, _: *abi.RocHost, _: HostValueCapability) HostValue {
        return .invalid;
    }

    /// Returns the thin render-command sink used by the shared engine.
    pub fn sink(_: Handle) Sink {
        return .{};
    }
};

// ---------------------------------------------------------------------------
// The erased callables the capability and the transforms are made of
// ---------------------------------------------------------------------------

fn cloneCallable(_: *abi.RocHost, result: ?[*]u8, args: ?[*]const u8, _: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const input: *align(1) const erased_calls.ErasedHostValueUnaryArgs = @ptrCast(args orelse unreachable);
    const out: *align(1) HostValue = @ptrCast(result orelse unreachable);
    out.* = HostValue.fromRaw(input.arg0);
}

fn dropCallable(_: *abi.RocHost, _: ?[*]u8, _: ?[*]const u8, _: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {}

fn eqCallable(_: *abi.RocHost, result: ?[*]u8, args: ?[*]const u8, _: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const input: *align(1) const erased_calls.ErasedHostValueBinaryArgs = @ptrCast(args orelse unreachable);
    (result orelse unreachable)[0] = @intFromBool(input.arg0 == input.arg1);
}

fn unaryTransformCallable(_: *abi.RocHost, result: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const capture: *const TransformCapture = @ptrCast(@alignCast(capture_ptr orelse unreachable));
    const input: *align(1) const erased_calls.ErasedHostValueUnaryArgs = @ptrCast(args orelse unreachable);
    const out: *align(1) HostValue = @ptrCast(result orelse unreachable);
    out.* = encode(applyUnary(@enumFromInt(capture.op), capture.operand, decode(HostValue.fromRaw(input.arg0))));
}

fn binaryTransformCallable(_: *abi.RocHost, result: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const capture: *const TransformCapture = @ptrCast(@alignCast(capture_ptr orelse unreachable));
    const input: *align(1) const erased_calls.ErasedHostValueBinaryArgs = @ptrCast(args orelse unreachable);
    const out: *align(1) HostValue = @ptrCast(result orelse unreachable);
    const left = decode(HostValue.fromRaw(input.arg0));
    const right = decode(HostValue.fromRaw(input.arg1));
    out.* = encode(applyBinary(@enumFromInt(capture.op), capture.operand, left, right));
}

/// Reads the child list a `combine` node is handed, releasing the reference the
/// engine transferred with the call.
fn combineTransformCallable(roc_host: *abi.RocHost, result: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const capture: *const TransformCapture = @ptrCast(@alignCast(capture_ptr orelse unreachable));
    const input: *align(1) const erased_calls.ErasedHostValueListUnaryArgs = @ptrCast(args orelse unreachable);
    const list: HostValueList = input.arg0;
    var inputs: [max_combine_children]u64 = undefined;
    const items = list.items();
    for (items, 0..) |item, index| inputs[index] = decode(item);
    const out: *align(1) HostValue = @ptrCast(result orelse unreachable);
    out.* = encode(applyCombine(@enumFromInt(capture.op), capture.operand, inputs[0..items.len]));
    list.decref(roc_host);
}

/// Allocates one erased callable carrying `capture`.
fn allocateTransform(roc_host: *abi.RocHost, function: abi.RocErasedCallableFn, capture: TransformCapture) abi.RocErasedCallable {
    const callable = abi.rocErasedCallableAllocate(roc_host, function, null, @sizeOf(TransformCapture));
    const slot: *TransformCapture = @ptrCast(@alignCast(abi.rocErasedCallableCapturePtr(callable)));
    slot.* = capture;
    return callable;
}

// ---------------------------------------------------------------------------
// One engine under test
// ---------------------------------------------------------------------------

/// The order a batch's dirty sources are handed to the engine. Rank ordering
/// means the outcome must not depend on it.
const Order = enum { generated, reversed };

/// What one batch did to one engine, kept so two engines can be compared.
const Outcome = struct {
    dirty: [max_nodes]u64 = @splat(0),
    dirty_len: usize = 0,
    changed: [max_nodes]u64 = @splat(0),
    changed_len: usize = 0,
    derived_calls: u64 = 0,
    prunes: u64 = 0,
};

/// A complete engine plus the graph mounted in it: records, capability, and
/// one transform callable per derived node.
///
/// Everything except the arena-owned program lives on this harness's own debug
/// allocator, including the `RocEnv` the erased callables allocate from, so a
/// leaked capability edge or a leaked scratch buffer fails the run rather than
/// escaping into the next input.
const Harness = struct {
    program: Program,
    order: Order,
    gpa: std.heap.DebugAllocator(.{}),
    env: abi.RocEnv,
    roc_host: abi.RocHost,
    host: FuzzHost,
    engine: Engine,
    records: []Record,
    transforms: []abi.RocErasedCallable,
    clone: abi.RocErasedCallable,
    drop: abi.RocErasedCallable,
    eq: abi.RocErasedCallable,
    cap: HostValueCapability,
    generation: u64,

    /// Mounts `program` in a fresh engine with every cache holding its initial
    /// value, which is the state a real graph is in after collection.
    fn init(self: *Harness, arena: std.mem.Allocator, program: Program, order: Order) void {
        self.program = program;
        self.order = order;
        self.gpa = .{};
        self.generation = 0;
        const gpa = self.gpa.allocator();
        self.env = .{ .allocator = gpa, .roc_io = abi.RocIo.default() };
        self.roc_host = abi.makeRocHost(&self.env);
        self.host = .{ .allocator = gpa };
        self.engine = Engine.init();

        self.clone = abi.rocErasedCallableAllocate(&self.roc_host, cloneCallable, null, 0).?;
        self.drop = abi.rocErasedCallableAllocate(&self.roc_host, dropCallable, null, 0).?;
        self.eq = abi.rocErasedCallableAllocate(&self.roc_host, eqCallable, null, 0).?;
        self.cap = .{ .clone = self.clone, .drop = self.drop, .eq = self.eq };

        self.records = arena.alloc(Record, program.nodes.len) catch fail("harness arena exhausted", .{});
        self.transforms = arena.alloc(abi.RocErasedCallable, program.nodes.len) catch fail("harness arena exhausted", .{});

        const values = evaluate(program, program.initial);
        for (program.nodes, 0..) |node, index| {
            self.transforms[index] = null;
            const initial_cache = signal_records.CacheSlot{
                .present = HostValueCell.initRetained(encode(values.items[index]), self.cap, &self.engine.pending_roc_metrics),
            };
            self.records[index] = .{ .ref_count = 1, .payload = switch (node.kind) {
                .source => .{ .interval_source = .{
                    .period_ms = 1,
                    .initial = .fromAbi(self.clone),
                    .tick = .fromAbi(self.clone),
                    .cap = self.cap,
                    .cached_value = initial_cache,
                } },
                .map => blk: {
                    self.transforms[index] = allocateTransform(&self.roc_host, unaryTransformCallable, .{ .op = @intFromEnum(node.unary), .operand = node.operand });
                    break :blk .{ .map = .{
                        .input = &self.records[node.inputs[0]],
                        .transform = .fromAbi(self.transforms[index]),
                        .cap = self.cap,
                        .cached_value = initial_cache,
                    } };
                },
                .map2 => blk: {
                    self.transforms[index] = allocateTransform(&self.roc_host, binaryTransformCallable, .{ .op = @intFromEnum(node.binary), .operand = node.operand });
                    break :blk .{ .map2 = .{
                        .left = &self.records[node.inputs[0]],
                        .right = &self.records[node.inputs[1]],
                        .transform = .fromAbi(self.transforms[index]),
                        .cap = self.cap,
                        .cached_value = initial_cache,
                    } };
                },
                .combine => blk: {
                    const vector = arena.alloc(*Record, node.inputs.len) catch fail("harness arena exhausted", .{});
                    for (node.inputs, vector) |input, *child| child.* = &self.records[input];
                    self.transforms[index] = allocateTransform(&self.roc_host, combineTransformCallable, .{ .op = @intFromEnum(node.combine), .operand = node.operand });
                    break :blk .{ .combine = .{
                        .children = vector,
                        .transform = .fromAbi(self.transforms[index]),
                        .cap = self.cap,
                        .cached_value = initial_cache,
                    } };
                },
            } };
        }

        for (program.nodes, 0..) |node, index| {
            _ = active_graph.appendNode(Record, gpa, &self.engine.active_signal_graph, &self.records[index], node.rank);
        }
        for (program.nodes, 0..) |node, index| {
            for (node.inputs) |input| {
                active_graph.appendDependentId(Record, gpa, self.engine.active_signal_graph.items, input, @intCast(index));
            }
        }
    }

    /// Releases every cache, graph buffer, and erased callable, then reports a
    /// leak as a run failure.
    fn deinit(self: *Harness) void {
        const gpa = self.gpa.allocator();
        for (self.records) |*record| {
            record.cachedSlot().?.deinit(&self.host, &self.roc_host, &self.engine.pending_roc_metrics);
        }
        for (self.engine.active_signal_graph.items) |node| gpa.free(node.dependents);
        self.engine.active_signal_graph.deinit(gpa);
        self.engine.scratch.deinit(gpa);
        self.engine.render_cache.deinit(&self.host);
        self.host.render_batch.deinit(gpa);
        for (self.transforms) |callable| abi.decrefErasedCallable(callable, &self.roc_host);
        abi.decrefErasedCallable(self.clone, &self.roc_host);
        abi.decrefErasedCallable(self.drop, &self.roc_host);
        abi.decrefErasedCallable(self.eq, &self.roc_host);
        if (self.gpa.deinit() == .leak) fail("engine allocator leaked", .{});
    }

    /// Dirties `update`'s sources and propagates, exactly as
    /// `PreparedSourceTransaction.prepareRoots` does: a source handed the value
    /// it already holds is pruned at the source and never becomes a root, and a
    /// batch with no surviving root does not propagate at all.
    fn apply(self: *Harness, update: Batch) Outcome {
        const gpa = self.gpa.allocator();
        const derived_before = self.engine.pending_roc_metrics.derived_calls_into_roc;
        const prunes_before = self.engine.pending_roc_metrics.propagation_prunes;
        const generation = self.generation + 1;

        var roots: [max_sources]u64 = undefined;
        var root_len: usize = 0;
        for (0..update.sources.len) |step| {
            const position = switch (self.order) {
                .generated => step,
                .reversed => update.sources.len - 1 - step,
            };
            const source = update.sources[position];
            const value = encode(update.values[position]);
            const record = &self.records[source];
            const slot = record.cachedSlot().?;
            if (!self.engine.updateDirtySignalCache(&self.host, &self.roc_host, slot, value, self.cap)) continue;
            _ = self.engine.rememberDirtySignalResult(record, generation, .{ .value = value, .changed = true });
            roots[root_len] = source;
            root_len += 1;
        }

        var outcome = Outcome{};
        if (root_len != 0) {
            self.engine.scratch.dirty_active_records.reserveForGraph(Record, gpa, self.engine.active_signal_graph.items) catch {
                fail("reserving the dirty queue for a {d}-node graph failed", .{self.engine.active_signal_graph.items.len});
            };
            // Both slices below borrow engine scratch that the next call
            // overwrites, so each is copied before anything else runs.
            const dirty = self.engine.scratch.dirty_active_records.collectForRoots(Record, gpa, self.engine.active_signal_graph.items, roots[0..root_len]);
            outcome.dirty_len = dirty.len;
            @memcpy(outcome.dirty[0..dirty.len], dirty);
            const changed = self.engine.propagateDirtyActiveSignalRecordIds(&self.host, &self.roc_host, outcome.dirty[0..outcome.dirty_len], &.{}, generation);
            outcome.changed_len = changed.len;
            @memcpy(outcome.changed[0..changed.len], changed);
            self.generation = generation;
            self.engine.dirty_signal_generation = generation;
        }

        outcome.derived_calls = self.engine.pending_roc_metrics.derived_calls_into_roc - derived_before;
        outcome.prunes = self.engine.pending_roc_metrics.propagation_prunes - prunes_before;
        return outcome;
    }

    /// Returns the value the engine has cached for node `index`.
    fn cached(self: *Harness, index: usize) u64 {
        return switch (self.records[index].cachedSlot().?.*) {
            .absent => fail("node {d} lost its cached value", .{index}),
            .present => |cell| decode(cell.value),
        };
    }
};

// ---------------------------------------------------------------------------
// Oracles
// ---------------------------------------------------------------------------

/// Judges one batch on one engine against the model.
fn check(harness: *Harness, program: Program, batch_index: usize, outcome: Outcome, after: Values, expected: Expected) void {
    phase = if (harness.order == .generated) "batch" else "reversed batch";
    batch_number = batch_index;

    for (0..program.nodes.len) |index| {
        if (harness.cached(index) != after.items[index]) {
            fail("node {d} cached {d}, model computed {d}", .{ index, harness.cached(index), after.items[index] });
        }
    }

    if (expected.idle) {
        if (outcome.dirty_len != 0) fail("a batch whose every source was pruned still propagated {d} records", .{outcome.dirty_len});
    } else {
        expectDirtySet(harness, program, outcome, expected);
        expectChangedSet(outcome, expected);
        expectStamps(harness, program, outcome, expected);
    }

    if (outcome.derived_calls != expected.derived_calls) {
        fail("engine called {d} transforms, model requires exactly {d}", .{ outcome.derived_calls, expected.derived_calls });
    }
    if (outcome.prunes != expected.prunes) {
        fail("engine recorded {d} prunes, model requires exactly {d}", .{ outcome.prunes, expected.prunes });
    }
}

/// Asserts the scheduler produced the forward closure of the roots, each id
/// once, in non-decreasing rank order.
///
/// Rank order is the whole reason a diamond's shared consumer recomputes once;
/// a duplicate id is what a broken visited-set epoch produces, and it is
/// invisible to every value oracle because the second evaluation is memoized.
fn expectDirtySet(harness: *Harness, program: Program, outcome: Outcome, expected: Expected) void {
    var seen: [max_nodes]bool = @splat(false);
    var previous_rank: u64 = 0;
    for (outcome.dirty[0..outcome.dirty_len]) |record_id| {
        const index: usize = @intCast(record_id);
        if (index >= program.nodes.len) fail("dirty record {d} is outside the graph", .{record_id});
        if (seen[index]) fail("dirty record {d} was scheduled more than once", .{record_id});
        seen[index] = true;
        if (!expected.reachable[index]) fail("record {d} was scheduled but is not reachable from the batch's roots", .{record_id});
        const rank = harness.engine.activeSignalRank(record_id);
        if (rank < previous_rank) fail("record {d} of rank {d} was scheduled after rank {d}", .{ record_id, rank, previous_rank });
        previous_rank = rank;
    }
    for (0..program.nodes.len) |index| {
        if (expected.reachable[index] and !seen[index]) fail("reachable record {d} was never scheduled", .{index});
    }
}

/// Asserts the engine reported exactly the nodes whose value moved, in the
/// order they were scheduled.
fn expectChangedSet(outcome: Outcome, expected: Expected) void {
    var position: usize = 0;
    for (outcome.dirty[0..outcome.dirty_len]) |record_id| {
        const index: usize = @intCast(record_id);
        if (!expected.changed[index]) continue;
        if (position >= outcome.changed_len) fail("record {d} changed but was not reported", .{record_id});
        if (outcome.changed[position] != record_id) {
            fail("changed record {d} of {d} is {d}, model expects {d}", .{ position, outcome.changed_len, outcome.changed[position], record_id });
        }
        position += 1;
    }
    if (position != outcome.changed_len) {
        fail("engine reported {d} changed records, model expects {d}", .{ outcome.changed_len, position });
    }
}

/// Asserts every scheduled record carries this batch's generation, and that any
/// record carrying it - including an unscheduled input pulled in from outside
/// the closure - carries the changed flag the model predicts.
fn expectStamps(harness: *Harness, program: Program, outcome: Outcome, expected: Expected) void {
    for (outcome.dirty[0..outcome.dirty_len]) |record_id| {
        const record = &harness.records[@intCast(record_id)];
        if (record.last_dirty_generation != harness.generation) {
            fail("scheduled record {d} is stamped with generation {d}, not {d}", .{ record_id, record.last_dirty_generation, harness.generation });
        }
    }
    for (0..program.nodes.len) |index| {
        const record = &harness.records[index];
        if (record.last_dirty_generation != harness.generation) continue;
        if (record.last_dirty_changed != expected.changed[index]) {
            fail("record {d} is stamped changed={}, model expects {}", .{ index, record.last_dirty_changed, expected.changed[index] });
        }
    }
}

/// Asserts two engines that ran the same batches agree on everything the batch
/// order could plausibly have disturbed.
///
/// The changed lists are compared as sets because within one rank the schedule
/// is free to order records by the order their roots were enqueued, and records
/// of equal rank cannot depend on each other.
fn expectAgreement(left: *Harness, right: *Harness, left_outcome: Outcome, right_outcome: Outcome, what: []const u8) void {
    for (0..left.program.nodes.len) |index| {
        if (left.cached(index) != right.cached(index)) {
            fail("{s}: node {d} cached {d} against {d}", .{ what, index, left.cached(index), right.cached(index) });
        }
    }
    if (left_outcome.derived_calls != right_outcome.derived_calls) {
        fail("{s}: {d} transform calls against {d}", .{ what, left_outcome.derived_calls, right_outcome.derived_calls });
    }
    if (left_outcome.prunes != right_outcome.prunes) {
        fail("{s}: {d} prunes against {d}", .{ what, left_outcome.prunes, right_outcome.prunes });
    }
    if (left_outcome.dirty_len != right_outcome.dirty_len or left_outcome.changed_len != right_outcome.changed_len) {
        fail("{s}: {d} scheduled and {d} changed against {d} and {d}", .{ what, left_outcome.dirty_len, left_outcome.changed_len, right_outcome.dirty_len, right_outcome.changed_len });
    }
    var left_changed = left_outcome.changed;
    var right_changed = right_outcome.changed;
    std.mem.sort(u64, left_changed[0..left_outcome.changed_len], {}, std.sort.asc(u64));
    std.mem.sort(u64, right_changed[0..right_outcome.changed_len], {}, std.sort.asc(u64));
    for (left_changed[0..left_outcome.changed_len], right_changed[0..right_outcome.changed_len]) |left_id, right_id| {
        if (left_id != right_id) fail("{s}: changed sets differ at record {d} against {d}", .{ what, left_id, right_id });
    }
}

// ---------------------------------------------------------------------------
// Generation
// ---------------------------------------------------------------------------

fn generate(reader: *FuzzReader, arena: std.mem.Allocator) !Program {
    const source_count = reader.intRangeAtMost(usize, 1, max_sources);
    const node_count = reader.intRangeAtMost(usize, source_count, max_nodes);
    const nodes = try arena.alloc(Node, node_count);

    for (nodes[0..source_count]) |*node| node.* = .{ .kind = .source, .inputs = &.{} };
    for (nodes[source_count..], source_count..) |*node, index| {
        const kind: NodeKind = switch (reader.intRangeAtMost(u8, 0, 3)) {
            0, 1 => .map,
            2 => .map2,
            else => .combine,
        };
        const arity: usize = switch (kind) {
            .source => unreachable,
            .map => 1,
            .map2 => 2,
            .combine => reader.intRangeAtMost(usize, 1, max_combine_children),
        };
        const inputs = try arena.alloc(u8, arity);
        var rank: u64 = 0;
        for (inputs) |*input| {
            input.* = reader.intRangeLessThan(u8, 0, @intCast(index));
            rank = @max(rank, nodes[input.*].rank + 1);
        }
        node.* = .{
            .kind = kind,
            .inputs = inputs,
            .unary = @enumFromInt(reader.intRangeAtMost(u8, 0, @typeInfo(UnaryOp).@"enum".fields.len - 1)),
            .binary = @enumFromInt(reader.intRangeAtMost(u8, 0, @typeInfo(BinaryOp).@"enum".fields.len - 1)),
            .combine = @enumFromInt(reader.intRangeAtMost(u8, 0, @typeInfo(CombineOp).@"enum".fields.len - 1)),
            .operand = reader.intRangeAtMost(u64, 0, value_modulus - 1),
            .rank = rank,
        };
    }

    const initial = try arena.alloc(u64, node_count);
    @memset(initial, 0);
    for (initial[0..source_count]) |*value| value.* = reader.intRangeAtMost(u64, 0, value_modulus - 1);

    const batch_count = reader.intRangeAtMost(usize, 1, max_batches);
    const batches = try arena.alloc(Batch, batch_count);
    for (batches) |*entry| entry.* = try generateBatch(reader, arena, source_count);
    return .{ .nodes = nodes, .source_count = source_count, .initial = initial, .batches = batches };
}

/// Draws one batch of simultaneously dirty sources.
///
/// Sources are drawn without replacement because a transaction cannot hand one
/// source two values: `OwnedSourceUpdates.adoptAssumeCapacity` rejects a
/// duplicate record before ownership changes hands, so a batch naming one twice
/// would model a transaction the engine refuses to build.
fn generateBatch(reader: *FuzzReader, arena: std.mem.Allocator, source_count: usize) !Batch {
    var pool: [max_sources]u8 = undefined;
    for (pool[0..source_count], 0..) |*slot, index| slot.* = @intCast(index);
    var remaining = source_count;

    const length = reader.intRangeAtMost(usize, 1, source_count);
    const sources = try arena.alloc(u8, length);
    const values = try arena.alloc(u64, length);
    for (sources, values) |*source, *value| {
        const choice = reader.intRangeLessThan(usize, 0, remaining);
        source.* = pool[choice];
        pool[choice] = pool[remaining - 1];
        remaining -= 1;
        value.* = reader.intRangeAtMost(u64, 0, value_modulus - 1);
    }
    return .{ .sources = sources, .values = values };
}

fn printProgram(program: Program) void {
    std.debug.print("program: {d} nodes, {d} sources, {d} batches\n", .{ program.nodes.len, program.source_count, program.batches.len });
    for (program.nodes, 0..) |node, index| {
        std.debug.print("  [{d}] rank={d} {t}", .{ index, node.rank, node.kind });
        switch (node.kind) {
            .source => std.debug.print(" initial={d}", .{program.initial[index]}),
            .map => std.debug.print(" {t}({d}) of {d}", .{ node.unary, node.operand, node.inputs[0] }),
            .map2 => std.debug.print(" {t}({d}) of {d} and {d}", .{ node.binary, node.operand, node.inputs[0], node.inputs[1] }),
            .combine => {
                std.debug.print(" {t}({d}) of", .{ node.combine, node.operand });
                for (node.inputs) |input| std.debug.print(" {d}", .{input});
            },
        }
        std.debug.print("\n", .{});
    }
    var live: [max_sources]u64 = undefined;
    @memcpy(live[0..program.source_count], program.initial[0..program.source_count]);
    const sources = live[0..program.source_count];
    for (program.batches, 0..) |entry, index| {
        std.debug.print("  batch[{d}]:", .{index});
        for (entry.sources, entry.values) |source, value| std.debug.print(" source{d}<-{d}", .{ source, value });
        const before = evaluate(program, sources);
        for (entry.sources, entry.values) |source, value| live[source] = value;
        const after = evaluate(program, sources);
        const expected = expectationsFor(program, entry, before, after);
        std.debug.print(" -> calls={d} prunes={d}\n", .{ expected.derived_calls, expected.prunes });
    }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// AFL++ persistent-mode initialization hook.
pub export fn zig_fuzz_init() void {}

/// AFL++ persistent-mode entry point.
pub export fn zig_fuzz_test(buf: [*]u8, len: isize) void {
    zig_fuzz_test_inner(buf, len, false);
}

/// Runs one fuzz input.
pub fn zig_fuzz_test_inner(buf: [*]u8, len: isize, debug: bool) void {
    var reader = FuzzReader.init(buf[0..@intCast(len)]);

    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const program = generate(&reader, arena) catch fail("program arena exhausted", .{});
    if (debug) printProgram(program);

    // Three engines run the same batches: the first as generated, the second
    // with every batch's sources reversed, and the third a replay of the first
    // from scratch. The second proves the schedule does not depend on the order
    // sources were dirtied; the third proves the run is reproducible, which is
    // what AFL++'s stability metric measures.
    var forward: Harness = undefined;
    forward.init(arena, program, .generated);
    defer forward.deinit();
    var reversed: Harness = undefined;
    reversed.init(arena, program, .reversed);
    defer reversed.deinit();
    var replay: Harness = undefined;
    replay.init(arena, program, .generated);
    defer replay.deinit();

    var sources: [max_sources]u64 = undefined;
    @memcpy(sources[0..program.source_count], program.initial[0..program.source_count]);

    for (program.batches, 0..) |entry, index| {
        const before = evaluate(program, sources[0..program.source_count]);
        for (entry.sources, entry.values) |source, value| sources[source] = value;
        const after = evaluate(program, sources[0..program.source_count]);
        const expected = expectationsFor(program, entry, before, after);

        const forward_outcome = forward.apply(entry);
        check(&forward, program, index, forward_outcome, after, expected);
        const reversed_outcome = reversed.apply(entry);
        check(&reversed, program, index, reversed_outcome, after, expected);
        const replay_outcome = replay.apply(entry);

        phase = "order independence";
        batch_number = index;
        expectAgreement(&forward, &reversed, forward_outcome, reversed_outcome, "reversing the batch's dirty sources changed the result");
        phase = "determinism";
        expectAgreement(&forward, &replay, forward_outcome, replay_outcome, "replaying the same batches produced a different result");
    }

    if (debug) {
        std.debug.print("final values:", .{});
        for (0..program.nodes.len) |index| std.debug.print(" {d}", .{forward.cached(index)});
        std.debug.print("\ntransform calls: {d}, prunes: {d}\n", .{
            forward.engine.pending_roc_metrics.derived_calls_into_roc,
            forward.engine.pending_roc_metrics.propagation_prunes,
        });
    }
}

/// Which run and which batch the oracles are judging, named in every failure so
/// a replay says where the model and the engine parted.
var phase: []const u8 = "before the first batch";
var batch_number: usize = 0;

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("propagation fuzz oracle failed ({s} {d}): " ++ fmt ++ "\n", .{ phase, batch_number } ++ args);
    @panic("propagation fuzz oracle failed");
}
