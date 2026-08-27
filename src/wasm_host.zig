//! Browser-oriented Signals platform host symbols for wasm32 builds.
//!
//! This host links Signals Roc apps as wasm reactors and owns the browser-facing
//! boundary only: `roc_alloc` marshalling, the command-buffer sink serialized
//! into linear memory, and the event payload slots JavaScript fills from
//! descriptors.
//!
//! All reactive and structural behaviour lives in the shared `engine.zig`. Like
//! the native host, this file is a thin shell: it provides a `Ctx` (`WasmCtx`)
//! plus a render `sink()` and drives the engine's collect/apply/dispatch path.
//! It deliberately holds no reactive or structural logic of its own.

const std = @import("std");
const signals = @import("signals");
const abi = signals.abi;
const abi_view = signals.abi_view;
const boundary = signals.boundary;
const render = signals.render;
const render_sink = signals.render_sink;
const host_value_registry = signals.host_value_registry;
const erased_calls = signals.erased_calls;
const hv = signals.host_values;
const engine = signals.engine;

const HostValue = u64;
const HostValueCapability = hv.HostValueCapabilityHandle;
const ElemBox = @typeInfo(@TypeOf(abi.roc_ui_init)).@"fn".return_type.?;
const RenderTextField = render.TextField;
const RenderBoolField = render.BoolField;
const RenderEventKind = render.EventKind;
const SharedEngine = engine.Engine(WasmCtx);
const HostNodeDescriptorStream = engine.HostNodeDescriptorStream;
const BoundaryPayloadDescriptor = engine.BoundaryPayloadDescriptor;
const BoundaryPayloadKind = boundary.PayloadKind;
const EventBindingKey = render_sink.EventBindingKey;
const EventBinding = render_sink.EventBinding;
const EventBindCommand = render_sink.EventBindCommand;
const EventClearCommand = render_sink.EventClearCommand;
const HostActiveEventDesc = SharedEngine.ActiveEventDesc;

const WasmCtx = struct {
    pub const Handle = WasmCtx;
    pub const RegistryOps = hv.RegistryOps();
    pub const Metrics = engine.NoMetrics;
    pub const Sink = WasmSink;

    pub fn zeroMetrics() Metrics {
        return .{};
    }

    pub fn allocator(_: Handle) std.mem.Allocator {
        return std.heap.wasm_allocator;
    }

    pub fn cloneHostValue(_: Handle, value: HostValue) HostValue {
        return shared_engine.host_values.clone(std.heap.wasm_allocator, value, registryOps()) catch |err| {
            failHostValueRegistryError(err);
        };
    }

    pub fn stateValueByNodeId(_: Handle, node_id: u64) HostValue {
        return currentStateValue(node_id);
    }

    pub fn stateCapability(_: Handle, node_id: u64) HostValueCapability {
        return shared_engine.stateCapability(node_id) catch failHost();
    }

    pub fn updateStateValue(_: Handle, _: *abi.RocHost, node_id: u64, value: HostValue) bool {
        return updateStateCell(node_id, value);
    }

    pub fn initialLocationPayload(_: Handle, _: *abi.RocHost, cap: HostValueCapability) HostValue {
        return makeInitialLocationPayload(cap);
    }

    pub fn initialVisibilityPayload(_: Handle, _: *abi.RocHost, cap: HostValueCapability) HostValue {
        return makeInitialVisibilityPayload(cap);
    }

    pub fn initialOnlinePayload(_: Handle, _: *abi.RocHost, cap: HostValueCapability) HostValue {
        return makeInitialOnlinePayload(cap);
    }

    pub fn initialStoragePayload(_: Handle, _: *abi.RocHost, area: boundary.StorageArea, key: []const u8, cap: HostValueCapability) HostValue {
        return makeInitialStoragePayload(area, key, cap);
    }

    pub fn sink(_: Handle) Sink {
        return .{};
    }

    pub fn debugPhase(_: Handle, phase: u32) void {
        roc_allocation_phase = phase;
    }

    pub fn failWithMessage(_: Handle, message: []const u8) noreturn {
        failHostWithFmt("{s}", .{message});
    }

    pub fn pushHostValueCapabilities(_: Handle, caps: []const HostValueCapability) void {
        active_capabilities.push(caps);
    }

    pub fn popHostValueCapabilities(_: Handle) void {
        active_capabilities.pop();
    }
};

// The engine threads a zero-sized `WasmCtx{}` value through every
// collect/apply/dispatch call and reaches host state through its methods plus the
// `shared_engine` global. The command-buffer sink always emits — there is no
// silent "build cache only" phase in the browser host (teardown never touches
// the sink), so the sink carries no state.
const WasmSink = struct {
    pub fn reset(_: WasmSink) void {
        appendCommand(.reset_dom, 0, 0, 0, 0, 0);
    }

    pub fn appendNode(_: WasmSink, elem_id: u64, parent_elem_id: u64, tag: []const u8) void {
        if (std.mem.eql(u8, tag, "text")) {
            appendStringCommand(.create_text, toU32(elem_id), "");
        } else {
            appendStringCommand(.create_element, toU32(elem_id), tag);
        }
        appendCommand(.append_child, toU32(parent_elem_id), toU32(elem_id), 0, 0, 0);
    }

    pub fn ensureNode(_: WasmSink, elem_id: u64, tag: []const u8) void {
        if (std.mem.eql(u8, tag, "text")) {
            appendStringCommand(.create_text, toU32(elem_id), "");
        } else {
            appendStringCommand(.create_element, toU32(elem_id), tag);
        }
    }

    pub fn removeNode(_: WasmSink, elem_id: u64) void {
        appendCommand(.remove_node, toU32(elem_id), 0, 0, 0, 0);
    }

    // The engine hands the sink the final child order; achieving it in the real
    // DOM is a sequence of `appendChild`s, which the JS executor treats as a move
    // for already-attached nodes and a parent-link for freshly created ones. The
    // engine still computes the minimal-move count for its telemetry; this thin
    // executor just realises the order it was given.
    pub fn replaceChildren(_: WasmSink, parent_elem_id: u64, next_child_ids: []const u64) void {
        emitAppendChildren(parent_elem_id, next_child_ids);
    }

    pub fn replaceChildrenForMoves(_: WasmSink, parent_elem_id: u64, next_child_ids: []const u64) void {
        emitAppendChildren(parent_elem_id, next_child_ids);
    }

    pub fn applyTextField(_: WasmSink, elem_id: u64, field: RenderTextField, value: []const u8) void {
        if (textAttrNameForField(field)) |name| {
            appendDynamicSetAttrText(toU32(elem_id), name, value);
        } else {
            appendStringCommand(field.setOp(), toU32(elem_id), value);
        }
    }

    pub fn applyTextAttr(_: WasmSink, elem_id: u64, name: []const u8, value: []const u8) void {
        appendDynamicSetAttrText(toU32(elem_id), name, value);
    }

    pub fn applyBoolField(_: WasmSink, elem_id: u64, field: RenderBoolField, value: bool) void {
        appendBoolFieldCommand(field, toU32(elem_id), value);
    }

    pub fn clearTextField(_: WasmSink, elem_id: u64, field: RenderTextField) void {
        if (textAttrNameForField(field)) |name| {
            appendDynamicRemoveAttr(toU32(elem_id), name);
        } else {
            appendStringCommand(field.setOp(), toU32(elem_id), "");
        }
    }

    pub fn clearTextAttr(_: WasmSink, elem_id: u64, name: []const u8) void {
        appendDynamicRemoveAttr(toU32(elem_id), name);
    }

    pub fn clearBoolField(_: WasmSink, elem_id: u64, field: RenderBoolField) void {
        appendBoolFieldCommand(field, toU32(elem_id), false);
    }

    pub fn bindEvent(_: WasmSink, elem_id: u64, key: EventBindingKey, binding: EventBinding) void {
        appendEventBindCommand(.{ .elem_id = elem_id, .key = key, .binding = binding });
    }

    pub fn clearEvent(_: WasmSink, elem_id: u64, key: EventBindingKey) void {
        appendEventClearCommand(.{ .elem_id = elem_id, .key = key });
    }

    pub fn startInterval(_: WasmSink, token: u64, period_ms: u64) void {
        appendCommand(.start_interval, toU32(token), toU32(period_ms), 0, 0, 0);
    }

    pub fn cancelInterval(_: WasmSink, token: u64) void {
        appendCommand(.cancel_interval, toU32(token), 0, 0, 0, 0);
    }

    pub fn startTask(_: WasmSink, request_id: u64, task_name: []const u8, request: []const u8) void {
        const name_offset = storeBytes(task_name);
        const request_offset = storeBytes(request);
        appendCommand(.start_task, toU32(request_id), name_offset, toU32(task_name.len), request_offset, toU32(request.len));
    }

    pub fn cancelTask(_: WasmSink, request_id: u64) void {
        appendCommand(.cancel_task, toU32(request_id), 0, 0, 0, 0);
    }

    pub fn navigate(_: WasmSink, kind: render_sink.NavigationKind, location: boundary.LocationSnapshot) void {
        setCurrentLocationSnapshot(location);
        appendLocationCommand(switch (kind) {
            .push => .push_state,
            .replace => .replace_state,
        }, location);
    }

    pub fn setDocumentTitle(_: WasmSink, title: []const u8) void {
        appendDocumentTitleCommand(title);
    }

    pub fn setStorageText(_: WasmSink, area: boundary.StorageArea, key: []const u8, value: []const u8) void {
        appendStorageSetCommand(area, key, value);
    }

    pub fn removeStorage(_: WasmSink, area: boundary.StorageArea, key: []const u8) void {
        appendStorageRemoveCommand(area, key);
    }

    pub fn debugAssertNode(_: WasmSink, _: u64, _: bool, _: ?[]const u8, _: ?u64, _: []const u64, _: ?u64, _: ?u64, _: ?u64, _: ?u64, _: ?u64, _: ?u64, _: ?u64) void {}
};

fn emitAppendChildren(parent_elem_id: u64, next_child_ids: []const u64) void {
    for (next_child_ids) |child_id| {
        appendCommand(.append_child, toU32(parent_elem_id), toU32(child_id), 0, 0, 0);
    }
}

var shared_engine: SharedEngine = .init();
var command_batch: render.TransactionalBatch = .{};
var initial_location_payload: ?[]u8 = null;
var initial_visibility_payload: ?[]u8 = null;
var initial_online_payload: ?[]u8 = null;

const StorageDeclaration = struct {
    area: boundary.StorageArea,
    key: []const u8,
};

const InitialStoragePayload = struct {
    area: boundary.StorageArea,
    key: []u8,
    payload: []u8,

    fn deinit(self: InitialStoragePayload, alloc: std.mem.Allocator) void {
        alloc.free(self.key);
        alloc.free(self.payload);
    }
};

var storage_declarations: std.ArrayListUnmanaged(StorageDeclaration) = .empty;
var initial_storage_payloads: std.ArrayListUnmanaged(InitialStoragePayload) = .empty;
var mount_prepared: bool = false;

const RocAllocation = struct {
    user_ptr: [*]u8,
    requested_size: usize,
    allocated_size: usize,
    alignment: std.mem.Alignment,
    phase: u32,
};

const FreedRocAllocation = struct {
    user_ptr_addr: usize,
    requested_size: usize,
    allocated_size: usize,
    alignment: std.mem.Alignment,
    phase: u32,
};

const NearestRocAllocation = struct {
    user_ptr_addr: usize,
    allocated_size: usize,
    distance: usize,
};

const recent_freed_roc_allocation_capacity = 4096;

var roc_allocations: std.ArrayListUnmanaged(RocAllocation) = .empty;
var recent_freed_roc_allocations: [recent_freed_roc_allocation_capacity]FreedRocAllocation = undefined;
var recent_freed_roc_allocation_len: usize = 0;
var recent_freed_roc_allocation_next: usize = 0;
var roc_allocation_phase: u32 = 0;
var active_capabilities: hv.ActiveCapabilityStack = .{};
var roc_host_env: u8 = 0;
var roc_host = abi.RocHost{
    .env = @ptrCast(&roc_host_env),
    .roc_alloc = &rocAllocForAbi,
    .roc_dealloc = &rocDeallocForAbi,
    .roc_realloc = &rocReallocForAbi,
    .roc_dbg = &rocDbgForAbi,
    .roc_expect_failed = &rocExpectFailedForAbi,
    .roc_crashed = &rocCrashedForAbi,
};

var last_host_error: []const u8 = "";
var last_host_error_buf: [512]u8 = undefined;
var host_poisoned: bool = false;

fn beginHostCall() void {
    if (host_poisoned) @trap();
    last_host_error = "";
}

fn failHostWith(message: []const u8) noreturn {
    command_batch.abort();
    host_poisoned = true;
    last_host_error = message;
    @trap();
}

fn failHostWithFmt(comptime fmt: []const u8, args: anytype) noreturn {
    command_batch.abort();
    host_poisoned = true;
    last_host_error = std.fmt.bufPrint(&last_host_error_buf, fmt, args) catch "Signals wasm host invariant failed while formatting diagnostic";
    @trap();
}

fn failHost() noreturn {
    failHostWith("Signals wasm host invariant failed");
}

fn allocator() std.mem.Allocator {
    return std.heap.wasm_allocator;
}

fn toU32(value: anytype) u32 {
    return std.math.cast(u32, value) orelse failHost();
}

fn alignmentFromBytes(alignment: usize) std.mem.Alignment {
    if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) failHost();
    return @enumFromInt(std.math.log2_int(usize, alignment));
}

fn appendCommand(op: render.Op, a: u32, b: u32, c: u32, d: u32, e: u32) void {
    command_batch.staged.commands.append(allocator(), op, a, b, c, d, e) catch failHostWith("out of memory while staging render commands");
}

fn clearCommandBuffers() void {
    command_batch.clearPublished();
}

fn beginCommandTransaction() void {
    command_batch.begin();
}

fn commitCommandTransaction() void {
    command_batch.commit();
}

fn storeBytes(bytes: []const u8) u32 {
    const offset = toU32(command_batch.staged.strings.items.len);
    command_batch.staged.strings.appendSlice(allocator(), bytes) catch failHostWith("out of memory while staging render strings");
    return offset;
}

fn appendStringCommand(op: render.Op, elem_id: u32, bytes: []const u8) void {
    appendCommand(op, elem_id, storeBytes(bytes), toU32(bytes.len), 0, 0);
}

fn storeLocationHref(location: boundary.LocationSnapshot) render.DynamicSlice {
    if (location.path.len == 0 or location.path[0] != '/') failHostWith("location path must start with /");
    const offset = toU32(command_batch.staged.strings.items.len);
    command_batch.staged.strings.appendSlice(allocator(), location.path) catch failHostWith("out of memory while staging location command");
    if (location.query.len != 0) {
        command_batch.staged.strings.append(allocator(), '?') catch failHostWith("out of memory while staging location command");
        command_batch.staged.strings.appendSlice(allocator(), location.query) catch failHostWith("out of memory while staging location command");
    }
    if (location.hash.len != 0) {
        command_batch.staged.strings.append(allocator(), '#') catch failHostWith("out of memory while staging location command");
        command_batch.staged.strings.appendSlice(allocator(), location.hash) catch failHostWith("out of memory while staging location command");
    }
    return .{ .offset = offset, .len = toU32(command_batch.staged.strings.items.len - offset) };
}

fn appendLocationCommand(op: render.Op, location: boundary.LocationSnapshot) void {
    const href = storeLocationHref(location);
    appendCommand(op, href.offset, href.len, 0, 0, 0);
}

fn appendDocumentTitleCommand(title: []const u8) void {
    appendCommand(.set_document_title, 0, storeBytes(title), toU32(title.len), 0, 0);
}

fn appendStorageSetCommand(area: boundary.StorageArea, key: []const u8, value: []const u8) void {
    const key_offset = storeBytes(key);
    const value_offset = storeBytes(value);
    appendCommand(.set_storage_text, toU32(@intFromEnum(area)), key_offset, toU32(key.len), value_offset, toU32(value.len));
}

fn appendStorageRemoveCommand(area: boundary.StorageArea, key: []const u8) void {
    const key_offset = storeBytes(key);
    appendCommand(.remove_storage, toU32(@intFromEnum(area)), key_offset, toU32(key.len), 0, 0);
}

fn textAttrNameForField(field: RenderTextField) ?[]const u8 {
    return switch (field) {
        .role => "role",
        .label => "aria-label",
        .test_id => "data-testid",
        .class => "class",
        .text, .value => null,
    };
}

fn appendDynamicSetAttrText(elem_id: u32, name: []const u8, value: []const u8) void {
    const slice = command_batch.staged.dynamic.appendSetAttrText(allocator(), elem_id, name, value) catch failHostWith("out of memory while staging dynamic render command");
    appendCommand(.extended, slice.offset, slice.len, 0, 0, 0);
}

fn appendDynamicRemoveAttr(elem_id: u32, name: []const u8) void {
    const slice = command_batch.staged.dynamic.appendRemoveAttr(allocator(), elem_id, name) catch failHostWith("out of memory while staging dynamic render command");
    appendCommand(.extended, slice.offset, slice.len, 0, 0, 0);
}

fn appendEventBindCommand(command: EventBindCommand) void {
    const elem_id = toU32(command.elem_id);
    const binding = command.binding;
    if (binding.delivery.effective != .native) {
        @panic("browser event command wire only supports native delivery");
    }
    switch (command.key) {
        .fixed => |kind| {
            if (binding.canUseFixedOpcode(kind)) {
                appendCommand(kind.bindOp(), elem_id, toU32(binding.event_id), 0, 0, 0);
            } else {
                appendDynamicBindEvent(elem_id, kind.domEventName(), toU32(binding.event_id), binding.policy.toWireBits(), binding.delivery.toWire(), binding.payload_descriptor);
            }
        },
        .named => |name| appendDynamicBindEvent(elem_id, name, toU32(binding.event_id), binding.policy.toWireBits(), binding.delivery.toWire(), binding.payload_descriptor),
    }
}

fn appendEventClearCommand(command: EventClearCommand) void {
    const elem_id = toU32(command.elem_id);
    switch (command.key) {
        .fixed => |kind| appendCommand(.clear_event, elem_id, toU32(@intFromEnum(kind)), 0, 0, 0),
        .named => |name| appendDynamicClearEvent(elem_id, name),
    }
}

fn appendDynamicBindEvent(elem_id: u32, name: []const u8, event_id: u32, options: u32, delivery: render.EventDeliveryWire, payload_descriptor: BoundaryPayloadDescriptor) void {
    const slice = command_batch.staged.dynamic.appendBindEvent(allocator(), elem_id, event_id, name, options, delivery, payload_descriptor) catch failHostWith("out of memory while staging dynamic event command");
    appendCommand(.extended, slice.offset, slice.len, 0, 0, 0);
}

fn appendDynamicClearEvent(elem_id: u32, name: []const u8) void {
    const slice = command_batch.staged.dynamic.appendClearEvent(allocator(), elem_id, name) catch failHostWith("out of memory while staging dynamic event command");
    appendCommand(.extended, slice.offset, slice.len, 0, 0, 0);
}

fn appendBoolFieldCommand(field: RenderBoolField, elem_id: u32, value: bool) void {
    appendCommand(field.setOp(), elem_id, @intFromBool(value), 0, 0, 0);
}

const callErasedHostValueToHostValue = erased_calls.callErasedHostValueToHostValue;
const callErasedHostValueHostValueToHostValue = erased_calls.callErasedHostValueHostValueToHostValue;
const callErasedHostValueHostValueHostValueToHostValue = erased_calls.callErasedHostValueHostValueHostValueToHostValue;
const callErasedHostValueToUnit = erased_calls.callErasedHostValueToUnit;

fn callHostValueToUnitWithCapability(cap: HostValueCapability, callable: abi.RocErasedCallable, value: HostValue) void {
    const caps = [_]HostValueCapability{cap};
    active_capabilities.push(&caps);
    defer active_capabilities.pop();
    callErasedHostValueToUnit(&roc_host, callable, value);
}

fn callHostValueToHostValueWithCapability(cap: HostValueCapability, callable: abi.RocErasedCallable, value: HostValue) HostValue {
    const caps = [_]HostValueCapability{cap};
    active_capabilities.push(&caps);
    defer active_capabilities.pop();
    return callErasedHostValueToHostValue(&roc_host, callable, value);
}

fn callHostValueHostValueToHostValueWithCapabilities(left_cap: HostValueCapability, right_cap: HostValueCapability, callable: abi.RocErasedCallable, left: HostValue, right: HostValue) HostValue {
    const caps = [_]HostValueCapability{ left_cap, right_cap };
    active_capabilities.push(&caps);
    defer active_capabilities.pop();
    return callErasedHostValueHostValueToHostValue(&roc_host, callable, left, right);
}

fn callHostValueHostValueHostValueToHostValueWithCapabilities(first_cap: HostValueCapability, second_cap: HostValueCapability, third_cap: HostValueCapability, callable: abi.RocErasedCallable, first: HostValue, second: HostValue, third: HostValue) HostValue {
    const caps = [_]HostValueCapability{ first_cap, second_cap, third_cap };
    active_capabilities.push(&caps);
    defer active_capabilities.pop();
    return callErasedHostValueHostValueHostValueToHostValue(&roc_host, callable, first, second, third);
}

// --- Host value registry glue (all routed through the engine's registry) ---

fn registryOps() hv.RegistryOps() {
    return .{
        .roc_host = &roc_host,
        .active_capabilities = &active_capabilities,
        .debug_phase = &roc_allocation_phase,
    };
}

fn failHostValueRegistryError(err: host_value_registry.Error) noreturn {
    switch (err) {
        error.InvalidHandle => failHostWith("HostValue handle referenced an unknown value"),
        error.ReleasedHandle => failHostWith("HostValue handle referenced a released value"),
        error.UnconsumedHandle => failHostWith("HostValue consuming callback returned without taking the transferred value"),
        error.MissingCapability => failHostWith("HostValue operation crossed erasure boundary without an owning capability"),
        error.CapabilityMismatch => failHostWith("HostValue operation used a capability that does not own the retained value"),
        error.ConflictingCapability => failHostWith("HostValue was assigned a conflicting capability"),
        error.InactiveCapability => failHostWith("HostValue split operation ran without an active owning capability"),
        error.CloneCapabilityMismatch => failHostWith("HostValue capability clone returned a value owned by a different capability"),
        error.CloneReturnedSource => failHostWith("HostValue capability clone returned the source handle"),
        error.OutOfMemory => failHostWith("HostValue registry allocation failed"),
    }
}

fn cloneHostValue(value: HostValue) HostValue {
    return shared_engine.host_values.clone(allocator(), value, registryOps()) catch |err| {
        failHostValueRegistryError(err);
    };
}

fn setHostValueCapability(value: HostValue, cap: HostValueCapability) void {
    shared_engine.host_values.setCapability(value, cap, registryOps()) catch |err| {
        failHostValueRegistryError(err);
    };
}

fn hostValueTakeEpoch() u64 {
    return shared_engine.host_values.takeEpoch();
}

fn assertHostValueTakenAfter(value: HostValue, epoch: u64) void {
    shared_engine.host_values.assertTakenAfter(value, epoch) catch |err| {
        failHostValueRegistryError(err);
    };
}

// `ctx` surface consumed by the shared `host_values` box constructors. The
// browser host has no test-kind bookkeeping, so `recordKind` is a no-op.
const HostValueOpsCtx = struct {
    pub fn store(_: HostValueOpsCtx, box: abi.RocBox) HostValue {
        return shared_engine.host_values.storeOwnedCapability(allocator(), box, null, registryOps()) catch |err| {
            failHostValueRegistryError(err);
        };
    }

    pub fn storeWithCapability(_: HostValueOpsCtx, box: abi.RocBox, cap: HostValueCapability) HostValue {
        return shared_engine.host_values.storeRetainedCapability(allocator(), box, cap, registryOps()) catch |err| {
            failHostValueRegistryError(err);
        };
    }

    pub fn recordKind(_: HostValueOpsCtx, _: HostValue, _: hv.ValueKind) void {}
};

fn hostValueUnit() HostValue {
    return hv.makeUnit(HostValueOpsCtx{}, &roc_host);
}

fn hostValueStr(bytes: []const u8) HostValue {
    return hv.makeStr(HostValueOpsCtx{}, &roc_host, bytes);
}

fn hostValueBool(value: bool) HostValue {
    return hv.makeBool(HostValueOpsCtx{}, &roc_host, value);
}

fn hostValueU8List(bytes: []const u8) HostValue {
    return hv.makeU8List(HostValueOpsCtx{}, &roc_host, bytes);
}

fn hostValueU8ListWithCapability(bytes: []const u8, cap: HostValueCapability) HostValue {
    return hv.makeU8ListWithCapability(HostValueOpsCtx{}, &roc_host, bytes, cap);
}

fn makeDefaultLocationPayload() []u8 {
    return boundary.encodeLocationPayload(allocator(), .{ .path = "/", .query = "", .hash = "" }) catch |err| switch (err) {
        error.OutOfMemory => failHostWith("location payload allocation failed"),
        error.BoundaryTextTooLong => failHostWith("location payload field exceeded boundary length"),
    };
}

fn makeInitialLocationPayload(cap: HostValueCapability) HostValue {
    if (initial_location_payload) |bytes| {
        return hostValueU8ListWithCapability(bytes, cap);
    }

    const bytes = makeDefaultLocationPayload();
    defer allocator().free(bytes);
    return hostValueU8ListWithCapability(bytes, cap);
}

fn makeDefaultVisibilityPayload() []u8 {
    return boundary.encodeVisibilityPayload(allocator(), .visible) catch |err| switch (err) {
        error.OutOfMemory => failHostWith("visibility payload allocation failed"),
        error.BoundaryTextTooLong => failHostWith("visibility payload field exceeded boundary length"),
    };
}

fn makeInitialVisibilityPayload(cap: HostValueCapability) HostValue {
    if (initial_visibility_payload) |bytes| {
        return hostValueU8ListWithCapability(bytes, cap);
    }

    const bytes = makeDefaultVisibilityPayload();
    defer allocator().free(bytes);
    return hostValueU8ListWithCapability(bytes, cap);
}

fn makeDefaultOnlinePayload() []u8 {
    return boundary.encodeOnlinePayload(allocator(), .online) catch |err| switch (err) {
        error.OutOfMemory => failHostWith("online payload allocation failed"),
        error.BoundaryTextTooLong => failHostWith("online payload field exceeded boundary length"),
    };
}

fn makeInitialOnlinePayload(cap: HostValueCapability) HostValue {
    if (initial_online_payload) |bytes| {
        return hostValueU8ListWithCapability(bytes, cap);
    }

    const bytes = makeDefaultOnlinePayload();
    defer allocator().free(bytes);
    return hostValueU8ListWithCapability(bytes, cap);
}

fn initialStoragePayload(area: boundary.StorageArea, key: []const u8) ?[]const u8 {
    for (initial_storage_payloads.items) |entry| {
        if (entry.area == area and std.mem.eql(u8, entry.key, key)) {
            return entry.payload;
        }
    }
    return null;
}

fn makeInitialStoragePayload(area: boundary.StorageArea, key: []const u8, cap: HostValueCapability) HostValue {
    if (initialStoragePayload(area, key)) |bytes| {
        return hostValueU8ListWithCapability(bytes, cap);
    }

    const bytes = boundary.encodeStoragePayload(allocator(), .missing) catch |err| switch (err) {
        error.OutOfMemory => failHostWith("storage payload allocation failed"),
        error.BoundaryTextTooLong => failHostWith("storage payload field exceeded boundary length"),
    };
    defer allocator().free(bytes);
    return hostValueU8ListWithCapability(bytes, cap);
}

fn clearStorageDeclarations() void {
    storage_declarations.clearRetainingCapacity();
}

fn clearInitialStoragePayloads() void {
    for (initial_storage_payloads.items) |entry| {
        entry.deinit(allocator());
    }
    initial_storage_payloads.clearRetainingCapacity();
}

fn clearStorageEnvironment() void {
    clearStorageDeclarations();
    clearInitialStoragePayloads();
}

fn rememberStorageDeclaration(area: boundary.StorageArea, key: []const u8) void {
    for (storage_declarations.items) |entry| {
        if (entry.area == area and std.mem.eql(u8, entry.key, key)) {
            return;
        }
    }
    storage_declarations.append(allocator(), .{ .area = area, .key = key }) catch failHost();
}

fn discoverStorageSignalExpr(expr: abi.NodeSignalExpr) void {
    switch (abi_view.SignalExpr.fromAbi(expr)) {
        .ref, .const_value, .task_source, .interval_source, .location_source, .online_source, .visibility_source => {},
        .map => |payload| discoverStorageSignalExpr(payload.input.*),
        .map2 => |payload| {
            discoverStorageSignalExpr(payload.left.*);
            discoverStorageSignalExpr(payload.right.*);
        },
        .combine => |payload| {
            for (payload.children) |child| {
                discoverStorageSignalExpr(child);
            }
        },
        .storage_source => |payload| rememberStorageDeclaration(payload.area, payload.key.asSlice()),
    }
}

fn discoverStorageAttr(attr: abi.NodeAttr) void {
    switch (abi_view.NodeAttr.fromAbi(attr)) {
        .static_text, .static_bool, .event, .named_event => {},
        .signal_text => |payload| discoverStorageSignalExpr(payload.signal.*),
        .signal_optional_text => |payload| discoverStorageSignalExpr(payload.signal.*),
        .signal_bool => |payload| discoverStorageSignalExpr(payload.signal.*),
    }
}

fn discoverStorageElem(elem: abi.Elem) void {
    switch (abi_view.Elem.fromAbi(elem)) {
        .element => |payload| {
            for (payload.attrs) |attr| {
                discoverStorageAttr(attr);
            }
            for (payload.children) |child| {
                discoverStorageElem(child);
            }
        },
        .text, .cleanup, .on_mount => {},
        .text_signal => |payload| discoverStorageSignalExpr(payload.signal.*),
        .on_change => |payload| discoverStorageSignalExpr(payload.signal.*),
        .state => |payload| discoverStorageElem(payload.child.*),
        .component => |payload| discoverStorageElem(payload.child.*),
        .when => |payload| {
            discoverStorageSignalExpr(payload.condition.*);
            discoverStorageElem(payload.when_false.*);
            discoverStorageElem(payload.when_true.*);
        },
        .each => |payload| {
            discoverStorageSignalExpr(payload.items.*);
        },
    }
}

fn setInitialStoragePayload(area: boundary.StorageArea, key: []const u8, payload: []const u8) void {
    for (initial_storage_payloads.items) |*entry| {
        if (entry.area == area and std.mem.eql(u8, entry.key, key)) {
            allocator().free(entry.payload);
            entry.payload = allocator().dupe(u8, payload) catch failHost();
            return;
        }
    }

    const key_copy = allocator().dupe(u8, key) catch failHost();
    errdefer allocator().free(key_copy);
    const payload_copy = allocator().dupe(u8, payload) catch failHost();
    errdefer allocator().free(payload_copy);
    initial_storage_payloads.append(allocator(), .{ .area = area, .key = key_copy, .payload = payload_copy }) catch failHost();
}

fn setCurrentLocationPayload(bytes: []const u8) void {
    if (initial_location_payload) |existing| {
        allocator().free(existing);
    }
    initial_location_payload = allocator().dupe(u8, bytes) catch failHost();
}

fn setInitialLocationPayload(bytes: []const u8) void {
    if (shared_engine.root_elem != null) failHostWith("initial location cannot be set after mount");
    setCurrentLocationPayload(bytes);
}

fn setCurrentLocationSnapshot(location: boundary.LocationSnapshot) void {
    const bytes = boundary.encodeLocationPayload(allocator(), location) catch |err| switch (err) {
        error.OutOfMemory => failHostWith("location payload allocation failed"),
        error.BoundaryTextTooLong => failHostWith("location payload field exceeded boundary length"),
    };
    defer allocator().free(bytes);
    setCurrentLocationPayload(bytes);
}

fn clearInitialLocationPayload() void {
    if (initial_location_payload) |bytes| {
        allocator().free(bytes);
        initial_location_payload = null;
    }
}

fn setCurrentVisibilityPayload(bytes: []const u8) void {
    if (initial_visibility_payload) |existing| {
        allocator().free(existing);
    }
    initial_visibility_payload = allocator().dupe(u8, bytes) catch failHost();
}

fn setInitialVisibilityPayload(bytes: []const u8) void {
    if (shared_engine.root_elem != null) failHostWith("initial visibility cannot be set after mount");
    setCurrentVisibilityPayload(bytes);
}

fn clearInitialVisibilityPayload() void {
    if (initial_visibility_payload) |bytes| {
        allocator().free(bytes);
        initial_visibility_payload = null;
    }
}

fn setCurrentOnlinePayload(bytes: []const u8) void {
    if (initial_online_payload) |existing| {
        allocator().free(existing);
    }
    initial_online_payload = allocator().dupe(u8, bytes) catch failHost();
}

fn setInitialOnlinePayload(bytes: []const u8) void {
    if (shared_engine.root_elem != null) failHostWith("initial online status cannot be set after mount");
    setCurrentOnlinePayload(bytes);
}

fn clearInitialOnlinePayload() void {
    if (initial_online_payload) |bytes| {
        allocator().free(bytes);
        initial_online_payload = null;
    }
}

// --- State access (routed through the engine's state table) ---

fn currentStateValue(node_id: u64) HostValue {
    const state_index = shared_engine.stateIndexByNodeId(node_id) orelse failHost();
    return cloneHostValue(shared_engine.states.items[state_index].cell.value);
}

fn updateStateCell(node_id: u64, value: HostValue) bool {
    const state_index = shared_engine.stateIndexByNodeId(node_id) orelse failHost();
    const state = &shared_engine.states.items[state_index];
    const ctx = WasmCtx{};
    if (state.cell.valueEquals(ctx, &roc_host, value)) {
        state.cell.dropIncoming(ctx, &roc_host, value);
        return false;
    }
    state.cell.replaceValue(ctx, &roc_host, value);
    state.version += 1;
    return true;
}

// --- Engine-driven init / dispatch / teardown ---

fn dropMovedElemPayload(_: ?*anyopaque, _: *abi.RocHost) callconv(.c) void {}

fn initRootElem() void {
    if (shared_engine.root_elem != null) failHostWith("Roc root Elem initialized more than once");
    const root_box: ElemBox = abi.roc_ui_init();
    shared_engine.root_elem = root_box.*;
    abi.decrefBoxWith(@ptrCast(root_box), @alignOf(abi.Elem), true, &dropMovedElemPayload, &roc_host);
}

fn prepareMountRoot() void {
    clearActiveRuntime();
    clearCommandBuffers();
    clearStorageEnvironment();
    initRootElem();
    if (shared_engine.root_elem) |root| {
        discoverStorageElem(root);
    }
    mount_prepared = true;
}

/// Collect the root `Elem` into a fresh descriptor stream, apply it against the
/// active stream (first render creates everything; later renders diff), rebuild
/// the active event table, and swap the new stream in. Mirrors the native host's
/// `renderActiveRootMeasured`.
fn renderActiveRoot(dirty_source_node_ids: []const u64) void {
    const ctx = WasmCtx{};
    const root = shared_engine.root_elem orelse failHost();

    var next_stream: HostNodeDescriptorStream = .{};
    shared_engine.collectActiveElemRootDescriptors(ctx, &roc_host, &next_stream, root, dirty_source_node_ids);

    if (!shared_engine.hasRenderRoot()) {
        _ = shared_engine.applyNodeDescriptorStream(ctx, &roc_host, &next_stream);
    } else {
        _ = shared_engine.applyStructuralNodeDescriptorStream(ctx, &roc_host, &next_stream);
    }

    shared_engine.rebuildActiveEventsFromStream(ctx, &next_stream);
    shared_engine.active_stream.deinit(allocator(), ctx, &roc_host, &shared_engine.pending_roc_metrics);
    shared_engine.active_stream = next_stream;
    const on_change_initial_counts = shared_engine.runActiveOnChangeInitialCommands(ctx, &roc_host);
    const mount_counts = shared_engine.runActiveMountCommands(ctx, &roc_host);
    shared_engine.render_metrics.addCommandCounts(on_change_initial_counts);
    shared_engine.render_metrics.addCommandCounts(mount_counts);
}

fn hostEventById(event_id: u32) HostActiveEventDesc {
    if (event_id == 0 or event_id > shared_engine.active_events.items.len) failHost();
    return shared_engine.active_events.items[event_id - 1];
}

/// Route a DOM event into its source node's retained reducer thunk, then
/// propagate in rank order and apply both scalar render sinks and any structural
/// splice the change triggers. Mirrors the native host's `dispatchRocEventMeasured`.
fn dispatchEvent(desc: HostActiveEventDesc, payload: HostValue) void {
    const ctx = WasmCtx{};
    const payload_cap = desc.payload_reducer.capability;
    setHostValueCapability(payload, payload_cap);
    defer callHostValueToUnitWithCapability(payload_cap, hv.hostValueCapabilityDrop(payload_cap), payload);

    shared_engine.recordDispatch();

    const current = currentStateValue(desc.target_node_id);
    const state_cap = shared_engine.stateCapability(desc.target_node_id) catch failHost();
    defer callHostValueToUnitWithCapability(state_cap, hv.hostValueCapabilityDrop(state_cap), current);
    const read = currentStateValue(desc.read_node_id);
    const read_cap = shared_engine.stateCapability(desc.read_node_id) catch failHost();
    defer callHostValueToUnitWithCapability(read_cap, hv.hostValueCapabilityDrop(read_cap), read);
    const next = callHostValueHostValueHostValueToHostValueWithCapabilities(state_cap, read_cap, payload_cap, desc.payload_reducer.transform, current, read, payload);
    if (!updateStateCell(desc.target_node_id, next)) return;

    const dirty_source_node_ids = [_]u64{desc.target_node_id};
    const dirty_generation = shared_engine.nextDirtySignalGeneration();

    const changed_record_ids = shared_engine.propagateDirtyActiveSignals(ctx, &roc_host, allocator(), &dirty_source_node_ids, dirty_generation);
    _ = shared_engine.applyDirtySignalBatch(ctx, &roc_host, &dirty_source_node_ids, changed_record_ids, dirty_generation);
}

fn resolveTask(request_id: u64, payload_text: []const u8, failed: bool) void {
    const previous_phase = roc_allocation_phase;
    defer roc_allocation_phase = previous_phase;
    const ctx = WasmCtx{};
    const pending_index = switch (shared_engine.classifyTaskResolution(request_id)) {
        .pending => shared_engine.pendingTaskIndexByRequestId(request_id).?,
        .superseded => {
            shared_engine.noteStaleTaskResolutionIgnored();
            return;
        },
        .unknown => failHostWith("task result had no matching pending request"),
    };
    var pending = shared_engine.removePendingTaskAt(pending_index);
    defer shared_engine.deinitPendingTask(ctx, &pending);

    const record = shared_engine.activeTaskRecordByToken(pending.task_token) orelse failHostWith("task result matched no active task source");
    const task_payload = switch (record.payload) {
        .task_source => |payload| payload,
        .ref, .const_value, .map, .map2, .combine, .interval_source, .location_source, .online_source, .visibility_source, .storage_source => unreachable,
    };
    if (record.token().? != pending.task_token) failHostWith("task result matched a pending request for a different task source");

    roc_allocation_phase = 10;
    const payload = hostValueStr(payload_text);
    setHostValueCapability(payload, task_payload.payload_cap);
    const payload_take_epoch = hostValueTakeEpoch();

    roc_allocation_phase = 20;
    const next = if (failed)
        callHostValueToHostValueWithCapability(task_payload.payload_cap, task_payload.failed, payload)
    else
        callHostValueToHostValueWithCapability(task_payload.payload_cap, task_payload.done, payload);
    assertHostValueTakenAfter(payload, payload_take_epoch);
    roc_allocation_phase = 30;
    _ = shared_engine.dispatchEffectSourceValue(ctx, &roc_host, record, next);
}

fn tickInterval(token: u64) void {
    const ctx = WasmCtx{};
    _ = shared_engine.tickIntervalSourceByRuntimeToken(ctx, &roc_host, token);
}

fn dispatchLocationChange(payload: []const u8) void {
    const ctx = WasmCtx{};
    setCurrentLocationPayload(payload);
    _ = shared_engine.dispatchCurrentLocationSources(ctx, &roc_host);
}

fn dispatchVisibilityChange(payload: []const u8) void {
    const ctx = WasmCtx{};
    setCurrentVisibilityPayload(payload);
    _ = shared_engine.dispatchCurrentVisibilitySources(ctx, &roc_host);
}

fn dispatchOnlineChange(payload: []const u8) void {
    const ctx = WasmCtx{};
    setCurrentOnlinePayload(payload);
    _ = shared_engine.dispatchCurrentOnlineSources(ctx, &roc_host);
}

/// Tear the engine's reactive runtime back down to a re-mountable empty state.
/// Runs before each mount and on unmount; the order mirrors the engine portion of
/// the native host's `HostEnv.deinit`.
fn clearActiveRuntime() void {
    const a = allocator();
    const ctx = WasmCtx{};
    shared_engine.roc_host = &roc_host;
    mount_prepared = false;

    shared_engine.clearActiveSignalRoutes(ctx);
    shared_engine.active_source_signal_routes.deinit(a);
    shared_engine.active_text_signal_routes.deinit(a);
    shared_engine.active_bool_signal_routes.deinit(a);
    shared_engine.active_change_signal_routes.deinit(a);
    shared_engine.active_structural_signal_routes.deinit(a);
    shared_engine.active_source_signal_routes = .empty;
    shared_engine.active_text_signal_routes = .empty;
    shared_engine.active_bool_signal_routes = .empty;
    shared_engine.active_change_signal_routes = .empty;
    shared_engine.active_structural_signal_routes = .empty;

    shared_engine.clearActiveSignalGraph(ctx);
    shared_engine.active_signal_graph.deinit(a);
    shared_engine.active_signal_graph = .empty;

    shared_engine.active_stream.deinit(a, ctx, &roc_host, &shared_engine.pending_roc_metrics);
    shared_engine.active_stream = .{};

    shared_engine.clearActiveEvents() catch failHost();
    shared_engine.active_events.deinit(a);
    shared_engine.active_events = .empty;

    shared_engine.clearPendingTasks(ctx);
    shared_engine.pending_tasks.deinit(a);
    shared_engine.pending_tasks = .empty;

    shared_engine.clearActiveIntervals(ctx);
    shared_engine.active_intervals.deinit(a);
    shared_engine.active_intervals = .empty;

    engine.deinitCleanupEvents(a, &shared_engine.cleanup_events);

    if (shared_engine.root_elem) |root| {
        root.decref(&roc_host);
        shared_engine.root_elem = null;
    }

    shared_engine.clearStates(WasmCtx{}) catch failHost();
    shared_engine.states.deinit(a);
    shared_engine.states = .empty;
    shared_engine.state_indexes_by_node_id.deinit(a);
    shared_engine.state_indexes_by_node_id = .empty;

    shared_engine.clearScopes(WasmCtx{}) catch failHost();
    shared_engine.scopes.deinit(a);
    shared_engine.scopes = .empty;

    shared_engine.node_identities.deinit(a);
    shared_engine.node_identities = .empty;
    shared_engine.dom_identities.deinit(a);
    shared_engine.dom_identities = .empty;
    shared_engine.active_node_identity_ids.deinit(a);
    shared_engine.active_node_identity_ids = .empty;
    shared_engine.active_dom_identity_ids.deinit(a);
    shared_engine.active_dom_identity_ids = .empty;

    shared_engine.deinitRenderCache(ctx);
    shared_engine.deinitScratch(ctx);

    if (shared_engine.host_values.hasLiveValues()) failHost();
    shared_engine.host_values.deinit(a);
    shared_engine.host_values = .{};
}

// --- Compiler-rt shim ---

// The Roc app's `key.hash` path (`Ui.each_str`) emits a 128-bit integer multiply.
// ReleaseSmall leaves it as an undefined `__multi3` symbol instead of bundling
// compiler-rt, so the app object imports `env.__multi3`. The host is linked into
// every app wasm, so defining it here resolves that reference at link time and
// keeps the final module self-contained (no `env` imports) — the JS runtime can
// keep instantiating with no import object.
//
// ABI matches compiler-rt's sret form `void __multi3(i128 *ret, i128 a, i128 b)`,
// which wasm32 lowers to `(i32, i64, i64, i64, i64) -> ()` with each i128 split
// little-endian into (low, high).
//
// The body computes the low 128 bits of a*b using only 64-bit limb arithmetic. A
// `u128 *% u128` here would lower straight back to a `__multi3` call and recurse
// forever, so the 64x64->128 product of the low words is done with the classic
// 32-bit-limb schoolbook multiply, and the two cross terms (a_low*b_high,
// a_high*b_low) contribute only their low 64 bits — the a_high*b_high term lands
// entirely above bit 128 and drops.
export fn __multi3(result: *align(8) u128, a_low: u64, a_high: u64, b_low: u64, b_high: u64) callconv(.c) void {
    const mask: u64 = 0xffff_ffff;
    const al = a_low & mask;
    const ah = a_low >> 32;
    const bl = b_low & mask;
    const bh = b_low >> 32;

    var t: u64 = al *% bl;
    const w0 = t & mask;
    var k: u64 = t >> 32;

    t = ah *% bl +% k;
    const w1 = t & mask;
    const w2 = t >> 32;

    t = al *% bh +% w1;
    k = t >> 32;

    const lo = (t << 32) +% w0;
    const hi = ah *% bh +% w2 +% k +% (a_low *% b_high) +% (a_high *% b_low);

    result.* = (@as(u128, hi) << 64) | @as(u128, lo);
}

// --- Allocation marshalling (roc_alloc and friends) ---

fn allocatedSizeForRocRequest(length: usize) usize {
    return if (length == 0) 1 else length;
}

fn findRocAllocationIndex(ptr: *anyopaque) ?usize {
    const ptr_addr = @intFromPtr(ptr);
    for (roc_allocations.items, 0..) |alloc, index| {
        const user_addr = @intFromPtr(alloc.user_ptr);
        const end_addr = user_addr + alloc.allocated_size;
        if (ptr_addr >= user_addr and ptr_addr < end_addr) return index;
    }
    return null;
}

fn findExactRocAllocationIndex(ptr: *anyopaque) ?usize {
    const ptr_addr = @intFromPtr(ptr);
    for (roc_allocations.items, 0..) |alloc, index| {
        if (ptr_addr == @intFromPtr(alloc.user_ptr)) return index;
    }
    return null;
}

fn removeRocAllocationAt(index: usize) RocAllocation {
    if (index >= roc_allocations.items.len) failHostWith("Roc allocation ledger index is out of bounds");
    return roc_allocations.swapRemove(index);
}

fn recordFreedRocAllocation(alloc: RocAllocation) void {
    recent_freed_roc_allocations[recent_freed_roc_allocation_next] = .{
        .user_ptr_addr = @intFromPtr(alloc.user_ptr),
        .requested_size = alloc.requested_size,
        .allocated_size = alloc.allocated_size,
        .alignment = alloc.alignment,
        .phase = roc_allocation_phase,
    };
    recent_freed_roc_allocation_next = (recent_freed_roc_allocation_next + 1) % recent_freed_roc_allocation_capacity;
    recent_freed_roc_allocation_len = @min(recent_freed_roc_allocation_len + 1, recent_freed_roc_allocation_capacity);
}

fn findRecentlyFreedRocAllocation(ptr: *anyopaque) ?FreedRocAllocation {
    const ptr_addr = @intFromPtr(ptr);
    for (recent_freed_roc_allocations[0..recent_freed_roc_allocation_len]) |alloc| {
        if (alloc.user_ptr_addr == ptr_addr) return alloc;
    }
    return null;
}

fn distanceBetweenAddresses(left: usize, right: usize) usize {
    return if (left >= right) left - right else right - left;
}

fn nearestLiveRocAllocation(ptr: *anyopaque) ?NearestRocAllocation {
    const ptr_addr = @intFromPtr(ptr);
    var nearest: ?NearestRocAllocation = null;
    for (roc_allocations.items) |alloc| {
        const user_ptr_addr = @intFromPtr(alloc.user_ptr);
        const distance = distanceBetweenAddresses(ptr_addr, user_ptr_addr);
        if (nearest == null or distance < nearest.?.distance) {
            nearest = .{
                .user_ptr_addr = user_ptr_addr,
                .allocated_size = alloc.allocated_size,
                .distance = distance,
            };
        }
    }
    return nearest;
}

fn nearestRecentlyFreedRocAllocation(ptr: *anyopaque) ?NearestRocAllocation {
    const ptr_addr = @intFromPtr(ptr);
    var nearest: ?NearestRocAllocation = null;
    for (recent_freed_roc_allocations[0..recent_freed_roc_allocation_len]) |alloc| {
        const distance = distanceBetweenAddresses(ptr_addr, alloc.user_ptr_addr);
        if (nearest == null or distance < nearest.?.distance) {
            nearest = .{
                .user_ptr_addr = alloc.user_ptr_addr,
                .allocated_size = alloc.allocated_size,
                .distance = distance,
            };
        }
    }
    return nearest;
}

fn failUnknownRocAllocation(comptime op: []const u8, ptr: *anyopaque, alignment_arg: usize) noreturn {
    const nearest_live = nearestLiveRocAllocation(ptr);
    const nearest_freed = nearestRecentlyFreedRocAllocation(ptr);
    if (nearest_live) |live| {
        if (nearest_freed) |freed| {
            failHostWithFmt(
                "{s} unknown ptr=0x{x} align={} live={} nearest_live=0x{x}/{} dist={} recent_freed={} nearest_freed=0x{x}/{} dist={}",
                .{ op, @intFromPtr(ptr), alignment_arg, roc_allocations.items.len, live.user_ptr_addr, live.allocated_size, live.distance, recent_freed_roc_allocation_len, freed.user_ptr_addr, freed.allocated_size, freed.distance },
            );
        }
        failHostWithFmt(
            "{s} unknown ptr=0x{x} align={} live={} nearest_live=0x{x}/{} dist={} recent_freed=0",
            .{ op, @intFromPtr(ptr), alignment_arg, roc_allocations.items.len, live.user_ptr_addr, live.allocated_size, live.distance },
        );
    }
    if (nearest_freed) |freed| {
        failHostWithFmt(
            "{s} unknown ptr=0x{x} align={} live=0 recent_freed={} nearest_freed=0x{x}/{} dist={}",
            .{ op, @intFromPtr(ptr), alignment_arg, recent_freed_roc_allocation_len, freed.user_ptr_addr, freed.allocated_size, freed.distance },
        );
    }
    failHostWithFmt(
        "{s} unknown ptr=0x{x} align={} live=0 recent_freed=0",
        .{ op, @intFromPtr(ptr), alignment_arg },
    );
}

fn recordRocAllocation(user_ptr: [*]u8, requested_size: usize, allocated_size: usize, alignment: std.mem.Alignment) bool {
    roc_allocations.append(allocator(), .{
        .user_ptr = user_ptr,
        .requested_size = requested_size,
        .allocated_size = allocated_size,
        .alignment = alignment,
        .phase = roc_allocation_phase,
    }) catch return false;
    return true;
}

fn allocRocMemory(length: usize, alignment_arg: usize) ?*anyopaque {
    const min_alignment = @max(alignment_arg, @sizeOf(usize));
    const alignment = alignmentFromBytes(min_alignment);
    const allocated_size = allocatedSizeForRocRequest(length);
    const user_ptr = std.heap.wasm_allocator.rawAlloc(allocated_size, alignment, @returnAddress()) orelse return null;
    if (!recordRocAllocation(user_ptr, length, allocated_size, alignment)) {
        std.heap.wasm_allocator.rawFree(user_ptr[0..allocated_size], alignment, @returnAddress());
        return null;
    }
    return @ptrCast(user_ptr);
}

fn freeRocAllocation(ptr: *anyopaque, alignment_arg: usize) RocAllocation {
    const min_alignment = @max(alignment_arg, @sizeOf(usize));
    const alignment = alignmentFromBytes(min_alignment);
    const index = findExactRocAllocationIndex(ptr) orelse {
        if (findRocAllocationIndex(ptr)) |interior_index| {
            const alloc = roc_allocations.items[interior_index];
            const base = @intFromPtr(alloc.user_ptr);
            const ptr_addr = @intFromPtr(ptr);
            failHostWithFmt("roc_dealloc received an interior pointer ptr=0x{x} align={} base=0x{x} offset={} requested_size={} allocated_size={} tracked_align={} current_phase={}", .{ ptr_addr, alignment_arg, base, ptr_addr - base, alloc.requested_size, alloc.allocated_size, alloc.alignment.toByteUnits(), roc_allocation_phase });
        }
        if (findRecentlyFreedRocAllocation(ptr)) |freed| {
            if (freed.alignment != alignment) {
                failHostWithFmt("roc_dealloc received an already freed pointer ptr=0x{x} align={} with tracked_align={} requested_size={} allocated_size={} freed_phase={} current_phase={}", .{ @intFromPtr(ptr), alignment_arg, freed.alignment.toByteUnits(), freed.requested_size, freed.allocated_size, freed.phase, roc_allocation_phase });
            }
            failHostWithFmt("roc_dealloc received a pointer that was already freed ptr=0x{x} align={} requested_size={} allocated_size={} freed_phase={} current_phase={}", .{ @intFromPtr(ptr), alignment_arg, freed.requested_size, freed.allocated_size, freed.phase, roc_allocation_phase });
        }
        failUnknownRocAllocation("roc_dealloc", ptr, alignment_arg);
    };
    if (roc_allocations.items[index].alignment != alignment) {
        failHostWithFmt("roc_dealloc alignment did not match the tracked allocation ptr=0x{x} align={} tracked_align={}", .{ @intFromPtr(ptr), alignment_arg, roc_allocations.items[index].alignment.toByteUnits() });
    }
    const alloc = removeRocAllocationAt(index);
    recordFreedRocAllocation(alloc);
    std.heap.wasm_allocator.rawFree(alloc.user_ptr[0..alloc.allocated_size], alloc.alignment, @returnAddress());
    return alloc;
}

export fn roc_alloc(length: usize, alignment: usize) callconv(.c) ?*anyopaque {
    if (host_poisoned) return null;
    return allocRocMemory(length, alignment);
}

export fn roc_ui_debug_live_allocation_count() callconv(.c) usize {
    return roc_allocations.items.len;
}

export fn roc_ui_debug_live_allocation_bytes() callconv(.c) usize {
    var bytes: usize = 0;
    for (roc_allocations.items) |alloc| bytes += alloc.requested_size;
    return bytes;
}

export fn roc_ui_debug_live_allocation_size(index: usize) callconv(.c) usize {
    if (index >= roc_allocations.items.len) return 0;
    return roc_allocations.items[index].requested_size;
}

export fn roc_ui_debug_live_allocation_phase(index: usize) callconv(.c) u32 {
    if (index >= roc_allocations.items.len) return 0;
    return roc_allocations.items[index].phase;
}

export fn roc_dealloc(ptr: *anyopaque, alignment: usize) callconv(.c) void {
    _ = freeRocAllocation(ptr, alignment);
}

export fn roc_realloc(ptr: *anyopaque, new_length: usize, alignment_arg: usize) callconv(.c) ?*anyopaque {
    const old_index = findExactRocAllocationIndex(ptr) orelse {
        if (findRocAllocationIndex(ptr)) |interior_index| {
            const alloc = roc_allocations.items[interior_index];
            const base = @intFromPtr(alloc.user_ptr);
            const ptr_addr = @intFromPtr(ptr);
            failHostWithFmt("roc_realloc received an interior pointer ptr=0x{x} align={} base=0x{x} offset={} requested_size={} allocated_size={} tracked_align={} current_phase={}", .{ ptr_addr, alignment_arg, base, ptr_addr - base, alloc.requested_size, alloc.allocated_size, alloc.alignment.toByteUnits(), roc_allocation_phase });
        }
        if (findRecentlyFreedRocAllocation(ptr)) |freed| {
            const min_alignment = @max(alignment_arg, @sizeOf(usize));
            const alignment = alignmentFromBytes(min_alignment);
            if (freed.alignment != alignment) {
                failHostWithFmt("roc_realloc received an already freed pointer ptr=0x{x} align={} with tracked_align={}", .{ @intFromPtr(ptr), alignment_arg, freed.alignment.toByteUnits() });
            }
            failHostWithFmt("roc_realloc received a pointer that was already freed ptr=0x{x} align={}", .{ @intFromPtr(ptr), alignment_arg });
        }
        failUnknownRocAllocation("roc_realloc", ptr, alignment_arg);
    };
    const old_alloc = roc_allocations.items[old_index];
    const min_alignment = @max(alignment_arg, @sizeOf(usize));
    const alignment = alignmentFromBytes(min_alignment);
    if (old_alloc.alignment != alignment) {
        failHostWithFmt("roc_realloc alignment did not match the tracked allocation ptr=0x{x} align={} tracked_align={}", .{ @intFromPtr(ptr), alignment_arg, old_alloc.alignment.toByteUnits() });
    }

    const new_allocation_ptr = allocRocMemory(new_length, alignment_arg) orelse return null;
    const new_allocation_user_ptr: [*]u8 = @ptrCast(new_allocation_ptr);
    const old_user_ptr: [*]const u8 = @ptrCast(ptr);
    const copy_size = @min(old_alloc.requested_size, new_length);
    @memcpy(new_allocation_user_ptr[0..copy_size], old_user_ptr[0..copy_size]);
    const freed = removeRocAllocationAt(old_index);
    recordFreedRocAllocation(freed);
    std.heap.wasm_allocator.rawFree(freed.user_ptr[0..freed.allocated_size], freed.alignment, @returnAddress());
    return @ptrCast(new_allocation_user_ptr);
}

// --- Command-buffer wire surface (drained by the JS executor) ---

export fn roc_ui_protocol_version() callconv(.c) u32 {
    return render.protocol_version;
}

export fn roc_ui_protocol_features() callconv(.c) u32 {
    return render.protocol_features;
}

export fn roc_ui_command_buffer_ptr() callconv(.c) usize {
    return command_batch.published.commands.ptrAddress();
}

export fn roc_ui_command_buffer_len() callconv(.c) usize {
    return command_batch.published.commands.len();
}

export fn roc_ui_string_buffer_ptr() callconv(.c) usize {
    if (command_batch.published.strings.items.len == 0) return 0;
    return @intFromPtr(command_batch.published.strings.items.ptr);
}

export fn roc_ui_string_buffer_len() callconv(.c) usize {
    return command_batch.published.strings.items.len;
}

export fn roc_ui_dynamic_buffer_ptr() callconv(.c) usize {
    return command_batch.published.dynamic.ptrAddress();
}

export fn roc_ui_dynamic_buffer_len() callconv(.c) usize {
    return command_batch.published.dynamic.len();
}

export fn roc_ui_command_record_words() callconv(.c) usize {
    return render.Record.word_count;
}

export fn roc_ui_command_buffer_clear() callconv(.c) void {
    clearCommandBuffers();
}

export fn roc_ui_last_error_ptr() callconv(.c) usize {
    return @intFromPtr(last_host_error.ptr);
}

export fn roc_ui_last_error_len() callconv(.c) usize {
    return last_host_error.len;
}

export fn roc_ui_is_poisoned() callconv(.c) u32 {
    return @intFromBool(host_poisoned);
}

/// Number of retained host values currently live in the registry.
///
/// The browser leak guard asserts this returns to zero after `roc_ui_unmount`,
/// proving the host drops every retained closure/value it stored while mounted.
export fn roc_ui_live_host_values() callconv(.c) usize {
    return shared_engine.host_values.liveCount();
}

export fn roc_ui_prepare_mount() callconv(.c) void {
    beginHostCall();
    prepareMountRoot();
}

export fn roc_ui_storage_declaration_count() callconv(.c) usize {
    return storage_declarations.items.len;
}

export fn roc_ui_storage_declaration_area(index: usize) callconv(.c) u32 {
    if (index >= storage_declarations.items.len) failHostWith("storage declaration index out of bounds");
    return @intCast(@intFromEnum(storage_declarations.items[index].area));
}

export fn roc_ui_storage_declaration_key_ptr(index: usize) callconv(.c) usize {
    if (index >= storage_declarations.items.len) failHostWith("storage declaration index out of bounds");
    const key = storage_declarations.items[index].key;
    if (key.len == 0) return 0;
    return @intFromPtr(key.ptr);
}

export fn roc_ui_storage_declaration_key_len(index: usize) callconv(.c) usize {
    if (index >= storage_declarations.items.len) failHostWith("storage declaration index out of bounds");
    return storage_declarations.items[index].key.len;
}

export fn roc_ui_set_storage_payload(area_id: u32, key_ptr: usize, key_len: usize, payload_ptr: usize, payload_len: usize) callconv(.c) void {
    beginHostCall();
    const area = boundary.StorageArea.fromId(area_id) orelse failHostWith("storage payload used an unknown storage area");
    const key = (@as([*]const u8, @ptrFromInt(key_ptr)))[0..key_len];
    const payload = (@as([*]const u8, @ptrFromInt(payload_ptr)))[0..payload_len];
    setInitialStoragePayload(area, key, payload);
}

export fn roc_ui_mount() callconv(.c) void {
    beginHostCall();
    beginCommandTransaction();
    if (!mount_prepared) {
        clearActiveRuntime();
        clearStorageEnvironment();
        initRootElem();
    } else {
        mount_prepared = false;
    }

    renderActiveRoot(&.{});
    clearStorageDeclarations();
    commitCommandTransaction();
}

export fn roc_ui_set_location(payload_ptr: usize, payload_len: usize) callconv(.c) void {
    beginHostCall();
    setInitialLocationPayload((@as([*]const u8, @ptrFromInt(payload_ptr)))[0..payload_len]);
}

export fn roc_ui_update_location(payload_ptr: usize, payload_len: usize) callconv(.c) void {
    beginHostCall();
    beginCommandTransaction();
    dispatchLocationChange((@as([*]const u8, @ptrFromInt(payload_ptr)))[0..payload_len]);
    commitCommandTransaction();
}

export fn roc_ui_set_visibility(payload_ptr: usize, payload_len: usize) callconv(.c) void {
    beginHostCall();
    setInitialVisibilityPayload((@as([*]const u8, @ptrFromInt(payload_ptr)))[0..payload_len]);
}

export fn roc_ui_update_visibility(payload_ptr: usize, payload_len: usize) callconv(.c) void {
    beginHostCall();
    beginCommandTransaction();
    dispatchVisibilityChange((@as([*]const u8, @ptrFromInt(payload_ptr)))[0..payload_len]);
    commitCommandTransaction();
}

export fn roc_ui_set_online(payload_ptr: usize, payload_len: usize) callconv(.c) void {
    beginHostCall();
    setInitialOnlinePayload((@as([*]const u8, @ptrFromInt(payload_ptr)))[0..payload_len]);
}

export fn roc_ui_update_online(payload_ptr: usize, payload_len: usize) callconv(.c) void {
    beginHostCall();
    beginCommandTransaction();
    dispatchOnlineChange((@as([*]const u8, @ptrFromInt(payload_ptr)))[0..payload_len]);
    commitCommandTransaction();
}

fn payloadKindFromWire(payload_kind: u32) BoundaryPayloadKind {
    return switch (payload_kind) {
        @intFromEnum(BoundaryPayloadKind.unit) => .unit,
        @intFromEnum(BoundaryPayloadKind.str) => .str,
        @intFromEnum(BoundaryPayloadKind.bool) => .bool,
        @intFromEnum(BoundaryPayloadKind.bytes) => .bytes,
        else => failHostWith("DOM event used an unknown payload kind"),
    };
}

export fn roc_ui_event(event_id: u32, payload_kind: u32, payload_ptr: usize, payload_len: usize, bool_value: u32) callconv(.c) u32 {
    beginHostCall();
    beginCommandTransaction();
    const desc = hostEventById(event_id);
    const actual_payload_kind = payloadKindFromWire(payload_kind);
    const expected_payload_kind = desc.payload_descriptor.payloadKind();
    if (actual_payload_kind != expected_payload_kind) {
        failHostWith("DOM event payload kind does not match Roc event descriptor");
    }
    const payload = switch (actual_payload_kind) {
        .unit => hostValueUnit(),
        .str => hostValueStr((@as([*]const u8, @ptrFromInt(payload_ptr)))[0..payload_len]),
        .bool => hostValueBool(bool_value != 0),
        .bytes => hostValueU8List((@as([*]const u8, @ptrFromInt(payload_ptr)))[0..payload_len]),
    };
    dispatchEvent(desc, payload);
    commitCommandTransaction();
    return 0;
}

export fn roc_ui_timer(token: u32) callconv(.c) void {
    beginHostCall();
    beginCommandTransaction();
    tickInterval(token);
    commitCommandTransaction();
}

export fn roc_ui_resolve(request_id: u32, payload_ptr: usize, payload_len: usize, failed: u32) callconv(.c) void {
    beginHostCall();
    beginCommandTransaction();
    resolveTask(
        request_id,
        (@as([*]const u8, @ptrFromInt(payload_ptr)))[0..payload_len],
        failed != 0,
    );
    commitCommandTransaction();
}

export fn roc_ui_unmount() callconv(.c) void {
    if (host_poisoned) {
        command_batch.abort();
        return;
    }
    beginHostCall();
    beginCommandTransaction();
    clearActiveRuntime();
    clearInitialLocationPayload();
    clearInitialVisibilityPayload();
    clearInitialOnlinePayload();
    clearStorageEnvironment();
    commitCommandTransaction();
}

export fn roc_dbg(_: [*]const u8, _: usize) callconv(.c) void {}

export fn roc_expect_failed(_: [*]const u8, _: usize) callconv(.c) void {}

export fn roc_crashed(ptr: [*]const u8, len: usize) callconv(.c) void {
    failHostWithFmt("Roc crashed: {s}", .{ptr[0..len]});
}

fn rocAllocForAbi(_: *abi.RocHost, length: usize, alignment: usize) callconv(.c) ?*anyopaque {
    return roc_alloc(length, alignment);
}

fn rocDeallocForAbi(_: *abi.RocHost, ptr: *anyopaque, alignment: usize) callconv(.c) void {
    roc_dealloc(ptr, alignment);
}

fn rocReallocForAbi(_: *abi.RocHost, ptr: *anyopaque, new_length: usize, alignment: usize) callconv(.c) ?*anyopaque {
    return roc_realloc(ptr, new_length, alignment);
}

fn rocDbgForAbi(_: *abi.RocHost, bytes: [*]const u8, len: usize) callconv(.c) void {
    roc_dbg(bytes, len);
}

fn rocExpectFailedForAbi(_: *abi.RocHost, bytes: [*]const u8, len: usize) callconv(.c) void {
    roc_expect_failed(bytes, len);
}

fn rocCrashedForAbi(_: *abi.RocHost, bytes: [*]const u8, len: usize) callconv(.c) void {
    roc_crashed(bytes, len);
}

export fn roc_host_value_clone(value: HostValue) callconv(.c) HostValue {
    const previous_phase = roc_allocation_phase;
    roc_allocation_phase = 101;
    defer roc_allocation_phase = previous_phase;
    return shared_engine.host_values.clone(std.heap.wasm_allocator, value, registryOps()) catch |err| {
        failHostValueRegistryError(err);
    };
}

export fn roc_host_value_get_with_capability(value: HostValue, cap: HostValueCapability) callconv(.c) abi.RocBox {
    const previous_phase = roc_allocation_phase;
    roc_allocation_phase = 108;
    defer roc_allocation_phase = previous_phase;
    defer hv.releaseHostValueCapability(cap, &roc_host);
    return shared_engine.host_values.getWithCapability(std.heap.wasm_allocator, value, cap, registryOps()) catch |err| {
        failHostValueRegistryError(err);
    };
}

export fn roc_host_value_get_with_split(value: HostValue, split: abi.RocErasedCallable) callconv(.c) abi.RocBox {
    const previous_phase = roc_allocation_phase;
    roc_allocation_phase = 103;
    defer roc_allocation_phase = previous_phase;
    defer abi.decrefErasedCallable(split, &roc_host);
    return shared_engine.host_values.getWithSplit(value, split, registryOps()) catch |err| {
        failHostValueRegistryError(err);
    };
}

export fn roc_host_value_store_with_capability(box: abi.RocBox, cap: HostValueCapability) callconv(.c) HostValue {
    const previous_phase = roc_allocation_phase;
    roc_allocation_phase = 109;
    defer roc_allocation_phase = previous_phase;
    return shared_engine.host_values.storeOwnedCapability(std.heap.wasm_allocator, box, cap, registryOps()) catch |err| {
        failHostValueRegistryError(err);
    };
}

export fn roc_host_value_store_with_existing_capability(box: abi.RocBox, source_value: HostValue) callconv(.c) HostValue {
    const previous_phase = roc_allocation_phase;
    roc_allocation_phase = 109;
    defer roc_allocation_phase = previous_phase;
    return shared_engine.host_values.storeRetainedExistingCapability(std.heap.wasm_allocator, box, source_value, registryOps()) catch |err| {
        failHostValueRegistryError(err);
    };
}

export fn roc_host_value_take_with_capability(value: HostValue, cap: HostValueCapability) callconv(.c) abi.RocBox {
    const previous_phase = roc_allocation_phase;
    roc_allocation_phase = 110;
    defer roc_allocation_phase = previous_phase;
    defer hv.releaseHostValueCapability(cap, &roc_host);
    return shared_engine.host_values.takeWithCapability(value, cap, registryOps()) catch |err| {
        failHostValueRegistryError(err);
    };
}

export fn roc_host_value_take_with_split(value: HostValue, split: abi.RocErasedCallable) callconv(.c) abi.RocBox {
    const previous_phase = roc_allocation_phase;
    roc_allocation_phase = 107;
    defer roc_allocation_phase = previous_phase;
    defer abi.decrefErasedCallable(split, &roc_host);
    return shared_engine.host_values.takeWithSplit(value, split, registryOps()) catch |err| {
        failHostValueRegistryError(err);
    };
}

comptime {
    if (@TypeOf(&roc_host_value_get_with_split) != @TypeOf(&abi.roc_host_value_get_with_split)) {
        @compileError("roc_host_value_get_with_split does not match the generated platform ABI");
    }
    if (@TypeOf(&roc_host_value_take_with_split) != @TypeOf(&abi.roc_host_value_take_with_split)) {
        @compileError("roc_host_value_take_with_split does not match the generated platform ABI");
    }
}
