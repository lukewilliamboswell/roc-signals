//! Platform host for testing signal-based reactive UI applications.
//!
//! The native host is the spec/telemetry/debug boundary: it owns the simulated
//! DOM, Roc allocation diagnostics, benchmark metrics, and browser-style event
//! replay. Reactive and structural behavior lives in `engine.zig`; this host
//! supplies `NativeCtx` plus a render sink and drives the shared engine path.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const signals = @import("signals");
const abi = signals.abi;
const boundary = signals.boundary;
const render = signals.render;
const render_cache = signals.render_cache;
const render_sink = signals.render_sink;
const ids = signals.ids;
const scope_tree = signals.scope_tree;
const erased_calls = signals.erased_calls;
const CapabilitySplit = signals.callable_roles.CapabilitySplit;
const hv = signals.host_values;
const engine = signals.engine;
const DebugPhase = signals.debug_phase.Phase;
const FaultAllocator = signals.fault_allocator.FaultAllocator;
const spec_parser = @import("spec/spec_parser.zig");
const spec_runner = @import("spec/spec_runner.zig");
const benchmark = @import("bench/benchmark.zig");
const sim_dom = @import("sim_dom.zig");
const roc_alloc_ledger = @import("roc_alloc_ledger.zig");
const crash_handlers = @import("crash_handlers.zig");

const enable_runtime_metrics = host_fixtures or build_options.metrics;
/// Test-only host machinery (value-kind tracking, the current-host binding,
/// fixture builders) is also compiled into fuzz targets, which are ordinary
/// builds that opt in through `-Dfuzz`'s options module.
const host_fixtures = builtin.is_test or build_options.fuzz_fixtures;

const ElemBox = @typeInfo(@TypeOf(abi.roc_ui_init)).@"fn".return_type.?;
const RocStr = abi.RocStr;
const HostValue = hv.HostValue;
const HostValueCapability = hv.HostValueCapabilityHandle;
const HostTextRead = engine.HostTextRead;
const HostBoolRead = engine.HostBoolRead;
const HostEachOps = engine.HostEachOps;
const HostValueList = abi.RocListWith(HostValue, false);
const I64List = abi.RocListWith(i64, false);
const U8List = hv.U8List;
const RenderTextField = render.TextField;
const RenderBoolField = render.BoolField;
const RenderEventKind = render.EventKind;
const CommandCounts = render.Counts;
const HostScopeBranch = scope_tree.Branch;

const NativeRenderPublication = struct {
    /// `OutOfMemory`: the host allocator refused; `ResourceLimit`: a count exceeded its arithmetic bound;
    /// `InvalidRenderTopology`: the splice names a DOM node the simulated tree does not hold.
    pub const PrepareError = std.mem.Allocator.Error || error{ ResourceLimit, InvalidRenderTopology };

    dom: sim_dom.PreparedPublication,

    fn prepareTextField(allocator: std.mem.Allocator, node: *sim_dom.Element, field: RenderTextField, next: ?[]const u8) std.mem.Allocator.Error!void {
        const slot: *?[]const u8 = switch (field) {
            .text => &node.text,
            .role => &node.role,
            .label => &node.label,
            .test_id => &node.test_id,
            .value => &node.value,
            .class => &node.class,
        };
        if (field == .value) value: {
            if (next == null) {
                if (slot.*) |old| allocator.free(old);
                slot.* = null;
                node.value_update_count += 1;
                break :value;
            }
            if (node.value) |old_value| if (std.mem.eql(u8, old_value, next.?)) {
                if (node.pending_value) |pending| allocator.free(pending);
                node.pending_value = null;
                break :value;
            };
            const copied = try allocator.dupe(u8, next.?);
            if (node.focused or node.composing) {
                if (node.pending_value) |old| allocator.free(old);
                node.pending_value = copied;
                break :value;
            }
            if (node.pending_value) |pending| allocator.free(pending);
            node.pending_value = null;
            if (slot.*) |old| allocator.free(old);
            slot.* = copied;
            node.value_update_count += 1;
        } else {
            const copied = if (next) |value| try allocator.dupe(u8, value) else null;
            if (slot.*) |old| allocator.free(old);
            slot.* = copied;
            if (field == .text) node.text_update_count += 1;
        }
    }

    fn prepare(host: *HostEnv, splice: anytype) PrepareError!NativeRenderPublication {
        const allocator = host.hostAllocator();
        var touched: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer touched.deinit(allocator);
        var count: usize = 0;
        inline for (.{ splice.removals.items.len, splice.creations.items.len, splice.children.items.len, splice.parent_intents.items.len, splice.text_fields.items.len, splice.bool_fields.items.len, splice.fixed_events.items.len, splice.custom_attrs.items.len, splice.named_events.items.len }) |additional| {
            count = std.math.add(usize, count, additional) catch return error.ResourceLimit;
        }
        try touched.ensureUnusedCapacity(allocator, std.math.cast(u32, count) orelse return error.ResourceLimit);
        var max_elem_id: u64 = if (host.dom_elements.items.len == 0) 0 else host.dom_elements.items.len - 1;
        for (splice.removals.items) |entry| {
            touched.putAssumeCapacity(entry.elem_id.raw(), {});
            max_elem_id = @max(max_elem_id, entry.elem_id.raw());
        }
        for (splice.creations.items) |entry| {
            touched.putAssumeCapacity(entry.elem_id.raw(), {});
            max_elem_id = @max(max_elem_id, entry.elem_id.raw());
        }
        for (splice.children.items) |entry| {
            touched.putAssumeCapacity(entry.parent_elem_id.raw(), {});
            max_elem_id = @max(max_elem_id, entry.parent_elem_id.raw());
        }
        for (splice.parent_intents.items) |intent| {
            touched.putAssumeCapacity(intent.child_id.raw(), {});
            max_elem_id = @max(max_elem_id, intent.child_id.raw());
        }
        inline for (.{ splice.text_fields.items, splice.bool_fields.items, splice.fixed_events.items, splice.custom_attrs.items, splice.named_events.items }) |entries| for (entries) |entry| {
            touched.putAssumeCapacity(entry.elem_id.raw(), {});
            max_elem_id = @max(max_elem_id, entry.elem_id.raw());
        };
        const touched_ids = try allocator.alloc(u64, touched.count());
        defer allocator.free(touched_ids);
        var iterator = touched.keyIterator();
        var write: usize = 0;
        while (iterator.next()) |id| : (write += 1) touched_ids[write] = id.*;
        var dom = sim_dom.PreparedPublication.init(allocator, &host.dom_elements, touched_ids, max_elem_id) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.ResourceLimit => error.ResourceLimit,
            error.DuplicateNode => error.InvalidRenderTopology,
        };
        errdefer dom.deinit();
        for (splice.removals.items) |entry| sim_dom.deactivateRemovedNode(allocator, dom.node(entry.elem_id.raw()) orelse return error.InvalidRenderTopology);
        for (splice.creations.items) |entry| {
            const node = dom.node(entry.elem_id.raw()) orelse return error.InvalidRenderTopology;
            const tag = try allocator.dupe(u8, entry.tag);
            node.deinit(allocator);
            node.* = sim_dom.Element.init(entry.elem_id.raw(), tag);
        }
        for (splice.children.items) |entry| {
            const parent = dom.node(entry.parent_elem_id.raw()) orelse return error.InvalidRenderTopology;
            parent.children.deinit(allocator);
            parent.children = .empty;
            try parent.children.ensureTotalCapacity(allocator, entry.next.len);
            for (entry.next) |child_id| parent.children.appendAssumeCapacity(child_id.raw());
        }
        for (splice.parent_intents.items) |intent| (dom.node(intent.child_id.raw()) orelse return error.InvalidRenderTopology).parent_id = if (intent.next) |parent_id| parent_id.raw() else null;
        for (splice.text_fields.items) |entry| {
            const node = dom.node(entry.elem_id.raw()) orelse return error.InvalidRenderTopology;
            try prepareTextField(allocator, node, entry.field, entry.next);
        }
        for (splice.bool_fields.items) |entry| {
            const node = dom.node(entry.elem_id.raw()) orelse return error.InvalidRenderTopology;
            switch (entry.field) {
                .checked => {
                    node.checked = entry.next orelse false;
                    node.checked_update_count += 1;
                },
                .disabled => {
                    node.disabled = entry.next orelse false;
                    node.disabled_update_count += 1;
                },
            }
        }
        for (splice.fixed_events.items) |entry| {
            const node = dom.node(entry.elem_id.raw()) orelse return error.InvalidRenderTopology;
            switch (entry.kind) {
                .click => node.event_bindings.click = entry.next,
                .input => node.event_bindings.input = entry.next,
                .check => node.event_bindings.check = entry.next,
                .pointer_down => node.event_bindings.pointer_down = entry.next,
                .pointer_up => node.event_bindings.pointer_up = entry.next,
                .pointer_enter => node.event_bindings.pointer_enter = entry.next,
                .pointer_leave => node.event_bindings.pointer_leave = entry.next,
            }
        }
        for (splice.custom_attrs.items) |entry| {
            const node = dom.node(entry.elem_id.raw()) orelse return error.InvalidRenderTopology;
            for (node.attrs.items) |attr| attr.deinit(allocator);
            node.attrs.clearRetainingCapacity();
            try node.attrs.ensureTotalCapacity(allocator, entry.next.len);
            for (entry.next) |attr| {
                const name = try allocator.dupe(u8, attr.name);
                errdefer allocator.free(name);
                const value = try allocator.dupe(u8, attr.value);
                node.attrs.appendAssumeCapacity(.{ .name = name, .value = value });
            }
        }
        for (splice.named_events.items) |entry| {
            const node = dom.node(entry.elem_id.raw()) orelse return error.InvalidRenderTopology;
            for (node.named_events.items) |event| event.deinit(allocator);
            node.named_events.clearRetainingCapacity();
            try node.named_events.ensureTotalCapacity(allocator, entry.next.len);
            for (entry.next) |event| node.named_events.appendAssumeCapacity(.{
                .name = try allocator.dupe(u8, event.name),
                .binding = event.binding,
            });
        }
        return .{ .dom = dom };
    }

    fn apply(self: *NativeRenderPublication, host: *HostEnv) void {
        self.dom.apply(&host.dom_elements);
    }

    /// Releases provisional DOM slots on abort or displaced slots after publication.
    pub fn deinit(self: *NativeRenderPublication) void {
        self.dom.deinit();
    }
};

const NativeCtx = struct {
    pub const Handle = *HostEnv;
    pub const RegistryOps = hv.RegistryOps();
    pub const Metrics = RuntimeMetrics;
    pub const Sink = render_sink.DomSink(HostEnv);
    pub const RenderPublication = NativeRenderPublication;

    /// Creates the host's zeroed metric accumulator for a new engine operation.
    pub fn zeroMetrics() Metrics {
        return zeroRuntimeMetrics();
    }

    /// Returns the allocator owned by this host context for shared-engine work.
    pub fn allocator(ctx: Handle) std.mem.Allocator {
        return ctx.engine_allocator_override orelse ctx.hostAllocator();
    }

    /// Prepares the native simulated-DOM shadow without mutating host-visible state.
    pub fn prepareRenderPublication(ctx: Handle, splice: anytype) RenderPublication.PrepareError!RenderPublication {
        return RenderPublication.prepare(ctx, splice);
    }

    /// Makes the already-prepared native DOM shadow host-visible without allocation.
    pub fn publishRenderPublication(ctx: Handle, publication: *RenderPublication) void {
        publication.apply(ctx);
    }

    /// Produces an independently owned copy through the value's app-compiled capability.
    pub fn cloneHostValue(ctx: Handle, value: HostValue) HostValue {
        return ctx.cloneHostValue(value);
    }

    /// Provides debug phase for native semantic observation without duplicating engine behavior.
    pub fn debugPhase(ctx: Handle, phase: DebugPhase) void {
        ctx.debug_phase = phase;
    }

    /// Provides debug inactive task for native semantic observation without duplicating engine behavior.
    pub fn debugInactiveTask(_: Handle, name: []const u8) void {
        writeStderr("inactive StartTask name=");
        writeStderr(name);
        writeStderr("\n");
    }

    /// Terminates the current host instance with a bounded diagnostic.
    pub fn failWithMessage(_: Handle, message: []const u8) noreturn {
        failHost(message);
    }

    /// Opens a checked capability frame for an app-compiled erased call.
    pub fn pushHostValueCapabilities(ctx: Handle, caps: []const HostValueCapability) void {
        ctx.active_capabilities.push(caps);
    }

    /// Closes the current capability frame after an app-compiled erased call.
    pub fn popHostValueCapabilities(ctx: Handle) void {
        ctx.active_capabilities.pop();
    }

    /// Resolves a state cell by dense node id without scanning the signal graph.
    pub fn stateValueByNodeId(ctx: Handle, node_id: u64) HostValue {
        return ctx.stateValueByNodeId(ids.NodeId.fromRaw(node_id));
    }

    /// Returns the exact app-compiled capability that owns the requested state cell.
    pub fn stateCapability(ctx: Handle, node_id: u64) HostValueCapability {
        return ctx.stateCapability(ids.NodeId.fromRaw(node_id));
    }

    /// Replaces a state source value and enters the ordinary dirty-propagation path.
    pub fn updateStateValue(ctx: Handle, roc_host: *abi.RocHost, node_id: u64, value: HostValue) bool {
        return ctx.updateStateValue(roc_host, ids.NodeId.fromRaw(node_id), value);
    }

    /// Marks a task request settled when its prepared source transaction commits.
    pub fn noteTaskResolved(ctx: Handle, request_id: u64) void {
        ctx.noteTaskResolved(ids.TaskRequestId.fromRaw(request_id));
    }

    /// Materializes the mount-time browser location through the source's owning capability.
    pub fn initialLocationPayload(ctx: Handle, roc_host: *abi.RocHost, cap: HostValueCapability) HostValue {
        return ctx.initialLocationPayload(roc_host, cap);
    }

    /// Materializes the mount-time visibility state through the source's owning capability.
    pub fn initialVisibilityPayload(ctx: Handle, roc_host: *abi.RocHost, cap: HostValueCapability) HostValue {
        return ctx.initialVisibilityPayload(roc_host, cap);
    }

    /// Materializes the mount-time online state through the source's owning capability.
    pub fn initialOnlinePayload(ctx: Handle, roc_host: *abi.RocHost, cap: HostValueCapability) HostValue {
        return ctx.initialOnlinePayload(roc_host, cap);
    }

    /// Materializes one declared storage key through the source's owning capability.
    pub fn initialStoragePayload(ctx: Handle, roc_host: *abi.RocHost, area: boundary.StorageArea, key: []const u8, cap: HostValueCapability) HostValue {
        return ctx.initialStoragePayload(roc_host, area, key, cap);
    }

    /// Returns the thin render-command sink used by the shared engine.
    pub fn sink(ctx: Handle) Sink {
        return ctx.sink();
    }
};

const HostEngine = engine.Engine(NativeCtx);
const RuntimeMetrics = engine.RuntimeMetrics;
const NoMetrics = engine.NoMetrics;
const addRuntimeMetrics = engine.addRuntimeMetrics;

comptime {
    std.debug.assert(@sizeOf(NoMetrics) == 0);
}

test "NoMetrics is a zero-size no-op metrics sink" {
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(NoMetrics));
    var metrics: NoMetrics = .{};
    metrics.bump(.closure_retains, 2);
    metrics.bump(.dirty_source_roots, 1);
}

const EventPayloadKind = engine.EventPayloadKind;
const EventExtractionPlanKind = engine.EventExtractionPlanKind;
const BoundaryPayloadDescriptor = engine.BoundaryPayloadDescriptor;
const SignalKind = engine.SignalKind;
const HostActiveEventDesc = engine.HostActiveEventDesc;
const HostPendingTask = engine.HostPendingTask;

const HostSignalCacheSlot = engine.HostSignalCacheSlot;

const HostNodeScopeSiteKind = engine.HostNodeScopeSiteKind;
const HostBinderToken = engine.HostBinderToken;
const HostSignalToken = engine.HostSignalToken;
const HostBinderBinding = engine.HostBinderBinding;

const HostSignalRecordPayload = engine.HostSignalRecordPayload;
const NodeFieldCustom = engine.NodeFieldCustom;

const HostSignalRecord = engine.HostSignalRecord;

const HostSignalBinding = engine.HostSignalBinding;

const HostNodeDescriptorStream = engine.HostNodeDescriptorStream;

const HostActiveStructuralSignalKind = engine.HostActiveStructuralSignalKind;
const HostDirtyStructuralSignal = engine.HostDirtyStructuralSignal;
const HostKeyedRowDiffResult = engine.HostKeyedRowDiffResult;

pub const std_options = crash_handlers.std_options;
pub const panic = crash_handlers.panic;

fn writeStderr(bytes: []const u8) void {
    crash_handlers.writeStderr(bytes);
}

fn writeUsage() void {
    writeStderr("Usage: ./app [--verbose] [--trace-allocations] [--run-spec-json] <case.scm>\n       ./app --bench-app [--bench-name NAME] [--bench-warmup N] [--bench-iterations N] [--bench-samples N] <case.scm>\n");
}

const SpecJsonFailure = struct {
    phase: []const u8,
    kind: []const u8,
    message: []const u8,
};

const SpecJsonResult = struct {
    protocol: []const u8 = "roc-signals/spec-result/v1",
    id: []const u8,
    name: []const u8,
    status: []const u8,
    duration_ns: u64,
    failure: ?SpecJsonFailure,
};

fn writeSpecJsonResult(result: SpecJsonResult) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_state = std.Io.File.stdout().writer(io, &stdout_buffer);
    var stream: std.json.Stringify = .{ .writer = &stdout_state.interface };
    stream.write(result) catch return;
    stdout_state.interface.writeByte('\n') catch return;
    stdout_state.interface.flush() catch {};
}

const DomElement = sim_dom.Element;
const DomNamedEvent = sim_dom.NamedEvent;

const SpecCommandType = spec_parser.SpecCommandType;
const Locator = spec_parser.Locator;
const SpecCommand = spec_parser.SpecCommand;
const ParseError = spec_parser.ParseError;
const parseTestSpecFile = spec_parser.parseTestSpecFile;
const freeSpecCommands = spec_parser.freeSpecCommands;
const BenchmarkStats = benchmark.Stats;

const TestState = struct {
    verbose: bool,
    trace_allocations: bool,
    allocation_snapshot: roc_alloc_ledger.Snapshot,
    trace_host_live_count: u64,
    trace_host_live_bytes: u64,
    commands: []SpecCommand,

    fn init() TestState {
        return .{
            .verbose = false,
            .trace_allocations = false,
            .allocation_snapshot = .{ .next_id = 1, .live_count = 0, .live_bytes = 0 },
            .trace_host_live_count = 0,
            .trace_host_live_bytes = 0,
            .commands = &.{},
        };
    }
};

const NativeTaskRecord = struct {
    request_id: ids.TaskRequestId,
    name: []const u8,
};

const NativeLocation = struct {
    path: []u8,
    query: []u8,
    hash: []u8,

    fn init(allocator: std.mem.Allocator, location: boundary.LocationSnapshot) NativeLocation {
        if (location.path.len == 0 or location.path[0] != '/') {
            failHost("location path must start with /");
        }
        const path = allocator.dupe(u8, location.path) catch @panic("out of memory");
        const query = allocator.dupe(u8, location.query) catch {
            allocator.free(path);
            @panic("out of memory");
        };
        const hash = allocator.dupe(u8, location.hash) catch {
            allocator.free(path);
            allocator.free(query);
            @panic("out of memory");
        };
        return .{ .path = path, .query = query, .hash = hash };
    }

    fn deinit(self: NativeLocation, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.query);
        allocator.free(self.hash);
    }

    fn snapshot(self: NativeLocation) boundary.LocationSnapshot {
        return .{ .path = self.path, .query = self.query, .hash = self.hash };
    }
};

const NativeStorageEntry = struct {
    area: boundary.StorageArea,
    key: []u8,
    value: []u8,

    fn init(allocator: std.mem.Allocator, area: boundary.StorageArea, key: []const u8, value: []const u8) NativeStorageEntry {
        const key_copy = allocator.dupe(u8, key) catch @panic("out of memory");
        const value_copy = allocator.dupe(u8, value) catch {
            allocator.free(key_copy);
            @panic("out of memory");
        };
        return .{ .area = area, .key = key_copy, .value = value_copy };
    }

    fn deinit(self: NativeStorageEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
    }
};

fn u64SliceContains(items: []const u64, target: u64) bool {
    for (items) |item| {
        if (item == target) return true;
    }
    return false;
}

fn failScopeTreeError(err: anyerror, unknown_scope_message: []const u8) noreturn {
    switch (err) {
        error.OutOfMemory => std.process.exit(1),
        error.UnknownScope => failHost(unknown_scope_message),
        error.InactiveScope => failHost("scope id references a disposed host scope"),
        error.InvalidRoot => failHost("host root scope descriptor is not indexed by scope id"),
        else => failHost("scope tree operation failed"),
    }
}

fn failIdentityTableError(err: anyerror) noreturn {
    switch (err) {
        error.OutOfMemory => std.process.exit(1),
        else => failHost("identity table operation failed"),
    }
}

fn failScopeOrIdentityTableError(err: anyerror, unknown_scope_message: []const u8) noreturn {
    switch (err) {
        error.UnknownScope, error.InactiveScope, error.InvalidRoot => failScopeTreeError(err, unknown_scope_message),
        error.OutOfMemory => std.process.exit(1),
        else => failIdentityTableError(err),
    }
}

fn failSignalLookupError(err: HostEngine.SignalLookupError) noreturn {
    switch (err) {
        error.MissingSignalRoute => failHost("state id has no host signal route descriptor"),
        error.SignalRouteIndexMismatch => failHost("host signal route table is not indexed by state id"),
        error.MissingSignalDependentRoute => failHost("signal id has no host dependent route descriptor"),
        error.SignalDependentRouteIndexMismatch => failHost("host signal dependent route table is not indexed by signal id"),
        error.MissingSignalDescriptor => failHost("signal id has no host signal descriptor"),
        error.SignalDescriptorIndexMismatch => failHost("host signal descriptor table is not indexed by signal id"),
    }
}

fn failRocHostRequiredError(err: HostEngine.RocHostRequiredError, message: []const u8) noreturn {
    switch (err) {
        error.MissingRocHost => failHost(message),
    }
}

fn failHostValueRegistryError(err: anyerror) noreturn {
    switch (err) {
        error.OutOfMemory => std.process.exit(1),
        error.InvalidHandle => failHost("HostValue handle referenced an unknown value"),
        error.ReleasedHandle => failHost("HostValue handle referenced a released value"),
        error.UnconsumedHandle => failHost("HostValue consuming callback returned without taking the transferred value"),
        error.MissingCapability => failHost("HostValue operation crossed erasure boundary without an owning capability"),
        error.CapabilityMismatch => failHost("HostValue operation used a capability that does not own the retained value"),
        error.ConflictingCapability => failHost("HostValue was assigned a conflicting capability"),
        error.InactiveCapability => failHost("HostValue split operation ran without an active owning capability"),
        error.CloneCapabilityMismatch => failHost("HostValue capability clone returned a value owned by a different capability"),
        error.CloneReturnedSource => failHost("HostValue capability clone returned the source handle"),
        else => failHost("HostValue registry operation failed"),
    }
}

const TestHostValueKind = enum {
    unit,
    i64,
    bool,
    str,
    i64_list,
    u8_list,
};

const HostAllocator = struct {
    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn host(ptr: *anyopaque) *HostEnv {
        return @ptrCast(@alignCast(ptr));
    }

    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const env = host(ptr);
        const memory = env.backingAllocator().rawAlloc(len, alignment, ret_addr) orelse return null;
        env.recordHostAlloc(len);
        return memory;
    }

    fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const env = host(ptr);
        if (!env.backingAllocator().rawResize(memory, alignment, new_len, ret_addr)) return false;
        env.recordHostResize(memory.len, new_len);
        return true;
    }

    fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const env = host(ptr);
        const result = env.backingAllocator().rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        env.recordHostResize(memory.len, new_len);
        return result;
    }

    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const env = host(ptr);
        env.recordHostFree(memory.len);
        env.backingAllocator().rawFree(memory, alignment, ret_addr);
    }
};

const HostEnv = struct {
    gpa: std.heap.DebugAllocator(.{ .safety = true }),
    allocation_fault: ?FaultAllocator = null,
    engine_allocator_override: ?std.mem.Allocator = null,
    engine: HostEngine = .{},
    test_state: TestState,
    roc_allocations: roc_alloc_ledger.Ledger = .{},
    test_host_value_kinds: std.ArrayListUnmanaged(?TestHostValueKind) = .empty,
    alloc_count: usize = 0,
    dealloc_count: usize = 0,
    host_alloc_count: u64 = 0,
    host_dealloc_count: u64 = 0,
    host_alloc_bytes: u64 = 0,
    host_dealloc_bytes: u64 = 0,
    debug_phase: DebugPhase = .idle,
    active_capabilities: hv.ActiveCapabilityStack = .{},
    dom_elements: std.ArrayListUnmanaged(DomElement) = .empty,
    started_tasks: std.ArrayListUnmanaged(NativeTaskRecord) = .empty,
    canceled_tasks: std.ArrayListUnmanaged(NativeTaskRecord) = .empty,
    location_history: std.ArrayListUnmanaged(NativeLocation) = .empty,
    location_index: usize = 0,
    visibility: boundary.VisibilitySnapshot = .visible,
    online: boundary.OnlineSnapshot = .online,
    storage_entries: std.ArrayListUnmanaged(NativeStorageEntry) = .empty,
    document_title: ?[]u8 = null,

    fn init() HostEnv {
        return .{
            .gpa = std.heap.DebugAllocator(.{ .safety = true }){},
            .test_state = TestState.init(),
        };
    }

    fn backingAllocator(self: *HostEnv) std.mem.Allocator {
        if (self.allocation_fault) |*fault| return fault.allocator();
        return self.gpa.allocator();
    }

    fn configureAllocationFailure(self: *HostEnv, number: ?usize) void {
        if (self.allocation_fault == null) {
            self.allocation_fault = FaultAllocator.init(self.gpa.allocator());
        }
        if (self.allocation_fault) |*fault| fault.configure(number);
    }

    inline fn hostAllocator(self: *HostEnv) std.mem.Allocator {
        if (comptime !enable_runtime_metrics) return self.backingAllocator();
        return .{ .ptr = self, .vtable = &HostAllocator.vtable };
    }

    fn deinitTaskRecords(self: *HostEnv) void {
        const allocator = self.hostAllocator();
        for (self.started_tasks.items) |record| {
            allocator.free(record.name);
        }
        self.started_tasks.deinit(allocator);
        self.started_tasks = .empty;
        for (self.canceled_tasks.items) |record| {
            allocator.free(record.name);
        }
        self.canceled_tasks.deinit(allocator);
        self.canceled_tasks = .empty;
    }

    fn recordStartedTask(self: *HostEnv, request_id: ids.TaskRequestId, task_name: []const u8) void {
        const allocator = self.hostAllocator();
        const task_name_copy = allocator.dupe(u8, task_name) catch @panic("out of memory");
        self.started_tasks.append(allocator, .{
            .request_id = request_id,
            .name = task_name_copy,
        }) catch {
            allocator.free(task_name_copy);
            @panic("out of memory");
        };
    }

    fn takeStartedTask(self: *HostEnv, request_id: ids.TaskRequestId) ?NativeTaskRecord {
        for (self.started_tasks.items, 0..) |record, index| {
            if (record.request_id == request_id) return self.started_tasks.swapRemove(index);
        }
        return null;
    }

    fn noteTaskResolved(self: *HostEnv, request_id: ids.TaskRequestId) void {
        if (self.takeStartedTask(request_id)) |record| {
            self.hostAllocator().free(record.name);
        }
    }

    fn recordCanceledTask(self: *HostEnv, request_id: ids.TaskRequestId) void {
        const record = self.takeStartedTask(request_id) orelse return;
        self.canceled_tasks.append(self.hostAllocator(), record) catch {
            self.hostAllocator().free(record.name);
            @panic("out of memory");
        };
    }

    fn takeCanceledTaskByName(self: *HostEnv, name: []const u8) ?NativeTaskRecord {
        for (self.canceled_tasks.items, 0..) |record, index| {
            if (std.mem.eql(u8, record.name, name)) return self.canceled_tasks.swapRemove(index);
        }
        return null;
    }

    fn canceledTaskCountByName(self: *const HostEnv, name: []const u8) u64 {
        var count: u64 = 0;
        for (self.canceled_tasks.items) |record| {
            if (std.mem.eql(u8, record.name, name)) count += 1;
        }
        return count;
    }

    inline fn hostMetricBytes(bytes: usize) u64 {
        return std.math.cast(u64, bytes) orelse failHost("host allocation byte count exceeded metric range");
    }

    inline fn recordHostAlloc(self: *HostEnv, bytes: usize) void {
        if (comptime !enable_runtime_metrics) return;
        const metric_bytes = HostEnv.hostMetricBytes(bytes);
        self.host_alloc_count += 1;
        self.host_alloc_bytes += metric_bytes;
        self.engine.pending_roc_metrics.bump(.host_allocs_this_event, 1);
        self.engine.pending_roc_metrics.bump(.host_alloc_bytes_this_event, metric_bytes);
    }

    inline fn recordHostFree(self: *HostEnv, bytes: usize) void {
        if (comptime !enable_runtime_metrics) return;
        const metric_bytes = HostEnv.hostMetricBytes(bytes);
        self.host_dealloc_count += 1;
        self.host_dealloc_bytes += metric_bytes;
        self.engine.pending_roc_metrics.bump(.host_deallocs_this_event, 1);
        self.engine.pending_roc_metrics.bump(.host_dealloc_bytes_this_event, metric_bytes);
    }

    inline fn recordHostResize(self: *HostEnv, old_len: usize, new_len: usize) void {
        if (comptime !enable_runtime_metrics) return;
        if (new_len > old_len) {
            const delta = HostEnv.hostMetricBytes(new_len - old_len);
            self.host_alloc_bytes += delta;
            self.engine.pending_roc_metrics.bump(.host_alloc_bytes_this_event, delta);
        } else if (old_len > new_len) {
            const delta = HostEnv.hostMetricBytes(old_len - new_len);
            self.host_dealloc_bytes += delta;
            self.engine.pending_roc_metrics.bump(.host_dealloc_bytes_this_event, delta);
        }
    }

    inline fn recordRocAllocMetric(self: *HostEnv) void {
        if (comptime !enable_runtime_metrics) return;
        self.alloc_count += 1;
        self.engine.pending_roc_metrics.bump(.allocs_this_event, 1);
    }

    inline fn recordRocFreeMetric(self: *HostEnv) void {
        if (comptime !enable_runtime_metrics) return;
        self.dealloc_count += 1;
        self.engine.pending_roc_metrics.bump(.deallocs_this_event, 1);
    }

    /// Returns the thin render-command sink used by the shared engine.
    pub fn sink(self: *HostEnv) render_sink.DomSink(HostEnv) {
        return .{ .host = self };
    }

    /// Adapts the shared engine's reset command to this host without re-deciding reactive meaning.
    pub fn sinkReset(self: *HostEnv) void {
        resetSimulatedDom(self);
    }

    /// Adapts the shared engine's reserve nodes command to this host without re-deciding reactive meaning.
    pub fn sinkReserveNodes(self: *HostEnv, capacity: usize) void {
        self.dom_elements.ensureTotalCapacity(self.hostAllocator(), capacity) catch failHost("out of memory");
    }

    /// Adapts the shared engine's append node command to this host without re-deciding reactive meaning.
    pub fn sinkAppendNode(self: *HostEnv, elem_id: ids.ElemId, parent_elem_id: ids.ElemId, tag: []const u8) void {
        appendDomNode(self, elem_id, parent_elem_id, tag);
    }

    /// Adapts the shared engine's ensure node command to this host without re-deciding reactive meaning.
    pub fn sinkEnsureNode(self: *HostEnv, elem_id: ids.ElemId, tag: []const u8) void {
        ensureDomNode(self, elem_id, tag);
    }

    /// Adapts the shared engine's remove node command to this host without re-deciding reactive meaning.
    pub fn sinkRemoveNode(self: *HostEnv, elem_id: ids.ElemId) void {
        removeDomNode(self, elem_id);
    }

    /// Adapts the shared engine's replace children command to this host without re-deciding reactive meaning.
    pub fn sinkReplaceChildren(self: *HostEnv, parent_elem_id: ids.ElemId, next_child_ids: []const ids.ElemId) void {
        replaceDomChildrenForStructuralParent(self, parent_elem_id, next_child_ids);
    }

    /// Adapts the shared engine's replace children for moves command to this host without re-deciding reactive meaning.
    pub fn sinkReplaceChildrenForMoves(self: *HostEnv, parent_elem_id: ids.ElemId, next_child_ids: []const ids.ElemId) void {
        replaceDomChildrenForStructuralParentMoves(self, parent_elem_id, next_child_ids);
    }

    /// Adapts the shared engine's apply text field command to this host without re-deciding reactive meaning.
    pub fn sinkApplyTextField(self: *HostEnv, elem_id: ids.ElemId, field: RenderTextField, value: []const u8) void {
        setRenderTextField(self, elem_id, field, value);
    }

    /// Adapts the shared engine's apply text attr command to this host without re-deciding reactive meaning.
    pub fn sinkApplyTextAttr(self: *HostEnv, elem_id: ids.ElemId, name: []const u8, value: []const u8) void {
        setRenderTextAttr(self, elem_id, name, value);
    }

    /// Adapts the shared engine's apply bool field command to this host without re-deciding reactive meaning.
    pub fn sinkApplyBoolField(self: *HostEnv, elem_id: ids.ElemId, field: RenderBoolField, value: bool) void {
        setRenderBoolField(self, elem_id, field, value);
    }

    /// Adapts the shared engine's clear text field command to this host without re-deciding reactive meaning.
    pub fn sinkClearTextField(self: *HostEnv, elem_id: ids.ElemId, field: RenderTextField) void {
        clearRenderTextField(self, elem_id, field);
    }

    /// Adapts the shared engine's clear text attr command to this host without re-deciding reactive meaning.
    pub fn sinkClearTextAttr(self: *HostEnv, elem_id: ids.ElemId, name: []const u8) void {
        clearRenderTextAttr(self, elem_id, name);
    }

    /// Adapts the shared engine's clear bool field command to this host without re-deciding reactive meaning.
    pub fn sinkClearBoolField(self: *HostEnv, elem_id: ids.ElemId, field: RenderBoolField) void {
        clearRenderBoolField(self, elem_id, field);
    }

    /// Adapts the shared engine's bind event command to this host without re-deciding reactive meaning.
    pub fn sinkBindEvent(self: *HostEnv, command: render_sink.EventBindCommand) void {
        bindNodeEvent(self, command);
    }

    /// Adapts the shared engine's clear event command to this host without re-deciding reactive meaning.
    pub fn sinkClearEvent(self: *HostEnv, command: render_sink.EventClearCommand) void {
        clearNodeEvent(self, command);
    }

    /// Adapts the shared engine's start interval command to this host without re-deciding reactive meaning.
    pub fn sinkStartInterval(_: *HostEnv, _: ids.IntervalToken, _: u64) void {}

    /// Adapts the shared engine's cancel interval command to this host without re-deciding reactive meaning.
    pub fn sinkCancelInterval(_: *HostEnv, _: ids.IntervalToken) void {}

    /// Adapts the shared engine's start task command to this host without re-deciding reactive meaning.
    pub fn sinkStartTask(self: *HostEnv, request_id: ids.TaskRequestId, task_name: []const u8, _: []const u8) void {
        self.recordStartedTask(request_id, task_name);
    }

    /// Adapts the shared engine's cancel task command to this host without re-deciding reactive meaning.
    pub fn sinkCancelTask(self: *HostEnv, request_id: ids.TaskRequestId) void {
        self.recordCanceledTask(request_id);
    }

    /// Adapts the shared engine's navigate command to this host without re-deciding reactive meaning.
    pub fn sinkNavigate(self: *HostEnv, kind: render_sink.NavigationKind, location: boundary.LocationSnapshot) void {
        switch (kind) {
            .push => self.pushCurrentLocation(location),
            .replace => self.replaceCurrentLocation(location),
        }
    }

    /// Adapts the shared engine's set document title command to this host without re-deciding reactive meaning.
    pub fn sinkSetDocumentTitle(self: *HostEnv, title: []const u8) void {
        self.setDocumentTitle(title);
    }

    /// Adapts the shared engine's set storage text command to this host without re-deciding reactive meaning.
    pub fn sinkSetStorageText(self: *HostEnv, area: boundary.StorageArea, key: []const u8, value: []const u8) void {
        self.setStorageText(area, key, value);
    }

    /// Adapts the shared engine's remove storage command to this host without re-deciding reactive meaning.
    pub fn sinkRemoveStorage(self: *HostEnv, area: boundary.StorageArea, key: []const u8) void {
        self.removeStorage(area, key);
    }

    /// Adapts the shared engine's debug assert node command to this host without re-deciding reactive meaning.
    pub fn sinkDebugAssertNode(self: *HostEnv, elem_id: ids.ElemId, active: bool, tag: ?[]const u8, parent_id: ?ids.ElemId, children: []const ids.ElemId, click_event: ?ids.EventId, input_event: ?ids.EventId, check_event: ?ids.EventId, pointer_down_event: ?ids.EventId, pointer_up_event: ?ids.EventId, pointer_enter_event: ?ids.EventId, pointer_leave_event: ?ids.EventId) void {
        if (elem_id.index() >= self.dom_elements.items.len) {
            if (!active) return;
            failHost("render cache active node was missing from simulated DOM");
        }

        const elem = &self.dom_elements.items[elem_id.index()];
        if (elem.active != active) failHost("render cache active flag disagreed with simulated DOM");
        if (!active) return;

        const expected_tag = tag orelse failHost("active render cache node had no tag");
        if (!std.mem.eql(u8, elem.tag, expected_tag)) failHost("render cache tag disagreed with simulated DOM");
        if (elem.parent_id != ids.optionalElemRaw(parent_id)) failHost("render cache parent disagreed with simulated DOM");
        if (!std.mem.eql(u64, elem.children.items, ids.elemSliceRaw(children))) failHost("render cache child order disagreed with simulated DOM");
        if (sim_dom.fixedEventId(elem, .click) != ids.optionalEventRaw(click_event)) failHost("render cache click binding disagreed with simulated DOM");
        if (sim_dom.fixedEventId(elem, .input) != ids.optionalEventRaw(input_event)) failHost("render cache input binding disagreed with simulated DOM");
        if (sim_dom.fixedEventId(elem, .check) != ids.optionalEventRaw(check_event)) failHost("render cache check binding disagreed with simulated DOM");
        if (sim_dom.fixedEventId(elem, .pointer_down) != ids.optionalEventRaw(pointer_down_event)) failHost("render cache pointer-down binding disagreed with simulated DOM");
        if (sim_dom.fixedEventId(elem, .pointer_up) != ids.optionalEventRaw(pointer_up_event)) failHost("render cache pointer-up binding disagreed with simulated DOM");
        if (sim_dom.fixedEventId(elem, .pointer_enter) != ids.optionalEventRaw(pointer_enter_event)) failHost("render cache pointer-enter binding disagreed with simulated DOM");
        if (sim_dom.fixedEventId(elem, .pointer_leave) != ids.optionalEventRaw(pointer_leave_event)) failHost("render cache pointer-leave binding disagreed with simulated DOM");
    }

    fn activeRocHost(self: *HostEnv) *abi.RocHost {
        return self.engine.roc_host orelse failHost("HostValue capability release requires an active Roc host");
    }

    fn releaseOwnedHostValueCapability(self: *HostEnv, cap: HostValueCapability) void {
        hv.releaseHostValueCapability(cap, self.activeRocHost());
    }

    fn hostValueRegistryOps(self: *HostEnv) hv.RegistryOps() {
        return .{
            .roc_host = self.activeRocHost(),
            .active_capabilities = &self.active_capabilities,
            .debug_phase = &self.debug_phase,
        };
    }

    /// Opens a checked capability frame for an app-compiled erased call.
    pub fn pushHostValueCapabilities(self: *HostEnv, caps: []const HostValueCapability) void {
        self.active_capabilities.push(caps);
    }

    /// Closes the current capability frame after an app-compiled erased call.
    pub fn popHostValueCapabilities(self: *HostEnv) void {
        self.active_capabilities.pop();
    }

    // `ctx` surface consumed by the shared `host_values` box constructors
    // (`pub` so the `host_values` module can call them through `anytype`).
    /// Transfers an owned Roc box into the host value registry.
    pub fn store(self: *HostEnv, box: abi.RocBox) HostValue {
        return self.storeHostValue(box);
    }

    /// Transfers an owned Roc box into a registry cell tied to its exact capability.
    pub fn storeWithCapability(self: *HostEnv, box: abi.RocBox, cap: HostValueCapability) HostValue {
        return self.storeHostValueWithRetainedCapability(box, cap);
    }

    /// Records the debug-only value kind used to detect erased-value routing mistakes.
    pub fn recordKind(self: *HostEnv, value: HostValue, kind: hv.ValueKind) void {
        if (host_fixtures) self.setTestHostValueKind(value, switch (kind) {
            .unit => .unit,
            .str => .str,
            .bool => .bool,
            .i64 => .i64,
            .u8_list => .u8_list,
        });
    }

    fn resetTestHostValueKind(self: *HostEnv, value: HostValue) void {
        if (host_fixtures) {
            const allocator = self.hostAllocator();
            const index = value.registryIndex();
            if (index >= self.test_host_value_kinds.items.len) {
                self.test_host_value_kinds.append(allocator, null) catch std.process.exit(1);
            } else {
                self.test_host_value_kinds.items[@intCast(index)] = null;
            }
        }
    }

    fn storeHostValueWithOwnedCapability(self: *HostEnv, box: abi.RocBox, owned_cap: HostValueCapability) HostValue {
        const allocator = self.hostAllocator();
        const previous_phase = self.debug_phase;
        self.debug_phase = .host_value_store;
        defer self.debug_phase = previous_phase;
        const value = self.engine.host_values.storeOwnedCapability(allocator, box, owned_cap, self.hostValueRegistryOps()) catch |err| {
            failHostValueRegistryError(err);
        };
        self.resetTestHostValueKind(value);
        return value;
    }

    fn storeHostValueWithRetainedCapability(self: *HostEnv, box: abi.RocBox, borrowed_cap: HostValueCapability) HostValue {
        const allocator = self.hostAllocator();
        const value = self.engine.host_values.storeRetainedCapability(allocator, box, borrowed_cap, self.hostValueRegistryOps()) catch |err| {
            failHostValueRegistryError(err);
        };
        self.resetTestHostValueKind(value);
        return value;
    }

    fn storeHostValueWithExistingCapability(self: *HostEnv, box: abi.RocBox, source_value: HostValue) HostValue {
        const allocator = self.hostAllocator();
        const previous_phase = self.debug_phase;
        self.debug_phase = .host_value_store;
        defer self.debug_phase = previous_phase;
        const value = self.engine.host_values.storeRetainedExistingCapability(allocator, box, source_value, self.hostValueRegistryOps()) catch |err| {
            failHostValueRegistryError(err);
        };
        self.resetTestHostValueKind(value);
        if (host_fixtures) {
            self.setTestHostValueKind(value, self.testHostValueKind(source_value));
        }
        return value;
    }

    fn storeHostValue(self: *HostEnv, box: abi.RocBox) HostValue {
        const allocator = self.hostAllocator();
        const value = self.engine.host_values.storeOwnedCapability(allocator, box, null, self.hostValueRegistryOps()) catch |err| {
            failHostValueRegistryError(err);
        };
        self.resetTestHostValueKind(value);
        return value;
    }

    fn setTestHostValueKind(self: *HostEnv, value: HostValue, kind: TestHostValueKind) void {
        if (!host_fixtures) @compileError("setTestHostValueKind is test-only");
        const index = value.registryIndex();
        if (index >= self.test_host_value_kinds.items.len) failHost("test HostValue kind referenced an unknown value");
        self.test_host_value_kinds.items[@intCast(index)] = kind;
    }

    fn testHostValueKind(self: *HostEnv, value: HostValue) TestHostValueKind {
        if (!host_fixtures) @compileError("testHostValueKind is test-only");
        const index = value.registryIndex();
        if (index >= self.test_host_value_kinds.items.len) failHost("test HostValue kind referenced an unknown value");
        return self.test_host_value_kinds.items[@intCast(index)] orelse @panic("test HostValue kind was not recorded");
    }

    fn setHostValueCapability(self: *HostEnv, value: HostValue, borrowed_cap: HostValueCapability) void {
        self.engine.host_values.setCapability(value, borrowed_cap, self.hostValueRegistryOps()) catch |err| {
            failHostValueRegistryError(err);
        };
    }

    fn getHostValue(self: *HostEnv, value: HostValue) abi.RocBox {
        const previous_phase = self.debug_phase;
        self.debug_phase = .host_value_get;
        defer self.debug_phase = previous_phase;
        return self.engine.host_values.get(self.hostAllocator(), value, self.hostValueRegistryOps()) catch |err| {
            failHostValueRegistryError(err);
        };
    }

    fn getHostValueWithCapability(self: *HostEnv, value: HostValue, owned_cap: HostValueCapability) abi.RocBox {
        const previous_phase = self.debug_phase;
        self.debug_phase = .host_value_get;
        defer self.debug_phase = previous_phase;
        defer self.releaseOwnedHostValueCapability(owned_cap);
        return self.engine.host_values.getWithCapability(self.hostAllocator(), value, owned_cap, self.hostValueRegistryOps()) catch |err| {
            failHostValueRegistryError(err);
        };
    }

    fn getHostValueWithSplit(self: *HostEnv, value: HostValue, owned_split: CapabilitySplit) abi.RocBox {
        const previous_phase = self.debug_phase;
        self.debug_phase = .host_value_get_with_split;
        defer self.debug_phase = previous_phase;
        defer abi.decrefErasedCallable(owned_split.toAbi(), self.activeRocHost());
        return self.engine.host_values.getWithSplit(value, owned_split, self.hostValueRegistryOps()) catch |err| {
            failHostValueRegistryError(err);
        };
    }

    fn takeHostValue(self: *HostEnv, value: HostValue) abi.RocBox {
        const box = self.engine.host_values.take(value, self.hostValueRegistryOps()) catch |err| {
            failHostValueRegistryError(err);
        };
        if (host_fixtures) self.test_host_value_kinds.items[value.registryIndex()] = null;
        return box;
    }

    fn takeHostValueWithCapability(self: *HostEnv, value: HostValue, owned_cap: HostValueCapability) abi.RocBox {
        const previous_phase = self.debug_phase;
        self.debug_phase = .host_value_take;
        defer self.debug_phase = previous_phase;
        defer self.releaseOwnedHostValueCapability(owned_cap);
        return self.engine.host_values.takeWithCapability(value, owned_cap, self.hostValueRegistryOps()) catch |err| {
            failHostValueRegistryError(err);
        };
    }

    fn takeHostValueWithSplit(self: *HostEnv, value: HostValue, owned_split: CapabilitySplit) abi.RocBox {
        const previous_phase = self.debug_phase;
        self.debug_phase = .host_value_take_with_split;
        defer self.debug_phase = previous_phase;
        defer abi.decrefErasedCallable(owned_split.toAbi(), self.activeRocHost());
        const box = self.engine.host_values.takeWithSplit(value, owned_split, self.hostValueRegistryOps()) catch |err| {
            failHostValueRegistryError(err);
        };
        if (host_fixtures) self.test_host_value_kinds.items[value.registryIndex()] = null;
        return box;
    }

    fn hostValueTakeEpoch(self: *const HostEnv) u64 {
        return self.engine.host_values.takeEpoch();
    }

    fn assertHostValueTakenAfter(self: *HostEnv, value: HostValue, epoch: u64) void {
        self.engine.host_values.assertTakenAfter(value, epoch) catch |err| {
            failHostValueRegistryError(err);
        };
    }

    fn currentLocation(self: *const HostEnv) boundary.LocationSnapshot {
        if (self.location_history.items.len == 0) {
            return .{ .path = "/", .query = "", .hash = "" };
        }
        return self.location_history.items[self.location_index].snapshot();
    }

    fn clearLocationHistory(self: *HostEnv) void {
        const allocator = self.hostAllocator();
        for (self.location_history.items) |entry| {
            entry.deinit(allocator);
        }
        self.location_history.clearRetainingCapacity();
        self.location_index = 0;
    }

    fn setCurrentLocation(self: *HostEnv, location: boundary.LocationSnapshot) void {
        const allocator = self.hostAllocator();
        self.clearLocationHistory();
        self.location_history.append(allocator, NativeLocation.init(allocator, location)) catch @panic("out of memory");
        self.location_index = 0;
    }

    fn ensureLocationHistory(self: *HostEnv) void {
        if (self.location_history.items.len != 0) return;
        self.setCurrentLocation(.{ .path = "/", .query = "", .hash = "" });
    }

    fn clearForwardLocationHistory(self: *HostEnv) void {
        const allocator = self.hostAllocator();
        if (self.location_history.items.len == 0) return;
        var index = self.location_index + 1;
        while (index < self.location_history.items.len) : (index += 1) {
            self.location_history.items[index].deinit(allocator);
        }
        self.location_history.items.len = self.location_index + 1;
    }

    fn pushCurrentLocation(self: *HostEnv, location: boundary.LocationSnapshot) void {
        const allocator = self.hostAllocator();
        self.ensureLocationHistory();
        self.clearForwardLocationHistory();
        self.location_history.append(allocator, NativeLocation.init(allocator, location)) catch @panic("out of memory");
        self.location_index = self.location_history.items.len - 1;
    }

    fn replaceCurrentLocation(self: *HostEnv, location: boundary.LocationSnapshot) void {
        const allocator = self.hostAllocator();
        self.ensureLocationHistory();
        self.location_history.items[self.location_index].deinit(allocator);
        self.location_history.items[self.location_index] = NativeLocation.init(allocator, location);
    }

    fn backCurrentLocation(self: *HostEnv) bool {
        if (self.location_history.items.len == 0 or self.location_index == 0) return false;
        self.location_index -= 1;
        return true;
    }

    fn forwardCurrentLocation(self: *HostEnv) bool {
        if (self.location_index + 1 >= self.location_history.items.len) return false;
        self.location_index += 1;
        return true;
    }

    fn initialLocationPayload(self: *HostEnv, roc_host: *abi.RocHost, cap: HostValueCapability) HostValue {
        const bytes = boundary.encodeLocationPayload(self.hostAllocator(), self.currentLocation()) catch |err| switch (err) {
            error.OutOfMemory => failHost("location payload allocation failed"),
            error.BoundaryTextTooLong => failHost("location payload field exceeded boundary length"),
        };
        defer self.hostAllocator().free(bytes);
        return hv.makeU8ListWithCapability(self, roc_host, bytes, cap);
    }

    fn initialVisibilityPayload(self: *HostEnv, roc_host: *abi.RocHost, cap: HostValueCapability) HostValue {
        const bytes = boundary.encodeVisibilityPayload(self.hostAllocator(), self.visibility) catch |err| switch (err) {
            error.OutOfMemory => failHost("visibility payload allocation failed"),
            error.BoundaryTextTooLong => unreachable,
        };
        defer self.hostAllocator().free(bytes);
        return hv.makeU8ListWithCapability(self, roc_host, bytes, cap);
    }

    fn setVisibility(self: *HostEnv, visibility: boundary.VisibilitySnapshot) void {
        self.visibility = visibility;
    }

    fn initialOnlinePayload(self: *HostEnv, roc_host: *abi.RocHost, cap: HostValueCapability) HostValue {
        const bytes = boundary.encodeOnlinePayload(self.hostAllocator(), self.online) catch |err| switch (err) {
            error.OutOfMemory => failHost("online payload allocation failed"),
            error.BoundaryTextTooLong => unreachable,
        };
        defer self.hostAllocator().free(bytes);
        return hv.makeU8ListWithCapability(self, roc_host, bytes, cap);
    }

    fn setOnline(self: *HostEnv, online: boundary.OnlineSnapshot) void {
        self.online = online;
    }

    fn storageEntryIndex(self: *const HostEnv, area: boundary.StorageArea, key: []const u8) ?usize {
        for (self.storage_entries.items, 0..) |entry, index| {
            if (entry.area == area and std.mem.eql(u8, entry.key, key)) return index;
        }
        return null;
    }

    fn storageValue(self: *const HostEnv, area: boundary.StorageArea, key: []const u8) ?[]const u8 {
        const index = self.storageEntryIndex(area, key) orelse return null;
        return self.storage_entries.items[index].value;
    }

    fn setStorageText(self: *HostEnv, area: boundary.StorageArea, key: []const u8, value: []const u8) void {
        const allocator = self.hostAllocator();
        if (self.storageEntryIndex(area, key)) |index| {
            allocator.free(self.storage_entries.items[index].value);
            self.storage_entries.items[index].value = allocator.dupe(u8, value) catch @panic("out of memory");
            return;
        }
        self.storage_entries.append(allocator, NativeStorageEntry.init(allocator, area, key, value)) catch @panic("out of memory");
    }

    fn removeStorage(self: *HostEnv, area: boundary.StorageArea, key: []const u8) void {
        const allocator = self.hostAllocator();
        const index = self.storageEntryIndex(area, key) orelse return;
        const removed = self.storage_entries.swapRemove(index);
        removed.deinit(allocator);
    }

    fn setDocumentTitle(self: *HostEnv, title: []const u8) void {
        const allocator = self.hostAllocator();
        self.clearDocumentTitle();
        self.document_title = allocator.dupe(u8, title) catch @panic("out of memory");
    }

    fn currentDocumentTitle(self: *const HostEnv) []const u8 {
        return self.document_title orelse "";
    }

    fn clearDocumentTitle(self: *HostEnv) void {
        if (self.document_title) |title| {
            self.hostAllocator().free(title);
            self.document_title = null;
        }
    }

    fn clearStorage(self: *HostEnv) void {
        const allocator = self.hostAllocator();
        for (self.storage_entries.items) |entry| {
            entry.deinit(allocator);
        }
        self.storage_entries.clearRetainingCapacity();
    }

    fn initialStoragePayload(self: *HostEnv, roc_host: *abi.RocHost, area: boundary.StorageArea, key: []const u8, cap: HostValueCapability) HostValue {
        const snapshot: boundary.StorageSnapshot = if (self.storageValue(area, key)) |value| .{ .value = value } else .missing;
        const bytes = boundary.encodeStoragePayload(self.hostAllocator(), snapshot) catch |err| switch (err) {
            error.OutOfMemory => failHost("storage payload allocation failed"),
            error.BoundaryTextTooLong => failHost("storage payload field exceeded boundary length"),
        };
        defer self.hostAllocator().free(bytes);
        return hv.makeU8ListWithCapability(self, roc_host, bytes, cap);
    }

    // `pub` so the shared `engine.HostValueCell.cloneRetained` can clone a value
    // through the host's registry (the engine treats `self` as its clone ctx).
    /// Produces an independently owned copy through the value's app-compiled capability.
    pub fn cloneHostValue(self: *HostEnv, value: HostValue) HostValue {
        const allocator = self.hostAllocator();
        const previous_phase = self.debug_phase;
        self.debug_phase = .host_value_clone;
        defer self.debug_phase = previous_phase;
        const cloned = self.engine.host_values.clone(allocator, value, self.hostValueRegistryOps()) catch |err| {
            failHostValueRegistryError(err);
        };
        self.resetTestHostValueKind(cloned);
        if (host_fixtures) {
            self.setTestHostValueKind(cloned, self.testHostValueKind(value));
        }
        return cloned;
    }

    fn nextDirtySignalGeneration(self: *HostEnv) u64 {
        return self.engine.nextDirtySignalGeneration();
    }

    fn clearEventDescriptors(self: *HostEnv) void {
        self.engine.clearEventDescriptors();
    }

    fn clearActiveEvents(self: *HostEnv) void {
        self.engine.clearActiveEvents() catch |err| {
            failRocHostRequiredError(err, "active event table cannot release retained payloads without a Roc host");
        };
    }

    fn rebuildActiveEventsFromStream(self: *HostEnv, stream: *HostNodeDescriptorStream) void {
        return self.engine.rebuildActiveEventsFromStream(self, stream);
    }

    fn clearSignalEventRoutes(self: *HostEnv) void {
        const allocator = self.hostAllocator();
        for (self.engine.signal_event_routes.items) |route| {
            allocator.free(route.signal_ids);
        }
        self.engine.signal_event_routes.items.len = 0;
    }

    fn rebuildSignalEventRoutesFromSignals(self: *HostEnv) void {
        const allocator = self.hostAllocator();
        var route_lists = allocator.alloc(std.ArrayListUnmanaged(u64), self.engine.event_descriptors.items.len) catch std.process.exit(1);
        defer allocator.free(route_lists);

        for (route_lists) |*list| {
            list.* = .empty;
        }
        errdefer {
            for (route_lists) |*list| {
                list.deinit(allocator);
            }
        }

        for (self.engine.signal_descriptors.items) |signal| {
            if (signal.kind != .source) continue;
            for (signal.source_event_ids) |event_id| {
                if (event_id == 0 or event_id > self.engine.event_descriptors.items.len) {
                    failHost("host source signal registry contains an unknown event id");
                }
                route_lists[@intCast(event_id - 1)].append(allocator, signal.signal_id) catch std.process.exit(1);
            }
        }

        self.clearSignalEventRoutes();

        for (route_lists, 0..) |*route_list, index| {
            const signal_ids = route_list.toOwnedSlice(allocator) catch std.process.exit(1);
            self.engine.signal_event_routes.append(allocator, .{
                .event_id = @intCast(index + 1),
                .signal_ids = signal_ids,
            }) catch {
                allocator.free(signal_ids);
                std.process.exit(1);
            };
        }
    }

    fn clearSignalDescriptors(self: *HostEnv) void {
        const allocator = self.hostAllocator();
        for (self.engine.signal_descriptors.items) |descriptor| {
            allocator.free(descriptor.source_state_ids);
            allocator.free(descriptor.source_event_ids);
            allocator.free(descriptor.input_signal_ids);
        }
        self.engine.signal_descriptors.items.len = 0;
    }

    fn clearSignalRoutes(self: *HostEnv) void {
        const allocator = self.hostAllocator();
        for (self.engine.signal_routes.items) |route| {
            allocator.free(route.signal_ids);
        }
        self.engine.signal_routes.items.len = 0;
    }

    fn clearSignalDependents(self: *HostEnv) void {
        const allocator = self.hostAllocator();
        for (self.engine.signal_dependents.items) |route| {
            allocator.free(route.signal_ids);
        }
        self.engine.signal_dependents.items.len = 0;
    }

    fn clearSignalCache(self: *HostEnv) void {
        self.engine.clearSignalCache(self) catch |err| {
            failRocHostRequiredError(err, "signal cache cannot release values without a Roc host");
        };
    }

    fn clearActiveSignalGraph(self: *HostEnv) void {
        return self.engine.clearActiveSignalGraph(self);
    }

    fn clearActiveSignalRoutes(self: *HostEnv) void {
        return self.engine.clearActiveSignalRoutes(self);
    }

    fn requireActiveSignalRecordId(self: *HostEnv, record: *const HostSignalRecord) u64 {
        return self.engine.requireActiveSignalRecordId(record);
    }

    fn rebuildSignalTopologyFromSignals(self: *HostEnv) void {
        const allocator = self.hostAllocator();
        const signal_count = self.engine.signal_descriptors.items.len;
        var route_lists = allocator.alloc(std.ArrayListUnmanaged(u64), signal_count) catch std.process.exit(1);
        defer allocator.free(route_lists);
        const ranks = allocator.alloc(u64, signal_count) catch std.process.exit(1);
        defer allocator.free(ranks);

        for (route_lists) |*list| {
            list.* = .empty;
        }
        @memset(ranks, 0);

        errdefer {
            for (route_lists) |*list| {
                list.deinit(allocator);
            }
        }

        for (self.engine.signal_descriptors.items, 0..) |*signal, index| {
            if (signal.signal_id != index) {
                failHost("host signal registry is not indexed by signal id");
            }

            for (signal.input_signal_ids) |input_signal_id| {
                if (input_signal_id >= index) {
                    failHost("host signal topology must reference prior signal ids");
                }

                const input_index: usize = @intCast(input_signal_id);
                const next_rank = ranks[input_index] + 1;
                if (next_rank > ranks[index]) {
                    ranks[index] = next_rank;
                }
                if (!u64SliceContains(route_lists[input_index].items, signal.signal_id)) {
                    route_lists[input_index].append(allocator, signal.signal_id) catch std.process.exit(1);
                }
            }

            signal.rank = ranks[index];
        }

        self.clearSignalDependents();

        for (route_lists, 0..) |*route_list, index| {
            const signal_ids = route_list.toOwnedSlice(allocator) catch std.process.exit(1);
            self.engine.signal_dependents.append(allocator, .{
                .signal_id = @intCast(index),
                .signal_ids = signal_ids,
            }) catch {
                allocator.free(signal_ids);
                std.process.exit(1);
            };
        }
    }

    fn signalRank(self: *HostEnv, signal_id: u64) u64 {
        return self.engine.signalRank(signal_id) catch |err| {
            failSignalLookupError(err);
        };
    }

    fn activeSignalRank(self: *HostEnv, record_id: u64) u64 {
        return self.engine.activeSignalRank(record_id);
    }

    fn dependentActiveSignalRecordIds(self: *HostEnv, record_id: u64) []const u64 {
        return self.engine.dependentActiveSignalRecordIds(record_id);
    }

    fn recordDispatch(self: *HostEnv) void {
        self.engine.recordDispatch();
    }

    fn deinitPendingTask(self: *HostEnv, task: *HostPendingTask) void {
        return self.engine.deinitPendingTask(self, task);
    }

    fn clearPendingTasks(self: *HostEnv) void {
        self.engine.clearPendingTasks(self);
    }

    fn clearStates(self: *HostEnv) void {
        self.engine.clearStates(self) catch |err| {
            failRocHostRequiredError(err, "state table cannot release values without a Roc host");
        };
    }

    /// Resolves a state cell by dense node id without scanning the signal graph.
    pub fn stateValueByNodeId(self: *HostEnv, node_id: ids.NodeId) HostValue {
        const state_index = self.engine.stateIndexByNodeId(node_id.raw()) orelse failHost("signal referenced an unknown active state node");
        return self.cloneHostValue(self.engine.states.items[state_index].activePayloadConst().cell.value);
    }

    /// Replaces a state source value and enters the ordinary dirty-propagation path.
    pub fn updateStateValue(self: *HostEnv, roc_host: *abi.RocHost, node_id: ids.NodeId, value: HostValue) bool {
        const state_index = self.engine.stateIndexByNodeId(node_id.raw()) orelse failHost("event referenced an unknown active state node");
        const state = &self.engine.states.items[state_index];
        const payload = state.activePayload();
        if (payload.cell.valueEquals(self, roc_host, value)) {
            payload.cell.dropIncoming(self, roc_host, value);
            return false;
        }

        payload.cell.replaceValue(self, roc_host, value);
        payload.version += 1;
        return true;
    }

    /// Returns the exact app-compiled capability that owns the requested state cell.
    pub fn stateCapability(self: *HostEnv, node_id: ids.NodeId) HostValueCapability {
        return self.engine.stateCapability(node_id.raw()) catch |err| switch (err) {
            error.MissingActiveState => failHost("active state has no capability"),
        };
    }

    fn validateScopeId(self: *HostEnv, scope_id: ids.ScopeId) void {
        self.engine.validateScopeId(scope_id.raw()) catch |err| {
            failScopeTreeError(err, "scope id has no host scope descriptor");
        };
    }

    fn internRootScope(self: *HostEnv) ids.ScopeId {
        const result = self.engine.internRootScope(self.hostAllocator()) catch |err| {
            failScopeTreeError(err, "scope id has no host scope descriptor");
        };
        return result.scope_id;
    }

    fn internComponentScope(self: *HostEnv, parent_scope_id: ids.ScopeId, site_ordinal: ids.SiteOrdinal) ids.ScopeId {
        const result = self.engine.internComponentScope(self.hostAllocator(), parent_scope_id, site_ordinal) catch |err| {
            failScopeTreeError(err, "scope id has no host scope descriptor");
        };
        return result.scope_id;
    }

    fn internWhenBranchScope(self: *HostEnv, parent_scope_id: ids.ScopeId, site_ordinal: ids.SiteOrdinal, branch: HostScopeBranch) ids.ScopeId {
        const result = self.engine.internWhenBranchScope(self.hostAllocator(), parent_scope_id, site_ordinal, branch) catch |err| {
            failScopeTreeError(err, "scope id has no host scope descriptor");
        };
        return result.scope_id;
    }

    fn createEachRowScope(self: *HostEnv, parent_scope_id: ids.ScopeId, site_ordinal: ids.SiteOrdinal, key_hash: u64, key: HostValue, item: HostValue, key_cap: HostValueCapability, item_cap: HostValueCapability) ids.ScopeId {
        return self.engine.createEachRowScope(self, parent_scope_id, site_ordinal, key_hash, key, item, key_cap, item_cap);
    }

    fn internNodeIdentity(self: *HostEnv, scope_id: ids.ScopeId, ordinal: ids.SiteOrdinal) ids.NodeId {
        return self.engine.internNodeIdentity(self.hostAllocator(), scope_id, ordinal) catch |err| {
            failScopeOrIdentityTableError(err, "scope id has no host scope descriptor");
        };
    }

    fn internDomIdentity(self: *HostEnv, scope_id: ids.ScopeId, ordinal: ids.SiteOrdinal) ids.ElemId {
        return self.engine.internDomIdentity(self.hostAllocator(), scope_id, ordinal) catch |err| {
            failScopeOrIdentityTableError(err, "scope id has no host scope descriptor");
        };
    }

    fn disposeScopeSubtree(self: *HostEnv, roc_host: *abi.RocHost, scope_id: ids.ScopeId) void {
        self.engine.disposeScopeSubtree(self, roc_host, scope_id.raw());
    }

    fn eachRowScopeValues(self: *HostEnv, scope_id: ids.ScopeId) engine.EachRowValues {
        return self.engine.eachRowScopeValues(scope_id.raw());
    }

    fn syncEachRowScopes(self: *HostEnv, roc_host: *abi.RocHost, parent_scope_id: ids.ScopeId, site_ordinal: ids.SiteOrdinal, keys: []const HostValue, items: []const HostValue, ops: HostEachOps) HostKeyedRowDiffResult {
        return self.engine.syncEachRowScopes(self, roc_host, parent_scope_id, site_ordinal, keys, items, ops);
    }

    fn bindNodeSignal(self: *HostEnv, allocator: std.mem.Allocator, stream: *HostNodeDescriptorStream, expr: abi.NodeSignalExpr, binder_stack: []const HostBinderBinding) HostSignalBinding {
        return self.engine.bindNodeSignal(allocator, stream, expr, binder_stack);
    }

    fn activeWhenBranchScopeId(self: *HostEnv, parent_scope_id: ids.ScopeId, site_ordinal: ids.SiteOrdinal, branch: HostScopeBranch) ?ids.ScopeId {
        const raw = self.engine.activeWhenBranchScopeId(parent_scope_id.raw(), site_ordinal.raw(), branch) catch |err| {
            failScopeTreeError(err, "scope id has no host scope descriptor");
        };
        return if (raw) |scope_id| ids.ScopeId.fromRaw(scope_id) else null;
    }

    fn collectActiveElemRootDescriptors(self: *HostEnv, roc_host: *abi.RocHost, stream: *HostNodeDescriptorStream, root: abi.Elem, dirty_source_node_ids: []const u64) void {
        return self.engine.collectActiveElemRootDescriptors(self, roc_host, stream, root, dirty_source_node_ids);
    }

    fn clearScopes(self: *HostEnv) void {
        self.engine.clearScopes(self) catch |err| {
            failRocHostRequiredError(err, "host scope table cannot release keys without a Roc host");
        };
    }

    fn deinit(self: *HostEnv) void {
        const allocator = self.hostAllocator();

        self.clearActiveSignalRoutes();
        self.engine.active_source_signal_routes.deinit(allocator);
        self.engine.active_text_signal_routes.deinit(allocator);
        self.engine.active_bool_signal_routes.deinit(allocator);
        self.engine.active_change_signal_routes.deinit(allocator);
        self.engine.active_structural_signal_routes.deinit(allocator);
        self.engine.clearActiveIntervals(self);
        self.engine.active_intervals.deinit(allocator);
        self.clearActiveSignalGraph();
        self.engine.active_signal_graph.deinit(allocator);
        self.engine.active_stream.deinit(allocator, self, self.engine.roc_host.?, &self.engine.pending_roc_metrics);
        self.clearActiveEvents();
        self.engine.active_events.deinit(allocator);

        self.clearPendingTasks();
        self.engine.pending_tasks.deinit(allocator);
        self.deinitTaskRecords();

        engine.deinitCleanupEvents(allocator, &self.engine.cleanup_events);

        if (self.engine.root_elem) |root| {
            root.decref(self.engine.roc_host.?);
            self.engine.root_elem = null;
        }

        for (self.dom_elements.items) |*elem| {
            elem.deinit(allocator);
        }
        self.dom_elements.deinit(allocator);
        self.clearEventDescriptors();
        self.engine.event_descriptors.deinit(allocator);
        self.clearSignalEventRoutes();
        self.engine.signal_event_routes.deinit(allocator);
        self.clearSignalDescriptors();
        self.engine.signal_descriptors.deinit(allocator);
        self.clearSignalRoutes();
        self.engine.signal_routes.deinit(allocator);
        self.clearSignalDependents();
        self.engine.signal_dependents.deinit(allocator);
        self.clearSignalCache();
        self.engine.signal_cache.deinit(allocator);
        self.clearStates();
        self.engine.states.deinit(allocator);
        self.engine.state_indexes_by_node_id.deinit(allocator);
        self.clearScopes();
        self.engine.scopes.deinit(allocator);
        self.engine.node_identities.deinit(allocator);
        self.engine.dom_identities.deinit(allocator);
        self.engine.active_node_identity_ids.deinit(allocator);
        self.engine.active_dom_identity_ids.deinit(allocator);
        self.engine.deinitRenderCache(self);
        self.engine.deinitScratch(self);
        self.clearLocationHistory();
        self.location_history.deinit(allocator);
        self.clearStorage();
        self.storage_entries.deinit(allocator);
        self.clearDocumentTitle();

        freeSpecCommands(allocator, self.test_state.commands);

        if (self.engine.host_values.hasLiveValues()) failHost("host value registry still owned a typed cell at shutdown");
        self.engine.host_values.deinit(allocator);
        self.test_host_value_kinds.deinit(allocator);

        if (self.roc_allocations.allocations.items.len != 0) {
            var buf: [256]u8 = undefined;
            const summary = std.fmt.bufPrint(&buf, "native host shutdown retained {d} Roc allocations / {d} bytes\n", .{
                self.roc_allocations.allocations.items.len,
                self.roc_allocations.snapshot().live_bytes,
            }) catch "native host shutdown retained Roc allocations\n";
            writeStderr(summary);
            for (self.roc_allocations.allocations.items) |alloc| {
                const detail = std.fmt.bufPrint(&buf, "  phase={d} caller=0x{x} size={d} ptr=0x{x}\n", .{
                    @intFromEnum(alloc.phase),
                    alloc.return_address,
                    alloc.requested_size,
                    @intFromPtr(alloc.user_ptr),
                }) catch "  allocation detail unavailable\n";
                writeStderr(detail);
            }
            failHost("native host leaked Roc allocations at shutdown");
        }
        self.roc_allocations.deinit(allocator);
    }

    fn appendDescendantText(self: *HostEnv, elem: *const DomElement, text: *std.ArrayListUnmanaged(u8)) void {
        for (elem.children.items) |child_id| {
            if (child_id >= self.dom_elements.items.len) continue;
            const child = &self.dom_elements.items[@intCast(child_id)];
            if (!child.active) continue;
            if (child.text) |child_text| text.appendSlice(self.hostAllocator(), child_text) catch @panic("out of memory");
            self.appendDescendantText(child, text);
        }
    }

    fn matchesLocator(self: *HostEnv, elem: *const DomElement, locator: Locator) bool {
        if (locator.kind != .role_name or sim_dom.accessibleName(elem).len != 0) {
            return sim_dom.matchesLocator(elem, locator);
        }

        var descendant_text: std.ArrayListUnmanaged(u8) = .empty;
        defer descendant_text.deinit(self.hostAllocator());
        self.appendDescendantText(elem, &descendant_text);
        return sim_dom.matchesLocatorWithAccessibleName(elem, locator, descendant_text.items);
    }

    fn findElementByLocator(self: *HostEnv, locator: Locator, line_num: usize) ?*DomElement {
        var found: ?*DomElement = null;
        var match_count: usize = 0;
        for (self.dom_elements.items) |*elem| {
            if (!elem.active) continue;
            if (!self.matchesLocator(elem, locator)) continue;
            match_count += 1;
            if (found == null) found = elem;
        }

        if (match_count > 1) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "TEST FAILED at line {d}: locator matched {d} elements\n", .{ line_num, match_count }) catch "TEST FAILED: ambiguous locator\n";
            writeStderr(msg);
            if (self.test_state.verbose) self.dumpDom();
            return null;
        }
        if (found == null and self.test_state.verbose) self.dumpDom();
        return found;
    }

    fn countElementsByLocator(self: *HostEnv, locator: Locator) usize {
        var match_count: usize = 0;
        for (self.dom_elements.items) |*elem| {
            if (!elem.active) continue;
            if (!self.matchesLocator(elem, locator)) continue;
            match_count += 1;
        }
        return match_count;
    }

    fn dumpDom(self: *HostEnv) void {
        for (self.dom_elements.items, 0..) |elem, idx| {
            var dbg_buf: [512]u8 = undefined;
            const dbg_msg = std.fmt.bufPrint(&dbg_buf, "[DEBUG] elem[{d}] tag=\"{s}\" text=\"{s}\" value=\"{s}\" parent={?d} children={d} active={} updates={d}\n", .{
                idx,
                elem.tag,
                elem.text orelse "(null)",
                elem.value orelse "(null)",
                elem.parent_id,
                elem.children.items.len,
                elem.active,
                elem.text_update_count + elem.value_update_count + elem.checked_update_count + elem.disabled_update_count,
            }) catch "";
            writeStderr(dbg_msg);
        }
    }

    fn traceAllocationCheckpoint(self: *HostEnv, line_num: usize, command_name: []const u8) void {
        if (!self.test_state.trace_allocations) return;

        const previous = self.test_state.allocation_snapshot;
        const current = self.roc_allocations.snapshot();
        const new_live_count = self.roc_allocations.liveCountSince(previous);
        const new_live_bytes = self.roc_allocations.liveBytesSince(previous);
        var old_live_count: usize = 0;
        var old_live_bytes: usize = 0;
        for (self.roc_allocations.allocations.items) |alloc| {
            if (alloc.id < previous.next_id) {
                old_live_count += 1;
                old_live_bytes += alloc.requested_size;
            }
        }
        const freed_count = previous.live_count -| old_live_count;
        const freed_bytes = previous.live_bytes -| old_live_bytes;
        const combined_live_count = self.host_alloc_count -| self.host_dealloc_count;
        const combined_live_bytes = self.host_alloc_bytes -| self.host_dealloc_bytes;
        var roc_backing_bytes: u64 = 0;
        for (self.roc_allocations.allocations.items) |alloc| {
            roc_backing_bytes += HostEnv.hostMetricBytes(alloc.allocated_size);
        }
        // The host allocator backs both host-owned collections and the Roc
        // ledger's user blocks. Subtract live Roc blocks to avoid reporting the
        // same retained allocation as both a Roc leak and a host leak.
        const host_live_count = combined_live_count -| @as(u64, @intCast(current.live_count));
        const host_live_bytes = combined_live_bytes -| roc_backing_bytes;
        const host_count_delta: i128 = @as(i128, host_live_count) - @as(i128, self.test_state.trace_host_live_count);
        const host_bytes_delta: i128 = @as(i128, host_live_bytes) - @as(i128, self.test_state.trace_host_live_bytes);

        var buf: [512]u8 = undefined;
        const summary = std.fmt.bufPrint(&buf, "[ALLOC TRACE] line={d} command={s} roc_live={d}/{d}B roc_metric_live={d} roc_new_live={d}/{d}B roc_freed={d}/{d}B host_values={d} host_only_live={d}/{d}B host_only_delta={d}/{d}B\n", .{
            line_num,
            command_name,
            current.live_count,
            current.live_bytes,
            self.alloc_count -| self.dealloc_count,
            new_live_count,
            new_live_bytes,
            freed_count,
            freed_bytes,
            self.engine.host_values.liveCount(),
            host_live_count,
            host_live_bytes,
            host_count_delta,
            host_bytes_delta,
        }) catch "[ALLOC TRACE] checkpoint formatting failed\n";
        writeStderr(summary);

        for (self.roc_allocations.allocations.items, 0..) |alloc, index| {
            if (alloc.id < previous.next_id) continue;
            var first = true;
            for (self.roc_allocations.allocations.items[0..index]) |earlier| {
                if (earlier.id >= previous.next_id and earlier.phase == alloc.phase and earlier.return_address == alloc.return_address and earlier.requested_size == alloc.requested_size) {
                    first = false;
                    break;
                }
            }
            if (!first) continue;

            var cohort_count: usize = 0;
            var cohort_bytes: usize = 0;
            for (self.roc_allocations.allocations.items[index..]) |candidate| {
                if (candidate.id >= previous.next_id and candidate.phase == alloc.phase and candidate.return_address == alloc.return_address and candidate.requested_size == alloc.requested_size) {
                    cohort_count += 1;
                    cohort_bytes += candidate.requested_size;
                }
            }
            const first_word: usize = if (alloc.allocated_size >= @sizeOf(usize))
                @as(*align(1) const usize, @ptrCast(alloc.user_ptr)).*
            else
                0;
            const cohort = std.fmt.bufPrint(&buf, "[ALLOC TRACE]   phase={d} caller=0x{x} size={d} count={d} bytes={d} sample=0x{x} first_word=0x{x}\n", .{
                @intFromEnum(alloc.phase),
                alloc.return_address,
                alloc.requested_size,
                cohort_count,
                cohort_bytes,
                @intFromPtr(alloc.user_ptr),
                first_word,
            }) catch "[ALLOC TRACE] cohort formatting failed\n";
            writeStderr(cohort);
        }
        self.test_state.allocation_snapshot = current;
        self.test_state.trace_host_live_count = host_live_count;
        self.test_state.trace_host_live_bytes = host_live_bytes;
    }
};

fn zeroRuntimeMetrics() RuntimeMetrics {
    return engine.zeroRuntimeMetrics();
}

var current_host: ?*HostEnv = null;
var current_roc_host: ?*abi.RocHost = null;

fn hostFromRocHost(roc_host: *abi.RocHost) *HostEnv {
    return @ptrCast(@alignCast(roc_host.env));
}

fn currentRocHost() *abi.RocHost {
    return current_roc_host orelse @panic("signals RocHost is not initialized");
}

fn findExactRocAllocationIndex(host: *HostEnv, ptr: *anyopaque) ?usize {
    return host.roc_allocations.findExactIndex(ptr);
}

fn findRecentlyFreedRocAllocation(host: *HostEnv, ptr: *anyopaque) ?roc_alloc_ledger.FreedAllocation {
    return host.roc_allocations.findRecentlyFreed(ptr);
}

fn failRocDeallocError(err: roc_alloc_ledger.DeallocError) noreturn {
    failHost(roc_alloc_ledger.deallocErrorMessage(err));
}

fn failRocReallocError(err: roc_alloc_ledger.ReallocError) noreturn {
    failHost(roc_alloc_ledger.reallocErrorMessage(err));
}

fn rocAllocFn(roc_host: *abi.RocHost, length: usize, alignment: usize) callconv(.c) ?*anyopaque {
    return rocAllocAt(roc_host, length, alignment, @returnAddress());
}

fn rocAllocAt(roc_host: *abi.RocHost, length: usize, alignment: usize, return_address: usize) ?*anyopaque {
    const host = hostFromRocHost(roc_host);
    const result = host.roc_allocations.allocate(host.hostAllocator(), host.backingAllocator(), length, alignment, host.debug_phase, return_address) orelse failHost("Roc allocation failed");
    host.recordHostAlloc(result.allocated_size);
    host.recordRocAllocMetric();
    return result.ptr;
}

fn rocDeallocFn(roc_host: *abi.RocHost, ptr: *anyopaque, alignment: usize) callconv(.c) void {
    const host = hostFromRocHost(roc_host);
    const alloc = host.roc_allocations.deallocate(host.hostAllocator(), host.backingAllocator(), ptr, alignment, @returnAddress()) catch |err| failRocDeallocError(err);
    host.recordRocFreeMetric();
    host.recordHostFree(alloc.allocated_size);
}

fn rocReallocFn(roc_host: *abi.RocHost, ptr: *anyopaque, new_length: usize, alignment_arg: usize) callconv(.c) ?*anyopaque {
    return rocReallocAt(roc_host, ptr, new_length, alignment_arg, @returnAddress());
}

fn rocReallocAt(roc_host: *abi.RocHost, ptr: *anyopaque, new_length: usize, alignment_arg: usize, return_address: usize) ?*anyopaque {
    const host = hostFromRocHost(roc_host);
    const result = host.roc_allocations.reallocate(host.hostAllocator(), host.backingAllocator(), ptr, new_length, alignment_arg, host.debug_phase, return_address) catch |err| switch (err) {
        error.OutOfMemory => failHost("Roc reallocation failed"),
        else => failRocReallocError(err),
    };
    host.recordHostAlloc(result.allocated_size);
    host.recordRocAllocMetric();
    host.recordRocFreeMetric();
    host.recordHostFree(result.freed.allocated_size);
    return result.ptr;
}

fn rocDbgFn(roc_host: *abi.RocHost, bytes: [*]const u8, len: usize) callconv(.c) void {
    _ = roc_host;
    const message = bytes[0..len];
    std.debug.print("ROC DBG: {s}\n", .{message});
}

fn rocExpectFailedFn(roc_host: *abi.RocHost, bytes: [*]const u8, len: usize) callconv(.c) void {
    _ = roc_host;
    const source_bytes = bytes[0..len];
    const trimmed = std.mem.trim(u8, source_bytes, " \t\n\r");
    std.debug.print("Expect failed: {s}\n", .{trimmed});
}

fn rocCrashedFn(roc_host: *abi.RocHost, bytes: [*]const u8, len: usize) callconv(.c) void {
    _ = roc_host;
    const message = bytes[0..len];
    writeStderr("\n\x1b[31mRoc crashed:\x1b[0m ");
    writeStderr(message);
    writeStderr("\n");
    std.process.exit(1);
}

fn hostAlloc(length: usize, alignment: usize) callconv(.c) ?*anyopaque {
    return rocAllocAt(currentRocHost(), length, alignment, @returnAddress());
}

fn hostDealloc(ptr: *anyopaque, alignment: usize) callconv(.c) void {
    rocDeallocFn(currentRocHost(), ptr, alignment);
}

fn hostRealloc(ptr: *anyopaque, new_length: usize, alignment: usize) callconv(.c) ?*anyopaque {
    return rocReallocAt(currentRocHost(), ptr, new_length, alignment, @returnAddress());
}

fn hostDbg(bytes: [*]const u8, len: usize) callconv(.c) void {
    rocDbgFn(currentRocHost(), bytes, len);
}

fn hostExpectFailed(bytes: [*]const u8, len: usize) callconv(.c) void {
    rocExpectFailedFn(currentRocHost(), bytes, len);
}

fn hostCrashed(bytes: [*]const u8, len: usize) callconv(.c) void {
    rocCrashedFn(currentRocHost(), bytes, len);
}

fn currentHost() *HostEnv {
    return current_host orelse @panic("signals HostEnv is not initialized");
}

fn hostValueClone(value: u64) callconv(.c) u64 {
    return currentHost().cloneHostValue(HostValue.fromRaw(value)).toRaw();
}

fn hostValueGetWithCapability(value: u64, cap: HostValueCapability) callconv(.c) abi.RocBox {
    return currentHost().getHostValueWithCapability(HostValue.fromRaw(value), cap);
}

fn hostValueGetWithSplit(value: u64, split: abi.RocErasedCallable) callconv(.c) abi.RocBox {
    return currentHost().getHostValueWithSplit(HostValue.fromRaw(value), CapabilitySplit.fromAbi(split));
}

fn hostValueStoreWithCapability(box: abi.RocBox, cap: HostValueCapability) callconv(.c) u64 {
    return currentHost().storeHostValueWithOwnedCapability(box, cap).toRaw();
}

fn hostValueStoreWithExistingCapability(box: abi.RocBox, source_value: u64) callconv(.c) u64 {
    return currentHost().storeHostValueWithExistingCapability(box, HostValue.fromRaw(source_value)).toRaw();
}

fn hostValueTakeWithCapability(value: u64, cap: HostValueCapability) callconv(.c) abi.RocBox {
    return currentHost().takeHostValueWithCapability(HostValue.fromRaw(value), cap);
}

fn hostValueTakeWithSplit(value: u64, split: abi.RocErasedCallable) callconv(.c) abi.RocBox {
    return currentHost().takeHostValueWithSplit(HostValue.fromRaw(value), CapabilitySplit.fromAbi(split));
}

fn failHost(message: []const u8) noreturn {
    writeStderr("HOST ERROR: ");
    writeStderr(message);
    writeStderr("\n");
    std.process.exit(1);
}

fn u64MetricAsI64(value: u64) i64 {
    return std.math.cast(i64, value) orelse failHost("runtime metric exceeded signed assertion range");
}

fn setElementText(host: *HostEnv, elem: *DomElement, text: []const u8) void {
    sim_dom.setText(host.hostAllocator(), elem, text);
}

fn setElementValueIfChanged(host: *HostEnv, elem: *DomElement, value: []const u8) bool {
    return sim_dom.setUserValueIfChanged(host.hostAllocator(), elem, value);
}

fn setElementValue(host: *HostEnv, elem: *DomElement, value: []const u8) void {
    _ = sim_dom.setControlledValue(host.hostAllocator(), elem, value);
}

fn clearElementText(host: *HostEnv, elem: *DomElement) void {
    sim_dom.clearText(host.hostAllocator(), elem);
}

fn clearElementValue(host: *HostEnv, elem: *DomElement) void {
    sim_dom.clearValue(host.hostAllocator(), elem);
}

fn setElementTextAttr(host: *HostEnv, elem: *DomElement, name: []const u8, value: []const u8) void {
    sim_dom.setTextAttr(host.hostAllocator(), elem, name, value);
}

fn clearElementTextAttr(host: *HostEnv, elem: *DomElement, name: []const u8) void {
    sim_dom.clearTextAttr(host.hostAllocator(), elem, name);
}

fn elementTextAttr(elem: *const DomElement, name: []const u8) ?[]const u8 {
    return sim_dom.textAttr(elem, name);
}

fn setElementCheckedIfChanged(elem: *DomElement, checked: bool) bool {
    return sim_dom.setCheckedIfChanged(elem, checked);
}

fn setElementChecked(elem: *DomElement, checked: bool) void {
    sim_dom.setChecked(elem, checked);
}

fn setElementDisabled(elem: *DomElement, disabled: bool) void {
    sim_dom.setDisabled(elem, disabled);
}

fn resetSimulatedDom(host: *HostEnv) void {
    sim_dom.reset(host.hostAllocator(), &host.dom_elements);
    host.engine.next_elem_id = 1;
}

fn domElementById(host: *HostEnv, id: ids.ElemId) *DomElement {
    if (id.raw() >= host.dom_elements.items.len) failHost("DOM command referenced missing element");
    const elem = &host.dom_elements.items[id.index()];
    if (!elem.active) {
        var message: [96]u8 = undefined;
        const rendered = std.fmt.bufPrint(&message, "DOM command referenced inactive element {d}", .{id.raw()}) catch "DOM command referenced inactive element";
        failHost(rendered);
    }
    return elem;
}

fn setRenderTextField(host: *HostEnv, elem_id: ids.ElemId, field: RenderTextField, value: []const u8) void {
    const elem = domElementById(host, elem_id);
    switch (field) {
        .text => setElementText(host, elem, value),
        .role => sim_dom.setOwnedString(host.hostAllocator(), &elem.role, value),
        .label => sim_dom.setOwnedString(host.hostAllocator(), &elem.label, value),
        .test_id => sim_dom.setOwnedString(host.hostAllocator(), &elem.test_id, value),
        .value => setElementValue(host, elem, value),
        .class => sim_dom.setOwnedString(host.hostAllocator(), &elem.class, value),
    }
}

fn setRenderTextAttr(host: *HostEnv, elem_id: ids.ElemId, name: []const u8, value: []const u8) void {
    setElementTextAttr(host, domElementById(host, elem_id), name, value);
}

fn setRenderBoolField(host: *HostEnv, elem_id: ids.ElemId, field: RenderBoolField, value: bool) void {
    const elem = domElementById(host, elem_id);
    switch (field) {
        .checked => setElementChecked(elem, value),
        .disabled => setElementDisabled(elem, value),
    }
}

fn clearRenderTextField(host: *HostEnv, elem_id: ids.ElemId, field: RenderTextField) void {
    const elem = domElementById(host, elem_id);
    switch (field) {
        .text => clearElementText(host, elem),
        .role => sim_dom.clearOwnedString(host.hostAllocator(), &elem.role),
        .label => sim_dom.clearOwnedString(host.hostAllocator(), &elem.label),
        .test_id => sim_dom.clearOwnedString(host.hostAllocator(), &elem.test_id),
        .value => clearElementValue(host, elem),
        .class => sim_dom.clearOwnedString(host.hostAllocator(), &elem.class),
    }
}

fn clearRenderTextAttr(host: *HostEnv, elem_id: ids.ElemId, name: []const u8) void {
    clearElementTextAttr(host, domElementById(host, elem_id), name);
}

fn clearRenderBoolField(host: *HostEnv, elem_id: ids.ElemId, field: RenderBoolField) void {
    const elem = domElementById(host, elem_id);
    switch (field) {
        .checked => setElementChecked(elem, false),
        .disabled => setElementDisabled(elem, false),
    }
}

fn appendDetachedDomNode(host: *HostEnv, elem_id: ids.ElemId, tag: []const u8) void {
    if (elem_id.raw() < host.dom_elements.items.len and host.dom_elements.items[elem_id.index()].active) {
        failHost("descriptor stream attempted to reuse an active elem id");
    }
    sim_dom.appendDetached(host.hostAllocator(), &host.dom_elements, elem_id.raw(), tag);
    host.engine.next_elem_id = @max(host.engine.next_elem_id, elem_id.raw() + 1);
}

fn appendDomNode(host: *HostEnv, elem_id: ids.ElemId, parent_elem_id: ids.ElemId, tag: []const u8) void {
    appendDetachedDomNode(host, elem_id, tag);
    const parent = domElementById(host, parent_elem_id);
    const child = domElementById(host, elem_id);
    sim_dom.appendChild(host.hostAllocator(), parent, child);
}

fn findDomChildIndex(elem: *const DomElement, child_id: u64) ?usize {
    return sim_dom.childIndex(elem, child_id);
}

fn ensureDomNode(host: *HostEnv, elem_id: ids.ElemId, tag: []const u8) void {
    if (elem_id == ids.root_elem) failHost("render descriptor cannot claim the host DOM root id");
    appendDetachedDomNode(host, elem_id, tag);
}

fn propagateDirtyActiveSignals(host: *HostEnv, roc_host: *abi.RocHost, allocator: std.mem.Allocator, dirty_source_node_ids: []const u64, dirty_generation: u64) []const u64 {
    return host.engine.propagateDirtyActiveSignals(host, roc_host, allocator, dirty_source_node_ids, dirty_generation);
}

fn hostSignalRecordCapability(host: *HostEnv, record: *const HostSignalRecord) HostValueCapability {
    return host.engine.hostSignalRecordCapability(host, record);
}

fn hostSignalBindingCapability(host: *HostEnv, signal: *const HostSignalBinding) HostValueCapability {
    return hostSignalRecordCapability(host, signal.record);
}

fn updateDirtySignalCache(host: *HostEnv, roc_host: *abi.RocHost, cache_slot: *HostSignalCacheSlot, value: HostValue) bool {
    const cap = testHostValueCapability(roc_host);
    defer cap.decref(roc_host);
    return host.engine.updateDirtySignalCache(host, roc_host, cache_slot, value, cap);
}

fn resolvePendingTask(host: *HostEnv, roc_host: *abi.RocHost, name: []const u8, payload_text: []const u8, failed: bool) CommandCounts {
    const pending_index = host.engine.pendingTaskIndexByName(name) orelse failHost("fake task result had no matching pending request");
    const pending = host.engine.pending_tasks.items[pending_index];

    const record = host.engine.activeTaskRecordByToken(pending.task_token) orelse failHost("fake task result matched no active task source");
    const task_payload = switch (record.payload) {
        .task_source => |payload| payload,
        .ref, .const_value, .map, .map2, .combine, .interval_source, .location_source, .online_source, .visibility_source, .storage_source => unreachable,
    };
    if (record.token().? != pending.task_token) {
        failHost("fake task result matched a pending request for a different task source");
    }

    const payload_value = hostValueStrWithCapability(host, roc_host, payload_text, task_payload.payload_cap);
    const payload_take_epoch = host.hostValueTakeEpoch();
    const next = if (failed)
        callHostValueToHostValueWithCapability(host, roc_host, task_payload.payload_cap, task_payload.failed.toAbi(), payload_value)
    else
        callHostValueToHostValueWithCapability(host, roc_host, task_payload.payload_cap, task_payload.done.toAbi(), payload_value);
    host.assertHostValueTakenAfter(payload_value, payload_take_epoch);
    return host.engine.dispatchTaskSourceValue(host, roc_host, pending.request_id, record, next);
}

fn resolveStalePendingTask(host: *HostEnv, name: []const u8, _: []const u8, _: bool) CommandCounts {
    const record = host.takeCanceledTaskByName(name) orelse failHost("fake stale task result had no matching canceled request");
    defer host.hostAllocator().free(record.name);
    switch (host.engine.classifyTaskResolution(record.request_id)) {
        .pending => failHost("fake stale task result still matched a pending request"),
        .superseded => {
            host.engine.noteStaleTaskResolutionIgnored();
            return .{};
        },
        .unknown => failHost("fake stale task result matched an unknown request"),
    }
}

fn tickIntervalSource(host: *HostEnv, roc_host: *abi.RocHost, period_ms: u64) CommandCounts {
    return host.engine.tickIntervalSource(host, roc_host, period_ms);
}

fn dispatchCurrentLocationSources(host: *HostEnv, roc_host: *abi.RocHost) CommandCounts {
    return host.engine.dispatchCurrentLocationSources(host, roc_host);
}

fn dispatchCurrentVisibilitySources(host: *HostEnv, roc_host: *abi.RocHost) CommandCounts {
    return host.engine.dispatchCurrentVisibilitySources(host, roc_host);
}

fn dispatchCurrentOnlineSources(host: *HostEnv, roc_host: *abi.RocHost) CommandCounts {
    return host.engine.dispatchCurrentOnlineSources(host, roc_host);
}

fn collectDirtyStructuralSignals(host: *HostEnv, roc_host: *abi.RocHost, allocator: std.mem.Allocator, dirty_source_node_ids: []const u64, changed_record_ids: []const u64, dirty_generation: u64) []HostDirtyStructuralSignal {
    return host.engine.collectDirtyStructuralSignals(host, roc_host, allocator, dirty_source_node_ids, changed_record_ids, dirty_generation);
}

fn applyDirtyRenderSinks(host: *HostEnv, roc_host: *abi.RocHost, dirty_source_node_ids: []const u64, changed_record_ids: []const u64, dirty_generation: u64) CommandCounts {
    return host.engine.applyDirtyRenderSinks(host, roc_host, dirty_source_node_ids, changed_record_ids, dirty_generation);
}

fn bindNodeEvent(host: *HostEnv, command: render_sink.EventBindCommand) void {
    sim_dom.bindEvent(host.hostAllocator(), domElementById(host, command.elem_id), command.key, command.binding);
}

fn clearNodeEvent(host: *HostEnv, command: render_sink.EventClearCommand) void {
    sim_dom.clearEvent(host.hostAllocator(), domElementById(host, command.elem_id), command.key);
}

fn nodeEventName(elem: *const DomElement, name: []const u8) ?DomNamedEvent {
    return sim_dom.namedEvent(elem, name);
}

fn nodeFixedEventId(host: *const HostEnv, elem_id: ids.ElemId, kind: RenderEventKind) ?u64 {
    return sim_dom.fixedEventId(&host.dom_elements.items[@intCast(elem_id.raw())], kind);
}

fn replaceDomChildrenForStructuralParentMoves(host: *HostEnv, parent_elem_id: ids.ElemId, next_child_ids: []const ids.ElemId) void {
    replaceDomChildrenForStructuralParent(host, parent_elem_id, next_child_ids);
}

fn removeDomNode(host: *HostEnv, elem_id: ids.ElemId) void {
    if (elem_id == ids.root_elem) failHost("structural patch attempted to remove host DOM root");
    if (elem_id.raw() >= host.dom_elements.items.len) failHost("structural patch removed an element missing from DOM state");

    const elem = &host.dom_elements.items[elem_id.index()];
    if (!elem.active) {
        var message: [128]u8 = undefined;
        const rendered = std.fmt.bufPrint(&message, "structural patch removed inactive DOM node {d}", .{elem_id.raw()}) catch "structural patch removed an inactive DOM node";
        failHost(rendered);
    }
    if (elem.parent_id) |parent_id| {
        if (parent_id >= host.dom_elements.items.len) failHost("structural patch removed an element with missing parent");
        const parent = &host.dom_elements.items[@intCast(parent_id)];
        if (parent.active) {
            if (findDomChildIndex(parent, elem_id.raw())) |child_index| {
                sim_dom.removeChildAt(parent, child_index);
            }
        }
    }
    deactivateDomSubtree(host, elem_id);
}

fn deactivateDomSubtree(host: *HostEnv, elem_id: ids.ElemId) void {
    const allocator = host.hostAllocator();
    if (elem_id.raw() >= host.dom_elements.items.len) return;
    const elem = &host.dom_elements.items[elem_id.index()];
    if (!elem.active) return;

    const child_ids = allocator.dupe(u64, elem.children.items) catch @panic("out of memory");
    defer allocator.free(child_ids);
    for (child_ids) |child_id| {
        deactivateDomSubtree(host, ids.ElemId.fromRaw(child_id));
    }
    sim_dom.deactivateRemovedNode(allocator, elem);
}

fn replaceDomChildrenForStructuralParent(host: *HostEnv, parent_elem_id: ids.ElemId, next_child_ids: []const ids.ElemId) void {
    const allocator = host.hostAllocator();
    if (parent_elem_id.raw() >= host.dom_elements.items.len) failHost("structural child replacement referenced missing parent");
    const parent = &host.dom_elements.items[parent_elem_id.index()];
    if (!parent.active) {
        var message: [128]u8 = undefined;
        const rendered = std.fmt.bufPrint(&message, "structural child replacement referenced inactive parent {d}", .{parent_elem_id.raw()}) catch "structural child replacement referenced inactive parent";
        failHost(rendered);
    }

    for (next_child_ids) |child_id| {
        if (child_id.raw() >= host.dom_elements.items.len) failHost("structural child replacement referenced missing child");
        const child = &host.dom_elements.items[child_id.index()];
        if (!child.active) {
            var message: [128]u8 = undefined;
            const rendered = std.fmt.bufPrint(&message, "structural child replacement referenced inactive child {d} under parent {d}", .{ child_id.raw(), parent_elem_id.raw() }) catch "structural child replacement referenced inactive child";
            failHost(rendered);
        }
    }

    sim_dom.replaceChildren(allocator, host.dom_elements.items, parent, ids.elemSliceRaw(next_child_ids));
}

fn applyNodeDescriptorStream(host: *HostEnv, roc_host: *abi.RocHost, stream: *HostNodeDescriptorStream) CommandCounts {
    return host.engine.applyNodeDescriptorStream(host, roc_host, stream);
}

fn applyStructuralNodeDescriptorStream(host: *HostEnv, roc_host: *abi.RocHost, stream: *HostNodeDescriptorStream) CommandCounts {
    return host.engine.applyStructuralNodeDescriptorStream(host, roc_host, stream);
}

fn dropMovedElemPayload(_: ?*anyopaque, _: *abi.RocHost) callconv(.c) void {}

fn hostValueUnit(host: *HostEnv, roc_host: *abi.RocHost) HostValue {
    return hv.makeUnit(host, roc_host);
}

fn hostValueStr(host: *HostEnv, roc_host: *abi.RocHost, value: []const u8) HostValue {
    return hv.makeStr(host, roc_host, value);
}

fn hostValueStrWithCapability(host: *HostEnv, roc_host: *abi.RocHost, value: []const u8, cap: HostValueCapability) HostValue {
    return hv.makeStrWithCapability(host, roc_host, value, cap);
}

fn hostValueBool(host: *HostEnv, roc_host: *abi.RocHost, value: bool) HostValue {
    return hv.makeBool(host, roc_host, value);
}

fn hostValueI64(host: *HostEnv, roc_host: *abi.RocHost, value: i64) HostValue {
    return hv.makeI64(host, roc_host, value);
}

fn hostValueU8List(host: *HostEnv, roc_host: *abi.RocHost, bytes: []const u8) HostValue {
    return hv.makeU8List(host, roc_host, bytes);
}

const ErasedHostValueUnaryArgs = erased_calls.ErasedHostValueUnaryArgs;
const ErasedHostValueBinaryArgs = erased_calls.ErasedHostValueBinaryArgs;
const ErasedHostValueTernaryArgs = erased_calls.ErasedHostValueTernaryArgs;
const ErasedRocBoxUnaryArgs = erased_calls.ErasedRocBoxUnaryArgs;

const callErasedHostValueToHostValue = erased_calls.callErasedHostValueToHostValue;

const callErasedHostValueHostValueToHostValue = erased_calls.callErasedHostValueHostValueToHostValue;
const callErasedHostValueHostValueHostValueToHostValue = erased_calls.callErasedHostValueHostValueHostValueToHostValue;

const callErasedHostValueHostValueToElem = erased_calls.callErasedHostValueHostValueToElem;

const callErasedHostValueHostValueToBool = erased_calls.callErasedHostValueHostValueToBool;

const callErasedHostValueToUnit = erased_calls.callErasedHostValueToUnit;

fn callHostValueToUnitWithCapability(host: *HostEnv, roc_host: *abi.RocHost, cap: HostValueCapability, callable: abi.RocErasedCallable, value: HostValue) void {
    const caps = [_]HostValueCapability{cap};
    host.pushHostValueCapabilities(&caps);
    defer host.popHostValueCapabilities();
    callErasedHostValueToUnit(roc_host, callable, value);
}

fn callHostValueToHostValueWithCapability(host: *HostEnv, roc_host: *abi.RocHost, cap: HostValueCapability, callable: abi.RocErasedCallable, value: HostValue) HostValue {
    const caps = [_]HostValueCapability{cap};
    host.pushHostValueCapabilities(&caps);
    defer host.popHostValueCapabilities();
    return callErasedHostValueToHostValue(roc_host, callable, value);
}

fn callHostValueHostValueToHostValueWithCapabilities(host: *HostEnv, roc_host: *abi.RocHost, left_cap: HostValueCapability, right_cap: HostValueCapability, callable: abi.RocErasedCallable, left: HostValue, right: HostValue) HostValue {
    const caps = [_]HostValueCapability{ left_cap, right_cap };
    host.pushHostValueCapabilities(&caps);
    defer host.popHostValueCapabilities();
    return callErasedHostValueHostValueToHostValue(roc_host, callable, left, right);
}

fn callHostValueHostValueHostValueToHostValueWithCapabilities(host: *HostEnv, roc_host: *abi.RocHost, first_cap: HostValueCapability, second_cap: HostValueCapability, third_cap: HostValueCapability, callable: abi.RocErasedCallable, first: HostValue, second: HostValue, third: HostValue) HostValue {
    const caps = [_]HostValueCapability{ first_cap, second_cap, third_cap };
    host.pushHostValueCapabilities(&caps);
    defer host.popHostValueCapabilities();
    return callErasedHostValueHostValueHostValueToHostValue(roc_host, callable, first, second, third);
}

fn hostEventById(host: *HostEnv, event_id: ids.EventId) HostActiveEventDesc {
    if (event_id.raw() == 0 or event_id.raw() > host.engine.active_events.items.len) {
        failHost("DOM event referenced an unknown active event");
    }
    return host.engine.active_events.items[@intCast(event_id.raw() - 1)];
}

fn validateBoundaryPayloadDescriptor(desc: HostActiveEventDesc, expected_payload_descriptor: BoundaryPayloadDescriptor) void {
    if (!desc.payload_descriptor.eql(expected_payload_descriptor)) {
        failHost("DOM event payload descriptor does not match Roc event descriptor");
    }
}

fn finishHostMetrics(host: *HostEnv) void {
    if (comptime !enable_runtime_metrics) return;
    var metrics = addRuntimeMetrics(host.engine.last_runtime_metrics, host.engine.pending_roc_metrics);
    metrics.patches_emitted = host.engine.render_metrics.patches_emitted;
    metrics.reset_dom = host.engine.render_metrics.reset_dom;
    metrics.create_element = host.engine.render_metrics.create_element;
    metrics.append_child = host.engine.render_metrics.append_child;
    metrics.remove_node = host.engine.render_metrics.remove_node;
    metrics.move_before = host.engine.render_metrics.move_before;
    metrics.set_text = host.engine.render_metrics.set_text;
    metrics.set_value = host.engine.render_metrics.set_value;
    metrics.set_checked = host.engine.render_metrics.set_checked;
    metrics.set_disabled = host.engine.render_metrics.set_disabled;
    metrics.set_metadata = host.engine.render_metrics.set_metadata;
    metrics.bind_event = host.engine.render_metrics.bind_event;
    metrics.retained_alloc_delta = @as(i64, @intCast(host.alloc_count)) - @as(i64, @intCast(host.dealloc_count));
    metrics.host_retained_alloc_delta = u64MetricAsI64(host.host_alloc_count) - u64MetricAsI64(host.host_dealloc_count);
    metrics.host_retained_bytes_delta = u64MetricAsI64(host.host_alloc_bytes) - u64MetricAsI64(host.host_dealloc_bytes);
    metrics.events_processed = host.engine.dispatch_metrics.events_processed;
    metrics.recompute_batches = host.engine.dispatch_metrics.recompute_batches;
    host.engine.last_runtime_metrics = metrics;
    host.engine.pending_roc_metrics = zeroRuntimeMetrics();
}

fn applyDirtyStructuralSignalsLocally(host: *HostEnv, roc_host: *abi.RocHost, dirty_source_node_ids: []const u64, dirty_generation: u64, changes: []HostDirtyStructuralSignal) CommandCounts {
    return host.engine.applyDirtyStructuralSignalsLocally(host, roc_host, dirty_source_node_ids, dirty_generation, changes);
}

fn applyDirtyWhenStructuralSignals(host: *HostEnv, roc_host: *abi.RocHost, dirty_source_node_ids: []const u64, dirty_generation: u64, changes: []HostDirtyStructuralSignal) CommandCounts {
    return host.engine.applyDirtyWhenStructuralSignals(host, roc_host, dirty_source_node_ids, dirty_generation, changes);
}

fn tryRenderInitialRoot(host: *HostEnv, roc_host: *abi.RocHost, root: abi.Elem, dirty_source_node_ids: []const u64) HostEngine.CollectionError!CommandCounts {
    const collection = try HostEngine.PreparedRootCollection.prepare(&host.engine, host, roc_host, root, .{}, dirty_source_node_ids);
    errdefer collection.deinit();
    const prepared = try HostEngine.PreparedRootDownstream.prepare(collection);
    defer prepared.deinit();
    var counts = prepared.downstream.render_splice.?.wire.counts();
    prepared.commit();
    counts.addAll(prepared.runLifecycle());
    return counts;
}

/// Renders an initial root like `tryRenderInitialRoot`, but arms `fault` so
/// that commit and teardown fail on their first allocation attempt. Preparation
/// keeps `fault`'s configured failure number, so a sweep over preparation
/// attempts still refuses at the requested point; publication itself must
/// never allocate, which is what the armed phases prove.
fn tryRenderInitialRootWithArmedPublication(host: *HostEnv, roc_host: *abi.RocHost, root: abi.Elem, fault: *FaultAllocator) HostEngine.CollectionError!CommandCounts {
    const collection = try HostEngine.PreparedRootCollection.prepare(&host.engine, host, roc_host, root, .{}, &.{});
    errdefer collection.deinit();
    const prepared = try HostEngine.PreparedRootDownstream.prepare(collection);
    var counts = prepared.downstream.render_splice.?.wire.counts();
    const preparation_attempts = fault.attempts;

    fault.configure(1);
    prepared.commit();
    if (fault.attempts != 0) @panic("initial root commit attempted an allocation");
    fault.configure(null);
    counts.addAll(prepared.runLifecycle());
    fault.configure(1);
    prepared.deinit();
    if (fault.attempts != 0) @panic("initial root teardown attempted an allocation");
    fault.configure(null);
    fault.attempts = preparation_attempts;
    return counts;
}

fn renderActiveRootWithStats(host: *HostEnv, roc_host: *abi.RocHost, dirty_source_node_ids: []const u64, apply_ns: ?*u64, command_counts: ?*CommandCounts) void {
    // Only the initial mount renders from the root Elem.
    const root = host.engine.root_elem orelse failHost("host render requested before Roc root Elem was initialized");

    if (!host.engine.hasRenderRoot()) {
        const start_ns = benchmark.nowNs();
        const counts = tryRenderInitialRoot(host, roc_host, root, dirty_source_node_ids) catch |err| switch (err) {
            error.OutOfMemory => failHost("out of memory preparing initial root transaction"),
            error.ResourceLimit => failHost("initial root exceeded configured runtime limits"),
            error.InvalidScope => failHost("initial root named a scope or identity that is unknown, inactive, or already claimed"),
            error.InvalidDescriptor => failHost("initial root staged a descriptor the committed stream does not hold"),
            error.OverlappingRemoval => failHost("initial root staged overlapping removals"),
            error.InvalidRenderTopology => failHost("initial root staged a render topology that conflicts with the committed tree"),
            error.InvalidSignalGraphAppend => failHost("initial root staged a signal graph append that does not match the committed graph"),
            error.InvalidSignalGraphRelease => failHost("initial root staged a signal graph release that does not match the committed graph"),
        };
        const elapsed = benchmark.nowNs() - start_ns;
        if (apply_ns) |ns| ns.* += elapsed;
        if (command_counts) |total| total.addAll(counts);
        if (comptime enable_runtime_metrics) host.engine.render_metrics.addCommandCounts(counts);
        finishHostMetrics(host);
        return;
    }

    // Every update after the initial mount is a prepared transaction driven
    // by dispatch; there is deliberately no full re-render path to fall back
    // to, so that a transition the transactional engine cannot stage fails
    // loudly instead of being quietly recollected.
    failHost("render root already published; live updates must go through prepared transactions");
}

fn acceptInitElemWithStats(host: *HostEnv, roc_host: *abi.RocHost, root_box: ElemBox, apply_ns: ?*u64, command_counts: ?*CommandCounts) void {
    if (host.engine.root_elem != null) failHost("Roc root Elem initialized more than once");
    const root = root_box.*;
    host.engine.root_elem = root;
    abi.decrefBoxWith(@ptrCast(root_box), @alignOf(abi.Elem), true, &dropMovedElemPayload, roc_host);
    renderActiveRootWithStats(host, roc_host, &.{}, apply_ns, command_counts);
}

fn acceptInitElem(host: *HostEnv, roc_host: *abi.RocHost, root_box: ElemBox) void {
    acceptInitElemWithStats(host, roc_host, root_box, null, null);
}

fn dispatchRocEventWithStats(host: *HostEnv, roc_host: *abi.RocHost, event_id: ids.EventId, payload_descriptor: BoundaryPayloadDescriptor, payload: HostValue, stats: ?*BenchmarkStats) void {
    // Register this before the ownership defers below so retained-allocation
    // metrics observe the fully-settled event, including payload/state drops.
    defer finishHostMetrics(host);

    const desc = hostEventById(host, event_id);
    validateBoundaryPayloadDescriptor(desc, payload_descriptor);
    const payload_cap = desc.payload_reducer.capability;
    host.setHostValueCapability(payload, payload_cap);
    defer {
        host.debug_phase = .event_drop_payload;
        callHostValueToUnitWithCapability(host, roc_host, payload_cap, hv.hostValueCapabilityDrop(payload_cap), payload);
    }

    const start_ns = benchmark.nowNs();
    const current = host.stateValueByNodeId(desc.target_node_id);
    const state_cap = host.stateCapability(desc.target_node_id);
    defer {
        host.debug_phase = .event_drop_state;
        callHostValueToUnitWithCapability(host, roc_host, state_cap, hv.hostValueCapabilityDrop(state_cap), current);
    }
    const read = host.stateValueByNodeId(desc.read_node_id);
    const read_cap = host.stateCapability(desc.read_node_id);
    defer {
        host.debug_phase = .event_drop_read;
        callHostValueToUnitWithCapability(host, roc_host, read_cap, hv.hostValueCapabilityDrop(read_cap), read);
    }
    const next = callHostValueHostValueHostValueToHostValueWithCapabilities(host, roc_host, state_cap, read_cap, payload_cap, desc.payload_reducer.transform, current, read, payload);
    if (stats) |s| s.dispatch_roc_ns += benchmark.nowNs() - start_ns;

    const apply_start_ns = benchmark.nowNs();
    const counts = host.engine.dispatchStateValue(host, roc_host, desc.target_node_id.raw(), next, state_cap);
    if (stats) |s| {
        s.dispatch_apply_ns += benchmark.nowNs() - apply_start_ns;
        s.commands.addAll(counts);
        s.actions += 1;
    }
}

fn dispatchRocEvent(host: *HostEnv, roc_host: *abi.RocHost, event_id: ids.EventId, payload_descriptor: BoundaryPayloadDescriptor, payload: HostValue) void {
    dispatchRocEventWithStats(host, roc_host, event_id, payload_descriptor, payload, null);
}

fn encodeKeyShiftPayload(allocator: std.mem.Allocator, key: []const u8, shift_key: bool) []u8 {
    const bytes = allocator.alloc(u8, @sizeOf(u32) + key.len + 1) catch std.process.exit(1);
    std.mem.writeInt(u32, bytes[0..@sizeOf(u32)], @intCast(key.len), .little);
    @memcpy(bytes[@sizeOf(u32)..][0..key.len], key);
    bytes[@sizeOf(u32) + key.len] = if (shift_key) 1 else 0;
    return bytes;
}

fn requireNamedEvent(elem: *const DomElement, name: []const u8, message: []const u8) DomNamedEvent {
    return nodeEventName(elem, name) orelse failHost(message);
}

fn dispatchKeyDownWithStats(host: *HostEnv, roc_host: *abi.RocHost, elem: *const DomElement, key: []const u8, shift_key: bool, stats: ?*BenchmarkStats) bool {
    const event = requireNamedEvent(elem, "keydown", "keydown target has no named keydown binding");
    if (!event.binding.payload_descriptor.eql(BoundaryPayloadDescriptor.init(.bytes, .record_key_shift))) {
        failHost("keydown binding does not request the key/shift payload descriptor");
    }
    const payload_bytes = encodeKeyShiftPayload(host.hostAllocator(), key, shift_key);
    defer host.hostAllocator().free(payload_bytes);
    dispatchRocEventWithStats(host, roc_host, event.binding.event_id, event.binding.payload_descriptor, hostValueU8List(host, roc_host, payload_bytes), stats);
    return event.binding.policy.prevent_default;
}

fn dispatchSubmitWithStats(host: *HostEnv, roc_host: *abi.RocHost, elem: *const DomElement, stats: ?*BenchmarkStats) void {
    const event = requireNamedEvent(elem, "submit", "submit target has no named submit binding");
    if (!event.binding.payload_descriptor.eql(BoundaryPayloadDescriptor.init(.unit, .none))) {
        failHost("submit binding does not use a unit payload descriptor");
    }
    if (!event.binding.policy.prevent_default) {
        failHost("submit binding does not request prevent-default policy");
    }
    dispatchRocEventWithStats(host, roc_host, event.binding.event_id, event.binding.payload_descriptor, hostValueUnit(host, roc_host), stats);
}

fn dispatchResetWithStats(host: *HostEnv, roc_host: *abi.RocHost, elem: *const DomElement, stats: ?*BenchmarkStats) void {
    const event = requireNamedEvent(elem, "reset", "reset target has no named reset binding");
    if (!event.binding.payload_descriptor.eql(BoundaryPayloadDescriptor.init(.unit, .none))) {
        failHost("reset binding does not use a unit payload descriptor");
    }
    if (!event.binding.policy.prevent_default) {
        failHost("reset binding does not request prevent-default policy");
    }
    dispatchRocEventWithStats(host, roc_host, event.binding.event_id, event.binding.payload_descriptor, hostValueUnit(host, roc_host), stats);
}

fn makeSignalsRocHost(host: *HostEnv) abi.RocHost {
    if (host_fixtures) current_host = host;
    return .{
        .env = @ptrCast(host),
        .roc_alloc = &rocAllocFn,
        .roc_dealloc = &rocDeallocFn,
        .roc_realloc = &rocReallocFn,
        .roc_dbg = &rocDbgFn,
        .roc_expect_failed = &rocExpectFailedFn,
        .roc_crashed = &rocCrashedFn,
    };
}

fn pointerEventIdForCommand(elem: *const DomElement, cmd_type: SpecCommandType) ?u64 {
    return switch (cmd_type) {
        .pointer_down => sim_dom.fixedEventId(elem, .pointer_down),
        .pointer_up => sim_dom.fixedEventId(elem, .pointer_up),
        .pointer_enter => sim_dom.fixedEventId(elem, .pointer_enter),
        .pointer_leave => sim_dom.fixedEventId(elem, .pointer_leave),
        else => null,
    };
}

const BenchmarkDomElement = DomElement;

fn hostValueUnitForBenchmark(host: *HostEnv, roc_host: *abi.RocHost) HostValue {
    return hostValueUnit(host, roc_host);
}

fn hostValueStrForBenchmark(host: *HostEnv, roc_host: *abi.RocHost, value: []const u8) HostValue {
    return hostValueStr(host, roc_host, value);
}

fn hostValueBoolForBenchmark(host: *HostEnv, roc_host: *abi.RocHost, value: bool) HostValue {
    return hostValueBool(host, roc_host, value);
}

fn setElementValueForBenchmark(host: *HostEnv, elem: *DomElement, value: []const u8) bool {
    return setElementValueIfChanged(host, elem, value);
}

fn setElementCheckedForBenchmark(elem: *DomElement, checked: bool) bool {
    return setElementCheckedIfChanged(elem, checked);
}

fn resolvePendingTaskForBenchmark(host: *HostEnv, roc_host: *abi.RocHost, name: []const u8, payload_text: []const u8, failed: bool) CommandCounts {
    return resolvePendingTask(host, roc_host, name, payload_text, failed);
}

fn resolveStalePendingTaskForBenchmark(host: *HostEnv, name: []const u8, payload_text: []const u8, failed: bool) CommandCounts {
    return resolveStalePendingTask(host, name, payload_text, failed);
}

fn tickIntervalSourceForBenchmark(host: *HostEnv, roc_host: *abi.RocHost, period_ms: u64) CommandCounts {
    return tickIntervalSource(host, roc_host, period_ms);
}

fn finishHostMetricsForBenchmark(host: *HostEnv) void {
    finishHostMetrics(host);
}

fn addRuntimeMetricsForBenchmark(left: RuntimeMetrics, right: RuntimeMetrics) RuntimeMetrics {
    return addRuntimeMetrics(left, right);
}

const BenchmarkCtx = struct {
    pub const Host = HostEnv;
    pub const RocHost = abi.RocHost;
    pub const DomElement = BenchmarkDomElement;

    /// Terminates this test or host path because continuing could leave runtime meaning incoherent.
    pub fn fail(message: []const u8) noreturn {
        failHost(message);
    }

    /// Provides init host for native semantic observation without duplicating engine behavior.
    pub fn initHost() Host {
        return Host.init();
    }

    /// Provides deinit host for native semantic observation without duplicating engine behavior.
    pub fn deinitHost(host: *Host) void {
        host.deinit();
    }

    /// Sets verbose at the narrow host or engine boundary that owns the mutation.
    pub fn setVerbose(host: *Host, verbose: bool) void {
        host.test_state.verbose = verbose;
    }

    /// Constructs roc host with the host references required by the shared engine contract.
    pub fn makeRocHost(host: *Host) RocHost {
        return makeSignalsRocHost(host);
    }

    /// Provides attach roc host for native semantic observation without duplicating engine behavior.
    pub fn attachRocHost(host: *Host, roc_host: *RocHost) void {
        host.engine.roc_host = roc_host;
    }

    /// Provides enter current for native semantic observation without duplicating engine behavior.
    pub fn enterCurrent(host: *Host, roc_host: *RocHost) void {
        current_host = host;
        current_roc_host = roc_host;
    }

    /// Provides leave current for native semantic observation without duplicating engine behavior.
    pub fn leaveCurrent() void {
        current_host = null;
        current_roc_host = null;
    }

    /// Provides init roc ui for native semantic observation without duplicating engine behavior.
    pub fn initRocUi() ElemBox {
        return abi.roc_ui_init();
    }

    /// Provides accept init elem measured for native semantic observation without duplicating engine behavior.
    pub fn acceptInitElemMeasured(host: *Host, roc_host: *RocHost, root_box: ElemBox, apply_ns: ?*u64, command_counts: ?*CommandCounts) void {
        acceptInitElemWithStats(host, roc_host, root_box, apply_ns, command_counts);
    }

    /// Resolves element by locator from maintained indexes without scanning the full descriptor stream.
    pub fn findElementByLocator(host: *Host, locator: Locator, line_num: usize) ?*BenchmarkDomElement {
        return host.findElementByLocator(locator, line_num);
    }

    /// Returns by id from the host's semantic render model.
    pub fn elementById(host: *Host, elem_id: u64) ?*BenchmarkDomElement {
        if (elem_id >= host.dom_elements.items.len) return null;
        const elem = &host.dom_elements.items[@intCast(elem_id)];
        if (!elem.active) return null;
        return elem;
    }

    /// Returns disabled from the host's semantic render model.
    pub fn elementDisabled(elem: *const BenchmarkDomElement) bool {
        return elem.disabled;
    }

    /// Provides fixed event id for native semantic observation without duplicating engine behavior.
    pub fn fixedEventId(elem: *const BenchmarkDomElement, kind: render.EventKind) ?u64 {
        return sim_dom.fixedEventId(elem, kind);
    }

    /// Provides click event id for native semantic observation without duplicating engine behavior.
    pub fn clickEventId(elem: *const BenchmarkDomElement) ?u64 {
        return sim_dom.fixedEventId(elem, .click);
    }

    /// Provides pointer event id for native semantic observation without duplicating engine behavior.
    pub fn pointerEventId(elem: *const BenchmarkDomElement, cmd_type: SpecCommandType) ?u64 {
        return pointerEventIdForCommand(elem, cmd_type);
    }

    /// Provides input event id for native semantic observation without duplicating engine behavior.
    pub fn inputEventId(elem: *const BenchmarkDomElement) ?u64 {
        return sim_dom.fixedEventId(elem, .input);
    }

    /// Provides check event id for native semantic observation without duplicating engine behavior.
    pub fn checkEventId(elem: *const BenchmarkDomElement) ?u64 {
        return sim_dom.fixedEventId(elem, .check);
    }

    /// Provides named event for native semantic observation without duplicating engine behavior.
    pub fn namedEvent(elem: *const BenchmarkDomElement, name: []const u8) ?DomNamedEvent {
        return nodeEventName(elem, name);
    }

    /// Returns text attr from the host's semantic render model.
    pub fn elementTextAttr(elem: *const BenchmarkDomElement, name: []const u8) ?[]const u8 {
        return sim_dom.textAttr(elem, name);
    }

    /// Dispatches roc event measured through validated routing and dependency-ordered propagation.
    pub fn dispatchRocEventMeasured(host: *Host, roc_host: *RocHost, event_id: u64, payload_descriptor: BoundaryPayloadDescriptor, payload: HostValue, stats: ?*BenchmarkStats) void {
        dispatchRocEventWithStats(host, roc_host, ids.EventId.fromRaw(event_id), payload_descriptor, payload, stats);
    }

    /// Materializes unit as a capability-owned host value for boundary delivery.
    pub fn hostValueUnit(host: *Host, roc_host: *RocHost) HostValue {
        return hostValueUnitForBenchmark(host, roc_host);
    }

    /// Materializes str as a capability-owned host value for boundary delivery.
    pub fn hostValueStr(host: *Host, roc_host: *RocHost, value: []const u8) HostValue {
        return hostValueStrForBenchmark(host, roc_host, value);
    }

    /// Materializes bool as a capability-owned host value for boundary delivery.
    pub fn hostValueBool(host: *Host, roc_host: *RocHost, value: bool) HostValue {
        return hostValueBoolForBenchmark(host, roc_host, value);
    }

    /// Dispatches key down measured through validated routing and dependency-ordered propagation.
    pub fn dispatchKeyDownMeasured(host: *Host, roc_host: *RocHost, elem: *const BenchmarkDomElement, key: []const u8, shift_key: bool, stats: ?*BenchmarkStats) bool {
        return dispatchKeyDownWithStats(host, roc_host, elem, key, shift_key, stats);
    }

    /// Dispatches submit measured through validated routing and dependency-ordered propagation.
    pub fn dispatchSubmitMeasured(host: *Host, roc_host: *RocHost, elem: *const BenchmarkDomElement, stats: ?*BenchmarkStats) void {
        dispatchSubmitWithStats(host, roc_host, elem, stats);
    }

    /// Dispatches reset measured through validated routing and dependency-ordered propagation.
    pub fn dispatchResetMeasured(host: *Host, roc_host: *RocHost, elem: *const BenchmarkDomElement, stats: ?*BenchmarkStats) void {
        dispatchResetWithStats(host, roc_host, elem, stats);
    }

    /// Updates value if changed only when the simulated or browser field actually differs.
    pub fn setElementValueIfChanged(host: *Host, elem: *BenchmarkDomElement, value: []const u8) bool {
        return setElementValueForBenchmark(host, elem, value);
    }

    /// Marks the controlled element focused so conflicting value writes can be deferred safely.
    pub fn focusElement(_: *Host, elem: *BenchmarkDomElement) void {
        sim_dom.focusElement(elem);
    }

    /// Ends controlled-element focus and applies any still-relevant deferred value.
    pub fn blurElement(host: *Host, elem: *BenchmarkDomElement) void {
        _ = sim_dom.blurElement(host.hostAllocator(), elem);
    }

    /// Marks the controlled input as composing so engine writes do not disrupt IME text.
    pub fn beginComposition(_: *Host, elem: *BenchmarkDomElement) void {
        sim_dom.beginComposition(elem);
    }

    /// Ends IME composition and reconciles the latest engine-selected value.
    pub fn endComposition(host: *Host, elem: *BenchmarkDomElement) void {
        _ = sim_dom.endComposition(host.hostAllocator(), elem);
    }

    /// Updates checked if changed only when the simulated or browser field actually differs.
    pub fn setElementCheckedIfChanged(elem: *BenchmarkDomElement, checked: bool) bool {
        return setElementCheckedForBenchmark(elem, checked);
    }

    /// Delivers pending task through the same source-update and propagation path as other inputs.
    pub fn resolvePendingTask(host: *Host, roc_host: *RocHost, name: []const u8, payload_text: []const u8, failed: bool) CommandCounts {
        return resolvePendingTaskForBenchmark(host, roc_host, name, payload_text, failed);
    }

    /// Consumes a deliberately stale task result for lifecycle testing without reviving canceled work.
    pub fn resolveStalePendingTask(host: *Host, _: *RocHost, name: []const u8, payload_text: []const u8, failed: bool) CommandCounts {
        return resolveStalePendingTaskForBenchmark(host, name, payload_text, failed);
    }

    /// Advances interval source through the shared propagation queue.
    pub fn tickIntervalSource(host: *Host, roc_host: *RocHost, period_ms: u64) CommandCounts {
        return tickIntervalSourceForBenchmark(host, roc_host, period_ms);
    }

    /// Seeds location before mount so the first graph evaluation observes host state.
    pub fn setInitialLocation(host: *Host, location: boundary.LocationSnapshot) void {
        host.setCurrentLocation(location);
    }

    /// Seeds visibility before mount so the first graph evaluation observes host state.
    pub fn setInitialVisibility(host: *Host, visibility: boundary.VisibilitySnapshot) void {
        host.setVisibility(visibility);
    }

    /// Seeds online before mount so the first graph evaluation observes host state.
    pub fn setInitialOnline(host: *Host, online: boundary.OnlineSnapshot) void {
        host.setOnline(online);
    }

    /// Seeds one storage fixture entry before mount without bypassing declared storage sources.
    pub fn seedStorage(host: *Host, area: boundary.StorageArea, key: []const u8, value: []const u8) void {
        host.setStorageText(area, key, value);
    }

    /// Publishes a location change and refreshes active location sources in the same engine turn.
    pub fn navigateLocation(host: *Host, roc_host: *RocHost, location: boundary.LocationSnapshot) CommandCounts {
        host.pushCurrentLocation(location);
        return dispatchCurrentLocationSources(host, roc_host);
    }

    /// Moves browser history back and re-enters the location source through propagation.
    pub fn historyBack(host: *Host, roc_host: *RocHost) CommandCounts {
        if (!host.backCurrentLocation()) failHost("history_back had no previous location");
        return dispatchCurrentLocationSources(host, roc_host);
    }

    /// Moves browser history forward and re-enters the location source through propagation.
    pub fn historyForward(host: *Host, roc_host: *RocHost) CommandCounts {
        if (!host.forwardCurrentLocation()) failHost("history_forward had no next location");
        return dispatchCurrentLocationSources(host, roc_host);
    }

    /// Sets visibility at the narrow host or engine boundary that owns the mutation.
    pub fn setVisibility(host: *Host, roc_host: *RocHost, visibility: boundary.VisibilitySnapshot) CommandCounts {
        host.setVisibility(visibility);
        return dispatchCurrentVisibilitySources(host, roc_host);
    }

    /// Sets online at the narrow host or engine boundary that owns the mutation.
    pub fn setOnline(host: *Host, roc_host: *RocHost, online: boundary.OnlineSnapshot) CommandCounts {
        host.setOnline(online);
        return dispatchCurrentOnlineSources(host, roc_host);
    }

    /// Returns active interval record count by period from the maintained active-runtime indexes.
    pub fn activeIntervalRecordCountByPeriod(host: *const Host, period_ms: u64) u64 {
        return host.engine.activeIntervalRecordCountByPeriod(period_ms);
    }

    /// Provides finish host metrics for native semantic observation without duplicating engine behavior.
    pub fn finishHostMetrics(host: *Host) void {
        finishHostMetricsForBenchmark(host);
    }

    /// Provides alloc count for native semantic observation without duplicating engine behavior.
    pub fn allocCount(host: *const Host) usize {
        return host.alloc_count;
    }

    /// Provides dealloc count for native semantic observation without duplicating engine behavior.
    pub fn deallocCount(host: *const Host) usize {
        return host.dealloc_count;
    }

    /// Provides host alloc count for native semantic observation without duplicating engine behavior.
    pub fn hostAllocCount(host: *const Host) u64 {
        return host.host_alloc_count;
    }

    /// Provides host dealloc count for native semantic observation without duplicating engine behavior.
    pub fn hostDeallocCount(host: *const Host) u64 {
        return host.host_dealloc_count;
    }

    /// Provides host alloc bytes for native semantic observation without duplicating engine behavior.
    pub fn hostAllocBytes(host: *const Host) u64 {
        return host.host_alloc_bytes;
    }

    /// Provides host dealloc bytes for native semantic observation without duplicating engine behavior.
    pub fn hostDeallocBytes(host: *const Host) u64 {
        return host.host_dealloc_bytes;
    }

    /// Returns last runtime metrics retained for observability or local structural traversal.
    pub fn lastRuntimeMetrics(host: *const Host) RuntimeMetrics {
        return host.engine.last_runtime_metrics;
    }

    /// Provides canceled task count by name for native semantic observation without duplicating engine behavior.
    pub fn canceledTaskCountByName(host: *const Host, name: []const u8) u64 {
        return host.canceledTaskCountByName(name);
    }

    /// Provides add runtime metrics for native semantic observation without duplicating engine behavior.
    pub fn addRuntimeMetrics(left: RuntimeMetrics, right: RuntimeMetrics) RuntimeMetrics {
        return addRuntimeMetricsForBenchmark(left, right);
    }
};

const BenchmarkRunner = benchmark.Runner(BenchmarkCtx);
const runAppBenchmarks = BenchmarkRunner.runAppBenchmarks;

const SpecRunnerCtx = struct {
    pub const Host = HostEnv;
    pub const RocHost = abi.RocHost;

    /// Terminates this test or host path because continuing could leave runtime meaning incoherent.
    pub fn fail(message: []const u8) noreturn {
        failHost(message);
    }

    /// Writes a diagnostic directly to standard error without entering application semantics.
    pub fn writeStderr(bytes: []const u8) void {
        crash_handlers.writeStderr(bytes);
    }

    /// Returns the allocator owned by this host context for shared-engine work.
    pub fn allocator(host: *Host) std.mem.Allocator {
        return host.hostAllocator();
    }

    /// Resolves element by locator from maintained indexes without scanning the full descriptor stream.
    pub fn findElementByLocator(host: *Host, locator: Locator, line_num: usize) ?*DomElement {
        return host.findElementByLocator(locator, line_num);
    }

    /// Returns by id from the host's semantic render model.
    pub fn elementById(host: *Host, elem_id: u64) ?*DomElement {
        if (elem_id >= host.dom_elements.items.len) return null;
        const elem = &host.dom_elements.items[@intCast(elem_id)];
        if (!elem.active) return null;
        return elem;
    }

    /// Provides count elements by locator for native semantic observation without duplicating engine behavior.
    pub fn countElementsByLocator(host: *Host, locator: Locator) usize {
        return host.countElementsByLocator(locator);
    }

    /// Provides named event for native semantic observation without duplicating engine behavior.
    pub fn namedEvent(elem: *const DomElement, name: []const u8) ?DomNamedEvent {
        return nodeEventName(elem, name);
    }

    /// Provides fixed event id for native semantic observation without duplicating engine behavior.
    pub fn fixedEventId(elem: *const DomElement, kind: RenderEventKind) ?ids.EventId {
        const raw = sim_dom.fixedEventId(elem, kind) orelse return null;
        return ids.EventId.fromRaw(raw);
    }

    /// Dispatches roc event through validated routing and dependency-ordered propagation.
    pub fn dispatchRocEvent(host: *Host, roc_host: *RocHost, event_id: ids.EventId, payload_descriptor: BoundaryPayloadDescriptor, payload: HostValue) void {
        dispatchRocEventWithStats(host, roc_host, event_id, payload_descriptor, payload, null);
    }

    /// Materializes unit as a capability-owned host value for boundary delivery.
    pub fn hostValueUnit(host: *Host, roc_host: *RocHost) HostValue {
        return hostValueUnitForBenchmark(host, roc_host);
    }

    /// Materializes str as a capability-owned host value for boundary delivery.
    pub fn hostValueStr(host: *Host, roc_host: *RocHost, value: []const u8) HostValue {
        return hostValueStrForBenchmark(host, roc_host, value);
    }

    /// Materializes bool as a capability-owned host value for boundary delivery.
    pub fn hostValueBool(host: *Host, roc_host: *RocHost, value: bool) HostValue {
        return hostValueBoolForBenchmark(host, roc_host, value);
    }

    /// Materializes u8 list as a capability-owned host value for boundary delivery.
    pub fn hostValueU8List(host: *Host, roc_host: *RocHost, bytes: []const u8) HostValue {
        return hv.makeU8List(host, roc_host, bytes);
    }

    /// Updates value if changed only when the simulated or browser field actually differs.
    pub fn setElementValueIfChanged(host: *Host, elem: *DomElement, value: []const u8) bool {
        return sim_dom.setUserValueIfChanged(host.hostAllocator(), elem, value);
    }

    /// Marks the controlled element focused so conflicting value writes can be deferred safely.
    pub fn focusElement(_: *Host, elem: *DomElement) void {
        sim_dom.focusElement(elem);
    }

    /// Ends controlled-element focus and applies any still-relevant deferred value.
    pub fn blurElement(host: *Host, elem: *DomElement) void {
        _ = sim_dom.blurElement(host.hostAllocator(), elem);
    }

    /// Marks the controlled input as composing so engine writes do not disrupt IME text.
    pub fn beginComposition(_: *Host, elem: *DomElement) void {
        sim_dom.beginComposition(elem);
    }

    /// Ends IME composition and reconciles the latest engine-selected value.
    pub fn endComposition(host: *Host, elem: *DomElement) void {
        _ = sim_dom.endComposition(host.hostAllocator(), elem);
    }

    /// Updates checked if changed only when the simulated or browser field actually differs.
    pub fn setElementCheckedIfChanged(elem: *DomElement, checked: bool) bool {
        return sim_dom.setCheckedIfChanged(elem, checked);
    }

    /// Returns text attr from the host's semantic render model.
    pub fn elementTextAttr(elem: *const DomElement, name: []const u8) ?[]const u8 {
        return sim_dom.textAttr(elem, name);
    }

    /// Delivers pending task through the same source-update and propagation path as other inputs.
    pub fn resolvePendingTask(host: *Host, roc_host: *RocHost, name: []const u8, payload_text: []const u8, failed: bool) CommandCounts {
        return resolvePendingTaskForBenchmark(host, roc_host, name, payload_text, failed);
    }

    /// Consumes a deliberately stale task result for lifecycle testing without reviving canceled work.
    pub fn resolveStalePendingTask(host: *Host, _: *RocHost, name: []const u8, payload_text: []const u8, failed: bool) CommandCounts {
        return resolveStalePendingTaskForBenchmark(host, name, payload_text, failed);
    }

    /// Advances interval source through the shared propagation queue.
    pub fn tickIntervalSource(host: *Host, roc_host: *RocHost, period_ms: u64) CommandCounts {
        return tickIntervalSourceForBenchmark(host, roc_host, period_ms);
    }

    /// Publishes a location change and refreshes active location sources in the same engine turn.
    pub fn navigateLocation(host: *Host, roc_host: *RocHost, location: boundary.LocationSnapshot) CommandCounts {
        host.pushCurrentLocation(location);
        return dispatchCurrentLocationSources(host, roc_host);
    }

    /// Moves browser history back and re-enters the location source through propagation.
    pub fn historyBack(host: *Host, roc_host: *RocHost) CommandCounts {
        if (!host.backCurrentLocation()) failHost("history_back had no previous location");
        return dispatchCurrentLocationSources(host, roc_host);
    }

    /// Moves browser history forward and re-enters the location source through propagation.
    pub fn historyForward(host: *Host, roc_host: *RocHost) CommandCounts {
        if (!host.forwardCurrentLocation()) failHost("history_forward had no next location");
        return dispatchCurrentLocationSources(host, roc_host);
    }

    /// Provides current location for native semantic observation without duplicating engine behavior.
    pub fn currentLocation(host: *const Host) boundary.LocationSnapshot {
        return host.currentLocation();
    }

    /// Sets visibility at the narrow host or engine boundary that owns the mutation.
    pub fn setVisibility(host: *Host, roc_host: *RocHost, visibility: boundary.VisibilitySnapshot) CommandCounts {
        host.setVisibility(visibility);
        return dispatchCurrentVisibilitySources(host, roc_host);
    }

    /// Sets online at the narrow host or engine boundary that owns the mutation.
    pub fn setOnline(host: *Host, roc_host: *RocHost, online: boundary.OnlineSnapshot) CommandCounts {
        host.setOnline(online);
        return dispatchCurrentOnlineSources(host, roc_host);
    }

    /// Provides storage value for native semantic observation without duplicating engine behavior.
    pub fn storageValue(host: *const Host, area: boundary.StorageArea, key: []const u8) ?[]const u8 {
        return host.storageValue(area, key);
    }

    /// Provides document title for native semantic observation without duplicating engine behavior.
    pub fn documentTitle(host: *const Host) []const u8 {
        return host.currentDocumentTitle();
    }

    /// Provides finish host metrics for native semantic observation without duplicating engine behavior.
    pub fn finishHostMetrics(host: *Host) void {
        finishHostMetricsForBenchmark(host);
    }

    /// Provides cleanup event count for native semantic observation without duplicating engine behavior.
    pub fn cleanupEventCount(host: *const Host, name: []const u8) u64 {
        return host.engine.cleanupEventCount(name);
    }

    /// Resolves pending task count by name from the bounded task registry without scanning unrelated work.
    pub fn pendingTaskCountByName(host: *const Host, name: []const u8) u64 {
        return host.engine.pendingTaskCountByName(name);
    }

    /// Provides canceled task count by name for native semantic observation without duplicating engine behavior.
    pub fn canceledTaskCountByName(host: *const Host, name: []const u8) u64 {
        return host.canceledTaskCountByName(name);
    }

    /// Returns active interval record count by period from the maintained active-runtime indexes.
    pub fn activeIntervalRecordCountByPeriod(host: *const Host, period_ms: u64) u64 {
        return host.engine.activeIntervalRecordCountByPeriod(period_ms);
    }

    /// Returns last runtime metrics retained for observability or local structural traversal.
    pub fn lastRuntimeMetrics(host: *const Host) RuntimeMetrics {
        return host.engine.last_runtime_metrics;
    }

    /// Provides trace allocation checkpoint for native semantic observation without duplicating engine behavior.
    pub fn traceAllocationCheckpoint(host: *Host, line_num: usize, command_name: []const u8) void {
        host.traceAllocationCheckpoint(line_num, command_name);
    }
};

const SpecRunner = spec_runner.Runner(SpecRunnerCtx);

comptime {
    if (!host_fixtures) {
        @export(&hostAlloc, .{ .name = "roc_alloc", .visibility = .hidden });
        @export(&hostDealloc, .{ .name = "roc_dealloc", .visibility = .hidden });
        @export(&hostRealloc, .{ .name = "roc_realloc", .visibility = .hidden });
        @export(&hostDbg, .{ .name = "roc_dbg", .visibility = .hidden });
        @export(&hostExpectFailed, .{ .name = "roc_expect_failed", .visibility = .hidden });
        @export(&hostCrashed, .{ .name = "roc_crashed", .visibility = .hidden });
        @export(&hostValueClone, .{ .name = "roc_host_value_clone", .visibility = .hidden });
        @export(&hostValueGetWithCapability, .{ .name = "roc_host_value_get_with_capability", .visibility = .hidden });
        @export(&hostValueGetWithSplit, .{ .name = "roc_host_value_get_with_split", .visibility = .hidden });
        @export(&hostValueStoreWithCapability, .{ .name = "roc_host_value_store_with_capability", .visibility = .hidden });
        @export(&hostValueStoreWithExistingCapability, .{ .name = "roc_host_value_store_with_existing_capability", .visibility = .hidden });
        @export(&hostValueTakeWithCapability, .{ .name = "roc_host_value_take_with_capability", .visibility = .hidden });
        @export(&hostValueTakeWithSplit, .{ .name = "roc_host_value_take_with_split", .visibility = .hidden });

        @export(&main, .{ .name = "main" });
        if (@import("builtin").os.tag == .windows) {
            @export(&__main, .{ .name = "__main" });
        }
    }
}

fn __main() callconv(.c) void {}

fn main(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    var verbose = false;
    var trace_allocations = false;
    var result_json = false;
    var bench_app = false;
    var bench_name: []const u8 = "app_dispatch";
    var bench_warmup: usize = 0;
    var bench_iterations: usize = 100;
    var bench_samples: usize = 3;
    var spec_file: ?[]const u8 = null;

    var i: usize = 1;
    const arg_count: usize = @intCast(argc);
    while (i < arg_count) : (i += 1) {
        const arg = std.mem.span(argv[i]);
        if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--trace-allocations")) {
            trace_allocations = true;
        } else if (std.mem.eql(u8, arg, "--run-spec-json")) {
            result_json = true;
        } else if (std.mem.eql(u8, arg, "--bench-app")) {
            bench_app = true;
        } else if (std.mem.eql(u8, arg, "--bench-name")) {
            i += 1;
            if (i >= arg_count) {
                writeUsage();
                return 1;
            }
            bench_name = std.mem.span(argv[i]);
        } else if (std.mem.eql(u8, arg, "--bench-iterations")) {
            i += 1;
            if (i >= arg_count) {
                writeUsage();
                return 1;
            }
            bench_iterations = std.fmt.parseInt(usize, std.mem.span(argv[i]), 10) catch {
                writeStderr("Error: Invalid --bench-iterations value\n");
                return 1;
            };
            if (bench_iterations == 0) {
                writeStderr("Error: --bench-iterations must be greater than zero\n");
                return 1;
            }
        } else if (std.mem.eql(u8, arg, "--bench-warmup")) {
            i += 1;
            if (i >= arg_count) {
                writeStderr("Error: --bench-warmup requires a value\n");
                return 1;
            }
            bench_warmup = std.fmt.parseInt(usize, std.mem.span(argv[i]), 10) catch {
                writeStderr("Error: Invalid --bench-warmup value\n");
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--bench-samples")) {
            i += 1;
            if (i >= arg_count) {
                writeUsage();
                return 1;
            }
            bench_samples = std.fmt.parseInt(usize, std.mem.span(argv[i]), 10) catch {
                writeStderr("Error: Invalid --bench-samples value\n");
                return 1;
            };
            if (bench_samples == 0) {
                writeStderr("Error: --bench-samples must be greater than zero\n");
                return 1;
            }
        } else if (arg.len > 0 and arg[0] != '-') {
            spec_file = arg;
        } else {
            writeUsage();
            return 1;
        }
    }

    if (spec_file == null) {
        writeUsage();
        return 1;
    }

    if (bench_app) {
        if (builtin.mode != .ReleaseFast) {
            writeStderr("Error: --bench-app requires a ReleaseFast host; run `zig build build-test-hosts -Doptimize=ReleaseFast` before building the Roc app\n");
            return 1;
        }
        return runAppBenchmarks(spec_file.?, bench_name, bench_warmup, bench_iterations, bench_samples, verbose) catch |err| {
            writeStderr("HOST ERROR: ");
            writeStderr(@errorName(err));
            writeStderr("\n");
            return 1;
        };
    }

    return platform_main(spec_file.?, verbose, trace_allocations, result_json) catch |err| {
        writeStderr("HOST ERROR: ");
        writeStderr(@errorName(err));
        writeStderr("\n");
        return 1;
    };
}

fn locationSnapshotFromSpecText(text: []const u8) boundary.LocationSnapshot {
    return spec_parser.locationSnapshotFromSpecText(text) catch failHost("set_initial_location path must start with /");
}

fn visibilitySnapshotFromSpecText(text: []const u8) boundary.VisibilitySnapshot {
    return spec_parser.visibilitySnapshotFromSpecText(text) catch failHost("visibility must be visible or hidden");
}

fn onlineSnapshotFromSpecText(text: []const u8) boundary.OnlineSnapshot {
    return spec_parser.onlineSnapshotFromSpecText(text) catch failHost("online state must be online or offline");
}

fn applyPreMountSpecCommands(host: *HostEnv, commands: []const SpecCommand) void {
    for (commands) |cmd| {
        switch (cmd.cmd_type) {
            .set_initial_location => {
                const text = cmd.expected_text orelse failHost("set_initial_location command is missing URL text");
                host.setCurrentLocation(locationSnapshotFromSpecText(text));
            },
            .set_initial_visibility => {
                const text = cmd.expected_text orelse failHost("set_initial_visibility command is missing visibility text");
                host.setVisibility(visibilitySnapshotFromSpecText(text));
            },
            .set_initial_online => {
                const text = cmd.expected_text orelse failHost("set_initial_online command is missing online text");
                host.setOnline(onlineSnapshotFromSpecText(text));
            },
            .seed_local_storage, .seed_session_storage => {
                const key = cmd.task_name orelse failHost("seed storage command is missing key text");
                const value = cmd.expected_text orelse failHost("seed storage command is missing value text");
                const area: boundary.StorageArea = switch (cmd.cmd_type) {
                    .seed_local_storage => .local,
                    .seed_session_storage => .session,
                    else => unreachable,
                };
                host.setStorageText(area, key, value);
            },
            else => {},
        }
    }
}

fn platform_main(spec_file: []const u8, verbose: bool, trace_allocations: bool, result_json: bool) error{}!c_int {
    const started_ns = benchmark.nowNs();
    var host_env = HostEnv.init();
    defer if (host_env.gpa.deinit() == .leak) failHost("native host leaked host-owned allocations at shutdown");
    const allocator = host_env.hostAllocator();

    const parsed_spec = parseTestSpecFile(allocator, spec_file) catch |err| {
        const message = switch (err) {
            ParseError.FileNotFound => "test spec file not found",
            ParseError.InvalidFormat => "invalid test spec format",
            else => "failed to parse test spec",
        };
        switch (err) {
            ParseError.FileNotFound => writeStderr("Error: Test spec file not found\n"),
            ParseError.InvalidFormat => writeStderr("Error: Invalid test spec format\n"),
            else => writeStderr("Error: Failed to parse test spec\n"),
        }
        if (result_json) writeSpecJsonResult(.{
            .id = spec_file,
            .name = spec_file,
            .status = "error",
            .duration_ns = benchmark.nowNs() - started_ns,
            .failure = .{ .phase = "parse", .kind = "invalid_spec", .message = message },
        });
        return 2;
    };
    defer allocator.free(parsed_spec.name);
    host_env.test_state.commands = parsed_spec.commands;
    host_env.test_state.verbose = verbose;
    host_env.test_state.trace_allocations = trace_allocations;

    var roc_host = makeSignalsRocHost(&host_env);
    host_env.engine.roc_host = &roc_host;
    current_host = &host_env;
    current_roc_host = &roc_host;
    defer current_host = null;
    defer current_roc_host = null;
    defer host_env.deinit();

    applyPreMountSpecCommands(&host_env, host_env.test_state.commands);
    acceptInitElem(&host_env, &roc_host, abi.roc_ui_init());
    host_env.traceAllocationCheckpoint(0, "mount");

    if (verbose) {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "[INFO] UI built: {d} DOM elements, {d} recomputed nodes\n", .{
            host_env.dom_elements.items.len,
            host_env.engine.last_runtime_metrics.dirty_source_roots,
        }) catch "";
        writeStderr(msg);
        host_env.dumpDom();
    }

    const result = SpecRunner.run(&host_env, &roc_host, host_env.test_state.commands, verbose);
    if (result_json) writeSpecJsonResult(.{
        .id = spec_file,
        .name = parsed_spec.name,
        .status = if (result == 0) "passed" else "failed",
        .duration_ns = benchmark.nowNs() - started_ns,
        .failure = if (result == 0) null else .{
            .phase = "step",
            .kind = "assertion",
            .message = "spec step failed; see captured stderr for details",
        },
    });
    return result;
}

fn deinitTestHostGraph(host: *HostEnv) void {
    if (!host_fixtures) @compileError("deinitTestHostGraph is test-only");

    const allocator = host.hostAllocator();
    host.clearActiveSignalRoutes();
    host.engine.active_source_signal_routes.deinit(allocator);
    host.engine.active_text_signal_routes.deinit(allocator);
    host.engine.active_bool_signal_routes.deinit(allocator);
    host.engine.active_change_signal_routes.deinit(allocator);
    host.engine.active_structural_signal_routes.deinit(allocator);
    host.engine.clearActiveIntervals(host);
    host.engine.active_intervals.deinit(allocator);
    host.clearActiveSignalGraph();
    host.engine.active_signal_graph.deinit(allocator);
    host.clearActiveEvents();
    host.engine.active_events.deinit(allocator);
    host.clearEventDescriptors();
    host.engine.event_descriptors.deinit(allocator);
    host.clearSignalEventRoutes();
    host.engine.signal_event_routes.deinit(allocator);
    host.clearSignalDescriptors();
    host.engine.signal_descriptors.deinit(allocator);
    host.clearSignalRoutes();
    host.engine.signal_routes.deinit(allocator);
    host.clearSignalDependents();
    host.engine.signal_dependents.deinit(allocator);
    host.clearSignalCache();
    host.engine.signal_cache.deinit(allocator);
}

fn deinitTestHostIdentity(host: *HostEnv) void {
    if (!host_fixtures) @compileError("deinitTestHostIdentity is test-only");

    const allocator = host.hostAllocator();
    host.clearScopes();
    host.engine.scopes.deinit(allocator);
    host.engine.node_identities.deinit(allocator);
    host.engine.dom_identities.deinit(allocator);
    host.engine.active_node_identity_ids.deinit(allocator);
    host.engine.active_dom_identity_ids.deinit(allocator);
    host.engine.deinitScratch(host);
    if (host.engine.host_values.hasLiveValues()) failHost("test host value registry still owned a typed cell at shutdown");
    host.engine.host_values.deinit(allocator);
    host.test_host_value_kinds.deinit(allocator);
    host.roc_allocations.deinit(allocator);
}

test "signals metrics accumulate propagation pruning counters" {
    var left = zeroRuntimeMetrics();
    left.active_graph_records_rebuilt = 7;
    left.allocs_this_event = 9;
    left.deallocs_this_event = 6;
    left.events_processed = 2;
    left.host_allocs_this_event = 3;
    left.host_deallocs_this_event = 2;
    left.host_alloc_bytes_this_event = 128;
    left.host_dealloc_bytes_this_event = 64;
    left.host_retained_alloc_delta = 1;
    left.host_retained_bytes_delta = 64;
    left.dirty_source_roots = 5;
    left.propagation_prunes = 3;
    left.derived_calls_into_roc = 4;
    left.each_key_compares = 6;
    left.each_key_hashes = 2;
    left.each_key_reuse_compares = 3;
    left.each_key_duplicate_compares = 1;
    left.each_item_compares = 4;
    left.each_syncs = 5;
    left.each_sync_keys = 6;
    left.each_sync_existing_rows = 7;
    left.recompute_batches = 2;
    left.patches_emitted = 7;
    left.create_element = 2;
    left.append_child = 3;
    left.remove_node = 4;
    left.move_before = 5;
    left.set_text = 1;
    left.bind_event = 1;
    left.stream_nodes_scanned = 12;
    left.stream_nodes_scanned_apply = 1;
    left.stream_nodes_scanned_children = 2;
    left.stream_nodes_scanned_dirty_scope = 3;
    left.stream_nodes_scanned_events = 4;
    left.stream_nodes_scanned_mounts = 5;
    left.stream_nodes_scanned_remove_target = 6;
    left.stream_nodes_scanned_render_scope = 7;
    left.stream_nodes_scanned_splice = 8;
    left.signal_record_table_rebuilt = 9;
    left.active_intervals_synced = 10;
    left.render_indexes_refreshed = 11;

    var right = zeroRuntimeMetrics();
    right.active_graph_records_rebuilt = 2;
    right.allocs_this_event = 4;
    right.deallocs_this_event = 5;
    right.events_processed = 1;
    right.host_allocs_this_event = 5;
    right.host_deallocs_this_event = 1;
    right.host_alloc_bytes_this_event = 512;
    right.host_dealloc_bytes_this_event = 128;
    right.host_retained_alloc_delta = 4;
    right.host_retained_bytes_delta = 384;
    right.dirty_source_roots = 8;
    right.propagation_prunes = 11;
    right.derived_calls_into_roc = 6;
    right.each_key_compares = 7;
    right.each_key_hashes = 5;
    right.each_key_reuse_compares = 7;
    right.each_key_duplicate_compares = 11;
    right.each_item_compares = 13;
    right.each_syncs = 17;
    right.each_sync_keys = 19;
    right.each_sync_existing_rows = 23;
    right.recompute_batches = 1;
    right.patches_emitted = 13;
    right.create_element = 5;
    right.append_child = 8;
    right.remove_node = 10;
    right.move_before = 12;
    right.set_text = 2;
    right.bind_event = 4;
    right.stream_nodes_scanned = 5;
    right.stream_nodes_scanned_apply = 11;
    right.stream_nodes_scanned_children = 13;
    right.stream_nodes_scanned_dirty_scope = 17;
    right.stream_nodes_scanned_events = 19;
    right.stream_nodes_scanned_mounts = 23;
    right.stream_nodes_scanned_remove_target = 29;
    right.stream_nodes_scanned_render_scope = 31;
    right.stream_nodes_scanned_splice = 37;
    right.signal_record_table_rebuilt = 41;
    right.active_intervals_synced = 43;
    right.render_indexes_refreshed = 47;
    right.retained_alloc_delta = -2;

    const total = addRuntimeMetrics(left, right);
    try std.testing.expectEqual(@as(u64, 9), total.active_graph_records_rebuilt);
    try std.testing.expectEqual(@as(u64, 13), total.allocs_this_event);
    try std.testing.expectEqual(@as(u64, 11), total.deallocs_this_event);
    try std.testing.expectEqual(@as(u64, 3), total.events_processed);
    try std.testing.expectEqual(@as(u64, 8), total.host_allocs_this_event);
    try std.testing.expectEqual(@as(u64, 3), total.host_deallocs_this_event);
    try std.testing.expectEqual(@as(u64, 640), total.host_alloc_bytes_this_event);
    try std.testing.expectEqual(@as(u64, 192), total.host_dealloc_bytes_this_event);
    try std.testing.expectEqual(@as(i64, 5), total.host_retained_alloc_delta);
    try std.testing.expectEqual(@as(i64, 448), total.host_retained_bytes_delta);
    try std.testing.expectEqual(@as(u64, 13), total.dirty_source_roots);
    try std.testing.expectEqual(@as(u64, 14), total.propagation_prunes);
    try std.testing.expectEqual(@as(u64, 10), total.derived_calls_into_roc);
    try std.testing.expectEqual(@as(u64, 13), total.each_key_compares);
    try std.testing.expectEqual(@as(u64, 7), total.each_key_hashes);
    try std.testing.expectEqual(@as(u64, 10), total.each_key_reuse_compares);
    try std.testing.expectEqual(@as(u64, 12), total.each_key_duplicate_compares);
    try std.testing.expectEqual(@as(u64, 17), total.each_item_compares);
    try std.testing.expectEqual(@as(u64, 22), total.each_syncs);
    try std.testing.expectEqual(@as(u64, 25), total.each_sync_keys);
    try std.testing.expectEqual(@as(u64, 30), total.each_sync_existing_rows);
    try std.testing.expectEqual(@as(u64, 3), total.recompute_batches);
    try std.testing.expectEqual(@as(u64, 20), total.patches_emitted);
    try std.testing.expectEqual(@as(u64, 7), total.create_element);
    try std.testing.expectEqual(@as(u64, 11), total.append_child);
    try std.testing.expectEqual(@as(u64, 14), total.remove_node);
    try std.testing.expectEqual(@as(u64, 17), total.move_before);
    try std.testing.expectEqual(@as(u64, 3), total.set_text);
    try std.testing.expectEqual(@as(u64, 5), total.bind_event);
    try std.testing.expectEqual(@as(u64, 17), total.stream_nodes_scanned);
    try std.testing.expectEqual(@as(u64, 12), total.stream_nodes_scanned_apply);
    try std.testing.expectEqual(@as(u64, 15), total.stream_nodes_scanned_children);
    try std.testing.expectEqual(@as(u64, 20), total.stream_nodes_scanned_dirty_scope);
    try std.testing.expectEqual(@as(u64, 23), total.stream_nodes_scanned_events);
    try std.testing.expectEqual(@as(u64, 28), total.stream_nodes_scanned_mounts);
    try std.testing.expectEqual(@as(u64, 35), total.stream_nodes_scanned_remove_target);
    try std.testing.expectEqual(@as(u64, 38), total.stream_nodes_scanned_render_scope);
    try std.testing.expectEqual(@as(u64, 45), total.stream_nodes_scanned_splice);
    try std.testing.expectEqual(@as(u64, 50), total.signal_record_table_rebuilt);
    try std.testing.expectEqual(@as(u64, 53), total.active_intervals_synced);
    try std.testing.expectEqual(@as(u64, 58), total.render_indexes_refreshed);
    try std.testing.expectEqual(@as(i64, -2), total.retained_alloc_delta);
}

test "signals host assigns explicit active graph record ids" {
    test_erased_callable_drop_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    const state_token = newTestBinderToken(&roc_host);
    const label = testNodeStableStrMapExpr(&roc_host, testNodeRefExpr(state_token));
    const root = testNodeStateWithTokenAndInitial(
        &roc_host,
        state_token,
        testHostValueI64(1),
        testNodeTextSignal(&roc_host, label),
    );
    defer root.decref(&roc_host);

    var stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
    _ = applyNodeDescriptorStream(&host, &roc_host, &stream);
    host.engine.active_stream = stream;

    try std.testing.expectEqual(@as(usize, 2), host.engine.active_signal_graph.items.len);
    try std.testing.expectEqual(@as(u64, 2), host.engine.pending_roc_metrics.active_graph_records_rebuilt);

    const first_record = host.engine.active_signal_graph.items[0].record;
    const second_record = host.engine.active_signal_graph.items[1].record;
    try std.testing.expectEqual(@as(?u64, 0), first_record.active_graph_id);
    try std.testing.expectEqual(@as(?u64, 1), second_record.active_graph_id);
    try std.testing.expectEqual(@as(u64, 0), host.requireActiveSignalRecordId(first_record));
    try std.testing.expectEqual(@as(u64, 1), host.requireActiveSignalRecordId(second_record));

    host.clearActiveSignalGraph();

    try std.testing.expectEqual(@as(usize, 0), host.engine.active_signal_graph.items.len);
    try std.testing.expectEqual(@as(?u64, null), first_record.active_graph_id);
    try std.testing.expectEqual(@as(?u64, null), second_record.active_graph_id);
}

test "signals host allocation ledger tracks exact returned pointers" {
    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    const first = rocAllocFn(&roc_host, 8, 8) orelse return error.OutOfMemory;
    const middle = rocAllocFn(&roc_host, 16, 8) orelse return error.OutOfMemory;
    const last = rocAllocFn(&roc_host, 24, 8) orelse return error.OutOfMemory;

    try std.testing.expectEqual(@as(usize, 3), host.roc_allocations.allocations.items.len);
    try std.testing.expect(findExactRocAllocationIndex(&host, first) != null);
    try std.testing.expect(findExactRocAllocationIndex(&host, middle) != null);
    try std.testing.expect(findExactRocAllocationIndex(&host, last) != null);

    rocDeallocFn(&roc_host, middle, 8);

    try std.testing.expectEqual(@as(usize, 2), host.roc_allocations.allocations.items.len);
    try std.testing.expect(findExactRocAllocationIndex(&host, first) != null);
    try std.testing.expectEqual(@as(?usize, null), findExactRocAllocationIndex(&host, middle));
    try std.testing.expect(findExactRocAllocationIndex(&host, last) != null);
    try std.testing.expect(findRecentlyFreedRocAllocation(&host, middle) != null);
    try std.testing.expectEqual(@as(u64, 3), host.engine.pending_roc_metrics.allocs_this_event);
    try std.testing.expectEqual(@as(u64, 1), host.engine.pending_roc_metrics.deallocs_this_event);

    const grown = rocReallocFn(&roc_host, first, 32, 8) orelse return error.OutOfMemory;

    try std.testing.expectEqual(@as(usize, 2), host.roc_allocations.allocations.items.len);
    try std.testing.expectEqual(@as(?usize, null), findExactRocAllocationIndex(&host, first));
    try std.testing.expect(findExactRocAllocationIndex(&host, grown) != null);
    try std.testing.expect(findExactRocAllocationIndex(&host, last) != null);
    try std.testing.expect(findRecentlyFreedRocAllocation(&host, first) != null);
    try std.testing.expectEqual(@as(u64, 4), host.alloc_count);
    try std.testing.expectEqual(@as(u64, 2), host.dealloc_count);
    try std.testing.expectEqual(@as(u64, 4), host.engine.pending_roc_metrics.allocs_this_event);
    try std.testing.expectEqual(@as(u64, 2), host.engine.pending_roc_metrics.deallocs_this_event);

    rocDeallocFn(&roc_host, last, 8);
    rocDeallocFn(&roc_host, grown, 8);

    try std.testing.expectEqual(@as(usize, 0), host.roc_allocations.allocations.items.len);
    try std.testing.expectEqual(@as(u64, 4), host.alloc_count);
    try std.testing.expectEqual(@as(u64, 4), host.dealloc_count);
    try std.testing.expectEqual(@as(u64, 4), host.engine.pending_roc_metrics.allocs_this_event);
    try std.testing.expectEqual(@as(u64, 4), host.engine.pending_roc_metrics.deallocs_this_event);
}

test "native host allocation injection remains recoverable outside Roc ABI calls" {
    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.configureAllocationFailure(null);
        host.deinit();
        _ = host.gpa.deinit();
    }

    host.configureAllocationFailure(1);
    try std.testing.expectError(error.OutOfMemory, host.hostAllocator().alloc(u8, 32));
    try std.testing.expectEqual(@as(usize, 0), host.roc_allocations.allocations.items.len);

    host.configureAllocationFailure(null);
    const recovered = rocAllocFn(&roc_host, 32, 8) orelse return error.OutOfMemory;
    try std.testing.expectEqual(@as(usize, 1), host.roc_allocations.allocations.items.len);
    rocDeallocFn(&roc_host, recovered, 8);
    try std.testing.expectEqual(@as(usize, 0), host.roc_allocations.allocations.items.len);
}

test "native Roc ABI allocation failures terminate in a subprocess" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (std.process.Environ.getPosix(std.testing.environ, "ROC_SIGNALS_FATAL_ALLOC_FIXTURE")) |mode| {
        var host = HostEnv.init();
        var roc_host = makeSignalsRocHost(&host);
        host.engine.roc_host = &roc_host;
        if (std.mem.eql(u8, mode, "alloc")) {
            host.configureAllocationFailure(1);
            _ = rocAllocFn(&roc_host, 32, 8);
        } else if (std.mem.eql(u8, mode, "realloc")) {
            const original = rocAllocFn(&roc_host, 32, 8) orelse unreachable;
            host.configureAllocationFailure(1);
            _ = rocReallocFn(&roc_host, original, 64, 8);
        } else if (std.mem.eql(u8, mode, "event_callback")) {
            const cap = testHostValueCapability(&roc_host);
            const reducer = writeTestErasedCallable(TestErasedI64Capture, &roc_host, &testUnitIncrementHostValueCallable, &testErasedCallableOnDrop, .{ .amount = 0 });
            const current = testHostValueI64(1);
            const payload = testHostValueUnit();
            host.configureAllocationFailure(1);
            _ = callHostValueHostValueHostValueToHostValueWithCapabilities(&host, &roc_host, cap, cap, cap, reducer, current, current, payload);
        } else if (std.mem.eql(u8, mode, "task_callback")) {
            const cap = testHostValueCapability(&roc_host);
            const transform = writeTestErasedCallable(TestErasedI64Capture, &roc_host, &testStableStrHostValueCallable, &testErasedCallableOnDrop, .{ .amount = 0 });
            const payload = testHostValueI64(1);
            host.configureAllocationFailure(1);
            _ = callHostValueToHostValueWithCapability(&host, &roc_host, cap, transform, payload);
        } else if (std.mem.eql(u8, mode, "duplicate_each_key")) {
            const cap = testHostValueCapability(&roc_host);
            const keys = [_]HostValue{ testHostValueI64(42), testHostValueI64(42) };
            const items = [_]HostValue{ testHostValueI64(1), testHostValueI64(2) };
            _ = host.engine.internRootScope(host.hostAllocator()) catch unreachable;
            _ = syncTestEachRowScopes(&host, &roc_host, ids.root_scope, 3, &keys, &items, cap, cap);
        } else unreachable;
        unreachable;
    }

    for ([_]struct { mode: []const u8, diagnostic: []const u8 }{
        .{ .mode = "alloc", .diagnostic = "HOST ERROR: Roc allocation failed\n" },
        .{ .mode = "realloc", .diagnostic = "HOST ERROR: Roc reallocation failed\n" },
        .{ .mode = "event_callback", .diagnostic = "HOST ERROR: Roc allocation failed\n" },
        .{ .mode = "task_callback", .diagnostic = "HOST ERROR: Roc allocation failed\n" },
        .{ .mode = "duplicate_each_key", .diagnostic = "Ui.each_str duplicate key \"42\": rows 1 and 2 share this key (each site: parent scope 0, ordinal 3); keys must be unique per list\n" },
    }) |case| {
        var environment = try std.testing.environ.createMap(std.testing.allocator);
        defer environment.deinit();
        try environment.put("ROC_SIGNALS_FATAL_ALLOC_FIXTURE", case.mode);
        const result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{"/proc/self/exe"},
            .environ_map = &environment,
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(4096),
        });
        defer std.testing.allocator.free(result.stdout);
        defer std.testing.allocator.free(result.stderr);
        switch (result.term) {
            .exited => |status| {
                try std.testing.expectEqual(@as(u8, 1), status);
            },
            .signal => |signal| {
                try std.testing.expectEqualStrings("duplicate_each_key", case.mode);
                try std.testing.expectEqual(std.posix.SIG.ABRT, signal);
            },
            else => return error.TestUnexpectedResult,
        }
        if (std.mem.eql(u8, case.mode, "duplicate_each_key")) {
            try std.testing.expect(std.mem.indexOf(u8, result.stderr, case.diagnostic) != null);
        } else {
            try std.testing.expect(std.mem.endsWith(u8, result.stderr, case.diagnostic));
        }
    }
}

test "native prepared render publication keeps DOM unchanged until armed apply" {
    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }
    const allocator = host.hostAllocator();
    host.engine.resetRenderTree(&host);
    host.engine.appendRenderNode(&host, ids.ElemId.fromRaw(1), ids.ElemId.fromRaw(0), "button");
    var splice = try render_cache.PreparedRenderSplice(NativeCtx).init(allocator, &host.engine.render_cache, .{
        .node_capacity = 4,
        .new_tags = 1,
        .removals = 1,
        .creations = 1,
        .children = 2,
        .child_links = 3,
        .text_fields = 1,
        .bool_fields = 1,
        .fixed_events = 1,
        .custom_attrs = 1,
        .named_events = 1,
        .wire_commands = 10,
    });
    defer splice.deinit();
    try splice.addNodeReplacement(&host.engine.render_cache, ids.ElemId.fromRaw(1), "section");
    try splice.addCreation(&host.engine.render_cache, ids.ElemId.fromRaw(3), "text");
    try splice.addChildren(&host.engine.render_cache, ids.ElemId.fromRaw(0), &.{ids.ElemId.fromRaw(1)});
    try splice.addChildren(&host.engine.render_cache, ids.ElemId.fromRaw(1), &.{ids.ElemId.fromRaw(3)});
    try splice.addTextField(&host.engine.render_cache, ids.ElemId.fromRaw(3), .text, "prepared");
    try splice.addBoolField(&host.engine.render_cache, ids.ElemId.fromRaw(1), .checked, true);
    const click_binding = render_sink.EventBinding{ .event_id = ids.EventId.fromRaw(17), .payload_descriptor = RenderEventKind.click.payloadDescriptor() };
    try splice.addFixedEvent(&host.engine.render_cache, ids.ElemId.fromRaw(1), .click, click_binding);
    try splice.addCustomAttrs(&host.engine.render_cache, ids.ElemId.fromRaw(1), &.{.{ .name = "data-state", .value = "ready" }});
    try splice.addNamedEvents(&host.engine.render_cache, ids.ElemId.fromRaw(1), &.{.{
        .name = "submit",
        .binding = .{ .event_id = ids.EventId.fromRaw(19), .payload_descriptor = boundary.BoundaryPayloadDescriptor.init(.unit, .none) },
    }});

    var publication = try NativeRenderPublication.prepare(&host, &splice);
    defer publication.deinit();
    try std.testing.expectEqualStrings("button", host.dom_elements.items[1].tag);
    try std.testing.expectEqual(@as(usize, 2), host.dom_elements.items.len);
    host.configureAllocationFailure(1);
    publication.apply(&host);
    try std.testing.expectEqual(@as(usize, 0), host.allocation_fault.?.attempts);
    try std.testing.expectEqualStrings("section", host.dom_elements.items[1].tag);
    try std.testing.expect(host.dom_elements.items[1].checked);
    try std.testing.expectEqualStrings("ready", host.dom_elements.items[1].attrs.items[0].value);
    try std.testing.expectEqual(@as(?u64, 17), if (host.dom_elements.items[1].event_bindings.click) |binding| binding.event_id.raw() else null);
    try std.testing.expectEqualStrings("submit", host.dom_elements.items[1].named_events.items[0].name);
    try std.testing.expectEqual(@as(u64, 19), host.dom_elements.items[1].named_events.items[0].binding.event_id.raw());
    try std.testing.expectEqualStrings("prepared", host.dom_elements.items[3].text.?);
    try std.testing.expectEqualSlices(u64, &.{1}, host.dom_elements.items[0].children.items);
    try std.testing.expectEqualSlices(u64, &.{3}, host.dom_elements.items[1].children.items);
    try std.testing.expectEqual(@as(?u64, 1), host.dom_elements.items[3].parent_id);
    host.configureAllocationFailure(null);

    var counted = try NativeRenderPublication.prepare(&host, &splice);
    const prepare_attempts = host.allocation_fault.?.attempts;
    counted.deinit();
    try std.testing.expect(prepare_attempts != 0);
    for (1..prepare_attempts + 1) |failure_number| {
        host.configureAllocationFailure(failure_number);
        try std.testing.expectError(error.OutOfMemory, NativeRenderPublication.prepare(&host, &splice));
        try std.testing.expectEqual(@as(usize, 1), host.allocation_fault.?.induced_failures);
        try std.testing.expectEqualStrings("section", host.dom_elements.items[1].tag);
        try std.testing.expectEqualStrings("prepared", host.dom_elements.items[3].text.?);
        host.configureAllocationFailure(null);
        var retry = try NativeRenderPublication.prepare(&host, &splice);
        retry.deinit();
    }

    const dom_value_node = &host.dom_elements.items[1];
    dom_value_node.value = try allocator.dupe(u8, "same");
    dom_value_node.pending_value = try allocator.dupe(u8, "stale");
    dom_value_node.focused = true;
    const updates_before = dom_value_node.value_update_count;
    var equal_value = try render_cache.PreparedRenderSplice(NativeCtx).init(allocator, &host.engine.render_cache, .{ .node_capacity = 4, .text_fields = 1, .wire_commands = 1 });
    defer equal_value.deinit();
    try equal_value.addTextField(&host.engine.render_cache, ids.ElemId.fromRaw(1), .value, "same");
    var equal_publication = try NativeRenderPublication.prepare(&host, &equal_value);
    try std.testing.expectEqualStrings("same", equal_publication.dom.node(1).?.value.?);
    try std.testing.expectEqual(@as(?[]const u8, null), equal_publication.dom.node(1).?.pending_value);
    try std.testing.expectEqual(updates_before, equal_publication.dom.node(1).?.value_update_count);
    equal_publication.deinit();

    var differing_value = try render_cache.PreparedRenderSplice(NativeCtx).init(allocator, &host.engine.render_cache, .{ .node_capacity = 4, .text_fields = 1, .wire_commands = 1 });
    defer differing_value.deinit();
    try differing_value.addTextField(&host.engine.render_cache, ids.ElemId.fromRaw(1), .value, "different");
    var differing_publication = try NativeRenderPublication.prepare(&host, &differing_value);
    try std.testing.expectEqualStrings("same", differing_publication.dom.node(1).?.value.?);
    try std.testing.expectEqualStrings("different", differing_publication.dom.node(1).?.pending_value.?);
    try std.testing.expectEqual(updates_before, differing_publication.dom.node(1).?.value_update_count);
    differing_publication.deinit();

    host.engine.render_cache.nodes.items[1].value = try allocator.dupe(u8, "cache-value");
    var clear_value = try render_cache.PreparedRenderSplice(NativeCtx).init(allocator, &host.engine.render_cache, .{ .node_capacity = 4, .text_fields = 1, .wire_commands = 1 });
    defer clear_value.deinit();
    try clear_value.addTextField(&host.engine.render_cache, ids.ElemId.fromRaw(1), .value, null);
    var clear_publication = try NativeRenderPublication.prepare(&host, &clear_value);
    try std.testing.expectEqual(@as(?[]const u8, null), clear_publication.dom.node(1).?.value);
    try std.testing.expectEqualStrings("stale", clear_publication.dom.node(1).?.pending_value.?);
    try std.testing.expectEqual(updates_before + 1, clear_publication.dom.node(1).?.value_update_count);
    clear_publication.deinit();

    host.configureAllocationFailure(1);
    try NativeRenderPublication.prepareTextField(host.hostAllocator(), dom_value_node, .value, "same");
    try std.testing.expectEqual(@as(usize, 0), host.allocation_fault.?.attempts);
    try std.testing.expectEqualStrings("same", dom_value_node.value.?);
    try std.testing.expectEqual(@as(?[]const u8, null), dom_value_node.pending_value);
    host.configureAllocationFailure(null);
}

test "native engine identity preparation sweeps all recoverable allocation failures" {
    const node_count = blk: {
        var host = HostEnv.init();
        var roc_host = makeSignalsRocHost(&host);
        host.engine.roc_host = &roc_host;
        defer {
            host.configureAllocationFailure(null);
            host.deinit();
            _ = host.gpa.deinit();
        }
        const root = try host.engine.internRootScope(host.hostAllocator());
        host.configureAllocationFailure(null);
        _ = try host.engine.internNodeIdentity(host.hostAllocator(), root.scope_id, ids.SiteOrdinal.fromRaw(0));
        break :blk host.allocation_fault.?.attempts;
    };
    try std.testing.expect(node_count >= 2);

    for (1..node_count + 1) |failure_number| {
        var host = HostEnv.init();
        var roc_host = makeSignalsRocHost(&host);
        host.engine.roc_host = &roc_host;
        defer {
            host.configureAllocationFailure(null);
            host.deinit();
            _ = host.gpa.deinit();
        }
        const root = try host.engine.internRootScope(host.hostAllocator());
        host.configureAllocationFailure(failure_number);

        try std.testing.expectError(error.OutOfMemory, host.engine.internNodeIdentity(host.hostAllocator(), root.scope_id, ids.SiteOrdinal.fromRaw(0)));
        try std.testing.expectEqual(@as(usize, 0), host.engine.node_identities.items.len);
        try std.testing.expectEqual(@as(usize, 0), host.engine.active_node_identity_ids.count());

        host.configureAllocationFailure(null);
        try std.testing.expectEqual(ids.NodeId.fromRaw(0), try host.engine.internNodeIdentity(host.hostAllocator(), root.scope_id, ids.SiteOrdinal.fromRaw(0)));
        try std.testing.expectEqual(@as(usize, 1), host.engine.node_identities.items.len);
        try std.testing.expectEqual(@as(usize, 1), host.engine.active_node_identity_ids.count());
    }

    const dom_count = blk: {
        var host = HostEnv.init();
        var roc_host = makeSignalsRocHost(&host);
        host.engine.roc_host = &roc_host;
        defer {
            host.configureAllocationFailure(null);
            host.deinit();
            _ = host.gpa.deinit();
        }
        const root = try host.engine.internRootScope(host.hostAllocator());
        host.configureAllocationFailure(null);
        _ = try host.engine.internDomIdentity(host.hostAllocator(), root.scope_id, ids.SiteOrdinal.fromRaw(0));
        break :blk host.allocation_fault.?.attempts;
    };
    try std.testing.expect(dom_count >= 2);

    for (1..dom_count + 1) |failure_number| {
        var host = HostEnv.init();
        var roc_host = makeSignalsRocHost(&host);
        host.engine.roc_host = &roc_host;
        defer {
            host.configureAllocationFailure(null);
            host.deinit();
            _ = host.gpa.deinit();
        }
        const root = try host.engine.internRootScope(host.hostAllocator());
        host.configureAllocationFailure(failure_number);

        try std.testing.expectError(error.OutOfMemory, host.engine.internDomIdentity(host.hostAllocator(), root.scope_id, ids.SiteOrdinal.fromRaw(0)));
        try std.testing.expectEqual(@as(usize, 0), host.engine.dom_identities.items.len);
        try std.testing.expectEqual(@as(usize, 0), host.engine.active_dom_identity_ids.count());

        host.configureAllocationFailure(null);
        try std.testing.expectEqual(ids.ElemId.fromRaw(1), try host.engine.internDomIdentity(host.hostAllocator(), root.scope_id, ids.SiteOrdinal.fromRaw(0)));
        try std.testing.expectEqual(@as(usize, 1), host.engine.dom_identities.items.len);
        try std.testing.expectEqual(@as(usize, 1), host.engine.active_dom_identity_ids.count());
    }
}

const TestErasedI64Capture = extern struct {
    amount: i64,
};

const TestErasedBinderCapture = extern struct {
    condition_binder: HostBinderToken,
    condition_cap: HostValueCapability,
};

const TestErasedHostValueCapture = extern struct {
    value: HostValue,
};

const TestBinderInitialCapture = extern struct {
    value: HostValue,
    initialized: bool,
};

const TestCapabilityCloneCapture = extern struct {
    split: abi.RocErasedCallable,
};

const TestTaskPayloadCapture = extern struct {
    payload_cap: HostValueCapability,
};

const TestPayloadTransformCapture = extern struct {
    cap: HostValueCapability,
};

const TestLocationCmdCapture = extern struct {
    tag: abi.NodeCmdTag,
    path: RocStr,
    query: RocStr,
    hash: RocStr,
};

const TestLocationPathEqualsCapture = extern struct {
    cap: HostValueCapability,
    path: RocStr,
};

var test_erased_callable_drop_count: u64 = 0;
var test_row_elem_call_count: u64 = 0;

fn testCapturePtrAs(comptime T: type, capture_ptr: ?[*]u8) *T {
    return @ptrCast(@alignCast(capture_ptr orelse unreachable));
}

fn testErasedArgsAs(comptime T: type, args: ?[*]const u8) *align(1) const T {
    return @as(*align(1) const T, @ptrCast(args orelse unreachable));
}

fn writeTestErasedResult(comptime T: type, ret: ?[*]u8, value: T) void {
    @as(*align(1) T, @ptrCast(ret orelse unreachable)).* = value;
}

fn writeTestErasedCallable(
    comptime Capture: type,
    roc_host: *abi.RocHost,
    callable_fn_ptr: abi.RocErasedCallableFn,
    on_drop: ?abi.RocErasedCallableOnDrop,
    capture: Capture,
) abi.RocErasedCallable {
    comptime {
        if (@alignOf(Capture) > abi.roc_erased_callable_capture_alignment) {
            @compileError("signals test erased-callable capture alignment exceeds Roc ABI alignment");
        }
    }
    const callable = abi.rocErasedCallableAllocate(roc_host, callable_fn_ptr, on_drop, @sizeOf(Capture));
    testCapturePtrAs(Capture, abi.rocErasedCallableCapturePtr(callable)).* = capture;
    return callable;
}

fn testCurrentRocHost() *abi.RocHost {
    return currentHost().engine.roc_host orelse failHost("test HostValue helper requires an active Roc host");
}

fn capabilityTestHostValue(host: *HostEnv, roc_host: *abi.RocHost, value: HostValue) HostValue {
    const cap = testHostValueCapability(roc_host);
    host.setHostValueCapability(value, cap);
    host.releaseOwnedHostValueCapability(cap);
    return value;
}

fn testHostValueUnit() HostValue {
    const host = currentHost();
    const roc_host = testCurrentRocHost();
    return hostValueUnit(host, roc_host);
}

fn testHostValueStr(roc_host: *abi.RocHost, value: []const u8) HostValue {
    const host = hostFromRocHost(roc_host);
    return capabilityTestHostValue(host, roc_host, hostValueStr(host, roc_host, value));
}

fn testHostValueBool(value: bool) HostValue {
    const host = currentHost();
    const roc_host = testCurrentRocHost();
    return capabilityTestHostValue(host, roc_host, hostValueBool(host, roc_host, value));
}

fn testHostValueI64(value: i64) HostValue {
    const host = currentHost();
    const roc_host = testCurrentRocHost();
    return capabilityTestHostValue(host, roc_host, hostValueI64(host, roc_host, value));
}

fn nominalHostValue(value: anytype) HostValue {
    return if (@TypeOf(value) == HostValue) value else HostValue.fromRaw(value);
}

fn testReadHostValueI64(roc_host: *abi.RocHost, raw_value: anytype) i64 {
    const value = nominalHostValue(raw_value);
    const host = hostFromRocHost(roc_host);
    if (host.testHostValueKind(value) != .i64) @panic("test HostValue expected I64");
    const box = host.getHostValue(value);
    defer abi.decrefBox(box, roc_host);
    const payload: *const i64 = @ptrCast(@alignCast(box orelse unreachable));
    return payload.*;
}

fn testReadHostValueBool(roc_host: *abi.RocHost, raw_value: anytype) bool {
    const value = nominalHostValue(raw_value);
    const host = hostFromRocHost(roc_host);
    if (host.testHostValueKind(value) != .bool) @panic("test HostValue expected Bool");
    const box = host.getHostValue(value);
    defer abi.decrefBox(box, roc_host);
    const payload: *const bool = @ptrCast(@alignCast(box orelse unreachable));
    return payload.*;
}

fn testReadHostValueStr(roc_host: *abi.RocHost, raw_value: anytype) RocStr {
    const value = nominalHostValue(raw_value);
    const host = hostFromRocHost(roc_host);
    if (host.testHostValueKind(value) != .str) @panic("test HostValue expected Str");
    const box = host.getHostValue(value);
    defer abi.decrefBox(box, roc_host);
    const payload: *const RocStr = @ptrCast(@alignCast(box orelse unreachable));
    return payload.*;
}

fn testReadHostValueI64List(roc_host: *abi.RocHost, raw_value: anytype) I64List {
    const value = nominalHostValue(raw_value);
    const host = hostFromRocHost(roc_host);
    if (host.testHostValueKind(value) != .i64_list) @panic("test HostValue expected List(I64)");
    const box = host.getHostValue(value);
    defer abi.decrefBox(box, roc_host);
    const payload: *const I64List = @ptrCast(@alignCast(box orelse unreachable));
    return payload.*;
}

fn testReadHostValueU8List(roc_host: *abi.RocHost, raw_value: anytype) U8List {
    const value = nominalHostValue(raw_value);
    const host = hostFromRocHost(roc_host);
    if (host.testHostValueKind(value) != .u8_list) @panic("test HostValue expected List(U8)");
    const box = host.getHostValue(value);
    defer abi.decrefBox(box, roc_host);
    const payload: *const U8List = @ptrCast(@alignCast(box orelse unreachable));
    return payload.*;
}

fn testDropRocStrBoxPayload(data_ptr: ?*anyopaque, roc_host: *abi.RocHost) callconv(.c) void {
    const payload: *RocStr = @ptrCast(@alignCast(data_ptr orelse return));
    payload.*.decref(roc_host);
}

fn testDropI64ListBoxPayload(data_ptr: ?*anyopaque, roc_host: *abi.RocHost) callconv(.c) void {
    const payload: *I64List = @ptrCast(@alignCast(data_ptr orelse return));
    payload.*.decref(roc_host);
}

fn testDropU8ListBoxPayload(data_ptr: ?*anyopaque, roc_host: *abi.RocHost) callconv(.c) void {
    const payload: *U8List = @ptrCast(@alignCast(data_ptr orelse return));
    payload.*.decref(roc_host);
}

fn testDropHostValue(roc_host: *abi.RocHost, raw_value: anytype) void {
    const value = nominalHostValue(raw_value);
    const host = hostFromRocHost(roc_host);
    const kind = host.testHostValueKind(value);
    const box = host.takeHostValue(value);
    switch (kind) {
        .unit, .i64, .bool => abi.decrefBox(box, roc_host),
        .str => abi.decrefBoxWith(box, @alignOf(RocStr), true, &testDropRocStrBoxPayload, roc_host),
        .i64_list => abi.decrefBoxWith(box, @alignOf(I64List), true, &testDropI64ListBoxPayload, roc_host),
        .u8_list => abi.decrefBoxWith(box, @alignOf(U8List), true, &testDropU8ListBoxPayload, roc_host),
    }
}

fn testHostValueDropCallable(roc_host: *abi.RocHost) abi.RocErasedCallable {
    return writeTestErasedCallable(
        TestErasedI64Capture,
        roc_host,
        &testDropHostValueCallable,
        &testErasedCallableOnDrop,
        .{ .amount = 0 },
    );
}

fn testHostValueCloneCallable(roc_host: *abi.RocHost, split: abi.RocErasedCallable) abi.RocErasedCallable {
    return writeTestErasedCallable(
        TestCapabilityCloneCapture,
        roc_host,
        &testCloneHostValueWithSplitCallable,
        &testCapabilityCloneOnDrop,
        .{ .split = split },
    );
}

fn testHostValueCapabilityWithEq(roc_host: *abi.RocHost, eq_fn: abi.RocErasedCallableFn) HostValueCapability {
    const split = writeTestErasedCallable(
        TestErasedI64Capture,
        roc_host,
        &testSplitHostValueBoxCallable,
        &testErasedCallableOnDrop,
        .{ .amount = 0 },
    );
    return .{
        .clone = testHostValueCloneCallable(roc_host, split),
        .eq = writeTestErasedCallable(
            TestErasedI64Capture,
            roc_host,
            eq_fn,
            &testErasedCallableOnDrop,
            .{ .amount = 0 },
        ),
        .drop = testHostValueDropCallable(roc_host),
    };
}

fn testHostValueCapability(roc_host: *abi.RocHost) HostValueCapability {
    return testHostValueCapabilityWithEq(roc_host, &testHostValueEqErasedCallable);
}

fn testHostValueKeyTextCallable(roc_host: *abi.RocHost) abi.RocErasedCallable {
    return writeTestErasedCallable(
        TestErasedI64Capture,
        roc_host,
        &testHostValueKeyTextErasedCallable,
        &testErasedCallableOnDrop,
        .{ .amount = 0 },
    );
}

fn testHashI64KeyText(value: i64) u64 {
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
    return std.hash.Wyhash.hash(0, text);
}

fn testHashHostValueKeyText(roc_host: *abi.RocHost, key: HostValue) u64 {
    return testHashI64KeyText(testReadHostValueI64(roc_host, key));
}

fn testReadStrCallable(roc_host: *abi.RocHost) abi.RocErasedCallable {
    return writeTestErasedCallable(
        TestErasedI64Capture,
        roc_host,
        &testReadStrHostValueCallable,
        &testErasedCallableOnDrop,
        .{ .amount = 0 },
    );
}

fn testReadBoolCallable(roc_host: *abi.RocHost) abi.RocErasedCallable {
    return writeTestErasedCallable(
        TestErasedI64Capture,
        roc_host,
        &testReadBoolHostValueCallable,
        &testErasedCallableOnDrop,
        .{ .amount = 0 },
    );
}

fn testItemsToValuesCallable(roc_host: *abi.RocHost) abi.RocErasedCallable {
    return writeTestErasedCallable(
        TestErasedI64Capture,
        roc_host,
        &testI64ListToHostValuesCallable,
        &testErasedCallableOnDrop,
        .{ .amount = 0 },
    );
}

fn testUnaryHostValueCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const capture = testCapturePtrAs(TestErasedI64Capture, capture_ptr);
    const call_args = testErasedArgsAs(ErasedHostValueUnaryArgs, args);
    const input = testReadHostValueI64(roc_host, call_args.arg0);
    const host = hostFromRocHost(roc_host);
    writeTestErasedResult(HostValue, ret, capabilityTestHostValue(host, roc_host, hostValueI64(host, roc_host, input + capture.amount)));
}

/// A `key_of` that buckets items by integer division, so two different item
/// values can share one row key and an edit can change a row's item in place.
fn testBucketKeyHostValueCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const capture = testCapturePtrAs(TestErasedI64Capture, capture_ptr);
    const call_args = testErasedArgsAs(ErasedHostValueUnaryArgs, args);
    const input = testReadHostValueI64(roc_host, call_args.arg0);
    const host = hostFromRocHost(roc_host);
    writeTestErasedResult(HostValue, ret, capabilityTestHostValue(host, roc_host, hostValueI64(host, roc_host, @divTrunc(input, capture.amount))));
}

fn testHostValueKeyTextErasedCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    _ = capture_ptr;
    const call_args = testErasedArgsAs(ErasedHostValueUnaryArgs, args);
    const value = testReadHostValueI64(roc_host, call_args.arg0);
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
    writeTestErasedResult(RocStr, ret, RocStr.fromSlice(text, roc_host));
}

fn testUnaryIdentityHostValueCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    _ = capture_ptr;
    const call_args = testErasedArgsAs(ErasedHostValueUnaryArgs, args);
    writeTestErasedResult(HostValue, ret, hostFromRocHost(roc_host).cloneHostValue(HostValue.fromRaw(call_args.arg0)));
}

fn testBinaryHostValueCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const capture = testCapturePtrAs(TestErasedI64Capture, capture_ptr);
    const call_args = testErasedArgsAs(ErasedHostValueBinaryArgs, args);
    const left = testReadHostValueI64(roc_host, call_args.arg0);
    const right = testReadHostValueI64(roc_host, call_args.arg1);
    const host = hostFromRocHost(roc_host);
    writeTestErasedResult(HostValue, ret, capabilityTestHostValue(host, roc_host, hostValueI64(host, roc_host, left + right + capture.amount)));
}

fn testTernaryEventHostValueCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const capture = testCapturePtrAs(TestErasedI64Capture, capture_ptr);
    const call_args = testErasedArgsAs(ErasedHostValueTernaryArgs, args);
    const current = testReadHostValueI64(roc_host, call_args.arg0);
    const payload = testReadHostValueI64(roc_host, call_args.arg2);
    const host = hostFromRocHost(roc_host);
    writeTestErasedResult(HostValue, ret, capabilityTestHostValue(host, roc_host, hostValueI64(host, roc_host, current + payload + capture.amount)));
}

fn testUnitIncrementHostValueCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    _ = capture_ptr;
    const call_args = testErasedArgsAs(ErasedHostValueTernaryArgs, args);
    const current = testReadHostValueI64(roc_host, call_args.arg0);
    if (hostFromRocHost(roc_host).testHostValueKind(HostValue.fromRaw(call_args.arg2)) != .unit) @panic("test unit event callable expected unit payload");
    const host = hostFromRocHost(roc_host);
    writeTestErasedResult(HostValue, ret, capabilityTestHostValue(host, roc_host, hostValueI64(host, roc_host, current + 1)));
}

fn testInitialHostValueCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    _ = args;
    const capture = testCapturePtrAs(TestErasedHostValueCapture, capture_ptr);
    writeTestErasedResult(HostValue, ret, hostFromRocHost(roc_host).cloneHostValue(capture.value));
}

fn testBinderInitialCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    _ = args;
    const capture = testCapturePtrAs(TestBinderInitialCapture, capture_ptr);
    if (!capture.initialized) @panic("test binder initializer was used before receiving its value");
    writeTestErasedResult(HostValue, ret, hostFromRocHost(roc_host).cloneHostValue(capture.value));
}

fn testBinaryElemCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const capture = testCapturePtrAs(TestErasedI64Capture, capture_ptr);
    const call_args = testErasedArgsAs(ErasedHostValueBinaryArgs, args);
    const left = testReadHostValueI64(roc_host, call_args.arg0);
    const right = testReadHostValueI64(roc_host, call_args.arg1);
    var text_buffer: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buffer, "row-{d}", .{left + right + capture.amount}) catch @panic("test row Elem callable could not format text");
    writeTestErasedResult(abi.Elem, ret, testNodeText(roc_host, text));
}

fn testStatefulRowElemCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    test_row_elem_call_count += 1;
    const capture = testCapturePtrAs(TestErasedI64Capture, capture_ptr);
    const call_args = testErasedArgsAs(ErasedHostValueBinaryArgs, args);
    const key = testReadHostValueI64(roc_host, call_args.arg0);
    const item = testReadHostValueI64(roc_host, call_args.arg1);
    var text_buffer: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buffer, "row-{d}-{d}", .{ key, item + capture.amount }) catch @panic("test stateful row Elem callable could not format text");
    writeTestErasedResult(abi.Elem, ret, testNodeState(roc_host, testNodeText(roc_host, text)));
}

fn testStatefulRowButtonElemCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    test_row_elem_call_count += 1;
    const capture = testCapturePtrAs(TestErasedI64Capture, capture_ptr);
    const call_args = testErasedArgsAs(ErasedHostValueBinaryArgs, args);
    const key = testReadHostValueI64(roc_host, call_args.arg0);
    const item = testReadHostValueI64(roc_host, call_args.arg1);
    var text_buffer: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buffer, "row-action-{d}-{d}", .{ key, item + capture.amount }) catch @panic("test stateful row button Elem callable could not format text");
    const token = newTestBinderToken(roc_host);
    const attrs = [_]abi.NodeAttr{
        testNodeStaticTextAttr(roc_host, .text, text),
        testNodeEventAttr(roc_host, .click, token, .unit),
    };
    const button = testElementWith(roc_host, "button", &attrs, &.{});
    writeTestErasedResult(abi.Elem, ret, testNodeStateWithToken(roc_host, token, button));
}

fn testNestedWhenRowElemCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    test_row_elem_call_count += 1;
    const capture = testCapturePtrAs(TestErasedBinderCapture, capture_ptr);
    const call_args = testErasedArgsAs(ErasedHostValueBinaryArgs, args);
    const key = testReadHostValueI64(roc_host, call_args.arg0);
    const item = testReadHostValueI64(roc_host, call_args.arg1);

    var true_text_buffer: [64]u8 = undefined;
    var false_text_buffer: [64]u8 = undefined;
    const true_text = std.fmt.bufPrint(&true_text_buffer, "row-{d}-{d}-true", .{ key, item }) catch @panic("test nested row true text format failed");
    const false_text = std.fmt.bufPrint(&false_text_buffer, "row-{d}-{d}-false", .{ key, item }) catch @panic("test nested row false text format failed");
    const row = abi.Elem{
        .payload = .{
            .when = .{
                .condition = boxTestNodeSignalExpr(roc_host, testNodeRefExpr(capture.condition_binder)),
                .read = testBoolReadHandle(roc_host, capture.condition_cap),
                .when_false = boxTestElem(roc_host, testNodeText(roc_host, false_text)),
                .when_true = boxTestElem(roc_host, testNodeText(roc_host, true_text)),
            },
        },
        .tag = .When,
    };
    writeTestErasedResult(abi.Elem, ret, row);
}

fn testInitialEachNestedRowElemCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    _ = args;
    _ = capture_ptr;
    const state_token = newTestBinderToken(roc_host);
    const state_cap = testHostValueCapability(roc_host);
    var event = testNodeUnitIncrementEventAttr(roc_host, .click, state_token);
    event.payload.on.kind.id = 0;
    event.payload.on.name = RocStr.fromSlice("keydown", roc_host);
    const signal_attr = abi.NodeAttr{ .payload = .{ .signal_text = .{
        .field = .{ .id = @intFromEnum(RenderTextField.value) },
        .name = RocStr.fromSlice("", roc_host),
        .read = testI64TextReadHandle(roc_host, state_cap),
        .signal = boxTestNodeSignalExpr(roc_host, testNodeRefExpr(state_token)),
    } }, .tag = .SignalText };
    const attrs = [_]abi.NodeAttr{ event, signal_attr };
    const nested_when = testNodeWhen(roc_host, testNodeText(roc_host, "row-true"), testNodeText(roc_host, "row-false"));
    const child = testElementWith(roc_host, "div", &attrs, &.{nested_when});
    const row = testNodeStateWithTokenAndInitialCapability(roc_host, state_token, testHostValueI64(7), child, state_cap);
    writeTestErasedResult(abi.Elem, ret, row);
}

/// Renders one outer row as a label plus a nested keyed list of stateful rows,
/// so an initial mount stages each sites at two depths inside one transaction.
fn testNestedEachRowElemCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    _ = capture_ptr;
    test_row_elem_call_count += 1;
    const call_args = testErasedArgsAs(ErasedHostValueBinaryArgs, args);
    const key = testReadHostValueI64(roc_host, call_args.arg0);
    const inner_items = [_]HostValue{ testHostValueI64(key * 10 + 1), testHostValueI64(key * 10 + 2) };
    var text_buffer: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buffer, "outer-{d}", .{key}) catch @panic("test nested each row Elem callable could not format text");
    const children = [_]abi.Elem{ testNodeText(roc_host, text), testNodeEachWithItems(roc_host, &inner_items) };
    writeTestErasedResult(abi.Elem, ret, testElement(roc_host, &children));
}

/// Renders one outer row as a label plus a nested keyed list whose rows each
/// own a state cell, so a live edit that grows the outer list claims node
/// identities at two depths inside one staged transaction.
fn testNestedStatefulEachRowElemCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    _ = capture_ptr;
    test_row_elem_call_count += 1;
    const call_args = testErasedArgsAs(ErasedHostValueBinaryArgs, args);
    const key = testReadHostValueI64(roc_host, call_args.arg0);
    const inner_items = [_]HostValue{ testHostValueI64(key * 10 + 1), testHostValueI64(key * 10 + 2), testHostValueI64(key * 10 + 3) };
    var text_buffer: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buffer, "outer-{d}", .{key}) catch @panic("test nested stateful each row Elem callable could not format text");
    const children = [_]abi.Elem{ testNodeText(roc_host, text), testNodeEachWithItemsAndRow(roc_host, &inner_items, &testStatefulRowElemCallable) };
    writeTestErasedResult(abi.Elem, ret, testElement(roc_host, &children));
}

/// Renders one outer row as a label plus a nested keyed list whose rows nest
/// a further keyed list of stateful rows, so one transaction stages each
/// sites at three depths under every outer row.
fn testDoublyNestedEachRowElemCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    _ = capture_ptr;
    test_row_elem_call_count += 1;
    const call_args = testErasedArgsAs(ErasedHostValueBinaryArgs, args);
    const key = testReadHostValueI64(roc_host, call_args.arg0);
    const inner_items = [_]HostValue{ testHostValueI64(key * 10 + 1), testHostValueI64(key * 10 + 2) };
    var text_buffer: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buffer, "deep-{d}", .{key}) catch @panic("test doubly nested each row Elem callable could not format text");
    const children = [_]abi.Elem{ testNodeText(roc_host, text), testNodeEachWithItemsAndRow(roc_host, &inner_items, &testNestedEachRowElemCallable) };
    writeTestErasedResult(abi.Elem, ret, testElement(roc_host, &children));
}

/// Renders one row as a state cell whose constant-true branch owns an
/// interval source, so replacing the row retires an interval two scopes
/// below the row scope.
fn testIntervalBranchRowElemCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    _ = capture_ptr;
    test_row_elem_call_count += 1;
    const call_args = testErasedArgsAs(ErasedHostValueBinaryArgs, args);
    const key = testReadHostValueI64(roc_host, call_args.arg0);
    var text_buffer: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buffer, "row-{d}", .{key}) catch @panic("test interval branch row Elem callable could not format text");
    const clock = testNodeI64TextSignal(roc_host, testNodeIntervalSourceExpr(roc_host, 100, key));
    const when = testNodeWhen(roc_host, clock, testNodeText(roc_host, "clock-off"));
    const children = [_]abi.Elem{ testNodeText(roc_host, text), when };
    writeTestErasedResult(abi.Elem, ret, testNodeState(roc_host, testElement(roc_host, &children)));
}

fn testHostValueEqErasedCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    _ = capture_ptr;
    const call_args = testErasedArgsAs(ErasedHostValueBinaryArgs, args);
    const host = hostFromRocHost(roc_host);
    const left_kind = host.testHostValueKind(HostValue.fromRaw(call_args.arg0));
    const right_kind = host.testHostValueKind(HostValue.fromRaw(call_args.arg1));
    const is_equal = if (left_kind != right_kind) false else switch (left_kind) {
        .unit => true,
        .i64 => testReadHostValueI64(roc_host, call_args.arg0) == testReadHostValueI64(roc_host, call_args.arg1),
        .bool => testReadHostValueBool(roc_host, call_args.arg0) == testReadHostValueBool(roc_host, call_args.arg1),
        .str => blk: {
            const left = testReadHostValueStr(roc_host, call_args.arg0);
            const right = testReadHostValueStr(roc_host, call_args.arg1);
            break :blk std.mem.eql(u8, left.asSlice(), right.asSlice());
        },
        .i64_list => blk: {
            const left = testReadHostValueI64List(roc_host, call_args.arg0);
            const right = testReadHostValueI64List(roc_host, call_args.arg1);
            break :blk std.mem.eql(i64, left.items(), right.items());
        },
        .u8_list => blk: {
            const left = testReadHostValueU8List(roc_host, call_args.arg0);
            const right = testReadHostValueU8List(roc_host, call_args.arg1);
            break :blk std.mem.eql(u8, left.items(), right.items());
        },
    };
    writeTestErasedResult(bool, ret, is_equal);
}

fn testStableStrHostValueCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    _ = args;
    _ = capture_ptr;
    const host = hostFromRocHost(roc_host);
    writeTestErasedResult(HostValue, ret, capabilityTestHostValue(host, roc_host, hostValueStr(host, roc_host, "stable")));
}

fn testStableI64HostValueCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    _ = args;
    const capture = testCapturePtrAs(TestErasedI64Capture, capture_ptr);
    const host = hostFromRocHost(roc_host);
    writeTestErasedResult(HostValue, ret, capabilityTestHostValue(host, roc_host, hostValueI64(host, roc_host, capture.amount)));
}

fn testStableBoolHostValueCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    _ = args;
    _ = capture_ptr;
    const host = hostFromRocHost(roc_host);
    writeTestErasedResult(HostValue, ret, capabilityTestHostValue(host, roc_host, hostValueBool(host, roc_host, true)));
}

fn testBoolIdentityHostValueCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    _ = capture_ptr;
    const call_args = testErasedArgsAs(ErasedHostValueUnaryArgs, args);
    const input = testReadHostValueBool(roc_host, call_args.arg0);
    const host = hostFromRocHost(roc_host);
    writeTestErasedResult(HostValue, ret, capabilityTestHostValue(host, roc_host, hostValueBool(host, roc_host, input)));
}

fn testAlwaysEqualHostValueCallable(_: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    _ = args;
    _ = capture_ptr;
    writeTestErasedResult(bool, ret, true);
}

fn testNeverEqualHostValueCallable(_: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    _ = args;
    _ = capture_ptr;
    writeTestErasedResult(bool, ret, false);
}

fn testSplitHostValueBoxCallable(_: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    _ = capture_ptr;
    const call_args = testErasedArgsAs(ErasedRocBoxUnaryArgs, args);
    abi.increfBox(call_args.arg0, 1);
    writeTestErasedResult(erased_calls.RocBoxPair, ret, .{
        .keep = call_args.arg0,
        .out = call_args.arg0,
    });
}

fn testCloneHostValueWithSplitCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const capture = testCapturePtrAs(TestCapabilityCloneCapture, capture_ptr);
    const call_args = testErasedArgsAs(ErasedHostValueUnaryArgs, args);
    const host = hostFromRocHost(roc_host);

    abi.increfErasedCallable(capture.split, 1);
    const value = HostValue.fromRaw(call_args.arg0);
    const box = host.getHostValueWithSplit(value, CapabilitySplit.fromAbi(capture.split));
    const cloned = host.storeHostValueWithExistingCapability(box, value);
    writeTestErasedResult(HostValue, ret, cloned);
}

fn testErasedCallableOnDrop(_: ?[*]u8, _: *abi.RocHost) callconv(.c) void {
    test_erased_callable_drop_count += 1;
}

fn testCapabilityCloneOnDrop(capture_ptr: ?[*]u8, roc_host: *abi.RocHost) callconv(.c) void {
    test_erased_callable_drop_count += 1;
    const capture = testCapturePtrAs(TestCapabilityCloneCapture, capture_ptr);
    abi.decrefErasedCallable(capture.split, roc_host);
}

fn testBinderCaptureOnDrop(capture_ptr: ?[*]u8, roc_host: *abi.RocHost) callconv(.c) void {
    test_erased_callable_drop_count += 1;
    const capture = testCapturePtrAs(TestErasedBinderCapture, capture_ptr);
    abi.decrefErasedCallable(capture.condition_binder, roc_host);
    hv.releaseHostValueCapability(capture.condition_cap, roc_host);
}

fn testDropHostValueCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    _ = ret;
    _ = capture_ptr;
    const call_args = testErasedArgsAs(ErasedHostValueUnaryArgs, args);
    testDropHostValue(roc_host, call_args.arg0);
}

fn testConsumeTaskPayloadStrCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const host = hostFromRocHost(roc_host);
    const capture = testCapturePtrAs(TestTaskPayloadCapture, capture_ptr);
    const call_args = testErasedArgsAs(ErasedHostValueUnaryArgs, args);
    const box = host.takeHostValueWithCapability(HostValue.fromRaw(call_args.arg0), hv.retainHostValueCapability(capture.payload_cap));
    const value = host.storeHostValueWithRetainedCapability(box, capture.payload_cap);
    if (host_fixtures) host.setTestHostValueKind(value, .str);
    writeTestErasedResult(HostValue, ret, value);
}

fn testPayloadChecksumHostValueCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const host = hostFromRocHost(roc_host);
    const capture = testCapturePtrAs(TestPayloadTransformCapture, capture_ptr);
    const call_args = testErasedArgsAs(ErasedHostValueUnaryArgs, args);
    const payload = testReadHostValueU8List(roc_host, call_args.arg0);

    var checksum: i64 = 0;
    for (payload.items()) |byte| {
        checksum += @as(i64, byte);
    }
    testDropHostValue(roc_host, call_args.arg0);

    writeTestErasedResult(HostValue, ret, hv.makeI64WithCapability(host, roc_host, checksum, capture.cap));
}

fn testLocationCmdCaptureOnDrop(capture_ptr: ?[*]u8, roc_host: *abi.RocHost) callconv(.c) void {
    const capture = testCapturePtrAs(TestLocationCmdCapture, capture_ptr);
    capture.path.decref(roc_host);
    capture.query.decref(roc_host);
    capture.hash.decref(roc_host);
    test_erased_callable_drop_count += 1;
}

fn testLocationPathEqualsCaptureOnDrop(capture_ptr: ?[*]u8, roc_host: *abi.RocHost) callconv(.c) void {
    const capture = testCapturePtrAs(TestLocationPathEqualsCapture, capture_ptr);
    capture.path.decref(roc_host);
    test_erased_callable_drop_count += 1;
}

fn testLocationCmdCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    _ = args;
    const capture = testCapturePtrAs(TestLocationCmdCapture, capture_ptr);
    writeTestErasedResult(erased_calls.Cmd, ret, testLocationCmd(roc_host, capture.tag, .{
        .path = capture.path.asSlice(),
        .query = capture.query.asSlice(),
        .hash = capture.hash.asSlice(),
    }));
}

fn testLocationPathEqualsHostValueCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const host = hostFromRocHost(roc_host);
    const capture = testCapturePtrAs(TestLocationPathEqualsCapture, capture_ptr);
    const call_args = testErasedArgsAs(ErasedHostValueUnaryArgs, args);
    const payload = testReadHostValueU8List(roc_host, call_args.arg0);
    defer testDropHostValue(roc_host, call_args.arg0);

    const bytes = payload.items();
    if (bytes.len < 4) @panic("test location payload was missing path length");
    const path_len = std.mem.readInt(u32, bytes[0..4], .little);
    if (bytes.len < 4 + path_len) @panic("test location payload path length exceeded payload");
    const path = bytes[4..][0..path_len];
    writeTestErasedResult(HostValue, ret, hv.makeBoolWithCapability(host, roc_host, std.mem.eql(u8, path, capture.path.asSlice()), capture.cap));
}

fn testReadStrHostValueCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    _ = capture_ptr;
    const call_args = testErasedArgsAs(ErasedHostValueUnaryArgs, args);
    var value = testReadHostValueStr(roc_host, call_args.arg0);
    value.incref(1);
    writeTestErasedResult(RocStr, ret, value);
}

fn testReadBoolHostValueCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    _ = capture_ptr;
    const call_args = testErasedArgsAs(ErasedHostValueUnaryArgs, args);
    writeTestErasedResult(bool, ret, testReadHostValueBool(roc_host, call_args.arg0));
}

const TestCapabilityCapture = extern struct { cap: HostValueCapability };

fn testCapabilityCaptureOnDrop(capture_ptr: ?[*]u8, roc_host: *abi.RocHost) callconv(.c) void {
    hv.releaseHostValueCapability(testCapturePtrAs(TestCapabilityCapture, capture_ptr).cap, roc_host);
}

fn testI64ListContainsOneCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const host = hostFromRocHost(roc_host);
    const capture = testCapturePtrAs(TestCapabilityCapture, capture_ptr);
    const call_args = testErasedArgsAs(ErasedHostValueUnaryArgs, args);
    const values = testReadHostValueI64List(roc_host, call_args.arg0);
    const result = hostValueBool(host, roc_host, std.mem.indexOfScalar(i64, values.items(), 1) != null);
    host.setTestHostValueKind(result, .bool);
    host.setHostValueCapability(result, capture.cap);
    writeTestErasedResult(HostValue, ret, result);
}

/// Which fact about the shared `List I64` a generated `when` condition asks.
const TestListPredicate = enum(u8) {
    /// The list holds at least `operand` items.
    length_at_least,
    /// The list holds the key `operand`.
    contains,

    /// Evaluates the predicate against `items`; also the fuzz model's oracle.
    pub fn holds(self: TestListPredicate, items: []const i64, operand: i64) bool {
        return switch (self) {
            .length_at_least => items.len >= operand,
            .contains => std.mem.indexOfScalar(i64, items, operand) != null,
        };
    }
};

const TestListPredicateCapture = extern struct { cap: HostValueCapability, operand: i64, predicate: u8 };

fn testListPredicateCaptureOnDrop(capture_ptr: ?[*]u8, roc_host: *abi.RocHost) callconv(.c) void {
    hv.releaseHostValueCapability(testCapturePtrAs(TestListPredicateCapture, capture_ptr).cap, roc_host);
}

fn testI64ListPredicateCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const host = hostFromRocHost(roc_host);
    const capture = testCapturePtrAs(TestListPredicateCapture, capture_ptr);
    const call_args = testErasedArgsAs(ErasedHostValueUnaryArgs, args);
    const values = testReadHostValueI64List(roc_host, call_args.arg0);
    const predicate: TestListPredicate = @enumFromInt(capture.predicate);
    const result = hostValueBool(host, roc_host, predicate.holds(values.items(), capture.operand));
    host.setTestHostValueKind(result, .bool);
    host.setHostValueCapability(result, capture.cap);
    writeTestErasedResult(HostValue, ret, result);
}

fn testI64ListCopyCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const host = hostFromRocHost(roc_host);
    const capture = testCapturePtrAs(TestCapabilityCapture, capture_ptr);
    const call_args = testErasedArgsAs(ErasedHostValueUnaryArgs, args);
    const source = testReadHostValueI64List(roc_host, call_args.arg0);
    const source_items = source.items();
    const values = I64List.allocate(source_items.len, roc_host);
    if (source_items.len > 0) {
        const dest = values.elements_ptr orelse unreachable;
        for (source_items, 0..) |item, index| dest[index] = item;
    }
    const payload: *I64List = @ptrCast(@alignCast(abi.allocateBox(@sizeOf(I64List), @alignOf(I64List), true, roc_host)));
    payload.* = values;
    const result = host.storeHostValue(@ptrCast(payload));
    host.setTestHostValueKind(result, .i64_list);
    host.setHostValueCapability(result, capture.cap);
    writeTestErasedResult(HostValue, ret, result);
}

fn testI64ListToHostValuesCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    _ = capture_ptr;
    const host = hostFromRocHost(roc_host);
    const call_args = testErasedArgsAs(ErasedHostValueUnaryArgs, args);
    const source = testReadHostValueI64List(roc_host, call_args.arg0);
    const source_items = source.items();
    const result = HostValueList.allocate(source_items.len, roc_host);
    if (source_items.len > 0) {
        const dest = result.elements_ptr orelse unreachable;
        for (source_items, 0..) |item, index| {
            dest[index] = capabilityTestHostValue(host, roc_host, hostValueI64(host, roc_host, item));
        }
    }
    writeTestErasedResult(HostValueList, ret, result);
}

fn testHostValueCaptureOnDrop(capture_ptr: ?[*]u8, roc_host: *abi.RocHost) callconv(.c) void {
    test_erased_callable_drop_count += 1;
    const capture = testCapturePtrAs(TestErasedHostValueCapture, capture_ptr);
    testDropHostValue(roc_host, capture.value);
}

fn testBinderInitialOnDrop(capture_ptr: ?[*]u8, roc_host: *abi.RocHost) callconv(.c) void {
    test_erased_callable_drop_count += 1;
    const capture = testCapturePtrAs(TestBinderInitialCapture, capture_ptr);
    if (capture.initialized) testDropHostValue(roc_host, capture.value);
}

fn expectHostValueI64(value: HostValue, expected: i64) error{TestExpectedEqual}!void {
    const roc_host = testCurrentRocHost();
    try std.testing.expectEqual(expected, testReadHostValueI64(roc_host, value));
    testDropHostValue(roc_host, value);
}

fn expectCachedTaskSourceText(roc_host: *abi.RocHost, record: *HostSignalRecord, expected: []const u8) error{TestExpectedEqual}!void {
    const task_payload = switch (record.payload) {
        .task_source => |payload| payload,
        else => unreachable,
    };
    const cached = switch (task_payload.cached_value) {
        .present => |cell| cell,
        .absent => return error.TestExpectedEqual,
    };
    const text = testReadHostValueStr(roc_host, cached.value);
    try std.testing.expectEqualStrings(expected, text.asSlice());
}

fn makeTestConsumingTaskSourceRecord(host: *HostEnv, roc_host: *abi.RocHost, name: []const u8) *HostSignalRecord {
    const allocator = host.hostAllocator();
    const payload_cap = testHostValueCapability(roc_host);
    const capture = TestTaskPayloadCapture{ .payload_cap = payload_cap };
    const initial = writeTestErasedCallable(
        TestErasedI64Capture,
        roc_host,
        &testStableStrHostValueCallable,
        null,
        .{ .amount = 0 },
    );
    return HostSignalRecord.init(allocator, .{ .task_source = .{
        .name = allocator.dupe(u8, name) catch @panic("out of memory"),
        .payload_cap = payload_cap,
        .initial = .fromAbi(initial),
        .done = .fromAbi(writeTestErasedCallable(
            TestTaskPayloadCapture,
            roc_host,
            &testConsumeTaskPayloadStrCallable,
            &testErasedCallableOnDrop,
            capture,
        )),
        .failed = .fromAbi(writeTestErasedCallable(
            TestTaskPayloadCapture,
            roc_host,
            &testConsumeTaskPayloadStrCallable,
            &testErasedCallableOnDrop,
            capture,
        )),
        .cap = testHostValueCapability(roc_host),
        .reset_on_start = false,
    } });
}

test "signals host invokes erased HostValue thunks with ABI argument layouts" {
    test_erased_callable_drop_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    {
        const unary = writeTestErasedCallable(
            TestErasedI64Capture,
            &roc_host,
            &testUnaryHostValueCallable,
            &testErasedCallableOnDrop,
            .{ .amount = 5 },
        );
        defer abi.decrefErasedCallable(unary, &roc_host);

        const input = testHostValueI64(37);
        defer testDropHostValue(&roc_host, input);
        const result = callErasedHostValueToHostValue(&roc_host, unary, input);
        try expectHostValueI64(result, 42);
    }

    {
        const binary = writeTestErasedCallable(
            TestErasedI64Capture,
            &roc_host,
            &testBinaryHostValueCallable,
            &testErasedCallableOnDrop,
            .{ .amount = 3 },
        );
        defer abi.decrefErasedCallable(binary, &roc_host);

        const left = testHostValueI64(10);
        defer testDropHostValue(&roc_host, left);
        const right = testHostValueI64(29);
        defer testDropHostValue(&roc_host, right);
        const result = callErasedHostValueHostValueToHostValue(&roc_host, binary, left, right);
        try expectHostValueI64(result, 42);
    }

    {
        const row = writeTestErasedCallable(
            TestErasedI64Capture,
            &roc_host,
            &testBinaryElemCallable,
            &testErasedCallableOnDrop,
            .{ .amount = 3 },
        );
        defer abi.decrefErasedCallable(row, &roc_host);

        const left = testHostValueI64(10);
        defer testDropHostValue(&roc_host, left);
        const right = testHostValueI64(29);
        defer testDropHostValue(&roc_host, right);
        const result = callErasedHostValueHostValueToElem(&roc_host, row, left, right);
        defer result.decref(&roc_host);

        try std.testing.expectEqual(abi.ElemTag.Text, result.tag);
        try std.testing.expectEqualStrings("row-42", result.payload.text.asSlice());
    }

    {
        const eq = writeTestErasedCallable(
            TestErasedI64Capture,
            &roc_host,
            &testHostValueEqErasedCallable,
            &testErasedCallableOnDrop,
            .{ .amount = 0 },
        );
        defer abi.decrefErasedCallable(eq, &roc_host);

        const equal_left = testHostValueI64(42);
        defer testDropHostValue(&roc_host, equal_left);
        const equal_right = testHostValueI64(42);
        defer testDropHostValue(&roc_host, equal_right);
        try std.testing.expect(callErasedHostValueHostValueToBool(&roc_host, eq, equal_left, equal_right));

        const unequal_left = testHostValueI64(41);
        defer testDropHostValue(&roc_host, unequal_left);
        const unequal_right = testHostValueI64(42);
        defer testDropHostValue(&roc_host, unequal_right);
        try std.testing.expect(!callErasedHostValueHostValueToBool(&roc_host, eq, unequal_left, unequal_right));
    }

    try std.testing.expectEqual(@as(u64, 48), test_erased_callable_drop_count);
}

test "signals host task result callbacks consume heap string payloads" {
    test_erased_callable_drop_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;

    const record = makeTestConsumingTaskSourceRecord(&host, &roc_host, "lookup");
    host.engine.retainActiveSignalRecord(&host, record);
    defer {
        host.engine.clearActiveSignalGraph(&host);
        record.release(host.hostAllocator(), &host, &roc_host, &host.engine.pending_roc_metrics);
        host.deinit();
        _ = host.gpa.deinit();
    }

    const success_payload = "successful task payload that is intentionally longer than the Roc small string limit";
    _ = host.engine.appendPendingTask(&host, ids.ScopeId.fromRaw(0), record.token().?, "lookup", "/api/test");
    _ = resolvePendingTask(&host, &roc_host, "lookup", success_payload, false);
    try expectCachedTaskSourceText(&roc_host, record, success_payload);
    try std.testing.expectEqual(@as(usize, 0), host.engine.pending_tasks.items.len);

    const failed_payload = "failed task payload that is intentionally longer than the Roc small string limit";
    _ = host.engine.appendPendingTask(&host, ids.ScopeId.fromRaw(0), record.token().?, "lookup", "/api/test");
    _ = resolvePendingTask(&host, &roc_host, "lookup", failed_payload, true);
    try expectCachedTaskSourceText(&roc_host, record, failed_payload);
    try std.testing.expectEqual(@as(usize, 0), host.engine.pending_tasks.items.len);
}

test "task settlement sweeps host OOM without consuming pending ownership" {
    const Runner = struct {
        fn run(failure_number: ?usize) !usize {
            var host = HostEnv.init();
            var roc_host = makeSignalsRocHost(&host);
            host.engine.roc_host = &roc_host;
            defer {
                host.deinit();
                _ = host.gpa.deinit();
            }
            const task = testNodeTaskSourceExpr(&roc_host, "lookup", "loading", false);
            const root = testElement(&roc_host, &.{testNodeTextSignal(&roc_host, task)});
            defer root.decref(&roc_host);
            var stream: HostNodeDescriptorStream = .{};
            host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
            _ = applyNodeDescriptorStream(&host, &roc_host, &stream);
            host.engine.active_stream = stream;
            const record = host.engine.activeTaskRecordByName("lookup").?;
            const request_id = host.engine.appendPendingTask(&host, ids.ScopeId.fromRaw(0), record.token().?, "lookup", "/api/test");
            const source_before = record.requireTaskSource().cached_value.present.value;
            const generation_before = host.engine.dirty_signal_generation;
            const graph_len_before = host.engine.active_signal_graph.items.len;
            const dom_len_before = host.dom_elements.items.len;
            const allocations_before = host.roc_allocations.snapshot();

            const next = hostValueStrWithCapability(&host, &roc_host, "done", record.requireTaskSource().cap);
            var fault = FaultAllocator.init(host.gpa.allocator());
            fault.configure(failure_number);
            host.engine_allocator_override = fault.allocator();
            const result = host.engine.tryDispatchTaskSourceValue(&host, &roc_host, request_id, record, next);
            const attempts = fault.attempts;
            if (failure_number != null) {
                try std.testing.expectError(error.OutOfMemory, result);
                try std.testing.expectEqual(@as(usize, 1), fault.induced_failures);
                try std.testing.expectEqual(@as(usize, 1), host.engine.pending_tasks.items.len);
                try std.testing.expectEqual(request_id, host.engine.pending_tasks.items[0].request_id);
                try std.testing.expectEqual(source_before, record.requireTaskSource().cached_value.present.value);
                try std.testing.expectEqual(generation_before, host.engine.dirty_signal_generation);
                try std.testing.expectEqual(graph_len_before, host.engine.active_signal_graph.items.len);
                try std.testing.expectEqual(dom_len_before, host.dom_elements.items.len);
                try std.testing.expect(activeTextElementId(&host, "loading") != null);
                try std.testing.expectEqual(@as(usize, 0), host.roc_allocations.liveCountSince(allocations_before));
                fault.configure(null);
                _ = try host.engine.tryDispatchTaskSourceValue(&host, &roc_host, request_id, record, hostValueStrWithCapability(&host, &roc_host, "done", record.requireTaskSource().cap));
            } else {
                _ = try result;
            }
            try std.testing.expectEqual(@as(usize, 0), host.engine.pending_tasks.items.len);
            try std.testing.expect(activeTextElementId(&host, "done") != null);
            try std.testing.expectEqual(engine.TaskResolutionClass.superseded, host.engine.classifyTaskResolution(request_id));
            const equal_request_id = host.engine.appendPendingTask(&host, ids.ScopeId.fromRaw(0), record.token().?, "lookup", "/api/equal");
            const generation_after_change = host.engine.dirty_signal_generation;
            const equal_counts = try host.engine.tryDispatchTaskSourceValue(&host, &roc_host, equal_request_id, record, hostValueStrWithCapability(&host, &roc_host, "done", record.requireTaskSource().cap));
            try std.testing.expectEqual(@as(u64, 0), equal_counts.total);
            try std.testing.expectEqual(generation_after_change, host.engine.dirty_signal_generation);
            try std.testing.expectEqual(@as(usize, 0), host.engine.pending_tasks.items.len);
            try std.testing.expectEqual(engine.TaskResolutionClass.superseded, host.engine.classifyTaskResolution(equal_request_id));
            try std.testing.expectError(error.InvalidDescriptor, host.engine.tryDispatchTaskSourceValue(&host, &roc_host, equal_request_id, record, hostValueStrWithCapability(&host, &roc_host, "duplicate", record.requireTaskSource().cap)));
            try std.testing.expectEqual(generation_after_change, host.engine.dirty_signal_generation);
            try std.testing.expectEqual(@as(usize, 0), host.engine.pending_tasks.items.len);
            try std.testing.expect(activeTextElementId(&host, "done") != null);
            return attempts;
        }
    };

    const attempts = try Runner.run(null);
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| _ = try Runner.run(failure_number);
}

test "native task resolution uses the pending source token when active names repeat" {
    test_erased_callable_drop_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;

    const first = makeTestConsumingTaskSourceRecord(&host, &roc_host, "favorite");
    const second = makeTestConsumingTaskSourceRecord(&host, &roc_host, "favorite");
    host.engine.retainActiveSignalRecord(&host, first);
    host.engine.retainActiveSignalRecord(&host, second);
    defer {
        host.engine.clearActiveSignalGraph(&host);
        first.release(host.hostAllocator(), &host, &roc_host, &host.engine.pending_roc_metrics);
        second.release(host.hostAllocator(), &host, &roc_host, &host.engine.pending_roc_metrics);
        host.deinit();
        _ = host.gpa.deinit();
    }

    const second_token = second.token().?;
    _ = host.engine.appendPendingTask(&host, ids.ScopeId.fromRaw(0), second_token, "favorite", "/api/favorite");
    _ = resolvePendingTask(&host, &roc_host, "favorite", "second result", false);

    try expectCachedTaskSourceText(&roc_host, second, "second result");
    switch (first.requireTaskSource().cached_value) {
        .absent => {},
        .present => return error.TestUnexpectedResult,
    }
}

test "signals host task sources reset on start only when requested" {
    test_erased_callable_drop_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    const reset_task = testNodeTaskSourceExpr(&roc_host, "lookup", "loading", true);
    const sticky_task = testNodeTaskSourceExpr(&roc_host, "save", "idle", false);
    const children = [_]abi.Elem{
        testNodeTextSignal(&roc_host, reset_task),
        testNodeTextSignal(&roc_host, sticky_task),
    };
    const root = testElement(&roc_host, &children);
    defer root.decref(&roc_host);

    var stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
    const initial_counts = applyNodeDescriptorStream(&host, &roc_host, &stream);
    host.engine.active_stream = stream;

    try std.testing.expectEqual(@as(u64, 2), initial_counts.set_text);
    try std.testing.expectEqualStrings("loading", host.dom_elements.items[2].text.?);
    try std.testing.expectEqualStrings("idle", host.dom_elements.items[3].text.?);

    {
        const cmd = testStartTaskCmd(&roc_host, reset_task, "lookup", "/api/first");
        defer cmd.decref(&roc_host);
        const prune_start = host.engine.pending_roc_metrics.propagation_prunes;
        const counts = host.engine.startTaskCommand(&host, &roc_host, ids.ScopeId.fromRaw(0), cmd);
        try std.testing.expectEqual(@as(u64, 0), counts.total);
        try std.testing.expectEqual(prune_start + 1, host.engine.pending_roc_metrics.propagation_prunes);
        try std.testing.expectEqual(@as(usize, 1), host.engine.pending_tasks.items.len);
    }

    const resolved_counts = resolvePendingTask(&host, &roc_host, "lookup", "done", false);
    try std.testing.expectEqual(@as(u64, 1), resolved_counts.set_text);
    try std.testing.expectEqualStrings("done", host.dom_elements.items[2].text.?);

    {
        const cmd = testStartTaskCmd(&roc_host, reset_task, "lookup", "/api/second");
        defer cmd.decref(&roc_host);
        const counts = host.engine.startTaskCommand(&host, &roc_host, ids.ScopeId.fromRaw(0), cmd);
        try std.testing.expectEqual(@as(u64, 1), counts.set_text);
        try std.testing.expectEqualStrings("loading", host.dom_elements.items[2].text.?);
        try std.testing.expectEqual(@as(usize, 1), host.engine.pending_tasks.items.len);
    }
    _ = resolvePendingTask(&host, &roc_host, "lookup", "done-again", false);

    {
        const cmd = testStartTaskCmd(&roc_host, sticky_task, "save", "/api/save");
        defer cmd.decref(&roc_host);
        const counts = host.engine.startTaskCommand(&host, &roc_host, ids.ScopeId.fromRaw(0), cmd);
        try std.testing.expectEqual(@as(u64, 0), counts.total);
        try std.testing.expectEqual(@as(usize, 1), host.engine.pending_tasks.items.len);
    }

    const save_counts = resolvePendingTask(&host, &roc_host, "save", "saved", false);
    try std.testing.expectEqual(@as(u64, 1), save_counts.set_text);
    try std.testing.expectEqualStrings("saved", host.dom_elements.items[3].text.?);

    {
        const cmd = testStartTaskCmd(&roc_host, sticky_task, "save", "/api/save-again");
        defer cmd.decref(&roc_host);
        const counts = host.engine.startTaskCommand(&host, &roc_host, ids.ScopeId.fromRaw(0), cmd);
        try std.testing.expectEqual(@as(u64, 0), counts.total);
        try std.testing.expectEqualStrings("saved", host.dom_elements.items[3].text.?);
        try std.testing.expectEqual(@as(usize, 1), host.engine.pending_tasks.items.len);
    }
}

test "signals host classifies superseded task results" {
    test_erased_callable_drop_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;

    const record = makeTestConsumingTaskSourceRecord(&host, &roc_host, "lookup");
    defer {
        record.release(host.hostAllocator(), &host, &roc_host, &host.engine.pending_roc_metrics);
        host.deinit();
        _ = host.gpa.deinit();
    }

    const task_token = record.token().?;
    const request_id = host.engine.appendPendingTask(&host, ids.ScopeId.fromRaw(0), task_token, "lookup", "/api/first");

    try std.testing.expectEqual(engine.TaskResolutionClass.pending, host.engine.classifyTaskResolution(request_id));
    host.engine.cancelPendingTasksByTaskToken(&host, task_token);
    try std.testing.expectEqual(@as(usize, 0), host.engine.pending_tasks.items.len);
    try std.testing.expectEqual(engine.TaskResolutionClass.superseded, host.engine.classifyTaskResolution(request_id));
    try std.testing.expectEqual(engine.TaskResolutionClass.unknown, host.engine.classifyTaskResolution(ids.TaskRequestId.fromRaw(host.engine.next_task_request_id + 10)));

    const stale_start = host.engine.pending_roc_metrics.stale_task_results_ignored;
    host.engine.noteStaleTaskResolutionIgnored();
    try std.testing.expectEqual(stale_start + 1, host.engine.pending_roc_metrics.stale_task_results_ignored);
}

test "signals host interval sources tick by period and runtime token" {
    test_erased_callable_drop_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    const interval = testNodeIntervalSourceExpr(&roc_host, 100, 1);
    const root = testNodeI64TextSignal(&roc_host, interval);
    defer root.decref(&roc_host);

    var stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
    const initial_counts = applyNodeDescriptorStream(&host, &roc_host, &stream);
    host.engine.active_stream = stream;

    try std.testing.expectEqual(@as(u64, 1), initial_counts.set_text);
    try std.testing.expectEqualStrings("1", host.dom_elements.items[1].text.?);
    try std.testing.expectEqual(@as(usize, 1), host.engine.active_intervals.items.len);
    try std.testing.expectEqual(@as(u64, 100), host.engine.active_intervals.items[0].period_ms);

    const period_counts = tickIntervalSource(&host, &roc_host, 100);
    try std.testing.expectEqual(@as(u64, 1), period_counts.set_text);
    try std.testing.expectEqualStrings("2", host.dom_elements.items[1].text.?);

    const runtime_token = host.engine.active_intervals.items[0].token;
    const runtime_counts = host.engine.tickIntervalSourceByRuntimeToken(&host, &roc_host, runtime_token.raw());
    try std.testing.expectEqual(@as(u64, 1), runtime_counts.set_text);
    try std.testing.expectEqualStrings("3", host.dom_elements.items[1].text.?);
}

test "state transaction mounting an interval branch registers the interval it later retires" {
    // A prepared structural transaction appends new signal records through
    // PreparedGraphAppend and retires old ones through PreparedReleaseClosure.
    // Retirement removed interval sources from the active interval registry,
    // but appending never registered them: the registry only ever learned of
    // intervals through the pre-transactional rebuild path. Mounting a when
    // branch that owns Signal.interval therefore left the registry empty, and
    // swapping the branch back panicked with "active interval removal missed
    // its source token".
    const Runner = struct {
        fn run(failure_number: ?usize) !usize {
            var host = HostEnv.init();
            var roc_host = makeSignalsRocHost(&host);
            host.engine.roc_host = &roc_host;
            defer {
                host.deinit();
                _ = host.gpa.deinit();
            }

            const state_token = newTestBinderToken(&roc_host);
            const state_cap = testHostValueCapability(&roc_host);
            const clock = testNodeI64TextSignal(&roc_host, testNodeIntervalSourceExpr(&roc_host, 100, 1));
            const when: abi.Elem = .{
                .payload = .{
                    .when = .{
                        .condition = boxTestNodeSignalExpr(&roc_host, testNodeRefExpr(state_token)),
                        .read = testBoolReadHandle(&roc_host, state_cap),
                        .when_false = boxTestElem(&roc_host, testNodeText(&roc_host, "clock-off")),
                        .when_true = boxTestElem(&roc_host, clock),
                    },
                },
                .tag = .When,
            };
            // A tokened sibling record seeds the active graph the way every
            // application root does; a root made only of state refs never
            // prepares graph work at all (see the guard in
            // PreparedStructuralDownstream.prepareGraphRenderAndPublication).
            const label = testNodeI64TextSignal(&roc_host, testNodeConstExpr(&roc_host, testHostValueI64(0)));
            const section = testElementWith(&roc_host, "section", &.{}, &.{ when, label });
            const root = testNodeStateWithTokenAndInitialCapability(&roc_host, state_token, testHostValueBool(false), section, state_cap);
            defer root.decref(&roc_host);
            _ = try tryRenderInitialRoot(&host, &roc_host, root, &.{});
            try std.testing.expectEqual(@as(usize, 0), host.engine.active_intervals.items.len);
            const state_id = host.engine.active_stream.scope_sites.items[0].node_id;
            const allocations_before = host.roc_allocations.snapshot();

            var fault = FaultAllocator.init(host.gpa.allocator());
            fault.configure(failure_number);
            host.engine_allocator_override = fault.allocator();
            const result = host.engine.tryDispatchStateValue(&host, &roc_host, state_id.raw(), testHostValueBool(true), state_cap);
            const attempts = fault.attempts;
            if (failure_number != null) {
                try std.testing.expectError(error.OutOfMemory, result);
                try std.testing.expectEqual(@as(usize, 0), host.engine.active_intervals.items.len);
                try std.testing.expect(activeTextElementId(&host, "clock-off") != null);
                try std.testing.expectEqual(@as(usize, 0), host.roc_allocations.liveCountSince(allocations_before));
                fault.configure(null);
                _ = try host.engine.tryDispatchStateValue(&host, &roc_host, state_id.raw(), testHostValueBool(true), state_cap);
            } else _ = try result;

            try std.testing.expectEqual(@as(usize, 1), host.engine.active_intervals.items.len);
            try std.testing.expectEqual(@as(u64, 100), host.engine.active_intervals.items[0].period_ms);
            try std.testing.expect(activeTextElementId(&host, "clock-off") == null);
            const record = host.engine.activeIntervalRecordByPeriod(100).?;
            try std.testing.expectEqual(record.token().?, host.engine.active_intervals.items[0].source_token);
            const runtime_token = host.engine.active_intervals.items[0].token;
            _ = host.engine.tickIntervalSourceByRuntimeToken(&host, &roc_host, runtime_token.raw());

            _ = try host.engine.tryDispatchStateValue(&host, &roc_host, state_id.raw(), testHostValueBool(false), state_cap);
            try std.testing.expectEqual(@as(usize, 0), host.engine.active_intervals.items.len);
            try std.testing.expect(activeTextElementId(&host, "clock-off") != null);
            try std.testing.expect(host.engine.activeIntervalRecordByPeriod(100) == null);
            return attempts;
        }
    };

    const attempts = try Runner.run(null);
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| _ = try Runner.run(failure_number);
}

test "initial root reserves elem ids for siblings collected after an each site" {
    // The staged collection bounded the highest elem id a nested each could
    // reach by the ids interned so far plus the rows' own nodes. Siblings the
    // enclosing tree had counted but not yet collected (a text node after the
    // each site) were left out, so a signal text node inside the rows landed
    // past the per-elem descriptor index reservation and publication tripped
    // the capacity assertion. The rows nest an interval two scopes down, which
    // also exercises retiring that interval when the row is replaced.
    const Runner = struct {
        fn intervalRecordCount(host: *const HostEnv) usize {
            var count: usize = 0;
            for (host.engine.active_signal_graph.items) |node| {
                if (node.record.payload == .interval_source) count += 1;
            }
            return count;
        }

        fn run(failure_number: ?usize) !usize {
            test_row_elem_call_count = 0;
            var host = HostEnv.init();
            var roc_host = makeSignalsRocHost(&host);
            host.engine.roc_host = &roc_host;
            defer {
                host.deinit();
                _ = host.gpa.deinit();
            }

            const state_token = newTestBinderToken(&roc_host);
            const state_cap = testHostValueCapability(&roc_host);
            const each = testNodeEachWithSignalCapabilityAndRow(&roc_host, testNodeRefExpr(state_token), state_cap, &testIntervalBranchRowElemCallable);
            const label = testNodeI64TextSignal(&roc_host, testNodeConstExpr(&roc_host, testHostValueI64(0)));
            const section = testElementWith(&roc_host, "section", &.{}, &.{ each, label });
            const initial_items = [_]HostValue{testHostValueI64(1)};
            const root = testNodeStateWithTokenAndInitialCapability(&roc_host, state_token, testHostValueI64ListWithCapability(&roc_host, &initial_items, state_cap), section, state_cap);
            defer root.decref(&roc_host);
            _ = try tryRenderInitialRoot(&host, &roc_host, root, &.{});
            const state_id = host.engine.active_stream.scope_sites.items[0].node_id;
            try std.testing.expectEqual(@as(usize, 1), intervalRecordCount(&host));
            try std.testing.expectEqual(@as(usize, 1), host.engine.active_intervals.items.len);
            try std.testing.expect(activeTextElementId(&host, "row-1") != null);
            const allocations_before = host.roc_allocations.snapshot();

            var fault = FaultAllocator.init(host.gpa.allocator());
            fault.configure(failure_number);
            host.engine_allocator_override = fault.allocator();
            const next_items = [_]HostValue{testHostValueI64(2)};
            const result = host.engine.tryDispatchStateValue(&host, &roc_host, state_id.raw(), testHostValueI64ListWithCapability(&roc_host, &next_items, state_cap), state_cap);
            const attempts = fault.attempts;
            if (failure_number != null) {
                try std.testing.expectError(error.OutOfMemory, result);
                try std.testing.expectEqual(@as(usize, 1), intervalRecordCount(&host));
                try std.testing.expectEqual(@as(usize, 1), host.engine.active_intervals.items.len);
                try std.testing.expect(activeTextElementId(&host, "row-1") != null);
                try std.testing.expectEqual(@as(usize, 0), host.roc_allocations.liveCountSince(allocations_before));
                fault.configure(null);
                const retry_items = [_]HostValue{testHostValueI64(2)};
                _ = try host.engine.tryDispatchStateValue(&host, &roc_host, state_id.raw(), testHostValueI64ListWithCapability(&roc_host, &retry_items, state_cap), state_cap);
            } else _ = try result;

            // The retired row's interval leaves the graph and the registry;
            // the replacement row's interval is the only one left, so a tick
            // by period resolves to exactly one source.
            try std.testing.expect(activeTextElementId(&host, "row-1") == null);
            try std.testing.expect(activeTextElementId(&host, "row-2") != null);
            try std.testing.expectEqual(@as(usize, 1), intervalRecordCount(&host));
            try std.testing.expectEqual(@as(usize, 1), host.engine.active_intervals.items.len);
            _ = tickIntervalSource(&host, &roc_host, 100);
            try std.testing.expect(activeTextElementId(&host, "3") != null);

            _ = try host.engine.tryDispatchStateValue(&host, &roc_host, state_id.raw(), testHostValueI64ListWithCapability(&roc_host, &.{}, state_cap), state_cap);
            try std.testing.expectEqual(@as(usize, 0), intervalRecordCount(&host));
            try std.testing.expectEqual(@as(usize, 0), host.engine.active_intervals.items.len);
            return attempts;
        }
    };

    const attempts = try Runner.run(null);
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| _ = try Runner.run(failure_number);
}

test "signals host prepared interval transaction sweeps host OOM and retries" {
    const Runner = struct {
        fn run(fail_at: ?usize) !usize {
            test_erased_callable_drop_count = 0;
            var host = HostEnv.init();
            var roc_host = makeSignalsRocHost(&host);
            host.engine.roc_host = &roc_host;
            defer {
                host.configureAllocationFailure(null);
                host.deinit();
                _ = host.gpa.deinit();
            }
            const interval = testNodeIntervalSourceExpr(&roc_host, 100, 1);
            const root = testNodeI64TextSignal(&roc_host, interval);
            defer root.decref(&roc_host);
            var stream: HostNodeDescriptorStream = .{};
            host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
            _ = applyNodeDescriptorStream(&host, &roc_host, &stream);
            host.engine.active_stream = stream;
            const record = host.engine.activeIntervalRecordByPeriod(100).?;
            const next = testHostValueI64(2);

            host.configureAllocationFailure(fail_at);
            const result = host.engine.tryDispatchEffectSourceValue(&host, &roc_host, record, next);
            const attempts = host.allocation_fault.?.attempts;
            if (result) |counts| {
                try std.testing.expect(fail_at == null);
                try std.testing.expectEqual(@as(u64, 1), counts.set_text);
                try std.testing.expectEqualStrings("2", host.dom_elements.items[1].text.?);
                return attempts;
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expectEqualStrings("1", host.dom_elements.items[1].text.?);
                try std.testing.expectEqual(@as(i64, 1), testReadHostValueI64(&roc_host, record.requireIntervalSource().cached_value.present.value));
                host.configureAllocationFailure(null);
                const retry_next = testHostValueI64(2);
                const retry = try host.engine.tryDispatchEffectSourceValue(&host, &roc_host, record, retry_next);
                try std.testing.expectEqual(@as(u64, 1), retry.set_text);
                try std.testing.expectEqualStrings("2", host.dom_elements.items[1].text.?);
                return attempts;
            }
        }
    };

    const attempts = try Runner.run(null);
    var induced: usize = 0;
    for (1..attempts + 1) |fail_at| {
        _ = try Runner.run(fail_at);
        induced += 1;
    }
    try std.testing.expectEqual(attempts, induced);
}

test "signals host browser environment sources and commands update native state" {
    test_erased_callable_drop_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    try std.testing.expectEqualStrings("/", host.currentLocation().path);
    host.setCurrentLocation(.{ .path = "/start", .query = "", .hash = "" });
    host.setVisibility(.visible);
    host.setOnline(.online);
    host.setStorageText(.local, "cart", "seeded");

    {
        const exprs = [_]abi.NodeSignalExpr{
            testNodeLocationSourceExpr(&roc_host),
            testNodeVisibilitySourceExpr(&roc_host),
            testNodeOnlineSourceExpr(&roc_host),
            testNodeStorageSourceExpr(&roc_host, .local, "scratch"),
        };
        for (exprs) |expr| {
            expr.incref(1);
            expr.decref(&roc_host);
            expr.decref(&roc_host);
        }
    }

    const location = testNodeLocationSourceExpr(&roc_host);
    const visibility = testNodeVisibilitySourceExpr(&roc_host);
    const online = testNodeOnlineSourceExpr(&roc_host);
    const storage = testNodeStorageSourceExpr(&roc_host, .local, "cart");
    const children = [_]abi.Elem{
        testNodeI64TextSignal(&roc_host, location),
        testNodeI64TextSignal(&roc_host, visibility),
        testNodeI64TextSignal(&roc_host, online),
        testNodeI64TextSignal(&roc_host, storage),
    };
    const root = testElement(&roc_host, &children);
    defer root.decref(&roc_host);

    var stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
    const initial_counts = applyNodeDescriptorStream(&host, &roc_host, &stream);
    host.engine.active_stream = stream;

    try std.testing.expectEqual(@as(u64, 4), initial_counts.set_text);
    const testing_allocator = std.testing.allocator;
    const initial_location_text = try testing_allocator.dupe(u8, host.dom_elements.items[2].text.?);
    defer testing_allocator.free(initial_location_text);
    const initial_visibility_text = try testing_allocator.dupe(u8, host.dom_elements.items[3].text.?);
    defer testing_allocator.free(initial_visibility_text);
    const initial_online_text = try testing_allocator.dupe(u8, host.dom_elements.items[4].text.?);
    defer testing_allocator.free(initial_online_text);
    const initial_storage_text = try testing_allocator.dupe(u8, host.dom_elements.items[5].text.?);
    defer testing_allocator.free(initial_storage_text);

    {
        const noop_cmd = erased_calls.Cmd{ .payload = undefined, .tag = .Noop };
        retainTestCmd(noop_cmd);
        releaseTestCmd(&roc_host, noop_cmd);
        try std.testing.expectEqual(@as(u64, 0), host.engine.runCommand(&host, &roc_host, ids.ScopeId.fromRaw(0), noop_cmd).total);
    }

    {
        const cmd = testLocationCmd(&roc_host, .PushState, .{ .path = "/browser-env-next", .query = "panel=ops", .hash = "chart" });
        retainTestCmd(cmd);
        defer releaseTestCmd(&roc_host, cmd);
        defer releaseTestCmd(&roc_host, cmd);
        const counts = host.engine.runCommand(&host, &roc_host, ids.ScopeId.fromRaw(0), cmd);
        try std.testing.expectEqual(@as(u64, 1), counts.set_text);
        try std.testing.expectEqualStrings("/browser-env-next", host.currentLocation().path);
        try std.testing.expect(!std.mem.eql(u8, initial_location_text, host.dom_elements.items[2].text.?));
    }

    {
        const cmd = testLocationCmd(&roc_host, .ReplaceState, .{ .path = "/browser-env-replaced", .query = "", .hash = "" });
        retainTestCmd(cmd);
        defer releaseTestCmd(&roc_host, cmd);
        defer releaseTestCmd(&roc_host, cmd);
        const counts = host.engine.runCommand(&host, &roc_host, ids.ScopeId.fromRaw(0), cmd);
        try std.testing.expectEqual(@as(u64, 1), counts.set_text);
        try std.testing.expectEqualStrings("/browser-env-replaced", host.currentLocation().path);
    }

    {
        try std.testing.expect(host.backCurrentLocation());
        const counts = host.engine.dispatchCurrentLocationSources(&host, &roc_host);
        try std.testing.expectEqual(@as(u64, 1), counts.set_text);
        try std.testing.expectEqualStrings("/start", host.currentLocation().path);
    }

    {
        try std.testing.expect(host.forwardCurrentLocation());
        const counts = host.engine.dispatchCurrentLocationSources(&host, &roc_host);
        try std.testing.expectEqual(@as(u64, 1), counts.set_text);
        try std.testing.expectEqualStrings("/browser-env-replaced", host.currentLocation().path);
    }

    {
        try std.testing.expect(host.backCurrentLocation());
        const cmd = testLocationCmd(&roc_host, .PushState, .{ .path = "/browser-env-branch", .query = "", .hash = "" });
        retainTestCmd(cmd);
        defer releaseTestCmd(&roc_host, cmd);
        defer releaseTestCmd(&roc_host, cmd);
        _ = host.engine.runCommand(&host, &roc_host, ids.ScopeId.fromRaw(0), cmd);
        try std.testing.expectEqualStrings("/browser-env-branch", host.currentLocation().path);
        try std.testing.expect(!host.forwardCurrentLocation());
    }

    {
        host.setVisibility(.hidden);
        const counts = host.engine.dispatchCurrentVisibilitySources(&host, &roc_host);
        try std.testing.expectEqual(@as(u64, 1), counts.set_text);
        try std.testing.expect(!std.mem.eql(u8, initial_visibility_text, host.dom_elements.items[3].text.?));
    }

    {
        host.setOnline(.offline);
        const counts = host.engine.dispatchCurrentOnlineSources(&host, &roc_host);
        try std.testing.expectEqual(@as(u64, 1), counts.set_text);
        try std.testing.expect(!std.mem.eql(u8, initial_online_text, host.dom_elements.items[4].text.?));
    }

    {
        const cmd = testStorageSetCmd(&roc_host, .local, "theme", "dark");
        retainTestCmd(cmd);
        defer releaseTestCmd(&roc_host, cmd);
        defer releaseTestCmd(&roc_host, cmd);
        try std.testing.expectEqual(@as(u64, 0), host.engine.runCommand(&host, &roc_host, ids.ScopeId.fromRaw(0), cmd).total);
        try std.testing.expectEqualStrings("dark", host.storageValue(.local, "theme").?);
        try std.testing.expectEqualStrings(initial_storage_text, host.dom_elements.items[5].text.?);
    }

    {
        const cmd = testStorageSetCmd(&roc_host, .local, "theme", "light");
        retainTestCmd(cmd);
        defer releaseTestCmd(&roc_host, cmd);
        defer releaseTestCmd(&roc_host, cmd);
        _ = host.engine.runCommand(&host, &roc_host, ids.ScopeId.fromRaw(0), cmd);
        try std.testing.expectEqualStrings("light", host.storageValue(.local, "theme").?);
    }

    {
        const cmd = testStorageRemoveCmd(&roc_host, .local, "theme");
        retainTestCmd(cmd);
        defer releaseTestCmd(&roc_host, cmd);
        defer releaseTestCmd(&roc_host, cmd);
        _ = host.engine.runCommand(&host, &roc_host, ids.ScopeId.fromRaw(0), cmd);
        try std.testing.expectEqual(@as(?[]const u8, null), host.storageValue(.local, "theme"));
    }

    {
        const cmd = testStorageSetCmd(&roc_host, .local, "cart", "updated");
        retainTestCmd(cmd);
        defer releaseTestCmd(&roc_host, cmd);
        defer releaseTestCmd(&roc_host, cmd);
        const counts = host.engine.runCommand(&host, &roc_host, ids.ScopeId.fromRaw(0), cmd);
        try std.testing.expectEqual(@as(u64, 1), counts.set_text);
        try std.testing.expectEqualStrings("updated", host.storageValue(.local, "cart").?);
        try std.testing.expect(!std.mem.eql(u8, initial_storage_text, host.dom_elements.items[5].text.?));
    }

    const updated_storage_text = try testing_allocator.dupe(u8, host.dom_elements.items[5].text.?);
    defer testing_allocator.free(updated_storage_text);

    {
        const cmd = testStorageRemoveCmd(&roc_host, .local, "cart");
        retainTestCmd(cmd);
        defer releaseTestCmd(&roc_host, cmd);
        defer releaseTestCmd(&roc_host, cmd);
        const counts = host.engine.runCommand(&host, &roc_host, ids.ScopeId.fromRaw(0), cmd);
        try std.testing.expectEqual(@as(u64, 1), counts.set_text);
        try std.testing.expectEqual(@as(?[]const u8, null), host.storageValue(.local, "cart"));
        try std.testing.expect(!std.mem.eql(u8, updated_storage_text, host.dom_elements.items[5].text.?));
    }

    {
        const cmd = testDocumentTitleCmd(&roc_host, "Ops ready");
        retainTestCmd(cmd);
        defer releaseTestCmd(&roc_host, cmd);
        defer releaseTestCmd(&roc_host, cmd);
        try std.testing.expectEqual(@as(u64, 0), host.engine.runCommand(&host, &roc_host, ids.ScopeId.fromRaw(0), cmd).total);
        try std.testing.expectEqualStrings("Ops ready", host.currentDocumentTitle());
    }

    {
        const cmd = testDocumentTitleCmd(&roc_host, "Ops steady");
        retainTestCmd(cmd);
        defer releaseTestCmd(&roc_host, cmd);
        defer releaseTestCmd(&roc_host, cmd);
        _ = host.engine.runCommand(&host, &roc_host, ids.ScopeId.fromRaw(0), cmd);
        try std.testing.expectEqualStrings("Ops steady", host.currentDocumentTitle());
    }
}

test "signals host interns scopes and node identities from explicit paths" {
    test_erased_callable_drop_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        deinitTestHostIdentity(&host);
        _ = host.gpa.deinit();
    }

    const root = host.internRootScope();
    try std.testing.expectEqual(ids.root_scope, root);
    try std.testing.expectEqual(root, host.internRootScope());

    const true_branch = host.internWhenBranchScope(root, ids.SiteOrdinal.fromRaw(2), .true_branch);
    try std.testing.expectEqual(true_branch, host.internWhenBranchScope(root, ids.SiteOrdinal.fromRaw(2), .true_branch));

    const false_branch = host.internWhenBranchScope(root, ids.SiteOrdinal.fromRaw(2), .false_branch);
    try std.testing.expect(false_branch != true_branch);

    const nested_true_branch = host.internWhenBranchScope(true_branch, ids.SiteOrdinal.fromRaw(2), .true_branch);
    try std.testing.expect(nested_true_branch != true_branch);

    const key_cap = testHostValueCapability(&roc_host);
    defer key_cap.decref(&roc_host);

    const initial_keys = [_]HostValue{ testHostValueI64(10), testHostValueI64(11) };
    const initial_rows = syncTestEachRowScopes(&host, &roc_host, root, 7, &initial_keys, &initial_keys, key_cap, key_cap);
    defer freeKeyedRowDiff(&host, initial_rows);
    const row_a = initial_rows.scope_ids[0];
    const row_b = initial_rows.scope_ids[1];
    try std.testing.expect(row_b != row_a);

    const same_keys = [_]HostValue{testHostValueI64(10)};
    const same_rows = syncTestEachRowScopes(&host, &roc_host, root, 7, &same_keys, &same_keys, key_cap, key_cap);
    defer freeKeyedRowDiff(&host, same_rows);
    try std.testing.expectEqual(row_a, same_rows.scope_ids[0]);

    const other_site_keys = [_]HostValue{testHostValueI64(10)};
    const other_site_rows = syncTestEachRowScopes(&host, &roc_host, root, 8, &other_site_keys, &other_site_keys, key_cap, key_cap);
    defer freeKeyedRowDiff(&host, other_site_rows);
    const same_key_other_site = other_site_rows.scope_ids[0];
    try std.testing.expect(same_key_other_site != row_a);

    const root_state = host.internNodeIdentity(root, ids.SiteOrdinal.fromRaw(0));
    try std.testing.expectEqual(root_state, host.internNodeIdentity(root, ids.SiteOrdinal.fromRaw(0)));

    const row_state = host.internNodeIdentity(row_a, ids.SiteOrdinal.fromRaw(0));
    try std.testing.expect(row_state != root_state);

    const row_next_state = host.internNodeIdentity(row_a, ids.SiteOrdinal.fromRaw(1));
    try std.testing.expect(row_next_state != row_state);
}

test "signals host disposal retires scope subtree identities" {
    test_erased_callable_drop_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        deinitTestHostIdentity(&host);
        _ = host.gpa.deinit();
    }

    const key_cap = testHostValueCapability(&roc_host);
    defer key_cap.decref(&roc_host);

    const root = host.internRootScope();
    const row = createTestEachRowScope(&host, &roc_host, root, 3, testHostValueI64(10), testHostValueI64(10), key_cap, key_cap);
    const branch = host.internWhenBranchScope(row, ids.SiteOrdinal.fromRaw(4), .true_branch);
    const row_state = host.internNodeIdentity(row, ids.SiteOrdinal.fromRaw(0));
    const branch_state = host.internNodeIdentity(branch, ids.SiteOrdinal.fromRaw(0));

    host.disposeScopeSubtree(&roc_host, row);
    try std.testing.expectEqual(@as(u64, 2), host.engine.pending_roc_metrics.scopes_disposed);
    try std.testing.expect(!host.engine.scopes.items[row.index()].lifecycle.isActive());
    try std.testing.expect(!host.engine.scopes.items[branch.index()].lifecycle.isActive());
    try std.testing.expect(!host.engine.node_identities.items[row_state.index()].lifecycle.isActive());
    try std.testing.expect(!host.engine.node_identities.items[branch_state.index()].lifecycle.isActive());

    const recreated_row = createTestEachRowScope(&host, &roc_host, root, 3, testHostValueI64(10), testHostValueI64(10), key_cap, key_cap);
    try std.testing.expect(row != recreated_row);

    const recreated_state = host.internNodeIdentity(recreated_row, ids.SiteOrdinal.fromRaw(0));
    try std.testing.expect(row_state != recreated_state);
}

test "signals host patches dirty leaf sinks without descriptor rebuild" {
    test_erased_callable_drop_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    const state_token = newTestBinderToken(&roc_host);
    const state_cap = testHostValueCapability(&roc_host);
    const root = testNodeStateWithTokenAndInitialCapability(
        &roc_host,
        state_token,
        testHostValueStr(&roc_host, "first"),
        testNodeTextSignalWithCapability(&roc_host, testNodeRefExpr(state_token), state_cap),
        state_cap,
    );
    defer root.decref(&roc_host);

    var stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
    const initial_counts = applyNodeDescriptorStream(&host, &roc_host, &stream);
    host.engine.active_stream = stream;

    try std.testing.expectEqual(@as(u64, 1), initial_counts.reset_dom);
    try std.testing.expectEqual(@as(u64, 1), initial_counts.set_text);
    try std.testing.expectEqual(@as(usize, 2), host.dom_elements.items.len);
    try std.testing.expectEqualStrings("first", host.dom_elements.items[1].text.?);

    const state_id = host.engine.active_stream.scope_sites.items[0].node_id;
    const state_index = host.engine.stateIndexByNodeId(state_id.raw()) orelse unreachable;
    testDropHostValue(&roc_host, host.engine.states.items[state_index].activePayload().cell.value);
    host.engine.states.items[state_index].activePayload().cell.value = testHostValueStr(&roc_host, "second");
    host.engine.states.items[state_index].activePayload().version += 1;

    const dirty_source_node_ids = [_]u64{state_id.raw()};
    const dirty_generation = host.nextDirtySignalGeneration();
    const changed_record_ids = propagateDirtyActiveSignals(&host, &roc_host, host.hostAllocator(), &dirty_source_node_ids, dirty_generation);
    const dirty_structural_signals = collectDirtyStructuralSignals(&host, &roc_host, host.hostAllocator(), &dirty_source_node_ids, changed_record_ids, dirty_generation);
    defer host.hostAllocator().free(dirty_structural_signals);
    try std.testing.expectEqual(@as(usize, 0), dirty_structural_signals.len);

    const patch_start = host.engine.render_metrics.patches_emitted;
    const patch_counts = applyDirtyRenderSinks(&host, &roc_host, &dirty_source_node_ids, changed_record_ids, dirty_generation);
    try std.testing.expectEqual(@as(u64, 0), patch_counts.reset_dom);
    try std.testing.expectEqual(@as(u64, 0), patch_counts.create_element);
    try std.testing.expectEqual(@as(u64, 0), patch_counts.append_child);
    try std.testing.expectEqual(@as(u64, 1), patch_counts.set_text);
    try std.testing.expectEqual(@as(u64, 1), patch_counts.total);
    try std.testing.expectEqual(patch_start + 1, host.engine.render_metrics.patches_emitted);
    try std.testing.expectEqual(@as(usize, 2), host.dom_elements.items.len);
    try std.testing.expectEqualStrings("second", host.dom_elements.items[1].text.?);

    const unchanged_generation = host.nextDirtySignalGeneration();
    const unchanged_record_ids = propagateDirtyActiveSignals(&host, &roc_host, host.hostAllocator(), &dirty_source_node_ids, unchanged_generation);
    const unchanged_counts = applyDirtyRenderSinks(&host, &roc_host, &dirty_source_node_ids, unchanged_record_ids, unchanged_generation);
    try std.testing.expectEqual(@as(u64, 0), unchanged_counts.total);
}

test "signals host prunes dirty leaf sink when retained map equality is unchanged" {
    test_erased_callable_drop_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    const state_token = newTestBinderToken(&roc_host);
    const stable_label = testNodeStableStrMapExpr(&roc_host, testNodeRefExpr(state_token));
    const root = testNodeStateWithTokenAndInitial(
        &roc_host,
        state_token,
        testHostValueI64(1),
        testNodeTextSignal(&roc_host, stable_label),
    );
    defer root.decref(&roc_host);

    var stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
    const initial_counts = applyNodeDescriptorStream(&host, &roc_host, &stream);
    host.engine.active_stream = stream;

    try std.testing.expectEqual(@as(u64, 1), initial_counts.set_text);
    try std.testing.expectEqualStrings("stable", host.dom_elements.items[1].text.?);

    const state_id = host.engine.active_stream.scope_sites.items[0].node_id;
    const state_index = host.engine.stateIndexByNodeId(state_id.raw()) orelse unreachable;
    testDropHostValue(&roc_host, host.engine.states.items[state_index].activePayload().cell.value);
    host.engine.states.items[state_index].activePayload().cell.value = testHostValueI64(2);
    host.engine.states.items[state_index].activePayload().version += 1;

    const dirty_source_node_ids = [_]u64{state_id.raw()};
    const prune_start = host.engine.pending_roc_metrics.propagation_prunes;
    const dirty_generation = host.nextDirtySignalGeneration();
    const changed_record_ids = propagateDirtyActiveSignals(&host, &roc_host, host.hostAllocator(), &dirty_source_node_ids, dirty_generation);
    const patch_counts = applyDirtyRenderSinks(&host, &roc_host, &dirty_source_node_ids, changed_record_ids, dirty_generation);

    try std.testing.expectEqual(@as(u64, 0), patch_counts.total);
    try std.testing.expectEqual(prune_start + 1, host.engine.pending_roc_metrics.propagation_prunes);
    try std.testing.expectEqualStrings("stable", host.dom_elements.items[1].text.?);
}

test "signals host evaluates shared dirty record once per batch" {
    test_erased_callable_drop_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    const state_token = newTestBinderToken(&roc_host);
    const shared_label = testNodeStableStrMapExpr(&roc_host, testNodeRefExpr(state_token));
    shared_label.incref(1);
    const children = [_]abi.Elem{
        testNodeTextSignal(&roc_host, shared_label),
        testNodeTextSignal(&roc_host, shared_label),
    };
    const root = testNodeStateWithTokenAndInitial(
        &roc_host,
        state_token,
        testHostValueI64(1),
        testElement(&roc_host, &children),
    );
    defer root.decref(&roc_host);

    var stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
    const initial_counts = applyNodeDescriptorStream(&host, &roc_host, &stream);
    host.engine.active_stream = stream;

    try std.testing.expectEqual(@as(u64, 2), initial_counts.set_text);
    try std.testing.expectEqualStrings("stable", host.dom_elements.items[2].text.?);
    try std.testing.expectEqualStrings("stable", host.dom_elements.items[3].text.?);
    try std.testing.expect(host.engine.active_stream.signal_text_nodes.items[0].signal.record == host.engine.active_stream.signal_text_nodes.items[1].signal.record);
    try std.testing.expectEqual(@as(usize, 2), host.engine.active_signal_graph.items.len);

    const shared_record = host.engine.active_stream.signal_text_nodes.items[0].signal.record;
    const shared_record_id = host.requireActiveSignalRecordId(shared_record);
    const source_record = switch (shared_record.payload) {
        .map => |payload| payload.input,
        else => failHost("shared label test expected a map signal record"),
    };
    const source_record_id = host.requireActiveSignalRecordId(source_record);
    try std.testing.expectEqual(@as(u64, 0), host.activeSignalRank(source_record_id));
    try std.testing.expectEqual(@as(u64, 1), host.activeSignalRank(shared_record_id));
    const expected_dependents = [_]u64{shared_record_id};
    try std.testing.expectEqualSlices(u64, &expected_dependents, host.dependentActiveSignalRecordIds(source_record_id));

    const state_id = host.engine.active_stream.scope_sites.items[0].node_id;
    try std.testing.expectEqual(state_id.index() + 1, host.engine.active_source_signal_routes.items.len);
    const expected_source_routes = [_]u64{source_record_id};
    try std.testing.expectEqualSlices(u64, &expected_source_routes, host.engine.active_source_signal_routes.items[state_id.index()].items);
    try std.testing.expectEqual(@as(usize, 2), host.engine.active_text_signal_routes.items[@intCast(shared_record_id)].items.len);

    const state_index = host.engine.stateIndexByNodeId(state_id.raw()) orelse unreachable;
    testDropHostValue(&roc_host, host.engine.states.items[state_index].activePayload().cell.value);
    host.engine.states.items[state_index].activePayload().cell.value = testHostValueI64(2);
    host.engine.states.items[state_index].activePayload().version += 1;

    const dirty_source_node_ids = [_]u64{state_id.raw()};
    const prune_start = host.engine.pending_roc_metrics.propagation_prunes;
    const derived_start = host.engine.pending_roc_metrics.derived_calls_into_roc;
    const dirty_generation = host.nextDirtySignalGeneration();
    const changed_record_ids = propagateDirtyActiveSignals(&host, &roc_host, host.hostAllocator(), &dirty_source_node_ids, dirty_generation);
    const patch_counts = applyDirtyRenderSinks(&host, &roc_host, &dirty_source_node_ids, changed_record_ids, dirty_generation);

    try std.testing.expectEqual(@as(u64, 0), patch_counts.total);
    try std.testing.expectEqual(prune_start + 1, host.engine.pending_roc_metrics.propagation_prunes);
    try std.testing.expectEqual(derived_start + 1, host.engine.pending_roc_metrics.derived_calls_into_roc);
}

test "signals host skips parent transform when dirty child output is unchanged" {
    test_erased_callable_drop_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    const state_token = newTestBinderToken(&roc_host);
    const stable_count = testNodeStableI64MapExpr(&roc_host, testNodeRefExpr(state_token), 42);
    const parent_label = testNodeStableStrMapExpr(&roc_host, stable_count);
    const root = testNodeStateWithTokenAndInitial(
        &roc_host,
        state_token,
        testHostValueI64(1),
        testNodeTextSignal(&roc_host, parent_label),
    );
    defer root.decref(&roc_host);

    var stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
    const initial_counts = applyNodeDescriptorStream(&host, &roc_host, &stream);
    host.engine.active_stream = stream;

    try std.testing.expectEqual(@as(u64, 1), initial_counts.set_text);
    try std.testing.expectEqualStrings("stable", host.dom_elements.items[1].text.?);

    const state_id = host.engine.active_stream.scope_sites.items[0].node_id;
    const state_index = host.engine.stateIndexByNodeId(state_id.raw()) orelse unreachable;
    testDropHostValue(&roc_host, host.engine.states.items[state_index].activePayload().cell.value);
    host.engine.states.items[state_index].activePayload().cell.value = testHostValueI64(2);
    host.engine.states.items[state_index].activePayload().version += 1;

    const dirty_source_node_ids = [_]u64{state_id.raw()};
    const prune_start = host.engine.pending_roc_metrics.propagation_prunes;
    const derived_start = host.engine.pending_roc_metrics.derived_calls_into_roc;
    const dirty_generation = host.nextDirtySignalGeneration();
    const changed_record_ids = propagateDirtyActiveSignals(&host, &roc_host, host.hostAllocator(), &dirty_source_node_ids, dirty_generation);
    const patch_counts = applyDirtyRenderSinks(&host, &roc_host, &dirty_source_node_ids, changed_record_ids, dirty_generation);

    try std.testing.expectEqual(@as(u64, 0), patch_counts.total);
    try std.testing.expectEqual(prune_start + 1, host.engine.pending_roc_metrics.propagation_prunes);
    try std.testing.expectEqual(derived_start + 1, host.engine.pending_roc_metrics.derived_calls_into_roc);
    try std.testing.expectEqualStrings("stable", host.dom_elements.items[1].text.?);
}

test "signals host prunes dirty combine output through cache-owned equality" {
    test_erased_callable_drop_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    const initial_items = [_]HostValue{ testHostValueI64(1), testHostValueI64(2) };
    const combine = testNodeCombineExpr(&roc_host, &.{});
    var stream: HostNodeDescriptorStream = .{};
    defer stream.deinit(host.hostAllocator(), &host, &roc_host, &host.engine.pending_roc_metrics);
    var binding = host.bindNodeSignal(host.hostAllocator(), &stream, combine, &.{});
    defer binding.deinit(host.hostAllocator(), &host, &roc_host, &host.engine.pending_roc_metrics);
    var cache: HostSignalCacheSlot = .absent;
    cache.replace(&host, &roc_host, &host.engine.pending_roc_metrics, testHostValueI64List(&roc_host, &initial_items), hostSignalBindingCapability(&host, &binding));
    defer cache.deinit(&host, &roc_host, &host.engine.pending_roc_metrics);
    combine.decref(&roc_host);

    const dirty_items = [_]HostValue{ testHostValueI64(3), testHostValueI64(4) };
    const prune_start = host.engine.pending_roc_metrics.propagation_prunes;
    try std.testing.expect(!updateDirtySignalCache(&host, &roc_host, &cache, testHostValueI64List(&roc_host, &dirty_items)));
    try std.testing.expectEqual(prune_start + 1, host.engine.pending_roc_metrics.propagation_prunes);
}

test "signals host evaluates map2 through bind and dirty propagation" {
    test_erased_callable_drop_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    const left_token = newTestBinderToken(&roc_host);
    const right_token = newTestBinderToken(&roc_host);
    const summed = testNodeMap2Expr(&roc_host, testNodeRefExpr(left_token), testNodeRefExpr(right_token));
    const inner_state = testNodeStateWithTokenAndInitial(&roc_host, right_token, testHostValueI64(20), testNodeI64TextSignal(&roc_host, summed));
    const root = testNodeStateWithTokenAndInitial(&roc_host, left_token, testHostValueI64(10), inner_state);
    defer root.decref(&roc_host);

    var stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
    const initial_counts = applyNodeDescriptorStream(&host, &roc_host, &stream);
    host.engine.active_stream = stream;

    try std.testing.expectEqual(@as(u64, 1), initial_counts.set_text);
    try std.testing.expectEqualStrings("30", host.dom_elements.items[1].text.?);
    try std.testing.expectEqual(@as(std.meta.Tag(HostSignalRecordPayload), .map2), std.meta.activeTag(host.engine.active_stream.signal_text_nodes.items[0].signal.record.payload));

    const left_state_id = host.engine.active_stream.scope_sites.items[0].node_id;
    const right_state_id = host.engine.active_stream.scope_sites.items[1].node_id;
    try std.testing.expect(host.updateStateValue(&roc_host, left_state_id, testHostValueI64(11)));

    const dirty_source_node_ids = [_]u64{left_state_id.raw()};
    const derived_start = host.engine.pending_roc_metrics.derived_calls_into_roc;
    const dirty_generation = host.nextDirtySignalGeneration();
    const changed_record_ids = propagateDirtyActiveSignals(&host, &roc_host, host.hostAllocator(), &dirty_source_node_ids, dirty_generation);
    const patch_counts = applyDirtyRenderSinks(&host, &roc_host, &dirty_source_node_ids, changed_record_ids, dirty_generation);

    try std.testing.expectEqual(@as(u64, 1), patch_counts.set_text);
    try std.testing.expectEqualStrings("31", host.dom_elements.items[1].text.?);
    try std.testing.expectEqual(derived_start + 1, host.engine.pending_roc_metrics.derived_calls_into_roc);

    try std.testing.expect(host.updateStateValue(&roc_host, right_state_id, testHostValueI64(21)));
    const right_dirty_source_node_ids = [_]u64{right_state_id.raw()};
    const right_generation = host.nextDirtySignalGeneration();
    const right_changed_record_ids = propagateDirtyActiveSignals(&host, &roc_host, host.hostAllocator(), &right_dirty_source_node_ids, right_generation);
    const right_counts = applyDirtyRenderSinks(&host, &roc_host, &right_dirty_source_node_ids, right_changed_record_ids, right_generation);

    try std.testing.expectEqual(@as(u64, 1), right_counts.set_text);
    try std.testing.expectEqualStrings("32", host.dom_elements.items[1].text.?);
}

test "signals host marks dirty structural sources for structural patching" {
    test_erased_callable_drop_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    const state_token = newTestBinderToken(&roc_host);
    const state_cap = testHostValueCapability(&roc_host);
    const when_elem: abi.Elem = .{
        .payload = .{
            .when = .{
                .condition = boxTestNodeSignalExpr(&roc_host, testNodeRefExpr(state_token)),
                .read = testBoolReadHandle(&roc_host, state_cap),
                .when_false = boxTestElem(&roc_host, testNodeText(&roc_host, "false branch")),
                .when_true = boxTestElem(&roc_host, testNodeText(&roc_host, "true branch")),
            },
        },
        .tag = .When,
    };
    const root = testNodeStateWithTokenAndInitialCapability(&roc_host, state_token, testHostValueBool(true), when_elem, state_cap);
    defer root.decref(&roc_host);

    var stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
    const initial_counts = applyNodeDescriptorStream(&host, &roc_host, &stream);
    host.engine.active_stream = stream;

    try std.testing.expectEqual(@as(u64, 1), initial_counts.reset_dom);
    const state_id = host.engine.active_stream.scope_sites.items[0].node_id;
    const state_index = host.engine.stateIndexByNodeId(state_id.raw()) orelse unreachable;
    testDropHostValue(&roc_host, host.engine.states.items[state_index].activePayload().cell.value);
    host.engine.states.items[state_index].activePayload().cell.value = testHostValueBool(false);
    host.engine.states.items[state_index].activePayload().version += 1;
    const dirty_source_node_ids = [_]u64{state_id.raw()};
    const dirty_generation = host.nextDirtySignalGeneration();
    const changed_record_ids = propagateDirtyActiveSignals(&host, &roc_host, host.hostAllocator(), &dirty_source_node_ids, dirty_generation);
    const dirty_structural_signals = collectDirtyStructuralSignals(&host, &roc_host, host.hostAllocator(), &dirty_source_node_ids, changed_record_ids, dirty_generation);
    defer host.hostAllocator().free(dirty_structural_signals);
    try std.testing.expectEqual(@as(usize, 1), dirty_structural_signals.len);
    try std.testing.expectEqual(HostActiveStructuralSignalKind.when, dirty_structural_signals[0].kind);
    try std.testing.expectEqual(HostScopeBranch.false_branch, dirty_structural_signals[0].branch.?);

    const patch_counts = applyDirtyWhenStructuralSignals(&host, &roc_host, &dirty_source_node_ids, dirty_generation, dirty_structural_signals);

    try std.testing.expectEqual(@as(u64, 0), patch_counts.reset_dom);
    try std.testing.expectEqual(@as(u64, 1), patch_counts.create_element);
    try std.testing.expectEqual(@as(u64, 1), patch_counts.append_child);
    try std.testing.expectEqual(@as(u64, 1), patch_counts.remove_node);
    try std.testing.expectEqual(@as(u64, 1), patch_counts.set_text);
    try std.testing.expectEqual(@as(u64, 4), patch_counts.total);
    try std.testing.expect(activeTextElementId(&host, "true branch") == null);
    try std.testing.expect(activeTextElementId(&host, "false branch") != null);
}

test "signals host deferred on_change navigation preserves small string payloads" {
    test_erased_callable_drop_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    host.setCurrentLocation(.{ .path = "/start", .query = "", .hash = "" });

    const state_token = newTestBinderToken(&roc_host);
    const state_cap = testHostValueCapability(&roc_host);
    const children = [_]abi.Elem{
        testNodeOnChange(&roc_host, testNodeRefExpr(state_token), testLocationCmdCallableFor(&roc_host, .PushState, "/", "", "")),
        testNodeText(&roc_host, "ready"),
    };
    const root = testNodeStateWithTokenAndInitialCapability(&roc_host, state_token, testHostValueBool(false), testElement(&roc_host, &children), state_cap);
    defer root.decref(&roc_host);

    var stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
    _ = applyNodeDescriptorStream(&host, &roc_host, &stream);
    host.engine.active_stream = stream;

    const state_id = host.engine.active_stream.scope_sites.items[0].node_id;
    try std.testing.expect(host.updateStateValue(&roc_host, state_id, testHostValueBool(true)));

    const dirty_source_node_ids = [_]u64{state_id.raw()};
    const dirty_generation = host.nextDirtySignalGeneration();
    const changed_record_ids = propagateDirtyActiveSignals(&host, &roc_host, host.hostAllocator(), &dirty_source_node_ids, dirty_generation);
    _ = host.engine.applyDirtySignalBatch(&host, &roc_host, &dirty_source_node_ids, changed_record_ids, dirty_generation);

    try std.testing.expectEqualStrings("/", host.currentLocation().path);
}

test "signals host applies the final structural branch after deferred location redirects" {
    test_erased_callable_drop_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    host.setCurrentLocation(.{ .path = "/services/workers", .query = "", .hash = "" });

    const is_missing = testNodeLocationPathEqualsSourceExpr(&roc_host, "/services/missing");
    const is_detail = testNodeLocationPathEqualsSourceExpr(&roc_host, "/services/workers");
    const is_detail_cap = testNodeSignalExprCapabilityOrPanic(is_detail);
    const page = abi.Elem{
        .payload = .{
            .when = .{
                .condition = boxTestNodeSignalExpr(&roc_host, is_detail),
                .read = testBoolReadHandle(&roc_host, is_detail_cap),
                .when_false = boxTestElem(&roc_host, testNodeText(&roc_host, "overview branch")),
                .when_true = boxTestElem(&roc_host, testNodeText(&roc_host, "detail branch")),
            },
        },
        .tag = .When,
    };
    const children = [_]abi.Elem{
        testNodeOnChange(&roc_host, is_missing, testLocationCmdCallableFor(&roc_host, .ReplaceState, "/", "", "")),
        page,
    };
    const root = testElement(&roc_host, &children);
    defer root.decref(&roc_host);

    var stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
    _ = applyNodeDescriptorStream(&host, &roc_host, &stream);
    host.engine.active_stream = stream;

    try std.testing.expect(activeTextElementId(&host, "detail branch") != null);
    try std.testing.expect(activeTextElementId(&host, "overview branch") == null);

    host.pushCurrentLocation(.{ .path = "/services/missing", .query = "", .hash = "" });
    _ = host.engine.dispatchCurrentLocationSources(&host, &roc_host);

    try std.testing.expectEqualStrings("/", host.currentLocation().path);
    try std.testing.expect(activeTextElementId(&host, "detail branch") == null);
    try std.testing.expect(activeTextElementId(&host, "overview branch") != null);
}

test "location-driven when source transaction sweeps host OOM and retries without publication" {
    const Runner = struct {
        fn run(failure_number: ?usize) !usize {
            test_erased_callable_drop_count = 0;
            var host = HostEnv.init();
            var roc_host = makeSignalsRocHost(&host);
            host.engine.roc_host = &roc_host;
            defer {
                host.deinit();
                _ = host.gpa.deinit();
            }
            host.setCurrentLocation(.{ .path = "/detail", .query = "", .hash = "" });
            const condition = testNodeLocationPathEqualsSourceExpr(&roc_host, "/detail");
            const condition_cap = testNodeSignalExprCapabilityOrPanic(condition);
            const root = abi.Elem{ .payload = .{ .when = .{
                .condition = boxTestNodeSignalExpr(&roc_host, condition),
                .read = testBoolReadHandle(&roc_host, condition_cap),
                .when_false = boxTestElem(&roc_host, testNodeText(&roc_host, "overview branch")),
                .when_true = boxTestElem(&roc_host, testNodeText(&roc_host, "detail branch")),
            } }, .tag = .When };
            defer root.decref(&roc_host);
            var stream: HostNodeDescriptorStream = .{};
            host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
            _ = applyNodeDescriptorStream(&host, &roc_host, &stream);
            host.engine.active_stream = stream;
            host.pushCurrentLocation(.{ .path = "/", .query = "", .hash = "" });

            const generation_before = host.engine.dirty_signal_generation;
            const graph_len_before = host.engine.active_signal_graph.items.len;
            const scope_len_before = host.engine.scopes.items.len;
            const render_len_before = host.engine.active_stream.render_nodes.items.len;
            const dom_len_before = host.dom_elements.items.len;
            const root_children_before = try std.testing.allocator.dupe(ids.ElemId, host.engine.render_cache.nodes.items[1].children.items);
            defer std.testing.allocator.free(root_children_before);
            var location_record: ?*HostSignalRecord = null;
            for (host.engine.active_signal_graph.items) |node| if (node.record.locationSource() != null) {
                location_record = node.record;
                break;
            };
            const source_value_before = location_record.?.locationSource().?.cached_value.present.value;

            var fault = FaultAllocator.init(host.gpa.allocator());
            fault.configure(failure_number);
            host.engine_allocator_override = fault.allocator();
            const result = host.engine.tryDispatchCurrentLocationSources(&host, &roc_host);
            const attempts = fault.attempts;
            if (failure_number != null) {
                try std.testing.expectError(error.OutOfMemory, result);
                try std.testing.expectEqual(@as(usize, 1), fault.induced_failures);
                try std.testing.expectEqual(generation_before, host.engine.dirty_signal_generation);
                try std.testing.expectEqual(graph_len_before, host.engine.active_signal_graph.items.len);
                try std.testing.expectEqual(scope_len_before, host.engine.scopes.items.len);
                try std.testing.expectEqual(render_len_before, host.engine.active_stream.render_nodes.items.len);
                try std.testing.expectEqual(dom_len_before, host.dom_elements.items.len);
                try std.testing.expectEqualSlices(ids.ElemId, root_children_before, host.engine.render_cache.nodes.items[1].children.items);
                try std.testing.expectEqual(source_value_before, location_record.?.locationSource().?.cached_value.present.value);
                try std.testing.expect(activeTextElementId(&host, "detail branch") != null);
                try std.testing.expect(activeTextElementId(&host, "overview branch") == null);

                fault.configure(null);
                _ = try host.engine.tryDispatchCurrentLocationSources(&host, &roc_host);
            } else {
                _ = try result;
            }
            try std.testing.expect(activeTextElementId(&host, "detail branch") == null);
            try std.testing.expect(activeTextElementId(&host, "overview branch") != null);
            return attempts;
        }
    };

    const attempts = try Runner.run(null);
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| _ = try Runner.run(failure_number);
}

test "list source each transaction sweeps host OOM and retries without publication" {
    const Runner = struct {
        fn run(failure_number: ?usize) !usize {
            test_erased_callable_drop_count = 0;
            test_row_elem_call_count = 0;
            var host = HostEnv.init();
            var roc_host = makeSignalsRocHost(&host);
            host.engine.roc_host = &roc_host;
            defer {
                host.deinit();
                _ = host.gpa.deinit();
            }

            const initial_items = [_]HostValue{ testHostValueI64(1), testHostValueI64(2), testHostValueI64(3) };
            const source = testNodeIntervalListSourceExpr(&roc_host, 100, testHostValueI64List(&roc_host, &initial_items));
            const root = testElement(&roc_host, &.{testNodeEachWithSignalAndRow(&roc_host, source, &testStatefulRowElemCallable)});
            defer root.decref(&roc_host);
            var stream: HostNodeDescriptorStream = .{};
            host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
            _ = applyNodeDescriptorStream(&host, &roc_host, &stream);
            host.engine.active_stream = stream;

            const record = host.engine.activeIntervalRecordByPeriod(100).?;
            const each_site = for (host.engine.active_stream.scope_sites.items) |site| {
                if (site.kind == .each) break site;
            } else return error.TestUnexpectedResult;
            const each_cache_before = host.engine.active_stream.eaches.items[0].cached_value.present.value;
            const source_cache_before = record.requireIntervalSource().cached_value.present.value;
            const generation_before = host.engine.dirty_signal_generation;
            const graph_len_before = host.engine.active_signal_graph.items.len;
            const scope_len_before = host.engine.scopes.items.len;
            const render_len_before = host.engine.active_stream.render_nodes.items.len;
            const dom_len_before = host.dom_elements.items.len;
            const root_children_before = try std.testing.allocator.dupe(ids.ElemId, host.engine.render_cache.nodes.items[1].children.items);
            defer std.testing.allocator.free(root_children_before);
            const row_scopes_before = try host.engine.activeEachRowScopes(std.testing.allocator, each_site.scope_id, each_site.ordinal);
            defer std.testing.allocator.free(row_scopes_before);
            const allocations_before = host.roc_allocations.snapshot();

            const next_items = [_]HostValue{ testHostValueI64(2), testHostValueI64(3), testHostValueI64(4) };
            const next = testHostValueI64List(&roc_host, &next_items);
            var fault = FaultAllocator.init(host.gpa.allocator());
            fault.configure(failure_number);
            host.engine_allocator_override = fault.allocator();
            const result = host.engine.tryDispatchEffectSourceValue(&host, &roc_host, record, next);
            const attempts = fault.attempts;
            if (failure_number != null) {
                try std.testing.expectError(error.OutOfMemory, result);
                try std.testing.expectEqual(@as(usize, 1), fault.induced_failures);
                try std.testing.expectEqual(generation_before, host.engine.dirty_signal_generation);
                try std.testing.expectEqual(graph_len_before, host.engine.active_signal_graph.items.len);
                try std.testing.expectEqual(scope_len_before, host.engine.scopes.items.len);
                try std.testing.expectEqual(render_len_before, host.engine.active_stream.render_nodes.items.len);
                try std.testing.expectEqual(dom_len_before, host.dom_elements.items.len);
                try std.testing.expectEqualSlices(ids.ElemId, root_children_before, host.engine.render_cache.nodes.items[1].children.items);
                const row_scopes_after = try host.engine.activeEachRowScopes(std.testing.allocator, each_site.scope_id, each_site.ordinal);
                defer std.testing.allocator.free(row_scopes_after);
                try std.testing.expectEqualSlices(ids.ScopeId, row_scopes_before, row_scopes_after);
                try std.testing.expectEqual(source_cache_before, record.requireIntervalSource().cached_value.present.value);
                try std.testing.expectEqual(each_cache_before, host.engine.active_stream.eaches.items[0].cached_value.present.value);
                try std.testing.expect(activeTextElementId(&host, "row-1-1") != null);
                try std.testing.expect(activeTextElementId(&host, "row-4-4") == null);
                try std.testing.expectEqual(@as(usize, 0), host.roc_allocations.liveCountSince(allocations_before));

                fault.configure(null);
                const retry_items = [_]HostValue{ testHostValueI64(2), testHostValueI64(3), testHostValueI64(4) };
                _ = try host.engine.tryDispatchEffectSourceValue(&host, &roc_host, record, testHostValueI64List(&roc_host, &retry_items));
            } else {
                _ = try result;
            }
            try std.testing.expect(activeTextElementId(&host, "row-1-1") == null);
            try std.testing.expect(activeTextElementId(&host, "row-2-2") != null);
            try std.testing.expect(activeTextElementId(&host, "row-3-3") != null);
            try std.testing.expect(activeTextElementId(&host, "row-4-4") != null);
            return attempts;
        }
    };

    const attempts = try Runner.run(null);
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| _ = try Runner.run(failure_number);
}

test "one state transaction updates two each sites atomically through production" {
    const Runner = struct {
        fn run(failure_number: ?usize) !usize {
            test_erased_callable_drop_count = 0;
            test_row_elem_call_count = 0;
            var host = HostEnv.init();
            var roc_host = makeSignalsRocHost(&host);
            host.engine.roc_host = &roc_host;
            defer {
                host.deinit();
                _ = host.gpa.deinit();
            }

            const state_token = newTestBinderToken(&roc_host);
            const state_cap = testHostValueCapability(&roc_host);
            const first_each = testNodeEachWithSignalCapabilityAndRow(&roc_host, testNodeRefExpr(state_token), state_cap, &testStatefulRowElemCallable);
            const second_each = testNodeEachWithSignalCapabilityAndRow(&roc_host, testNodeRefExpr(state_token), state_cap, &testStatefulRowElemCallable);
            const section = testElementWith(&roc_host, "section", &.{}, &.{ first_each, testNodeText(&roc_host, "between-each-sites"), second_each });
            const initial_items = [_]HostValue{ testHostValueI64(1), testHostValueI64(2) };
            const root = testNodeStateWithTokenAndInitialCapability(&roc_host, state_token, testHostValueI64List(&roc_host, &initial_items), section, state_cap);
            defer root.decref(&roc_host);
            var stream: HostNodeDescriptorStream = .{};
            host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
            _ = applyNodeDescriptorStream(&host, &roc_host, &stream);
            host.engine.active_stream = stream;

            const state_id = host.engine.active_stream.scope_sites.items[0].node_id;
            const state_index = host.engine.stateIndexByNodeId(state_id.raw()).?;
            var each_sites: [2]engine.HostNodeScopeSiteDesc = undefined;
            var each_write: usize = 0;
            for (host.engine.active_stream.scope_sites.items) |site| if (site.kind == .each) {
                each_sites[each_write] = site;
                each_write += 1;
            };
            try std.testing.expectEqual(@as(usize, 2), each_write);
            const first_rows_before = try host.engine.activeEachRowScopes(std.testing.allocator, each_sites[0].scope_id, each_sites[0].ordinal);
            defer std.testing.allocator.free(first_rows_before);
            const second_rows_before = try host.engine.activeEachRowScopes(std.testing.allocator, each_sites[1].scope_id, each_sites[1].ordinal);
            defer std.testing.allocator.free(second_rows_before);
            const generation_before = host.engine.dirty_signal_generation;
            const graph_len_before = host.engine.active_signal_graph.items.len;
            const scope_len_before = host.engine.scopes.items.len;
            const render_len_before = host.engine.active_stream.render_nodes.items.len;
            const dom_len_before = host.dom_elements.items.len;
            const state_value_before = host.engine.states.items[state_index].activePayloadConst().cell.value;
            const rows_reused_before = host.engine.pending_roc_metrics.rows_reused;
            const rows_created_before = host.engine.pending_roc_metrics.rows_created;
            const rows_removed_before = host.engine.pending_roc_metrics.rows_removed;
            const root_children_before = try std.testing.allocator.dupe(ids.ElemId, host.engine.render_cache.nodes.items[1].children.items);
            defer std.testing.allocator.free(root_children_before);
            const allocations_before = host.roc_allocations.snapshot();

            const next_items = [_]HostValue{ testHostValueI64(2), testHostValueI64(3) };
            var fault = FaultAllocator.init(host.gpa.allocator());
            fault.configure(failure_number);
            host.engine_allocator_override = fault.allocator();
            const result = host.engine.tryDispatchStateValue(&host, &roc_host, state_id.raw(), testHostValueI64List(&roc_host, &next_items), state_cap);
            const attempts = fault.attempts;
            if (failure_number != null) {
                try std.testing.expectError(error.OutOfMemory, result);
                try std.testing.expectEqual(generation_before, host.engine.dirty_signal_generation);
                try std.testing.expectEqual(graph_len_before, host.engine.active_signal_graph.items.len);
                try std.testing.expectEqual(scope_len_before, host.engine.scopes.items.len);
                try std.testing.expectEqual(render_len_before, host.engine.active_stream.render_nodes.items.len);
                try std.testing.expectEqual(dom_len_before, host.dom_elements.items.len);
                try std.testing.expectEqual(state_value_before, host.engine.states.items[state_index].activePayloadConst().cell.value);
                try std.testing.expectEqualSlices(ids.ElemId, root_children_before, host.engine.render_cache.nodes.items[1].children.items);
                const first_after = try host.engine.activeEachRowScopes(std.testing.allocator, each_sites[0].scope_id, each_sites[0].ordinal);
                defer std.testing.allocator.free(first_after);
                const second_after = try host.engine.activeEachRowScopes(std.testing.allocator, each_sites[1].scope_id, each_sites[1].ordinal);
                defer std.testing.allocator.free(second_after);
                try std.testing.expectEqualSlices(ids.ScopeId, first_rows_before, first_after);
                try std.testing.expectEqualSlices(ids.ScopeId, second_rows_before, second_after);
                try std.testing.expectEqual(@as(usize, 0), host.roc_allocations.liveCountSince(allocations_before));
                fault.configure(null);
                const retry_items = [_]HostValue{ testHostValueI64(2), testHostValueI64(3) };
                _ = try host.engine.tryDispatchStateValue(&host, &roc_host, state_id.raw(), testHostValueI64List(&roc_host, &retry_items), state_cap);
            } else _ = try result;

            const first_rows = try host.engine.activeEachRowScopes(std.testing.allocator, each_sites[0].scope_id, each_sites[0].ordinal);
            defer std.testing.allocator.free(first_rows);
            const second_rows = try host.engine.activeEachRowScopes(std.testing.allocator, each_sites[1].scope_id, each_sites[1].ordinal);
            defer std.testing.allocator.free(second_rows);
            try std.testing.expectEqual(@as(usize, 2), first_rows.len);
            try std.testing.expectEqual(@as(usize, 2), second_rows.len);
            try std.testing.expect(first_rows[0] != second_rows[0]);
            try std.testing.expect(activeTextElementId(&host, "row-1-1") == null);
            try std.testing.expect(activeTextElementId(&host, "row-2-2") != null);
            try std.testing.expect(activeTextElementId(&host, "row-3-3") != null);
            try std.testing.expectEqual(@as(u64, 2), host.engine.pending_roc_metrics.rows_reused - rows_reused_before);
            try std.testing.expectEqual(@as(u64, 2), host.engine.pending_roc_metrics.rows_created - rows_created_before);
            try std.testing.expectEqual(@as(u64, 2), host.engine.pending_roc_metrics.rows_removed - rows_removed_before);
            return attempts;
        }
    };

    const attempts = try Runner.run(null);
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| _ = try Runner.run(failure_number);
}

test "one state transaction updates two each sites under distinct parents through production" {
    // Two live each sites under *different* render parents make the composite
    // downstream suppress more than one parent. Suppressing only a lone parent
    // let the structural pass and `prepareFinalRenderTopology` both register
    // the same parent on one splice, which is a duplicate parent intent rather
    // than a resource limit.
    const Runner = struct {
        fn run(failure_number: ?usize) !usize {
            test_erased_callable_drop_count = 0;
            test_row_elem_call_count = 0;
            var host = HostEnv.init();
            var roc_host = makeSignalsRocHost(&host);
            host.engine.roc_host = &roc_host;
            defer {
                host.deinit();
                _ = host.gpa.deinit();
            }

            const state_token = newTestBinderToken(&roc_host);
            const state_cap = testHostValueCapability(&roc_host);
            const first_each = testNodeEachWithSignalCapabilityAndRow(&roc_host, testNodeRefExpr(state_token), state_cap, &testStatefulRowElemCallable);
            const second_each = testNodeEachWithSignalCapabilityAndRow(&roc_host, testNodeRefExpr(state_token), state_cap, &testStatefulRowElemCallable);
            const first_column = testElementWith(&roc_host, "div", &.{}, &.{first_each});
            const second_column = testElementWith(&roc_host, "div", &.{}, &.{second_each});
            const section = testElementWith(&roc_host, "section", &.{}, &.{ first_column, testNodeText(&roc_host, "between-columns"), second_column });
            const initial_items = [_]HostValue{ testHostValueI64(1), testHostValueI64(2) };
            const root = testNodeStateWithTokenAndInitialCapability(&roc_host, state_token, testHostValueI64List(&roc_host, &initial_items), section, state_cap);
            defer root.decref(&roc_host);
            var stream: HostNodeDescriptorStream = .{};
            host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
            _ = applyNodeDescriptorStream(&host, &roc_host, &stream);
            host.engine.active_stream = stream;

            const state_id = host.engine.active_stream.scope_sites.items[0].node_id;
            const state_index = host.engine.stateIndexByNodeId(state_id.raw()).?;
            var each_sites: [2]engine.HostNodeScopeSiteDesc = undefined;
            var each_write: usize = 0;
            for (host.engine.active_stream.scope_sites.items) |site| if (site.kind == .each) {
                each_sites[each_write] = site;
                each_write += 1;
            };
            try std.testing.expectEqual(@as(usize, 2), each_write);
            // The two sites must sit under distinct parents for this to cover
            // the multi-parent suppression path at all.
            try std.testing.expect(each_sites[0].parent_elem_id != each_sites[1].parent_elem_id);

            const first_rows_before = try host.engine.activeEachRowScopes(std.testing.allocator, each_sites[0].scope_id, each_sites[0].ordinal);
            defer std.testing.allocator.free(first_rows_before);
            const second_rows_before = try host.engine.activeEachRowScopes(std.testing.allocator, each_sites[1].scope_id, each_sites[1].ordinal);
            defer std.testing.allocator.free(second_rows_before);
            const generation_before = host.engine.dirty_signal_generation;
            const graph_len_before = host.engine.active_signal_graph.items.len;
            const scope_len_before = host.engine.scopes.items.len;
            const render_len_before = host.engine.active_stream.render_nodes.items.len;
            const dom_len_before = host.dom_elements.items.len;
            const state_value_before = host.engine.states.items[state_index].activePayloadConst().cell.value;
            const first_parent_children_before = try std.testing.allocator.dupe(ids.ElemId, host.engine.render_cache.nodes.items[each_sites[0].parent_elem_id.index()].children.items);
            defer std.testing.allocator.free(first_parent_children_before);
            const second_parent_children_before = try std.testing.allocator.dupe(ids.ElemId, host.engine.render_cache.nodes.items[each_sites[1].parent_elem_id.index()].children.items);
            defer std.testing.allocator.free(second_parent_children_before);
            const allocations_before = host.roc_allocations.snapshot();

            const next_items = [_]HostValue{ testHostValueI64(2), testHostValueI64(3) };
            var fault = FaultAllocator.init(host.gpa.allocator());
            fault.configure(failure_number);
            host.engine_allocator_override = fault.allocator();
            const result = host.engine.tryDispatchStateValue(&host, &roc_host, state_id.raw(), testHostValueI64List(&roc_host, &next_items), state_cap);
            const attempts = fault.attempts;
            if (failure_number != null) {
                try std.testing.expectError(error.OutOfMemory, result);
                try std.testing.expectEqual(generation_before, host.engine.dirty_signal_generation);
                try std.testing.expectEqual(graph_len_before, host.engine.active_signal_graph.items.len);
                try std.testing.expectEqual(scope_len_before, host.engine.scopes.items.len);
                try std.testing.expectEqual(render_len_before, host.engine.active_stream.render_nodes.items.len);
                try std.testing.expectEqual(dom_len_before, host.dom_elements.items.len);
                try std.testing.expectEqual(state_value_before, host.engine.states.items[state_index].activePayloadConst().cell.value);
                try std.testing.expectEqualSlices(ids.ElemId, first_parent_children_before, host.engine.render_cache.nodes.items[each_sites[0].parent_elem_id.index()].children.items);
                try std.testing.expectEqualSlices(ids.ElemId, second_parent_children_before, host.engine.render_cache.nodes.items[each_sites[1].parent_elem_id.index()].children.items);
                const first_after = try host.engine.activeEachRowScopes(std.testing.allocator, each_sites[0].scope_id, each_sites[0].ordinal);
                defer std.testing.allocator.free(first_after);
                const second_after = try host.engine.activeEachRowScopes(std.testing.allocator, each_sites[1].scope_id, each_sites[1].ordinal);
                defer std.testing.allocator.free(second_after);
                try std.testing.expectEqualSlices(ids.ScopeId, first_rows_before, first_after);
                try std.testing.expectEqualSlices(ids.ScopeId, second_rows_before, second_after);
                try std.testing.expectEqual(@as(usize, 0), host.roc_allocations.liveCountSince(allocations_before));
                fault.configure(null);
                const retry_items = [_]HostValue{ testHostValueI64(2), testHostValueI64(3) };
                _ = try host.engine.tryDispatchStateValue(&host, &roc_host, state_id.raw(), testHostValueI64List(&roc_host, &retry_items), state_cap);
            } else _ = try result;

            const first_rows = try host.engine.activeEachRowScopes(std.testing.allocator, each_sites[0].scope_id, each_sites[0].ordinal);
            defer std.testing.allocator.free(first_rows);
            const second_rows = try host.engine.activeEachRowScopes(std.testing.allocator, each_sites[1].scope_id, each_sites[1].ordinal);
            defer std.testing.allocator.free(second_rows);
            try std.testing.expectEqual(@as(usize, 2), first_rows.len);
            try std.testing.expectEqual(@as(usize, 2), second_rows.len);
            try std.testing.expect(first_rows[0] != second_rows[0]);
            try std.testing.expect(activeTextElementId(&host, "row-1-1") == null);
            try std.testing.expect(activeTextElementId(&host, "row-2-2") != null);
            try std.testing.expect(activeTextElementId(&host, "row-3-3") != null);
            // Each column publishes exactly its own two rows: a parent whose
            // children were registered twice ends up with duplicates here.
            for (each_sites) |site| {
                const children = host.engine.render_cache.nodes.items[site.parent_elem_id.index()].children.items;
                try std.testing.expectEqual(@as(usize, 2), children.len);
                try std.testing.expect(children[0] != children[1]);
            }
            return attempts;
        }
    };

    const attempts = try Runner.run(null);
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| _ = try Runner.run(failure_number);
}

test "sibling each sites keep their insertion indexes after an earlier site grows" {
    // Every structural transaction lays a site's rows out from its committed
    // `render_insert_index`. Growing the first site shifts every render node
    // after it, so the sibling's index must be re-based at commit; leaving it
    // stale makes the *next* transaction stage rows over the wrong span and
    // refuse with a topology error. The second edit is the assertion.
    const Runner = struct {
        fn run(failure_number: ?usize) !usize {
            test_erased_callable_drop_count = 0;
            test_row_elem_call_count = 0;
            var host = HostEnv.init();
            var roc_host = makeSignalsRocHost(&host);
            host.engine.roc_host = &roc_host;
            defer {
                host.deinit();
                _ = host.gpa.deinit();
            }

            const state_token = newTestBinderToken(&roc_host);
            const state_cap = testHostValueCapability(&roc_host);
            const first_each = testNodeEachWithSignalCapabilityAndRow(&roc_host, testNodeRefExpr(state_token), state_cap, &testStatefulRowElemCallable);
            const second_each = testNodeEachWithSignalCapabilityAndRow(&roc_host, testNodeRefExpr(state_token), state_cap, &testStatefulRowElemCallable);
            const first_column = testElementWith(&roc_host, "div", &.{}, &.{first_each});
            const second_column = testElementWith(&roc_host, "div", &.{}, &.{second_each});
            const section = testElementWith(&roc_host, "section", &.{}, &.{ first_column, testNodeText(&roc_host, "between-columns"), second_column });
            const initial_items = [_]HostValue{ testHostValueI64(1), testHostValueI64(2) };
            const root = testNodeStateWithTokenAndInitialCapability(&roc_host, state_token, testHostValueI64List(&roc_host, &initial_items), section, state_cap);
            defer root.decref(&roc_host);
            var stream: HostNodeDescriptorStream = .{};
            host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
            _ = applyNodeDescriptorStream(&host, &roc_host, &stream);
            host.engine.active_stream = stream;

            const state_id = host.engine.active_stream.scope_sites.items[0].node_id;
            var each_node_ids: [2]ids.NodeId = undefined;
            var each_write: usize = 0;
            for (host.engine.active_stream.scope_sites.items) |site| if (site.kind == .each) {
                each_node_ids[each_write] = site.node_id;
                each_write += 1;
            };
            try std.testing.expectEqual(@as(usize, 2), each_write);

            // Grow both sites from two rows to four. The first site's growth
            // pushes the second site's rows two render nodes further along.
            const grown_items = [_]HostValue{ testHostValueI64(1), testHostValueI64(2), testHostValueI64(3), testHostValueI64(4) };
            _ = try host.engine.tryDispatchStateValue(&host, &roc_host, state_id.raw(), testHostValueI64List(&roc_host, &grown_items), state_cap);
            for (each_node_ids) |node_id| {
                const site = host.engine.activeScopeSiteByNodeId(node_id.raw(), .each).?;
                const rows = try host.engine.activeEachRowScopes(std.testing.allocator, site.scope_id, site.ordinal);
                defer std.testing.allocator.free(rows);
                try std.testing.expectEqual(@as(usize, 4), rows.len);
                const first_row_index = for (host.engine.active_stream.render_nodes.items, 0..) |node, index| {
                    if (engine.renderNodeScopeId(&host.engine.active_stream, node) == rows[0].raw()) break index;
                } else return error.TestUnexpectedResult;
                try std.testing.expectEqual(first_row_index, site.render_insert_index);
            }

            // The next transaction is staged from the re-based indexes; a
            // stale one overlaps the first site's span and is refused.
            const scope_len_before = host.engine.scopes.items.len;
            const render_len_before = host.engine.active_stream.render_nodes.items.len;
            const allocations_before = host.roc_allocations.snapshot();
            const shrunk_items = [_]HostValue{ testHostValueI64(4), testHostValueI64(2), testHostValueI64(5) };
            var fault = FaultAllocator.init(host.gpa.allocator());
            fault.configure(failure_number);
            host.engine_allocator_override = fault.allocator();
            const result = host.engine.tryDispatchStateValue(&host, &roc_host, state_id.raw(), testHostValueI64List(&roc_host, &shrunk_items), state_cap);
            const attempts = fault.attempts;
            if (failure_number != null) {
                try std.testing.expectError(error.OutOfMemory, result);
                try std.testing.expectEqual(scope_len_before, host.engine.scopes.items.len);
                try std.testing.expectEqual(render_len_before, host.engine.active_stream.render_nodes.items.len);
                try std.testing.expectEqual(@as(usize, 0), host.roc_allocations.liveCountSince(allocations_before));
                fault.configure(null);
                const retry_items = [_]HostValue{ testHostValueI64(4), testHostValueI64(2), testHostValueI64(5) };
                _ = try host.engine.tryDispatchStateValue(&host, &roc_host, state_id.raw(), testHostValueI64List(&roc_host, &retry_items), state_cap);
            } else _ = try result;

            for (each_node_ids) |node_id| {
                const site = host.engine.activeScopeSiteByNodeId(node_id.raw(), .each).?;
                const rows = try host.engine.activeEachRowScopes(std.testing.allocator, site.scope_id, site.ordinal);
                defer std.testing.allocator.free(rows);
                try std.testing.expectEqual(@as(usize, 3), rows.len);
                const children = host.engine.render_cache.nodes.items[site.parent_elem_id.index()].children.items;
                try std.testing.expectEqual(@as(usize, 3), children.len);
            }
            try std.testing.expect(activeTextElementId(&host, "row-1-1") == null);
            try std.testing.expect(activeTextElementId(&host, "row-3-3") == null);
            try std.testing.expect(activeTextElementId(&host, "row-5-5") != null);
            return attempts;
        }
    };

    const attempts = try Runner.run(null);
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| _ = try Runner.run(failure_number);
}

/// Position of the text element rendering `text` among the committed children
/// of `parent_elem_id`, so a test can assert document order after a splice.
fn childOrderOfText(host: *HostEnv, parent_elem_id: ids.ElemId, text: []const u8) ?usize {
    const elem_id = activeTextElementId(host, text) orelse return null;
    const children = host.engine.render_cache.nodes.items[parent_elem_id.index()].children.items;
    for (children, 0..) |child, index| if (child.raw() == elem_id) return index;
    return null;
}

/// Position of the text element rendering `text` in the committed render
/// stream, which is the order every later structural transaction lays out from.
fn streamOrderOfText(host: *HostEnv, text: []const u8) ?usize {
    const elem_id = activeTextElementId(host, text) orelse return null;
    for (host.engine.active_stream.render_nodes.items, 0..) |node, index| if (node.elem_id.raw() == elem_id) return index;
    return null;
}

/// Node ids of the active scope sites of one kind, in collection order.
fn activeScopeSiteNodeIdsOfKind(host: *HostEnv, kind: HostNodeScopeSiteKind, buffer: []ids.NodeId) []ids.NodeId {
    var write: usize = 0;
    for (host.engine.active_stream.scope_sites.items) |site| if (site.kind == kind) {
        if (write == buffer.len) @panic("more scope sites of the requested kind than the test expected");
        buffer[write] = site.node_id;
        write += 1;
    };
    return buffer[0..write];
}

/// Asserts a committed scope site's `render_insert_index`. Indexes are
/// positions in the active render stream, where the root element itself is
/// node 0, so a root's first child sits at index 1.
fn expectScopeSiteInsertIndex(host: *HostEnv, node_id: ids.NodeId, kind: HostNodeScopeSiteKind, expected: usize) !void {
    const site = host.engine.activeScopeSiteByNodeId(node_id.raw(), kind) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(expected, site.render_insert_index);
}

/// A `when` whose condition reads a state cell directly through a bare `Ref`.
fn testNodeWhenReadingState(roc_host: *abi.RocHost, condition_binder: HostBinderToken, condition_cap: HostValueCapability, when_true: abi.Elem, when_false: abi.Elem) abi.Elem {
    return .{ .payload = .{ .when = .{
        .condition = boxTestNodeSignalExpr(roc_host, testNodeRefExpr(condition_binder)),
        .read = testBoolReadHandle(roc_host, condition_cap),
        .when_false = boxTestElem(roc_host, when_false),
        .when_true = boxTestElem(roc_host, when_true),
    } }, .tag = .When };
}

/// A branch or site that renders nothing: an `each` over a frozen empty list.
/// It still registers a scope site at the insertion point, which is exactly
/// the empty-site shape the rebase has to order.
fn testNodeEmptyConstantEach(roc_host: *abi.RocHost) abi.Elem {
    return testNodeEachWithItemsRowAndCapture(TestErasedI64Capture, roc_host, &.{}, &testStatefulRowElemCallable, .{ .amount = 0 });
}

/// Dispatches `value` into `state_id`, sweeping host allocation failure at
/// `failure_number` and retrying without the fault; returns the attempt count.
fn dispatchStateValueSweeping(host: *HostEnv, roc_host: *abi.RocHost, state_id: ids.NodeId, value: HostValue, retry_value: HostValue, cap: HostValueCapability, failure_number: ?usize) !usize {
    const scope_len_before = host.engine.scopes.items.len;
    const render_len_before = host.engine.active_stream.render_nodes.items.len;
    const allocations_before = host.roc_allocations.snapshot();
    var fault = FaultAllocator.init(host.gpa.allocator());
    fault.configure(failure_number);
    host.engine_allocator_override = fault.allocator();
    defer host.engine_allocator_override = null;
    const result = host.engine.tryDispatchStateValue(host, roc_host, state_id.raw(), value, cap);
    const attempts = fault.attempts;
    if (failure_number != null) {
        try std.testing.expectError(error.OutOfMemory, result);
        try std.testing.expectEqual(scope_len_before, host.engine.scopes.items.len);
        try std.testing.expectEqual(render_len_before, host.engine.active_stream.render_nodes.items.len);
        try std.testing.expectEqual(@as(usize, 0), host.roc_allocations.liveCountSince(allocations_before));
        fault.configure(null);
        _ = try host.engine.tryDispatchStateValue(host, roc_host, state_id.raw(), retry_value, cap);
    } else {
        testDropHostValue(roc_host, retry_value);
        _ = try result;
    }
    return attempts;
}

test "an each growing inside a when's live branch leaves the when site's insertion index alone" {
    // The loan-comparator shape: a `when` whose live branch *is* an `each`.
    // Both sites start at the same index. Growing the each is a region inside
    // the when's own content, so it must not shift the when, while the sibling
    // site after the branch must move by the growth.
    const Runner = struct {
        fn run(failure_number: ?usize) !usize {
            test_erased_callable_drop_count = 0;
            test_row_elem_call_count = 0;
            var host = HostEnv.init();
            var roc_host = makeSignalsRocHost(&host);
            host.engine.roc_host = &roc_host;
            defer {
                host.deinit();
                _ = host.gpa.deinit();
            }

            const list_token = newTestBinderToken(&roc_host);
            const list_cap = testHostValueCapability(&roc_host);
            const bool_token = newTestBinderToken(&roc_host);
            const bool_cap = testHostValueCapability(&roc_host);
            const inner_each = testNodeEachWithSignalCapabilityAndRow(&roc_host, testNodeRefExpr(list_token), list_cap, &testStatefulRowElemCallable);
            const when = testNodeWhenReadingState(&roc_host, bool_token, bool_cap, inner_each, testNodeText(&roc_host, "when-off"));
            const trailing_each = testNodeEachWithSignalCapabilityAndRow(&roc_host, testNodeRefExpr(list_token), list_cap, &testStatefulRowButtonElemCallable);
            const section = testElementWith(&roc_host, "section", &.{}, &.{ testNodeText(&roc_host, "before"), when, trailing_each, testNodeText(&roc_host, "after") });
            const bool_state = testNodeStateWithTokenAndInitialCapability(&roc_host, bool_token, testHostValueBool(true), section, bool_cap);
            const initial = [_]HostValue{testHostValueI64(1)};
            const root = testNodeStateWithTokenAndInitialCapability(&roc_host, list_token, testHostValueI64List(&roc_host, &initial), bool_state, list_cap);
            defer root.decref(&roc_host);
            var stream: HostNodeDescriptorStream = .{};
            host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
            _ = applyNodeDescriptorStream(&host, &roc_host, &stream);
            host.engine.active_stream = stream;

            var state_buffer: [8]ids.NodeId = undefined;
            const states = activeScopeSiteNodeIdsOfKind(&host, .state, &state_buffer);
            const list_state_id = states[0];
            const bool_state_id = states[1];
            var when_buffer: [1]ids.NodeId = undefined;
            const when_id = activeScopeSiteNodeIdsOfKind(&host, .when, &when_buffer)[0];
            var each_buffer: [2]ids.NodeId = undefined;
            const eaches = activeScopeSiteNodeIdsOfKind(&host, .each, &each_buffer);
            try std.testing.expectEqual(@as(usize, 2), eaches.len);
            const inner_each_id = eaches[0];
            const trailing_each_id = eaches[1];
            try expectScopeSiteInsertIndex(&host, when_id, .when, 2);
            try expectScopeSiteInsertIndex(&host, inner_each_id, .each, 2);
            try expectScopeSiteInsertIndex(&host, trailing_each_id, .each, 3);

            const grown = [_]HostValue{ testHostValueI64(1), testHostValueI64(2) };
            _ = try host.engine.tryDispatchStateValue(&host, &roc_host, list_state_id.raw(), testHostValueI64List(&roc_host, &grown), list_cap);
            try expectScopeSiteInsertIndex(&host, when_id, .when, 2);
            try expectScopeSiteInsertIndex(&host, inner_each_id, .each, 2);
            try expectScopeSiteInsertIndex(&host, trailing_each_id, .each, 4);

            // Retiring the branch removes the each's rows; the trailing site
            // moves back behind the one-node false branch.
            const attempts = try dispatchStateValueSweeping(&host, &roc_host, bool_state_id, testHostValueBool(false), testHostValueBool(false), bool_cap, failure_number);
            try expectScopeSiteInsertIndex(&host, when_id, .when, 2);
            const trailing_after = host.engine.activeScopeSiteByNodeId(trailing_each_id.raw(), .each) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(usize, 3), trailing_after.render_insert_index);
            const section_id = host.engine.active_stream.elements.items[0].elem_id;
            try std.testing.expectEqual(@as(?usize, 0), childOrderOfText(&host, section_id, "before"));
            try std.testing.expectEqual(@as(?usize, 1), childOrderOfText(&host, section_id, "when-off"));
            try std.testing.expectEqual(@as(?usize, 2), childOrderOfText(&host, section_id, "row-action-1-1"));
            try std.testing.expectEqual(@as(?usize, 4), childOrderOfText(&host, section_id, "after"));
            try std.testing.expect(activeTextElementId(&host, "row-1-1") == null);
            return attempts;
        }
    };

    const attempts = try Runner.run(null);
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| _ = try Runner.run(failure_number);
}

test "an empty each before a reordered sibling each keeps its shared insertion index" {
    // The shape from structural fuzz input in_108: a constant site with no
    // rows sits at the same index as the shared site after it. Reordering the
    // shared site's first row moves the node at that index, which must not
    // drag the empty site with it; the empty site after both stays put too,
    // then follows the shared site's growth.
    const Runner = struct {
        fn run(failure_number: ?usize) !usize {
            test_erased_callable_drop_count = 0;
            test_row_elem_call_count = 0;
            var host = HostEnv.init();
            var roc_host = makeSignalsRocHost(&host);
            host.engine.roc_host = &roc_host;
            defer {
                host.deinit();
                _ = host.gpa.deinit();
            }

            const list_token = newTestBinderToken(&roc_host);
            const cap = testHostValueCapability(&roc_host);
            const shared_each = testNodeEachWithSignalCapabilityAndRow(&roc_host, testNodeRefExpr(list_token), cap, &testStatefulRowElemCallable);
            const section = testElementWith(&roc_host, "section", &.{}, &.{ testNodeEmptyConstantEach(&roc_host), shared_each, testNodeEmptyConstantEach(&roc_host), testNodeText(&roc_host, "after") });
            const initial = [_]HostValue{ testHostValueI64(1), testHostValueI64(2), testHostValueI64(3) };
            const root = testNodeStateWithTokenAndInitialCapability(&roc_host, list_token, testHostValueI64List(&roc_host, &initial), section, cap);
            defer root.decref(&roc_host);
            var stream: HostNodeDescriptorStream = .{};
            host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
            _ = applyNodeDescriptorStream(&host, &roc_host, &stream);
            host.engine.active_stream = stream;

            const list_state_id = host.engine.active_stream.scope_sites.items[0].node_id;
            var each_buffer: [3]ids.NodeId = undefined;
            const eaches = activeScopeSiteNodeIdsOfKind(&host, .each, &each_buffer);
            try std.testing.expectEqual(@as(usize, 3), eaches.len);
            try expectScopeSiteInsertIndex(&host, eaches[0], .each, 1);
            try expectScopeSiteInsertIndex(&host, eaches[1], .each, 1);
            try expectScopeSiteInsertIndex(&host, eaches[2], .each, 4);

            const reordered = [_]HostValue{ testHostValueI64(2), testHostValueI64(3), testHostValueI64(1) };
            _ = try host.engine.tryDispatchStateValue(&host, &roc_host, list_state_id.raw(), testHostValueI64List(&roc_host, &reordered), cap);
            try expectScopeSiteInsertIndex(&host, eaches[0], .each, 1);
            try expectScopeSiteInsertIndex(&host, eaches[1], .each, 1);
            try expectScopeSiteInsertIndex(&host, eaches[2], .each, 4);
            const section_id = host.engine.active_stream.elements.items[0].elem_id;
            try std.testing.expectEqual(@as(?usize, 0), childOrderOfText(&host, section_id, "row-2-2"));
            try std.testing.expectEqual(@as(?usize, 2), childOrderOfText(&host, section_id, "row-1-1"));

            const grown = [_]HostValue{ testHostValueI64(2), testHostValueI64(3), testHostValueI64(1), testHostValueI64(4) };
            const retry = [_]HostValue{ testHostValueI64(2), testHostValueI64(3), testHostValueI64(1), testHostValueI64(4) };
            const attempts = try dispatchStateValueSweeping(&host, &roc_host, list_state_id, testHostValueI64List(&roc_host, &grown), testHostValueI64List(&roc_host, &retry), cap, failure_number);
            try expectScopeSiteInsertIndex(&host, eaches[0], .each, 1);
            try expectScopeSiteInsertIndex(&host, eaches[1], .each, 1);
            try expectScopeSiteInsertIndex(&host, eaches[2], .each, 5);
            try std.testing.expectEqual(@as(?usize, 4), childOrderOfText(&host, section_id, "after"));
            return attempts;
        }
    };

    const attempts = try Runner.run(null);
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| _ = try Runner.run(failure_number);
}

test "an empty each growing at the node a when site owns shifts the when site" {
    // The status-page shape: an `each` with no rows sits at the index of the
    // next sibling's first node, a `when` branch. Growing the each inserts in
    // front of that node, so the when site must move with its branch.
    const Runner = struct {
        fn run(failure_number: ?usize) !usize {
            test_erased_callable_drop_count = 0;
            test_row_elem_call_count = 0;
            var host = HostEnv.init();
            var roc_host = makeSignalsRocHost(&host);
            host.engine.roc_host = &roc_host;
            defer {
                host.deinit();
                _ = host.gpa.deinit();
            }

            const list_token = newTestBinderToken(&roc_host);
            const list_cap = testHostValueCapability(&roc_host);
            const bool_token = newTestBinderToken(&roc_host);
            const bool_cap = testHostValueCapability(&roc_host);
            const each = testNodeEachWithSignalCapabilityAndRow(&roc_host, testNodeRefExpr(list_token), list_cap, &testStatefulRowElemCallable);
            const when = testNodeWhenReadingState(&roc_host, bool_token, bool_cap, testNodeText(&roc_host, "when-on"), testNodeText(&roc_host, "when-off"));
            const section = testElementWith(&roc_host, "section", &.{}, &.{ testNodeText(&roc_host, "before"), each, when, testNodeText(&roc_host, "after") });
            const bool_state = testNodeStateWithTokenAndInitialCapability(&roc_host, bool_token, testHostValueBool(true), section, bool_cap);
            const root = testNodeStateWithTokenAndInitialCapability(&roc_host, list_token, testHostValueI64List(&roc_host, &.{}), bool_state, list_cap);
            defer root.decref(&roc_host);
            var stream: HostNodeDescriptorStream = .{};
            host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
            _ = applyNodeDescriptorStream(&host, &roc_host, &stream);
            host.engine.active_stream = stream;

            var state_buffer: [8]ids.NodeId = undefined;
            const states = activeScopeSiteNodeIdsOfKind(&host, .state, &state_buffer);
            const list_state_id = states[0];
            const bool_state_id = states[1];
            var when_buffer: [1]ids.NodeId = undefined;
            const when_id = activeScopeSiteNodeIdsOfKind(&host, .when, &when_buffer)[0];
            var each_buffer: [1]ids.NodeId = undefined;
            const each_id = activeScopeSiteNodeIdsOfKind(&host, .each, &each_buffer)[0];
            try expectScopeSiteInsertIndex(&host, each_id, .each, 2);
            try expectScopeSiteInsertIndex(&host, when_id, .when, 2);

            const grown = [_]HostValue{ testHostValueI64(1), testHostValueI64(2) };
            const retry = [_]HostValue{ testHostValueI64(1), testHostValueI64(2) };
            const attempts = try dispatchStateValueSweeping(&host, &roc_host, list_state_id, testHostValueI64List(&roc_host, &grown), testHostValueI64List(&roc_host, &retry), list_cap, failure_number);
            try expectScopeSiteInsertIndex(&host, each_id, .each, 2);
            try expectScopeSiteInsertIndex(&host, when_id, .when, 4);
            const section_id = host.engine.active_stream.elements.items[0].elem_id;
            try std.testing.expectEqual(@as(?usize, 3), childOrderOfText(&host, section_id, "when-on"));

            // The next branch flip is staged from the re-based index.
            _ = try host.engine.tryDispatchStateValue(&host, &roc_host, bool_state_id.raw(), testHostValueBool(false), bool_cap);
            try expectScopeSiteInsertIndex(&host, when_id, .when, 4);
            try std.testing.expectEqual(@as(?usize, 3), childOrderOfText(&host, section_id, "when-off"));
            try std.testing.expectEqual(@as(?usize, 4), childOrderOfText(&host, section_id, "after"));
            return attempts;
        }
    };

    const attempts = try Runner.run(null);
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| _ = try Runner.run(failure_number);
}

test "an empty when before another empty when at one index stays in front when the later one grows" {
    // Two `when` sites rendering nothing share an index in front of a text
    // node. Growing the *second* inserts after the first's position, so the
    // first must keep its index; when it grows afterwards its content has to
    // land in front of the second's. Ordering by the node at the index would
    // push the first site behind content that follows it in the document.
    const Runner = struct {
        fn run(failure_number: ?usize) !usize {
            test_erased_callable_drop_count = 0;
            test_row_elem_call_count = 0;
            var host = HostEnv.init();
            var roc_host = makeSignalsRocHost(&host);
            host.engine.roc_host = &roc_host;
            defer {
                host.deinit();
                _ = host.gpa.deinit();
            }

            const first_token = newTestBinderToken(&roc_host);
            const first_cap = testHostValueCapability(&roc_host);
            const second_token = newTestBinderToken(&roc_host);
            const second_cap = testHostValueCapability(&roc_host);
            const first_when = testNodeWhenReadingState(&roc_host, first_token, first_cap, testNodeText(&roc_host, "first-on"), testNodeEmptyConstantEach(&roc_host));
            const second_when = testNodeWhenReadingState(&roc_host, second_token, second_cap, testNodeText(&roc_host, "second-on"), testNodeEmptyConstantEach(&roc_host));
            const section = testElementWith(&roc_host, "section", &.{}, &.{ first_when, second_when, testNodeText(&roc_host, "tail") });
            const second_state = testNodeStateWithTokenAndInitialCapability(&roc_host, second_token, testHostValueBool(false), section, second_cap);
            const root = testNodeStateWithTokenAndInitialCapability(&roc_host, first_token, testHostValueBool(false), second_state, first_cap);
            defer root.decref(&roc_host);
            var stream: HostNodeDescriptorStream = .{};
            host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
            _ = applyNodeDescriptorStream(&host, &roc_host, &stream);
            host.engine.active_stream = stream;

            var state_buffer: [4]ids.NodeId = undefined;
            const states = activeScopeSiteNodeIdsOfKind(&host, .state, &state_buffer);
            const first_state_id = states[0];
            const second_state_id = states[1];
            var when_buffer: [2]ids.NodeId = undefined;
            const whens = activeScopeSiteNodeIdsOfKind(&host, .when, &when_buffer);
            try expectScopeSiteInsertIndex(&host, whens[0], .when, 1);
            try expectScopeSiteInsertIndex(&host, whens[1], .when, 1);

            _ = try host.engine.tryDispatchStateValue(&host, &roc_host, second_state_id.raw(), testHostValueBool(true), second_cap);
            try expectScopeSiteInsertIndex(&host, whens[0], .when, 1);
            try expectScopeSiteInsertIndex(&host, whens[1], .when, 1);
            try std.testing.expectEqual(@as(?usize, 1), streamOrderOfText(&host, "second-on"));
            try std.testing.expectEqual(@as(?usize, 0), childOrderOfText(&host, host.engine.active_stream.elements.items[0].elem_id, "second-on"));
            try std.testing.expectEqual(@as(?usize, 1), childOrderOfText(&host, host.engine.active_stream.elements.items[0].elem_id, "tail"));

            const attempts = try dispatchStateValueSweeping(&host, &roc_host, first_state_id, testHostValueBool(true), testHostValueBool(true), first_cap, failure_number);
            try expectScopeSiteInsertIndex(&host, whens[0], .when, 1);
            try expectScopeSiteInsertIndex(&host, whens[1], .when, 2);
            try std.testing.expectEqual(@as(?usize, 1), streamOrderOfText(&host, "first-on"));
            try std.testing.expectEqual(@as(?usize, 2), streamOrderOfText(&host, "second-on"));
            try std.testing.expectEqual(@as(?usize, 3), streamOrderOfText(&host, "tail"));
            const section_id = host.engine.active_stream.elements.items[0].elem_id;
            try std.testing.expectEqual(@as(?usize, 0), childOrderOfText(&host, section_id, "first-on"));
            try std.testing.expectEqual(@as(?usize, 1), childOrderOfText(&host, section_id, "second-on"));
            try std.testing.expectEqual(@as(?usize, 2), childOrderOfText(&host, section_id, "tail"));
            try std.testing.expectEqual(@as(usize, 3), host.engine.render_cache.nodes.items[section_id.index()].children.items.len);
            return attempts;
        }
    };

    const attempts = try Runner.run(null);
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| _ = try Runner.run(failure_number);
}

test "a when flipping from an empty branch anchors its DOM node at its site, not after its siblings" {
    // The retired branch rendered nothing, so the render cache holds no
    // retired child to mark the insertion point. The DOM child order has to
    // come from the final render topology like the each paths, not from
    // "insert where the retired child was, else append".
    const Runner = struct {
        fn run(failure_number: ?usize) !usize {
            test_erased_callable_drop_count = 0;
            test_row_elem_call_count = 0;
            var host = HostEnv.init();
            var roc_host = makeSignalsRocHost(&host);
            host.engine.roc_host = &roc_host;
            defer {
                host.deinit();
                _ = host.gpa.deinit();
            }

            const token = newTestBinderToken(&roc_host);
            const cap = testHostValueCapability(&roc_host);
            const when = testNodeWhenReadingState(&roc_host, token, cap, testNodeText(&roc_host, "on"), testNodeEmptyConstantEach(&roc_host));
            const section = testElementWith(&roc_host, "section", &.{}, &.{ when, testNodeText(&roc_host, "tail") });
            const root = testNodeStateWithTokenAndInitialCapability(&roc_host, token, testHostValueBool(false), section, cap);
            defer root.decref(&roc_host);
            var stream: HostNodeDescriptorStream = .{};
            host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
            _ = applyNodeDescriptorStream(&host, &roc_host, &stream);
            host.engine.active_stream = stream;

            const state_id = host.engine.active_stream.scope_sites.items[0].node_id;
            const section_id = host.engine.active_stream.elements.items[0].elem_id;
            try std.testing.expectEqual(@as(?usize, 0), childOrderOfText(&host, section_id, "tail"));

            const attempts = try dispatchStateValueSweeping(&host, &roc_host, state_id, testHostValueBool(true), testHostValueBool(true), cap, failure_number);
            try std.testing.expectEqual(@as(?usize, 1), streamOrderOfText(&host, "on"));
            try std.testing.expectEqual(@as(?usize, 2), streamOrderOfText(&host, "tail"));
            try std.testing.expectEqual(@as(?usize, 0), childOrderOfText(&host, section_id, "on"));
            try std.testing.expectEqual(@as(?usize, 1), childOrderOfText(&host, section_id, "tail"));
            try std.testing.expectEqual(@as(usize, 2), host.engine.render_cache.nodes.items[section_id.index()].children.items.len);

            // Flipping back removes the node; flipping again anchors it again.
            _ = try host.engine.tryDispatchStateValue(&host, &roc_host, state_id.raw(), testHostValueBool(false), cap);
            try std.testing.expectEqual(@as(?usize, 0), childOrderOfText(&host, section_id, "tail"));
            try std.testing.expectEqual(@as(usize, 1), host.engine.render_cache.nodes.items[section_id.index()].children.items.len);
            _ = try host.engine.tryDispatchStateValue(&host, &roc_host, state_id.raw(), testHostValueBool(true), cap);
            try std.testing.expectEqual(@as(?usize, 0), childOrderOfText(&host, section_id, "on"));
            try std.testing.expectEqual(@as(?usize, 1), childOrderOfText(&host, section_id, "tail"));
            return attempts;
        }
    };

    const attempts = try Runner.run(null);
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| _ = try Runner.run(failure_number);
}

/// Row callable whose row is a `when` asking `length >= min_length` of the
/// list in the captured state cell, rendering `row-<key>-on` or `row-<key>-off`.
const TestListWhenRowCapture = extern struct { token: *const HostBinderToken, min_length: i64 = 1 };

fn testListWhenRowElemCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const capture = testCapturePtrAs(TestListWhenRowCapture, capture_ptr);
    const call_args = testErasedArgsAs(ErasedHostValueBinaryArgs, args);
    const key = testReadHostValueI64(roc_host, call_args.arg0);
    var on_buffer: [32]u8 = undefined;
    var off_buffer: [32]u8 = undefined;
    const on = std.fmt.bufPrint(&on_buffer, "row-{d}-on", .{key}) catch unreachable;
    const off = std.fmt.bufPrint(&off_buffer, "row-{d}-off", .{key}) catch unreachable;
    writeTestErasedResult(abi.Elem, ret, testNodeWhenOnListPredicate(roc_host, capture.token.*, .length_at_least, capture.min_length, testNodeText(roc_host, on), testNodeText(roc_host, off)));
}

test "a branch mounted by a flip reads the list the flip published, not the retired one" {
    // The outer when flips when the list empties. Its new branch holds a
    // constant each whose row carries a when on the same list, so the row
    // has to be collected against the value the transaction publishes.
    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    const list_token = newTestBinderToken(&roc_host);
    const cap = testHostValueCapability(&roc_host);
    const row_each = testNodeEachWithItemsRowAndCapture(TestListWhenRowCapture, &roc_host, &.{testHostValueI64(0)}, &testListWhenRowElemCallable, .{ .token = &list_token });
    const false_branch = testElementWith(&roc_host, "div", &.{}, &.{row_each});
    const outer_when = testNodeWhenOnListPredicate(&roc_host, list_token, .length_at_least, 2, testNodeText(&roc_host, "outer-on"), false_branch);
    const shared_each = testNodeEachWithSignalCapabilityAndRow(&roc_host, testNodeRefExpr(list_token), cap, &testStatefulRowElemCallable);
    const section = testElementWith(&roc_host, "section", &.{}, &.{ shared_each, outer_when });
    const initial = [_]HostValue{ testHostValueI64(1), testHostValueI64(2) };
    const root = testNodeStateWithTokenAndInitialCapability(&roc_host, list_token, testHostValueI64List(&roc_host, &initial), section, cap);
    defer root.decref(&roc_host);
    var stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
    _ = applyNodeDescriptorStream(&host, &roc_host, &stream);
    host.engine.active_stream = stream;
    try std.testing.expect(activeTextElementId(&host, "outer-on") != null);

    const list_state_id = host.engine.active_stream.scope_sites.items[0].node_id;
    _ = try host.engine.tryDispatchStateValue(&host, &roc_host, list_state_id.raw(), testHostValueI64List(&roc_host, &.{}), cap);
    try std.testing.expect(activeTextElementId(&host, "outer-on") == null);
    try std.testing.expect(activeTextElementId(&host, "row-0-on") == null);
    try std.testing.expect(activeTextElementId(&host, "row-0-off") != null);
}

test "a row mounted by a re-diff reads the list the edit published, not the retired one" {
    // Growing the list mounts rows whose own `when` reads that list. The row
    // records are collected fresh, so the cache overlay holds nothing for
    // them; only the staged state value can answer with the published list.
    // One shared site takes the single-each path, two take the composite.
    const Runner = struct {
        fn run(shared_sites: usize) !void {
            var host = HostEnv.init();
            var roc_host = makeSignalsRocHost(&host);
            host.engine.roc_host = &roc_host;
            defer {
                host.deinit();
                _ = host.gpa.deinit();
            }

            const list_token = newTestBinderToken(&roc_host);
            const cap = testHostValueCapability(&roc_host);
            var children: [2]abi.Elem = undefined;
            for (children[0..shared_sites]) |*child| {
                child.* = testNodeEachWithSignalCapabilityRowAndCapture(TestListWhenRowCapture, &roc_host, testNodeRefExpr(list_token), cap, &testListWhenRowElemCallable, .{ .token = &list_token });
            }
            const section = testElementWith(&roc_host, "section", &.{}, children[0..shared_sites]);
            const root = testNodeStateWithTokenAndInitialCapability(&roc_host, list_token, testHostValueI64List(&roc_host, &.{}), section, cap);
            defer root.decref(&roc_host);
            var stream: HostNodeDescriptorStream = .{};
            host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
            _ = applyNodeDescriptorStream(&host, &roc_host, &stream);
            host.engine.active_stream = stream;
            try std.testing.expect(activeTextElementId(&host, "row-7-on") == null);

            // The row when asks `length >= 1`, which the retired empty list
            // fails and the published one-item list satisfies.
            const list_state_id = host.engine.active_stream.scope_sites.items[0].node_id;
            const grown = [_]HostValue{testHostValueI64(7)};
            _ = try host.engine.tryDispatchStateValue(&host, &roc_host, list_state_id.raw(), testHostValueI64List(&roc_host, &grown), cap);
            try std.testing.expect(activeTextElementId(&host, "row-7-on") != null);
            try std.testing.expect(activeTextElementId(&host, "row-7-off") == null);
        }
    };
    try Runner.run(1);
    try Runner.run(2);
}

test "adjacent when rows flipping together retire their own branches, not each other's" {
    // Two rows of one constant each are whens on the list, side by side under
    // one parent. When both flip in one transaction, the removal scan for the
    // first branch must stop at its own nodes: scanned against every retired
    // scope at once it swallows the second branch, whose own interval then
    // overlaps it and the edit is refused as `OverlappingRemoval`.
    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    const list_token = newTestBinderToken(&roc_host);
    const cap = testHostValueCapability(&roc_host);
    const rows = [_]HostValue{ testHostValueI64(0), testHostValueI64(1) };
    const each = testNodeEachWithItemsRowAndCapture(TestListWhenRowCapture, &roc_host, &rows, &testListWhenRowElemCallable, .{ .token = &list_token });
    const section = testElementWith(&roc_host, "section", &.{}, &.{ each, testNodeText(&roc_host, "tail") });
    const initial = [_]HostValue{testHostValueI64(5)};
    const root = testNodeStateWithTokenAndInitialCapability(&roc_host, list_token, testHostValueI64List(&roc_host, &initial), section, cap);
    defer root.decref(&roc_host);
    var stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
    _ = applyNodeDescriptorStream(&host, &roc_host, &stream);
    host.engine.active_stream = stream;
    const section_id = host.engine.active_stream.elements.items[0].elem_id;
    try std.testing.expectEqual(@as(?usize, 0), childOrderOfText(&host, section_id, "row-0-on"));
    try std.testing.expectEqual(@as(?usize, 1), childOrderOfText(&host, section_id, "row-1-on"));

    const list_state_id = host.engine.active_stream.scope_sites.items[0].node_id;
    _ = try host.engine.tryDispatchStateValue(&host, &roc_host, list_state_id.raw(), testHostValueI64List(&roc_host, &.{}), cap);
    try std.testing.expectEqual(@as(?usize, 0), childOrderOfText(&host, section_id, "row-0-off"));
    try std.testing.expectEqual(@as(?usize, 1), childOrderOfText(&host, section_id, "row-1-off"));
    try std.testing.expectEqual(@as(?usize, 2), childOrderOfText(&host, section_id, "tail"));
    try std.testing.expect(activeTextElementId(&host, "row-0-on") == null);
    try std.testing.expect(activeTextElementId(&host, "row-1-on") == null);
    host.engine.validateActiveScopeSiteInsertIndexes();
}

test "reordered surviving rows each carry their own flipping when" {
    // Two rows of a shared each survive an edit that swaps them and, through
    // the same list, flips the when inside each. The layout lays survivors
    // out in their next order, so the when nested in a row has to be found by
    // the row's scope; taking regions in old document order handed each row
    // the other's when and the edit was refused as `InvalidRenderTopology`.
    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    const list_token = newTestBinderToken(&roc_host);
    const cap = testHostValueCapability(&roc_host);
    const each = testNodeEachWithSignalCapabilityRowAndCapture(TestListWhenRowCapture, &roc_host, testNodeRefExpr(list_token), cap, &testListWhenRowElemCallable, .{ .token = &list_token, .min_length = 3 });
    const section = testElementWith(&roc_host, "section", &.{}, &.{ each, testNodeText(&roc_host, "tail") });
    const initial = [_]HostValue{ testHostValueI64(1), testHostValueI64(2) };
    const root = testNodeStateWithTokenAndInitialCapability(&roc_host, list_token, testHostValueI64List(&roc_host, &initial), section, cap);
    defer root.decref(&roc_host);
    var stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
    _ = applyNodeDescriptorStream(&host, &roc_host, &stream);
    host.engine.active_stream = stream;
    const section_id = host.engine.active_stream.elements.items[0].elem_id;
    try std.testing.expectEqual(@as(?usize, 0), childOrderOfText(&host, section_id, "row-1-off"));
    try std.testing.expectEqual(@as(?usize, 1), childOrderOfText(&host, section_id, "row-2-off"));

    const list_state_id = host.engine.active_stream.scope_sites.items[0].node_id;
    const swapped = [_]HostValue{ testHostValueI64(2), testHostValueI64(1), testHostValueI64(3) };
    _ = try host.engine.tryDispatchStateValue(&host, &roc_host, list_state_id.raw(), testHostValueI64List(&roc_host, &swapped), cap);
    try std.testing.expectEqual(@as(?usize, 0), childOrderOfText(&host, section_id, "row-2-on"));
    try std.testing.expectEqual(@as(?usize, 1), childOrderOfText(&host, section_id, "row-1-on"));
    try std.testing.expectEqual(@as(?usize, 2), childOrderOfText(&host, section_id, "row-3-on"));
    try std.testing.expectEqual(@as(?usize, 3), childOrderOfText(&host, section_id, "tail"));
    try std.testing.expect(activeTextElementId(&host, "row-1-off") == null);
    try std.testing.expect(activeTextElementId(&host, "row-2-off") == null);
    host.engine.validateActiveScopeSiteInsertIndexes();
}

test "a when site collected later inside an earlier branch still orders before the empty site after it" {
    // A branch mounted after the initial collection carries a `when` whose
    // node id is larger than the sibling site after the branch. Node ids say
    // nothing about document order: when that nested when grows at the end
    // of the stream, the sibling behind it must shift, so its own content
    // lands after the nested when's.
    const Runner = struct {
        fn run(failure_number: ?usize) !usize {
            test_erased_callable_drop_count = 0;
            test_row_elem_call_count = 0;
            var host = HostEnv.init();
            var roc_host = makeSignalsRocHost(&host);
            host.engine.roc_host = &roc_host;
            defer {
                host.deinit();
                _ = host.gpa.deinit();
            }

            const outer_token = newTestBinderToken(&roc_host);
            const outer_cap = testHostValueCapability(&roc_host);
            const nested_token = newTestBinderToken(&roc_host);
            const nested_cap = testHostValueCapability(&roc_host);
            const sibling_token = newTestBinderToken(&roc_host);
            const sibling_cap = testHostValueCapability(&roc_host);
            const nested_when = testNodeWhenReadingState(&roc_host, nested_token, nested_cap, testNodeText(&roc_host, "nested-on"), testNodeEmptyConstantEach(&roc_host));
            const outer_when = testNodeWhenReadingState(&roc_host, outer_token, outer_cap, nested_when, testNodeEmptyConstantEach(&roc_host));
            const sibling_when = testNodeWhenReadingState(&roc_host, sibling_token, sibling_cap, testNodeText(&roc_host, "sibling-on"), testNodeEmptyConstantEach(&roc_host));
            const section = testElementWith(&roc_host, "section", &.{}, &.{ outer_when, sibling_when });
            const sibling_state = testNodeStateWithTokenAndInitialCapability(&roc_host, sibling_token, testHostValueBool(false), section, sibling_cap);
            const nested_state = testNodeStateWithTokenAndInitialCapability(&roc_host, nested_token, testHostValueBool(false), sibling_state, nested_cap);
            const root = testNodeStateWithTokenAndInitialCapability(&roc_host, outer_token, testHostValueBool(false), nested_state, outer_cap);
            defer root.decref(&roc_host);
            var stream: HostNodeDescriptorStream = .{};
            host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
            _ = applyNodeDescriptorStream(&host, &roc_host, &stream);
            host.engine.active_stream = stream;

            var state_buffer: [4]ids.NodeId = undefined;
            const states = activeScopeSiteNodeIdsOfKind(&host, .state, &state_buffer);
            const outer_state_id = states[0];
            const nested_state_id = states[1];
            const sibling_state_id = states[2];
            var when_buffer: [3]ids.NodeId = undefined;
            const initial_whens = activeScopeSiteNodeIdsOfKind(&host, .when, &when_buffer);
            try std.testing.expectEqual(@as(usize, 2), initial_whens.len);
            const outer_when_id = initial_whens[0];
            const sibling_when_id = initial_whens[1];

            _ = try host.engine.tryDispatchStateValue(&host, &roc_host, outer_state_id.raw(), testHostValueBool(true), outer_cap);
            const whens = activeScopeSiteNodeIdsOfKind(&host, .when, &when_buffer);
            try std.testing.expectEqual(@as(usize, 3), whens.len);
            const nested_when_id = for (whens) |node_id| {
                if (node_id != outer_when_id and node_id != sibling_when_id) break node_id;
            } else return error.TestUnexpectedResult;
            try std.testing.expect(nested_when_id.raw() > sibling_when_id.raw());
            try expectScopeSiteInsertIndex(&host, nested_when_id, .when, 1);
            try expectScopeSiteInsertIndex(&host, sibling_when_id, .when, 1);

            _ = try host.engine.tryDispatchStateValue(&host, &roc_host, nested_state_id.raw(), testHostValueBool(true), nested_cap);
            try expectScopeSiteInsertIndex(&host, outer_when_id, .when, 1);
            try expectScopeSiteInsertIndex(&host, nested_when_id, .when, 1);
            try expectScopeSiteInsertIndex(&host, sibling_when_id, .when, 2);

            const attempts = try dispatchStateValueSweeping(&host, &roc_host, sibling_state_id, testHostValueBool(true), testHostValueBool(true), sibling_cap, failure_number);
            try expectScopeSiteInsertIndex(&host, sibling_when_id, .when, 2);
            try std.testing.expectEqual(@as(?usize, 1), streamOrderOfText(&host, "nested-on"));
            try std.testing.expectEqual(@as(?usize, 2), streamOrderOfText(&host, "sibling-on"));
            const section_id = host.engine.active_stream.elements.items[0].elem_id;
            try std.testing.expectEqual(@as(?usize, 0), childOrderOfText(&host, section_id, "nested-on"));
            try std.testing.expectEqual(@as(?usize, 1), childOrderOfText(&host, section_id, "sibling-on"));
            try std.testing.expectEqual(@as(usize, 2), host.engine.render_cache.nodes.items[section_id.index()].children.items.len);
            return attempts;
        }
    };

    const attempts = try Runner.run(null);
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| _ = try Runner.run(failure_number);
}

test "a when branch and an each under one parent grow in one transaction and re-base the sites after them" {
    // One list state feeds a `when` condition and an `each` under the same
    // parent, so a single dispatch stages the mixed when+each transaction:
    // the branch mounts one node in front of the each while the each grows.
    const Runner = struct {
        fn run(failure_number: ?usize) !usize {
            test_erased_callable_drop_count = 0;
            test_row_elem_call_count = 0;
            var host = HostEnv.init();
            var roc_host = makeSignalsRocHost(&host);
            host.engine.roc_host = &roc_host;
            defer {
                host.deinit();
                _ = host.gpa.deinit();
            }

            const list_token = newTestBinderToken(&roc_host);
            const cap = testHostValueCapability(&roc_host);
            const when = testNodeWhenWithSignal(&roc_host, testNodeListContainsOneExpr(&roc_host, testNodeRefExpr(list_token)), testNodeText(&roc_host, "has-one"), testNodeEmptyConstantEach(&roc_host));
            const each = testNodeEachWithSignalCapabilityAndRow(&roc_host, testNodeRefExpr(list_token), cap, &testStatefulRowElemCallable);
            const section = testElementWith(&roc_host, "section", &.{}, &.{ when, each, testNodeEmptyConstantEach(&roc_host), testNodeText(&roc_host, "tail") });
            const initial = [_]HostValue{ testHostValueI64(2), testHostValueI64(3) };
            const root = testNodeStateWithTokenAndInitialCapability(&roc_host, list_token, testHostValueI64List(&roc_host, &initial), section, cap);
            defer root.decref(&roc_host);
            var stream: HostNodeDescriptorStream = .{};
            host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
            _ = applyNodeDescriptorStream(&host, &roc_host, &stream);
            host.engine.active_stream = stream;

            const list_state_id = host.engine.active_stream.scope_sites.items[0].node_id;
            var when_buffer: [1]ids.NodeId = undefined;
            const when_id = activeScopeSiteNodeIdsOfKind(&host, .when, &when_buffer)[0];
            var each_buffer: [3]ids.NodeId = undefined;
            const eaches = activeScopeSiteNodeIdsOfKind(&host, .each, &each_buffer);
            try std.testing.expectEqual(@as(usize, 3), eaches.len);
            const shared_each_id = eaches[1];
            const trailing_each_id = eaches[2];
            try expectScopeSiteInsertIndex(&host, when_id, .when, 1);
            try expectScopeSiteInsertIndex(&host, shared_each_id, .each, 1);
            try expectScopeSiteInsertIndex(&host, trailing_each_id, .each, 3);

            const grown = [_]HostValue{ testHostValueI64(1), testHostValueI64(2), testHostValueI64(3), testHostValueI64(4) };
            const retry = [_]HostValue{ testHostValueI64(1), testHostValueI64(2), testHostValueI64(3), testHostValueI64(4) };
            const attempts = try dispatchStateValueSweeping(&host, &roc_host, list_state_id, testHostValueI64List(&roc_host, &grown), testHostValueI64List(&roc_host, &retry), cap, failure_number);
            try expectScopeSiteInsertIndex(&host, when_id, .when, 1);
            try expectScopeSiteInsertIndex(&host, shared_each_id, .each, 2);
            try expectScopeSiteInsertIndex(&host, trailing_each_id, .each, 6);
            try std.testing.expectEqual(@as(?usize, 1), streamOrderOfText(&host, "has-one"));
            try std.testing.expectEqual(@as(?usize, 2), streamOrderOfText(&host, "row-1-1"));
            try std.testing.expectEqual(@as(?usize, 5), streamOrderOfText(&host, "row-4-4"));
            try std.testing.expectEqual(@as(?usize, 6), streamOrderOfText(&host, "tail"));
            const section_id = host.engine.active_stream.elements.items[0].elem_id;
            try std.testing.expectEqual(@as(?usize, 0), childOrderOfText(&host, section_id, "has-one"));
            try std.testing.expectEqual(@as(?usize, 1), childOrderOfText(&host, section_id, "row-1-1"));
            try std.testing.expectEqual(@as(?usize, 4), childOrderOfText(&host, section_id, "row-4-4"));
            try std.testing.expectEqual(@as(?usize, 5), childOrderOfText(&host, section_id, "tail"));
            try std.testing.expectEqual(@as(usize, 6), host.engine.render_cache.nodes.items[section_id.index()].children.items.len);

            // Shrinking flips the branch back and drops rows in one transaction.
            const shrunk = [_]HostValue{testHostValueI64(3)};
            _ = try host.engine.tryDispatchStateValue(&host, &roc_host, list_state_id.raw(), testHostValueI64List(&roc_host, &shrunk), cap);
            try expectScopeSiteInsertIndex(&host, when_id, .when, 1);
            try expectScopeSiteInsertIndex(&host, shared_each_id, .each, 1);
            try expectScopeSiteInsertIndex(&host, trailing_each_id, .each, 2);
            try std.testing.expectEqual(@as(?usize, 1), streamOrderOfText(&host, "row-3-3"));
            try std.testing.expectEqual(@as(?usize, 2), streamOrderOfText(&host, "tail"));
            try std.testing.expect(activeTextElementId(&host, "has-one") == null);
            try std.testing.expectEqual(@as(?usize, 0), childOrderOfText(&host, section_id, "row-3-3"));
            try std.testing.expectEqual(@as(?usize, 1), childOrderOfText(&host, section_id, "tail"));
            try std.testing.expectEqual(@as(usize, 2), host.engine.render_cache.nodes.items[section_id.index()].children.items.len);
            return attempts;
        }
    };

    const attempts = try Runner.run(null);
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| _ = try Runner.run(failure_number);
}
test "an each reading a root state list through a bare ref mounts in one staged transaction and survives a live edit" {
    // A bare `Ref` record carries no signal token. The initial mount's graph
    // publication used to decide whether anything needed publishing from the
    // active graph (empty on a first mount) and the replacement stream's token
    // index, so a mount whose only signal was a bare `Ref` published no graph
    // node and no source route at all; the mount rendered, but the next state
    // dispatch found nothing dirty and the each never re-diffed. The edit is
    // the assertion, and every allocation attempt across mount and edit is
    // swept.
    const Runner = struct {
        fn run(failure_number: ?usize) !usize {
            test_erased_callable_drop_count = 0;
            test_row_elem_call_count = 0;
            var host = HostEnv.init();
            var roc_host = makeSignalsRocHost(&host);
            host.engine.roc_host = &roc_host;
            defer {
                host.deinit();
                _ = host.gpa.deinit();
            }

            const state_token = newTestBinderToken(&roc_host);
            const state_cap = testHostValueCapability(&roc_host);
            const each = testNodeEachWithSignalCapabilityAndRow(&roc_host, testNodeRefExpr(state_token), state_cap, &testStatefulRowElemCallable);
            const initial_items = [_]HostValue{ testHostValueI64(1), testHostValueI64(2) };
            const root = testNodeStateWithTokenAndInitialCapability(&roc_host, state_token, testHostValueI64List(&roc_host, &initial_items), testElement(&roc_host, &.{each}), state_cap);
            defer root.decref(&roc_host);
            const refs_before = host.roc_allocations.snapshot();

            var fault = FaultAllocator.init(host.gpa.allocator());
            fault.configure(failure_number);
            host.engine_allocator_override = fault.allocator();
            const mount = tryRenderInitialRootWithArmedPublication(&host, &roc_host, root, &fault);
            const mount_attempts = fault.attempts;
            if (failure_number != null and failure_number.? <= mount_attempts) {
                try std.testing.expectError(error.OutOfMemory, mount);
                try std.testing.expect(!host.engine.render_cache.hasRoot());
                try std.testing.expectEqual(@as(usize, 0), host.engine.states.items.len);
                try std.testing.expectEqual(@as(usize, 0), host.engine.each_row_sites.items.len);
                try std.testing.expectEqual(@as(usize, 0), host.roc_allocations.liveCountSince(refs_before));
                fault.configure(null);
                _ = try tryRenderInitialRootWithArmedPublication(&host, &roc_host, root, &fault);
            } else _ = try mount;
            // The root cell plus one state cell per stateful row.
            try std.testing.expectEqual(@as(usize, 3), host.engine.states.items.len);
            try std.testing.expectEqual(@as(usize, 1), host.engine.each_row_sites.items.len);
            try std.testing.expect(activeTextElementId(&host, "row-1-1") != null);
            try std.testing.expect(activeTextElementId(&host, "row-2-2") != null);

            const state_id = host.engine.active_stream.scope_sites.items[0].node_id;
            const site_node_id = for (host.engine.active_stream.scope_sites.items) |site| {
                if (site.kind == .each) break site.node_id;
            } else return error.TestUnexpectedResult;

            // The edit continues the sweep where the mount stopped counting; a
            // failure number inside the mount's range was already spent there.
            const edit_failure: ?usize = if (failure_number) |number| (if (number > mount_attempts) number - mount_attempts else null) else null;
            fault.configure(edit_failure);
            const scope_len_before = host.engine.scopes.items.len;
            const render_len_before = host.engine.active_stream.render_nodes.items.len;
            const allocations_before = host.roc_allocations.snapshot();
            const edited_items = [_]HostValue{ testHostValueI64(2), testHostValueI64(3), testHostValueI64(1) };
            const result = host.engine.tryDispatchStateValue(&host, &roc_host, state_id.raw(), testHostValueI64List(&roc_host, &edited_items), state_cap);
            const edit_attempts = fault.attempts;
            if (edit_failure != null) {
                try std.testing.expectError(error.OutOfMemory, result);
                try std.testing.expectEqual(scope_len_before, host.engine.scopes.items.len);
                try std.testing.expectEqual(render_len_before, host.engine.active_stream.render_nodes.items.len);
                try std.testing.expectEqual(@as(usize, 0), host.roc_allocations.liveCountSince(allocations_before));
                fault.configure(null);
                const retry_items = [_]HostValue{ testHostValueI64(2), testHostValueI64(3), testHostValueI64(1) };
                _ = try host.engine.tryDispatchStateValue(&host, &roc_host, state_id.raw(), testHostValueI64List(&roc_host, &retry_items), state_cap);
            } else _ = try result;

            const site = host.engine.activeScopeSiteByNodeId(site_node_id.raw(), .each).?;
            const rows = try host.engine.activeEachRowScopes(std.testing.allocator, site.scope_id, site.ordinal);
            defer std.testing.allocator.free(rows);
            try std.testing.expectEqual(@as(usize, 3), rows.len);
            const children = host.engine.render_cache.nodes.items[site.parent_elem_id.index()].children.items;
            try std.testing.expectEqual(@as(usize, 3), children.len);
            try std.testing.expectEqual(@as(usize, 4), host.engine.states.items.len);
            try std.testing.expect(activeTextElementId(&host, "row-1-1") != null);
            try std.testing.expect(activeTextElementId(&host, "row-2-2") != null);
            try std.testing.expect(activeTextElementId(&host, "row-3-3") != null);
            return mount_attempts + edit_attempts;
        }
    };

    const attempts = try Runner.run(null);
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| _ = try Runner.run(failure_number);
}

test "changing a row item keeps its rendered nodes and diffs their fields" {
    // A row whose key survives but whose item changed is re-collected by the
    // row builder, and the re-collected subtree claims the same element ids
    // under the same tags. The render splice used to journal that as a
    // remove/recreate pair per node, so the host rebuilt the row's DOM (and
    // dropped focus, pending input, and listeners) for what is a scalar
    // change. The nodes must stay in place and only changed fields may emit.
    const Runner = struct {
        fn run(failure_number: ?usize) !usize {
            test_erased_callable_drop_count = 0;
            test_row_elem_call_count = 0;
            var host = HostEnv.init();
            var roc_host = makeSignalsRocHost(&host);
            host.engine.roc_host = &roc_host;
            defer {
                host.deinit();
                _ = host.gpa.deinit();
            }

            const state_token = newTestBinderToken(&roc_host);
            const state_cap = testHostValueCapability(&roc_host);
            // Keys are item / 100, so 202 and 250 are the same row.
            const each = testNodeEachWithSignalCapabilityKeyOfRowAndCapture(TestErasedI64Capture, &roc_host, testNodeRefExpr(state_token), state_cap, &testBucketKeyHostValueCallable, .{ .amount = 100 }, &testStatefulRowElemCallable, .{ .amount = 0 });
            const section = testElementWith(&roc_host, "section", &.{}, &.{each});
            const initial_items = [_]HostValue{ testHostValueI64(101), testHostValueI64(202), testHostValueI64(303) };
            const root = testNodeStateWithTokenAndInitialCapability(&roc_host, state_token, testHostValueI64List(&roc_host, &initial_items), section, state_cap);
            defer root.decref(&roc_host);
            var stream: HostNodeDescriptorStream = .{};
            host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
            _ = applyNodeDescriptorStream(&host, &roc_host, &stream);
            host.engine.active_stream = stream;

            const state_id = host.engine.active_stream.scope_sites.items[0].node_id;
            const row_2_id = activeTextElementId(&host, "row-2-202") orelse return error.TestUnexpectedResult;
            const text_updates_before = host.dom_elements.items[@intCast(row_2_id)].text_update_count;
            const render_before = host.engine.render_metrics;
            const rows_before = host.engine.pending_roc_metrics;
            var row_calls_before = test_row_elem_call_count;
            const scope_len_before = host.engine.scopes.items.len;
            const allocations_before = host.roc_allocations.snapshot();

            const next_items = [_]HostValue{ testHostValueI64(101), testHostValueI64(250), testHostValueI64(303) };
            var fault = FaultAllocator.init(host.gpa.allocator());
            fault.configure(failure_number);
            host.engine_allocator_override = fault.allocator();
            const result = host.engine.tryDispatchStateValue(&host, &roc_host, state_id.raw(), testHostValueI64List(&roc_host, &next_items), state_cap);
            const attempts = fault.attempts;
            if (failure_number != null) {
                try std.testing.expectError(error.OutOfMemory, result);
                try std.testing.expectEqual(scope_len_before, host.engine.scopes.items.len);
                try std.testing.expectEqual(row_2_id, activeTextElementId(&host, "row-2-202") orelse return error.TestUnexpectedResult);
                try std.testing.expectEqual(@as(usize, 0), host.roc_allocations.liveCountSince(allocations_before));
                fault.configure(null);
                row_calls_before = test_row_elem_call_count;
                const retry_items = [_]HostValue{ testHostValueI64(101), testHostValueI64(250), testHostValueI64(303) };
                _ = try host.engine.tryDispatchStateValue(&host, &roc_host, state_id.raw(), testHostValueI64List(&roc_host, &retry_items), state_cap);
            } else _ = try result;

            // The row builder ran once, for the changed row only.
            try std.testing.expectEqual(row_calls_before + 1, test_row_elem_call_count);
            try std.testing.expectEqual(@as(u64, 3), host.engine.pending_roc_metrics.rows_reused - rows_before.rows_reused);
            try std.testing.expectEqual(@as(u64, 0), host.engine.pending_roc_metrics.rows_created - rows_before.rows_created);
            try std.testing.expectEqual(@as(u64, 0), host.engine.pending_roc_metrics.rows_removed - rows_before.rows_removed);
            // Same text node, one text update, nothing created or removed.
            try std.testing.expectEqual(row_2_id, activeTextElementId(&host, "row-2-250") orelse return error.TestUnexpectedResult);
            try std.testing.expectEqual(text_updates_before + 1, host.dom_elements.items[@intCast(row_2_id)].text_update_count);
            try std.testing.expectEqual(@as(u64, 0), host.engine.render_metrics.create_element - render_before.create_element);
            try std.testing.expectEqual(@as(u64, 0), host.engine.render_metrics.remove_node - render_before.remove_node);
            try std.testing.expectEqual(@as(u64, 0), host.engine.render_metrics.move_before - render_before.move_before);
            try std.testing.expectEqual(@as(u64, 1), host.engine.render_metrics.set_text - render_before.set_text);
            try std.testing.expectEqual(@as(u64, 1), host.engine.render_metrics.patches_emitted - render_before.patches_emitted);
            try std.testing.expect(activeTextElementId(&host, "row-1-101") != null);
            try std.testing.expect(activeTextElementId(&host, "row-3-303") != null);
            return attempts;
        }
    };

    const attempts = try Runner.run(null);
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| _ = try Runner.run(failure_number);
}

test "retiring an each row disposes the nested each site it owned" {
    // The row sync removes an outer row's own membership, but the row may own a
    // nested each site with rows of its own in `each_row_sites`. Those used to
    // survive the row: the nested site's descriptor was gone, yet the site and
    // its rows stayed registered, so the engine's site count drifted above the
    // structure it rendered on every removal.
    const Runner = struct {
        fn run(failure_number: ?usize) !usize {
            test_erased_callable_drop_count = 0;
            test_row_elem_call_count = 0;
            var host = HostEnv.init();
            var roc_host = makeSignalsRocHost(&host);
            host.engine.roc_host = &roc_host;
            defer {
                host.deinit();
                _ = host.gpa.deinit();
            }

            const state_token = newTestBinderToken(&roc_host);
            const state_cap = testHostValueCapability(&roc_host);
            const outer = testNodeEachWithSignalCapabilityAndRow(&roc_host, testNodeRefExpr(state_token), state_cap, &testNestedEachRowElemCallable);
            const section = testElementWith(&roc_host, "section", &.{}, &.{outer});
            const initial_items = [_]HostValue{ testHostValueI64(1), testHostValueI64(2) };
            const root = testNodeStateWithTokenAndInitialCapability(&roc_host, state_token, testHostValueI64List(&roc_host, &initial_items), section, state_cap);
            defer root.decref(&roc_host);
            var stream: HostNodeDescriptorStream = .{};
            host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
            _ = applyNodeDescriptorStream(&host, &roc_host, &stream);
            host.engine.active_stream = stream;

            const state_id = host.engine.active_stream.scope_sites.items[0].node_id;
            // The outer site plus one nested site per outer row.
            try std.testing.expectEqual(@as(usize, 3), host.engine.each_row_sites.items.len);
            try std.testing.expect(activeTextElementId(&host, "outer-1") != null);
            try std.testing.expect(activeTextElementId(&host, "outer-2") != null);

            const scope_len_before = host.engine.scopes.items.len;
            const render_len_before = host.engine.active_stream.render_nodes.items.len;
            const allocations_before = host.roc_allocations.snapshot();
            const next_items = [_]HostValue{testHostValueI64(2)};
            var fault = FaultAllocator.init(host.gpa.allocator());
            fault.configure(failure_number);
            host.engine_allocator_override = fault.allocator();
            const result = host.engine.tryDispatchStateValue(&host, &roc_host, state_id.raw(), testHostValueI64List(&roc_host, &next_items), state_cap);
            const attempts = fault.attempts;
            if (failure_number != null) {
                try std.testing.expectError(error.OutOfMemory, result);
                try std.testing.expectEqual(scope_len_before, host.engine.scopes.items.len);
                try std.testing.expectEqual(render_len_before, host.engine.active_stream.render_nodes.items.len);
                try std.testing.expectEqual(@as(usize, 3), host.engine.each_row_sites.items.len);
                try std.testing.expectEqual(@as(usize, 0), host.roc_allocations.liveCountSince(allocations_before));
                fault.configure(null);
                const retry_items = [_]HostValue{testHostValueI64(2)};
                _ = try host.engine.tryDispatchStateValue(&host, &roc_host, state_id.raw(), testHostValueI64List(&roc_host, &retry_items), state_cap);
            } else _ = try result;

            // The retired row's nested site is gone with it: outer plus one.
            try std.testing.expectEqual(@as(usize, 2), host.engine.each_row_sites.items.len);
            for (host.engine.each_row_sites.items) |site| {
                try std.testing.expect(host.engine.scopes.items[site.key.parent_scope_id.index()].lifecycle.isActive());
            }
            try std.testing.expect(activeTextElementId(&host, "outer-1") == null);
            try std.testing.expect(activeTextElementId(&host, "outer-2") != null);
            return attempts;
        }
    };

    const attempts = try Runner.run(null);
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| _ = try Runner.run(failure_number);
}

test "growing an empty each whose rows nest stateful each rows reserves every state index" {
    // Each nested reservation used to size the state index table to the
    // committed identities plus the intents issued so far plus its own sites,
    // while the outer reservation's sites were still outstanding. A sibling
    // site whose stateful rows are collected after the nested ones claims
    // those outstanding identities, so its state cells landed past the
    // reserved capacity and publication - which must not allocate - tripped
    // the capacity assertion instead.
    const Runner = struct {
        fn run(failure_number: ?usize) !usize {
            test_erased_callable_drop_count = 0;
            test_row_elem_call_count = 0;
            var host = HostEnv.init();
            var roc_host = makeSignalsRocHost(&host);
            host.engine.roc_host = &roc_host;
            defer {
                host.deinit();
                _ = host.gpa.deinit();
            }

            const state_token = newTestBinderToken(&roc_host);
            const state_cap = testHostValueCapability(&roc_host);
            const outer = testNodeEachWithSignalCapabilityAndRow(&roc_host, testNodeRefExpr(state_token), state_cap, &testNestedStatefulEachRowElemCallable);
            const sibling = testNodeEachWithSignalCapabilityAndRow(&roc_host, testNodeRefExpr(state_token), state_cap, &testStatefulRowElemCallable);
            const section = testElementWith(&roc_host, "section", &.{}, &.{ outer, sibling });
            const root = testNodeStateWithTokenAndInitialCapability(&roc_host, state_token, testHostValueI64List(&roc_host, &.{}), section, state_cap);
            defer root.decref(&roc_host);
            var stream: HostNodeDescriptorStream = .{};
            host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
            _ = applyNodeDescriptorStream(&host, &roc_host, &stream);
            host.engine.active_stream = stream;

            const state_id = host.engine.active_stream.scope_sites.items[0].node_id;
            try std.testing.expectEqual(@as(usize, 2), host.engine.each_row_sites.items.len);
            try std.testing.expectEqual(@as(usize, 1), host.engine.states.items.len);

            const scope_len_before = host.engine.scopes.items.len;
            const render_len_before = host.engine.active_stream.render_nodes.items.len;
            const allocations_before = host.roc_allocations.snapshot();
            const grown_items = [_]HostValue{ testHostValueI64(1), testHostValueI64(2), testHostValueI64(3), testHostValueI64(4), testHostValueI64(5), testHostValueI64(6) };
            var fault = FaultAllocator.init(host.gpa.allocator());
            fault.configure(failure_number);
            host.engine_allocator_override = fault.allocator();
            const result = host.engine.tryDispatchStateValue(&host, &roc_host, state_id.raw(), testHostValueI64List(&roc_host, &grown_items), state_cap);
            const attempts = fault.attempts;
            if (failure_number != null) {
                try std.testing.expectError(error.OutOfMemory, result);
                try std.testing.expectEqual(scope_len_before, host.engine.scopes.items.len);
                try std.testing.expectEqual(render_len_before, host.engine.active_stream.render_nodes.items.len);
                try std.testing.expectEqual(@as(usize, 1), host.engine.states.items.len);
                try std.testing.expectEqual(@as(usize, 0), host.roc_allocations.liveCountSince(allocations_before));
                fault.configure(null);
                const retry_items = [_]HostValue{ testHostValueI64(1), testHostValueI64(2), testHostValueI64(3), testHostValueI64(4), testHostValueI64(5), testHostValueI64(6) };
                _ = try host.engine.tryDispatchStateValue(&host, &roc_host, state_id.raw(), testHostValueI64List(&roc_host, &retry_items), state_cap);
            } else _ = try result;

            // The root cell, one cell per nested row (six rows of three), and
            // one per sibling row.
            try std.testing.expectEqual(@as(usize, 1 + 6 * 3 + 6), host.engine.states.items.len);
            try std.testing.expectEqual(@as(usize, 2 + 6), host.engine.each_row_sites.items.len);
            for (host.engine.states.items, 0..) |state, index| {
                try std.testing.expectEqual(@as(?usize, index), host.engine.stateIndexByNodeId(state.state_id));
            }
            try std.testing.expect(activeTextElementId(&host, "outer-6") != null);
            try std.testing.expect(activeTextElementId(&host, "row-6-6") != null);
            return attempts;
        }
    };

    const attempts = try Runner.run(null);
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| _ = try Runner.run(failure_number);
}

test "one state transaction retires nested each with when atomically through production" {
    const Runner = struct {
        fn run(failure_number: ?usize) !usize {
            var host = HostEnv.init();
            var roc_host = makeSignalsRocHost(&host);
            host.engine.roc_host = &roc_host;
            defer {
                host.deinit();
                _ = host.gpa.deinit();
            }

            const state_token = newTestBinderToken(&roc_host);
            const state_cap = testHostValueCapability(&roc_host);
            const each = testNodeEachWithSignalCapabilityAndRow(&roc_host, testNodeRefExpr(state_token), state_cap, &testStatefulRowElemCallable);
            const when = testNodeWhenWithSignal(&roc_host, testNodeListContainsOneExpr(&roc_host, testNodeRefExpr(state_token)), each, testNodeText(&roc_host, "mixed-false"));
            const section = testElementWith(&roc_host, "section", &.{}, &.{ when, testNodeText(&roc_host, "mixed-after") });
            const initial_items = [_]HostValue{ testHostValueI64(1), testHostValueI64(2) };
            const root = testNodeStateWithTokenAndInitialCapability(&roc_host, state_token, testHostValueI64ListWithCapability(&roc_host, &initial_items, state_cap), section, state_cap);
            defer root.decref(&roc_host);
            var stream: HostNodeDescriptorStream = .{};
            host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
            _ = applyNodeDescriptorStream(&host, &roc_host, &stream);
            host.engine.active_stream = stream;

            const state_id = host.engine.active_stream.scope_sites.items[0].node_id;
            const state_index = host.engine.stateIndexByNodeId(state_id.raw()).?;
            var each_site: ?engine.HostNodeScopeSiteDesc = null;
            for (host.engine.active_stream.scope_sites.items) |site| {
                if (site.kind == .each) each_site = site;
            }
            const rows_before = try host.engine.activeEachRowScopes(std.testing.allocator, each_site.?.scope_id, each_site.?.ordinal);
            defer std.testing.allocator.free(rows_before);
            const generation_before = host.engine.dirty_signal_generation;
            const graph_len_before = host.engine.active_signal_graph.items.len;
            const scope_len_before = host.engine.scopes.items.len;
            const render_len_before = host.engine.active_stream.render_nodes.items.len;
            const dom_len_before = host.dom_elements.items.len;
            const state_value_before = host.engine.states.items[state_index].activePayloadConst().cell.value;
            const batches_before = host.engine.dispatch_metrics.recompute_batches;
            const root_children_before = try std.testing.allocator.dupe(ids.ElemId, host.engine.render_cache.nodes.items[1].children.items);
            defer std.testing.allocator.free(root_children_before);
            const allocations_before = host.roc_allocations.snapshot();

            const next_items = [_]HostValue{ testHostValueI64(2), testHostValueI64(3) };
            var fault = FaultAllocator.init(host.gpa.allocator());
            fault.configure(failure_number);
            host.engine_allocator_override = fault.allocator();
            const result = host.engine.tryDispatchStateValue(&host, &roc_host, state_id.raw(), testHostValueI64ListWithCapability(&roc_host, &next_items, state_cap), state_cap);
            const attempts = fault.attempts;
            if (failure_number != null) {
                try std.testing.expectError(error.OutOfMemory, result);
                try std.testing.expectEqual(generation_before, host.engine.dirty_signal_generation);
                try std.testing.expectEqual(graph_len_before, host.engine.active_signal_graph.items.len);
                try std.testing.expectEqual(scope_len_before, host.engine.scopes.items.len);
                try std.testing.expectEqual(render_len_before, host.engine.active_stream.render_nodes.items.len);
                try std.testing.expectEqual(dom_len_before, host.dom_elements.items.len);
                try std.testing.expectEqual(state_value_before, host.engine.states.items[state_index].activePayloadConst().cell.value);
                try std.testing.expectEqualSlices(ids.ElemId, root_children_before, host.engine.render_cache.nodes.items[1].children.items);
                const rows_after_failure = try host.engine.activeEachRowScopes(std.testing.allocator, each_site.?.scope_id, each_site.?.ordinal);
                defer std.testing.allocator.free(rows_after_failure);
                try std.testing.expectEqualSlices(ids.ScopeId, rows_before, rows_after_failure);
                try std.testing.expectEqual(@as(usize, 0), host.roc_allocations.liveCountSince(allocations_before));
                try std.testing.expect(activeTextElementId(&host, "mixed-false") == null);
                try std.testing.expect(activeTextElementId(&host, "mixed-after") != null);
                try std.testing.expect(activeTextElementId(&host, "row-1-1") != null);
                try std.testing.expect(activeTextElementId(&host, "row-2-2") != null);
                fault.configure(null);
                const retry_items = [_]HostValue{ testHostValueI64(2), testHostValueI64(3) };
                _ = try host.engine.tryDispatchStateValue(&host, &roc_host, state_id.raw(), testHostValueI64ListWithCapability(&roc_host, &retry_items, state_cap), state_cap);
            } else _ = try result;

            try std.testing.expectEqual(batches_before + 1, host.engine.dispatch_metrics.recompute_batches);
            try std.testing.expect(activeTextElementId(&host, "mixed-false") != null);
            try std.testing.expect(activeTextElementId(&host, "mixed-after") != null);
            try std.testing.expect(activeTextElementId(&host, "row-1-1") == null);
            try std.testing.expect(activeTextElementId(&host, "row-2-2") == null);
            try std.testing.expect(activeTextElementId(&host, "row-3-3") == null);
            return attempts;
        }
    };

    const attempts = try Runner.run(null);
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| _ = try Runner.run(failure_number);
}

test "event state transaction sweeps host OOM and retries without mutation" {
    const Runner = struct {
        fn run(failure_number: ?usize) !usize {
            var host = HostEnv.init();
            var roc_host = makeSignalsRocHost(&host);
            host.engine.roc_host = &roc_host;
            defer {
                host.deinit();
                _ = host.gpa.deinit();
            }
            const token = newTestBinderToken(&roc_host);
            const state_cap = testHostValueCapability(&roc_host);
            const child = abi.Elem{ .payload = .{ .text_signal = .{
                .read = testI64TextReadHandle(&roc_host, state_cap),
                .signal = boxTestNodeSignalExpr(&roc_host, testNodeRefExpr(token)),
            } }, .tag = .TextSignal };
            const root = testNodeStateWithTokenAndInitialCapability(&roc_host, token, testHostValueI64(1), child, state_cap);
            defer root.decref(&roc_host);
            var stream: HostNodeDescriptorStream = .{};
            host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
            _ = applyNodeDescriptorStream(&host, &roc_host, &stream);
            host.engine.active_stream = stream;
            const state_id = host.engine.active_stream.scope_sites.items[0].node_id;
            const state_index = host.engine.stateIndexByNodeId(state_id.raw()).?;
            const state_value_before = host.engine.states.items[state_index].activePayloadConst().cell.value;
            const state_version_before = host.engine.states.items[state_index].activePayloadConst().version;
            const generation_before = host.engine.dirty_signal_generation;
            const graph_len_before = host.engine.active_signal_graph.items.len;
            const dom_len_before = host.dom_elements.items.len;
            const allocations_before = host.roc_allocations.snapshot();

            const next = testHostValueI64(2);
            var fault = FaultAllocator.init(host.gpa.allocator());
            fault.configure(failure_number);
            host.engine_allocator_override = fault.allocator();
            const result = host.engine.tryDispatchStateValue(&host, &roc_host, state_id.raw(), next, state_cap);
            const attempts = fault.attempts;
            if (failure_number != null) {
                try std.testing.expectError(error.OutOfMemory, result);
                try std.testing.expectEqual(@as(usize, 1), fault.induced_failures);
                try std.testing.expectEqual(state_value_before, host.engine.states.items[state_index].activePayloadConst().cell.value);
                try std.testing.expectEqual(state_version_before, host.engine.states.items[state_index].activePayloadConst().version);
                try std.testing.expectEqual(generation_before, host.engine.dirty_signal_generation);
                try std.testing.expectEqual(graph_len_before, host.engine.active_signal_graph.items.len);
                try std.testing.expectEqual(dom_len_before, host.dom_elements.items.len);
                try std.testing.expectEqualStrings("1", host.dom_elements.items[1].text.?);
                try std.testing.expectEqual(@as(usize, 0), host.roc_allocations.liveCountSince(allocations_before));
                fault.configure(null);
                _ = try host.engine.tryDispatchStateValue(&host, &roc_host, state_id.raw(), testHostValueI64(2), state_cap);
            } else {
                _ = try result;
            }
            try std.testing.expectEqual(state_version_before + 1, host.engine.states.items[state_index].activePayloadConst().version);
            try std.testing.expectEqualStrings("2", host.dom_elements.items[1].text.?);
            return attempts;
        }
    };

    const attempts = try Runner.run(null);
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| _ = try Runner.run(failure_number);
}

test "a scalar state transaction folds its commands into the render metrics" {
    // PreparedSourceTransaction.commit records published command counts in
    // `render_metrics` on every structural branch, but the scalar branch (a
    // dirty text sink and nothing structural) published its set_text without
    // recording it, so `patches_emitted` stayed flat while the DOM changed.
    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }
    const token = newTestBinderToken(&roc_host);
    const state_cap = testHostValueCapability(&roc_host);
    const child = abi.Elem{ .payload = .{ .text_signal = .{
        .read = testI64TextReadHandle(&roc_host, state_cap),
        .signal = boxTestNodeSignalExpr(&roc_host, testNodeRefExpr(token)),
    } }, .tag = .TextSignal };
    const root = testNodeStateWithTokenAndInitialCapability(&roc_host, token, testHostValueI64(1), child, state_cap);
    defer root.decref(&roc_host);
    _ = try tryRenderInitialRoot(&host, &roc_host, root, &.{});
    const state_id = host.engine.active_stream.scope_sites.items[0].node_id;
    const metrics_before = host.engine.render_metrics;

    const counts = try host.engine.tryDispatchStateValue(&host, &roc_host, state_id.raw(), testHostValueI64(2), state_cap);

    try std.testing.expectEqualStrings("2", host.dom_elements.items[1].text.?);
    try std.testing.expectEqual(@as(u64, 1), counts.set_text);
    try std.testing.expectEqual(@as(u64, 1), counts.total);
    try std.testing.expectEqual(metrics_before.patches_emitted + 1, host.engine.render_metrics.patches_emitted);
    try std.testing.expectEqual(metrics_before.set_text + 1, host.engine.render_metrics.set_text);
}

test "signals host reuses active signal records while collecting dirty when branch" {
    test_erased_callable_drop_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    const state_token = newTestBinderToken(&roc_host);
    const ready = testNodeBoolIdentityMapExpr(&roc_host, testNodeRefExpr(state_token));
    ready.incref(1);
    const label = testNodeStableStrMapExpr(&roc_host, ready);
    const ready_cap = testNodeSignalExprCapabilityOrPanic(ready);
    const when_elem: abi.Elem = .{
        .payload = .{
            .when = .{
                .condition = boxTestNodeSignalExpr(&roc_host, ready),
                .read = testBoolReadHandle(&roc_host, ready_cap),
                .when_false = boxTestElem(&roc_host, testNodeText(&roc_host, "loading")),
                .when_true = boxTestElem(&roc_host, testNodeTextSignal(&roc_host, label)),
            },
        },
        .tag = .When,
    };
    const root = testNodeStateWithTokenAndInitial(&roc_host, state_token, testHostValueBool(false), when_elem);
    defer root.decref(&roc_host);

    var stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
    _ = applyNodeDescriptorStream(&host, &roc_host, &stream);
    host.engine.active_stream = stream;

    try std.testing.expect(activeTextElementId(&host, "loading") != null);
    try std.testing.expect(activeTextElementId(&host, "stable") == null);

    const state_id = host.engine.active_stream.scope_sites.items[0].node_id;
    const state_index = host.engine.stateIndexByNodeId(state_id.raw()) orelse unreachable;
    testDropHostValue(&roc_host, host.engine.states.items[state_index].activePayload().cell.value);
    host.engine.states.items[state_index].activePayload().cell.value = testHostValueBool(true);
    host.engine.states.items[state_index].activePayload().version += 1;

    const dirty_source_node_ids = [_]u64{state_id.raw()};
    const dirty_generation = host.nextDirtySignalGeneration();
    const changed_record_ids = propagateDirtyActiveSignals(&host, &roc_host, host.hostAllocator(), &dirty_source_node_ids, dirty_generation);
    const dirty_structural_signals = collectDirtyStructuralSignals(&host, &roc_host, host.hostAllocator(), &dirty_source_node_ids, changed_record_ids, dirty_generation);
    defer host.hostAllocator().free(dirty_structural_signals);
    try std.testing.expectEqual(@as(usize, 1), dirty_structural_signals.len);
    try std.testing.expectEqual(HostActiveStructuralSignalKind.when, dirty_structural_signals[0].kind);

    _ = applyDirtyWhenStructuralSignals(&host, &roc_host, &dirty_source_node_ids, dirty_generation, dirty_structural_signals);

    try std.testing.expect(dirty_structural_signals[0].pending_when_cache == null);
    try std.testing.expect(activeTextElementId(&host, "loading") == null);
    try std.testing.expect(activeTextElementId(&host, "stable") != null);
}

test "signals host prunes structural render when retained condition equality is unchanged" {
    test_erased_callable_drop_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    const state_token = newTestBinderToken(&roc_host);
    const condition = testNodeStableBoolMapExpr(&roc_host, testNodeRefExpr(state_token));
    const condition_cap = testNodeSignalExprCapabilityOrPanic(condition);
    const when_elem: abi.Elem = .{
        .payload = .{
            .when = .{
                .condition = boxTestNodeSignalExpr(&roc_host, condition),
                .read = testBoolReadHandle(&roc_host, condition_cap),
                .when_false = boxTestElem(&roc_host, testNodeText(&roc_host, "false branch")),
                .when_true = boxTestElem(&roc_host, testNodeText(&roc_host, "true branch")),
            },
        },
        .tag = .When,
    };
    const root = testNodeStateWithTokenAndInitial(&roc_host, state_token, testHostValueI64(1), when_elem);
    defer root.decref(&roc_host);

    var stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
    _ = applyNodeDescriptorStream(&host, &roc_host, &stream);
    host.engine.active_stream = stream;

    try std.testing.expect(activeTextElementId(&host, "true branch") != null);

    const state_id = host.engine.active_stream.scope_sites.items[0].node_id;
    const state_index = host.engine.stateIndexByNodeId(state_id.raw()) orelse unreachable;
    testDropHostValue(&roc_host, host.engine.states.items[state_index].activePayload().cell.value);
    host.engine.states.items[state_index].activePayload().cell.value = testHostValueI64(2);
    host.engine.states.items[state_index].activePayload().version += 1;

    const dirty_source_node_ids = [_]u64{state_id.raw()};
    const prune_start = host.engine.pending_roc_metrics.propagation_prunes;

    const dirty_generation = host.nextDirtySignalGeneration();
    const changed_record_ids = propagateDirtyActiveSignals(&host, &roc_host, host.hostAllocator(), &dirty_source_node_ids, dirty_generation);
    const dirty_structural_signals = collectDirtyStructuralSignals(&host, &roc_host, host.hostAllocator(), &dirty_source_node_ids, changed_record_ids, dirty_generation);
    defer host.hostAllocator().free(dirty_structural_signals);
    try std.testing.expectEqual(@as(usize, 0), dirty_structural_signals.len);
    try std.testing.expectEqual(prune_start + 1, host.engine.pending_roc_metrics.propagation_prunes);
    try std.testing.expect(activeTextElementId(&host, "true branch") != null);
    try std.testing.expect(activeTextElementId(&host, "false branch") == null);
}

test "signals host structural patch reorders keyed row DOM without recreating survivors" {
    test_erased_callable_drop_count = 0;
    test_row_elem_call_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    const initial_items = [_]HostValue{ testHostValueI64(1), testHostValueI64(2), testHostValueI64(3) };
    const initial_children = [_]abi.Elem{
        testNodeEachWithItems(&roc_host, &initial_items),
    };
    const initial_root = testElementWith(&roc_host, "section", &.{}, &initial_children);
    defer initial_root.decref(&roc_host);

    var initial_stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &initial_stream, initial_root, &.{});
    const initial_counts = applyNodeDescriptorStream(&host, &roc_host, &initial_stream);
    host.engine.active_stream = initial_stream;

    try std.testing.expectEqual(@as(u64, 3), test_row_elem_call_count);
    try std.testing.expectEqual(@as(u64, 1), initial_counts.reset_dom);
    try std.testing.expectEqual(@as(u64, 4), initial_counts.create_element);
    try std.testing.expectEqual(@as(usize, 5), host.dom_elements.items.len);

    const section_id = host.engine.active_stream.elements.items[0].elem_id;
    const row_1_id = activeTextElementId(&host, "row-1-1") orelse unreachable;
    const row_2_id = activeTextElementId(&host, "row-2-2") orelse unreachable;
    const row_3_id = activeTextElementId(&host, "row-3-3") orelse unreachable;
    try std.testing.expectEqualSlices(u64, &.{ row_1_id, row_2_id, row_3_id }, host.dom_elements.items[@intCast(section_id.raw())].children.items);

    const reordered_items = [_]HostValue{ testHostValueI64(3), testHostValueI64(1), testHostValueI64(2) };
    const reordered_children = [_]abi.Elem{
        testNodeEachWithItems(&roc_host, &reordered_items),
    };
    const reordered_root = testElementWith(&roc_host, "section", &.{}, &reordered_children);
    defer reordered_root.decref(&roc_host);

    var reordered_stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &reordered_stream, reordered_root, &.{});
    const patch_counts = applyStructuralNodeDescriptorStream(&host, &roc_host, &reordered_stream);
    host.engine.active_stream.deinit(host.hostAllocator(), &host, &roc_host, &host.engine.pending_roc_metrics);
    host.engine.active_stream = reordered_stream;

    try std.testing.expectEqual(@as(u64, 3), test_row_elem_call_count);
    try std.testing.expectEqual(@as(u64, 0), patch_counts.reset_dom);
    try std.testing.expectEqual(@as(u64, 0), patch_counts.create_element);
    try std.testing.expectEqual(@as(u64, 0), patch_counts.append_child);
    try std.testing.expectEqual(@as(u64, 0), patch_counts.remove_node);
    try std.testing.expect(patch_counts.move_before >= 2);
    try std.testing.expectEqual(@as(usize, 5), host.dom_elements.items.len);
    try std.testing.expectEqual(row_1_id, activeTextElementId(&host, "row-1-1") orelse unreachable);
    try std.testing.expectEqual(row_2_id, activeTextElementId(&host, "row-2-2") orelse unreachable);
    try std.testing.expectEqual(row_3_id, activeTextElementId(&host, "row-3-3") orelse unreachable);
    try std.testing.expectEqualSlices(u64, &.{ row_3_id, row_1_id, row_2_id }, host.dom_elements.items[@intCast(section_id.raw())].children.items);

    const changed_items = [_]HostValue{ testHostValueI64(2), testHostValueI64(4) };
    const changed_children = [_]abi.Elem{
        testNodeEachWithItems(&roc_host, &changed_items),
    };
    const changed_root = testElementWith(&roc_host, "section", &.{}, &changed_children);
    defer changed_root.decref(&roc_host);

    var changed_stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &changed_stream, changed_root, &.{});
    const changed_counts = applyStructuralNodeDescriptorStream(&host, &roc_host, &changed_stream);
    host.engine.active_stream.deinit(host.hostAllocator(), &host, &roc_host, &host.engine.pending_roc_metrics);
    host.engine.active_stream = changed_stream;

    try std.testing.expectEqual(@as(u64, 4), test_row_elem_call_count);
    const row_4_id = activeTextElementId(&host, "row-4-4") orelse unreachable;
    try std.testing.expectEqual(@as(u64, 0), changed_counts.reset_dom);
    try std.testing.expectEqual(@as(u64, 1), changed_counts.create_element);
    try std.testing.expectEqual(@as(u64, 1), changed_counts.append_child);
    try std.testing.expectEqual(@as(u64, 2), changed_counts.remove_node);
    try std.testing.expectEqual(@as(u64, 1), changed_counts.set_text);
    try std.testing.expectEqual(@as(u64, 5), changed_counts.total);
    try std.testing.expectEqual(row_2_id, activeTextElementId(&host, "row-2-2") orelse unreachable);
    try std.testing.expect(activeTextElementId(&host, "row-1-1") == null);
    try std.testing.expect(activeTextElementId(&host, "row-3-3") == null);
    try std.testing.expectEqualSlices(u64, &.{ row_2_id, row_4_id }, host.dom_elements.items[@intCast(section_id.raw())].children.items);
}

test "signals host dirty each append patches only changed row" {
    test_erased_callable_drop_count = 0;
    test_row_elem_call_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    const row_count = 24;
    const state_token = newTestBinderToken(&roc_host);
    const state_cap = testHostValueCapability(&roc_host);
    const each = testNodeEachWithSignalCapabilityAndRow(&roc_host, testNodeRefExpr(state_token), state_cap, &testStatefulRowElemCallable);
    const children = [_]abi.Elem{each};
    const section = testElementWith(&roc_host, "section", &.{}, &children);

    var initial_items: [row_count]HostValue = undefined;
    for (&initial_items, 0..) |*item, index| {
        item.* = testHostValueI64(@intCast(index + 1));
    }
    const root = testNodeStateWithTokenAndInitialCapability(&roc_host, state_token, testHostValueI64List(&roc_host, &initial_items), section, state_cap);
    defer root.decref(&roc_host);

    var initial_stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &initial_stream, root, &.{});
    _ = applyNodeDescriptorStream(&host, &roc_host, &initial_stream);
    host.engine.active_stream = initial_stream;

    try std.testing.expectEqual(@as(u64, row_count), test_row_elem_call_count);
    try std.testing.expect(activeTextElementId(&host, "row-24-24") != null);

    const state_id = host.engine.active_stream.scope_sites.items[0].node_id;
    const state_index = host.engine.stateIndexByNodeId(state_id.raw()) orelse unreachable;

    var next_items: [row_count + 1]HostValue = undefined;
    for (&next_items, 0..) |*item, index| {
        item.* = testHostValueI64(@intCast(index + 1));
    }
    testDropHostValue(&roc_host, host.engine.states.items[state_index].activePayload().cell.value);
    host.engine.states.items[state_index].activePayload().cell.value = testHostValueI64List(&roc_host, &next_items);
    host.engine.states.items[state_index].activePayload().version += 1;

    const dirty_source_node_ids = [_]u64{state_id.raw()};
    const dirty_generation = host.nextDirtySignalGeneration();
    const changed_record_ids = propagateDirtyActiveSignals(&host, &roc_host, host.hostAllocator(), &dirty_source_node_ids, dirty_generation);
    const dirty_structural_signals = collectDirtyStructuralSignals(&host, &roc_host, host.hostAllocator(), &dirty_source_node_ids, changed_record_ids, dirty_generation);
    defer host.hostAllocator().free(dirty_structural_signals);

    try std.testing.expectEqual(@as(usize, 1), dirty_structural_signals.len);
    try std.testing.expectEqual(HostActiveStructuralSignalKind.each, dirty_structural_signals[0].kind);

    const rows_reused_start = host.engine.pending_roc_metrics.rows_reused;
    const rows_created_start = host.engine.pending_roc_metrics.rows_created;
    const rows_removed_start = host.engine.pending_roc_metrics.rows_removed;
    const row_call_start = test_row_elem_call_count;
    const patch_start = host.engine.render_metrics.patches_emitted;
    const graph_rebuild_start = host.engine.pending_roc_metrics.active_graph_records_rebuilt;

    const patch_counts = applyDirtyStructuralSignalsLocally(&host, &roc_host, &dirty_source_node_ids, dirty_generation, dirty_structural_signals);

    try std.testing.expectEqual(@as(u64, row_count), host.engine.pending_roc_metrics.rows_reused - rows_reused_start);
    try std.testing.expectEqual(@as(u64, 1), host.engine.pending_roc_metrics.rows_created - rows_created_start);
    try std.testing.expectEqual(@as(u64, 0), host.engine.pending_roc_metrics.rows_removed - rows_removed_start);
    try std.testing.expectEqual(@as(u64, 0), host.engine.pending_roc_metrics.active_graph_records_rebuilt - graph_rebuild_start);
    try std.testing.expectEqual(row_call_start + 1, test_row_elem_call_count);
    try std.testing.expectEqual(@as(u64, 1), patch_counts.create_element);
    try std.testing.expectEqual(@as(u64, 1), patch_counts.append_child);
    try std.testing.expectEqual(@as(u64, 1), patch_counts.set_text);
    try std.testing.expectEqual(@as(u64, 3), patch_counts.total);
    try std.testing.expectEqual(patch_start + 3, host.engine.render_metrics.patches_emitted);
    try std.testing.expect(activeTextElementId(&host, "row-25-25") != null);
}

test "prepared dirty each inputs retain inside capability frame and sweep host OOM" {
    test_erased_callable_drop_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    const state_token = newTestBinderToken(&roc_host);
    const state_cap = testHostValueCapability(&roc_host);
    const each = testNodeEachWithSignalCapabilityAndRow(&roc_host, testNodeRefExpr(state_token), state_cap, &testStatefulRowElemCallable);
    const children = [_]abi.Elem{each};
    const section = testElementWith(&roc_host, "section", &.{}, &children);
    const initial_items = [_]HostValue{ testHostValueI64(1), testHostValueI64(2), testHostValueI64(3) };
    const root = testNodeStateWithTokenAndInitialCapability(&roc_host, state_token, testHostValueI64List(&roc_host, &initial_items), section, state_cap);
    defer root.decref(&roc_host);

    var initial_stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &initial_stream, root, &.{});
    _ = applyNodeDescriptorStream(&host, &roc_host, &initial_stream);
    host.engine.active_stream = initial_stream;

    const each_desc = host.engine.active_stream.eaches.items[0];
    const site = host.engine.active_stream.scope_sites.items[1];
    const row_scopes = try host.engine.activeEachRowScopes(host.hostAllocator(), site.scope_id, site.ordinal);
    defer host.hostAllocator().free(row_scopes);
    var baseline_fault = FaultAllocator.init(host.hostAllocator());
    var baseline = try HostEngine.PreparedActiveEachRows.prepare(&host.engine, &host, &roc_host, site, each_desc, baseline_fault.allocator());
    const attempts = baseline_fault.attempts;
    try std.testing.expect(attempts >= 4);
    try std.testing.expectEqual(@as(usize, 3), baseline.inputs.items.len);
    for (baseline.inputs.items, row_scopes) |item, scope_id| {
        try std.testing.expect(host.engine.eachRowScopeItemEquals(&host, &roc_host, scope_id.raw(), item, each_desc.ops.item_capability));
    }
    baseline.deinit();
    const before = host.roc_allocations.snapshot();

    for (1..attempts + 1) |failure_number| {
        var fault = FaultAllocator.init(host.hostAllocator());
        fault.configure(failure_number);
        try std.testing.expectError(error.OutOfMemory, HostEngine.PreparedActiveEachRows.prepare(&host.engine, &host, &roc_host, site, each_desc, fault.allocator()));
        try std.testing.expectEqual(@as(usize, 1), fault.induced_failures);
        try std.testing.expectEqual(@as(usize, 0), host.roc_allocations.liveCountSince(before));

        fault.configure(null);
        var retry = try HostEngine.PreparedActiveEachRows.prepare(&host.engine, &host, &roc_host, site, each_desc, fault.allocator());
        for (retry.inputs.items, row_scopes) |item, scope_id| {
            try std.testing.expect(host.engine.eachRowScopeItemEquals(&host, &roc_host, scope_id.raw(), item, each_desc.ops.item_capability));
        }
        retry.deinit();
        try std.testing.expectEqual(@as(usize, 0), host.roc_allocations.liveCountSince(before));
    }

    var committed = try HostEngine.PreparedActiveEachRows.prepare(&host.engine, &host, &roc_host, site, each_desc, host.hostAllocator());
    var diff = committed.commit();
    try std.testing.expectEqual(@as(u64, 3), diff.rows_reused);
    try std.testing.expectEqual(@as(u64, 3), diff.row_items_unchanged);
    try std.testing.expectEqual(@as(u64, 0), diff.row_items_updated);
    diff.deinit(host.hostAllocator());
    committed.deinit();
    try std.testing.expectEqual(@as(usize, 0), host.roc_allocations.liveCountSince(before));
}

test "signals host dirty each reorder moves rows without recollecting bodies" {
    test_erased_callable_drop_count = 0;
    test_row_elem_call_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    const state_token = newTestBinderToken(&roc_host);
    const state_cap = testHostValueCapability(&roc_host);
    const each = testNodeEachWithSignalCapabilityAndRow(&roc_host, testNodeRefExpr(state_token), state_cap, &testStatefulRowElemCallable);
    const children = [_]abi.Elem{each};
    const section = testElementWith(&roc_host, "section", &.{}, &children);

    const initial_items = [_]HostValue{ testHostValueI64(1), testHostValueI64(2), testHostValueI64(3) };
    const root = testNodeStateWithTokenAndInitialCapability(&roc_host, state_token, testHostValueI64List(&roc_host, &initial_items), section, state_cap);
    defer root.decref(&roc_host);

    var initial_stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &initial_stream, root, &.{});
    _ = applyNodeDescriptorStream(&host, &roc_host, &initial_stream);
    host.engine.active_stream = initial_stream;

    try std.testing.expectEqual(@as(u64, 3), test_row_elem_call_count);
    const section_id = host.engine.active_stream.elements.items[0].elem_id;
    const row_1_id = activeTextElementId(&host, "row-1-1") orelse unreachable;
    const row_2_id = activeTextElementId(&host, "row-2-2") orelse unreachable;
    const row_3_id = activeTextElementId(&host, "row-3-3") orelse unreachable;
    try std.testing.expectEqualSlices(u64, &.{ row_1_id, row_2_id, row_3_id }, host.dom_elements.items[@intCast(section_id.raw())].children.items);

    const state_id = host.engine.active_stream.scope_sites.items[0].node_id;
    const state_index = host.engine.stateIndexByNodeId(state_id.raw()) orelse unreachable;

    const reordered_items = [_]HostValue{ testHostValueI64(3), testHostValueI64(1), testHostValueI64(2) };
    testDropHostValue(&roc_host, host.engine.states.items[state_index].activePayload().cell.value);
    host.engine.states.items[state_index].activePayload().cell.value = testHostValueI64List(&roc_host, &reordered_items);
    host.engine.states.items[state_index].activePayload().version += 1;

    const dirty_source_node_ids = [_]u64{state_id.raw()};
    const dirty_generation = host.nextDirtySignalGeneration();
    const changed_record_ids = propagateDirtyActiveSignals(&host, &roc_host, host.hostAllocator(), &dirty_source_node_ids, dirty_generation);
    const dirty_structural_signals = collectDirtyStructuralSignals(&host, &roc_host, host.hostAllocator(), &dirty_source_node_ids, changed_record_ids, dirty_generation);
    defer host.hostAllocator().free(dirty_structural_signals);

    try std.testing.expectEqual(@as(usize, 1), dirty_structural_signals.len);
    try std.testing.expectEqual(HostActiveStructuralSignalKind.each, dirty_structural_signals[0].kind);

    const rows_reused_start = host.engine.pending_roc_metrics.rows_reused;
    const rows_created_start = host.engine.pending_roc_metrics.rows_created;
    const rows_removed_start = host.engine.pending_roc_metrics.rows_removed;
    const row_call_start = test_row_elem_call_count;
    const patch_start = host.engine.render_metrics.patches_emitted;
    const graph_rebuild_start = host.engine.pending_roc_metrics.active_graph_records_rebuilt;

    const patch_counts = applyDirtyStructuralSignalsLocally(&host, &roc_host, &dirty_source_node_ids, dirty_generation, dirty_structural_signals);

    try std.testing.expectEqual(@as(u64, 3), host.engine.pending_roc_metrics.rows_reused - rows_reused_start);
    try std.testing.expectEqual(@as(u64, 0), host.engine.pending_roc_metrics.rows_created - rows_created_start);
    try std.testing.expectEqual(@as(u64, 0), host.engine.pending_roc_metrics.rows_removed - rows_removed_start);
    try std.testing.expectEqual(@as(u64, 0), host.engine.pending_roc_metrics.active_graph_records_rebuilt - graph_rebuild_start);
    try std.testing.expectEqual(row_call_start, test_row_elem_call_count);
    try std.testing.expectEqual(@as(u64, 0), patch_counts.create_element);
    try std.testing.expectEqual(@as(u64, 0), patch_counts.append_child);
    try std.testing.expectEqual(@as(u64, 0), patch_counts.remove_node);
    try std.testing.expectEqual(@as(u64, 1), patch_counts.move_before);
    try std.testing.expectEqual(@as(u64, 0), patch_counts.set_text);
    try std.testing.expectEqual(@as(u64, 1), patch_counts.total);
    try std.testing.expectEqual(patch_start + 1, host.engine.render_metrics.patches_emitted);
    try std.testing.expectEqualSlices(u64, &.{ row_3_id, row_1_id, row_2_id }, host.dom_elements.items[@intCast(section_id.raw())].children.items);
}

test "signals host keeps table sizes flat across repeated keyed row reorder churn" {
    test_erased_callable_drop_count = 0;
    test_row_elem_call_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    const state_token = newTestBinderToken(&roc_host);
    const state_cap = testHostValueCapability(&roc_host);
    const each = testNodeEachWithSignalCapabilityAndRow(&roc_host, testNodeRefExpr(state_token), state_cap, &testStatefulRowElemCallable);
    const children = [_]abi.Elem{each};
    const section = testElementWith(&roc_host, "section", &.{}, &children);

    const initial_items = [_]HostValue{ testHostValueI64(1), testHostValueI64(2), testHostValueI64(3), testHostValueI64(4) };
    const root = testNodeStateWithTokenAndInitialCapability(&roc_host, state_token, testHostValueI64List(&roc_host, &initial_items), section, state_cap);
    defer root.decref(&roc_host);

    var initial_stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &initial_stream, root, &.{});
    _ = applyNodeDescriptorStream(&host, &roc_host, &initial_stream);
    host.engine.active_stream = initial_stream;
    finishHostMetrics(&host);

    const state_id = host.engine.active_stream.scope_sites.items[0].node_id;

    var snapshot_after_warmup: ?HostPlateauSnapshot = null;
    var iteration: usize = 0;
    while (iteration < 80) : (iteration += 1) {
        var items: [4]HostValue = undefined;
        switch (iteration % 4) {
            0 => items = .{ testHostValueI64(4), testHostValueI64(1), testHostValueI64(2), testHostValueI64(3) },
            1 => items = .{ testHostValueI64(2), testHostValueI64(4), testHostValueI64(3), testHostValueI64(1) },
            2 => items = .{ testHostValueI64(1), testHostValueI64(3), testHostValueI64(4), testHostValueI64(2) },
            else => items = .{ testHostValueI64(1), testHostValueI64(2), testHostValueI64(3), testHostValueI64(4) },
        }

        try std.testing.expect(host.updateStateValue(&roc_host, state_id, testHostValueI64List(&roc_host, &items)));

        const dirty_source_node_ids = [_]u64{state_id.raw()};
        const dirty_generation = host.nextDirtySignalGeneration();
        const changed_record_ids = propagateDirtyActiveSignals(&host, &roc_host, host.hostAllocator(), &dirty_source_node_ids, dirty_generation);
        const dirty_structural_signals = collectDirtyStructuralSignals(&host, &roc_host, host.hostAllocator(), &dirty_source_node_ids, changed_record_ids, dirty_generation);

        try std.testing.expectEqual(@as(usize, 1), dirty_structural_signals.len);
        try std.testing.expectEqual(HostActiveStructuralSignalKind.each, dirty_structural_signals[0].kind);

        const rows_created_start = host.engine.last_runtime_metrics.rows_created;
        const rows_removed_start = host.engine.last_runtime_metrics.rows_removed;
        const row_call_start = test_row_elem_call_count;

        _ = applyDirtyStructuralSignalsLocally(&host, &roc_host, &dirty_source_node_ids, dirty_generation, dirty_structural_signals);
        host.hostAllocator().free(dirty_structural_signals);
        finishHostMetrics(&host);

        try std.testing.expectEqual(@as(u64, 0), host.engine.last_runtime_metrics.rows_created - rows_created_start);
        try std.testing.expectEqual(@as(u64, 0), host.engine.last_runtime_metrics.rows_removed - rows_removed_start);
        try std.testing.expectEqual(row_call_start, test_row_elem_call_count);

        const snapshot = HostPlateauSnapshot.capture(&host);
        if (iteration == 7) {
            snapshot_after_warmup = snapshot;
        } else if (iteration > 7) {
            try expectHostPlateauSnapshot(snapshot_after_warmup.?, snapshot);
        }
    }

    try std.testing.expect(activeTextElementId(&host, "row-1-1") != null);
    try std.testing.expect(activeTextElementId(&host, "row-2-2") != null);
    try std.testing.expect(activeTextElementId(&host, "row-3-3") != null);
    try std.testing.expect(activeTextElementId(&host, "row-4-4") != null);
}

test "signals host removal reinsert churn plateaus dense tables" {
    test_erased_callable_drop_count = 0;
    test_row_elem_call_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    const state_token = newTestBinderToken(&roc_host);
    const state_cap = testHostValueCapability(&roc_host);
    const each = testNodeEachWithSignalCapabilityAndRow(&roc_host, testNodeRefExpr(state_token), state_cap, &testStatefulRowElemCallable);
    const children = [_]abi.Elem{each};
    const section = testElementWith(&roc_host, "section", &.{}, &children);

    const initial_items = [_]HostValue{ testHostValueI64(1), testHostValueI64(2), testHostValueI64(3) };
    const root = testNodeStateWithTokenAndInitialCapability(&roc_host, state_token, testHostValueI64List(&roc_host, &initial_items), section, state_cap);
    defer root.decref(&roc_host);

    var initial_stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &initial_stream, root, &.{});
    _ = applyNodeDescriptorStream(&host, &roc_host, &initial_stream);
    host.engine.active_stream = initial_stream;
    finishHostMetrics(&host);

    const state_id = host.engine.active_stream.scope_sites.items[0].node_id;

    var snapshot_after_warmup: ?HostPlateauSnapshot = null;
    var iteration: usize = 0;
    while (iteration < 40) : (iteration += 1) {
        var items: [3]HostValue = undefined;
        if (iteration % 2 == 0) {
            items = .{ testHostValueI64(1), testHostValueI64(3), testHostValueI64(4) };
        } else {
            items = .{ testHostValueI64(1), testHostValueI64(2), testHostValueI64(3) };
        }

        try std.testing.expect(host.updateStateValue(&roc_host, state_id, testHostValueI64List(&roc_host, &items)));

        const before_metrics = host.engine.last_runtime_metrics;
        const row_call_start = test_row_elem_call_count;

        {
            const dirty_source_node_ids = [_]u64{state_id.raw()};
            const dirty_generation = host.nextDirtySignalGeneration();
            const changed_record_ids = propagateDirtyActiveSignals(&host, &roc_host, host.hostAllocator(), &dirty_source_node_ids, dirty_generation);
            const dirty_structural_signals = collectDirtyStructuralSignals(&host, &roc_host, host.hostAllocator(), &dirty_source_node_ids, changed_record_ids, dirty_generation);
            defer host.hostAllocator().free(dirty_structural_signals);

            try std.testing.expectEqual(@as(usize, 1), dirty_structural_signals.len);
            try std.testing.expectEqual(HostActiveStructuralSignalKind.each, dirty_structural_signals[0].kind);

            _ = applyDirtyStructuralSignalsLocally(&host, &roc_host, &dirty_source_node_ids, dirty_generation, dirty_structural_signals);
        }
        finishHostMetrics(&host);

        try std.testing.expectEqual(@as(u64, 1), host.engine.last_runtime_metrics.rows_created - before_metrics.rows_created);
        try std.testing.expectEqual(@as(u64, 1), host.engine.last_runtime_metrics.rows_removed - before_metrics.rows_removed);
        try std.testing.expectEqual(row_call_start + 1, test_row_elem_call_count);

        const snapshot = HostPlateauSnapshot.capture(&host);
        if (iteration == 7) {
            snapshot_after_warmup = snapshot;
        } else if (iteration > 7) {
            try expectHostPlateauSnapshot(snapshot_after_warmup.?, snapshot);
        }
    }

    try std.testing.expect(activeTextElementId(&host, "row-1-1") != null);
    try std.testing.expect(activeTextElementId(&host, "row-2-2") != null);
    try std.testing.expect(activeTextElementId(&host, "row-3-3") != null);
    try std.testing.expect(activeTextElementId(&host, "row-4-4") == null);
}

test "live row churn never recycles a node id the descriptor stream still holds" {
    // Node ids index the descriptor stream's per-node slots, one descriptor per
    // slot, so a node id is unusable while any of its slots is occupied.
    // Identity reservation used to recycle purely on identity lifecycle, so a
    // construction site instantiated in a second scope could be handed a node
    // id another scope's live site still occupied, publishing two descriptors
    // into one slot at the allocation-free commit boundary ("descriptor stream
    // recorded duplicate descriptor index").
    //
    // This guards the invariant rather than replaying that trigger: the
    // shortest shape that reproduces it in an example needs render-layout
    // arithmetic that is still broken for multi-site growth, so this covers
    // live churn across sibling sites at a fixed row count instead.
    const Check = struct {
        fn expectDistinctNodeIds(host: *const HostEnv) !void {
            const sites = host.engine.active_stream.scope_sites.items;
            for (sites, 0..) |site, index| {
                for (sites[0..index]) |earlier| {
                    if (earlier.node_id.raw() == site.node_id.raw() and earlier.kind == site.kind) {
                        std.debug.print(
                            "node id {d} carries two live {t} scope sites (scopes {d} and {d})\n",
                            .{ site.node_id.raw(), site.kind, earlier.scope_id.raw(), site.scope_id.raw() },
                        );
                        return error.DuplicateLiveNodeId;
                    }
                }
            }
        }
    };

    test_erased_callable_drop_count = 0;
    test_row_elem_call_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    const condition_token = newTestBinderToken(&roc_host);
    const condition_cap = testHostValueCapability(&roc_host);
    const items_token = newTestBinderToken(&roc_host);
    const items_cap = testHostValueCapability(&roc_host);
    // Two sibling sites under distinct parents: each row scope owns a `when`
    // construction site, so churning the list retires and re-reserves node
    // identities while the other site's rows stay live.
    const first_each = testNodeEachSignalWithNestedWhenRows(&roc_host, testNodeRefExpr(items_token), items_cap, condition_token, condition_cap);
    const second_each = testNodeEachSignalWithNestedWhenRows(&roc_host, testNodeRefExpr(items_token), items_cap, condition_token, condition_cap);
    const first_column = testElementWith(&roc_host, "div", &.{}, &.{first_each});
    const second_column = testElementWith(&roc_host, "div", &.{}, &.{second_each});
    const section = testElementWith(&roc_host, "section", &.{}, &.{ first_column, second_column });
    const initial_items = [_]HostValue{ testHostValueI64(1), testHostValueI64(2), testHostValueI64(3) };
    const items_state = testNodeStateWithTokenAndInitialCapability(&roc_host, items_token, testHostValueI64List(&roc_host, &initial_items), section, items_cap);
    const root = testNodeStateWithTokenAndInitialCapability(&roc_host, condition_token, testHostValueBool(true), items_state, condition_cap);
    defer root.decref(&roc_host);

    var stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
    _ = applyNodeDescriptorStream(&host, &roc_host, &stream);
    host.engine.active_stream = stream;
    try Check.expectDistinctNodeIds(&host);

    var state_ids: [2]u64 = undefined;
    var state_count: usize = 0;
    for (host.engine.active_stream.scope_sites.items) |site| {
        if (site.kind != .state) continue;
        if (state_count < state_ids.len) state_ids[state_count] = site.node_id.raw();
        state_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), state_count);
    const items_state_id = state_ids[1];

    // Every edit replaces all three keys, so each dispatch retires both sites'
    // row scopes -- and their nested `when` node identities -- and reserves
    // fresh ones in the same transaction. Keeping the row count fixed keeps
    // this focused on identity reuse rather than on render-layout arithmetic.
    const edits = [_][3]i64{
        .{ 4, 5, 6 },
        .{ 7, 8, 9 },
        .{ 10, 11, 12 },
        .{ 13, 14, 15 },
    };
    for (edits) |edit| {
        var items: [3]HostValue = undefined;
        for (edit, 0..) |value, index| items[index] = testHostValueI64(value);
        _ = try host.engine.tryDispatchStateValue(&host, &roc_host, items_state_id, testHostValueI64List(&roc_host, &items), items_cap);
        try Check.expectDistinctNodeIds(&host);
    }

    // The last edit is the one on screen, in both columns.
    try std.testing.expect(activeTextElementId(&host, "row-15-15-true") != null);
    try std.testing.expect(activeTextElementId(&host, "row-1-1-true") == null);
}

test "signals host nested removal reinsert churn plateaus branch scopes" {
    test_erased_callable_drop_count = 0;
    test_row_elem_call_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    const condition_token = newTestBinderToken(&roc_host);
    const condition_cap = testHostValueCapability(&roc_host);
    const items_token = newTestBinderToken(&roc_host);
    const items_cap = testHostValueCapability(&roc_host);
    const each = testNodeEachSignalWithNestedWhenRows(&roc_host, testNodeRefExpr(items_token), items_cap, condition_token, condition_cap);
    const children = [_]abi.Elem{each};
    const section = testElementWith(&roc_host, "section", &.{}, &children);
    const initial_items = [_]HostValue{ testHostValueI64(1), testHostValueI64(2), testHostValueI64(3) };
    const items_state = testNodeStateWithTokenAndInitialCapability(&roc_host, items_token, testHostValueI64List(&roc_host, &initial_items), section, items_cap);
    const root = testNodeStateWithTokenAndInitialCapability(&roc_host, condition_token, testHostValueBool(true), items_state, condition_cap);
    defer root.decref(&roc_host);

    var initial_stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &initial_stream, root, &.{});
    _ = applyNodeDescriptorStream(&host, &roc_host, &initial_stream);
    host.engine.active_stream = initial_stream;
    finishHostMetrics(&host);

    var state_ids: [2]u64 = undefined;
    var state_count: usize = 0;
    for (host.engine.active_stream.scope_sites.items) |site| {
        if (site.kind != .state) continue;
        if (state_count < state_ids.len) state_ids[state_count] = site.node_id.raw();
        state_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), state_count);
    const items_state_id = state_ids[1];

    var snapshot_after_warmup: ?HostPlateauSnapshot = null;
    var iteration: usize = 0;
    while (iteration < 40) : (iteration += 1) {
        var items: [3]HostValue = undefined;
        if (iteration % 2 == 0) {
            items = .{ testHostValueI64(1), testHostValueI64(3), testHostValueI64(4) };
        } else {
            items = .{ testHostValueI64(1), testHostValueI64(2), testHostValueI64(3) };
        }

        try std.testing.expect(host.updateStateValue(&roc_host, ids.NodeId.fromRaw(items_state_id), testHostValueI64List(&roc_host, &items)));

        const before_metrics = host.engine.last_runtime_metrics;
        const row_call_start = test_row_elem_call_count;

        {
            const dirty_source_node_ids = [_]u64{items_state_id};
            const dirty_generation = host.nextDirtySignalGeneration();
            const changed_record_ids = propagateDirtyActiveSignals(&host, &roc_host, host.hostAllocator(), &dirty_source_node_ids, dirty_generation);
            const dirty_structural_signals = collectDirtyStructuralSignals(&host, &roc_host, host.hostAllocator(), &dirty_source_node_ids, changed_record_ids, dirty_generation);
            defer host.hostAllocator().free(dirty_structural_signals);

            try std.testing.expectEqual(@as(usize, 1), dirty_structural_signals.len);
            try std.testing.expectEqual(HostActiveStructuralSignalKind.each, dirty_structural_signals[0].kind);

            _ = applyDirtyStructuralSignalsLocally(&host, &roc_host, &dirty_source_node_ids, dirty_generation, dirty_structural_signals);
        }
        finishHostMetrics(&host);

        try std.testing.expectEqual(@as(u64, 1), host.engine.last_runtime_metrics.rows_created - before_metrics.rows_created);
        try std.testing.expectEqual(@as(u64, 1), host.engine.last_runtime_metrics.rows_removed - before_metrics.rows_removed);
        try std.testing.expectEqual(row_call_start + 1, test_row_elem_call_count);

        const snapshot = HostPlateauSnapshot.capture(&host);
        if (iteration == 7) {
            snapshot_after_warmup = snapshot;
        } else if (iteration > 7) {
            try expectHostPlateauSnapshot(snapshot_after_warmup.?, snapshot);
        }
    }

    try std.testing.expect(activeTextElementId(&host, "row-1-1-true") != null);
    try std.testing.expect(activeTextElementId(&host, "row-2-2-true") != null);
    try std.testing.expect(activeTextElementId(&host, "row-3-3-true") != null);
    try std.testing.expect(activeTextElementId(&host, "row-4-4-true") == null);
}

test "signals host dirty each mixed churn splices changed rows and moves survivors" {
    test_erased_callable_drop_count = 0;
    test_row_elem_call_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    const state_token = newTestBinderToken(&roc_host);
    const state_cap = testHostValueCapability(&roc_host);
    const each = testNodeEachWithSignalCapabilityAndRow(&roc_host, testNodeRefExpr(state_token), state_cap, &testStatefulRowElemCallable);
    const children = [_]abi.Elem{each};
    const section = testElementWith(&roc_host, "section", &.{}, &children);

    const initial_items = [_]HostValue{ testHostValueI64(1), testHostValueI64(2), testHostValueI64(3) };
    const root = testNodeStateWithTokenAndInitialCapability(&roc_host, state_token, testHostValueI64List(&roc_host, &initial_items), section, state_cap);
    defer root.decref(&roc_host);

    var initial_stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &initial_stream, root, &.{});
    _ = applyNodeDescriptorStream(&host, &roc_host, &initial_stream);
    host.engine.active_stream = initial_stream;

    try std.testing.expectEqual(@as(u64, 3), test_row_elem_call_count);
    const section_id = host.engine.active_stream.elements.items[0].elem_id;
    const row_1_id = activeTextElementId(&host, "row-1-1") orelse unreachable;
    const row_2_id = activeTextElementId(&host, "row-2-2") orelse unreachable;
    const row_3_id = activeTextElementId(&host, "row-3-3") orelse unreachable;
    try std.testing.expectEqualSlices(u64, &.{ row_1_id, row_2_id, row_3_id }, host.dom_elements.items[@intCast(section_id.raw())].children.items);

    const state_id = host.engine.active_stream.scope_sites.items[0].node_id;
    const state_index = host.engine.stateIndexByNodeId(state_id.raw()) orelse unreachable;

    const mixed_items = [_]HostValue{ testHostValueI64(3), testHostValueI64(1), testHostValueI64(4) };
    testDropHostValue(&roc_host, host.engine.states.items[state_index].activePayload().cell.value);
    host.engine.states.items[state_index].activePayload().cell.value = testHostValueI64List(&roc_host, &mixed_items);
    host.engine.states.items[state_index].activePayload().version += 1;

    const dirty_source_node_ids = [_]u64{state_id.raw()};
    const dirty_generation = host.nextDirtySignalGeneration();
    const changed_record_ids = propagateDirtyActiveSignals(&host, &roc_host, host.hostAllocator(), &dirty_source_node_ids, dirty_generation);
    const dirty_structural_signals = collectDirtyStructuralSignals(&host, &roc_host, host.hostAllocator(), &dirty_source_node_ids, changed_record_ids, dirty_generation);
    defer host.hostAllocator().free(dirty_structural_signals);

    try std.testing.expectEqual(@as(usize, 1), dirty_structural_signals.len);
    try std.testing.expectEqual(HostActiveStructuralSignalKind.each, dirty_structural_signals[0].kind);

    const rows_reused_start = host.engine.pending_roc_metrics.rows_reused;
    const rows_created_start = host.engine.pending_roc_metrics.rows_created;
    const rows_removed_start = host.engine.pending_roc_metrics.rows_removed;
    const row_call_start = test_row_elem_call_count;
    const patch_start = host.engine.render_metrics.patches_emitted;
    const graph_rebuild_start = host.engine.pending_roc_metrics.active_graph_records_rebuilt;

    const patch_counts = applyDirtyStructuralSignalsLocally(&host, &roc_host, &dirty_source_node_ids, dirty_generation, dirty_structural_signals);

    try std.testing.expectEqual(@as(u64, 2), host.engine.pending_roc_metrics.rows_reused - rows_reused_start);
    try std.testing.expectEqual(@as(u64, 1), host.engine.pending_roc_metrics.rows_created - rows_created_start);
    try std.testing.expectEqual(@as(u64, 1), host.engine.pending_roc_metrics.rows_removed - rows_removed_start);
    try std.testing.expectEqual(@as(u64, 0), host.engine.pending_roc_metrics.active_graph_records_rebuilt - graph_rebuild_start);
    try std.testing.expectEqual(row_call_start + 1, test_row_elem_call_count);
    try std.testing.expectEqual(@as(u64, 1), patch_counts.create_element);
    try std.testing.expectEqual(@as(u64, 1), patch_counts.append_child);
    try std.testing.expectEqual(@as(u64, 1), patch_counts.remove_node);
    try std.testing.expectEqual(@as(u64, 1), patch_counts.move_before);
    try std.testing.expectEqual(@as(u64, 1), patch_counts.set_text);
    try std.testing.expectEqual(@as(u64, 5), patch_counts.total);
    try std.testing.expectEqual(patch_start + 5, host.engine.render_metrics.patches_emitted);
    const row_4_id = activeTextElementId(&host, "row-4-4") orelse unreachable;
    try std.testing.expectEqual(row_1_id, activeTextElementId(&host, "row-1-1") orelse unreachable);
    try std.testing.expectEqual(row_3_id, activeTextElementId(&host, "row-3-3") orelse unreachable);
    try std.testing.expect(activeTextElementId(&host, "row-2-2") == null);
    try std.testing.expectEqualSlices(u64, &.{ row_3_id, row_1_id, row_4_id }, host.dom_elements.items[@intCast(section_id.raw())].children.items);
}

test "signals host updates nested when without rebuilding unchanged row" {
    test_erased_callable_drop_count = 0;
    test_row_elem_call_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    const state_token = newTestBinderToken(&roc_host);
    const state_cap = testHostValueCapability(&roc_host);
    const items = [_]HostValue{testHostValueI64(1)};
    const children = [_]abi.Elem{
        testNodeEachWithNestedWhenRows(&roc_host, &items, state_token, state_cap),
    };
    const section = testElementWith(&roc_host, "section", &.{}, &children);
    const root = testNodeStateWithTokenAndInitialCapability(&roc_host, state_token, testHostValueBool(true), section, state_cap);
    defer root.decref(&roc_host);

    var initial_stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &initial_stream, root, &.{});
    _ = applyNodeDescriptorStream(&host, &roc_host, &initial_stream);
    host.engine.active_stream = initial_stream;

    try std.testing.expectEqual(@as(u64, 1), test_row_elem_call_count);
    try std.testing.expect(activeTextElementId(&host, "row-1-1-true") != null);
    try std.testing.expect(activeTextElementId(&host, "row-1-1-false") == null);

    const state_id = host.engine.active_stream.scope_sites.items[0].node_id;
    const state_index = host.engine.stateIndexByNodeId(state_id.raw()) orelse unreachable;
    testDropHostValue(&roc_host, host.engine.states.items[state_index].activePayload().cell.value);
    host.engine.states.items[state_index].activePayload().cell.value = testHostValueBool(false);
    host.engine.states.items[state_index].activePayload().version += 1;

    const dirty_source_node_ids = [_]u64{state_id.raw()};
    const dirty_generation = host.nextDirtySignalGeneration();
    const changed_record_ids = propagateDirtyActiveSignals(&host, &roc_host, host.hostAllocator(), &dirty_source_node_ids, dirty_generation);
    const dirty_structural_signals = collectDirtyStructuralSignals(&host, &roc_host, host.hostAllocator(), &dirty_source_node_ids, changed_record_ids, dirty_generation);
    defer host.hostAllocator().free(dirty_structural_signals);
    try std.testing.expectEqual(@as(usize, 1), dirty_structural_signals.len);
    try std.testing.expectEqual(HostActiveStructuralSignalKind.when, dirty_structural_signals[0].kind);

    const graph_rebuild_start = host.engine.pending_roc_metrics.active_graph_records_rebuilt;
    _ = applyDirtyWhenStructuralSignals(&host, &roc_host, &dirty_source_node_ids, dirty_generation, dirty_structural_signals);

    try std.testing.expectEqual(@as(u64, 0), host.engine.pending_roc_metrics.active_graph_records_rebuilt - graph_rebuild_start);
    try std.testing.expectEqual(@as(u64, 1), test_row_elem_call_count);
    try std.testing.expect(activeTextElementId(&host, "row-1-1-true") == null);
    try std.testing.expect(activeTextElementId(&host, "row-1-1-false") != null);
}

test "signals host structural patch clears fields absent from reused DOM node" {
    test_erased_callable_drop_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    const initial_attrs = [_]abi.NodeAttr{
        testNodeStaticTextAttr(&roc_host, .label, "Initial label"),
        testNodeStaticCustomTextAttr(&roc_host, "data-mode", "initial"),
        testNodeStaticBoolAttr(.disabled, true),
    };
    const initial_root = testElementWith(&roc_host, "section", &initial_attrs, &.{});
    defer initial_root.decref(&roc_host);

    var initial_stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &initial_stream, initial_root, &.{});
    _ = applyNodeDescriptorStream(&host, &roc_host, &initial_stream);
    host.engine.active_stream = initial_stream;

    const section_id = host.engine.active_stream.elements.items[0].elem_id;
    try std.testing.expectEqualStrings("Initial label", host.dom_elements.items[@intCast(section_id.raw())].label.?);
    try std.testing.expectEqualStrings("initial", elementTextAttr(&host.dom_elements.items[@intCast(section_id.raw())], "data-mode").?);
    try std.testing.expect(host.dom_elements.items[@intCast(section_id.raw())].disabled);

    const next_root = testElementWith(&roc_host, "section", &.{}, &.{});
    defer next_root.decref(&roc_host);

    var next_stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &next_stream, next_root, &.{});
    const patch_counts = applyStructuralNodeDescriptorStream(&host, &roc_host, &next_stream);
    host.engine.active_stream.deinit(host.hostAllocator(), &host, &roc_host, &host.engine.pending_roc_metrics);
    host.engine.active_stream = next_stream;

    try std.testing.expectEqual(@as(u64, 0), patch_counts.reset_dom);
    try std.testing.expectEqual(@as(u64, 0), patch_counts.create_element);
    try std.testing.expectEqual(@as(u64, 2), patch_counts.set_metadata);
    try std.testing.expectEqual(@as(u64, 1), patch_counts.set_disabled);
    try std.testing.expect(host.dom_elements.items[@intCast(section_id.raw())].label == null);
    try std.testing.expect(elementTextAttr(&host.dom_elements.items[@intCast(section_id.raw())], "data-mode") == null);
    try std.testing.expect(!host.dom_elements.items[@intCast(section_id.raw())].disabled);
}

test "signals host structural patch binds only changed event slots" {
    test_erased_callable_drop_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    const state_token = newTestBinderToken(&roc_host);
    const initial_button_attrs = [_]abi.NodeAttr{
        testNodeStaticTextAttr(&roc_host, .text, "Submit"),
        testNodeEventAttr(&roc_host, .click, state_token, .unit),
    };
    const initial_children = [_]abi.Elem{
        testElementWith(&roc_host, "button", &initial_button_attrs, &.{}),
    };
    const initial_section = testElementWith(&roc_host, "section", &.{}, &initial_children);
    const initial_root = testNodeStateWithToken(&roc_host, state_token, initial_section);
    defer initial_root.decref(&roc_host);

    var initial_stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &initial_stream, initial_root, &.{});
    const initial_counts = applyNodeDescriptorStream(&host, &roc_host, &initial_stream);
    host.engine.active_stream = initial_stream;

    try std.testing.expectEqual(@as(u64, 1), initial_counts.bind_event);
    const button_id = host.engine.active_stream.elements.items[1].elem_id;
    try std.testing.expectEqual(@as(?u64, 1), nodeFixedEventId(&host, button_id, .click));

    const same_button_attrs = [_]abi.NodeAttr{
        testNodeStaticTextAttr(&roc_host, .text, "Submit"),
        testNodeEventAttr(&roc_host, .click, state_token, .unit),
    };
    const same_children = [_]abi.Elem{
        testElementWith(&roc_host, "button", &same_button_attrs, &.{}),
    };
    const same_section = testElementWith(&roc_host, "section", &.{}, &same_children);
    const same_root = testNodeStateWithToken(&roc_host, cloneTestBinderToken(state_token), same_section);
    defer same_root.decref(&roc_host);

    var same_stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &same_stream, same_root, &.{});
    const same_counts = applyStructuralNodeDescriptorStream(&host, &roc_host, &same_stream);
    host.engine.active_stream.deinit(host.hostAllocator(), &host, &roc_host, &host.engine.pending_roc_metrics);
    host.engine.active_stream = same_stream;

    try std.testing.expectEqual(@as(u64, 0), same_counts.bind_event);
    try std.testing.expectEqual(@as(?u64, 1), nodeFixedEventId(&host, button_id, .click));

    const removed_button_attrs = [_]abi.NodeAttr{
        testNodeStaticTextAttr(&roc_host, .text, "Submit"),
    };
    const removed_children = [_]abi.Elem{
        testElementWith(&roc_host, "button", &removed_button_attrs, &.{}),
    };
    const removed_section = testElementWith(&roc_host, "section", &.{}, &removed_children);
    const removed_root = testNodeStateWithToken(&roc_host, cloneTestBinderToken(state_token), removed_section);
    defer removed_root.decref(&roc_host);

    var removed_stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &removed_stream, removed_root, &.{});
    const removed_counts = applyStructuralNodeDescriptorStream(&host, &roc_host, &removed_stream);
    host.engine.active_stream.deinit(host.hostAllocator(), &host, &roc_host, &host.engine.pending_roc_metrics);
    host.engine.active_stream = removed_stream;

    try std.testing.expectEqual(@as(u64, 1), removed_counts.bind_event);
    try std.testing.expect(nodeFixedEventId(&host, button_id, .click) == null);
}

test "signals host structural patch shifts moved row event ids only" {
    test_erased_callable_drop_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    const initial_items = [_]HostValue{ testHostValueI64(1), testHostValueI64(2) };
    const initial_children = [_]abi.Elem{
        testNodeEachWithItemsAndRow(&roc_host, &initial_items, &testStatefulRowButtonElemCallable),
    };
    const initial_root = testElementWith(&roc_host, "section", &.{}, &initial_children);
    defer initial_root.decref(&roc_host);

    var initial_stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &initial_stream, initial_root, &.{});
    const initial_counts = applyNodeDescriptorStream(&host, &roc_host, &initial_stream);
    host.engine.active_stream = initial_stream;

    try std.testing.expectEqual(@as(u64, 2), initial_counts.bind_event);
    const row_1_button_id = activeTextElementId(&host, "row-action-1-1") orelse unreachable;
    const row_2_button_id = activeTextElementId(&host, "row-action-2-2") orelse unreachable;
    try std.testing.expectEqual(@as(?u64, 1), nodeFixedEventId(&host, ids.ElemId.fromRaw(row_1_button_id), .click));
    try std.testing.expectEqual(@as(?u64, 2), nodeFixedEventId(&host, ids.ElemId.fromRaw(row_2_button_id), .click));

    const reordered_items = [_]HostValue{ testHostValueI64(2), testHostValueI64(1) };
    const reordered_children = [_]abi.Elem{
        testNodeEachWithItemsAndRow(&roc_host, &reordered_items, &testStatefulRowButtonElemCallable),
    };
    const reordered_root = testElementWith(&roc_host, "section", &.{}, &reordered_children);
    defer reordered_root.decref(&roc_host);

    var reordered_stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &reordered_stream, reordered_root, &.{});
    const reordered_counts = applyStructuralNodeDescriptorStream(&host, &roc_host, &reordered_stream);
    host.engine.active_stream.deinit(host.hostAllocator(), &host, &roc_host, &host.engine.pending_roc_metrics);
    host.engine.active_stream = reordered_stream;

    try std.testing.expectEqual(@as(u64, 0), reordered_counts.create_element);
    try std.testing.expectEqual(@as(u64, 2), reordered_counts.bind_event);
    try std.testing.expectEqual(row_1_button_id, activeTextElementId(&host, "row-action-1-1") orelse unreachable);
    try std.testing.expectEqual(row_2_button_id, activeTextElementId(&host, "row-action-2-2") orelse unreachable);
    try std.testing.expectEqual(@as(?u64, 2), nodeFixedEventId(&host, ids.ElemId.fromRaw(row_1_button_id), .click));
    try std.testing.expectEqual(@as(?u64, 1), nodeFixedEventId(&host, ids.ElemId.fromRaw(row_2_button_id), .click));

    const same_reordered_items = [_]HostValue{ testHostValueI64(2), testHostValueI64(1) };
    const same_reordered_children = [_]abi.Elem{
        testNodeEachWithItemsAndRow(&roc_host, &same_reordered_items, &testStatefulRowButtonElemCallable),
    };
    const same_reordered_root = testElementWith(&roc_host, "section", &.{}, &same_reordered_children);
    defer same_reordered_root.decref(&roc_host);

    var same_reordered_stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &same_reordered_stream, same_reordered_root, &.{});
    const same_reordered_counts = applyStructuralNodeDescriptorStream(&host, &roc_host, &same_reordered_stream);
    host.engine.active_stream.deinit(host.hostAllocator(), &host, &roc_host, &host.engine.pending_roc_metrics);
    host.engine.active_stream = same_reordered_stream;

    try std.testing.expectEqual(@as(u64, 0), same_reordered_counts.create_element);
    try std.testing.expectEqual(@as(u64, 0), same_reordered_counts.bind_event);
    try std.testing.expectEqual(@as(?u64, 2), nodeFixedEventId(&host, ids.ElemId.fromRaw(row_1_button_id), .click));
    try std.testing.expectEqual(@as(?u64, 1), nodeFixedEventId(&host, ids.ElemId.fromRaw(row_2_button_id), .click));
}

test "signals host dirty each removal refreshes survivor event ids" {
    test_erased_callable_drop_count = 0;
    test_row_elem_call_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    const state_token = newTestBinderToken(&roc_host);
    const state_cap = testHostValueCapability(&roc_host);
    const each = testNodeEachWithSignalCapabilityAndRow(&roc_host, testNodeRefExpr(state_token), state_cap, &testStatefulRowButtonElemCallable);
    const children = [_]abi.Elem{each};
    const section = testElementWith(&roc_host, "section", &.{}, &children);

    const initial_items = [_]HostValue{ testHostValueI64(1), testHostValueI64(2), testHostValueI64(3) };
    const root = testNodeStateWithTokenAndInitialCapability(&roc_host, state_token, testHostValueI64List(&roc_host, &initial_items), section, state_cap);
    defer root.decref(&roc_host);

    var initial_stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &initial_stream, root, &.{});
    _ = applyNodeDescriptorStream(&host, &roc_host, &initial_stream);
    host.rebuildActiveEventsFromStream(&initial_stream);
    host.engine.active_stream = initial_stream;

    const state_id = host.engine.active_stream.scope_sites.items[0].node_id;
    const state_index = host.engine.stateIndexByNodeId(state_id.raw()) orelse unreachable;
    const row_3_button_id = activeTextElementId(&host, "row-action-3-3") orelse unreachable;
    try std.testing.expectEqual(@as(?u64, 3), nodeFixedEventId(&host, ids.ElemId.fromRaw(row_3_button_id), .click));

    const next_items = [_]HostValue{ testHostValueI64(1), testHostValueI64(3) };
    testDropHostValue(&roc_host, host.engine.states.items[state_index].activePayload().cell.value);
    host.engine.states.items[state_index].activePayload().cell.value = testHostValueI64List(&roc_host, &next_items);
    host.engine.states.items[state_index].activePayload().version += 1;

    const dirty_source_node_ids = [_]u64{state_id.raw()};
    const dirty_generation = host.nextDirtySignalGeneration();
    const changed_record_ids = propagateDirtyActiveSignals(&host, &roc_host, host.hostAllocator(), &dirty_source_node_ids, dirty_generation);
    const dirty_structural_signals = collectDirtyStructuralSignals(&host, &roc_host, host.hostAllocator(), &dirty_source_node_ids, changed_record_ids, dirty_generation);
    defer host.hostAllocator().free(dirty_structural_signals);

    try std.testing.expectEqual(@as(usize, 1), dirty_structural_signals.len);
    _ = applyDirtyStructuralSignalsLocally(&host, &roc_host, &dirty_source_node_ids, dirty_generation, dirty_structural_signals);

    try std.testing.expectEqual(@as(usize, 2), host.engine.active_events.items.len);
    try std.testing.expectEqual(row_3_button_id, activeTextElementId(&host, "row-action-3-3") orelse unreachable);
    try std.testing.expectEqual(@as(?u64, 2), nodeFixedEventId(&host, ids.ElemId.fromRaw(row_3_button_id), .click));

    const replacement_items = [_]HostValue{testHostValueI64(4)};
    testDropHostValue(&roc_host, host.engine.states.items[state_index].activePayload().cell.value);
    host.engine.states.items[state_index].activePayload().cell.value = testHostValueI64List(&roc_host, &replacement_items);
    host.engine.states.items[state_index].activePayload().version += 1;

    const replacement_generation = host.nextDirtySignalGeneration();
    const replacement_record_ids = propagateDirtyActiveSignals(&host, &roc_host, host.hostAllocator(), &dirty_source_node_ids, replacement_generation);
    const replacement_structural_signals = collectDirtyStructuralSignals(&host, &roc_host, host.hostAllocator(), &dirty_source_node_ids, replacement_record_ids, replacement_generation);
    defer host.hostAllocator().free(replacement_structural_signals);

    try std.testing.expectEqual(@as(usize, 1), replacement_structural_signals.len);
    _ = applyDirtyStructuralSignalsLocally(&host, &roc_host, &dirty_source_node_ids, replacement_generation, replacement_structural_signals);

    try std.testing.expectEqual(@as(usize, 1), host.engine.active_events.items.len);
    try std.testing.expect(activeTextElementId(&host, "row-action-1-1") == null);
    try std.testing.expect(activeTextElementId(&host, "row-action-3-3") == null);
    const row_4_button_id = activeTextElementId(&host, "row-action-4-4") orelse unreachable;
    try std.testing.expectEqual(@as(?u64, 1), nodeFixedEventId(&host, ids.ElemId.fromRaw(row_4_button_id), .click));
}

fn freeKeyedRowDiff(host: *HostEnv, diff: HostKeyedRowDiffResult) void {
    diff.deinit(host.hostAllocator());
}

fn syncTestEachRowScopes(host: *HostEnv, roc_host: *abi.RocHost, parent_scope_id: ids.ScopeId, site_ordinal: u64, keys: []const HostValue, items: []const HostValue, key_cap: HostValueCapability, item_cap: HostValueCapability) HostKeyedRowDiffResult {
    const allocator = host.hostAllocator();
    const key_values = allocator.alloc(HostValue, keys.len) catch std.process.exit(1);
    defer allocator.free(key_values);
    const item_values = allocator.alloc(HostValue, items.len) catch std.process.exit(1);
    defer allocator.free(item_values);

    for (keys, key_values) |key, *dest| {
        dest.* = host.cloneHostValue(key);
    }
    for (items, item_values) |item, *dest| {
        dest.* = host.cloneHostValue(item);
    }
    for (keys) |key| {
        testDropHostValue(roc_host, key);
    }
    if (keys.ptr != items.ptr) {
        for (items) |item| {
            testDropHostValue(roc_host, item);
        }
    }

    const key_text = testHostValueKeyTextCallable(roc_host);
    defer abi.decrefErasedCallable(key_text, roc_host);
    const key_of = writeTestErasedCallable(
        TestErasedI64Capture,
        roc_host,
        &testUnaryHostValueCallable,
        &testErasedCallableOnDrop,
        .{ .amount = 0 },
    );
    defer abi.decrefErasedCallable(key_of, roc_host);
    const items_to_values = testItemsToValuesCallable(roc_host);
    defer abi.decrefErasedCallable(items_to_values, roc_host);
    const row = writeTestErasedCallable(
        TestErasedI64Capture,
        roc_host,
        &testBinaryElemCallable,
        &testErasedCallableOnDrop,
        .{ .amount = 0 },
    );
    defer abi.decrefErasedCallable(row, roc_host);
    const ops: HostEachOps = .{
        .items_capability = item_cap,
        .item_capability = item_cap,
        .key_capability = key_cap,
        .items_to_values = items_to_values,
        .key_text = key_text,
        .key_of = key_of,
        .row = row,
    };
    return host.syncEachRowScopes(roc_host, parent_scope_id, ids.SiteOrdinal.fromRaw(site_ordinal), key_values, item_values, ops);
}

fn createTestEachRowScope(host: *HostEnv, roc_host: *abi.RocHost, parent_scope_id: ids.ScopeId, site_ordinal: u64, key: HostValue, item: HostValue, key_cap: HostValueCapability, item_cap: HostValueCapability) ids.ScopeId {
    return host.createEachRowScope(parent_scope_id, ids.SiteOrdinal.fromRaw(site_ordinal), testHashHostValueKeyText(roc_host, key), key, item, key_cap, item_cap);
}

fn boxTestElem(roc_host: *abi.RocHost, elem: abi.Elem) *abi.Elem {
    const raw = abi.allocateBox(@sizeOf(abi.Elem), @alignOf(abi.Elem), true, roc_host);
    const boxed: *abi.Elem = @ptrCast(@alignCast(raw));
    boxed.* = elem;
    return boxed;
}

fn boxTestNodeSignalExpr(roc_host: *abi.RocHost, expr: abi.NodeSignalExpr) *abi.NodeSignalExpr {
    const raw = abi.allocateBox(@sizeOf(abi.NodeSignalExpr), @alignOf(abi.NodeSignalExpr), true, roc_host);
    const boxed: *abi.NodeSignalExpr = @ptrCast(@alignCast(raw));
    boxed.* = expr;
    return boxed;
}

fn newTestBinderToken(roc_host: *abi.RocHost) HostBinderToken {
    return writeTestErasedCallable(
        TestBinderInitialCapture,
        roc_host,
        &testBinderInitialCallable,
        &testBinderInitialOnDrop,
        .{ .value = .invalid, .initialized = false },
    ) orelse @panic("test binder initializer was null");
}

fn cloneTestBinderToken(token: HostBinderToken) HostBinderToken {
    abi.increfErasedCallable(token, 1);
    return token;
}

// These helpers build valid retained ABI shapes for host-level tests. Keep
// ownership and capability rules visible here instead of hiding them behind
// one-line wrappers around production value constructors.
fn cloneTestSignalToken(token: HostSignalToken) HostSignalToken {
    abi.increfErasedCallable(token, 1);
    return token;
}

fn testNodeConstExpr(roc_host: *abi.RocHost, value: HostValue) abi.NodeSignalExpr {
    const cap = testHostValueCapability(roc_host);
    const init = testHostValueInitialThunk(roc_host, value);
    abi.increfErasedCallable(init, 1);
    return .{
        .payload = .{ .const_value = .{
            ._0 = init,
            ._1 = init,
            ._2 = cap,
        } },
        .tag = .ConstValue,
    };
}

fn testNodeSignalExprCapability(signal: abi.NodeSignalExpr) ?HostValueCapability {
    return switch (signal.tag) {
        .ConstValue => signal.payload_const_value()._2,
        .Map => signal.payload_map()._3,
        .Map2 => signal.payload_map2()._4,
        .Combine => signal.payload_combine()._3,
        .TaskSource => signal.payload_task_source().cap,
        .IntervalSource => signal.payload_interval_source().cap,
        .LocationSource => signal.payload_location_source()._2,
        .OnlineSource => signal.payload_online_source()._2,
        .VisibilitySource => signal.payload_visibility_source()._2,
        .StorageSource => signal.payload_storage_source()._4,
        .Ref => null,
    };
}

fn testNodeSignalExprCapabilityOrPanic(signal: abi.NodeSignalExpr) HostValueCapability {
    return testNodeSignalExprCapability(signal) orelse @panic("test signal helper requires an explicit capability for Ref signals");
}

fn testTextReadHandle(roc_host: *abi.RocHost, cap: HostValueCapability) HostTextRead {
    return .{
        .capability = hv.retainHostValueCapability(cap),
        .read = testReadStrCallable(roc_host),
    };
}

fn testI64TextReadHandle(roc_host: *abi.RocHost, cap: HostValueCapability) HostTextRead {
    return .{
        .capability = hv.retainHostValueCapability(cap),
        .read = testHostValueKeyTextCallable(roc_host),
    };
}

fn testBoolReadHandle(roc_host: *abi.RocHost, cap: HostValueCapability) HostBoolRead {
    return .{
        .capability = hv.retainHostValueCapability(cap),
        .read = testReadBoolCallable(roc_host),
    };
}

fn testNodeRefExpr(binder_token: HostBinderToken) abi.NodeSignalExpr {
    return .{
        .payload = .{ .ref = cloneTestBinderToken(binder_token) },
        .tag = .Ref,
    };
}

fn testNodeMapExpr(roc_host: *abi.RocHost, input: abi.NodeSignalExpr) abi.NodeSignalExpr {
    const transform = writeTestErasedCallable(
        TestErasedI64Capture,
        roc_host,
        &testUnaryHostValueCallable,
        &testErasedCallableOnDrop,
        .{ .amount = 1 },
    );
    const cap = testHostValueCapability(roc_host);
    abi.increfErasedCallable(transform, 1);
    return .{
        .payload = .{
            .map = .{
                ._0 = transform,
                ._1 = boxTestNodeSignalExpr(roc_host, input),
                ._2 = transform,
                ._3 = cap,
            },
        },
        .tag = .Map,
    };
}

fn testNodeListContainsOneExpr(roc_host: *abi.RocHost, input: abi.NodeSignalExpr) abi.NodeSignalExpr {
    const cap = testHostValueCapability(roc_host);
    const transform = writeTestErasedCallable(TestCapabilityCapture, roc_host, &testI64ListContainsOneCallable, &testCapabilityCaptureOnDrop, .{ .cap = hv.retainHostValueCapability(cap) });
    abi.increfErasedCallable(transform, 1);
    return .{ .payload = .{ .map = .{
        ._0 = transform,
        ._1 = boxTestNodeSignalExpr(roc_host, input),
        ._2 = transform,
        ._3 = cap,
    } }, .tag = .Map };
}

/// A bool signal mapping the `List I64` in `input` through `predicate`.
fn testNodeListPredicateExpr(roc_host: *abi.RocHost, input: abi.NodeSignalExpr, predicate: TestListPredicate, operand: i64) abi.NodeSignalExpr {
    const cap = testHostValueCapability(roc_host);
    const transform = writeTestErasedCallable(TestListPredicateCapture, roc_host, &testI64ListPredicateCallable, &testListPredicateCaptureOnDrop, .{ .cap = hv.retainHostValueCapability(cap), .operand = operand, .predicate = @intFromEnum(predicate) });
    abi.increfErasedCallable(transform, 1);
    return .{ .payload = .{ .map = .{
        ._0 = transform,
        ._1 = boxTestNodeSignalExpr(roc_host, input),
        ._2 = transform,
        ._3 = cap,
    } }, .tag = .Map };
}

/// A `when` whose condition asks `predicate` of the list the state cell
/// `list_token` holds, so a dispatch into that cell can flip the branch.
fn testNodeWhenOnListPredicate(roc_host: *abi.RocHost, list_token: HostBinderToken, predicate: TestListPredicate, operand: i64, when_true: abi.Elem, when_false: abi.Elem) abi.Elem {
    return testNodeWhenWithSignal(roc_host, testNodeListPredicateExpr(roc_host, testNodeRefExpr(list_token), predicate, operand), when_true, when_false);
}

fn testNodeWhenWithSignal(roc_host: *abi.RocHost, condition: abi.NodeSignalExpr, when_true: abi.Elem, when_false: abi.Elem) abi.Elem {
    const condition_cap = testNodeSignalExprCapabilityOrPanic(condition);
    return .{ .payload = .{ .when = .{
        .condition = boxTestNodeSignalExpr(roc_host, condition),
        .read = testBoolReadHandle(roc_host, condition_cap),
        .when_false = boxTestElem(roc_host, when_false),
        .when_true = boxTestElem(roc_host, when_true),
    } }, .tag = .When };
}

fn testNodeMap2Expr(roc_host: *abi.RocHost, left: abi.NodeSignalExpr, right: abi.NodeSignalExpr) abi.NodeSignalExpr {
    const transform = writeTestErasedCallable(
        TestErasedI64Capture,
        roc_host,
        &testBinaryHostValueCallable,
        &testErasedCallableOnDrop,
        .{ .amount = 0 },
    );
    const cap = testHostValueCapability(roc_host);
    abi.increfErasedCallable(transform, 1);
    return .{
        .payload = .{
            .map2 = .{
                ._0 = transform,
                ._1 = boxTestNodeSignalExpr(roc_host, left),
                ._2 = boxTestNodeSignalExpr(roc_host, right),
                ._3 = transform,
                ._4 = cap,
            },
        },
        .tag = .Map2,
    };
}

fn testNodeStableStrMapExpr(roc_host: *abi.RocHost, input: abi.NodeSignalExpr) abi.NodeSignalExpr {
    const transform = writeTestErasedCallable(
        TestErasedI64Capture,
        roc_host,
        &testStableStrHostValueCallable,
        &testErasedCallableOnDrop,
        .{ .amount = 0 },
    );
    const cap = testHostValueCapability(roc_host);
    abi.increfErasedCallable(transform, 1);
    return .{
        .payload = .{
            .map = .{
                ._0 = transform,
                ._1 = boxTestNodeSignalExpr(roc_host, input),
                ._2 = transform,
                ._3 = cap,
            },
        },
        .tag = .Map,
    };
}

fn testNodeStableI64MapExpr(roc_host: *abi.RocHost, input: abi.NodeSignalExpr, value: i64) abi.NodeSignalExpr {
    const transform = writeTestErasedCallable(
        TestErasedI64Capture,
        roc_host,
        &testStableI64HostValueCallable,
        &testErasedCallableOnDrop,
        .{ .amount = value },
    );
    const cap = testHostValueCapability(roc_host);
    abi.increfErasedCallable(transform, 1);
    return .{
        .payload = .{
            .map = .{
                ._0 = transform,
                ._1 = boxTestNodeSignalExpr(roc_host, input),
                ._2 = transform,
                ._3 = cap,
            },
        },
        .tag = .Map,
    };
}

fn testNodeStableBoolMapExpr(roc_host: *abi.RocHost, input: abi.NodeSignalExpr) abi.NodeSignalExpr {
    const transform = writeTestErasedCallable(
        TestErasedI64Capture,
        roc_host,
        &testStableBoolHostValueCallable,
        &testErasedCallableOnDrop,
        .{ .amount = 0 },
    );
    const cap = testHostValueCapability(roc_host);
    abi.increfErasedCallable(transform, 1);
    return .{
        .payload = .{
            .map = .{
                ._0 = transform,
                ._1 = boxTestNodeSignalExpr(roc_host, input),
                ._2 = transform,
                ._3 = cap,
            },
        },
        .tag = .Map,
    };
}

fn testNodeBoolIdentityMapExpr(roc_host: *abi.RocHost, input: abi.NodeSignalExpr) abi.NodeSignalExpr {
    const transform = writeTestErasedCallable(
        TestErasedI64Capture,
        roc_host,
        &testBoolIdentityHostValueCallable,
        &testErasedCallableOnDrop,
        .{ .amount = 0 },
    );
    const cap = testHostValueCapability(roc_host);
    abi.increfErasedCallable(transform, 1);
    return .{
        .payload = .{
            .map = .{
                ._0 = transform,
                ._1 = boxTestNodeSignalExpr(roc_host, input),
                ._2 = transform,
                ._3 = cap,
            },
        },
        .tag = .Map,
    };
}

fn testNodeCombineExpr(roc_host: *abi.RocHost, children: []const abi.NodeSignalExpr) abi.NodeSignalExpr {
    const transform = writeTestErasedCallable(
        TestErasedI64Capture,
        roc_host,
        &testUnaryIdentityHostValueCallable,
        &testErasedCallableOnDrop,
        .{ .amount = 0 },
    );
    const cap = testHostValueCapabilityWithEq(roc_host, &testAlwaysEqualHostValueCallable);
    abi.increfErasedCallable(transform, 1);
    return .{
        .payload = .{
            .combine = .{
                ._0 = transform,
                ._1 = abi.RocList(abi.NodeSignalExpr).fromSlice(children, roc_host),
                ._2 = transform,
                ._3 = cap,
            },
        },
        .tag = .Combine,
    };
}

fn testNodeTaskSourceExpr(roc_host: *abi.RocHost, name: []const u8, initial_text: []const u8, reset_on_start: bool) abi.NodeSignalExpr {
    const host = hostFromRocHost(roc_host);
    const cap = testHostValueCapability(roc_host);
    const payload_cap = testHostValueCapability(roc_host);
    const initial_value = hostValueStrWithCapability(host, roc_host, initial_text, cap);
    const payload_capture = TestTaskPayloadCapture{ .payload_cap = payload_cap };
    const initial = testHostValueInitialThunk(roc_host, initial_value);
    abi.increfErasedCallable(initial, 1);
    return .{
        .payload = .{ .task_source = .{
            .cap = cap,
            .done = writeTestErasedCallable(
                TestTaskPayloadCapture,
                roc_host,
                &testConsumeTaskPayloadStrCallable,
                &testErasedCallableOnDrop,
                payload_capture,
            ),
            .failed = writeTestErasedCallable(
                TestTaskPayloadCapture,
                roc_host,
                &testConsumeTaskPayloadStrCallable,
                &testErasedCallableOnDrop,
                payload_capture,
            ),
            .initial = initial,
            .name = RocStr.fromSlice(name, roc_host),
            .payload_cap = payload_cap,
            .token = initial,
            .reset_on_start = reset_on_start,
        } },
        .tag = .TaskSource,
    };
}

fn testNodeIntervalSourceExpr(roc_host: *abi.RocHost, period_ms: u64, initial_value: i64) abi.NodeSignalExpr {
    const host = hostFromRocHost(roc_host);
    const cap = testHostValueCapability(roc_host);
    const initial = testHostValueInitialThunk(roc_host, hv.makeI64WithCapability(host, roc_host, initial_value, cap));
    abi.increfErasedCallable(initial, 1);
    return .{
        .payload = .{ .interval_source = .{
            .period_ms = period_ms,
            .cap = cap,
            .initial = initial,
            .tick = writeTestErasedCallable(
                TestErasedI64Capture,
                roc_host,
                &testUnaryHostValueCallable,
                &testErasedCallableOnDrop,
                .{ .amount = 1 },
            ),
            .token = initial,
        } },
        .tag = .IntervalSource,
    };
}

fn testNodeIntervalListSourceExpr(roc_host: *abi.RocHost, period_ms: u64, initial_value: HostValue) abi.NodeSignalExpr {
    const cap = testHostValueCapability(roc_host);
    const initial = testHostValueInitialThunk(roc_host, initial_value);
    abi.increfErasedCallable(initial, 1);
    return .{
        .payload = .{ .interval_source = .{
            .period_ms = period_ms,
            .cap = cap,
            .initial = initial,
            .tick = writeTestErasedCallable(
                TestErasedI64Capture,
                roc_host,
                &testUnaryIdentityHostValueCallable,
                &testErasedCallableOnDrop,
                .{ .amount = 0 },
            ),
            .token = initial,
        } },
        .tag = .IntervalSource,
    };
}

fn testPayloadChecksumCallable(roc_host: *abi.RocHost, cap: HostValueCapability) abi.RocErasedCallable {
    return writeTestErasedCallable(
        TestPayloadTransformCapture,
        roc_host,
        &testPayloadChecksumHostValueCallable,
        &testErasedCallableOnDrop,
        .{ .cap = cap },
    );
}

fn testLocationCmdCallableFor(roc_host: *abi.RocHost, tag: abi.NodeCmdTag, path: []const u8, query: []const u8, hash: []const u8) abi.RocErasedCallable {
    return writeTestErasedCallable(
        TestLocationCmdCapture,
        roc_host,
        &testLocationCmdCallable,
        &testLocationCmdCaptureOnDrop,
        .{
            .tag = tag,
            .path = RocStr.fromSlice(path, roc_host),
            .query = RocStr.fromSlice(query, roc_host),
            .hash = RocStr.fromSlice(hash, roc_host),
        },
    );
}

fn testLocationPathEqualsCallable(roc_host: *abi.RocHost, cap: HostValueCapability, path: []const u8) abi.RocErasedCallable {
    return writeTestErasedCallable(
        TestLocationPathEqualsCapture,
        roc_host,
        &testLocationPathEqualsHostValueCallable,
        &testLocationPathEqualsCaptureOnDrop,
        .{
            .cap = cap,
            .path = RocStr.fromSlice(path, roc_host),
        },
    );
}

fn testNodeLocationSourceExpr(roc_host: *abi.RocHost) abi.NodeSignalExpr {
    const cap = testHostValueCapability(roc_host);
    const payload_cap = testHostValueCapability(roc_host);
    const from_payload = testPayloadChecksumCallable(roc_host, cap);
    abi.increfErasedCallable(from_payload, 1);
    return .{
        .payload = .{ .location_source = .{
            ._0 = from_payload,
            ._1 = from_payload,
            ._2 = cap,
            ._3 = payload_cap,
        } },
        .tag = .LocationSource,
    };
}

fn testNodeLocationPathEqualsSourceExpr(roc_host: *abi.RocHost, path: []const u8) abi.NodeSignalExpr {
    const cap = testHostValueCapability(roc_host);
    const payload_cap = testHostValueCapability(roc_host);
    const from_payload = testLocationPathEqualsCallable(roc_host, cap, path);
    abi.increfErasedCallable(from_payload, 1);
    return .{
        .payload = .{ .location_source = .{
            ._0 = from_payload,
            ._1 = from_payload,
            ._2 = cap,
            ._3 = payload_cap,
        } },
        .tag = .LocationSource,
    };
}

fn testNodeVisibilitySourceExpr(roc_host: *abi.RocHost) abi.NodeSignalExpr {
    const cap = testHostValueCapability(roc_host);
    const payload_cap = testHostValueCapability(roc_host);
    const from_payload = testPayloadChecksumCallable(roc_host, cap);
    abi.increfErasedCallable(from_payload, 1);
    return .{
        .payload = .{ .visibility_source = .{
            ._0 = from_payload,
            ._1 = from_payload,
            ._2 = cap,
            ._3 = payload_cap,
        } },
        .tag = .VisibilitySource,
    };
}

fn testNodeOnlineSourceExpr(roc_host: *abi.RocHost) abi.NodeSignalExpr {
    const cap = testHostValueCapability(roc_host);
    const payload_cap = testHostValueCapability(roc_host);
    const from_payload = testPayloadChecksumCallable(roc_host, cap);
    abi.increfErasedCallable(from_payload, 1);
    return .{
        .payload = .{ .online_source = .{
            ._0 = from_payload,
            ._1 = from_payload,
            ._2 = cap,
            ._3 = payload_cap,
        } },
        .tag = .OnlineSource,
    };
}

fn testNodeStorageSourceExpr(roc_host: *abi.RocHost, area: boundary.StorageArea, key: []const u8) abi.NodeSignalExpr {
    const cap = testHostValueCapability(roc_host);
    const payload_cap = testHostValueCapability(roc_host);
    const from_payload = testPayloadChecksumCallable(roc_host, cap);
    abi.increfErasedCallable(from_payload, 1);
    return .{
        .payload = .{ .storage_source = .{
            ._1 = @intFromEnum(area),
            ._0 = from_payload,
            ._2 = RocStr.fromSlice(key, roc_host),
            ._3 = from_payload,
            ._4 = cap,
            ._5 = payload_cap,
        } },
        .tag = .StorageSource,
    };
}

fn testNodeText(roc_host: *abi.RocHost, text: []const u8) abi.Elem {
    return .{
        .payload = .{ .text = RocStr.fromSlice(text, roc_host) },
        .tag = .Text,
    };
}

fn testNodeTextSignal(roc_host: *abi.RocHost, signal: abi.NodeSignalExpr) abi.Elem {
    const cap = testNodeSignalExprCapabilityOrPanic(signal);
    return testNodeTextSignalWithCapability(roc_host, signal, cap);
}

fn testNodeTextSignalWithCapability(roc_host: *abi.RocHost, signal: abi.NodeSignalExpr, cap: HostValueCapability) abi.Elem {
    return .{
        .payload = .{ .text_signal = .{
            .read = testTextReadHandle(roc_host, cap),
            .signal = boxTestNodeSignalExpr(roc_host, signal),
        } },
        .tag = .TextSignal,
    };
}

fn testNodeI64TextSignal(roc_host: *abi.RocHost, signal: abi.NodeSignalExpr) abi.Elem {
    const cap = testNodeSignalExprCapabilityOrPanic(signal);
    return .{
        .payload = .{ .text_signal = .{
            .read = testI64TextReadHandle(roc_host, cap),
            .signal = boxTestNodeSignalExpr(roc_host, signal),
        } },
        .tag = .TextSignal,
    };
}

fn testNodeStaticTextAttr(roc_host: *abi.RocHost, field: RenderTextField, value: []const u8) abi.NodeAttr {
    return .{
        .payload = .{
            .static_text = .{
                .field = .{ .id = @intFromEnum(field) },
                .name = RocStr.fromSlice("", roc_host),
                .value = RocStr.fromSlice(value, roc_host),
            },
        },
        .tag = .StaticText,
    };
}

fn testNodeStaticCustomTextAttr(roc_host: *abi.RocHost, name: []const u8, value: []const u8) abi.NodeAttr {
    return .{
        .payload = .{
            .static_text = .{
                .field = .{ .id = NodeFieldCustom },
                .name = RocStr.fromSlice(name, roc_host),
                .value = RocStr.fromSlice(value, roc_host),
            },
        },
        .tag = .StaticText,
    };
}

fn testNodeSignalTextAttr(roc_host: *abi.RocHost, field: RenderTextField, signal: abi.NodeSignalExpr) abi.NodeAttr {
    const cap = testNodeSignalExprCapabilityOrPanic(signal);
    return testNodeSignalTextAttrWithCapability(roc_host, field, signal, cap);
}

fn testNodeSignalTextAttrWithCapability(roc_host: *abi.RocHost, field: RenderTextField, signal: abi.NodeSignalExpr, cap: HostValueCapability) abi.NodeAttr {
    return .{
        .payload = .{
            .signal_text = .{
                .field = .{ .id = @intFromEnum(field) },
                .name = RocStr.fromSlice("", roc_host),
                .read = testTextReadHandle(roc_host, cap),
                .signal = boxTestNodeSignalExpr(roc_host, signal),
            },
        },
        .tag = .SignalText,
    };
}

fn testNodeStaticBoolAttr(field: RenderBoolField, value: bool) abi.NodeAttr {
    return .{
        .payload = .{
            .static_bool = .{
                .field = .{ .id = @intFromEnum(field) },
                .name = RocStr.empty(),
                .value = value,
            },
        },
        .tag = .StaticBool,
    };
}

fn testNodeSignalBoolAttr(roc_host: *abi.RocHost, field: RenderBoolField, signal: abi.NodeSignalExpr) abi.NodeAttr {
    const cap = testNodeSignalExprCapabilityOrPanic(signal);
    return testNodeSignalBoolAttrWithCapability(roc_host, field, signal, cap);
}

fn testNodeSignalBoolAttrWithCapability(roc_host: *abi.RocHost, field: RenderBoolField, signal: abi.NodeSignalExpr, cap: HostValueCapability) abi.NodeAttr {
    return .{
        .payload = .{
            .signal_bool = .{
                .field = .{ .id = @intFromEnum(field) },
                .name = RocStr.fromSlice("", roc_host),
                .read = testBoolReadHandle(roc_host, cap),
                .signal = boxTestNodeSignalExpr(roc_host, signal),
            },
        },
        .tag = .SignalBool,
    };
}

fn testExtractionPlanForKind(payload_kind: EventPayloadKind) EventExtractionPlanKind {
    return switch (payload_kind) {
        .unit => .none,
        .str => .target_value,
        .bool => .target_checked,
        .bytes => .record_key_shift,
    };
}

fn testEventExtractionPlan(roc_host: *abi.RocHost, extraction_plan: EventExtractionPlanKind) abi.NodeEventExtractionPlan {
    return .{
        .bytes = abi.RocListWith(u8, false).fromSlice(extraction_plan.bytes(), roc_host),
    };
}

fn testNodeEventPolicy(bits: u32) abi.NodeEventBindingPolicy {
    const policy = render.EventPolicy.fromWireBits(bits);
    return .{
        .capture = policy.capture,
        .once = policy.once,
        .passive = policy.passive,
        .prevent_default = policy.prevent_default,
        .self = policy.self,
        .stop_immediate = policy.stop_immediate,
        .stop_propagation = policy.stop_propagation,
        .trusted = policy.trusted,
    };
}

fn testNodeEventDelivery(native: bool) abi.NodeEventDelivery {
    return .{ .native = native };
}

fn testNodeEventAttr(roc_host: *abi.RocHost, kind: RenderEventKind, binder_token: HostBinderToken, payload_kind: EventPayloadKind) abi.NodeAttr {
    const extraction_plan = testExtractionPlanForKind(payload_kind);
    const transform = writeTestErasedCallable(
        TestErasedI64Capture,
        roc_host,
        &testTernaryEventHostValueCallable,
        &testErasedCallableOnDrop,
        .{ .amount = 0 },
    );
    const payload_cap = testHostValueCapability(roc_host);
    return .{
        .payload = .{
            .on = .{
                .kind = .{ .id = @intFromEnum(kind) },
                .msg = .{
                    .binder = cloneTestBinderToken(binder_token),
                    .read_binder = cloneTestBinderToken(binder_token),
                    .event_extraction_plan = testEventExtractionPlan(roc_host, extraction_plan),
                    .payload_reducer = .{
                        .capability = payload_cap,
                        .read_capability = hv.retainHostValueCapability(payload_cap),
                        .transform = transform,
                    },
                },
                .name = RocStr.empty(),
                .delivery = testNodeEventDelivery(false),
                .policy = testNodeEventPolicy(0),
            },
        },
        .tag = .On,
    };
}

fn testNodeUnitIncrementEventAttr(roc_host: *abi.RocHost, kind: RenderEventKind, binder_token: HostBinderToken) abi.NodeAttr {
    const transform = writeTestErasedCallable(
        TestErasedI64Capture,
        roc_host,
        &testUnitIncrementHostValueCallable,
        &testErasedCallableOnDrop,
        .{ .amount = 0 },
    );
    const payload_cap = testHostValueCapability(roc_host);
    return .{
        .payload = .{
            .on = .{
                .kind = .{ .id = @intFromEnum(kind) },
                .msg = .{
                    .binder = cloneTestBinderToken(binder_token),
                    .read_binder = cloneTestBinderToken(binder_token),
                    .event_extraction_plan = testEventExtractionPlan(roc_host, .none),
                    .payload_reducer = .{
                        .capability = payload_cap,
                        .read_capability = hv.retainHostValueCapability(payload_cap),
                        .transform = transform,
                    },
                },
                .name = RocStr.empty(),
                .delivery = testNodeEventDelivery(false),
                .policy = testNodeEventPolicy(0),
            },
        },
        .tag = .On,
    };
}

fn testElementWith(roc_host: *abi.RocHost, tag: []const u8, attrs: []const abi.NodeAttr, children: []const abi.Elem) abi.Elem {
    return .{
        .payload = .{
            .element = .{
                .attrs = abi.RocList(abi.NodeAttr).fromSlice(attrs, roc_host),
                .children = abi.RocList(abi.Elem).fromSlice(children, roc_host),
                .tag = RocStr.fromSlice(tag, roc_host),
            },
        },
        .tag = .Element,
    };
}

fn testElement(roc_host: *abi.RocHost, children: []const abi.Elem) abi.Elem {
    return testElementWith(roc_host, "div", &.{}, children);
}

fn testNodeOnChange(roc_host: *abi.RocHost, signal: abi.NodeSignalExpr, to_cmd: abi.RocErasedCallable) abi.Elem {
    return .{
        .payload = .{ .on_change = .{
            .signal = boxTestNodeSignalExpr(roc_host, signal),
            .to_cmd = to_cmd,
        } },
        .tag = .OnChange,
    };
}

fn testNodeOnChangeInitial(roc_host: *abi.RocHost, signal: abi.NodeSignalExpr, to_cmd: abi.RocErasedCallable) abi.Elem {
    return .{
        .payload = .{ .on_change_initial = .{
            .signal = boxTestNodeSignalExpr(roc_host, signal),
            .to_cmd = to_cmd,
        } },
        .tag = .OnChangeInitial,
    };
}

fn testHostValueInitialThunk(roc_host: *abi.RocHost, initial: HostValue) abi.RocErasedCallable {
    return writeTestErasedCallable(
        TestErasedHostValueCapture,
        roc_host,
        &testInitialHostValueCallable,
        &testHostValueCaptureOnDrop,
        .{ .value = initial },
    );
}

fn testStartTaskCmd(roc_host: *abi.RocHost, task_source: abi.NodeSignalExpr, name: []const u8, request: []const u8) erased_calls.StartTaskCmd {
    const host = hostFromRocHost(roc_host);
    const task_payload = task_source.payload_task_source();
    const request_cap = testHostValueCapability(roc_host);
    const request_value = hostValueStrWithCapability(host, roc_host, request, request_cap);
    return .{
        .request_init = testHostValueInitialThunk(roc_host, request_value),
        .request_read = .{
            .capability = request_cap,
            .read = testReadStrCallable(roc_host),
        },
        .task_name = RocStr.fromSlice(name, roc_host),
        .task_token = cloneTestSignalToken(task_payload.token.?),
    };
}

fn testLocationCmd(roc_host: *abi.RocHost, tag: abi.NodeCmdTag, location: boundary.LocationSnapshot) erased_calls.Cmd {
    return .{
        .payload = switch (tag) {
            .PushState => .{ .push_state = .{
                .hash = RocStr.fromSlice(location.hash, roc_host),
                .path = RocStr.fromSlice(location.path, roc_host),
                .query = RocStr.fromSlice(location.query, roc_host),
            } },
            .ReplaceState => .{ .replace_state = .{
                .hash = RocStr.fromSlice(location.hash, roc_host),
                .path = RocStr.fromSlice(location.path, roc_host),
                .query = RocStr.fromSlice(location.query, roc_host),
            } },
            else => @panic("testLocationCmd requires PushState or ReplaceState"),
        },
        .tag = tag,
    };
}

fn testStorageSetCmd(roc_host: *abi.RocHost, area: boundary.StorageArea, key: []const u8, value: []const u8) erased_calls.Cmd {
    return .{
        .payload = .{ .set_storage_text = .{
            .area = @intFromEnum(area),
            .key = RocStr.fromSlice(key, roc_host),
            .value = RocStr.fromSlice(value, roc_host),
        } },
        .tag = .SetStorageText,
    };
}

fn testStorageRemoveCmd(roc_host: *abi.RocHost, area: boundary.StorageArea, key: []const u8) erased_calls.Cmd {
    return .{
        .payload = .{ .remove_storage = .{
            .area = @intFromEnum(area),
            .key = RocStr.fromSlice(key, roc_host),
        } },
        .tag = .RemoveStorage,
    };
}

fn testDocumentTitleCmd(roc_host: *abi.RocHost, title: []const u8) erased_calls.Cmd {
    return .{
        .payload = .{ .set_document_title = .{
            .title = RocStr.fromSlice(title, roc_host),
        } },
        .tag = .SetDocumentTitle,
    };
}

fn retainTestCmd(cmd: erased_calls.Cmd) void {
    cmd.incref(1);
}

fn releaseTestCmd(roc_host: *abi.RocHost, cmd: erased_calls.Cmd) void {
    cmd.decref(roc_host);
}

fn testNodeStateWithTokenAndInitial(roc_host: *abi.RocHost, binder_token: HostBinderToken, initial: HostValue, child: abi.Elem) abi.Elem {
    const cap = testHostValueCapability(roc_host);
    return testNodeStateWithTokenAndInitialCapability(roc_host, binder_token, initial, child, cap);
}

fn testNodeStateWithTokenAndInitialCapability(roc_host: *abi.RocHost, binder_token: HostBinderToken, initial: HostValue, child: abi.Elem, cap: HostValueCapability) abi.Elem {
    const capture = testCapturePtrAs(TestBinderInitialCapture, abi.rocErasedCallableCapturePtr(binder_token));
    if (capture.initialized) {
        testDropHostValue(roc_host, initial);
    } else {
        capture.value = initial;
        capture.initialized = true;
    }
    abi.increfErasedCallable(binder_token, 1);
    return .{
        .payload = .{
            .state = .{
                .binder = binder_token,
                .child = boxTestElem(roc_host, child),
                .cap = cap,
                .initial = binder_token,
            },
        },
        .tag = .State,
    };
}

fn testNodeStateWithToken(roc_host: *abi.RocHost, binder_token: HostBinderToken, child: abi.Elem) abi.Elem {
    return testNodeStateWithTokenAndInitial(roc_host, binder_token, testHostValueI64(0), child);
}

fn testNodeState(roc_host: *abi.RocHost, child: abi.Elem) abi.Elem {
    return testNodeStateWithToken(roc_host, newTestBinderToken(roc_host), child);
}

fn testNodeWhen(roc_host: *abi.RocHost, when_true: abi.Elem, when_false: abi.Elem) abi.Elem {
    const condition = testNodeConstExpr(roc_host, testHostValueBool(true));
    const condition_cap = testNodeSignalExprCapabilityOrPanic(condition);
    return .{
        .payload = .{
            .when = .{
                .condition = boxTestNodeSignalExpr(roc_host, condition),
                .read = testBoolReadHandle(roc_host, condition_cap),
                .when_false = boxTestElem(roc_host, when_false),
                .when_true = boxTestElem(roc_host, when_true),
            },
        },
        .tag = .When,
    };
}

fn testHostValueI64List(roc_host: *abi.RocHost, items: []const HostValue) HostValue {
    const host = hostFromRocHost(roc_host);
    const values = I64List.allocate(items.len, roc_host);
    if (items.len > 0) {
        const dest = values.elements_ptr orelse unreachable;
        for (items, 0..) |item, index| {
            dest[index] = testReadHostValueI64(roc_host, item);
            testDropHostValue(roc_host, item);
        }
    }
    const payload: *I64List = @ptrCast(@alignCast(abi.allocateBox(@sizeOf(I64List), @alignOf(I64List), true, roc_host)));
    payload.* = values;
    const host_value = host.storeHostValue(@ptrCast(payload));
    host.setTestHostValueKind(host_value, .i64_list);
    return capabilityTestHostValue(host, roc_host, host_value);
}

fn testHostValueI64ListWithCapability(roc_host: *abi.RocHost, items: []const HostValue, cap: HostValueCapability) HostValue {
    const host = hostFromRocHost(roc_host);
    const values = I64List.allocate(items.len, roc_host);
    if (items.len > 0) {
        const dest = values.elements_ptr orelse unreachable;
        for (items, 0..) |item, index| {
            dest[index] = testReadHostValueI64(roc_host, item);
            testDropHostValue(roc_host, item);
        }
    }
    const payload: *I64List = @ptrCast(@alignCast(abi.allocateBox(@sizeOf(I64List), @alignOf(I64List), true, roc_host)));
    payload.* = values;
    const value = host.storeHostValue(@ptrCast(payload));
    host.setTestHostValueKind(value, .i64_list);
    host.setHostValueCapability(value, cap);
    return value;
}

fn testNodeEachWithSignalAndRow(roc_host: *abi.RocHost, signal: abi.NodeSignalExpr, row_fn: abi.RocErasedCallableFn) abi.Elem {
    const items_cap = testNodeSignalExprCapabilityOrPanic(signal);
    return testNodeEachWithSignalCapabilityAndRow(roc_host, signal, items_cap, row_fn);
}

fn testNodeEachWithSignalCapabilityAndRow(roc_host: *abi.RocHost, signal: abi.NodeSignalExpr, items_cap: HostValueCapability, row_fn: abi.RocErasedCallableFn) abi.Elem {
    return testNodeEachWithSignalCapabilityRowAndCapture(TestErasedI64Capture, roc_host, signal, items_cap, row_fn, .{ .amount = 0 });
}

/// Builds a keyed-list fixture whose row callable carries an arbitrary capture,
/// so a generated program can describe what every row should render.
fn testNodeEachWithItemsRowAndCapture(comptime Capture: type, roc_host: *abi.RocHost, items: []const HostValue, row_fn: abi.RocErasedCallableFn, capture: Capture) abi.Elem {
    const signal = testNodeConstExpr(roc_host, testHostValueI64List(roc_host, items));
    const items_cap = testNodeSignalExprCapabilityOrPanic(signal);
    return testNodeEachWithSignalCapabilityRowAndCapture(Capture, roc_host, signal, items_cap, row_fn, capture);
}

fn testNodeEachWithSignalCapabilityRowAndCapture(comptime Capture: type, roc_host: *abi.RocHost, signal: abi.NodeSignalExpr, items_cap: HostValueCapability, row_fn: abi.RocErasedCallableFn, capture: Capture) abi.Elem {
    return testNodeEachWithSignalCapabilityKeyOfRowAndCapture(Capture, roc_host, signal, items_cap, &testUnaryHostValueCallable, .{ .amount = 0 }, row_fn, capture);
}

/// Builds a keyed-list fixture whose `key_of` is chosen by the caller, so a
/// test can give different item values the same row key.
fn testNodeEachWithSignalCapabilityKeyOfRowAndCapture(comptime Capture: type, roc_host: *abi.RocHost, signal: abi.NodeSignalExpr, items_cap: HostValueCapability, key_of_fn: abi.RocErasedCallableFn, key_of_capture: TestErasedI64Capture, row_fn: abi.RocErasedCallableFn, capture: Capture) abi.Elem {
    const key_cap = testHostValueCapability(roc_host);
    const key_of = writeTestErasedCallable(
        TestErasedI64Capture,
        roc_host,
        key_of_fn,
        &testErasedCallableOnDrop,
        key_of_capture,
    );
    const key_text = testHostValueKeyTextCallable(roc_host);
    const item_cap = testHostValueCapability(roc_host);
    const items_to_values = testItemsToValuesCallable(roc_host);
    const row = writeTestErasedCallable(
        Capture,
        roc_host,
        row_fn,
        &testErasedCallableOnDrop,
        capture,
    );
    return .{
        .payload = .{
            .each = .{
                .items = boxTestNodeSignalExpr(roc_host, signal),
                .ops = .{
                    .items_capability = hv.retainHostValueCapability(items_cap),
                    .item_capability = item_cap,
                    .key_capability = key_cap,
                    .items_to_values = items_to_values,
                    .key_text = key_text,
                    .key_of = key_of,
                    .row = row,
                },
            },
        },
        .tag = .Each,
    };
}

fn testNodeI64ListCopyMapExpr(roc_host: *abi.RocHost, input: abi.NodeSignalExpr) abi.NodeSignalExpr {
    const cap = testHostValueCapability(roc_host);
    const transform = writeTestErasedCallable(
        TestCapabilityCapture,
        roc_host,
        &testI64ListCopyCallable,
        &testCapabilityCaptureOnDrop,
        .{ .cap = hv.retainHostValueCapability(cap) },
    );
    abi.increfErasedCallable(transform, 1);
    return .{
        .payload = .{
            .map = .{
                ._0 = transform,
                ._1 = boxTestNodeSignalExpr(roc_host, input),
                ._2 = transform,
                ._3 = cap,
            },
        },
        .tag = .Map,
    };
}

/// An `each` whose items signal is a bare `Ref` to the state cell `binder_token`
/// binds; `state_cap` is that cell's value capability.
fn testNodeEachOverStateListRowAndCapture(comptime Capture: type, roc_host: *abi.RocHost, binder_token: HostBinderToken, state_cap: HostValueCapability, row_fn: abi.RocErasedCallableFn, capture: Capture) abi.Elem {
    return testNodeEachWithSignalCapabilityRowAndCapture(Capture, roc_host, testNodeRefExpr(binder_token), state_cap, row_fn, capture);
}

fn testNodeEachWithItemsAndRow(roc_host: *abi.RocHost, items: []const HostValue, row_fn: abi.RocErasedCallableFn) abi.Elem {
    return testNodeEachWithSignalAndRow(roc_host, testNodeConstExpr(roc_host, testHostValueI64List(roc_host, items)), row_fn);
}

fn testNodeEachSignalWithNestedWhenRows(roc_host: *abi.RocHost, items_signal: abi.NodeSignalExpr, items_cap: HostValueCapability, condition_binder: HostBinderToken, condition_cap: HostValueCapability) abi.Elem {
    const key_cap = testHostValueCapability(roc_host);
    const key_of = writeTestErasedCallable(
        TestErasedI64Capture,
        roc_host,
        &testUnaryHostValueCallable,
        &testErasedCallableOnDrop,
        .{ .amount = 0 },
    );
    const key_text = testHostValueKeyTextCallable(roc_host);
    const item_cap = testHostValueCapability(roc_host);
    const items_to_values = testItemsToValuesCallable(roc_host);
    const row = writeTestErasedCallable(
        TestErasedBinderCapture,
        roc_host,
        &testNestedWhenRowElemCallable,
        &testBinderCaptureOnDrop,
        .{
            .condition_binder = cloneTestBinderToken(condition_binder),
            .condition_cap = hv.retainHostValueCapability(condition_cap),
        },
    );
    return .{
        .payload = .{
            .each = .{
                .items = boxTestNodeSignalExpr(roc_host, items_signal),
                .ops = .{
                    .items_capability = hv.retainHostValueCapability(items_cap),
                    .item_capability = item_cap,
                    .key_capability = key_cap,
                    .items_to_values = items_to_values,
                    .key_text = key_text,
                    .key_of = key_of,
                    .row = row,
                },
            },
        },
        .tag = .Each,
    };
}

fn testNodeEachWithNestedWhenRows(roc_host: *abi.RocHost, items: []const HostValue, condition_binder: HostBinderToken, condition_cap: HostValueCapability) abi.Elem {
    const items_signal = testNodeConstExpr(roc_host, testHostValueI64List(roc_host, items));
    const items_cap = testNodeSignalExprCapabilityOrPanic(items_signal);
    return testNodeEachSignalWithNestedWhenRows(roc_host, items_signal, items_cap, condition_binder, condition_cap);
}

fn testNodeEachWithItems(roc_host: *abi.RocHost, items: []const HostValue) abi.Elem {
    return testNodeEachWithItemsAndRow(roc_host, items, &testStatefulRowElemCallable);
}

fn testNodeEach(roc_host: *abi.RocHost) abi.Elem {
    return testNodeEachWithItems(roc_host, &.{});
}

fn activeTextElementId(host: *const HostEnv, text: []const u8) ?u64 {
    for (host.dom_elements.items) |elem| {
        if (!elem.active) continue;
        const elem_text = elem.text orelse continue;
        if (std.mem.eql(u8, elem_text, text)) return elem.id;
    }
    return null;
}

test "signals host keyed row diff reuses creates and removes by typed key" {
    test_erased_callable_drop_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        deinitTestHostIdentity(&host);
        _ = host.gpa.deinit();
    }

    const key_cap = testHostValueCapability(&roc_host);
    defer key_cap.decref(&roc_host);

    const root = host.internRootScope();

    const initial_keys = [_]HostValue{ testHostValueI64(1), testHostValueI64(2), testHostValueI64(3) };
    const initial = syncTestEachRowScopes(&host, &roc_host, root, 5, &initial_keys, &initial_keys, key_cap, key_cap);
    defer freeKeyedRowDiff(&host, initial);
    try std.testing.expectEqual(@as(u64, 0), initial.rows_reused);
    try std.testing.expectEqual(@as(u64, 3), initial.rows_created);
    try std.testing.expectEqual(@as(u64, 0), initial.rows_removed);
    try std.testing.expectEqual(@as(u64, 0), initial.row_items_unchanged);
    try std.testing.expectEqual(@as(u64, 0), initial.row_items_updated);

    const state_for_key_2 = host.internNodeIdentity(initial.scope_ids[1], ids.SiteOrdinal.fromRaw(0));

    const reordered_keys = [_]HostValue{ testHostValueI64(3), testHostValueI64(1), testHostValueI64(2) };
    const reordered = syncTestEachRowScopes(&host, &roc_host, root, 5, &reordered_keys, &reordered_keys, key_cap, key_cap);
    defer freeKeyedRowDiff(&host, reordered);
    try std.testing.expectEqual(@as(u64, 3), reordered.rows_reused);
    try std.testing.expectEqual(@as(u64, 0), reordered.rows_created);
    try std.testing.expectEqual(@as(u64, 0), reordered.rows_removed);
    try std.testing.expectEqual(@as(u64, 3), reordered.row_items_unchanged);
    try std.testing.expectEqual(@as(u64, 0), reordered.row_items_updated);
    try std.testing.expectEqual(initial.scope_ids[2], reordered.scope_ids[0]);
    try std.testing.expectEqual(initial.scope_ids[0], reordered.scope_ids[1]);
    try std.testing.expectEqual(initial.scope_ids[1], reordered.scope_ids[2]);
    try std.testing.expectEqual(state_for_key_2, host.internNodeIdentity(reordered.scope_ids[2], ids.SiteOrdinal.fromRaw(0)));

    const changed_keys = [_]HostValue{ testHostValueI64(2), testHostValueI64(4) };
    const changed_items = [_]HostValue{ testHostValueI64(22), testHostValueI64(4) };
    const changed = syncTestEachRowScopes(&host, &roc_host, root, 5, &changed_keys, &changed_items, key_cap, key_cap);
    defer freeKeyedRowDiff(&host, changed);
    try std.testing.expectEqual(@as(u64, 1), changed.rows_reused);
    try std.testing.expectEqual(@as(u64, 1), changed.rows_created);
    try std.testing.expectEqual(@as(u64, 2), changed.rows_removed);
    try std.testing.expectEqual(@as(u64, 0), changed.row_items_unchanged);
    try std.testing.expectEqual(@as(u64, 1), changed.row_items_updated);
    try std.testing.expectEqual(initial.scope_ids[1], changed.scope_ids[0]);
    try std.testing.expect(changed.scope_ids[1] != initial.scope_ids[0]);
    try std.testing.expect(changed.scope_ids[1] != initial.scope_ids[2]);

    const reappeared_keys = [_]HostValue{ testHostValueI64(1), testHostValueI64(2), testHostValueI64(4) };
    const reappeared = syncTestEachRowScopes(&host, &roc_host, root, 5, &reappeared_keys, &reappeared_keys, key_cap, key_cap);
    defer freeKeyedRowDiff(&host, reappeared);
    try std.testing.expectEqual(@as(u64, 2), reappeared.rows_reused);
    try std.testing.expectEqual(@as(u64, 1), reappeared.rows_created);
    try std.testing.expectEqual(@as(u64, 0), reappeared.rows_removed);
    try std.testing.expectEqual(@as(u64, 1), reappeared.row_items_unchanged);
    try std.testing.expectEqual(@as(u64, 1), reappeared.row_items_updated);
    try std.testing.expect(initial.scope_ids[0] != reappeared.scope_ids[0]);
    try std.testing.expectEqual(initial.scope_ids[1], reappeared.scope_ids[1]);
    try std.testing.expectEqual(changed.scope_ids[1], reappeared.scope_ids[2]);

    try std.testing.expectEqual(@as(u64, 6), host.engine.pending_roc_metrics.rows_reused);
    try std.testing.expectEqual(@as(u64, 5), host.engine.pending_roc_metrics.rows_created);
    try std.testing.expectEqual(@as(u64, 2), host.engine.pending_roc_metrics.rows_removed);
}

test "signals host keyed row diff hash probes scale linearly" {
    test_erased_callable_drop_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        deinitTestHostIdentity(&host);
        _ = host.gpa.deinit();
    }

    const key_cap = testHostValueCapability(&roc_host);
    defer key_cap.decref(&roc_host);

    const root = host.internRootScope();
    const row_count = 64;

    var initial_keys: [row_count]HostValue = undefined;
    for (&initial_keys, 0..) |*key, index| {
        key.* = testHostValueI64(@intCast(index + 1));
    }
    const initial = syncTestEachRowScopes(&host, &roc_host, root, 5, &initial_keys, &initial_keys, key_cap, key_cap);
    defer freeKeyedRowDiff(&host, initial);
    try std.testing.expectEqual(@as(u64, row_count), initial.rows_created);

    const metrics_start = host.engine.pending_roc_metrics;

    var reordered_keys: [row_count]HostValue = undefined;
    for (&reordered_keys, 0..) |*key, index| {
        key.* = testHostValueI64(@intCast(row_count - index));
    }
    const reordered = syncTestEachRowScopes(&host, &roc_host, root, 5, &reordered_keys, &reordered_keys, key_cap, key_cap);
    defer freeKeyedRowDiff(&host, reordered);
    try std.testing.expectEqual(@as(u64, row_count), reordered.rows_reused);
    try std.testing.expectEqual(@as(u64, 0), reordered.rows_created);
    try std.testing.expectEqual(@as(u64, 0), reordered.rows_removed);

    const metrics_end = host.engine.pending_roc_metrics;
    const compare_delta = metrics_end.each_key_compares - metrics_start.each_key_compares;
    const hash_delta = metrics_end.each_key_hashes - metrics_start.each_key_hashes;
    const reuse_delta = metrics_end.each_key_reuse_compares - metrics_start.each_key_reuse_compares;
    const duplicate_delta = metrics_end.each_key_duplicate_compares - metrics_start.each_key_duplicate_compares;
    const item_delta = metrics_end.each_item_compares - metrics_start.each_item_compares;
    try std.testing.expectEqual(@as(u64, row_count * 2), compare_delta);
    try std.testing.expectEqual(@as(u64, row_count), hash_delta);
    try std.testing.expectEqual(@as(u64, row_count), reuse_delta);
    try std.testing.expectEqual(@as(u64, 0), duplicate_delta);
    try std.testing.expectEqual(@as(u64, row_count), item_delta);
}

test "signals host row scopes retain key and item capabilities" {
    test_erased_callable_drop_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        deinitTestHostIdentity(&host);
        _ = host.gpa.deinit();
    }

    const key_cap = testHostValueCapability(&roc_host);
    const item_cap = testHostValueCapability(&roc_host);

    const root = host.internRootScope();
    const initial_keys = [_]HostValue{testHostValueI64(1)};
    const initial_items = [_]HostValue{testHostValueI64(10)};
    const initial = syncTestEachRowScopes(&host, &roc_host, root, 5, &initial_keys, &initial_items, key_cap, item_cap);
    defer freeKeyedRowDiff(&host, initial);
    try std.testing.expectEqual(@as(u64, 1), initial.rows_created);
    const row_scope_id = initial.scope_ids[0];

    test_erased_callable_drop_count = 0;
    key_cap.decref(&roc_host);
    item_cap.decref(&roc_host);
    try std.testing.expectEqual(@as(u64, 0), test_erased_callable_drop_count);

    const incoming_key_cap = testHostValueCapabilityWithEq(&roc_host, &testNeverEqualHostValueCallable);
    defer incoming_key_cap.decref(&roc_host);
    const incoming_item_cap = testHostValueCapabilityWithEq(&roc_host, &testNeverEqualHostValueCallable);
    defer incoming_item_cap.decref(&roc_host);

    const next_keys = [_]HostValue{testHostValueI64(1)};
    const next_items = [_]HostValue{testHostValueI64(10)};
    const next = syncTestEachRowScopes(&host, &roc_host, root, 5, &next_keys, &next_items, incoming_key_cap, incoming_item_cap);
    defer freeKeyedRowDiff(&host, next);
    try std.testing.expectEqual(@as(u64, 1), next.rows_reused);
    try std.testing.expectEqual(@as(u64, 0), next.rows_created);
    try std.testing.expectEqual(@as(u64, 1), next.row_items_unchanged);
    try std.testing.expectEqual(row_scope_id, next.scope_ids[0]);
}

test "signals host collects Elem descriptor stream" {
    test_erased_callable_drop_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    var stream: HostNodeDescriptorStream = .{};
    defer stream.deinit(host.hostAllocator(), &host, &roc_host, &host.engine.pending_roc_metrics);

    const root_attrs = [_]abi.NodeAttr{
        testNodeStaticTextAttr(&roc_host, .role, "region"),
        testNodeStaticTextAttr(&roc_host, .label, "Dashboard"),
        testNodeSignalTextAttr(&roc_host, .value, testNodeConstExpr(&roc_host, testHostValueStr(&roc_host, "search"))),
        testNodeStaticBoolAttr(.disabled, true),
        testNodeSignalBoolAttr(&roc_host, .checked, testNodeConstExpr(&roc_host, testHostValueBool(false))),
    };
    const state_token = newTestBinderToken(&roc_host);
    const state_cap = testHostValueCapability(&roc_host);
    const state_child_attrs = [_]abi.NodeAttr{
        testNodeStaticTextAttr(&roc_host, .test_id, "state-child"),
        testNodeSignalTextAttrWithCapability(&roc_host, .value, testNodeRefExpr(state_token), state_cap),
        testNodeEventAttr(&roc_host, .click, state_token, .unit),
    };
    const state_child_children = [_]abi.Elem{
        testNodeText(&roc_host, "state child"),
        testNodeTextSignalWithCapability(&roc_host, testNodeRefExpr(state_token), state_cap),
    };
    const state_child = testElementWith(&roc_host, "span", &state_child_attrs, &state_child_children);
    const state = testNodeStateWithTokenAndInitialCapability(&roc_host, state_token, testHostValueI64(0), state_child, state_cap);
    const when_elem = testNodeWhen(&roc_host, testNodeText(&roc_host, "true branch"), testNodeText(&roc_host, "false branch"));
    const each_elem = testNodeEach(&roc_host);
    const root_children = [_]abi.Elem{
        testNodeText(&roc_host, "intro"),
        testNodeTextSignal(&roc_host, testNodeConstExpr(&roc_host, testHostValueStr(&roc_host, "dynamic text"))),
        state,
        when_elem,
        each_elem,
    };
    const root = testElementWith(&roc_host, "section", &root_attrs, &root_children);
    defer root.decref(&roc_host);

    host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});

    try std.testing.expectEqual(@as(usize, 2), stream.elements.items.len);
    try std.testing.expectEqual(ids.ElemId.fromRaw(1), stream.elements.items[0].elem_id);
    try std.testing.expectEqual(ids.root_elem, stream.elements.items[0].parent_elem_id);
    try std.testing.expectEqual(ids.root_scope, stream.elements.items[0].scope_id);
    try std.testing.expectEqualStrings("section", stream.elements.items[0].tag);
    try std.testing.expectEqual(ids.ElemId.fromRaw(4), stream.elements.items[1].elem_id);
    try std.testing.expectEqual(ids.ElemId.fromRaw(1), stream.elements.items[1].parent_elem_id);
    try std.testing.expectEqualStrings("span", stream.elements.items[1].tag);

    try std.testing.expectEqual(@as(usize, 3), stream.text_nodes.items.len);
    try std.testing.expectEqual(@as(u64, 2), stream.text_nodes.items[0].elem_id.raw());
    try std.testing.expectEqual(@as(u64, 1), stream.text_nodes.items[0].parent_elem_id.raw());
    try std.testing.expectEqualStrings("intro", stream.text_nodes.items[0].value);
    try std.testing.expectEqual(@as(u64, 5), stream.text_nodes.items[1].elem_id.raw());
    try std.testing.expectEqual(@as(u64, 4), stream.text_nodes.items[1].parent_elem_id.raw());
    try std.testing.expectEqualStrings("state child", stream.text_nodes.items[1].value);
    try std.testing.expectEqual(@as(u64, 7), stream.text_nodes.items[2].elem_id.raw());
    try std.testing.expectEqual(@as(u64, 1), stream.text_nodes.items[2].parent_elem_id.raw());
    try std.testing.expectEqualStrings("true branch", stream.text_nodes.items[2].value);

    try std.testing.expectEqual(@as(usize, 2), stream.signal_text_nodes.items.len);
    try std.testing.expectEqual(@as(u64, 3), stream.signal_text_nodes.items[0].elem_id.raw());
    try std.testing.expectEqual(@as(u64, 1), stream.signal_text_nodes.items[0].parent_elem_id.raw());
    try std.testing.expectEqual(@as(std.meta.Tag(HostSignalRecordPayload), .const_value), std.meta.activeTag(stream.signal_text_nodes.items[0].signal.record.payload));
    try std.testing.expectEqual(@as(usize, 0), stream.signal_text_nodes.items[0].signal.source_node_ids.len);
    try std.testing.expectEqual(@as(u64, 6), stream.signal_text_nodes.items[1].elem_id.raw());
    try std.testing.expectEqual(@as(u64, 4), stream.signal_text_nodes.items[1].parent_elem_id.raw());
    try std.testing.expectEqual(@as(std.meta.Tag(HostSignalRecordPayload), .ref), std.meta.activeTag(stream.signal_text_nodes.items[1].signal.record.payload));
    try std.testing.expectEqual(@as(usize, 1), stream.signal_text_nodes.items[1].signal.source_node_ids.len);
    try std.testing.expectEqual(stream.scope_sites.items[0].node_id.raw(), stream.signal_text_nodes.items[1].signal.source_node_ids[0]);
    try std.testing.expectEqual(@as(u64, 8), stream.next_elem_id);

    try std.testing.expectEqual(@as(usize, 3), stream.static_text_attrs.items.len);
    try std.testing.expectEqual(RenderTextField.role, stream.static_text_attrs.items[0].field);
    try std.testing.expectEqualStrings("region", stream.static_text_attrs.items[0].value);
    try std.testing.expectEqual(RenderTextField.label, stream.static_text_attrs.items[1].field);
    try std.testing.expectEqualStrings("Dashboard", stream.static_text_attrs.items[1].value);
    try std.testing.expectEqual(RenderTextField.test_id, stream.static_text_attrs.items[2].field);
    try std.testing.expectEqualStrings("state-child", stream.static_text_attrs.items[2].value);

    try std.testing.expectEqual(@as(usize, 2), stream.signal_text_attrs.items.len);
    try std.testing.expectEqual(@as(u64, 1), stream.signal_text_attrs.items[0].elem_id.raw());
    try std.testing.expectEqual(RenderTextField.value, stream.signal_text_attrs.items[0].field);
    try std.testing.expectEqual(@as(std.meta.Tag(HostSignalRecordPayload), .const_value), std.meta.activeTag(stream.signal_text_attrs.items[0].signal.record.payload));
    try std.testing.expectEqual(@as(usize, 0), stream.signal_text_attrs.items[0].signal.source_node_ids.len);
    try std.testing.expectEqual(@as(u64, 4), stream.signal_text_attrs.items[1].elem_id.raw());
    try std.testing.expectEqual(RenderTextField.value, stream.signal_text_attrs.items[1].field);
    try std.testing.expectEqual(@as(std.meta.Tag(HostSignalRecordPayload), .ref), std.meta.activeTag(stream.signal_text_attrs.items[1].signal.record.payload));
    try std.testing.expectEqual(@as(usize, 1), stream.signal_text_attrs.items[1].signal.source_node_ids.len);
    try std.testing.expectEqual(stream.scope_sites.items[0].node_id.raw(), stream.signal_text_attrs.items[1].signal.source_node_ids[0]);

    try std.testing.expectEqual(@as(usize, 1), stream.static_bool_attrs.items.len);
    try std.testing.expectEqual(RenderBoolField.disabled, stream.static_bool_attrs.items[0].field);
    try std.testing.expect(stream.static_bool_attrs.items[0].value);

    try std.testing.expectEqual(@as(usize, 1), stream.signal_bool_attrs.items.len);
    try std.testing.expectEqual(RenderBoolField.checked, stream.signal_bool_attrs.items[0].field);
    try std.testing.expectEqual(@as(std.meta.Tag(HostSignalRecordPayload), .const_value), std.meta.activeTag(stream.signal_bool_attrs.items[0].signal.record.payload));
    try std.testing.expectEqual(@as(usize, 0), stream.signal_bool_attrs.items[0].signal.source_node_ids.len);

    try std.testing.expectEqual(@as(usize, 1), stream.events.items.len);
    try std.testing.expectEqual(RenderEventKind.click, stream.events.items[0].fixedKind().?);
    try std.testing.expectEqual(state_token, stream.events.items[0].binder_token);
    try std.testing.expectEqual(stream.scope_sites.items[0].node_id, stream.events.items[0].target_node_id);
    try std.testing.expectEqual(BoundaryPayloadDescriptor.init(.unit, .none), stream.events.items[0].payload_descriptor);

    try std.testing.expectEqual(@as(usize, 3), stream.scope_sites.items.len);
    try std.testing.expectEqual(HostNodeScopeSiteKind.state, stream.scope_sites.items[0].kind);
    try std.testing.expectEqual(@as(u64, 0), stream.scope_sites.items[0].ordinal.raw());
    try std.testing.expectEqual(@as(u64, 1), stream.scope_sites.items[0].parent_elem_id.raw());
    try std.testing.expectEqual(@as(usize, 0), stream.scope_sites.items[0].binder_bindings.len);
    try std.testing.expectEqual(HostNodeScopeSiteKind.when, stream.scope_sites.items[1].kind);
    try std.testing.expectEqual(@as(u64, 1), stream.scope_sites.items[1].ordinal.raw());
    try std.testing.expectEqual(@as(usize, 0), stream.scope_sites.items[1].binder_bindings.len);
    try std.testing.expectEqual(HostNodeScopeSiteKind.each, stream.scope_sites.items[2].kind);
    try std.testing.expectEqual(@as(u64, 2), stream.scope_sites.items[2].ordinal.raw());
    try std.testing.expectEqual(@as(usize, 0), stream.scope_sites.items[2].binder_bindings.len);

    try std.testing.expectEqual(@as(usize, 1), stream.states.items.len);
    try std.testing.expectEqual(stream.scope_sites.items[0].node_id, stream.states.items[0].node_id);
    try std.testing.expectEqual(@as(usize, 1), stream.whens.items.len);
    try std.testing.expectEqual(stream.scope_sites.items[1].node_id, stream.whens.items[0].node_id);
    try std.testing.expectEqual(@as(usize, 0), stream.whens.items[0].condition.source_node_ids.len);
    try std.testing.expectEqual(@as(usize, 1), stream.eaches.items.len);
    try std.testing.expectEqual(stream.scope_sites.items[2].node_id, stream.eaches.items[0].node_id);
    try std.testing.expectEqual(@as(usize, 0), stream.eaches.items[0].items.source_node_ids.len);

    try std.testing.expectEqual(@as(usize, 3), host.engine.node_identities.items.len);
    try std.testing.expectEqual(@as(u64, 0), host.engine.node_identities.items[0].ordinal.raw());
    try std.testing.expectEqual(@as(u64, 1), host.engine.node_identities.items[1].ordinal.raw());
    try std.testing.expectEqual(@as(u64, 2), host.engine.node_identities.items[2].ordinal.raw());
}

test "signals host tracks descriptor stream closure lifecycle metrics" {
    test_erased_callable_drop_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    var stream: HostNodeDescriptorStream = .{};

    const state_token = newTestBinderToken(&roc_host);
    const root_attrs = [_]abi.NodeAttr{
        testNodeSignalTextAttr(&roc_host, .value, testNodeMapExpr(&roc_host, testNodeConstExpr(&roc_host, testHostValueI64(41)))),
    };
    const state_child_attrs = [_]abi.NodeAttr{
        testNodeEventAttr(&roc_host, .click, state_token, .unit),
    };
    const state_child = testElementWith(&roc_host, "button", &state_child_attrs, &.{});
    const state = testNodeStateWithToken(&roc_host, state_token, state_child);
    const items = [_]HostValue{testHostValueI64(1)};
    const each = testNodeEachWithItems(&roc_host, &items);
    const root_children = [_]abi.Elem{ state, each };
    const root = testElementWith(&roc_host, "section", &root_attrs, &root_children);
    defer root.decref(&roc_host);

    host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});

    try std.testing.expectEqual(@as(u64, 62), host.engine.pending_roc_metrics.closure_retains);
    try std.testing.expectEqual(@as(u64, 0), host.engine.pending_roc_metrics.closure_releases);

    stream.deinit(host.hostAllocator(), &host, &roc_host, &host.engine.pending_roc_metrics);

    try std.testing.expectEqual(@as(u64, 62), host.engine.pending_roc_metrics.closure_retains);
    try std.testing.expectEqual(@as(u64, 50), host.engine.pending_roc_metrics.closure_releases);
}

test "signals host descriptors carry capability-owned extension records" {
    test_erased_callable_drop_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    var stream: HostNodeDescriptorStream = .{};
    defer stream.deinit(host.hostAllocator(), &host, &roc_host, &host.engine.pending_roc_metrics);

    const root_attrs = [_]abi.NodeAttr{
        testNodeSignalTextAttr(&roc_host, .value, testNodeConstExpr(&roc_host, testHostValueStr(&roc_host, "search"))),
        testNodeSignalBoolAttr(&roc_host, .checked, testNodeConstExpr(&roc_host, testHostValueBool(true))),
    };
    const state_token = newTestBinderToken(&roc_host);
    const state_child_attrs = [_]abi.NodeAttr{
        testNodeEventAttr(&roc_host, .click, state_token, .unit),
    };
    const state_child = testElementWith(&roc_host, "button", &state_child_attrs, &.{});
    const root_children = [_]abi.Elem{
        testNodeStateWithToken(&roc_host, state_token, state_child),
        testNodeWhen(&roc_host, testNodeText(&roc_host, "ready"), testNodeText(&roc_host, "waiting")),
        testNodeEach(&roc_host),
    };
    const root = testElementWith(&roc_host, "section", &root_attrs, &root_children);
    defer root.decref(&roc_host);

    host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});

    try std.testing.expectEqual(@as(usize, 1), stream.signal_text_attrs.items.len);
    const text_attr = &stream.signal_text_attrs.items[0];
    try std.testing.expect(hv.hostValueCapabilitiesMatch(text_attr.read.capability, hostSignalBindingCapability(&host, &text_attr.signal)));

    try std.testing.expectEqual(@as(usize, 1), stream.signal_bool_attrs.items.len);
    const bool_attr = &stream.signal_bool_attrs.items[0];
    try std.testing.expect(hv.hostValueCapabilitiesMatch(bool_attr.read.capability, hostSignalBindingCapability(&host, &bool_attr.signal)));

    try std.testing.expectEqual(@as(usize, 1), stream.whens.items.len);
    const when = &stream.whens.items[0];
    try std.testing.expect(hv.hostValueCapabilitiesMatch(when.read.capability, hostSignalBindingCapability(&host, &when.condition)));

    try std.testing.expectEqual(@as(usize, 1), stream.eaches.items.len);
    const each = &stream.eaches.items[0];
    try std.testing.expect(hv.hostValueCapabilitiesMatch(each.ops.items_capability, hostSignalBindingCapability(&host, &each.items)));

    try std.testing.expectEqual(@as(usize, 1), stream.events.items.len);
    const event_reducer = stream.events.items[0].payload_reducer;
    try std.testing.expect(stream.events.items[0].owns_payload_reducer);
    host.rebuildActiveEventsFromStream(&stream);
    try std.testing.expect(!stream.events.items[0].owns_payload_reducer);
    try std.testing.expectEqual(@as(usize, 1), host.engine.active_events.items.len);
    try std.testing.expect(hv.hostValueCapabilitiesMatch(host.engine.active_events.items[0].payload_reducer.capability, event_reducer.capability));
    try std.testing.expectEqual(host.engine.active_events.items[0].payload_reducer.transform, event_reducer.transform);
}

test "signals host preserves callable identity across cloned descriptors" {
    test_erased_callable_drop_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    var stream: HostNodeDescriptorStream = .{};
    defer stream.deinit(host.hostAllocator(), &host, &roc_host, &host.engine.pending_roc_metrics);

    const signal = testNodeMapExpr(&roc_host, testNodeConstExpr(&roc_host, testHostValueI64(41)));
    signal.incref(1);
    const root_children = [_]abi.Elem{
        testNodeTextSignal(&roc_host, signal),
        testNodeTextSignal(&roc_host, signal),
    };
    const root = testElement(&roc_host, &root_children);
    defer root.decref(&roc_host);

    host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});

    try std.testing.expectEqual(@as(usize, 2), stream.signal_text_nodes.items.len);
    const first = stream.signal_text_nodes.items[0].signal.record;
    const second = stream.signal_text_nodes.items[1].signal.record;
    try std.testing.expect(first == second);
    try std.testing.expectEqual(@as(std.meta.Tag(HostSignalRecordPayload), .map), std.meta.activeTag(first.payload));
    try std.testing.expectEqual(@as(std.meta.Tag(HostSignalRecordPayload), .map), std.meta.activeTag(second.payload));
    try std.testing.expectEqual(first.token().?, second.token().?);
}

test "signals host keeps same-specialization maps constants and state binders distinct" {
    test_erased_callable_drop_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    var stream: HostNodeDescriptorStream = .{};
    defer stream.deinit(host.hostAllocator(), &host, &roc_host, &host.engine.pending_roc_metrics);

    const left_token = newTestBinderToken(&roc_host);
    const right_token = newTestBinderToken(&roc_host);
    const left_map = testNodeMapExpr(&roc_host, testNodeRefExpr(left_token));
    const right_map = testNodeMapExpr(&roc_host, testNodeRefExpr(right_token));
    const first_const = testNodeConstExpr(&roc_host, testHostValueI64(1));
    const second_const = testNodeConstExpr(&roc_host, testHostValueI64(1));
    const children = [_]abi.Elem{
        testNodeI64TextSignal(&roc_host, left_map),
        testNodeI64TextSignal(&roc_host, right_map),
        testNodeI64TextSignal(&roc_host, first_const),
        testNodeI64TextSignal(&roc_host, second_const),
    };
    const inner = testNodeStateWithTokenAndInitial(&roc_host, right_token, testHostValueI64(20), testElement(&roc_host, &children));
    const root = testNodeStateWithTokenAndInitial(&roc_host, left_token, testHostValueI64(10), inner);
    defer root.decref(&roc_host);

    host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});

    try std.testing.expectEqual(@as(usize, 4), stream.signal_text_nodes.items.len);
    const left_record = stream.signal_text_nodes.items[0].signal.record;
    const right_record = stream.signal_text_nodes.items[1].signal.record;
    try std.testing.expect(left_record != right_record);
    try std.testing.expectEqual(
        abi.rocErasedCallablePayloadPtr(left_record.payload.map.transform.toAbi()).callable_fn_ptr,
        abi.rocErasedCallablePayloadPtr(right_record.payload.map.transform.toAbi()).callable_fn_ptr,
    );
    try std.testing.expect(left_record.token().? == left_record.payload.map.transform.toAbi().?);
    try std.testing.expect(right_record.token().? == right_record.payload.map.transform.toAbi().?);

    const first_const_record = stream.signal_text_nodes.items[2].signal.record;
    const second_const_record = stream.signal_text_nodes.items[3].signal.record;
    try std.testing.expect(first_const_record != second_const_record);
    try std.testing.expect(first_const_record.token().? != second_const_record.token().?);
    try std.testing.expect(first_const_record.token().? == first_const_record.payload.const_value.init.toAbi().?);
    try std.testing.expect(second_const_record.token().? == second_const_record.payload.const_value.init.toAbi().?);

    try std.testing.expectEqual(@as(usize, 2), stream.states.items.len);
    try std.testing.expect(stream.states.items[0].initial.toAbi().? != stream.states.items[1].initial.toAbi().?);
    try std.testing.expectEqual(left_token, stream.states.items[0].initial.toAbi().?);
    try std.testing.expectEqual(right_token, stream.states.items[1].initial.toAbi().?);
}

test "signals host derives browser source identity from from_payload" {
    test_erased_callable_drop_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    var stream: HostNodeDescriptorStream = .{};
    defer stream.deinit(host.hostAllocator(), &host, &roc_host, &host.engine.pending_roc_metrics);

    const expr = testNodeLocationSourceExpr(&roc_host);
    defer expr.decref(&roc_host);
    const from_payload = expr.payload_location_source()._1.?;
    const record = host.engine.bindNodeSignalExpr(host.hostAllocator(), &stream, expr, &.{});
    defer record.release(host.hostAllocator(), &host, &roc_host, &host.engine.pending_roc_metrics);

    try std.testing.expectEqual(from_payload, record.token().?);
    try std.testing.expectEqual(from_payload, record.payload.location_source.from_payload.toAbi().?);
}

test "signals host retains state equality outside descriptor stream" {
    test_erased_callable_drop_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    const state_token = newTestBinderToken(&roc_host);
    const root = testNodeStateWithTokenAndInitial(&roc_host, state_token, testHostValueI64(0), testNodeText(&roc_host, "state"));
    defer root.decref(&roc_host);

    var stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
    host.engine.active_stream = stream;

    const state_id = host.engine.active_stream.scope_sites.items[0].node_id;
    host.engine.active_stream.deinit(host.hostAllocator(), &host, &roc_host, &host.engine.pending_roc_metrics);
    host.engine.active_stream = .{};

    try std.testing.expect(!host.updateStateValue(&roc_host, state_id, testHostValueI64(0)));
    try std.testing.expect(host.updateStateValue(&roc_host, state_id, testHostValueI64(1)));
}

test "signals host dispatches through active event records outside descriptor stream" {
    test_erased_callable_drop_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    const state_token = newTestBinderToken(&roc_host);
    const attrs = [_]abi.NodeAttr{
        testNodeUnitIncrementEventAttr(&roc_host, .click, state_token),
    };
    const button = testElementWith(&roc_host, "button", &attrs, &.{});
    const root = testNodeStateWithTokenAndInitial(&roc_host, state_token, testHostValueI64(0), button);
    defer root.decref(&roc_host);

    var stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
    _ = applyNodeDescriptorStream(&host, &roc_host, &stream);
    host.rebuildActiveEventsFromStream(&stream);
    host.engine.active_stream = stream;

    const button_id = host.engine.active_stream.elements.items[0].elem_id;
    const event_id = nodeFixedEventId(&host, button_id, .click) orelse unreachable;
    const state_id = host.engine.active_stream.scope_sites.items[0].node_id;

    host.engine.active_stream.deinit(host.hostAllocator(), &host, &roc_host, &host.engine.pending_roc_metrics);
    host.engine.active_stream = .{};

    dispatchRocEvent(&host, &roc_host, ids.EventId.fromRaw(event_id), BoundaryPayloadDescriptor.init(.unit, .none), testHostValueUnit());
    try expectHostValueI64(host.stateValueByNodeId(state_id), 1);
}

const HostPlateauSnapshot = struct {
    retained_alloc_delta: i64,
    host_retained_alloc_delta: i64,
    host_retained_bytes_delta: i64,
    dom_elements_len: usize,
    active_events_len: usize,
    event_descriptors_len: usize,
    signal_descriptors_len: usize,
    signal_routes_len: usize,
    signal_dependents_len: usize,
    signal_cache_len: usize,
    states_len: usize,
    state_indexes_by_node_id_len: usize,
    scopes_len: usize,
    each_row_sites_len: usize,
    each_row_memberships_by_scope_id_len: usize,
    node_identities_len: usize,
    dom_identities_len: usize,
    active_stream_elements_len: usize,
    active_stream_events_len: usize,
    active_stream_states_len: usize,
    active_signal_graph_len: usize,
    active_source_signal_routes_len: usize,
    active_text_signal_routes_len: usize,
    active_bool_signal_routes_len: usize,
    active_change_signal_routes_len: usize,
    active_structural_signal_routes_len: usize,
    active_intervals_len: usize,
    pending_tasks_len: usize,
    dirty_queue_seen_capacity: usize,
    dirty_queue_pending_capacity: usize,
    dirty_queue_ordered_capacity: usize,
    dirty_queue_rank_counts_capacity: usize,
    dirty_changed_record_ids_capacity: usize,

    fn capture(current: *const HostEnv) @This() {
        const metrics = current.engine.last_runtime_metrics;
        const dirty_queue = current.engine.scratch.dirty_active_records;
        return .{
            .retained_alloc_delta = metrics.retained_alloc_delta,
            .host_retained_alloc_delta = metrics.host_retained_alloc_delta,
            .host_retained_bytes_delta = metrics.host_retained_bytes_delta,
            .dom_elements_len = current.dom_elements.items.len,
            .active_events_len = current.engine.active_events.items.len,
            .event_descriptors_len = current.engine.event_descriptors.items.len,
            .signal_descriptors_len = current.engine.signal_descriptors.items.len,
            .signal_routes_len = current.engine.signal_routes.items.len,
            .signal_dependents_len = current.engine.signal_dependents.items.len,
            .signal_cache_len = current.engine.signal_cache.items.len,
            .states_len = current.engine.states.items.len,
            .state_indexes_by_node_id_len = current.engine.state_indexes_by_node_id.items.len,
            .scopes_len = current.engine.scopes.items.len,
            .each_row_sites_len = current.engine.each_row_sites.items.len,
            .each_row_memberships_by_scope_id_len = current.engine.each_row_memberships_by_scope_id.items.len,
            .node_identities_len = current.engine.node_identities.items.len,
            .dom_identities_len = current.engine.dom_identities.items.len,
            .active_stream_elements_len = current.engine.active_stream.elements.items.len,
            .active_stream_events_len = current.engine.active_stream.events.items.len,
            .active_stream_states_len = current.engine.active_stream.states.items.len,
            .active_signal_graph_len = current.engine.active_signal_graph.items.len,
            .active_source_signal_routes_len = current.engine.active_source_signal_routes.items.len,
            .active_text_signal_routes_len = current.engine.active_text_signal_routes.items.len,
            .active_bool_signal_routes_len = current.engine.active_bool_signal_routes.items.len,
            .active_change_signal_routes_len = current.engine.active_change_signal_routes.items.len,
            .active_structural_signal_routes_len = current.engine.active_structural_signal_routes.items.len,
            .active_intervals_len = current.engine.active_intervals.items.len,
            .pending_tasks_len = current.engine.pending_tasks.items.len,
            .dirty_queue_seen_capacity = dirty_queue.seen_generations.capacity,
            .dirty_queue_pending_capacity = dirty_queue.pending_record_ids.capacity,
            .dirty_queue_ordered_capacity = dirty_queue.ordered_record_ids.capacity,
            .dirty_queue_rank_counts_capacity = dirty_queue.rank_counts.capacity,
            .dirty_changed_record_ids_capacity = current.engine.scratch.dirty_changed_record_ids.capacity,
        };
    }
};

fn expectHostPlateauSnapshot(expected: HostPlateauSnapshot, actual: HostPlateauSnapshot) !void {
    try std.testing.expect(std.meta.eql(expected, actual));
}

test "signals host keeps live allocations and table sizes flat across repeated events" {
    test_erased_callable_drop_count = 0;

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }

    const state_token = newTestBinderToken(&roc_host);
    const attrs = [_]abi.NodeAttr{
        testNodeUnitIncrementEventAttr(&roc_host, .click, state_token),
    };
    const button = testElementWith(&roc_host, "button", &attrs, &.{});
    const root = testNodeStateWithTokenAndInitial(&roc_host, state_token, testHostValueI64(0), button);
    defer root.decref(&roc_host);

    var stream: HostNodeDescriptorStream = .{};
    host.collectActiveElemRootDescriptors(&roc_host, &stream, root, &.{});
    _ = applyNodeDescriptorStream(&host, &roc_host, &stream);
    host.rebuildActiveEventsFromStream(&stream);
    host.engine.active_stream = stream;

    const button_id = host.engine.active_stream.elements.items[0].elem_id;
    const event_id = nodeFixedEventId(&host, button_id, .click) orelse unreachable;
    const state_id = host.engine.active_stream.scope_sites.items[0].node_id;

    var snapshot_after_warmup: ?HostPlateauSnapshot = null;
    var iteration: usize = 0;
    while (iteration < 100) : (iteration += 1) {
        dispatchRocEvent(&host, &roc_host, ids.EventId.fromRaw(event_id), BoundaryPayloadDescriptor.init(.unit, .none), hostValueUnit(&host, &roc_host));
        const snapshot = HostPlateauSnapshot.capture(&host);
        if (iteration == 9) {
            snapshot_after_warmup = snapshot;
        } else if (iteration > 9) {
            try expectHostPlateauSnapshot(snapshot_after_warmup.?, snapshot);
        }
    }

    try expectHostValueI64(host.stateValueByNodeId(state_id), 100);
}

test "native host teardown is allocation-free with populated real host state" {
    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;

    host.sinkReset();
    host.sinkAppendNode(ids.ElemId.fromRaw(1), ids.ElemId.fromRaw(0), "section");
    try host.location_history.append(host.hostAllocator(), NativeLocation.init(host.hostAllocator(), .{
        .path = "/teardown",
        .query = "fault=armed",
        .hash = "state",
    }));

    host.configureAllocationFailure(1);
    host.deinit();
    try std.testing.expectEqual(@as(usize, 0), host.allocation_fault.?.attempts);
    try std.testing.expectEqual(std.heap.Check.ok, host.gpa.deinit());
}

test "native initial root publication sweeps host OOM and retries on the same engine" {
    const Runner = struct {
        fn run(failure_number: ?usize) !usize {
            var host = HostEnv.init();
            var roc_host = makeSignalsRocHost(&host);
            host.engine.roc_host = &roc_host;
            defer {
                host.deinit();
                _ = host.gpa.deinit();
            }

            const state_token = newTestBinderToken(&roc_host);
            const attrs = [_]abi.NodeAttr{testNodeUnitIncrementEventAttr(&roc_host, .click, state_token)};
            const button = testElementWith(&roc_host, "button", &attrs, &.{testNodeText(&roc_host, "ready")});
            const root = testNodeStateWithTokenAndInitial(&roc_host, state_token, testHostValueI64(0), button);
            defer root.decref(&roc_host);

            var fault = FaultAllocator.init(host.gpa.allocator());
            fault.configure(failure_number);
            host.engine_allocator_override = fault.allocator();
            const result = tryRenderInitialRoot(&host, &roc_host, root, &.{});
            const attempts = fault.attempts;
            if (failure_number) |_| {
                try std.testing.expectError(error.OutOfMemory, result);
                try std.testing.expectEqual(@as(usize, 0), host.engine.scopes.items.len);
                try std.testing.expectEqual(@as(usize, 0), host.engine.node_identities.items.len);
                try std.testing.expectEqual(@as(usize, 0), host.engine.dom_identities.items.len);
                try std.testing.expectEqual(@as(usize, 0), host.engine.states.items.len);
                try std.testing.expectEqual(@as(usize, 0), host.engine.active_stream.render_nodes.items.len);
                try std.testing.expectEqual(@as(usize, 0), host.engine.active_events.items.len);
                try std.testing.expectEqual(@as(usize, 0), host.engine.active_signal_graph.items.len);
                try std.testing.expect(!host.engine.render_cache.hasRoot());
                try std.testing.expectEqual(@as(usize, 0), host.dom_elements.items.len);

                fault.configure(null);
                _ = try tryRenderInitialRoot(&host, &roc_host, root, &.{});
            } else {
                _ = try result;
            }
            try std.testing.expect(host.engine.render_cache.hasRoot());
            try std.testing.expectEqual(@as(usize, 1), host.engine.active_events.items.len);
            try std.testing.expectEqual(@as(usize, 0), host.engine.active_signal_graph.items.len);
            try std.testing.expectEqual(@as(usize, 3), host.dom_elements.items.len);
            try std.testing.expect(activeTextElementId(&host, "ready") != null);
            return attempts;
        }
    };

    const attempts = try Runner.run(null);
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| _ = try Runner.run(failure_number);
}

test "native initial root with sibling and nested each sites sweeps host OOM and publishes allocation free" {
    // Twelve sibling sites is past the slack an `ensureUnusedCapacity(1)`
    // leaves in an empty engine vector, which is where under-reserving the
    // cumulative staged-site total used to trap at commit (issue #22). Site
    // kinds rotate so rows carry state, nested when branches, and nested each
    // sites within the same transaction.
    const Runner = struct {
        const site_count = 12;
        const rows_per_site = 2;
        const nested_sites = (site_count / 3) * rows_per_site;
        const expected_sites = site_count + nested_sites;
        const expected_rows = (site_count + nested_sites) * rows_per_site;
        const expected_states = (site_count - site_count / 3) * rows_per_site + nested_sites * rows_per_site;

        fn buildRoot(roc_host: *abi.RocHost) abi.Elem {
            var sites: [site_count]abi.Elem = undefined;
            for (&sites, 0..) |*site, index| {
                const base: i64 = @intCast(index * rows_per_site);
                const items = [_]HostValue{ testHostValueI64(base + 1), testHostValueI64(base + 2) };
                site.* = switch (index % 3) {
                    0 => testNodeEachWithItems(roc_host, &items),
                    1 => testNodeEachWithItemsAndRow(roc_host, &items, &testInitialEachNestedRowElemCallable),
                    else => testNodeEachWithItemsAndRow(roc_host, &items, &testNestedEachRowElemCallable),
                };
            }
            return testElement(roc_host, &sites);
        }

        fn expectUnpublished(host: *const HostEnv) !void {
            try std.testing.expectEqual(@as(usize, 0), host.engine.scopes.items.len);
            try std.testing.expectEqual(@as(usize, 0), host.engine.node_identities.items.len);
            try std.testing.expectEqual(@as(usize, 0), host.engine.dom_identities.items.len);
            try std.testing.expectEqual(@as(usize, 0), host.engine.states.items.len);
            try std.testing.expectEqual(@as(usize, 0), host.engine.each_row_sites.items.len);
            try std.testing.expectEqual(@as(usize, 0), host.engine.each_row_site_indexes.count());
            try std.testing.expectEqual(@as(usize, 0), host.engine.active_stream.render_nodes.items.len);
            try std.testing.expectEqual(@as(usize, 0), host.engine.active_stream.eaches.items.len);
            try std.testing.expectEqual(@as(usize, 0), host.engine.active_stream.whens.items.len);
            try std.testing.expectEqual(@as(usize, 0), host.engine.active_events.items.len);
            try std.testing.expectEqual(@as(usize, 0), host.engine.active_signal_graph.items.len);
            try std.testing.expect(!host.engine.render_cache.hasRoot());
            try std.testing.expectEqual(@as(usize, 0), host.dom_elements.items.len);
        }

        fn expectPublished(host: *const HostEnv) !void {
            try std.testing.expect(host.engine.render_cache.hasRoot());
            try std.testing.expectEqual(@as(usize, expected_sites), host.engine.each_row_sites.items.len);
            try std.testing.expectEqual(@as(usize, expected_sites), host.engine.each_row_site_indexes.count());
            try std.testing.expectEqual(@as(usize, expected_sites), host.engine.active_stream.eaches.items.len);
            var rows: usize = 0;
            for (host.engine.each_row_sites.items) |site| rows += site.scope_ids.items.len;
            try std.testing.expectEqual(@as(usize, expected_rows), rows);
            try std.testing.expectEqual(@as(usize, expected_states), host.engine.states.items.len);
            try std.testing.expect(activeTextElementId(host, "row-1-1") != null);
            try std.testing.expect(activeTextElementId(host, "row-true") != null);
            try std.testing.expect(activeTextElementId(host, "outer-23") != null);
            try std.testing.expect(activeTextElementId(host, "row-232-232") != null);
        }

        fn run(failure_number: ?usize) !usize {
            var host = HostEnv.init();
            var roc_host = makeSignalsRocHost(&host);
            host.engine.roc_host = &roc_host;
            defer {
                host.deinit();
                _ = host.gpa.deinit();
            }

            const root = buildRoot(&roc_host);
            defer root.decref(&roc_host);
            const refs_before = host.roc_allocations.snapshot();

            var fault = FaultAllocator.init(host.gpa.allocator());
            fault.configure(failure_number);
            host.engine_allocator_override = fault.allocator();
            const result = tryRenderInitialRootWithArmedPublication(&host, &roc_host, root, &fault);
            const attempts = fault.attempts;
            if (failure_number != null) {
                try std.testing.expectError(error.OutOfMemory, result);
                try expectUnpublished(&host);
                try std.testing.expectEqual(host.engine.pending_roc_metrics.closure_retains, host.engine.pending_roc_metrics.closure_releases);
                try std.testing.expectEqual(refs_before.live_bytes, host.roc_allocations.snapshot().live_bytes);
                try std.testing.expectEqual(@as(usize, 0), host.roc_allocations.liveCountSince(refs_before));

                fault.configure(null);
                _ = try tryRenderInitialRootWithArmedPublication(&host, &roc_host, root, &fault);
            } else {
                _ = try result;
            }
            try expectPublished(&host);
            return attempts;
        }
    };

    const attempts = try Runner.run(null);
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| _ = try Runner.run(failure_number);
}

test "native initial root claims elem ids past a nested reservation for the static siblings after it" {
    // Element ids are claimed in collection order, so the static siblings
    // that follow an each site take ids above every id the site's rows
    // claimed. A nested reservation that bounds the highest elem id by the
    // ids interned so far plus its own nodes leaves those siblings past the
    // stream's per-elem index reservation: eight outer rows nesting stateful
    // lists put 40 ids under the site while thirty signal text nodes follow
    // it, so the final id exceeds the slack any earlier growth left. Signal
    // descriptors take their index slot at materialization, which must not
    // allocate.
    const Runner = struct {
        const outer_rows = 8;
        const inner_rows = 3;
        const tail_texts = 30;
        const expected_sites = 1 + outer_rows;
        const expected_rows = outer_rows + outer_rows * inner_rows;
        const expected_states = outer_rows * inner_rows;

        fn buildRoot(roc_host: *abi.RocHost) abi.Elem {
            var items: [outer_rows]HostValue = undefined;
            for (&items, 1..) |*item, key| item.* = testHostValueI64(@intCast(key));
            var children: [1 + tail_texts]abi.Elem = undefined;
            children[0] = testNodeEachWithItemsAndRow(roc_host, &items, &testNestedStatefulEachRowElemCallable);
            for (children[1..], 1..) |*child, index| child.* = testNodeI64TextSignal(roc_host, testNodeConstExpr(roc_host, testHostValueI64(@intCast(index))));
            return testElement(roc_host, &children);
        }

        fn expectUnpublished(host: *const HostEnv) !void {
            try std.testing.expectEqual(@as(usize, 0), host.engine.scopes.items.len);
            try std.testing.expectEqual(@as(usize, 0), host.engine.dom_identities.items.len);
            try std.testing.expectEqual(@as(usize, 0), host.engine.states.items.len);
            try std.testing.expectEqual(@as(usize, 0), host.engine.each_row_sites.items.len);
            try std.testing.expectEqual(@as(usize, 0), host.engine.active_stream.render_nodes.items.len);
            try std.testing.expect(!host.engine.render_cache.hasRoot());
        }

        fn expectPublished(host: *const HostEnv) !void {
            try std.testing.expect(host.engine.render_cache.hasRoot());
            try std.testing.expectEqual(@as(usize, expected_sites), host.engine.each_row_sites.items.len);
            var rows: usize = 0;
            for (host.engine.each_row_sites.items) |site| rows += site.scope_ids.items.len;
            try std.testing.expectEqual(@as(usize, expected_rows), rows);
            try std.testing.expectEqual(@as(usize, expected_states), host.engine.states.items.len);
            try std.testing.expect(activeTextElementId(host, "outer-8") != null);
            try std.testing.expect(activeTextElementId(host, "row-83-83") != null);
            try std.testing.expectEqual(@as(usize, tail_texts), host.engine.active_stream.signal_text_nodes.items.len);
        }

        fn run(failure_number: ?usize) !usize {
            var host = HostEnv.init();
            var roc_host = makeSignalsRocHost(&host);
            host.engine.roc_host = &roc_host;
            defer {
                host.deinit();
                _ = host.gpa.deinit();
            }

            const root = buildRoot(&roc_host);
            defer root.decref(&roc_host);
            const refs_before = host.roc_allocations.snapshot();

            var fault = FaultAllocator.init(host.gpa.allocator());
            fault.configure(failure_number);
            host.engine_allocator_override = fault.allocator();
            const result = tryRenderInitialRootWithArmedPublication(&host, &roc_host, root, &fault);
            const attempts = fault.attempts;
            if (failure_number != null) {
                try std.testing.expectError(error.OutOfMemory, result);
                try expectUnpublished(&host);
                try std.testing.expectEqual(host.engine.pending_roc_metrics.closure_retains, host.engine.pending_roc_metrics.closure_releases);
                try std.testing.expectEqual(refs_before.live_bytes, host.roc_allocations.snapshot().live_bytes);
                try std.testing.expectEqual(@as(usize, 0), host.roc_allocations.liveCountSince(refs_before));

                fault.configure(null);
                _ = try tryRenderInitialRootWithArmedPublication(&host, &roc_host, root, &fault);
            } else {
                _ = try result;
            }
            try expectPublished(&host);
            return attempts;
        }
    };

    const attempts = try Runner.run(null);
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| _ = try Runner.run(failure_number);
}

test "native initial root with sibling sites nesting each sites three deep sweeps host OOM and publishes allocation free" {
    // Every each site a staged transaction mounts is reserved against the
    // transaction's cumulative site total, never against the sites appended
    // so far: four sibling sites whose rows nest sites two further deep put
    // 28 sites and 56 rows into one collection, past the slack an
    // `ensureUnusedCapacity` growth leaves for a per-site reservation that
    // forgot to accumulate. Publication must not allocate at any depth.
    const Runner = struct {
        const site_count = 4;
        const rows_per_site = 2;
        const outer_rows = site_count * rows_per_site;
        const middle_sites = outer_rows;
        const middle_rows = middle_sites * rows_per_site;
        const inner_sites = middle_rows;
        const inner_rows = inner_sites * rows_per_site;
        const expected_sites = site_count + middle_sites + inner_sites;
        const expected_rows = outer_rows + middle_rows + inner_rows;
        const expected_states = inner_rows;

        fn buildRoot(roc_host: *abi.RocHost) abi.Elem {
            var sites: [site_count]abi.Elem = undefined;
            for (&sites, 0..) |*site, index| {
                const base: i64 = @intCast(index * rows_per_site);
                const items = [_]HostValue{ testHostValueI64(base + 1), testHostValueI64(base + 2) };
                site.* = testNodeEachWithItemsAndRow(roc_host, &items, &testDoublyNestedEachRowElemCallable);
            }
            return testElement(roc_host, &sites);
        }

        fn expectUnpublished(host: *const HostEnv) !void {
            try std.testing.expectEqual(@as(usize, 0), host.engine.scopes.items.len);
            try std.testing.expectEqual(@as(usize, 0), host.engine.node_identities.items.len);
            try std.testing.expectEqual(@as(usize, 0), host.engine.states.items.len);
            try std.testing.expectEqual(@as(usize, 0), host.engine.each_row_sites.items.len);
            try std.testing.expectEqual(@as(usize, 0), host.engine.each_row_site_indexes.count());
            try std.testing.expectEqual(@as(usize, 0), host.engine.active_stream.eaches.items.len);
            try std.testing.expect(!host.engine.render_cache.hasRoot());
        }

        fn expectPublished(host: *const HostEnv) !void {
            try std.testing.expect(host.engine.render_cache.hasRoot());
            try std.testing.expectEqual(@as(usize, expected_sites), host.engine.each_row_sites.items.len);
            try std.testing.expectEqual(@as(usize, expected_sites), host.engine.each_row_site_indexes.count());
            try std.testing.expectEqual(@as(usize, expected_sites), host.engine.active_stream.eaches.items.len);
            var rows: usize = 0;
            for (host.engine.each_row_sites.items) |site| rows += site.scope_ids.items.len;
            try std.testing.expectEqual(@as(usize, expected_rows), rows);
            try std.testing.expectEqual(@as(usize, expected_states), host.engine.states.items.len);
            try std.testing.expect(activeTextElementId(host, "deep-1") != null);
            try std.testing.expect(activeTextElementId(host, "deep-8") != null);
            try std.testing.expect(activeTextElementId(host, "outer-82") != null);
            try std.testing.expect(activeTextElementId(host, "row-822-822") != null);
        }

        fn run(failure_number: ?usize) !usize {
            var host = HostEnv.init();
            var roc_host = makeSignalsRocHost(&host);
            host.engine.roc_host = &roc_host;
            defer {
                host.deinit();
                _ = host.gpa.deinit();
            }

            const root = buildRoot(&roc_host);
            defer root.decref(&roc_host);
            const refs_before = host.roc_allocations.snapshot();

            var fault = FaultAllocator.init(host.gpa.allocator());
            fault.configure(failure_number);
            host.engine_allocator_override = fault.allocator();
            const result = tryRenderInitialRootWithArmedPublication(&host, &roc_host, root, &fault);
            const attempts = fault.attempts;
            if (failure_number != null) {
                try std.testing.expectError(error.OutOfMemory, result);
                try expectUnpublished(&host);
                try std.testing.expectEqual(host.engine.pending_roc_metrics.closure_retains, host.engine.pending_roc_metrics.closure_releases);
                try std.testing.expectEqual(refs_before.live_bytes, host.roc_allocations.snapshot().live_bytes);
                try std.testing.expectEqual(@as(usize, 0), host.roc_allocations.liveCountSince(refs_before));

                fault.configure(null);
                _ = try tryRenderInitialRootWithArmedPublication(&host, &roc_host, root, &fault);
            } else {
                _ = try result;
            }
            try expectPublished(&host);
            return attempts;
        }
    };

    const attempts = try Runner.run(null);
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| _ = try Runner.run(failure_number);
}

test "native initial each reading a staged state list resolves its items capability" {
    // The staged collection keeps every state cell it has declared in this
    // transaction as a provisional cell until publication, so an each whose
    // items signal is that state's ref must resolve its capability from the
    // provisional cells rather than the committed state table. The initial
    // each input extraction used the committed-only lookup, which failed with
    // "active state has no capability" for any keyed list mounted inside the
    // same transaction as the state it reads.
    const Runner = struct {
        fn run(failure_number: ?usize) !usize {
            test_row_elem_call_count = 0;
            var host = HostEnv.init();
            var roc_host = makeSignalsRocHost(&host);
            host.engine.roc_host = &roc_host;
            defer {
                host.deinit();
                _ = host.gpa.deinit();
            }

            const state_token = newTestBinderToken(&roc_host);
            const state_cap = testHostValueCapability(&roc_host);
            const items = [_]HostValue{ testHostValueI64(1), testHostValueI64(2) };
            const each = testNodeEachWithSignalCapabilityAndRow(&roc_host, testNodeRefExpr(state_token), state_cap, &testStatefulRowElemCallable);
            const section = testElementWith(&roc_host, "section", &.{}, &.{each});
            const root = testNodeStateWithTokenAndInitialCapability(&roc_host, state_token, testHostValueI64List(&roc_host, &items), section, state_cap);
            defer root.decref(&roc_host);
            const refs_before = host.roc_allocations.snapshot();

            var fault = FaultAllocator.init(host.gpa.allocator());
            fault.configure(failure_number);
            host.engine_allocator_override = fault.allocator();
            const result = tryRenderInitialRoot(&host, &roc_host, root, &.{});
            const attempts = fault.attempts;
            if (failure_number != null) {
                try std.testing.expectError(error.OutOfMemory, result);
                try std.testing.expectEqual(@as(usize, 0), host.engine.scopes.items.len);
                try std.testing.expectEqual(@as(usize, 0), host.engine.states.items.len);
                try std.testing.expectEqual(@as(usize, 0), host.engine.each_row_sites.items.len);
                try std.testing.expectEqual(@as(usize, 0), host.engine.active_stream.render_nodes.items.len);
                try std.testing.expect(!host.engine.render_cache.hasRoot());
                try std.testing.expectEqual(refs_before.live_bytes, host.roc_allocations.snapshot().live_bytes);
                fault.configure(null);
                _ = try tryRenderInitialRoot(&host, &roc_host, root, &.{});
            } else {
                _ = try result;
            }

            // The list state plus one cell per row.
            try std.testing.expectEqual(@as(usize, 3), host.engine.states.items.len);
            try std.testing.expectEqual(@as(usize, 1), host.engine.each_row_sites.items.len);
            for (host.engine.states.items, 0..) |state, index| {
                try std.testing.expectEqual(@as(?usize, index), host.engine.stateIndexByNodeId(state.state_id));
            }
            try std.testing.expect(activeTextElementId(&host, "row-1-1") != null);
            try std.testing.expect(activeTextElementId(&host, "row-2-2") != null);
            return attempts;
        }
    };

    const attempts = try Runner.run(null);
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| _ = try Runner.run(failure_number);
}

test "native initial each nested rows sweep host OOM and commit exact topology" {
    const Runner = struct {
        fn run(failure_number: ?usize) !usize {
            var host = HostEnv.init();
            var roc_host = makeSignalsRocHost(&host);
            host.engine.roc_host = &roc_host;
            defer {
                host.deinit();
                _ = host.gpa.deinit();
            }

            const items = [_]HostValue{ testHostValueI64(1), testHostValueI64(2) };
            const each = testNodeEachWithItemsAndRow(&roc_host, &items, &testInitialEachNestedRowElemCallable);
            const root = testElement(&roc_host, &.{each});
            defer root.decref(&roc_host);
            const refs_before = host.roc_allocations.snapshot();

            var fault = FaultAllocator.init(host.gpa.allocator());
            fault.configure(failure_number);
            host.engine_allocator_override = fault.allocator();
            const result = tryRenderInitialRoot(&host, &roc_host, root, &.{});
            const attempts = fault.attempts;
            if (failure_number != null) {
                try std.testing.expectError(error.OutOfMemory, result);
                try std.testing.expectEqual(@as(usize, 0), host.engine.scopes.items.len);
                try std.testing.expectEqual(@as(usize, 0), host.engine.node_identities.items.len);
                try std.testing.expectEqual(@as(usize, 0), host.engine.dom_identities.items.len);
                try std.testing.expectEqual(@as(usize, 0), host.engine.states.items.len);
                try std.testing.expectEqual(@as(usize, 0), host.engine.each_row_sites.items.len);
                try std.testing.expectEqual(@as(usize, 0), host.engine.active_stream.render_nodes.items.len);
                try std.testing.expectEqual(@as(usize, 0), host.engine.active_events.items.len);
                try std.testing.expectEqual(@as(usize, 0), host.engine.active_signal_graph.items.len);
                try std.testing.expect(!host.engine.render_cache.hasRoot());
                try std.testing.expectEqual(@as(usize, 0), host.dom_elements.items.len);
                try std.testing.expectEqual(refs_before.live_bytes, host.roc_allocations.snapshot().live_bytes);

                fault.configure(null);
                _ = try tryRenderInitialRoot(&host, &roc_host, root, &.{});
            } else {
                _ = try result;
            }

            try std.testing.expect(host.engine.render_cache.hasRoot());
            try std.testing.expectEqual(@as(usize, 2), host.engine.states.items.len);
            try std.testing.expectEqual(@as(usize, 2), host.engine.active_events.items.len);
            try std.testing.expect(host.engine.active_signal_graph.items.len != 0);
            try std.testing.expectEqual(@as(usize, 1), host.engine.each_row_sites.items.len);
            const each_site = host.engine.active_stream.scope_sites.items[host.engine.active_stream.scope_sites.items.len - 1];
            const segments = host.engine.activeEachRowRenderSegmentsInRenderOrder(std.testing.allocator, .{ .parent_scope_id = each_site.scope_id, .site_ordinal = each_site.ordinal });
            defer std.testing.allocator.free(segments);
            try std.testing.expectEqual(@as(usize, 2), segments.len);
            try std.testing.expectEqual(@as(usize, 2), segments[0].len);
            try std.testing.expectEqual(@as(usize, 2), segments[1].len);
            try std.testing.expectEqual(segments[0].start + segments[0].len, segments[1].start);
            try std.testing.expect(activeTextElementId(&host, "row-true") != null);
            return attempts;
        }
    };

    const attempts = try Runner.run(null);
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| _ = try Runner.run(failure_number);

    var host = HostEnv.init();
    var roc_host = makeSignalsRocHost(&host);
    host.engine.roc_host = &roc_host;
    defer {
        host.deinit();
        _ = host.gpa.deinit();
    }
    const items = [_]HostValue{ testHostValueI64(1), testHostValueI64(2) };
    const root = testElement(&roc_host, &.{testNodeEachWithItemsAndRow(&roc_host, &items, &testInitialEachNestedRowElemCallable)});
    defer root.decref(&roc_host);
    var fault = FaultAllocator.init(host.gpa.allocator());
    host.engine_allocator_override = fault.allocator();
    const collection = try HostEngine.PreparedRootCollection.prepare(&host.engine, &host, &roc_host, root, .{}, &.{});
    errdefer collection.deinit();
    const prepared = try HostEngine.PreparedRootDownstream.prepare(collection);
    defer prepared.deinit();
    fault.configure(1);
    prepared.commit();
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqual(@as(usize, 2), host.engine.states.items.len);
    try std.testing.expectEqual(@as(usize, 2), host.engine.active_events.items.len);
    try std.testing.expectEqual(@as(usize, 1), host.engine.each_row_sites.items.len);
    try std.testing.expect(host.engine.active_signal_graph.items.len != 0);
    try std.testing.expect(host.engine.render_cache.hasRoot());
}

/// Fixture surface for the model-based fuzz targets under `test/fuzzing`.
///
/// Fuzz objects are ordinary (non-test) ReleaseSafe builds, so nothing here
/// may depend on `std.testing`, and `bindHost` registers the current host
/// explicitly because `makeSignalsRocHost` only does so under test.
pub const fuzz_fixtures = struct {
    pub const Host = HostEnv;
    pub const NativeEngine = HostEngine;
    pub const BinaryArgs = ErasedHostValueBinaryArgs;
    pub const RenderCounts = CommandCounts;

    /// Creates a host whose allocator is a safety-checked debug allocator.
    pub fn createHost() HostEnv {
        return HostEnv.init();
    }

    /// Registers `host` as the current host and returns its Roc host table.
    pub fn bindHost(host: *HostEnv) abi.RocHost {
        current_host = host;
        return makeSignalsRocHost(host);
    }

    /// Tears the host down and reports whether its allocator saw a leak.
    pub fn destroyHost(host: *HostEnv) bool {
        host.deinit();
        current_host = null;
        return host.gpa.deinit() == .leak;
    }

    pub const ValueCapability = HostValueCapability;
    pub const BinderToken = HostBinderToken;

    pub const renderInitialRoot = tryRenderInitialRoot;
    pub const renderInitialRootWithArmedPublication = tryRenderInitialRootWithArmedPublication;
    pub const findActiveText = activeTextElementId;

    /// Publishes `value` into the live state cell identified by `node_id` as one
    /// atomic host transaction, exactly as a browser event would.
    ///
    /// This is the seam a fuzz target uses to drive a *live* structural edit:
    /// every `each` site reading the cell re-diffs its rows inside the single
    /// transaction, so one call can splice several sibling sites at once. The
    /// call takes ownership of `value` on both success and refusal; a refusal
    /// leaves the previously committed topology, render cache, and simulated
    /// DOM untouched and the same host ready to retry the identical edit.
    pub fn dispatchStateValue(
        host: *HostEnv,
        roc_host: *abi.RocHost,
        node_id: u64,
        value: HostValue,
        cap: HostValueCapability,
    ) HostEngine.CollectionError!CommandCounts {
        return host.engine.tryDispatchStateValue(host, roc_host, node_id, value, cap);
    }

    /// Returns the committed value of the state cell behind `node_id`, or null
    /// when no such cell is live.
    ///
    /// A refused transaction must leave the cell holding precisely what it held
    /// before, so a fuzz oracle snapshots this around an injected failure. The
    /// result is the raw erased handle rather than a decoded payload: the host
    /// may not inspect a retained Roc value's layout, and comparing handles is
    /// enough to prove the cell was not replaced.
    pub fn stateValue(host: *const HostEnv, node_id: u64) ?HostValue {
        const engine_ptr: *HostEngine = @constCast(&host.engine);
        const index = engine_ptr.stateIndexByNodeId(node_id) orelse return null;
        return engine_ptr.states.items[index].activePayloadConst().cell.value;
    }

    /// Lists the render-cache children of `parent`, in committed render order.
    ///
    /// The multi-parent splice bugs this surface exists to catch are visible
    /// here and almost nowhere else: a parent whose children were registered by
    /// two different staging passes ends up holding the same child twice, which
    /// no count-based oracle notices.
    pub fn renderChildren(host: *const HostEnv, parent: ids.ElemId) []const ids.ElemId {
        return host.engine.render_cache.nodes.items[parent.index()].children.items;
    }

    /// The committed render root, node 0 of the render cache.
    pub const render_root: ids.ElemId = ids.ElemId.fromRaw(0);

    /// Text an active simulated DOM node shows, or null for an element.
    pub fn renderText(host: *const HostEnv, elem_id: ids.ElemId) ?[]const u8 {
        for (host.dom_elements.items) |elem| {
            if (elem.active and elem.id == elem_id.raw()) return elem.text;
        }
        return null;
    }

    pub const element = testElement;
    pub const elementWith = testElementWith;
    pub const text = testNodeText;
    pub const state = testNodeState;
    pub const stateWithTokenInitialAndCapability = testNodeStateWithTokenAndInitialCapability;
    pub const newBinderToken = newTestBinderToken;
    pub const valueCapability = testHostValueCapability;
    pub const when = testNodeWhen;
    pub const ListPredicate = TestListPredicate;
    /// A `when` whose branch follows a predicate over the list in a state
    /// cell, so dispatching into the cell flips it.
    pub const whenOnListPredicate = testNodeWhenOnListPredicate;
    /// A branch or site that renders no DOM node at all: an `each` over a
    /// frozen empty list, which still registers a scope site at its index.
    pub const emptyEach = testNodeEmptyConstantEach;
    pub const i64Value = testHostValueI64;
    pub const i64ListValue = testHostValueI64List;
    pub const eachWithItemsRowAndCapture = testNodeEachWithItemsRowAndCapture;
    /// Builds an `each` whose rows come from the list held by the state cell
    /// `binder_token` names, as a copy taken through `Signal.map`.
    ///
    /// The copy is not decoration. A bare `Ref` hands the `each` the state's own
    /// capability, and the staged initial mount cannot resolve that while it is
    /// still creating the cell, so it terminates the host. Mapping the list
    /// through gives the site a capability of its own while keeping the real
    /// dependency, so one dispatch into the cell still re-diffs every site
    /// reading it.
    pub const eachOverStateListRowAndCapture = testNodeEachOverStateListRowAndCapture;

    pub const captureAs = testCapturePtrAs;
    pub const argsAs = testErasedArgsAs;
    pub const readI64 = testReadHostValueI64;
    pub const writeResult = writeTestErasedResult;
};
