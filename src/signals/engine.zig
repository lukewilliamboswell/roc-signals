//! Shared reactive-engine internals for the Signals hosts.
//!
//! This module is the home for the host-agnostic reactive engine that
//! `native_host.zig` and `wasm_host.zig` will both drive (see the G-B0 plan).
//! It starts with the retained "HostValue / thunk / scope" adapter: the value
//! cell that owns a boxed Roc value plus its equality/drop thunks, and the
//! each-row scope step that carries those cells through the scope forest.
//!
//! Host-specific concerns stay out: methods take the active `*abi.RocHost`
//! explicitly, the metrics sink is a duck-typed `anytype` (so a host can pass a
//! real `RuntimeMetrics` or a zero-size `NoMetrics`), and cloning a HostValue is
//! delegated to a `ctx` the host supplies (`ctx.cloneHostValue`).

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("roc_platform_abi.zig");
const abi_view = @import("abi_view.zig");
const boundary = @import("boundary.zig");
const scope_tree = @import("scope_tree.zig");
const erased_calls = @import("erased_calls.zig");
const render = @import("render_commands.zig");
const identity_table = @import("identity_table.zig");
const host_value_registry = @import("host_value_registry.zig");
const hv = @import("host_values.zig");
const engine_metrics = @import("engine_metrics.zig");
const engine_contract = @import("engine_contract.zig");
const render_sink = @import("render_sink.zig");
const render_cache_mod = @import("render_cache.zig");
const descriptor_stream = @import("descriptor_stream.zig");
const retained_values = @import("retained_values.zig");
const signal_records = @import("signal_records.zig");
const active_graph = @import("active_signal_graph.zig");
const scope_runtime = @import("scope_runtime.zig");
const each_runtime = @import("each_runtime.zig");
const effects_runtime = @import("effects_runtime.zig");
const collection_budget = @import("collection_budget.zig");
const collection_plan = @import("collection_plan.zig");
const structural_splice = @import("structural_splice.zig");
const engine_scratch = @import("engine_scratch.zig");
const DebugPhase = @import("debug_phase.zig").Phase;

const enable_runtime_metrics = engine_metrics.enable_runtime_metrics;

pub const RenderTextField = render.TextField;
pub const RenderBoolField = render.BoolField;
pub const RenderEventKind = render.EventKind;
pub const NavigationKind = render_sink.NavigationKind;
pub const EventPayloadKind = boundary.PayloadKind;
pub const EventExtractionPlanKind = boundary.EventExtractionPlanKind;
pub const BoundaryPayloadDescriptor = boundary.BoundaryPayloadDescriptor;
pub const NodeFieldCustom: u64 = abi_view.node_text_field_custom;

pub const HostValue = retained_values.HostValue;
pub const HostValueList = abi.RocListWith(HostValue, false);
pub const RuntimeMetrics = engine_metrics.RuntimeMetrics;
pub const NoMetrics = engine_metrics.NoMetrics;
pub const DispatchMetrics = engine_metrics.DispatchMetrics;
pub const zeroRuntimeMetrics = engine_metrics.zeroRuntimeMetrics;
pub const addRuntimeMetrics = engine_metrics.addRuntimeMetrics;
pub const verifyRegistryOps = engine_contract.verifyRegistryOps;
pub const verifySink = engine_contract.verifySink;
pub const verifyMetrics = engine_contract.verifyMetrics;
pub const verifyCtx = engine_contract.verifyCtx;
pub const HostNodeScopeSiteKind = descriptor_stream.ScopeSiteKind;
pub const HostTextFieldDescriptorIndexes = descriptor_stream.TextFieldDescriptorIndexes;
pub const HostBoolFieldDescriptorIndexes = descriptor_stream.BoolFieldDescriptorIndexes;
pub const HostEventDescriptorIndexes = descriptor_stream.EventDescriptorIndexes;
pub const HostRenderElemIndex = descriptor_stream.RenderElemIndex;
pub const HostRenderChildInsertHint = descriptor_stream.RenderChildInsertHint;
pub const HostElemDescriptorIndex = descriptor_stream.ElemDescriptorIndex;
pub const HostScopeSiteDescriptorIndexes = descriptor_stream.ScopeSiteDescriptorIndexes;
pub const HostNodeDescriptorIndex = descriptor_stream.NodeDescriptorIndex;
pub const HostRenderNodeKind = descriptor_stream.RenderNodeKind;
pub const HostRenderNode = descriptor_stream.RenderNode;
pub const HostElementDesc = descriptor_stream.ElementDesc;
pub const HostNodeTextNodeDesc = descriptor_stream.TextNodeDesc;
pub const HostNodeStaticTextAttrDesc = descriptor_stream.StaticTextAttrDesc;
pub const HostNodeStaticCustomTextAttrDesc = descriptor_stream.StaticCustomTextAttrDesc;
pub const HostNodeStaticCustomBoolAttrDesc = descriptor_stream.StaticCustomBoolAttrDesc;
pub const HostNodeStaticBoolAttrDesc = descriptor_stream.StaticBoolAttrDesc;
pub const HostNodeScopeSiteDesc = descriptor_stream.ScopeSiteDesc;
pub const HostNodeSignalTextNodeDesc = descriptor_stream.SignalTextNodeDesc;
pub const HostNodeSignalTextAttrDesc = descriptor_stream.SignalTextAttrDesc;
pub const HostNodeSignalCustomTextAttrDesc = descriptor_stream.SignalCustomTextAttrDesc;
pub const HostNodeSignalOptionalCustomTextAttrDesc = descriptor_stream.SignalOptionalCustomTextAttrDesc;
pub const HostNodeSignalCustomBoolAttrDesc = descriptor_stream.SignalCustomBoolAttrDesc;
pub const HostNodeSignalBoolAttrDesc = descriptor_stream.SignalBoolAttrDesc;
pub const HostNodeOnChangeDesc = descriptor_stream.OnChangeDesc;
pub const HostNodeEventDesc = descriptor_stream.EventDesc;
pub const HostNodeStateDesc = descriptor_stream.StateDesc;
pub const HostNodeWhenDesc = descriptor_stream.WhenDesc;
pub const HostNodeEachDesc = descriptor_stream.EachDesc;
pub const HostNodeMountDesc = descriptor_stream.MountDesc;
pub const HostNodeCleanupDesc = descriptor_stream.CleanupDesc;
pub const HostValueCapability = retained_values.HostValueCapability;
pub const HostTextRead = retained_values.HostTextRead;
pub const HostBoolRead = retained_values.HostBoolRead;
pub const HostEventReducer = retained_values.HostEventReducer;
pub const HostTaskRequestRead = retained_values.HostTaskRequestRead;
pub const HostEachOps = retained_values.HostEachOps;
pub const HostSignalToken = retained_values.HostSignalToken;
pub const HostValueCell = retained_values.HostValueCell;
pub const retainHostCallable = retained_values.retainHostCallable;
const retainHostValueCapability = retained_values.retainHostValueCapability;
const releaseHostValueCapability = retained_values.releaseHostValueCapability;
const assertHostValueCapabilitiesMatch = retained_values.assertHostValueCapabilitiesMatch;
const retainHostTextRead = retained_values.retainHostTextRead;
const releaseHostTextRead = retained_values.releaseHostTextRead;
const retainHostBoolRead = retained_values.retainHostBoolRead;
const releaseHostBoolRead = retained_values.releaseHostBoolRead;
const retainHostEventReducer = retained_values.retainHostEventReducer;
const releaseHostEventReducer = retained_values.releaseHostEventReducer;
const retainHostEachOps = retained_values.retainHostEachOps;
const releaseHostEachOps = retained_values.releaseHostEachOps;
pub const HostSignalCacheSlot = signal_records.CacheSlot;
pub const HostSignalEvalResult = signal_records.EvalResult;
pub const HostSignalConstRecord = signal_records.ConstRecord;
pub const HostSignalMapRecord = signal_records.MapRecord;
pub const HostSignalMap2Record = signal_records.Map2Record;
pub const HostSignalCombineRecord = signal_records.CombineRecord;
pub const HostSignalTaskSourceRecord = signal_records.TaskSourceRecord;
pub const HostSignalIntervalSourceRecord = signal_records.IntervalSourceRecord;
pub const HostSignalLocationSourceRecord = signal_records.LocationSourceRecord;
pub const HostSignalOnlineSourceRecord = signal_records.OnlineSourceRecord;
pub const HostSignalVisibilitySourceRecord = signal_records.VisibilitySourceRecord;
pub const HostSignalStorageSourceRecord = signal_records.StorageSourceRecord;
pub const HostSignalRecordPayload = signal_records.Payload;
pub const HostSignalRecord = signal_records.Record;
pub const HostSignalBinding = signal_records.Binding;
pub const validateExistingSignalRecord = signal_records.validateExistingSignalRecord;

const HostPendingOnChangeCommand = struct {
    scope_id: u64,
    cmd: erased_calls.Cmd,
};

const HostDeferredStorageEffect = struct {
    area: boundary.StorageArea,
    key: []u8,
};

pub const TaskResolutionClass = enum {
    pending,
    superseded,
    unknown,
};

/// Formats each duplicate key diagnostic into caller-provided bounded diagnostic storage.
pub fn formatEachDuplicateKeyDiagnostic(
    buffer: []u8,
    parent_scope_id: u64,
    site_ordinal: u64,
    first_index: usize,
    second_index: usize,
    key_text: []const u8,
) []const u8 {
    const max_key_len = 160;
    const displayed_key_len = utf8PrefixLenAtMost(key_text, max_key_len);
    const displayed_key = key_text[0..displayed_key_len];
    const suffix = if (displayed_key_len < key_text.len) "..." else "";
    return std.fmt.bufPrint(
        buffer,
        "Ui.each_str duplicate key \"{s}{s}\": rows {d} and {d} share this key (each site: parent scope {d}, ordinal {d}); keys must be unique per list",
        .{
            displayed_key,
            suffix,
            first_index + 1,
            second_index + 1,
            parent_scope_id,
            site_ordinal,
        },
    ) catch "Ui.each_str duplicate key: keys must be unique per list";
}

fn utf8PrefixLenAtMost(bytes: []const u8, max_len: usize) usize {
    if (bytes.len <= max_len) return bytes.len;
    var end = max_len;
    while (end > 0 and (bytes[end] & 0b1100_0000) == 0b1000_0000) {
        end -= 1;
    }
    return end;
}

test "formats each duplicate key diagnostics" {
    var buf: [512]u8 = undefined;
    const msg = formatEachDuplicateKeyDiagnostic(&buf, 12, 3, 2, 6, "alert-42");
    try std.testing.expectEqualStrings(
        "Ui.each_str duplicate key \"alert-42\": rows 3 and 7 share this key (each site: parent scope 12, ordinal 3); keys must be unique per list",
        msg,
    );
}

test "duplicate key diagnostics truncate at utf8 boundary" {
    var key: [162]u8 = undefined;
    @memset(key[0..159], 'a');
    key[159] = 0xc3;
    key[160] = 0xa9;
    key[161] = 'x';

    var buf: [512]u8 = undefined;
    const msg = formatEachDuplicateKeyDiagnostic(&buf, 12, 3, 0, 1, key[0..]);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\xc3") == null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "...") != null);
}
pub const appendSignalRecordSourceNodeIds = signal_records.appendSignalRecordSourceNodeIds;
pub const appendSignalRecordSourceNodeIdsFallible = signal_records.appendSignalRecordSourceNodeIdsFallible;

const render_event_kinds = [_]RenderEventKind{ .click, .input, .check, .pointer_down, .pointer_up, .pointer_enter, .pointer_leave };

fn firstEventDescriptorElemOutsideSeen(stream: *const HostNodeDescriptorStream, seen: []const bool) ?u64 {
    for (stream.events.items) |desc| {
        if (desc.elem_id >= seen.len or !seen[@intCast(desc.elem_id)]) return desc.elem_id;
    }
    return null;
}

fn u64SliceContains(items: []const u64, target: u64) bool {
    for (items) |item| {
        if (item == target) return true;
    }
    return false;
}

fn identityCanAppend(last: anytype, scope_id: u64, ordinal: u64) bool {
    if (!last.active) return false;
    return scope_id > last.scope_id or (scope_id == last.scope_id and ordinal > last.ordinal);
}

fn identityKey(scope_id: u64, ordinal: u64) u128 {
    return (@as(u128, scope_id) << 64) | ordinal;
}

fn structuralSpliceParentAvailable(parent_elem_id: u64, parent_active: bool, replacement_elem_ids: []const u64, removed_elem_ids: []const u64) bool {
    if (parent_elem_id == 0) return true;
    if (u64SliceContains(replacement_elem_ids, parent_elem_id)) return true;
    if (u64SliceContains(removed_elem_ids, parent_elem_id)) return false;
    return parent_active;
}

test "spliced structural parents may be active outside replacement range" {
    const replacement = [_]u64{ 43, 44, 45 };
    const removed = [_]u64{ 43, 44, 45 };

    try std.testing.expect(structuralSpliceParentAvailable(0, false, &replacement, &removed));
    try std.testing.expect(structuralSpliceParentAvailable(71, true, &replacement, &removed));
    try std.testing.expect(!structuralSpliceParentAvailable(71, false, &replacement, &removed));
    try std.testing.expect(structuralSpliceParentAvailable(43, false, &replacement, &removed));
    try std.testing.expect(!structuralSpliceParentAvailable(44, true, &.{}, &removed));
}

/// Appends unique u64 using capacity that must already satisfy the caller's transaction contract.
pub fn appendUniqueU64(allocator: std.mem.Allocator, values: *std.ArrayListUnmanaged(u64), value: u64) void {
    if (u64SliceContains(values.items, value)) return;
    values.append(allocator, value) catch @panic("out of memory");
}

fn renderNodeSliceContainsElem(items: []const HostRenderNode, elem_id: u64) bool {
    for (items) |item| {
        if (item.elem_id == elem_id) return true;
    }
    return false;
}

pub const HostEachRowScopeStep = scope_runtime.EachRowScopeStep;
pub const HostScopeStep = scope_runtime.ScopeStep;
pub const HostScope = scope_runtime.Scope;
pub const deinitHostScopeStep = scope_runtime.deinitScopeStep;

fn hashEachKeyText(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0, bytes);
}

const HostEachRowSiteIndexMap = each_runtime.SiteIndexMap;
const HostEachRowMembership = each_runtime.Membership;
const HostEachRowSite = each_runtime.Site;

// Descriptor layer
//
// The host's ingested view of the Roc `Elem` tree: one descriptor per element,
// text node, attribute, event binding, scope site, state, when, and each.
// Markup carries no identity of its own; dynamic descriptors reference shared
// signal records and event reducers by retained thunk.

pub const SignalKind = active_graph.SignalKind;

pub const HostEventDescriptor = active_graph.EventDescriptor;

pub const HostActiveEventDesc = struct {
    target_node_id: u64,
    read_node_id: u64,
    payload_descriptor: BoundaryPayloadDescriptor,
    payload_reducer: HostEventReducer,
};

pub const HostPendingTask = effects_runtime.PendingTask;
pub const HostActiveInterval = effects_runtime.ActiveInterval;
pub const HostCleanupEvents = effects_runtime.CleanupEvents;
pub const deinitCleanupEvents = effects_runtime.deinitCleanupEvents;

pub const HostSignalEventRoute = active_graph.EventRoute;

pub const HostState = struct {
    state_id: u64,
    cell: HostValueCell,
    version: u64,
    active: bool,
};

pub const HostSignalDescriptor = active_graph.Descriptor;

pub const HostSignalRoute = active_graph.StateRoute;

pub const HostSignalDependentsRoute = active_graph.DependentsRoute;

pub const HostActiveSignalGraphNode = active_graph.Node(HostSignalRecord);
pub const HostNodeIdentity = identity_table.NodeIdentity;
pub const HostDomIdentity = identity_table.DomIdentity;
pub const HostScopeBranch = scope_tree.Branch;

pub const HostActiveTextSignalSinkKind = active_graph.TextSinkKind;
pub const HostActiveTextSignalSink = active_graph.TextSink;
pub const HostActiveBoolSignalSinkKind = active_graph.BoolSinkKind;
pub const HostActiveBoolSignalSink = active_graph.BoolSink;
pub const HostActiveChangeSignalSink = active_graph.ChangeSink;
pub const HostActiveStructuralSignalKind = active_graph.StructuralKind;
pub const HostActiveStructuralSignal = active_graph.StructuralSink;
pub const HostDirtyStructuralSignal = struct {
    kind: HostActiveStructuralSignalKind,
    node_id: u64,
    scope_id: u64,
    ordinal: u64,
    record: *HostSignalRecord,
    branch: ?HostScopeBranch = null,
    pending_when_cache: ?HostValueCell = null,

    /// Drops a provisional dirty value without changing the live cache.
    pub fn abortPendingWhenCache(self: *@This(), ctx: anytype, roc_host: *abi.RocHost, metrics: anytype) void {
        if (self.pending_when_cache) |*cell| cell.deinit(ctx, roc_host, metrics);
        self.pending_when_cache = null;
    }

    /// Transfers the provisional dirty value into the live cache.
    pub fn commitPendingWhenCache(self: *@This(), slot: *HostSignalCacheSlot, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype) void {
        const cell = self.pending_when_cache orelse @panic("dirty when change lacked pending cache value");
        slot.deinit(ctx, roc_host, metrics);
        slot.* = .{ .present = cell };
        self.pending_when_cache = null;
    }
};

pub const HostEachSite = scope_runtime.EachSite;
pub const HostStructuralReplacementTarget = structural_splice.ReplacementTarget;
pub const HostStructuralPatchTargets = structural_splice.PatchTargets;
pub const HostStructuralSplice = structural_splice.Splice;
pub const HostStructuralSpliceAndTargets = structural_splice.SpliceAndTargets;

pub const RecomputeApplyOutcome = struct {
    structural_render_required: bool,
};

pub const HostKeyedRowDiffResult = each_runtime.DiffResult;

/// The retained key/item pair read back out of a `Ui.each_str` row scope. Named
/// so the native forwarder and the engine method share one type instead of each
/// declaring a distinct anonymous struct.
pub const EachRowValues = scope_runtime.EachRowValues;

pub const HostEachRowRenderSegment = each_runtime.RenderSegment;
pub const HostEachRowRenderMove = each_runtime.RenderMove;

pub const HostRequiredEventBinding = render_cache_mod.EventBinding;

pub const HostBinderToken = descriptor_stream.BinderToken;
pub const HostBinderBinding = descriptor_stream.BinderBinding;

const EngineScratch = engine_scratch.Scratch;

// Descriptor stream
//
// The retained stream of node descriptors plus the per-elem index that makes
// descriptor lookup O(1). Its append* methods ingest the Roc Elem tree; the
// host drives ingestion and consumes the stream to render.

pub const HostNodeDescriptorStream = descriptor_stream.Stream;

// Host-agnostic readers over a descriptor stream. These operate purely on the
// stream's descriptor tables and panic on internal invariant violations, so they
// are shared by both hosts and by the engine's structural apply path.

/// Resolves element desc from maintained indexes without scanning the full descriptor stream.
pub fn findElementDesc(stream: *const HostNodeDescriptorStream, elem_id: u64) ?HostElementDesc {
    return descriptor_stream.findElementDesc(HostNodeDescriptorStream, stream, elem_id);
}

/// Resolves text node desc from maintained indexes without scanning the full descriptor stream.
pub fn findTextNodeDesc(stream: *const HostNodeDescriptorStream, elem_id: u64) ?HostNodeTextNodeDesc {
    return descriptor_stream.findTextNodeDesc(HostNodeDescriptorStream, stream, elem_id);
}

/// Resolves signal text node desc from maintained indexes without scanning the full descriptor stream.
pub fn findSignalTextNodeDesc(stream: *const HostNodeDescriptorStream, elem_id: u64) ?HostNodeSignalTextNodeDesc {
    return descriptor_stream.findSignalTextNodeDesc(HostNodeDescriptorStream, stream, elem_id);
}

/// Resolves signal text node desc mutable from maintained indexes without scanning the full descriptor stream.
pub fn findSignalTextNodeDescMutable(stream: *HostNodeDescriptorStream, elem_id: u64) ?*HostNodeSignalTextNodeDesc {
    return descriptor_stream.findSignalTextNodeDescMutable(HostNodeDescriptorStream, stream, elem_id);
}

/// Reports whether the selected element has text field in the active descriptor stream.
pub fn streamHasTextField(stream: *const HostNodeDescriptorStream, elem_id: u64, field: RenderTextField) bool {
    return descriptor_stream.streamHasTextField(HostNodeDescriptorStream, stream, elem_id, field);
}

/// Reports whether the selected element has custom text attr in the active descriptor stream.
pub fn streamHasCustomTextAttr(stream: *const HostNodeDescriptorStream, elem_id: u64, name: []const u8) bool {
    return descriptor_stream.streamHasCustomTextAttr(HostNodeDescriptorStream, stream, elem_id, name);
}

/// Reports whether the selected element has bool field in the active descriptor stream.
pub fn streamHasBoolField(stream: *const HostNodeDescriptorStream, elem_id: u64, field: RenderBoolField) bool {
    return descriptor_stream.streamHasBoolField(HostNodeDescriptorStream, stream, elem_id, field);
}

/// Performs max render elem id inside the shared engine while preserving transaction and changed-set invariants.
pub fn maxRenderElemId(stream: *const HostNodeDescriptorStream) u64 {
    return descriptor_stream.maxRenderElemId(HostNodeDescriptorStream, stream);
}

/// Returns tag for an already indexed render node.
pub fn renderNodeTag(stream: *const HostNodeDescriptorStream, node: HostRenderNode) []const u8 {
    return descriptor_stream.renderNodeTag(HostNodeDescriptorStream, stream, node);
}

/// Reads elem tag from the active descriptor stream using engine-owned identity.
pub fn streamElemTag(stream: *const HostNodeDescriptorStream, elem_id: u64) []const u8 {
    return descriptor_stream.streamElemTag(HostNodeDescriptorStream, stream, elem_id);
}

/// Returns parent elem id for an already indexed render node.
pub fn renderNodeParentElemId(stream: *const HostNodeDescriptorStream, node: HostRenderNode) u64 {
    return descriptor_stream.renderNodeParentElemId(HostNodeDescriptorStream, stream, node);
}

/// Reads elem parent elem id from the active descriptor stream using engine-owned identity.
pub fn streamElemParentElemId(stream: *const HostNodeDescriptorStream, elem_id: u64) u64 {
    return descriptor_stream.streamElemParentElemId(HostNodeDescriptorStream, stream, elem_id);
}

/// Reads direct children from the active descriptor stream using engine-owned identity.
pub fn streamDirectChildren(allocator: std.mem.Allocator, stream: *const HostNodeDescriptorStream, parent_elem_id: u64) []u64 {
    return descriptor_stream.streamDirectChildren(HostNodeDescriptorStream, allocator, stream, parent_elem_id);
}

/// Reads direct children into from the active descriptor stream using engine-owned identity.
pub fn streamDirectChildrenInto(allocator: std.mem.Allocator, stream: *const HostNodeDescriptorStream, parent_elem_id: u64, children: *std.ArrayListUnmanaged(u64)) []const u64 {
    return descriptor_stream.streamDirectChildrenInto(HostNodeDescriptorStream, allocator, stream, parent_elem_id, children);
}

/// Returns scope id for an already indexed render node.
pub fn renderNodeScopeId(stream: *const HostNodeDescriptorStream, node: HostRenderNode) u64 {
    return descriptor_stream.renderNodeScopeId(HostNodeDescriptorStream, stream, node);
}

/// Performs elem scope id inside the shared engine while preserving transaction and changed-set invariants.
pub fn elemScopeId(stream: *const HostNodeDescriptorStream, elem_id: u64) ?u64 {
    return descriptor_stream.elemScopeId(HostNodeDescriptorStream, stream, elem_id);
}

fn textFieldDescriptorIndexesActive(indexes: HostTextFieldDescriptorIndexes) bool {
    return indexes.text != .none or
        indexes.role != .none or
        indexes.label != .none or
        indexes.test_id != .none or
        indexes.value != .none or
        indexes.class != .none;
}

fn boolFieldDescriptorIndexesActive(indexes: HostBoolFieldDescriptorIndexes) bool {
    return indexes.checked != .none or indexes.disabled != .none;
}

fn eventDescriptorIndexesActive(indexes: HostEventDescriptorIndexes) bool {
    return indexes.click != .none or
        indexes.input != .none or
        indexes.check != .none or
        indexes.pointer_down != .none or
        indexes.pointer_up != .none or
        indexes.pointer_enter != .none or
        indexes.pointer_leave != .none;
}

fn elemDescriptorIndexActive(index: HostElemDescriptorIndex) bool {
    return index.element != .none or
        index.text_node != .none or
        index.signal_text_node != .none or
        textFieldDescriptorIndexesActive(index.static_text_attrs) or
        textFieldDescriptorIndexesActive(index.signal_text_attrs) or
        boolFieldDescriptorIndexesActive(index.static_bool_attrs) or
        boolFieldDescriptorIndexesActive(index.signal_bool_attrs) or
        eventDescriptorIndexesActive(index.events);
}

/// Performs adjusted render insert index inside the shared engine while preserving transaction and changed-set invariants.
pub fn adjustedRenderInsertIndex(old_index: usize, replace_index: usize, removed_count: usize, replacement_count: usize) usize {
    return descriptor_stream.adjustedRenderInsertIndex(old_index, replace_index, removed_count, replacement_count);
}

fn sourceNodeIdsIntersect(left: []const u64, right: []const u64) bool {
    for (left) |left_id| {
        for (right) |right_id| {
            if (left_id == right_id) return true;
        }
    }
    return false;
}

// Host-agnostic signal-record construction helpers (shared by both hosts).

/// Delivers node binder ref through the same source-update and propagation path as other inputs.
pub fn resolveNodeBinderRef(binder_stack: []const HostBinderBinding, token: HostBinderToken) u64 {
    var index = binder_stack.len;
    while (index > 0) {
        index -= 1;
        const binding = binder_stack[index];
        if (binding.token == token) return binding.node_id;
    }
    @panic("Node.BinderRef referenced a state binder outside the active scope");
}

/// Performs render text field from abi inside the shared engine while preserving transaction and changed-set invariants.
pub fn renderTextFieldFromAbi(field: u64) RenderTextField {
    return abi_view.textFieldFromAbi(field);
}

/// Performs render bool field from abi inside the shared engine while preserving transaction and changed-set invariants.
pub fn renderBoolFieldFromAbi(field: u64) RenderBoolField {
    return abi_view.boolFieldFromAbi(field);
}

/// Performs render event kind from abi inside the shared engine while preserving transaction and changed-set invariants.
pub fn renderEventKindFromAbi(kind: u64) RenderEventKind {
    return abi_view.eventKindFromAbi(kind);
}

/// Performs engine inside the shared engine while preserving transaction and changed-set invariants.
pub fn Engine(comptime Ctx: type) type {
    verifyCtx(Ctx);

    return struct {
        const Self = @This();

        pub const Context = Ctx;
        pub const Metrics = Ctx.Metrics;
        pub const RegistryOps = Ctx.RegistryOps;
        pub const HostValueRegistry = host_value_registry.Registry(HostValueCapability);
        pub const ActiveEventDesc = HostActiveEventDesc;
        pub const IdentityInternError = scope_tree.Error || identity_table.Error;
        pub const EventLookupError = active_graph.EventLookupError;
        pub const SignalLookupError = active_graph.SignalLookupError;
        pub const ActiveEventLookupError = error{
            MissingActiveEvent,
        };
        pub const StateLookupError = error{
            MissingActiveState,
        };
        pub const RocHostRequiredError = error{
            MissingRocHost,
        };

        host_values: HostValueRegistry = .{},
        active_events: std.ArrayListUnmanaged(ActiveEventDesc) = .empty,
        event_descriptors: std.ArrayListUnmanaged(HostEventDescriptor) = .empty,
        signal_event_routes: std.ArrayListUnmanaged(HostSignalEventRoute) = .empty,
        signal_descriptors: std.ArrayListUnmanaged(HostSignalDescriptor) = .empty,
        signal_routes: std.ArrayListUnmanaged(HostSignalRoute) = .empty,
        signal_dependents: std.ArrayListUnmanaged(HostSignalDependentsRoute) = .empty,
        signal_cache: std.ArrayListUnmanaged(HostSignalCacheSlot) = .empty,
        states: std.ArrayListUnmanaged(HostState) = .empty,
        state_indexes_by_node_id: std.ArrayListUnmanaged(?usize) = .empty,
        scopes: std.ArrayListUnmanaged(HostScope) = .empty,
        each_row_site_indexes: HostEachRowSiteIndexMap = .empty,
        each_row_sites: std.ArrayListUnmanaged(HostEachRowSite) = .empty,
        each_row_memberships_by_scope_id: std.ArrayListUnmanaged(?HostEachRowMembership) = .empty,
        node_identities: std.ArrayListUnmanaged(HostNodeIdentity) = .empty,
        dom_identities: std.ArrayListUnmanaged(HostDomIdentity) = .empty,
        active_node_identity_ids: std.AutoHashMapUnmanaged(u128, u64) = .empty,
        active_dom_identity_ids: std.AutoHashMapUnmanaged(u128, u64) = .empty,
        has_inactive_scopes: bool = false,
        has_inactive_node_identities: bool = false,
        has_inactive_dom_identities: bool = false,
        // Identity ids retired during the current dirty generation must not be
        // reused until the next one; see identity_table.internNode.
        identity_reuse_barrier: u64 = 0,
        active_stream: HostNodeDescriptorStream = .{},
        active_signal_graph: std.ArrayListUnmanaged(HostActiveSignalGraphNode) = .empty,
        active_source_signal_routes: active_graph.RouteTable(u64) = .empty,
        active_text_signal_routes: active_graph.RouteTable(HostActiveTextSignalSink) = .empty,
        active_bool_signal_routes: active_graph.RouteTable(HostActiveBoolSignalSink) = .empty,
        active_change_signal_routes: active_graph.RouteTable(HostActiveChangeSignalSink) = .empty,
        active_structural_signal_routes: active_graph.RouteTable(HostActiveStructuralSignal) = .empty,
        render_cache: render_cache_mod.Cache(Ctx) = .{},
        pending_tasks: std.ArrayListUnmanaged(HostPendingTask) = .empty,
        active_intervals: std.ArrayListUnmanaged(HostActiveInterval) = .empty,
        cleanup_events: HostCleanupEvents = .empty,
        next_task_request_id: u64 = 1,
        next_interval_token: u64 = 1,
        next_elem_id: u64 = 0,
        roc_host: ?*abi.RocHost = null,
        root_elem: ?abi.Elem = null,
        last_runtime_metrics: Metrics = Ctx.zeroMetrics(),
        pending_roc_metrics: Metrics = Ctx.zeroMetrics(),
        // Render-command accumulator (patches/create/append/remove/...) folded into
        // last_runtime_metrics at finish. Engine-owned so both hosts share it.
        render_metrics: render.Metrics = .{},
        // Dispatch counters (events processed / recompute batches) folded into
        // last_runtime_metrics at finish. Engine-owned so both hosts share it.
        dispatch_metrics: DispatchMetrics = .{},
        dirty_signal_generation: u64 = 0,
        scratch: EngineScratch = .{},

        const ActiveSignalGraphLifecycle = struct {
            engine: *Self,
            ctx: Ctx.Handle,

            /// Ensures interval capacity or state before publication can begin.
            pub fn ensureInterval(self: *@This(), source_token: HostSignalToken, period_ms: u64) void {
                self.engine.ensureActiveInterval(self.ctx, source_token, period_ms);
            }

            /// Removes interval and releases the ownership attached to that live entry.
            pub fn removeInterval(self: *@This(), source_token: HostSignalToken) void {
                self.engine.removeActiveIntervalBySourceToken(self.ctx, source_token);
            }

            /// Performs release record inside the shared engine while preserving transaction and changed-set invariants.
            pub fn releaseRecord(self: *@This(), record: *HostSignalRecord) void {
                record.release(Ctx.allocator(self.ctx), self.ctx, self.engine.roc_host.?, &self.engine.pending_roc_metrics);
            }
        };

        const EachRowScopeKeyLookup = struct {
            engine: *Self,

            /// Performs row key hash through the keyed-row capabilities that own key and item values.
            pub fn rowKeyHash(self: *@This(), scope_id: u64) u64 {
                return self.engine.eachRowScopeKeyHash(scope_id);
            }
        };

        const EachRowSync = struct {
            engine: *Self,
            ctx: Ctx.Handle,
            roc_host: *abi.RocHost,
            ops: HostEachOps,

            /// Records each sync in the metrics or lifecycle state owned by this operation.
            pub fn recordEachSync(self: *@This(), next_len: usize, existing_len: usize) void {
                self.engine.recordEachSync(next_len, existing_len);
            }

            /// Reports whether h key is present in maintained state.
            /// Hashes an incoming key through the each descriptor capability.
            pub fn hashKey(self: *@This(), key: HostValue) u64 {
                return self.engine.hashEachKeyValue(self.ctx, self.roc_host, self.ops.key_text, self.ops.key_capability, key);
            }

            /// Compares candidate row keys exactly after hash lookup, preserving collision correctness.
            /// Compares two incoming keys before persistent publication.
            pub fn nextKeysEqual(self: *@This(), left: HostValue, right: HostValue) bool {
                return self.engine.eachKeysEqual(self.ctx, self.roc_host, self.ops, left, right);
            }

            /// Performs existing key equals inside the shared engine while preserving transaction and changed-set invariants.
            /// Compares an incoming key with one persistent row key.
            pub fn existingKeyEquals(self: *@This(), scope_id: u64, key: HostValue) bool {
                return self.engine.eachRowScopeKeyEquals(self.ctx, self.roc_host, scope_id, key, self.ops.key_capability);
            }

            /// Performs row item equals through the keyed-row capabilities that own key and item values.
            /// Compares an incoming item with one persistent row item.
            pub fn rowItemEquals(self: *@This(), scope_id: u64, item: HostValue) bool {
                return self.engine.eachRowScopeItemEquals(self.ctx, self.roc_host, scope_id, item, self.ops.item_capability);
            }

            /// Replaces row key while releasing displaced ownership exactly once.
            pub fn replaceRowKey(self: *@This(), scope_id: u64, key_hash: u64, key: HostValue) void {
                self.engine.replaceEachRowScopeKey(self.ctx, self.roc_host, scope_id, key_hash, key, self.ops.key_capability);
            }

            /// Replaces row item while releasing displaced ownership exactly once.
            pub fn replaceRowItem(self: *@This(), scope_id: u64, item: HostValue) void {
                self.engine.replaceEachRowScopeItemWithCapability(self.ctx, self.roc_host, scope_id, item, self.ops.item_capability);
            }

            /// Performs drop incoming key inside the shared engine while preserving transaction and changed-set invariants.
            pub fn dropIncomingKey(self: *@This(), key: HostValue) void {
                callHostValueToUnitWithCapability(self.ctx, self.roc_host, self.ops.key_capability, hv.hostValueCapabilityDrop(self.ops.key_capability), key);
            }

            /// Performs drop incoming item inside the shared engine while preserving transaction and changed-set invariants.
            pub fn dropIncomingItem(self: *@This(), item: HostValue) void {
                callHostValueToUnitWithCapability(self.ctx, self.roc_host, self.ops.item_capability, hv.hostValueCapabilityDrop(self.ops.item_capability), item);
            }

            /// Performs create row inside the shared engine while preserving transaction and changed-set invariants.
            pub fn createRow(self: *@This(), parent_scope_id: u64, site_ordinal: u64, key_hash: u64, key: HostValue, item: HostValue) u64 {
                return self.engine.createEachRowScope(self.ctx, parent_scope_id, site_ordinal, key_hash, key, item, self.ops.key_capability, self.ops.item_capability);
            }

            /// Performs dispose scope inside the shared engine while preserving transaction and changed-set invariants.
            pub fn disposeScope(self: *@This(), scope_id: u64) void {
                self.engine.disposeScopeSubtree(self.ctx, self.roc_host, scope_id);
            }

            /// Performs row key hash through the keyed-row capabilities that own key and item values.
            pub fn rowKeyHash(self: *@This(), scope_id: u64) u64 {
                return self.engine.eachRowScopeKeyHash(scope_id);
            }

            /// Records rows in the metrics or lifecycle state owned by this operation.
            pub fn recordRows(self: *@This(), rows_reused: u64, rows_created: u64, rows_removed: u64) void {
                var metrics = self.engine.pending_roc_metrics;
                metrics.bump(.rows_reused, rows_reused);
                metrics.bump(.rows_created, rows_created);
                metrics.bump(.rows_removed, rows_removed);
                self.engine.pending_roc_metrics = metrics;
            }

            /// Rejects a duplicate keyed row at the narrow reconciliation boundary with a bounded diagnostic.
            pub fn failDuplicateEachKey(self: *@This(), parent_scope_id: u64, site_ordinal: u64, first_index: usize, second_index: usize, key: HostValue) noreturn {
                self.engine.failDuplicateEachKey(
                    self.ctx,
                    self.roc_host,
                    self.ops.key_text,
                    self.ops.key_capability,
                    parent_scope_id,
                    site_ordinal,
                    first_index,
                    second_index,
                    key,
                );
            }
        };

        const PreparedEachRowSyncHooks = struct {
            base: EachRowSync,
            scopes: scope_runtime.PreparedEachRowScopes,

            fn init(engine: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, ops: HostEachOps) @This() {
                return .{
                    .base = .{ .engine = engine, .ctx = ctx, .roc_host = roc_host, .ops = ops },
                    .scopes = scope_runtime.PreparedEachRowScopes.init(Ctx.allocator(ctx), engine.scopes.items),
                };
            }

            /// Hashes an incoming key through the each descriptor capability.
            pub fn hashKey(self: *@This(), key: HostValue) u64 {
                return self.base.hashKey(key);
            }

            /// Compares two incoming keys before persistent publication.
            pub fn nextKeysEqual(self: *@This(), left: HostValue, right: HostValue) bool {
                return self.base.nextKeysEqual(left, right);
            }

            /// Compares an incoming key with one persistent row key.
            pub fn existingKeyEquals(self: *@This(), scope_id: u64, key: HostValue) bool {
                return self.base.existingKeyEquals(scope_id, key);
            }

            /// Compares an incoming item with one persistent row item.
            pub fn rowItemEquals(self: *@This(), scope_id: u64, item: HostValue) bool {
                return self.base.rowItemEquals(scope_id, item);
            }

            /// Retains a new row in the plan-local scope overlay.
            pub fn prepareCreatedRow(self: *@This(), allocator: std.mem.Allocator, parent_scope_id: u64, site_ordinal: u64, key_hash: u64, key: HostValue, item: HostValue) std.mem.Allocator.Error!u64 {
                _ = allocator;
                return self.scopes.prepareRow(
                    &self.base.engine.scopes,
                    self.base.ctx,
                    self.base.roc_host,
                    &self.base.engine.pending_roc_metrics,
                    parent_scope_id,
                    site_ordinal,
                    key_hash,
                    key,
                    item,
                    self.base.ops.key_capability,
                    self.base.ops.item_capability,
                );
            }

            /// Reserves engine retirement journals; populated by the enclosing transaction.
            pub fn prepareExistingRowsCommit(_: *@This(), _: std.mem.Allocator, _: usize) std.mem.Allocator.Error!void {}

            /// Validates that reconciliation references a prepared scope identity.
            pub fn commitCreatedRow(self: *@This(), scope_id: u64) void {
                const first: u64 = @intCast(self.scopes.original_scope_len);
                if (scope_id < first or scope_id >= first + self.scopes.rows.items.len) @panic("unknown provisional each-row scope");
            }

            /// Publishes all provisional scope records without allocation.
            pub fn finishPreparedRowsCommit(self: *@This()) void {
                self.scopes.commit(&self.base.engine.scopes);
            }

            /// Drops every provisional row cell while persistent scopes remain unchanged.
            pub fn abortPreparedRows(self: *@This()) void {
                self.scopes.abort(self.base.ctx, self.base.roc_host, &self.base.engine.pending_roc_metrics);
            }

            /// Replaces a surviving row key at the allocation-free commit boundary.
            pub fn replaceRowKey(self: *@This(), scope_id: u64, key_hash: u64, key: HostValue) void {
                self.base.replaceRowKey(scope_id, key_hash, key);
            }

            /// Replaces a surviving row item at the allocation-free commit boundary.
            pub fn replaceRowItem(self: *@This(), scope_id: u64, item: HostValue) void {
                self.base.replaceRowItem(scope_id, item);
            }

            /// Releases an unchanged incoming key after publication succeeds.
            pub fn dropIncomingKey(self: *@This(), key: HostValue) void {
                self.base.dropIncomingKey(key);
            }

            /// Releases an unchanged incoming item after publication succeeds.
            pub fn dropIncomingItem(self: *@This(), item: HostValue) void {
                self.base.dropIncomingItem(item);
            }

            /// Retires an obsolete row scope after all preparation succeeds.
            pub fn disposeScope(_: *@This(), _: u64) void {
                // The enclosing prepared subtree-retirement journal owns this
                // removal. Reconciliation publishes only the final site index.
            }

            /// Reads a committed row hash while rebuilding the site index.
            pub fn rowKeyHash(self: *@This(), scope_id: u64) u64 {
                return self.base.rowKeyHash(scope_id);
            }

            /// Reports duplicate incoming keys through the bounded host diagnostic.
            pub fn failDuplicateEachKey(self: *@This(), parent_scope_id: u64, site_ordinal: u64, first_index: usize, second_index: usize, key: HostValue) noreturn {
                self.base.failDuplicateEachKey(parent_scope_id, site_ordinal, first_index, second_index, key);
            }

            fn deinit(self: *@This()) void {
                self.scopes.deinit();
            }
        };

        const ScopeIdentityDeactivation = struct {
            engine: *Self,
            ctx: Ctx.Handle,
            roc_host: *abi.RocHost,

            /// Performs deactivate node inside the shared engine while preserving transaction and changed-set invariants.
            pub fn deactivateNode(self: *@This(), node_id: u64) void {
                const identity = self.engine.node_identities.items[@intCast(node_id)];
                _ = self.engine.active_node_identity_ids.remove(identityKey(identity.scope_id, identity.ordinal));
                self.engine.deactivateState(self.ctx, self.roc_host, node_id);
            }
        };

        const ScopeDisposal = struct {
            engine: *Self,
            ctx: Ctx.Handle,
            roc_host: *abi.RocHost,

            /// Performs deactivate node identities inside the shared engine while preserving transaction and changed-set invariants.
            pub fn deactivateNodeIdentities(self: *@This(), scope_id: u64) void {
                var identity_deactivation = ScopeIdentityDeactivation{ .engine = self.engine, .ctx = self.ctx, .roc_host = self.roc_host };
                var ordinal: u64 = 0;
                while (self.engine.active_node_identity_ids.fetchRemove(identityKey(scope_id, ordinal))) |entry| : (ordinal += 1) {
                    const node_id = entry.value;
                    identity_deactivation.deactivateNode(node_id);
                    const identity = &self.engine.node_identities.items[@intCast(node_id)];
                    identity.active = false;
                    identity.retired_at = self.engine.identity_reuse_barrier;
                    self.engine.has_inactive_node_identities = true;
                }
            }

            /// Appends cleanup events using capacity that must already satisfy the caller's transaction contract.
            pub fn appendCleanupEvents(self: *@This(), scope_id: u64) void {
                for (self.engine.active_stream.cleanups.items) |cleanup| {
                    if (cleanup.scope_id == scope_id) {
                        self.engine.appendCleanupEvent(self.ctx, cleanup.name);
                    }
                }
            }

            /// Performs cancel pending tasks inside the shared engine while preserving transaction and changed-set invariants.
            pub fn cancelPendingTasks(self: *@This(), scope_id: u64) void {
                self.engine.cancelPendingTasksInScopeSubtree(self.ctx, scope_id);
            }

            /// Performs deactivate dom identities inside the shared engine while preserving transaction and changed-set invariants.
            pub fn deactivateDomIdentities(self: *@This(), scope_id: u64) void {
                var ordinal: u64 = 0;
                while (self.engine.active_dom_identity_ids.fetchRemove(identityKey(scope_id, ordinal))) |entry| : (ordinal += 1) {
                    const identity = &self.engine.dom_identities.items[@intCast(entry.value - 1)];
                    identity.active = false;
                    identity.retired_at = self.engine.identity_reuse_barrier;
                    self.engine.has_inactive_dom_identities = true;
                }
            }

            /// Removes each row and releases the ownership attached to that live entry.
            pub fn removeEachRow(self: *@This(), scope_id: u64, key_hash: u64) void {
                self.engine.removeEachRowFromSiteIndex(scope_id, key_hash);
            }

            /// Performs deinit scope step inside the shared engine while preserving transaction and changed-set invariants.
            pub fn deinitScopeStep(self: *@This(), step: *HostScopeStep) void {
                deinitHostScopeStep(step, self.ctx, self.roc_host, &self.engine.pending_roc_metrics);
            }

            /// Records scope disposed in the metrics or lifecycle state owned by this operation.
            pub fn recordScopeDisposed(self: *@This()) void {
                self.engine.has_inactive_scopes = true;
                var metrics = self.engine.pending_roc_metrics;
                metrics.bump(.scopes_disposed, 1);
                self.engine.pending_roc_metrics = metrics;
            }
        };

        const ActiveDomIds = struct {
            stream: *const HostNodeDescriptorStream,

            /// Performs elem id is active inside the shared engine while preserving transaction and changed-set invariants.
            pub fn elemIdIsActive(self: @This(), elem_id: u64) bool {
                const index = self.stream.elemDescriptorIndex(elem_id) orelse return false;
                return elemDescriptorIndexActive(index);
            }
        };

        /// Creates an initialized value with the ownership and capacity invariants required by this module.
        pub fn init() Self {
            return .{};
        }

        /// Performs deinit scratch inside the shared engine while preserving transaction and changed-set invariants.
        pub fn deinitScratch(self: *Self, ctx: Ctx.Handle) void {
            self.scratch.deinit(Ctx.allocator(ctx));
        }

        fn scratchBinderStack(self: *Self, allocator: std.mem.Allocator, base: []const HostBinderBinding) *std.ArrayListUnmanaged(HostBinderBinding) {
            if (self.scratch.binder_stack.items.len != 0) {
                @panic("engine binder scratch was already active");
            }
            self.scratch.binder_stack.appendSlice(allocator, base) catch @panic("out of memory");
            return &self.scratch.binder_stack;
        }

        fn debugPhase(ctx: Ctx.Handle, phase: DebugPhase) void {
            if (comptime @hasDecl(Ctx, "debugPhase")) {
                Ctx.debugPhase(ctx, phase);
            }
        }

        fn callHostValueToUnitWithCapability(ctx: Ctx.Handle, roc_host: *abi.RocHost, cap: HostValueCapability, callable: abi.RocErasedCallable, value: HostValue) void {
            retained_values.callHostValueToUnitWithCapability(Ctx, ctx, roc_host, cap, callable, value);
        }

        fn callHostValueToHostValueWithCapability(ctx: Ctx.Handle, roc_host: *abi.RocHost, cap: HostValueCapability, callable: abi.RocErasedCallable, value: HostValue) HostValue {
            return retained_values.callHostValueToHostValueWithCapability(Ctx, ctx, roc_host, cap, callable, value);
        }

        fn callHostValueToCmdWithCapability(ctx: Ctx.Handle, roc_host: *abi.RocHost, cap: HostValueCapability, callable: abi.RocErasedCallable, value: HostValue) erased_calls.Cmd {
            return retained_values.callHostValueToCmdWithCapability(Ctx, ctx, roc_host, cap, callable, value);
        }

        fn callHostValueToStrWithCapability(ctx: Ctx.Handle, roc_host: *abi.RocHost, cap: HostValueCapability, callable: abi.RocErasedCallable, value: HostValue) abi.RocStr {
            return retained_values.callHostValueToStrWithCapability(Ctx, ctx, roc_host, cap, callable, value);
        }

        fn callHostValueToBoolWithCapability(ctx: Ctx.Handle, roc_host: *abi.RocHost, cap: HostValueCapability, callable: abi.RocErasedCallable, value: HostValue) bool {
            return retained_values.callHostValueToBoolWithCapability(Ctx, ctx, roc_host, cap, callable, value);
        }

        fn callHostValueToHostValueListWithCapability(ctx: Ctx.Handle, roc_host: *abi.RocHost, cap: HostValueCapability, callable: abi.RocErasedCallable, value: HostValue) HostValueList {
            return retained_values.callHostValueToHostValueListWithCapability(Ctx, ctx, roc_host, cap, callable, value);
        }

        fn callHostValueListToHostValueWithCapability(ctx: Ctx.Handle, roc_host: *abi.RocHost, cap: HostValueCapability, callable: abi.RocErasedCallable, value: HostValueList) HostValue {
            return retained_values.callHostValueListToHostValueWithCapability(Ctx, ctx, roc_host, cap, callable, value);
        }

        fn callHostValueHostValueToBoolWithCapability(ctx: Ctx.Handle, roc_host: *abi.RocHost, cap: HostValueCapability, callable: abi.RocErasedCallable, left: HostValue, right: HostValue) bool {
            return retained_values.callHostValueHostValueToBoolWithCapability(Ctx, ctx, roc_host, cap, callable, left, right);
        }

        fn callHostValueHostValueToHostValueWithCapabilities(ctx: Ctx.Handle, roc_host: *abi.RocHost, left_cap: HostValueCapability, right_cap: HostValueCapability, callable: abi.RocErasedCallable, left: HostValue, right: HostValue) HostValue {
            return retained_values.callHostValueHostValueToHostValueWithCapabilities(Ctx, ctx, roc_host, left_cap, right_cap, callable, left, right);
        }

        fn callHostValueHostValueToElemWithCapabilities(ctx: Ctx.Handle, roc_host: *abi.RocHost, left_cap: HostValueCapability, right_cap: HostValueCapability, callable: abi.RocErasedCallable, left: HostValue, right: HostValue) abi.Elem {
            return retained_values.callHostValueHostValueToElemWithCapabilities(Ctx, ctx, roc_host, left_cap, right_cap, callable, left, right);
        }

        /// Records dispatch in the metrics or lifecycle state owned by this operation.
        pub fn recordDispatch(self: *Self) void {
            if (comptime !enable_runtime_metrics) return;
            self.dispatch_metrics.events_processed += 1;
            self.dispatch_metrics.recompute_batches += 1;
        }

        /// Records stream nodes scanned in the metrics or lifecycle state owned by this operation.
        pub fn recordStreamNodesScanned(self: *Self, count: usize) void {
            self.pending_roc_metrics.bump(.stream_nodes_scanned, @intCast(count));
        }

        /// Records stream nodes scanned by in the metrics or lifecycle state owned by this operation.
        pub fn recordStreamNodesScannedBy(self: *Self, comptime field: RuntimeMetrics.Field, count: usize) void {
            var metrics = self.pending_roc_metrics;
            metrics.bump(.stream_nodes_scanned, @intCast(count));
            metrics.bump(field, @intCast(count));
            self.pending_roc_metrics = metrics;
        }

        /// Records scope created in the metrics or lifecycle state owned by this operation.
        pub fn recordScopeCreated(self: *Self) void {
            var metrics = self.pending_roc_metrics;
            metrics.bump(.scopes_created, 1);
            self.pending_roc_metrics = metrics;
        }

        /// Records each key compare in the metrics or lifecycle state owned by this operation.
        pub fn recordEachKeyCompare(self: *Self) void {
            var metrics = self.pending_roc_metrics;
            metrics.bump(.each_key_compares, 1);
            self.pending_roc_metrics = metrics;
        }

        /// Records each key hash in the metrics or lifecycle state owned by this operation.
        pub fn recordEachKeyHash(self: *Self) void {
            var metrics = self.pending_roc_metrics;
            metrics.bump(.each_key_compares, 1);
            metrics.bump(.each_key_hashes, 1);
            self.pending_roc_metrics = metrics;
        }

        /// Records each key reuse compare in the metrics or lifecycle state owned by this operation.
        pub fn recordEachKeyReuseCompare(self: *Self) void {
            var metrics = self.pending_roc_metrics;
            metrics.bump(.each_key_compares, 1);
            metrics.bump(.each_key_reuse_compares, 1);
            self.pending_roc_metrics = metrics;
        }

        /// Records each key duplicate compare in the metrics or lifecycle state owned by this operation.
        pub fn recordEachKeyDuplicateCompare(self: *Self) void {
            var metrics = self.pending_roc_metrics;
            metrics.bump(.each_key_compares, 1);
            metrics.bump(.each_key_duplicate_compares, 1);
            self.pending_roc_metrics = metrics;
        }

        /// Records each item compare in the metrics or lifecycle state owned by this operation.
        pub fn recordEachItemCompare(self: *Self) void {
            var metrics = self.pending_roc_metrics;
            metrics.bump(.each_item_compares, 1);
            self.pending_roc_metrics = metrics;
        }

        /// Records each sync in the metrics or lifecycle state owned by this operation.
        pub fn recordEachSync(self: *Self, key_count: usize, existing_count: usize) void {
            var metrics = self.pending_roc_metrics;
            metrics.bump(.each_syncs, 1);
            metrics.bump(.each_sync_keys, @intCast(key_count));
            metrics.bump(.each_sync_existing_rows, @intCast(existing_count));
            self.pending_roc_metrics = metrics;
        }

        /// Performs note stale task resolution ignored inside the shared engine while preserving transaction and changed-set invariants.
        pub fn noteStaleTaskResolutionIgnored(self: *Self) void {
            var metrics = self.pending_roc_metrics;
            metrics.bump(.stale_task_results_ignored, 1);
            self.pending_roc_metrics = metrics;
        }

        /// Performs deinit render cache inside the shared engine while preserving transaction and changed-set invariants.
        pub fn deinitRenderCache(self: *Self, ctx: Ctx.Handle) void {
            self.render_cache.deinit(ctx);
        }

        /// Reports whether render root is present in maintained state.
        pub fn hasRenderRoot(self: *const Self) bool {
            return self.render_cache.hasRoot();
        }

        /// Reports whether active render node is present in maintained state.
        pub fn hasActiveRenderNode(self: *const Self, elem_id: u64) bool {
            return self.render_cache.hasActiveNode(elem_id);
        }

        /// Performs reset render tree inside the shared engine while preserving transaction and changed-set invariants.
        pub fn resetRenderTree(self: *Self, ctx: Ctx.Handle) void {
            self.render_cache.reset(ctx);
        }

        /// Appends render node using capacity that must already satisfy the caller's transaction contract.
        pub fn appendRenderNode(self: *Self, ctx: Ctx.Handle, elem_id: u64, parent_elem_id: u64, tag: []const u8) void {
            self.render_cache.appendNode(ctx, elem_id, parent_elem_id, tag);
        }

        /// Ensures render node capacity or state before publication can begin.
        pub fn ensureRenderNode(self: *Self, ctx: Ctx.Handle, elem_id: u64, tag: []const u8, counts: *render.Counts) void {
            self.render_cache.ensureNode(ctx, elem_id, tag, counts);
        }

        fn ensureRenderNodeCapacity(self: *Self, ctx: Ctx.Handle, capacity: usize) void {
            self.render_cache.ensureNodeCapacity(ctx, capacity);
            if (comptime @hasDecl(Ctx.Sink, "reserveNodes")) Ctx.sink(ctx).reserveNodes(capacity);
        }

        /// Returns active render node tag differs from the maintained active-runtime indexes.
        pub fn activeRenderNodeTagDiffers(self: *const Self, elem_id: u64, tag: []const u8) bool {
            return self.render_cache.activeNodeTagDiffers(elem_id, tag);
        }

        /// Removes node while preserving indexes for unaffected render nodes.
        pub fn removeRenderNode(self: *Self, ctx: Ctx.Handle, elem_id: u64, counts: *render.Counts) void {
            self.render_cache.removeNode(ctx, elem_id, counts);
        }

        /// Replaces children for the affected parent without rebuilding unrelated tree state.
        pub fn replaceRenderChildren(self: *Self, ctx: Ctx.Handle, parent_elem_id: u64, next_child_ids: []const u64, counts: *render.Counts) void {
            self.render_cache.replaceChildren(ctx, parent_elem_id, next_child_ids, counts);
        }

        /// Replaces children for moves for the affected parent without rebuilding unrelated tree state.
        pub fn replaceRenderChildrenForMoves(self: *Self, ctx: Ctx.Handle, parent_elem_id: u64, next_child_ids: []const u64, counts: *render.Counts) void {
            self.render_cache.replaceChildrenForMoves(ctx, parent_elem_id, next_child_ids, counts);
        }

        /// Applies render event binding after preparation has fixed semantics and reserved fallible growth.
        pub fn applyRenderEventBinding(self: *Self, ctx: Ctx.Handle, elem_id: u64, kind: RenderEventKind, binding: ?HostRequiredEventBinding, counts: *render.Counts) void {
            self.render_cache.applyEventBinding(ctx, elem_id, kind, binding, counts);
        }

        /// Applies render named event binding after preparation has fixed semantics and reserved fallible growth.
        pub fn applyRenderNamedEventBinding(self: *Self, ctx: Ctx.Handle, elem_id: u64, name: []const u8, binding: ?HostRequiredEventBinding, counts: *render.Counts) void {
            self.render_cache.applyNamedEventBinding(ctx, elem_id, name, binding, counts);
        }

        fn descriptorStreamNodeTag(stream: *const HostNodeDescriptorStream, node: HostRenderNode) []const u8 {
            const descriptor_index = stream.elemDescriptorIndex(node.elem_id) orelse @panic("render node had no descriptor index");
            return switch (node.kind) {
                .element => blk: {
                    const index = descriptor_index.element.get() orelse @panic("element render node had no element descriptor");
                    if (index >= stream.elements.items.len) @panic("element descriptor index exceeded descriptor table");
                    const desc = stream.elements.items[index];
                    if (desc.elem_id != node.elem_id) @panic("element descriptor index pointed at the wrong elem id");
                    break :blk desc.tag;
                },
                .text, .signal_text => "text",
            };
        }

        fn descriptorStreamNodeParent(stream: *const HostNodeDescriptorStream, node: HostRenderNode) u64 {
            const descriptor_index = stream.elemDescriptorIndex(node.elem_id) orelse @panic("render node had no descriptor index");
            return switch (node.kind) {
                .element => blk: {
                    const index = descriptor_index.element.get() orelse @panic("element render node had no element descriptor");
                    if (index >= stream.elements.items.len) @panic("element descriptor index exceeded descriptor table");
                    const desc = stream.elements.items[index];
                    if (desc.elem_id != node.elem_id) @panic("element descriptor index pointed at the wrong elem id");
                    break :blk desc.parent_elem_id;
                },
                .text => blk: {
                    const index = descriptor_index.text_node.get() orelse @panic("text render node had no text descriptor");
                    if (index >= stream.text_nodes.items.len) @panic("text descriptor index exceeded descriptor table");
                    const desc = stream.text_nodes.items[index];
                    if (desc.elem_id != node.elem_id) @panic("text descriptor index pointed at the wrong elem id");
                    break :blk desc.parent_elem_id;
                },
                .signal_text => blk: {
                    const index = descriptor_index.signal_text_node.get() orelse @panic("signal text render node had no signal text descriptor");
                    if (index >= stream.signal_text_nodes.items.len) @panic("signal text descriptor index exceeded descriptor table");
                    const desc = stream.signal_text_nodes.items[index];
                    if (desc.elem_id != node.elem_id) @panic("signal text descriptor index pointed at the wrong elem id");
                    break :blk desc.parent_elem_id;
                },
            };
        }

        /// Performs debug assert render cache matches stream inside the shared engine while preserving transaction and changed-set invariants.
        pub fn debugAssertRenderCacheMatchesStream(self: *Self, ctx: Ctx.Handle, stream: *const HostNodeDescriptorStream) void {
            if (comptime builtin.mode != .Debug) return;

            const allocator = Ctx.allocator(ctx);
            self.scratch.debug_seen_render_nodes.resize(allocator, self.render_cache.nodes.items.len) catch @panic("out of memory");
            defer self.scratch.debug_seen_render_nodes.clearRetainingCapacity();
            const seen = self.scratch.debug_seen_render_nodes.items;
            @memset(seen, false);
            if (seen.len != 0) seen[0] = true;

            for (stream.render_nodes.items) |node| {
                const index: usize = @intCast(node.elem_id);
                if (index >= self.render_cache.nodes.items.len) @panic("descriptor stream referenced render cache node outside table");
                const cached = &self.render_cache.nodes.items[index];
                if (!cached.active) @panic("descriptor stream referenced inactive render cache node");
                if (cached.tag == null or !std.mem.eql(u8, cached.tag.?, descriptorStreamNodeTag(stream, node))) {
                    @panic("descriptor stream tag disagreed with render cache");
                }
                const parent_id = descriptorStreamNodeParent(stream, node);
                if (cached.parent_id == null or cached.parent_id.? != parent_id) {
                    const indexed_children = streamDirectChildrenInto(allocator, stream, parent_id, &self.scratch.stream_direct_children);
                    const cache_child_count = if (parent_id < self.render_cache.nodes.items.len and self.render_cache.nodes.items[@intCast(parent_id)].active)
                        self.render_cache.nodes.items[@intCast(parent_id)].children.items.len
                    else
                        0;
                    var message: [160]u8 = undefined;
                    const rendered = std.fmt.bufPrint(
                        &message,
                        "descriptor stream parent disagreed for elem {d}: stream parent {d}, cache parent {?d}, indexed children {d}, cache children {d}",
                        .{ node.elem_id, parent_id, cached.parent_id, indexed_children.len, cache_child_count },
                    ) catch "descriptor stream parent disagreed with render cache";
                    @panic(rendered);
                }
                seen[index] = true;
            }

            for (self.render_cache.nodes.items, 0..) |cached, index| {
                if (index == 0 or !cached.active) continue;
                if (index >= seen.len or !seen[index]) @panic("active render cache node was absent from descriptor stream");
            }

            for (self.render_cache.nodes.items, 0..) |cached, parent_id| {
                if (!cached.active) continue;
                const expected_children = &self.scratch.debug_expected_children;
                expected_children.clearRetainingCapacity();
                for (stream.render_nodes.items) |node| {
                    if (descriptorStreamNodeParent(stream, node) == parent_id) {
                        expected_children.append(allocator, node.elem_id) catch @panic("out of memory");
                    }
                }
                const indexed_children = streamDirectChildrenInto(allocator, stream, @intCast(parent_id), &self.scratch.stream_direct_children);
                if (!std.mem.eql(u64, indexed_children, expected_children.items)) {
                    var message: [160]u8 = undefined;
                    const rendered = std.fmt.bufPrint(
                        &message,
                        "descriptor stream child index disagreed with render order for parent {d}",
                        .{parent_id},
                    ) catch "descriptor stream child index disagreed with render order";
                    @panic(rendered);
                }
                if (!std.mem.eql(u64, cached.children.items, expected_children.items)) {
                    @panic("descriptor stream child order disagreed with render cache");
                }
            }
            self.scratch.debug_expected_children.clearRetainingCapacity();
        }

        /// Performs debug assert render cache matches sink inside the shared engine while preserving transaction and changed-set invariants.
        pub fn debugAssertRenderCacheMatchesSink(self: *Self, ctx: Ctx.Handle) void {
            self.render_cache.debugAssertMatchesSink(ctx);
        }

        /// Applies render text field after preparation has fixed semantics and reserved fallible growth.
        pub fn applyRenderTextField(self: *Self, ctx: Ctx.Handle, elem_id: u64, field: RenderTextField, value: []const u8) bool {
            return self.render_cache.applyTextField(ctx, elem_id, field, value);
        }

        /// Applies render text attr after preparation has fixed semantics and reserved fallible growth.
        pub fn applyRenderTextAttr(self: *Self, ctx: Ctx.Handle, elem_id: u64, name: []const u8, value: []const u8) bool {
            return self.render_cache.applyTextAttr(ctx, elem_id, name, value);
        }

        /// Applies render bool attr after preparation has fixed semantics and reserved fallible growth.
        pub fn applyRenderBoolAttr(self: *Self, ctx: Ctx.Handle, elem_id: u64, name: []const u8, value: bool) bool {
            if (value) {
                return self.applyRenderTextAttr(ctx, elem_id, name, "");
            }
            return self.clearRenderTextAttr(ctx, elem_id, name);
        }

        /// Applies render bool field after preparation has fixed semantics and reserved fallible growth.
        pub fn applyRenderBoolField(self: *Self, ctx: Ctx.Handle, elem_id: u64, field: RenderBoolField, value: bool) bool {
            return self.render_cache.applyBoolField(ctx, elem_id, field, value);
        }

        /// Clears render text field while retaining bounded storage where the type promises reuse.
        pub fn clearRenderTextField(self: *Self, ctx: Ctx.Handle, elem_id: u64, field: RenderTextField) bool {
            return self.render_cache.clearTextField(ctx, elem_id, field);
        }

        /// Clears render text attr while retaining bounded storage where the type promises reuse.
        pub fn clearRenderTextAttr(self: *Self, ctx: Ctx.Handle, elem_id: u64, name: []const u8) bool {
            return self.render_cache.clearTextAttr(ctx, elem_id, name);
        }

        /// Clears render bool field while retaining bounded storage where the type promises reuse.
        pub fn clearRenderBoolField(self: *Self, ctx: Ctx.Handle, elem_id: u64, field: RenderBoolField) bool {
            return self.render_cache.clearBoolField(ctx, elem_id, field);
        }

        /// Clears event descriptors while retaining bounded storage where the type promises reuse.
        pub fn clearEventDescriptors(self: *Self) void {
            self.event_descriptors.items.len = 0;
        }

        /// Performs deinit active event desc inside the shared engine while preserving transaction and changed-set invariants.
        pub fn deinitActiveEventDesc(self: *Self, roc_host: *abi.RocHost, desc: ActiveEventDesc) void {
            releaseHostEventReducer(desc.payload_reducer, roc_host, &self.pending_roc_metrics);
        }

        /// Clears active events while retaining bounded storage where the type promises reuse.
        pub fn clearActiveEvents(self: *Self) RocHostRequiredError!void {
            const roc_host = self.roc_host orelse {
                if (self.active_events.items.len != 0) return RocHostRequiredError.MissingRocHost;
                return;
            };
            for (self.active_events.items) |desc| {
                self.deinitActiveEventDesc(roc_host, desc);
            }
            self.active_events.items.len = 0;
        }

        /// Clears signal cache while retaining bounded storage where the type promises reuse.
        pub fn clearSignalCache(self: *Self, ctx: Ctx.Handle) RocHostRequiredError!void {
            const roc_host = self.roc_host orelse {
                if (self.signal_cache.items.len != 0) return RocHostRequiredError.MissingRocHost;
                return;
            };
            for (self.signal_cache.items) |*slot| {
                slot.deinit(ctx, roc_host, &self.pending_roc_metrics);
            }
            self.signal_cache.items.len = 0;
        }

        /// Clears states while retaining bounded storage where the type promises reuse.
        pub fn clearStates(self: *Self, ctx: Ctx.Handle) RocHostRequiredError!void {
            const roc_host = self.roc_host orelse {
                for (self.states.items) |state| {
                    if (state.active) return RocHostRequiredError.MissingRocHost;
                }
                self.states.items.len = 0;
                self.state_indexes_by_node_id.items.len = 0;
                return;
            };
            for (self.states.items) |*state| {
                if (!state.active) continue;
                state.cell.deinit(ctx, roc_host, &self.pending_roc_metrics);
                state.active = false;
            }
            self.states.items.len = 0;
            self.state_indexes_by_node_id.items.len = 0;
        }

        fn ensureStateIndexSlot(self: *Self, ctx: Ctx.Handle, node_id: u64) *?usize {
            const allocator = Ctx.allocator(ctx);
            const index: usize = @intCast(node_id);
            while (self.state_indexes_by_node_id.items.len <= index) {
                self.state_indexes_by_node_id.append(allocator, null) catch @panic("out of memory");
            }
            return &self.state_indexes_by_node_id.items[index];
        }

        fn recordStateCellIndex(self: *Self, ctx: Ctx.Handle, node_id: u64, index: usize) void {
            const slot = self.ensureStateIndexSlot(ctx, node_id);
            if (slot.* != null) @panic("state cell index already existed for node id");
            slot.* = index;
        }

        fn clearStateCellIndex(self: *Self, node_id: u64, expected: usize) void {
            if (node_id >= self.state_indexes_by_node_id.items.len) @panic("state cell index clear referenced an unknown node id");
            const slot = &self.state_indexes_by_node_id.items[@intCast(node_id)];
            const existing = slot.* orelse @panic("state cell index clear missed its node id");
            if (existing != expected) @panic("state cell index clear referenced the wrong state index");
            slot.* = null;
        }

        fn clearEachRowSites(self: *Self, allocator: std.mem.Allocator) void {
            each_runtime.clearSites(allocator, &self.each_row_sites, &self.each_row_site_indexes, &self.each_row_memberships_by_scope_id);
        }

        fn ensureEachRowSiteIndex(self: *Self, allocator: std.mem.Allocator, parent_scope_id: u64, site_ordinal: u64) usize {
            return each_runtime.ensureSiteIndex(allocator, &self.each_row_sites, &self.each_row_site_indexes, parent_scope_id, site_ordinal);
        }

        fn activeEachRowSiteIndex(self: *Self, parent_scope_id: u64, site_ordinal: u64) ?usize {
            return each_runtime.activeSiteIndex(&self.each_row_site_indexes, parent_scope_id, site_ordinal);
        }

        fn appendEachRowToSiteIndex(self: *Self, allocator: std.mem.Allocator, site_index: usize, scope_id: u64, key_hash: u64) void {
            each_runtime.appendRowToSiteIndex(allocator, &self.each_row_sites, &self.each_row_memberships_by_scope_id, site_index, scope_id, key_hash);
        }

        fn removeEachRowFromSiteIndex(self: *Self, scope_id: u64, key_hash: u64) void {
            var row_keys = EachRowScopeKeyLookup{ .engine = self };
            each_runtime.removeRowFromSiteIndex(&self.each_row_sites, &self.each_row_memberships_by_scope_id, scope_id, key_hash, &row_keys);
        }

        /// Performs deactivate state inside the shared engine while preserving transaction and changed-set invariants.
        pub fn deactivateState(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, node_id: u64) void {
            const state_index = self.stateIndexByNodeId(node_id) orelse return;
            const state = &self.states.items[state_index];
            state.cell.deinit(ctx, roc_host, &self.pending_roc_metrics);
            state.active = false;
            self.clearStateCellIndex(node_id, state_index);
        }

        /// Clears scopes while retaining bounded storage where the type promises reuse.
        pub fn clearScopes(self: *Self, ctx: Ctx.Handle) RocHostRequiredError!void {
            if (self.roc_host) |roc_host| {
                for (self.scopes.items) |*scope| {
                    if (!scope.active) continue;
                    deinitHostScopeStep(&scope.step, ctx, roc_host, &self.pending_roc_metrics);
                }
            } else if (self.scopes.items.len != 0) {
                return RocHostRequiredError.MissingRocHost;
            }
            self.scopes.items.len = 0;
            self.has_inactive_scopes = false;
            self.clearEachRowSites(Ctx.allocator(ctx));
        }

        /// Performs cleanup event count inside the shared engine while preserving transaction and changed-set invariants.
        pub fn cleanupEventCount(self: *const Self, name: []const u8) u64 {
            return effects_runtime.cleanupEventCount(self.cleanup_events.items, name);
        }

        /// Returns active task record by token from the maintained active-runtime indexes.
        pub fn activeTaskRecordByToken(self: *Self, token: HostSignalToken) ?*HostSignalRecord {
            return effects_runtime.activeTaskRecordByToken(self.active_signal_graph.items, token);
        }

        /// Returns active interval record count by period from the maintained active-runtime indexes.
        pub fn activeIntervalRecordCountByPeriod(self: *const Self, period_ms: u64) u64 {
            return effects_runtime.activeIntervalRecordCountByPeriod(self.active_signal_graph.items, period_ms);
        }

        /// Returns active interval record by token from the maintained active-runtime indexes.
        pub fn activeIntervalRecordByToken(self: *Self, source_token: HostSignalToken) ?*HostSignalRecord {
            return effects_runtime.activeIntervalRecordByToken(self.active_signal_graph.items, source_token);
        }

        /// Returns active interval source token by runtime token from the maintained active-runtime indexes.
        pub fn activeIntervalSourceTokenByRuntimeToken(self: *Self, token: u64) ?HostSignalToken {
            return effects_runtime.activeIntervalSourceTokenByRuntimeToken(self.active_intervals.items, token);
        }

        /// Resolves pending task count by name from the bounded task registry without scanning unrelated work.
        pub fn pendingTaskCountByName(self: *const Self, name: []const u8) u64 {
            return effects_runtime.pendingTaskCountByName(self.pending_tasks.items, name);
        }

        /// Resolves pending task index by request id from the bounded task registry without scanning unrelated work.
        pub fn pendingTaskIndexByRequestId(self: *Self, request_id: u64) ?usize {
            return effects_runtime.pendingTaskIndexByRequestId(self.pending_tasks.items, request_id);
        }

        /// Performs classify task resolution inside the shared engine while preserving transaction and changed-set invariants.
        pub fn classifyTaskResolution(self: *Self, request_id: u64) TaskResolutionClass {
            if (self.pendingTaskIndexByRequestId(request_id) != null) return .pending;
            // Any previously issued, no-longer-pending id is benign here. That
            // deliberately covers both canceled/superseded async work and double
            // resolves of already-completed tasks; hosts should reject ids that
            // were never issued before calling into the engine.
            if (request_id != 0 and request_id < self.next_task_request_id) return .superseded;
            return .unknown;
        }

        /// Returns dense source ids for the validated event route without rediscovering dependencies.
        pub fn sourceSignalIdsForEvent(self: *Self, event_id: u64) EventLookupError![]const u64 {
            return active_graph.sourceSignalIdsForEvent(self.signal_event_routes.items, event_id);
        }

        /// Performs event payload descriptor inside the shared engine while preserving transaction and changed-set invariants.
        pub fn eventPayloadDescriptor(self: *Self, event_id: u64) EventLookupError!BoundaryPayloadDescriptor {
            return active_graph.eventPayloadDescriptor(self.event_descriptors.items, event_id);
        }

        /// Returns dense signal ids associated with for state from maintained indexes.
        pub fn signalIdsForState(self: *Self, state_id: u64) SignalLookupError![]const u64 {
            return active_graph.signalIdsForState(self.signal_routes.items, state_id);
        }

        /// Performs dependent signal ids for signal inside the shared engine while preserving transaction and changed-set invariants.
        pub fn dependentSignalIdsForSignal(self: *Self, signal_id: u64) SignalLookupError![]const u64 {
            return active_graph.dependentSignalIdsForSignal(self.signal_dependents.items, signal_id);
        }

        /// Returns a signal's topological rank without traversing the dependency graph.
        pub fn signalRank(self: *Self, signal_id: u64) SignalLookupError!u64 {
            return active_graph.signalRank(self.signal_descriptors.items, signal_id);
        }

        /// Returns next dirty signal generation from maintained local structure without a full-tree scan.
        pub fn nextDirtySignalGeneration(self: *Self) u64 {
            if (self.dirty_signal_generation == std.math.maxInt(u64)) {
                @panic("host dirty signal generation overflowed");
            }
            self.dirty_signal_generation += 1;
            self.identity_reuse_barrier = self.dirty_signal_generation;
            return self.dirty_signal_generation;
        }

        /// Returns active signal rank from the maintained active-runtime indexes.
        pub fn activeSignalRank(self: *Self, record_id: u64) u64 {
            return active_graph.rank(HostSignalRecord, self.active_signal_graph.items, record_id);
        }

        /// Performs dependent active signal record ids inside the shared engine while preserving transaction and changed-set invariants.
        pub fn dependentActiveSignalRecordIds(self: *Self, record_id: u64) []const u64 {
            return active_graph.dependentIds(HostSignalRecord, self.active_signal_graph.items, record_id);
        }

        fn scratchDirtyActiveSignalRecordIdsForSources(self: *Self, ctx: Ctx.Handle, dirty_source_node_ids: []const u64) []const u64 {
            return self.scratch.dirty_active_records.collectForSources(
                HostSignalRecord,
                Ctx.allocator(ctx),
                self.active_signal_graph.items,
                self.active_source_signal_routes.items,
                dirty_source_node_ids,
            );
        }

        fn scratchDirtyActiveSignalRecordIdsForRoots(self: *Self, ctx: Ctx.Handle, root_record_ids: []const u64) []const u64 {
            return self.scratch.dirty_active_records.collectForRoots(
                HostSignalRecord,
                Ctx.allocator(ctx),
                self.active_signal_graph.items,
                root_record_ids,
            );
        }

        /// Records derived call in the metrics or lifecycle state owned by this operation.
        pub fn recordDerivedCall(self: *Self) void {
            var metrics = self.pending_roc_metrics;
            metrics.bump(.derived_calls_into_roc, 1);
            self.pending_roc_metrics = metrics;
        }

        /// Records signal prune in the metrics or lifecycle state owned by this operation.
        pub fn recordSignalPrune(self: *Self) void {
            var metrics = self.pending_roc_metrics;
            metrics.bump(.propagation_prunes, 1);
            self.pending_roc_metrics = metrics;
        }

        /// Performs clone cached signal value inside the shared engine while preserving transaction and changed-set invariants.
        pub fn cloneCachedSignalValue(self: *Self, ctx: Ctx.Handle, cache_slot: *const HostSignalCacheSlot) HostValue {
            _ = self;
            debugPhase(ctx, .clone_cached_signal);
            return switch (cache_slot.*) {
                .absent => @panic("cached signal expression value was requested before initialization"),
                .present => |cached| Ctx.cloneHostValue(ctx, cached.value),
            };
        }

        /// Performs update dirty signal expr cache inside the shared engine while preserving transaction and changed-set invariants.
        pub fn updateDirtySignalExprCache(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, cache_slot: *HostSignalCacheSlot, value: HostValue, cap: HostValueCapability) HostSignalEvalResult {
            switch (cache_slot.*) {
                .absent => {
                    debugPhase(ctx, .dirty_cache_initialize);
                    return .{
                        .value = self.replaceSignalExprCacheAndClone(ctx, cache_slot, roc_host, value, cap),
                        .changed = true,
                    };
                },
                .present => |*cached| {
                    debugPhase(ctx, .dirty_cache_compare);
                    const values_equal = cached.valueEquals(ctx, roc_host, value);
                    if (values_equal) {
                        debugPhase(ctx, .dirty_cache_drop_equal);
                        cached.dropIncoming(ctx, roc_host, value);
                        self.recordSignalPrune();
                        debugPhase(ctx, .dirty_cache_clone_equal);
                        return .{ .value = Ctx.cloneHostValue(ctx, cached.value), .changed = false };
                    }

                    debugPhase(ctx, .dirty_cache_replace);
                    cached.replaceValue(ctx, roc_host, value);
                    debugPhase(ctx, .dirty_cache_clone_changed);
                    return .{ .value = Ctx.cloneHostValue(ctx, cached.value), .changed = true };
                },
            }
        }

        /// Performs update dirty signal cache inside the shared engine while preserving transaction and changed-set invariants.
        pub fn updateDirtySignalCache(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, cache_slot: *HostSignalCacheSlot, value: HostValue, cap: HostValueCapability) bool {
            switch (cache_slot.*) {
                .absent => {
                    cache_slot.replace(ctx, roc_host, &self.pending_roc_metrics, value, cap);
                    return true;
                },
                .present => |*cached| {
                    const values_equal = cached.valueEquals(ctx, roc_host, value);
                    if (values_equal) {
                        cached.dropIncoming(ctx, roc_host, value);
                        self.recordSignalPrune();
                        return false;
                    }

                    cache_slot.replaceValue(ctx, roc_host, value);
                    return true;
                },
            }
        }

        /// Performs clone memoized dirty signal result inside the shared engine while preserving transaction and changed-set invariants.
        pub fn cloneMemoizedDirtySignalResult(self: *Self, ctx: Ctx.Handle, record: *HostSignalRecord, dirty_generation: u64) ?HostSignalEvalResult {
            if (record.last_dirty_generation != dirty_generation) return null;

            const cache_slot = record.cachedSlot() orelse return null;
            return .{
                .value = self.cloneCachedSignalValue(ctx, cache_slot),
                .changed = record.last_dirty_changed,
            };
        }

        /// Performs remember dirty signal result inside the shared engine while preserving transaction and changed-set invariants.
        pub fn rememberDirtySignalResult(_: *Self, record: *HostSignalRecord, dirty_generation: u64, result: HostSignalEvalResult) HostSignalEvalResult {
            record.last_dirty_generation = dirty_generation;
            record.last_dirty_changed = result.changed;
            return result;
        }

        /// Performs host signal record capability inside the shared engine while preserving transaction and changed-set invariants.
        pub fn hostSignalRecordCapability(_: *Self, ctx: Ctx.Handle, record: *const HostSignalRecord) HostValueCapability {
            return record.capability(Ctx, ctx);
        }

        /// Performs host signal binding capability inside the shared engine while preserving transaction and changed-set invariants.
        pub fn hostSignalBindingCapability(self: *Self, ctx: Ctx.Handle, signal: *const HostSignalBinding) HostValueCapability {
            return self.hostSignalRecordCapability(ctx, signal.record);
        }

        /// Performs drop host signal record value inside the shared engine while preserving transaction and changed-set invariants.
        pub fn dropHostSignalRecordValue(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, record: *const HostSignalRecord, value: HostValue) void {
            const cap = self.hostSignalRecordCapability(ctx, record);
            callHostValueToUnitWithCapability(ctx, roc_host, cap, hv.hostValueCapabilityDrop(cap), value);
        }

        /// Ensures state from desc capacity or state before publication can begin.
        pub fn ensureStateFromDesc(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, desc: HostNodeStateDesc) void {
            if (self.stateIndexByNodeId(desc.node_id) != null) return;

            const initial = erased_calls.callValueInitThunk(roc_host, desc.initial);
            var cell = HostValueCell.initRetained(initial, desc.cap, &self.pending_roc_metrics);
            const next_state = HostState{
                .state_id = desc.node_id,
                .cell = cell,
                .version = 0,
                .active = true,
            };
            const state_index = blk: {
                for (self.states.items, 0..) |state, index| {
                    if (state.active) continue;
                    self.states.items[index] = next_state;
                    break :blk index;
                }
                const index = self.states.items.len;
                self.states.append(Ctx.allocator(ctx), next_state) catch {
                    cell.deinit(ctx, roc_host, &self.pending_roc_metrics);
                    @panic("out of memory");
                };
                break :blk index;
            };
            self.recordStateCellIndex(ctx, desc.node_id, state_index);
        }

        fn signalRecordByTokenForStream(self: *Self, stream: *HostNodeDescriptorStream, token: HostSignalToken) ?*HostSignalRecord {
            if (stream.signalRecordByToken(token)) |record| return record;
            if (stream != &self.active_stream) return self.active_stream.signalRecordByToken(token);
            return null;
        }

        fn retainExistingSignalRecordForStream(self: *Self, allocator: std.mem.Allocator, stream: *HostNodeDescriptorStream, token: HostSignalToken, expected_tag: std.meta.Tag(HostSignalRecordPayload)) ?*HostSignalRecord {
            const record = self.signalRecordByTokenForStream(stream, token) orelse return null;
            validateExistingSignalRecord(record, expected_tag);
            stream.rememberSignalRecord(allocator, record);
            return record.retain();
        }

        /// Performs bind node signal expr inside the shared engine while preserving transaction and changed-set invariants.
        pub fn bindNodeSignalExpr(self: *Self, allocator: std.mem.Allocator, stream: *HostNodeDescriptorStream, expr: abi.NodeSignalExpr, binder_stack: []const HostBinderBinding) *HostSignalRecord {
            const binding = ImmediateSignalRecordCtx{ .engine = self, .allocator = allocator, .stream = stream };
            return self.bindSignalExprViewWith(ImmediateSignalRecordCtx, binding, abi_view.SignalExpr.fromAbi(expr), binder_stack) catch @panic("out of memory");
        }

        const ImmediateSignalRecordCtx = struct {
            engine: *Self,
            allocator: std.mem.Allocator,
            stream: *HostNodeDescriptorStream,

            fn retainExisting(self: @This(), token: HostSignalToken, expected_tag: std.meta.Tag(HostSignalRecordPayload)) error{OutOfMemory}!?*HostSignalRecord {
                return self.engine.retainExistingSignalRecordForStream(self.allocator, self.stream, token, expected_tag);
            }

            fn init(self: @This(), payload: HostSignalRecordPayload) error{OutOfMemory}!*HostSignalRecord {
                return HostSignalRecord.tryInit(self.allocator, payload);
            }

            fn remember(self: @This(), record: *HostSignalRecord) error{OutOfMemory}!void {
                self.stream.rememberSignalRecord(self.allocator, record);
            }
        };

        fn bindSignalExprViewWith(self: *Self, comptime Binding: type, binding: Binding, expr: abi_view.SignalExpr, binder_stack: []const HostBinderBinding) error{OutOfMemory}!*HostSignalRecord {
            const allocator = binding.allocator;
            return switch (expr) {
                .ref => |payload| blk: {
                    const token = payload.binder.callable;
                    const node_id = resolveNodeBinderRef(binder_stack, token);
                    break :blk try binding.init(.{ .ref = node_id });
                },
                .const_value => |payload| blk: {
                    const token = payload.token.callable;
                    if (try binding.retainExisting(token, .const_value)) |record| {
                        break :blk record;
                    }

                    const record = try binding.init(.{ .const_value = .{
                        .init = retainHostCallable(payload.init, &self.pending_roc_metrics),
                        .cap = retainHostValueCapability(payload.capability, &self.pending_roc_metrics),
                    } });
                    try binding.remember(record);
                    break :blk record;
                },
                .map => |payload| blk: {
                    const token = payload.token.callable;
                    if (try binding.retainExisting(token, .map)) |record| {
                        break :blk record;
                    }

                    const input = try self.bindSignalExprViewWith(Binding, binding, abi_view.SignalExpr.fromAbi(payload.input.*), binder_stack);
                    const record = try binding.init(.{ .map = .{
                        .input = input,
                        .transform = retainHostCallable(payload.transform, &self.pending_roc_metrics),
                        .cap = retainHostValueCapability(payload.capability, &self.pending_roc_metrics),
                    } });
                    try binding.remember(record);
                    break :blk record;
                },
                .map2 => |payload| blk: {
                    const token = payload.token.callable;
                    if (try binding.retainExisting(token, .map2)) |record| {
                        break :blk record;
                    }

                    const left = try self.bindSignalExprViewWith(Binding, binding, abi_view.SignalExpr.fromAbi(payload.left.*), binder_stack);
                    const right = try self.bindSignalExprViewWith(Binding, binding, abi_view.SignalExpr.fromAbi(payload.right.*), binder_stack);
                    const record = try binding.init(.{ .map2 = .{
                        .left = left,
                        .right = right,
                        .transform = retainHostCallable(payload.transform, &self.pending_roc_metrics),
                        .cap = retainHostValueCapability(payload.capability, &self.pending_roc_metrics),
                    } });
                    try binding.remember(record);
                    break :blk record;
                },
                .combine => |payload| blk: {
                    const token = payload.token.callable;
                    if (try binding.retainExisting(token, .combine)) |record| {
                        break :blk record;
                    }

                    const children = allocator.alloc(*HostSignalRecord, payload.children.len) catch @panic("out of memory");
                    for (payload.children, children) |child, *dest| {
                        dest.* = try self.bindSignalExprViewWith(Binding, binding, abi_view.SignalExpr.fromAbi(child), binder_stack);
                    }
                    const record = try binding.init(.{ .combine = .{
                        .children = children,
                        .transform = retainHostCallable(payload.transform, &self.pending_roc_metrics),
                        .cap = retainHostValueCapability(payload.capability, &self.pending_roc_metrics),
                    } });
                    try binding.remember(record);
                    break :blk record;
                },
                .task_source => |payload| blk: {
                    const token = payload.token.callable;
                    if (try binding.retainExisting(token, .task_source)) |record| {
                        break :blk record;
                    }

                    const record = try binding.init(.{ .task_source = .{
                        .name = allocator.dupe(u8, payload.name.asSlice()) catch @panic("out of memory"),
                        .payload_cap = retainHostValueCapability(payload.payload_capability, &self.pending_roc_metrics),
                        .initial = retainHostCallable(payload.initial, &self.pending_roc_metrics),
                        .done = retainHostCallable(payload.done, &self.pending_roc_metrics),
                        .failed = retainHostCallable(payload.failed, &self.pending_roc_metrics),
                        .cap = retainHostValueCapability(payload.capability, &self.pending_roc_metrics),
                        .reset_on_start = payload.reset_on_start,
                    } });
                    try binding.remember(record);
                    break :blk record;
                },
                .interval_source => |payload| blk: {
                    const token = payload.token.callable;
                    if (try binding.retainExisting(token, .interval_source)) |record| {
                        break :blk record;
                    }

                    const record = try binding.init(.{ .interval_source = .{
                        .period_ms = payload.period_ms,
                        .initial = retainHostCallable(payload.initial, &self.pending_roc_metrics),
                        .tick = retainHostCallable(payload.tick, &self.pending_roc_metrics),
                        .cap = retainHostValueCapability(payload.capability, &self.pending_roc_metrics),
                    } });
                    try binding.remember(record);
                    break :blk record;
                },
                .location_source => |payload| blk: {
                    const token = payload.token.callable;
                    if (try binding.retainExisting(token, .location_source)) |record| {
                        break :blk record;
                    }

                    const record = try binding.init(.{ .location_source = .{
                        .payload_cap = retainHostValueCapability(payload.payload_capability, &self.pending_roc_metrics),
                        .from_payload = retainHostCallable(payload.from_payload, &self.pending_roc_metrics),
                        .cap = retainHostValueCapability(payload.capability, &self.pending_roc_metrics),
                    } });
                    try binding.remember(record);
                    break :blk record;
                },
                .visibility_source => |payload| blk: {
                    const token = payload.token.callable;
                    if (try binding.retainExisting(token, .visibility_source)) |record| {
                        break :blk record;
                    }

                    const record = try binding.init(.{ .visibility_source = .{
                        .payload_cap = retainHostValueCapability(payload.payload_capability, &self.pending_roc_metrics),
                        .from_payload = retainHostCallable(payload.from_payload, &self.pending_roc_metrics),
                        .cap = retainHostValueCapability(payload.capability, &self.pending_roc_metrics),
                    } });
                    try binding.remember(record);
                    break :blk record;
                },
                .online_source => |payload| blk: {
                    const token = payload.token.callable;
                    if (try binding.retainExisting(token, .online_source)) |record| {
                        break :blk record;
                    }

                    const record = try binding.init(.{ .online_source = .{
                        .payload_cap = retainHostValueCapability(payload.payload_capability, &self.pending_roc_metrics),
                        .from_payload = retainHostCallable(payload.from_payload, &self.pending_roc_metrics),
                        .cap = retainHostValueCapability(payload.capability, &self.pending_roc_metrics),
                    } });
                    try binding.remember(record);
                    break :blk record;
                },
                .storage_source => |payload| blk: {
                    const token = payload.token.callable;
                    if (try binding.retainExisting(token, .storage_source)) |record| {
                        break :blk record;
                    }

                    const key_copy = allocator.dupe(u8, payload.key.asSlice()) catch @panic("out of memory");
                    errdefer allocator.free(key_copy);
                    const record = try binding.init(.{ .storage_source = .{
                        .area = payload.area,
                        .key = key_copy,
                        .payload_cap = retainHostValueCapability(payload.payload_capability, &self.pending_roc_metrics),
                        .from_payload = retainHostCallable(payload.from_payload, &self.pending_roc_metrics),
                        .cap = retainHostValueCapability(payload.capability, &self.pending_roc_metrics),
                    } });
                    try binding.remember(record);
                    break :blk record;
                },
            };
        }

        /// Performs bind node signal inside the shared engine while preserving transaction and changed-set invariants.
        pub fn bindNodeSignal(self: *Self, allocator: std.mem.Allocator, stream: *HostNodeDescriptorStream, expr: abi.NodeSignalExpr, binder_stack: []const HostBinderBinding) HostSignalBinding {
            const record = self.bindNodeSignalExpr(allocator, stream, expr, binder_stack);
            var source_node_ids: std.ArrayListUnmanaged(u64) = .empty;
            appendSignalRecordSourceNodeIds(allocator, &source_node_ids, record);
            return .{
                .record = record,
                .source_node_ids = source_node_ids.toOwnedSlice(allocator) catch @panic("out of memory"),
            };
        }

        /// Reads node id in scope subtree from the active descriptor stream using engine-owned identity.
        pub fn streamNodeIdInScopeSubtree(self: *Self, previous: *const HostNodeDescriptorStream, node_id: u64, root_scope_id: u64) bool {
            const descriptor_index = previous.nodeDescriptorIndex(node_id) orelse return false;
            const ScopeSiteSlot = struct {
                kind: HostNodeScopeSiteKind,
                index: ?usize,
            };
            const scope_site_slots = [_]ScopeSiteSlot{
                .{ .kind = .component, .index = descriptor_index.scope_sites.component.get() },
                .{ .kind = .state, .index = descriptor_index.scope_sites.state.get() },
                .{ .kind = .when, .index = descriptor_index.scope_sites.when.get() },
                .{ .kind = .each, .index = descriptor_index.scope_sites.each.get() },
            };
            for (scope_site_slots) |slot| {
                const site_index = slot.index orelse continue;
                if (site_index >= previous.scope_sites.items.len) @panic("scope site descriptor index exceeded descriptor table");
                const site = previous.scope_sites.items[site_index];
                if (site.node_id != node_id or site.kind != slot.kind) @panic("scope site descriptor index pointed at the wrong node");
                if (self.scopeIsDescendantOrSelf(site.scope_id, root_scope_id) catch @panic("scope descriptor referenced an unknown parent scope")) return true;
            }
            return false;
        }

        /// Returns in scope subtree for an already indexed render node.
        pub fn renderNodeInScopeSubtree(self: *Self, stream: *const HostNodeDescriptorStream, node: HostRenderNode, root_scope_id: u64) bool {
            return self.scopeIsDescendantOrSelf(renderNodeScopeId(stream, node), root_scope_id) catch @panic("scope descriptor referenced an unknown parent scope");
        }

        /// Performs first render index in scope subtree inside the shared engine while preserving transaction and changed-set invariants.
        pub fn firstRenderIndexInScopeSubtree(self: *Self, stream: *const HostNodeDescriptorStream, root_scope_id: u64) ?usize {
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_render_scope, stream.render_nodes.items.len);
            for (stream.render_nodes.items, 0..) |node, index| {
                if (self.renderNodeInScopeSubtree(stream, node, root_scope_id)) return index;
            }
            return null;
        }

        /// Returns last render end index in scope subtree retained for observability or local structural traversal.
        pub fn lastRenderEndIndexInScopeSubtree(self: *Self, stream: *const HostNodeDescriptorStream, root_scope_id: u64) ?usize {
            var end_index: ?usize = null;
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_render_scope, stream.render_nodes.items.len);
            for (stream.render_nodes.items, 0..) |node, index| {
                if (self.renderNodeInScopeSubtree(stream, node, root_scope_id)) {
                    end_index = index + 1;
                }
            }
            return end_index;
        }

        /// Evaluates scope subtree has dirty structural source using explicit scope ownership rather than DOM position or content.
        pub fn scopeSubtreeHasDirtyStructuralSource(self: *Self, previous: *const HostNodeDescriptorStream, root_scope_id: u64, dirty_source_node_ids: []const u64) bool {
            if (dirty_source_node_ids.len == 0) return false;

            self.recordStreamNodesScannedBy(.stream_nodes_scanned_dirty_scope, previous.whens.items.len);
            for (previous.whens.items) |desc| {
                if (!self.streamNodeIdInScopeSubtree(previous, desc.node_id, root_scope_id)) continue;
                if (sourceNodeIdsIntersect(desc.condition.source_node_ids, dirty_source_node_ids)) return true;
            }
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_dirty_scope, previous.eaches.items.len);
            for (previous.eaches.items) |desc| {
                if (!self.streamNodeIdInScopeSubtree(previous, desc.node_id, root_scope_id)) continue;
                if (sourceNodeIdsIntersect(desc.items.source_node_ids, dirty_source_node_ids)) return true;
            }
            return false;
        }

        /// Performs clone host signal cache slot inside the shared engine while preserving transaction and changed-set invariants.
        pub fn cloneHostSignalCacheSlot(self: *Self, ctx: Ctx.Handle, slot: HostSignalCacheSlot, metrics: anytype) HostSignalCacheSlot {
            _ = self;
            return slot.cloneRetained(ctx, metrics);
        }

        /// Performs copy active scope subtree descriptors inside the shared engine while preserving transaction and changed-set invariants.
        pub fn copyActiveScopeSubtreeDescriptors(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, stream: *HostNodeDescriptorStream, root_scope_id: u64) void {
            const allocator = Ctx.allocator(ctx);
            const previous = &self.active_stream;
            const previous_render_base = self.firstRenderIndexInScopeSubtree(previous, root_scope_id);
            const next_render_base = stream.render_nodes.items.len;
            var copied_elem_ids: std.ArrayListUnmanaged(u64) = .empty;
            defer copied_elem_ids.deinit(allocator);

            for (previous.render_nodes.items) |node| {
                const node_scope_id = renderNodeScopeId(previous, node);
                if (!(self.scopeIsDescendantOrSelf(node_scope_id, root_scope_id) catch @panic("scope descriptor referenced an unknown parent scope"))) continue;

                copied_elem_ids.append(allocator, node.elem_id) catch @panic("out of memory");
                switch (node.kind) {
                    .element => {
                        const desc = findElementDesc(previous, node.elem_id) orelse @panic("copyActiveScopeSubtreeDescriptors: render node has no matching descriptor");
                        _ = stream.appendElement(allocator, desc.elem_id, desc.parent_elem_id, desc.scope_id, desc.tag);
                    },
                    .text => {
                        const desc = findTextNodeDesc(previous, node.elem_id) orelse @panic("copyActiveScopeSubtreeDescriptors: render node has no matching descriptor");
                        stream.appendTextNode(allocator, desc.elem_id, desc.parent_elem_id, desc.scope_id, desc.value);
                    },
                    .signal_text => {
                        const desc = findSignalTextNodeDesc(previous, node.elem_id) orelse @panic("copyActiveScopeSubtreeDescriptors: render node has no matching descriptor");
                        const signal = desc.signal.cloneRetained(allocator, &self.pending_roc_metrics);
                        stream.appendSignalTextNode(allocator, ctx, roc_host, &self.pending_roc_metrics, desc.elem_id, desc.parent_elem_id, desc.scope_id, signal, desc.read);
                        stream.signal_text_nodes.items[stream.signal_text_nodes.items.len - 1].cached_value = self.cloneHostSignalCacheSlot(ctx, desc.cached_value, &self.pending_roc_metrics);
                    },
                }
            }

            for (previous.static_text_attrs.items) |desc| {
                if (!u64SliceContains(copied_elem_ids.items, desc.elem_id)) continue;
                stream.appendStaticTextAttr(allocator, desc.elem_id, desc.field, desc.value);
            }
            for (previous.signal_text_attrs.items) |desc| {
                if (!u64SliceContains(copied_elem_ids.items, desc.elem_id)) continue;
                const signal = desc.signal.cloneRetained(allocator, &self.pending_roc_metrics);
                stream.appendSignalTextAttr(allocator, ctx, roc_host, &self.pending_roc_metrics, desc.elem_id, desc.field, signal, desc.read);
                stream.signal_text_attrs.items[stream.signal_text_attrs.items.len - 1].cached_value = self.cloneHostSignalCacheSlot(ctx, desc.cached_value, &self.pending_roc_metrics);
            }
            for (previous.static_custom_text_attrs.items) |desc| {
                if (!u64SliceContains(copied_elem_ids.items, desc.elem_id)) continue;
                stream.appendStaticCustomTextAttr(allocator, desc.elem_id, desc.name, desc.value);
            }
            for (previous.signal_custom_text_attrs.items) |desc| {
                if (!u64SliceContains(copied_elem_ids.items, desc.elem_id)) continue;
                const signal = desc.signal.cloneRetained(allocator, &self.pending_roc_metrics);
                stream.appendSignalCustomTextAttr(allocator, ctx, roc_host, &self.pending_roc_metrics, desc.elem_id, desc.name, signal, desc.read);
                stream.signal_custom_text_attrs.items[stream.signal_custom_text_attrs.items.len - 1].cached_value = self.cloneHostSignalCacheSlot(ctx, desc.cached_value, &self.pending_roc_metrics);
            }
            for (previous.signal_optional_custom_text_attrs.items) |desc| {
                if (!u64SliceContains(copied_elem_ids.items, desc.elem_id)) continue;
                const signal = desc.signal.cloneRetained(allocator, &self.pending_roc_metrics);
                stream.appendSignalOptionalCustomTextAttr(allocator, ctx, roc_host, &self.pending_roc_metrics, desc.elem_id, desc.name, signal, desc.present, desc.read);
                stream.signal_optional_custom_text_attrs.items[stream.signal_optional_custom_text_attrs.items.len - 1].cached_value = self.cloneHostSignalCacheSlot(ctx, desc.cached_value, &self.pending_roc_metrics);
            }
            for (previous.static_custom_bool_attrs.items) |desc| {
                if (!u64SliceContains(copied_elem_ids.items, desc.elem_id)) continue;
                stream.appendStaticCustomBoolAttr(allocator, desc.elem_id, desc.name, desc.value);
            }
            for (previous.signal_custom_bool_attrs.items) |desc| {
                if (!u64SliceContains(copied_elem_ids.items, desc.elem_id)) continue;
                const signal = desc.signal.cloneRetained(allocator, &self.pending_roc_metrics);
                stream.appendSignalCustomBoolAttr(allocator, ctx, roc_host, &self.pending_roc_metrics, desc.elem_id, desc.name, signal, desc.read);
                stream.signal_custom_bool_attrs.items[stream.signal_custom_bool_attrs.items.len - 1].cached_value = self.cloneHostSignalCacheSlot(ctx, desc.cached_value, &self.pending_roc_metrics);
            }
            for (previous.static_bool_attrs.items) |desc| {
                if (!u64SliceContains(copied_elem_ids.items, desc.elem_id)) continue;
                stream.appendStaticBoolAttr(allocator, desc.elem_id, desc.field, desc.value);
            }
            for (previous.signal_bool_attrs.items) |desc| {
                if (!u64SliceContains(copied_elem_ids.items, desc.elem_id)) continue;
                const signal = desc.signal.cloneRetained(allocator, &self.pending_roc_metrics);
                stream.appendSignalBoolAttr(allocator, ctx, roc_host, &self.pending_roc_metrics, desc.elem_id, desc.field, signal, desc.read);
                stream.signal_bool_attrs.items[stream.signal_bool_attrs.items.len - 1].cached_value = self.cloneHostSignalCacheSlot(ctx, desc.cached_value, &self.pending_roc_metrics);
            }
            for (previous.on_changes.items) |desc| {
                if (!(self.scopeIsDescendantOrSelf(desc.scope_id, root_scope_id) catch @panic("scope descriptor referenced an unknown parent scope"))) continue;
                const signal = desc.signal.cloneRetained(allocator, &self.pending_roc_metrics);
                stream.appendOnChange(allocator, ctx, roc_host, &self.pending_roc_metrics, desc.scope_id, signal, desc.to_cmd, desc.run_initial, desc.run_initial_pending);
                stream.on_changes.items[stream.on_changes.items.len - 1].cached_value = self.cloneHostSignalCacheSlot(ctx, desc.cached_value, &self.pending_roc_metrics);
            }
            for (previous.mounts.items) |desc| {
                if (!(self.scopeIsDescendantOrSelf(desc.scope_id, root_scope_id) catch @panic("scope descriptor referenced an unknown parent scope"))) continue;
                stream.appendMount(allocator, roc_host, &self.pending_roc_metrics, desc.scope_id, desc.to_cmd, false);
            }
            for (previous.cleanups.items) |desc| {
                if (!(self.scopeIsDescendantOrSelf(desc.scope_id, root_scope_id) catch @panic("scope descriptor referenced an unknown parent scope"))) continue;
                stream.appendCleanup(allocator, desc.scope_id, desc.name);
            }
            for (previous.events.items, 0..) |desc, event_index| {
                if (!u64SliceContains(copied_elem_ids.items, desc.elem_id)) continue;
                const payload_reducer = if (desc.owns_payload_reducer) desc.payload_reducer else self.activeEventReducerByIndex(event_index) catch @panic("active event table is missing a retained payload reducer");
                switch (desc.binding) {
                    .fixed => |kind| stream.appendEvent(allocator, roc_host, &self.pending_roc_metrics, desc.elem_id, kind, desc.delivery_request, desc.binder_token, desc.target_node_id, desc.read_binder_token, desc.read_node_id, desc.payload_descriptor, payload_reducer),
                    .named => |binding| stream.appendNamedEvent(allocator, roc_host, &self.pending_roc_metrics, desc.elem_id, binding.name, binding.policy, binding.delivery_request, desc.binder_token, desc.target_node_id, desc.read_binder_token, desc.read_node_id, desc.payload_descriptor, payload_reducer),
                }
            }

            for (previous.scope_sites.items) |desc| {
                if (!(self.scopeIsDescendantOrSelf(desc.scope_id, root_scope_id) catch @panic("scope descriptor referenced an unknown parent scope"))) continue;
                const render_insert_index = if (previous_render_base) |render_base| blk: {
                    if (desc.render_insert_index < render_base) @panic("copied scope site insertion point precedes its scope subtree");
                    break :blk next_render_base + (desc.render_insert_index - render_base);
                } else next_render_base;
                stream.appendScopeSiteAt(allocator, desc.node_id, desc.scope_id, desc.ordinal, desc.parent_elem_id, render_insert_index, desc.kind, desc.binder_bindings);
            }
            for (previous.states.items) |desc| {
                if (!self.streamNodeIdInScopeSubtree(previous, desc.node_id, root_scope_id)) continue;
                stream.appendState(allocator, roc_host, &self.pending_roc_metrics, desc.node_id, desc.initial, desc.cap);
            }
            for (previous.whens.items) |desc| {
                if (!self.streamNodeIdInScopeSubtree(previous, desc.node_id, root_scope_id)) continue;
                const condition = desc.condition.cloneRetained(allocator, &self.pending_roc_metrics);
                stream.appendWhen(allocator, ctx, roc_host, &self.pending_roc_metrics, desc.node_id, condition, desc.read, desc.when_false, desc.when_true);
                stream.whens.items[stream.whens.items.len - 1].cached_value = self.cloneHostSignalCacheSlot(ctx, desc.cached_value, &self.pending_roc_metrics);
            }
            for (previous.eaches.items) |desc| {
                if (!self.streamNodeIdInScopeSubtree(previous, desc.node_id, root_scope_id)) continue;
                const items = desc.items.cloneRetained(allocator, &self.pending_roc_metrics);
                stream.appendEach(allocator, ctx, roc_host, &self.pending_roc_metrics, desc.node_id, items, desc.ops);
                stream.eaches.items[stream.eaches.items.len - 1].cached_value = self.cloneHostSignalCacheSlot(ctx, desc.cached_value, &self.pending_roc_metrics);
            }
        }

        /// Performs deinit pending task inside the shared engine while preserving transaction and changed-set invariants.
        pub fn deinitPendingTask(self: *Self, ctx: Ctx.Handle, task: *HostPendingTask) void {
            effects_runtime.deinitPendingTask(Ctx.allocator(ctx), self.roc_host.?, task);
        }

        /// Performs cancel pending task inside the shared engine while preserving transaction and changed-set invariants.
        pub fn cancelPendingTask(self: *Self, ctx: Ctx.Handle, task: *HostPendingTask) void {
            effects_runtime.cancelPendingTask(Ctx, ctx, Ctx.allocator(ctx), self.roc_host.?, task);
        }

        /// Clears pending tasks while retaining bounded storage where the type promises reuse.
        pub fn clearPendingTasks(self: *Self, ctx: Ctx.Handle) void {
            effects_runtime.clearPendingTasks(Ctx, ctx, Ctx.allocator(ctx), &self.pending_tasks, self.roc_host);
        }

        /// Performs cancel pending tasks by task token inside the shared engine while preserving transaction and changed-set invariants.
        pub fn cancelPendingTasksByTaskToken(self: *Self, ctx: Ctx.Handle, task_token: HostSignalToken) void {
            effects_runtime.cancelPendingTasksByTaskToken(Ctx, ctx, Ctx.allocator(ctx), &self.pending_tasks, self.roc_host, task_token);
        }

        /// Performs cancel pending tasks in scope subtree inside the shared engine while preserving transaction and changed-set invariants.
        pub fn cancelPendingTasksInScopeSubtree(self: *Self, ctx: Ctx.Handle, scope_id: u64) void {
            const ScopeLookup = struct {
                engine: *Self,

                /// Performs descendant or self inside the shared engine while preserving transaction and changed-set invariants.
                pub fn descendantOrSelf(self_lookup: *@This(), task_scope_id: u64, root_scope_id: u64) bool {
                    return self_lookup.engine.scopeIsDescendantOrSelf(task_scope_id, root_scope_id) catch @panic("scope descriptor referenced an unknown parent scope");
                }
            };
            var scope_lookup = ScopeLookup{ .engine = self };
            effects_runtime.cancelPendingTasksInScopeSubtree(Ctx, ctx, Ctx.allocator(ctx), &self.pending_tasks, self.roc_host, scope_id, &scope_lookup);
        }

        /// Appends cleanup event using capacity that must already satisfy the caller's transaction contract.
        pub fn appendCleanupEvent(self: *Self, ctx: Ctx.Handle, name: []const u8) void {
            effects_runtime.appendCleanupEvent(Ctx.allocator(ctx), &self.cleanup_events, name);
        }

        /// Performs dispose scope subtree inside the shared engine while preserving transaction and changed-set invariants.
        pub fn disposeScopeSubtree(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, scope_id: u64) void {
            var disposal = ScopeDisposal{ .engine = self, .ctx = ctx, .roc_host = roc_host };
            scope_runtime.disposeSubtree(HostEachRowScopeStep, self.scopes.items, scope_id, self.identity_reuse_barrier, &disposal);
        }

        /// Performs create each row scope inside the shared engine while preserving transaction and changed-set invariants.
        pub fn createEachRowScope(self: *Self, ctx: Ctx.Handle, parent_scope_id: u64, site_ordinal: u64, key_hash: u64, key: HostValue, item: HostValue, key_cap: HostValueCapability, item_cap: HostValueCapability) u64 {
            self.validateScopeId(parent_scope_id) catch @panic("scope id has no host scope descriptor");

            const result = if (self.has_inactive_scopes)
                scope_runtime.appendEachRow(Ctx.allocator(ctx), &self.scopes, parent_scope_id, site_ordinal, key_hash, key, item, key_cap, item_cap, &self.pending_roc_metrics, self.identity_reuse_barrier) catch @panic("scope id has no host scope descriptor")
            else
                scope_runtime.appendFreshEachRow(Ctx.allocator(ctx), &self.scopes, parent_scope_id, site_ordinal, key_hash, key, item, key_cap, item_cap, &self.pending_roc_metrics) catch @panic("scope id has no host scope descriptor");
            self.recordScopeCreated();
            const site_index = self.ensureEachRowSiteIndex(Ctx.allocator(ctx), parent_scope_id, site_ordinal);
            self.appendEachRowToSiteIndex(Ctx.allocator(ctx), site_index, result.scope_id, key_hash);
            return result.scope_id;
        }

        /// Performs each row scope item equals inside the shared engine while preserving transaction and changed-set invariants.
        pub fn eachRowScopeItemEquals(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, scope_id: u64, item: HostValue, item_cap: HostValueCapability) bool {
            self.recordEachItemCompare();
            return scope_runtime.eachRowItemEquals(self.scopes.items, ctx, roc_host, scope_id, item, item_cap);
        }

        /// Replaces each row scope key while releasing displaced ownership exactly once.
        pub fn replaceEachRowScopeKey(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, scope_id: u64, key_hash: u64, key: HostValue, key_cap: HostValueCapability) void {
            scope_runtime.replaceEachRowKey(self.scopes.items, ctx, roc_host, &self.pending_roc_metrics, scope_id, key_hash, key, key_cap);
        }

        /// Replaces each row scope item with capability while releasing displaced ownership exactly once.
        pub fn replaceEachRowScopeItemWithCapability(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, scope_id: u64, item: HostValue, item_cap: HostValueCapability) void {
            scope_runtime.replaceEachRowItem(self.scopes.items, ctx, roc_host, &self.pending_roc_metrics, scope_id, item, item_cap);
        }

        /// Performs each row scope values inside the shared engine while preserving transaction and changed-set invariants.
        pub fn eachRowScopeValues(self: *Self, scope_id: u64) EachRowValues {
            return scope_runtime.eachRowValues(self.scopes.items, scope_id);
        }

        /// Performs sync each row scopes inside the shared engine while preserving transaction and changed-set invariants.
        pub fn syncEachRowScopes(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, parent_scope_id: u64, site_ordinal: u64, keys: []const HostValue, items: []const HostValue, ops: HostEachOps) HostKeyedRowDiffResult {
            self.validateScopeId(parent_scope_id) catch @panic("scope id has no host scope descriptor");
            const allocator = Ctx.allocator(ctx);
            const site_index = self.ensureEachRowSiteIndex(allocator, parent_scope_id, site_ordinal);
            var sync = EachRowSync{ .engine = self, .ctx = ctx, .roc_host = roc_host, .ops = ops };
            return each_runtime.syncRows(allocator, &self.each_row_sites, &self.each_row_memberships_by_scope_id, site_index, parent_scope_id, site_ordinal, keys, items, &sync);
        }

        /// Performs sync active each row scopes inside the shared engine while preserving transaction and changed-set invariants.
        pub fn syncActiveEachRowScopes(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, site: HostNodeScopeSiteDesc, each: HostNodeEachDesc) HostKeyedRowDiffResult {
            if (site.kind != .each) {
                @panic("active row sync requires an each scope site");
            }
            if (site.node_id != each.node_id) {
                @panic("active row sync received mismatched each descriptors");
            }

            const allocator = Ctx.allocator(ctx);
            const items_value = self.cloneCachedSignalValue(ctx, &each.cached_value);
            const items_cap = self.hostSignalBindingCapability(ctx, &each.items);
            assertHostValueCapabilitiesMatch(each.ops.items_capability, items_cap, "each items extension capability did not match its signal value");
            defer callHostValueToUnitWithCapability(ctx, roc_host, items_cap, hv.hostValueCapabilityDrop(items_cap), items_value);

            const items = callHostValueToHostValueListWithCapability(ctx, roc_host, each.ops.items_capability, each.ops.items_to_values, items_value);
            defer items.decref(roc_host);
            const item_values = items.items();

            const keys = allocator.alloc(HostValue, item_values.len) catch @panic("out of memory");
            defer allocator.free(keys);

            for (item_values, 0..) |item, index| {
                keys[index] = callHostValueToHostValueWithCapability(ctx, roc_host, each.ops.item_capability, each.ops.key_of, item);
            }

            return self.syncEachRowScopes(ctx, roc_host, site.scope_id, site.ordinal, keys, item_values, each.ops);
        }

        /// Collects node attr descriptor from the explicitly affected graph or scope set.
        pub fn collectNodeAttrDescriptor(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, stream: *HostNodeDescriptorStream, elem_id: u64, attr: abi.NodeAttr, binder_stack: []const HostBinderBinding) void {
            const allocator = Ctx.allocator(ctx);
            switch (abi_view.NodeAttr.fromAbi(attr)) {
                .static_text => |payload| {
                    switch (payload.target) {
                        .fixed => |field| stream.appendStaticTextAttr(allocator, elem_id, field, payload.value.asSlice()),
                        .custom => |name| stream.appendStaticCustomTextAttr(allocator, elem_id, name.asSlice(), payload.value.asSlice()),
                    }
                },
                .signal_text => |payload| {
                    switch (payload.target) {
                        .fixed => |field| {
                            const signal = self.bindNodeSignal(allocator, stream, payload.signal.*, binder_stack);
                            stream.appendSignalTextAttr(allocator, ctx, roc_host, &self.pending_roc_metrics, elem_id, field, signal, payload.read);
                        },
                        .custom => |name| {
                            const name_slice = name.asSlice();
                            if (stream.customTextAttrDescriptorExists(elem_id, name_slice)) @panic("element has duplicate custom text attr descriptors");
                            const signal = self.bindNodeSignal(allocator, stream, payload.signal.*, binder_stack);
                            stream.appendSignalCustomTextAttr(allocator, ctx, roc_host, &self.pending_roc_metrics, elem_id, name_slice, signal, payload.read);
                        },
                    }
                },
                .signal_optional_text => |payload| {
                    switch (payload.target) {
                        .fixed => @panic("optional text attr descriptors require a custom attr name"),
                        .custom => |name| {
                            const name_slice = name.asSlice();
                            if (stream.customTextAttrDescriptorExists(elem_id, name_slice)) @panic("element has duplicate custom text attr descriptors");
                            const signal = self.bindNodeSignal(allocator, stream, payload.signal.*, binder_stack);
                            stream.appendSignalOptionalCustomTextAttr(allocator, ctx, roc_host, &self.pending_roc_metrics, elem_id, name_slice, signal, payload.present, payload.read);
                        },
                    }
                },
                .static_bool => |payload| {
                    switch (payload.target) {
                        .fixed => |field| stream.appendStaticBoolAttr(allocator, elem_id, field, payload.value),
                        .custom => |name| stream.appendStaticCustomBoolAttr(allocator, elem_id, name.asSlice(), payload.value),
                    }
                },
                .signal_bool => |payload| {
                    switch (payload.target) {
                        .fixed => |field| {
                            const signal = self.bindNodeSignal(allocator, stream, payload.signal.*, binder_stack);
                            stream.appendSignalBoolAttr(allocator, ctx, roc_host, &self.pending_roc_metrics, elem_id, field, signal, payload.read);
                        },
                        .custom => |name| {
                            const name_slice = name.asSlice();
                            if (stream.customTextAttrDescriptorExists(elem_id, name_slice)) @panic("element has duplicate custom bool attr descriptors");
                            const signal = self.bindNodeSignal(allocator, stream, payload.signal.*, binder_stack);
                            stream.appendSignalCustomBoolAttr(allocator, ctx, roc_host, &self.pending_roc_metrics, elem_id, name_slice, signal, payload.read);
                        },
                    }
                },
                .event => |payload| {
                    const binder_token = payload.msg.binder.callable;
                    const target_node_id = resolveNodeBinderRef(binder_stack, binder_token);
                    const read_binder_token = payload.msg.read_binder.callable;
                    const read_node_id = resolveNodeBinderRef(binder_stack, read_binder_token);
                    stream.appendEvent(allocator, roc_host, &self.pending_roc_metrics, elem_id, payload.kind, payload.delivery_request, binder_token, target_node_id, read_binder_token, read_node_id, payload.msg.payload_descriptor, payload.msg.payload_reducer);
                },
                .named_event => |payload| {
                    const binder_token = payload.msg.binder.callable;
                    const target_node_id = resolveNodeBinderRef(binder_stack, binder_token);
                    const read_binder_token = payload.msg.read_binder.callable;
                    const read_node_id = resolveNodeBinderRef(binder_stack, read_binder_token);
                    stream.appendNamedEvent(allocator, roc_host, &self.pending_roc_metrics, elem_id, payload.name.asSlice(), payload.policy, payload.delivery_request, binder_token, target_node_id, read_binder_token, read_node_id, payload.msg.payload_descriptor, payload.msg.payload_reducer);
                },
            }
        }

        /// Collects active when branch descriptors from the explicitly affected graph or scope set.
        pub fn collectActiveWhenBranchDescriptors(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, stream: *HostNodeDescriptorStream, site: HostNodeScopeSiteDesc, when: HostNodeWhenDesc, active_branch: HostScopeBranch, dirty_source_node_ids: []const u64) u64 {
            if (site.kind != .when) {
                @panic("active branch collection requires a when scope site");
            }
            if (site.node_id != when.node_id) {
                @panic("active branch collection received mismatched when descriptors");
            }

            if (self.activeWhenBranchScopeId(site.scope_id, site.ordinal, active_branch.opposite()) catch @panic("scope id has no host scope descriptor")) |inactive_scope_id| {
                self.disposeScopeSubtree(ctx, roc_host, inactive_scope_id);
            }

            const branch_scope = self.internWhenBranchScope(Ctx.allocator(ctx), site.scope_id, site.ordinal, active_branch) catch @panic("scope id has no host scope descriptor");
            const branch_scope_id = branch_scope.scope_id;
            const allocator = Ctx.allocator(ctx);
            const binder_stack = self.scratchBinderStack(allocator, site.binder_bindings);
            defer self.scratch.binder_stack.clearRetainingCapacity();

            const branch_elem = switch (active_branch) {
                .true_branch => when.when_true,
                .false_branch => when.when_false,
            };
            var ordinal: u64 = 0;
            var dom_ordinal: u64 = 0;
            self.collectActiveElemDescriptors(ctx, roc_host, stream, branch_elem, branch_scope_id, site.parent_elem_id, &ordinal, &dom_ordinal, binder_stack, branch_scope.created, dirty_source_node_ids);
            return branch_scope_id;
        }

        /// Collects active each row descriptors from the explicitly affected graph or scope set.
        pub fn collectActiveEachRowDescriptors(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, stream: *HostNodeDescriptorStream, site: HostNodeScopeSiteDesc, each: HostNodeEachDesc, dirty_source_node_ids: []const u64) void {
            const allocator = Ctx.allocator(ctx);
            const diff = self.syncActiveEachRowScopes(ctx, roc_host, site, each);
            defer diff.deinit(allocator);
            self.collectActiveEachRowDescriptorsFromDiff(ctx, roc_host, stream, site, each, diff, dirty_source_node_ids);
        }

        /// Collects active each row descriptors from diff from the explicitly affected graph or scope set.
        pub fn collectActiveEachRowDescriptorsFromDiff(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, stream: *HostNodeDescriptorStream, site: HostNodeScopeSiteDesc, each: HostNodeEachDesc, diff: HostKeyedRowDiffResult, dirty_source_node_ids: []const u64) void {
            const allocator = Ctx.allocator(ctx);
            const binder_stack = self.scratchBinderStack(allocator, site.binder_bindings);
            defer self.scratch.binder_stack.clearRetainingCapacity();

            for (diff.scope_ids, diff.row_items_changed, diff.scope_created) |row_scope_id, row_item_changed, row_created| {
                if (!row_item_changed and !self.scopeSubtreeHasDirtyStructuralSource(&self.active_stream, row_scope_id, dirty_source_node_ids)) {
                    self.copyActiveScopeSubtreeDescriptors(ctx, roc_host, stream, row_scope_id);
                    continue;
                }

                const row_values = self.eachRowScopeValues(row_scope_id);
                const row_elem = callHostValueHostValueToElemWithCapabilities(ctx, roc_host, each.ops.key_capability, each.ops.item_capability, each.ops.row, row_values.key, row_values.item);
                defer row_elem.decref(roc_host);

                var ordinal: u64 = 0;
                var dom_ordinal: u64 = 0;
                self.collectActiveEachRowElemDescriptors(ctx, roc_host, stream, each, row_elem, row_scope_id, site.parent_elem_id, &ordinal, &dom_ordinal, binder_stack, row_created, dirty_source_node_ids);
            }
        }

        /// Collects active each single row descriptors from the explicitly affected graph or scope set.
        pub fn collectActiveEachSingleRowDescriptors(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, stream: *HostNodeDescriptorStream, site: HostNodeScopeSiteDesc, each: HostNodeEachDesc, row_scope_id: u64, row_created: bool, dirty_source_node_ids: []const u64) void {
            const allocator = Ctx.allocator(ctx);
            const binder_stack = self.scratchBinderStack(allocator, site.binder_bindings);
            defer self.scratch.binder_stack.clearRetainingCapacity();

            const row_values = self.eachRowScopeValues(row_scope_id);
            const row_elem = callHostValueHostValueToElemWithCapabilities(ctx, roc_host, each.ops.key_capability, each.ops.item_capability, each.ops.row, row_values.key, row_values.item);
            defer row_elem.decref(roc_host);

            var ordinal: u64 = 0;
            var dom_ordinal: u64 = 0;
            self.collectActiveEachRowElemDescriptors(ctx, roc_host, stream, each, row_elem, row_scope_id, site.parent_elem_id, &ordinal, &dom_ordinal, binder_stack, row_created, dirty_source_node_ids);
        }

        const CollectionError = error{ OutOfMemory, ResourceLimit };
        const WhenCollection = struct { scope: scope_tree.InternResult, branch: HostScopeBranch };

        fn collectActiveEachRowElemDescriptorsWith(self: *Self, comptime Collection: type, collection: Collection, ctx: Ctx.Handle, roc_host: *abi.RocHost, stream: *HostNodeDescriptorStream, each: HostNodeEachDesc, row_elem: abi.Elem, row_scope_id: u64, parent_elem_id: u64, ordinal: *u64, dom_ordinal: *u64, binder_stack: *std.ArrayListUnmanaged(HostBinderBinding), row_created: bool, dirty_source_node_ids: []const u64) CollectionError!void {
            const caps = [_]HostValueCapability{ each.ops.key_capability, each.ops.item_capability };
            Ctx.pushHostValueCapabilities(ctx, &caps);
            defer Ctx.popHostValueCapabilities(ctx);
            try self.collectActiveElemDescriptorsWith(Collection, collection, ctx, roc_host, stream, row_elem, row_scope_id, parent_elem_id, ordinal, dom_ordinal, binder_stack, row_created, dirty_source_node_ids);
        }

        fn collectActiveEachRowElemDescriptors(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, stream: *HostNodeDescriptorStream, each: HostNodeEachDesc, row_elem: abi.Elem, row_scope_id: u64, parent_elem_id: u64, ordinal: *u64, dom_ordinal: *u64, binder_stack: *std.ArrayListUnmanaged(HostBinderBinding), row_created: bool, dirty_source_node_ids: []const u64) void {
            const collection = ImmediateCollectionCtx{ .engine = self, .host_ctx = ctx, .stream = stream };
            self.collectActiveEachRowElemDescriptorsWith(ImmediateCollectionCtx, collection, ctx, roc_host, stream, each, row_elem, row_scope_id, parent_elem_id, ordinal, dom_ordinal, binder_stack, row_created, dirty_source_node_ids) catch @panic("immediate descriptor collection failed");
        }

        const ImmediateCollectionCtx = struct {
            engine: *Self,
            host_ctx: Ctx.Handle,
            stream: *HostNodeDescriptorStream,

            fn validateScope(self: @This(), scope_id: u64) CollectionError!void {
                self.engine.validateScopeId(scope_id) catch @panic("scope id has no host scope descriptor");
            }

            fn rootScope(self: @This()) CollectionError!scope_tree.InternResult {
                return self.engine.internRootScope(Ctx.allocator(self.host_ctx)) catch @panic("scope id has no host scope descriptor");
            }

            fn appendElement(self: @This(), scope_id: u64, parent_elem_id: u64, dom_ordinal: *u64, tag: []const u8) CollectionError!u64 {
                const elem_id = self.engine.internDomIdentity(Ctx.allocator(self.host_ctx), scope_id, dom_ordinal.*) catch @panic("scope id has no host scope descriptor");
                dom_ordinal.* += 1;
                _ = self.stream.appendElement(Ctx.allocator(self.host_ctx), elem_id, parent_elem_id, scope_id, tag);
                return elem_id;
            }

            fn appendText(self: @This(), scope_id: u64, parent_elem_id: u64, dom_ordinal: *u64, text: []const u8) CollectionError!void {
                const elem_id = self.engine.internDomIdentity(Ctx.allocator(self.host_ctx), scope_id, dom_ordinal.*) catch @panic("scope id has no host scope descriptor");
                dom_ordinal.* += 1;
                self.stream.appendTextNode(Ctx.allocator(self.host_ctx), elem_id, parent_elem_id, scope_id, text);
            }

            fn appendSignalText(self: @This(), roc_host: *abi.RocHost, scope_id: u64, parent_elem_id: u64, dom_ordinal: *u64, payload: abi_view.TextSignalElem, binder_stack: []const HostBinderBinding) CollectionError!void {
                const allocator = Ctx.allocator(self.host_ctx);
                const elem_id = self.engine.internDomIdentity(allocator, scope_id, dom_ordinal.*) catch @panic("scope id has no host scope descriptor");
                dom_ordinal.* += 1;
                const signal = self.engine.bindNodeSignal(allocator, self.stream, payload.signal.*, binder_stack);
                self.stream.appendSignalTextNode(allocator, self.host_ctx, roc_host, &self.engine.pending_roc_metrics, elem_id, parent_elem_id, scope_id, signal, payload.read);
            }

            fn appendAttr(self: @This(), roc_host: *abi.RocHost, elem_id: u64, attr: abi.NodeAttr, binder_stack: []const HostBinderBinding) CollectionError!void {
                self.engine.collectNodeAttrDescriptor(self.host_ctx, roc_host, self.stream, elem_id, attr, binder_stack);
            }

            fn appendCleanup(self: @This(), _: *abi.RocHost, scope_id: u64, name: []const u8) CollectionError!void {
                self.stream.appendCleanup(Ctx.allocator(self.host_ctx), scope_id, name);
            }

            fn appendMount(self: @This(), roc_host: *abi.RocHost, scope_id: u64, to_cmd: abi.RocErasedCallable, run_on_mount: bool) CollectionError!void {
                self.stream.appendMount(Ctx.allocator(self.host_ctx), roc_host, &self.engine.pending_roc_metrics, scope_id, to_cmd, run_on_mount);
            }

            fn appendOnChange(self: @This(), roc_host: *abi.RocHost, scope_id: u64, payload: abi_view.OnChangeElem, binder_stack: []const HostBinderBinding, scope_created: bool) CollectionError!void {
                const allocator = Ctx.allocator(self.host_ctx);
                const signal = self.engine.bindNodeSignal(allocator, self.stream, payload.signal.*, binder_stack);
                self.stream.appendOnChange(allocator, self.host_ctx, roc_host, &self.engine.pending_roc_metrics, scope_id, signal, payload.to_cmd, payload.run_initial, payload.run_initial and scope_created);
            }

            fn beginState(self: @This(), roc_host: *abi.RocHost, scope_id: u64, parent_elem_id: u64, ordinal: *u64, binder_stack: *std.ArrayListUnmanaged(HostBinderBinding), state: abi_view.StateElem) CollectionError!HostBinderBinding {
                const allocator = Ctx.allocator(self.host_ctx);
                binder_stack.ensureUnusedCapacity(allocator, 1) catch @panic("out of memory");
                const site_ordinal = ordinal.*;
                const node_id = self.engine.internNodeIdentity(allocator, scope_id, site_ordinal) catch @panic("scope id has no host scope descriptor");
                ordinal.* += 1;
                self.stream.appendScopeSite(allocator, node_id, scope_id, site_ordinal, parent_elem_id, .state, binder_stack.items);
                self.stream.appendState(allocator, roc_host, &self.engine.pending_roc_metrics, node_id, state.initial, state.capability);
                self.engine.ensureStateFromDesc(self.host_ctx, roc_host, self.stream.states.items[self.stream.states.items.len - 1]);
                return .{ .token = state.binder.callable, .node_id = node_id };
            }

            fn beginComponent(self: @This(), scope_id: u64, parent_elem_id: u64, ordinal: *u64, binder_stack: []const HostBinderBinding) CollectionError!scope_tree.InternResult {
                const allocator = Ctx.allocator(self.host_ctx);
                const site_ordinal = ordinal.*;
                const node_id = self.engine.internNodeIdentity(allocator, scope_id, site_ordinal) catch @panic("scope id has no host scope descriptor");
                ordinal.* += 1;
                self.stream.appendScopeSite(allocator, node_id, scope_id, site_ordinal, parent_elem_id, .component, binder_stack);
                return self.engine.internComponentScope(allocator, scope_id, site_ordinal) catch @panic("scope id has no host scope descriptor");
            }

            fn beginWhen(self: @This(), roc_host: *abi.RocHost, scope_id: u64, parent_elem_id: u64, ordinal: *u64, binder_stack: []const HostBinderBinding, payload: abi_view.WhenElem) CollectionError!WhenCollection {
                const allocator = Ctx.allocator(self.host_ctx);
                const site_ordinal = ordinal.*;
                const node_id = self.engine.internNodeIdentity(allocator, scope_id, site_ordinal) catch @panic("scope id has no host scope descriptor");
                ordinal.* += 1;
                self.stream.appendScopeSite(allocator, node_id, scope_id, site_ordinal, parent_elem_id, .when, binder_stack);
                const condition_binding = self.engine.bindNodeSignal(allocator, self.stream, payload.condition.*, binder_stack);
                self.stream.appendWhen(allocator, self.host_ctx, roc_host, &self.engine.pending_roc_metrics, node_id, condition_binding, payload.read, payload.when_false.*, payload.when_true.*);
                const desc = &self.stream.whens.items[self.stream.whens.items.len - 1];
                const condition = self.engine.evalHostSignalBinding(self.host_ctx, roc_host, &desc.condition);
                const cap = self.engine.hostSignalBindingCapability(self.host_ctx, &desc.condition);
                assertHostValueCapabilitiesMatch(desc.read.capability, cap, "when read extension capability did not match its signal value");
                const branch: HostScopeBranch = if (callHostValueToBoolWithCapability(self.host_ctx, roc_host, desc.read.capability, desc.read.read, condition)) .true_branch else .false_branch;
                desc.cached_value.replace(self.host_ctx, roc_host, &self.engine.pending_roc_metrics, condition, cap);
                if (self.engine.activeWhenBranchScopeId(scope_id, site_ordinal, branch.opposite()) catch @panic("scope id has no host scope descriptor")) |inactive| self.engine.disposeScopeSubtree(self.host_ctx, roc_host, inactive);
                return .{ .scope = self.engine.internWhenBranchScope(allocator, scope_id, site_ordinal, branch) catch @panic("scope id has no host scope descriptor"), .branch = branch };
            }
        };

        const StagedCollectionCtx = struct {
            const Collection = @This();
            const PreparedRenderNode = union(enum) {
                static: usize,
                signal: usize,
            };
            engine: *Self,
            host_ctx: Ctx.Handle,
            stream: *HostNodeDescriptorStream,
            budget: collection_budget.StreamBudget,
            scopes: collection_plan.ScopeOverlay = .{},
            node_identities: collection_plan.IdentityOverlay = .{},
            dom_identities: collection_plan.IdentityOverlay = .{},
            prepared_nodes: std.ArrayListUnmanaged(HostNodeDescriptorStream.PreparedStaticNode) = .empty,
            prepared_render_order: std.ArrayListUnmanaged(PreparedRenderNode) = .empty,
            prepared_attrs: std.ArrayListUnmanaged(HostNodeDescriptorStream.PreparedStaticAttr) = .empty,
            prepared_signal_attrs: std.ArrayListUnmanaged(HostNodeDescriptorStream.PreparedSignalDescriptor) = .empty,
            prepared_events: std.ArrayListUnmanaged(HostNodeDescriptorStream.PreparedEventDescriptor) = .empty,
            prepared_lifecycle: std.ArrayListUnmanaged(HostNodeDescriptorStream.PreparedLifecycleDescriptor) = .empty,
            prepared_state_sites: std.ArrayListUnmanaged(HostNodeDescriptorStream.PreparedScopeSite) = .empty,
            prepared_states: std.ArrayListUnmanaged(HostNodeDescriptorStream.PreparedState) = .empty,
            prepared_state_cells: std.ArrayListUnmanaged(HostState) = .empty,
            prepared_whens: std.ArrayListUnmanaged(HostNodeDescriptorStream.PreparedWhen) = .empty,
            prepared_named_event_groups: std.ArrayListUnmanaged(HostNodeDescriptorStream.PreparedNamedEventIndexGroup) = .empty,
            prepared_named_event_group_by_elem: std.AutoHashMapUnmanaged(u64, usize) = .empty,
            signal_records: collection_plan.SignalRecordPlan(HostSignalToken, HostSignalRecord) = .{},
            signal_bindings: std.ArrayListUnmanaged(HostSignalBinding) = .empty,
            signal_roc_host: ?*abi.RocHost = null,
            signal_token_capacity: usize = 0,
            signal_root_capacity: usize = 0,
            stream_materialized: bool = false,
            committed: bool = false,

            fn init(engine_ptr: *Self, host_ctx: Ctx.Handle, stream: *HostNodeDescriptorStream, limits: collection_budget.Limits, expected_nodes: usize, expected_attrs: usize, expected_lifecycle: usize, expected_signal_records: usize, expected_state_sites: usize, expected_component_sites: usize, expected_when_sites: usize, expected_external_scopes: usize) CollectionError!@This() {
                var self = @This(){
                    .engine = engine_ptr,
                    .host_ctx = host_ctx,
                    .stream = stream,
                    .budget = collection_budget.StreamBudget.init(limits) catch return error.ResourceLimit,
                };
                errdefer self.deinit();
                const allocator = Ctx.allocator(host_ctx);
                const expected_state_component_sites = std.math.add(usize, expected_state_sites, expected_component_sites) catch return error.ResourceLimit;
                const attr_lifecycle_roots = std.math.add(usize, expected_attrs, expected_lifecycle) catch return error.ResourceLimit;
                // Every descriptor root contains at least one signal record.
                // The record count therefore also bounds roots that are not
                // attributes or lifecycle entries, such as when conditions
                // and signal-backed text nodes.
                const expected_signal_roots = @max(attr_lifecycle_roots, expected_signal_records);
                const expected_scope_sites = std.math.add(usize, expected_state_component_sites, expected_when_sites) catch return error.ResourceLimit;
                const expected_child_scopes = std.math.add(usize, expected_component_sites, expected_when_sites) catch return error.ResourceLimit;
                const expected_scope_intents = std.math.add(usize, expected_external_scopes, expected_child_scopes) catch return error.ResourceLimit;
                self.scopes.prepare(allocator, expected_scope_intents) catch return error.OutOfMemory;
                self.node_identities.prepare(allocator, expected_scope_sites) catch return error.OutOfMemory;
                if (expected_nodes > limits.nodes) return error.ResourceLimit;
                self.dom_identities.prepare(allocator, expected_nodes) catch return error.OutOfMemory;
                self.prepared_nodes.ensureTotalCapacity(allocator, expected_nodes) catch return error.OutOfMemory;
                self.prepared_render_order.ensureTotalCapacity(allocator, expected_nodes) catch return error.OutOfMemory;
                self.prepared_attrs.ensureTotalCapacity(allocator, expected_attrs) catch return error.OutOfMemory;
                const expected_signal_descriptors = std.math.add(usize, expected_attrs, expected_nodes) catch return error.ResourceLimit;
                self.prepared_signal_attrs.ensureTotalCapacity(allocator, expected_signal_descriptors) catch return error.OutOfMemory;
                self.prepared_events.ensureTotalCapacity(allocator, expected_attrs) catch return error.OutOfMemory;
                self.prepared_lifecycle.ensureTotalCapacity(allocator, expected_lifecycle) catch return error.OutOfMemory;
                self.stream.reservePreparedLifecycle(allocator, expected_lifecycle) catch return error.OutOfMemory;
                self.prepared_state_sites.ensureTotalCapacity(allocator, expected_scope_sites) catch return error.OutOfMemory;
                self.prepared_states.ensureTotalCapacity(allocator, expected_state_sites) catch return error.OutOfMemory;
                self.prepared_state_cells.ensureTotalCapacity(allocator, expected_state_sites) catch return error.OutOfMemory;
                self.prepared_whens.ensureTotalCapacity(allocator, expected_when_sites) catch return error.OutOfMemory;
                self.prepared_named_event_groups.ensureTotalCapacity(allocator, expected_attrs) catch return error.OutOfMemory;
                const expected_event_groups = std.math.cast(u32, expected_attrs) orelse return error.ResourceLimit;
                self.prepared_named_event_group_by_elem.ensureTotalCapacity(allocator, expected_event_groups) catch return error.OutOfMemory;
                self.signal_records.prepare(allocator, expected_signal_records, expected_signal_roots) catch return error.OutOfMemory;
                self.signal_bindings.ensureTotalCapacity(allocator, expected_signal_roots) catch return error.OutOfMemory;
                self.signal_token_capacity = expected_signal_records;
                self.signal_root_capacity = expected_signal_roots;
                self.engine.scopes.ensureUnusedCapacity(allocator, expected_scope_intents) catch return error.OutOfMemory;
                self.engine.node_identities.ensureUnusedCapacity(allocator, expected_scope_sites) catch return error.OutOfMemory;
                self.engine.active_node_identity_ids.ensureUnusedCapacity(allocator, std.math.cast(u32, expected_scope_sites) orelse return error.ResourceLimit) catch return error.OutOfMemory;
                self.engine.states.ensureUnusedCapacity(allocator, expected_state_sites) catch return error.OutOfMemory;
                const state_index_len = std.math.add(usize, self.engine.node_identities.items.len, expected_scope_sites) catch return error.ResourceLimit;
                self.engine.state_indexes_by_node_id.ensureTotalCapacity(allocator, state_index_len) catch return error.OutOfMemory;
                self.engine.dom_identities.ensureUnusedCapacity(allocator, expected_nodes) catch return error.OutOfMemory;
                self.engine.active_dom_identity_ids.ensureUnusedCapacity(allocator, @intCast(expected_nodes)) catch return error.OutOfMemory;
                const highest_elem_id = std.math.add(u64, @intCast(self.engine.dom_identities.items.len), @as(u64, @intCast(expected_nodes))) catch return error.ResourceLimit;
                self.stream.reservePreparedStaticNodes(allocator, expected_nodes, highest_elem_id) catch return error.OutOfMemory;
                self.stream.reservePreparedStaticAttrs(allocator, expected_attrs) catch return error.OutOfMemory;
                self.stream.reservePreparedSignalAttrs(allocator, expected_attrs, highest_elem_id) catch return error.OutOfMemory;
                self.stream.reservePreparedSignalTextNodes(allocator, expected_nodes, highest_elem_id) catch return error.OutOfMemory;
                self.stream.reservePreparedSignalRecordPublication(allocator, expected_signal_records) catch return error.OutOfMemory;
                self.stream.reservePreparedEvents(allocator, expected_attrs, highest_elem_id) catch return error.OutOfMemory;
                self.stream.reservePreparedCustomAttrIndex(allocator, expected_attrs) catch return error.OutOfMemory;
                if (expected_scope_sites != 0) {
                    const highest_node_id = std.math.sub(usize, state_index_len, 1) catch return error.ResourceLimit;
                    self.stream.reservePreparedStateSites(allocator, expected_scope_sites, @intCast(highest_node_id)) catch return error.OutOfMemory;
                    self.stream.reservePreparedWhens(allocator, expected_when_sites, @intCast(highest_node_id)) catch return error.OutOfMemory;
                }
                return self;
            }

            fn deinit(self: *@This()) void {
                const allocator = Ctx.allocator(self.host_ctx);
                if (!self.committed) {
                    var index = self.prepared_nodes.items.len;
                    if (!self.stream_materialized) {
                        while (index != 0) {
                            index -= 1;
                            self.prepared_nodes.items[index].abort(allocator);
                        }
                        index = self.prepared_events.items.len;
                        while (index != 0) {
                            index -= 1;
                            self.prepared_events.items[index].abort(allocator, self.signal_roc_host orelse @panic("staged event lacked Roc host"), &self.engine.pending_roc_metrics);
                        }
                        index = self.prepared_named_event_groups.items.len;
                        while (index != 0) {
                            index -= 1;
                            self.prepared_named_event_groups.items[index].abort(allocator);
                        }
                        index = self.prepared_lifecycle.items.len;
                        while (index != 0) {
                            index -= 1;
                            self.prepared_lifecycle.items[index].abort(allocator, self.host_ctx, self.signal_roc_host orelse @panic("staged lifecycle descriptor lacked Roc host"), &self.engine.pending_roc_metrics);
                        }
                    }
                    index = self.prepared_state_cells.items.len;
                    while (index != 0) {
                        index -= 1;
                        self.prepared_state_cells.items[index].cell.deinit(self.host_ctx, self.signal_roc_host orelse @panic("staged state lacked Roc host"), &self.engine.pending_roc_metrics);
                    }
                    if (!self.stream_materialized) {
                        index = self.prepared_states.items.len;
                        while (index != 0) {
                            index -= 1;
                            self.prepared_states.items[index].abort(self.signal_roc_host orelse @panic("staged state lacked Roc host"), &self.engine.pending_roc_metrics);
                        }
                        index = self.prepared_state_sites.items.len;
                        while (index != 0) {
                            index -= 1;
                            self.prepared_state_sites.items[index].abort(allocator);
                        }
                        index = self.prepared_whens.items.len;
                        while (index != 0) {
                            index -= 1;
                            self.prepared_whens.items[index].abort(allocator, self.host_ctx, self.signal_roc_host orelse @panic("staged when lacked Roc host"), &self.engine.pending_roc_metrics);
                        }
                        index = self.prepared_attrs.items.len;
                        while (index != 0) {
                            index -= 1;
                            self.prepared_attrs.items[index].abort(allocator);
                        }
                        index = self.prepared_signal_attrs.items.len;
                        while (index != 0) {
                            index -= 1;
                            self.prepared_signal_attrs.items[index].abort(
                                allocator,
                                self.host_ctx,
                                self.signal_roc_host orelse @panic("staged signal descriptor lacked Roc host"),
                                &self.engine.pending_roc_metrics,
                            );
                        }
                        for (self.signal_bindings.items) |binding| allocator.free(binding.source_node_ids);
                    }
                    self.scopes.abort();
                    self.node_identities.abort();
                    self.dom_identities.abort();
                }
                self.prepared_nodes.deinit(allocator);
                self.prepared_render_order.deinit(allocator);
                self.prepared_attrs.deinit(allocator);
                self.prepared_signal_attrs.deinit(allocator);
                self.prepared_events.deinit(allocator);
                self.prepared_lifecycle.deinit(allocator);
                self.prepared_named_event_groups.deinit(allocator);
                self.prepared_named_event_group_by_elem.deinit(allocator);
                self.prepared_state_sites.deinit(allocator);
                self.prepared_states.deinit(allocator);
                self.prepared_state_cells.deinit(allocator);
                self.prepared_whens.deinit(allocator);
                self.signal_bindings.deinit(allocator);
                const SignalReleaser = struct {
                    collection: *Collection,
                    /// Performs release record inside the shared engine while preserving transaction and changed-set invariants.
                    pub fn releaseRecord(releaser: @This(), record: *HostSignalRecord) void {
                        record.release(
                            Ctx.allocator(releaser.collection.host_ctx),
                            releaser.collection.host_ctx,
                            releaser.collection.signal_roc_host orelse @panic("staged signal record lacked Roc host"),
                            &releaser.collection.engine.pending_roc_metrics,
                        );
                    }
                };
                self.signal_records.deinit(allocator, SignalReleaser{ .collection = self });
                self.scopes.deinit(allocator);
                self.node_identities.deinit(allocator);
                self.dom_identities.deinit(allocator);
            }

            fn rootScope(self: *@This()) CollectionError!scope_tree.InternResult {
                const key: collection_plan.ScopeKey = .{ .parent_id = 0, .ordinal = 0, .kind = .root };
                const active_id: ?u64 = if (self.engine.scopes.items.len != 0) 0 else null;
                const scope_id = self.scopes.reserve(key, active_id, &.{0}) catch |err| switch (err) {
                    error.NoCapacity => return error.OutOfMemory,
                    error.NoAvailableScope => return error.ResourceLimit,
                };
                return .{ .scope_id = scope_id, .created = active_id == null };
            }

            fn validateScope(self: *@This(), scope_id: u64) CollectionError!void {
                const root_key: collection_plan.ScopeKey = .{ .parent_id = 0, .ordinal = 0, .kind = .root };
                if (self.scopes.lookup(root_key, null) == scope_id) return;
                if (self.scopes.reserved_ids.contains(scope_id)) return;
                self.engine.validateScopeId(scope_id) catch return error.ResourceLimit;
            }

            fn attachExternalScopeIds(self: *@This(), scope_ids: []const u64) CollectionError!void {
                for (scope_ids) |scope_id| {
                    if (scope_id < self.engine.scopes.items.len) return error.ResourceLimit;
                    self.scopes.reserveExternal(scope_id) catch |err| switch (err) {
                        error.NoCapacity => return error.OutOfMemory,
                        error.DuplicateScope => return error.ResourceLimit,
                    };
                }
            }

            fn reserveWhenBranchScope(self: *@This(), parent_scope_id: u64, site_ordinal: u64, branch: HostScopeBranch) CollectionError!scope_tree.InternResult {
                const persistent_parent = parent_scope_id < self.engine.scopes.items.len;
                const key: collection_plan.ScopeKey = .{ .parent_id = parent_scope_id, .ordinal = site_ordinal, .kind = .{ .when_branch = branch } };
                const active_id = if (persistent_parent) self.engine.activeWhenBranchScopeId(parent_scope_id, site_ordinal, branch) catch return error.ResourceLimit else null;
                const fresh_id: u64 = @intCast(self.engine.scopes.items.len + self.scopes.reserved_ids.count());
                const branch_scope_id = self.scopes.reserve(key, active_id, &.{fresh_id}) catch |err| switch (err) {
                    error.NoCapacity => return error.OutOfMemory,
                    error.NoAvailableScope => return error.ResourceLimit,
                };
                return .{ .scope_id = branch_scope_id, .created = active_id == null };
            }

            fn reserveDomIdentity(self: *@This(), scope_id: u64, ordinal: u64) CollectionError!u64 {
                const key = identityKey(scope_id, ordinal);
                const active_id = self.engine.active_dom_identity_ids.get(key);
                const fresh_id = std.math.add(u64, @intCast(self.engine.dom_identities.items.len + self.dom_identities.intents.items.len), 1) catch return error.ResourceLimit;
                return self.dom_identities.reserve(key, active_id, &.{fresh_id}) catch |err| switch (err) {
                    error.NoCapacity => error.OutOfMemory,
                    error.NoAvailableIdentity => error.ResourceLimit,
                };
            }

            fn reserveNodeIdentity(self: *@This(), scope_id: u64, ordinal: u64) CollectionError!u64 {
                const key = identityKey(scope_id, ordinal);
                const active_id = self.engine.active_node_identity_ids.get(key);
                const fresh_id: u64 = @intCast(self.engine.node_identities.items.len + self.node_identities.intents.items.len);
                return self.node_identities.reserve(key, active_id, &.{fresh_id}) catch |err| switch (err) {
                    error.NoCapacity => error.OutOfMemory,
                    error.NoAvailableIdentity => error.ResourceLimit,
                };
            }

            fn beginState(self: *@This(), roc_host: *abi.RocHost, scope_id: u64, parent_elem_id: u64, ordinal: *u64, binder_stack: *std.ArrayListUnmanaged(HostBinderBinding), state: abi_view.StateElem) CollectionError!HostBinderBinding {
                const allocator = Ctx.allocator(self.host_ctx);
                const binder_bytes = std.math.mul(usize, binder_stack.items.len, @sizeOf(HostBinderBinding)) catch return error.ResourceLimit;
                const descriptor_bytes = std.math.add(usize, @sizeOf(HostNodeScopeSiteDesc) + @sizeOf(HostNodeStateDesc), binder_bytes) catch return error.ResourceLimit;
                try self.budget.charge(0, descriptor_bytes);
                binder_stack.ensureUnusedCapacity(allocator, 1) catch return error.OutOfMemory;
                const site_ordinal = ordinal.*;
                const node_id = try self.reserveNodeIdentity(scope_id, site_ordinal);
                var prepared_site = self.stream.prepareScopeSite(allocator, node_id, scope_id, site_ordinal, parent_elem_id, .state, binder_stack.items) catch return error.OutOfMemory;
                prepared_site.desc.render_insert_index = self.prepared_render_order.items.len;
                errdefer prepared_site.abort(allocator);
                self.signal_roc_host = roc_host;
                const prepared_state = self.stream.prepareState(node_id, state.initial, state.capability, &self.engine.pending_roc_metrics);
                errdefer prepared_state.abort(roc_host, &self.engine.pending_roc_metrics);
                if (self.engine.stateIndexByNodeId(node_id) == null) {
                    const initial = erased_calls.callValueInitThunk(roc_host, state.initial);
                    const cell = HostValueCell.initRetained(initial, state.capability, &self.engine.pending_roc_metrics);
                    self.prepared_state_cells.appendAssumeCapacity(.{ .state_id = node_id, .cell = cell, .version = 0, .active = true });
                }
                self.prepared_state_sites.appendAssumeCapacity(prepared_site);
                self.prepared_states.appendAssumeCapacity(prepared_state);
                ordinal.* += 1;
                return .{ .token = state.binder.callable, .node_id = node_id };
            }

            fn beginComponent(self: *@This(), scope_id: u64, parent_elem_id: u64, ordinal: *u64, binder_stack: []const HostBinderBinding) CollectionError!scope_tree.InternResult {
                const binder_bytes = std.math.mul(usize, binder_stack.len, @sizeOf(HostBinderBinding)) catch return error.ResourceLimit;
                try self.budget.charge(0, std.math.add(usize, @sizeOf(HostNodeScopeSiteDesc), binder_bytes) catch return error.ResourceLimit);
                const site_ordinal = ordinal.*;
                const node_id = try self.reserveNodeIdentity(scope_id, site_ordinal);
                var prepared = self.stream.prepareScopeSite(Ctx.allocator(self.host_ctx), node_id, scope_id, site_ordinal, parent_elem_id, .component, binder_stack) catch return error.OutOfMemory;
                prepared.desc.render_insert_index = self.prepared_render_order.items.len;
                errdefer prepared.abort(Ctx.allocator(self.host_ctx));
                const key: collection_plan.ScopeKey = .{ .parent_id = scope_id, .ordinal = site_ordinal, .kind = .component };
                var active_id: ?u64 = null;
                for (self.engine.scopes.items) |scope| {
                    if (!scope.active or scope.parent_scope_id != scope_id) continue;
                    switch (scope.step) {
                        .component => |step| if (step.site_ordinal == site_ordinal) {
                            active_id = scope.scope_id;
                            break;
                        },
                        else => {},
                    }
                }
                const fresh_id: u64 = @intCast(self.engine.scopes.items.len + self.scopes.intents.items.len);
                const component_scope_id = self.scopes.reserve(key, active_id, &.{fresh_id}) catch |err| switch (err) {
                    error.NoCapacity => return error.OutOfMemory,
                    error.NoAvailableScope => return error.ResourceLimit,
                };
                self.prepared_state_sites.appendAssumeCapacity(prepared);
                ordinal.* += 1;
                return .{ .scope_id = component_scope_id, .created = active_id == null };
            }

            fn beginWhen(self: *@This(), roc_host: *abi.RocHost, scope_id: u64, parent_elem_id: u64, ordinal: *u64, binder_stack: []const HostBinderBinding, payload: abi_view.WhenElem) CollectionError!WhenCollection {
                const allocator = Ctx.allocator(self.host_ctx);
                const binder_bytes = std.math.mul(usize, binder_stack.len, @sizeOf(HostBinderBinding)) catch return error.ResourceLimit;
                try self.budget.charge(0, std.math.add(usize, @sizeOf(HostNodeScopeSiteDesc) + @sizeOf(HostNodeWhenDesc), binder_bytes) catch return error.ResourceLimit);
                const site_ordinal = ordinal.*;
                const node_id = try self.reserveNodeIdentity(scope_id, site_ordinal);
                var site = self.stream.prepareScopeSite(allocator, node_id, scope_id, site_ordinal, parent_elem_id, .when, binder_stack) catch return error.OutOfMemory;
                site.desc.render_insert_index = self.prepared_render_order.items.len;
                errdefer site.abort(allocator);
                const condition = try self.bindSignalRoot(roc_host, payload.condition.*, binder_stack);
                var prepared = self.stream.prepareWhen(node_id, condition, payload.read, payload.when_false.*, payload.when_true.*, &self.engine.pending_roc_metrics);
                errdefer prepared.abort(allocator, self.host_ctx, roc_host, &self.engine.pending_roc_metrics);
                self.signal_records.transferDescriptorRoot(condition.record);
                const journaled = self.signal_bindings.pop() orelse @panic("staged when binding journal underflow");
                if (journaled.record != condition.record or journaled.source_node_ids.ptr != condition.source_node_ids.ptr) @panic("staged when binding journal transfer mismatch");
                const value = self.engine.evalHostSignalBinding(self.host_ctx, roc_host, &prepared.desc.condition);
                const cap = self.engine.hostSignalBindingCapability(self.host_ctx, &prepared.desc.condition);
                assertHostValueCapabilitiesMatch(prepared.desc.read.capability, cap, "when read extension capability did not match its signal value");
                const branch: HostScopeBranch = if (callHostValueToBoolWithCapability(self.host_ctx, roc_host, prepared.desc.read.capability, prepared.desc.read.read, value)) .true_branch else .false_branch;
                prepared.desc.cached_value = .{ .present = HostValueCell.initRetained(value, cap, &self.engine.pending_roc_metrics) };
                const persistent_parent = scope_id < self.engine.scopes.items.len;
                if (persistent_parent and (self.engine.activeWhenBranchScopeId(scope_id, site_ordinal, branch.opposite()) catch return error.ResourceLimit) != null) return error.ResourceLimit;
                const branch_scope = try self.reserveWhenBranchScope(scope_id, site_ordinal, branch);
                self.prepared_state_sites.appendAssumeCapacity(site);
                self.prepared_whens.appendAssumeCapacity(prepared);
                ordinal.* += 1;
                return .{ .scope = branch_scope, .branch = branch };
            }

            fn appendElement(self: *@This(), scope_id: u64, parent_elem_id: u64, dom_ordinal: *u64, tag: []const u8) CollectionError!u64 {
                const descriptor_bytes = std.math.add(usize, @sizeOf(HostElementDesc), tag.len) catch return error.ResourceLimit;
                try self.budget.charge(1, descriptor_bytes);
                const elem_id = try self.reserveDomIdentity(scope_id, dom_ordinal.*);
                const prepared = self.stream.prepareElement(Ctx.allocator(self.host_ctx), elem_id, parent_elem_id, scope_id, tag) catch return error.OutOfMemory;
                self.prepared_nodes.appendAssumeCapacity(prepared);
                self.prepared_render_order.appendAssumeCapacity(.{ .static = self.prepared_nodes.items.len - 1 });
                dom_ordinal.* += 1;
                return elem_id;
            }

            fn appendText(self: *@This(), scope_id: u64, parent_elem_id: u64, dom_ordinal: *u64, value: []const u8) CollectionError!void {
                const descriptor_bytes = std.math.add(usize, @sizeOf(HostNodeTextNodeDesc), value.len) catch return error.ResourceLimit;
                try self.budget.charge(1, descriptor_bytes);
                const elem_id = try self.reserveDomIdentity(scope_id, dom_ordinal.*);
                const prepared = self.stream.prepareTextNode(Ctx.allocator(self.host_ctx), elem_id, parent_elem_id, scope_id, value) catch return error.OutOfMemory;
                self.prepared_nodes.appendAssumeCapacity(prepared);
                self.prepared_render_order.appendAssumeCapacity(.{ .static = self.prepared_nodes.items.len - 1 });
                dom_ordinal.* += 1;
            }

            fn appendSignalText(self: *@This(), roc_host: *abi.RocHost, scope_id: u64, parent_elem_id: u64, dom_ordinal: *u64, payload: abi_view.TextSignalElem, binder_stack: []const HostBinderBinding) CollectionError!void {
                try self.budget.charge(1, @sizeOf(HostNodeSignalTextNodeDesc));
                const elem_id = try self.reserveDomIdentity(scope_id, dom_ordinal.*);
                const signal = try self.bindSignalRoot(roc_host, payload.signal.*, binder_stack);
                const read = retainHostTextRead(payload.read, &self.engine.pending_roc_metrics);
                self.prepared_signal_attrs.appendAssumeCapacity(.{ .text_node = .{
                    .elem_id = elem_id,
                    .parent_elem_id = parent_elem_id,
                    .scope_id = scope_id,
                    .signal = signal,
                    .read = read,
                } });
                self.prepared_render_order.appendAssumeCapacity(.{ .signal = self.prepared_signal_attrs.items.len - 1 });
                self.signal_records.transferDescriptorRoot(signal.record);
                const journaled = self.signal_bindings.pop() orelse @panic("staged signal binding journal underflow");
                if (journaled.record != signal.record or journaled.source_node_ids.ptr != signal.source_node_ids.ptr or journaled.source_node_ids.len != signal.source_node_ids.len) @panic("staged signal binding journal transfer mismatch");
                dom_ordinal.* += 1;
            }

            fn appendAttr(self: *@This(), roc_host: *abi.RocHost, elem_id: u64, attr: abi.NodeAttr, binder_stack: []const HostBinderBinding) CollectionError!void {
                const prepared = switch (abi_view.NodeAttr.fromAbi(attr)) {
                    .signal_text => |payload| switch (payload.target) {
                        .fixed => |field| {
                            try self.budget.charge(0, @sizeOf(HostNodeSignalTextAttrDesc));
                            const signal = try self.bindSignalRoot(roc_host, payload.signal.*, binder_stack);
                            const read = retainHostTextRead(payload.read, &self.engine.pending_roc_metrics);
                            self.prepared_signal_attrs.appendAssumeCapacity(.{ .text_attr = .{
                                .elem_id = elem_id,
                                .field = field,
                                .signal = signal,
                                .read = read,
                            } });
                            self.signal_records.transferDescriptorRoot(signal.record);
                            const journaled = self.signal_bindings.pop() orelse @panic("staged signal binding journal underflow");
                            if (journaled.record != signal.record or journaled.source_node_ids.ptr != signal.source_node_ids.ptr or journaled.source_node_ids.len != signal.source_node_ids.len) {
                                @panic("staged signal binding journal transfer mismatch");
                            }
                            return;
                        },
                        .custom => |name| {
                            const name_slice = name.asSlice();
                            if (name_slice.len == 0 or self.customAttrExists(elem_id, name_slice)) return error.ResourceLimit;
                            const bytes = std.math.add(usize, @sizeOf(HostNodeSignalCustomTextAttrDesc), name_slice.len) catch return error.ResourceLimit;
                            try self.budget.charge(0, bytes);
                            const allocator = Ctx.allocator(self.host_ctx);
                            self.stream.reservePreparedCustomAttrElem(allocator, elem_id, self.signal_root_capacity) catch return error.OutOfMemory;
                            const name_copy = allocator.dupe(u8, name_slice) catch return error.OutOfMemory;
                            errdefer allocator.free(name_copy);
                            const signal = try self.bindSignalRoot(roc_host, payload.signal.*, binder_stack);
                            const read = retainHostTextRead(payload.read, &self.engine.pending_roc_metrics);
                            self.prepared_signal_attrs.appendAssumeCapacity(.{ .custom_text_attr = .{
                                .elem_id = elem_id,
                                .name = name_copy,
                                .signal = signal,
                                .read = read,
                            } });
                            self.signal_records.transferDescriptorRoot(signal.record);
                            const journaled = self.signal_bindings.pop() orelse @panic("staged signal binding journal underflow");
                            if (journaled.record != signal.record or journaled.source_node_ids.ptr != signal.source_node_ids.ptr or journaled.source_node_ids.len != signal.source_node_ids.len) {
                                @panic("staged signal binding journal transfer mismatch");
                            }
                            return;
                        },
                    },
                    .signal_optional_text => |payload| switch (payload.target) {
                        .fixed => return error.ResourceLimit,
                        .custom => |name| {
                            const name_slice = name.asSlice();
                            if (name_slice.len == 0 or self.customAttrExists(elem_id, name_slice)) return error.ResourceLimit;
                            const bytes = std.math.add(usize, @sizeOf(HostNodeSignalOptionalCustomTextAttrDesc), name_slice.len) catch return error.ResourceLimit;
                            try self.budget.charge(0, bytes);
                            const allocator = Ctx.allocator(self.host_ctx);
                            self.stream.reservePreparedCustomAttrElem(allocator, elem_id, self.signal_root_capacity) catch return error.OutOfMemory;
                            const name_copy = allocator.dupe(u8, name_slice) catch return error.OutOfMemory;
                            errdefer allocator.free(name_copy);
                            const signal = try self.bindSignalRoot(roc_host, payload.signal.*, binder_stack);
                            const present = retainHostBoolRead(payload.present, &self.engine.pending_roc_metrics);
                            const read = retainHostTextRead(payload.read, &self.engine.pending_roc_metrics);
                            self.prepared_signal_attrs.appendAssumeCapacity(.{ .optional_custom_text_attr = .{
                                .elem_id = elem_id,
                                .name = name_copy,
                                .signal = signal,
                                .present = present,
                                .read = read,
                            } });
                            self.signal_records.transferDescriptorRoot(signal.record);
                            const journaled = self.signal_bindings.pop() orelse @panic("staged signal binding journal underflow");
                            if (journaled.record != signal.record or journaled.source_node_ids.ptr != signal.source_node_ids.ptr or journaled.source_node_ids.len != signal.source_node_ids.len) @panic("staged signal binding journal transfer mismatch");
                            return;
                        },
                    },
                    .signal_bool => |payload| switch (payload.target) {
                        .fixed => |field| {
                            try self.budget.charge(0, @sizeOf(HostNodeSignalBoolAttrDesc));
                            const signal = try self.bindSignalRoot(roc_host, payload.signal.*, binder_stack);
                            const read = retainHostBoolRead(payload.read, &self.engine.pending_roc_metrics);
                            self.prepared_signal_attrs.appendAssumeCapacity(.{ .bool_attr = .{
                                .elem_id = elem_id,
                                .field = field,
                                .signal = signal,
                                .read = read,
                            } });
                            self.signal_records.transferDescriptorRoot(signal.record);
                            const journaled = self.signal_bindings.pop() orelse @panic("staged signal binding journal underflow");
                            if (journaled.record != signal.record or journaled.source_node_ids.ptr != signal.source_node_ids.ptr or journaled.source_node_ids.len != signal.source_node_ids.len) {
                                @panic("staged signal binding journal transfer mismatch");
                            }
                            return;
                        },
                        .custom => |name| {
                            const name_slice = name.asSlice();
                            if (name_slice.len == 0 or self.customAttrExists(elem_id, name_slice)) return error.ResourceLimit;
                            const bytes = std.math.add(usize, @sizeOf(HostNodeSignalCustomBoolAttrDesc), name_slice.len) catch return error.ResourceLimit;
                            try self.budget.charge(0, bytes);
                            const allocator = Ctx.allocator(self.host_ctx);
                            self.stream.reservePreparedCustomAttrElem(allocator, elem_id, self.signal_root_capacity) catch return error.OutOfMemory;
                            const name_copy = allocator.dupe(u8, name_slice) catch return error.OutOfMemory;
                            errdefer allocator.free(name_copy);
                            const signal = try self.bindSignalRoot(roc_host, payload.signal.*, binder_stack);
                            const read = retainHostBoolRead(payload.read, &self.engine.pending_roc_metrics);
                            self.prepared_signal_attrs.appendAssumeCapacity(.{ .custom_bool_attr = .{
                                .elem_id = elem_id,
                                .name = name_copy,
                                .signal = signal,
                                .read = read,
                            } });
                            self.signal_records.transferDescriptorRoot(signal.record);
                            const journaled = self.signal_bindings.pop() orelse @panic("staged signal binding journal underflow");
                            if (journaled.record != signal.record or journaled.source_node_ids.ptr != signal.source_node_ids.ptr or journaled.source_node_ids.len != signal.source_node_ids.len) @panic("staged signal binding journal transfer mismatch");
                            return;
                        },
                    },
                    .event => |payload| {
                        try self.budget.charge(0, @sizeOf(HostNodeEventDesc));
                        const binder_token = payload.msg.binder.callable;
                        const read_binder_token = payload.msg.read_binder.callable;
                        self.signal_roc_host = roc_host;
                        self.prepared_events.appendAssumeCapacity(.{ .desc = .{
                            .elem_id = elem_id,
                            .binding = .{ .fixed = payload.kind },
                            .delivery_request = payload.delivery_request,
                            .binder_token = binder_token,
                            .target_node_id = resolveNodeBinderRef(binder_stack, binder_token),
                            .read_binder_token = read_binder_token,
                            .read_node_id = resolveNodeBinderRef(binder_stack, read_binder_token),
                            .payload_descriptor = payload.msg.payload_descriptor,
                            .payload_reducer = retainHostEventReducer(payload.msg.payload_reducer, &self.engine.pending_roc_metrics),
                        } });
                        return;
                    },
                    .named_event => |payload| {
                        const name = payload.name.asSlice();
                        if (name.len == 0 or self.namedEventExists(elem_id, name)) return error.ResourceLimit;
                        const bytes = std.math.add(usize, @sizeOf(HostNodeEventDesc), name.len) catch return error.ResourceLimit;
                        try self.budget.charge(0, bytes);
                        const group_index = try self.prepareNamedEventGroup(elem_id);
                        const allocator = Ctx.allocator(self.host_ctx);
                        const name_copy = allocator.dupe(u8, name) catch return error.OutOfMemory;
                        errdefer allocator.free(name_copy);
                        const binder_token = payload.msg.binder.callable;
                        const read_binder_token = payload.msg.read_binder.callable;
                        self.signal_roc_host = roc_host;
                        const event_ordinal = self.prepared_events.items.len;
                        self.prepared_events.appendAssumeCapacity(.{ .desc = .{
                            .elem_id = elem_id,
                            .binding = .{ .named = .{
                                .name = name_copy,
                                .policy = payload.policy,
                                .delivery_request = payload.delivery_request,
                            } },
                            .delivery_request = payload.delivery_request,
                            .binder_token = binder_token,
                            .target_node_id = resolveNodeBinderRef(binder_stack, binder_token),
                            .read_binder_token = read_binder_token,
                            .read_node_id = resolveNodeBinderRef(binder_stack, read_binder_token),
                            .payload_descriptor = payload.msg.payload_descriptor,
                            .payload_reducer = retainHostEventReducer(payload.msg.payload_reducer, &self.engine.pending_roc_metrics),
                        } });
                        self.prepared_named_event_groups.items[group_index].event_ordinals.appendAssumeCapacity(event_ordinal);
                        return;
                    },
                    .static_text => |payload| switch (payload.target) {
                        .fixed => |field| blk: {
                            const bytes = std.math.add(usize, @sizeOf(HostNodeStaticTextAttrDesc), payload.value.asSlice().len) catch return error.ResourceLimit;
                            try self.budget.charge(0, bytes);
                            break :blk self.stream.prepareStaticTextAttr(Ctx.allocator(self.host_ctx), elem_id, field, payload.value.asSlice()) catch return error.OutOfMemory;
                        },
                        .custom => |name| blk: {
                            const name_slice = name.asSlice();
                            if (name_slice.len == 0 or self.customAttrExists(elem_id, name_slice)) return error.ResourceLimit;
                            const bytes = std.math.add(usize, @sizeOf(HostNodeStaticCustomTextAttrDesc), name_slice.len) catch return error.ResourceLimit;
                            const total = std.math.add(usize, bytes, payload.value.asSlice().len) catch return error.ResourceLimit;
                            try self.budget.charge(0, total);
                            const allocator = Ctx.allocator(self.host_ctx);
                            self.stream.reservePreparedCustomAttrElem(allocator, elem_id, self.signal_root_capacity) catch return error.OutOfMemory;
                            break :blk self.stream.prepareStaticCustomTextAttr(allocator, elem_id, name_slice, payload.value.asSlice()) catch return error.OutOfMemory;
                        },
                    },
                    .static_bool => |payload| switch (payload.target) {
                        .fixed => |field| blk: {
                            try self.budget.charge(0, @sizeOf(HostNodeStaticBoolAttrDesc));
                            break :blk self.stream.prepareStaticBoolAttr(elem_id, field, payload.value);
                        },
                        .custom => |name| blk: {
                            const name_slice = name.asSlice();
                            if (name_slice.len == 0 or self.customAttrExists(elem_id, name_slice)) return error.ResourceLimit;
                            const bytes = std.math.add(usize, @sizeOf(HostNodeStaticCustomBoolAttrDesc), name_slice.len) catch return error.ResourceLimit;
                            try self.budget.charge(0, bytes);
                            const allocator = Ctx.allocator(self.host_ctx);
                            self.stream.reservePreparedCustomAttrElem(allocator, elem_id, self.signal_root_capacity) catch return error.OutOfMemory;
                            break :blk self.stream.prepareStaticCustomBoolAttr(allocator, elem_id, name_slice, payload.value) catch return error.OutOfMemory;
                        },
                    },
                };
                self.prepared_attrs.appendAssumeCapacity(prepared);
            }

            fn appendCleanup(self: *@This(), roc_host: *abi.RocHost, scope_id: u64, name: []const u8) CollectionError!void {
                self.signal_roc_host = roc_host;
                const allocator = Ctx.allocator(self.host_ctx);
                self.stream.reserveLifecycleScope(allocator, scope_id, self.prepared_lifecycle.capacity) catch return error.OutOfMemory;
                const prepared = self.stream.prepareCleanup(allocator, scope_id, name) catch return error.OutOfMemory;
                self.prepared_lifecycle.appendAssumeCapacity(prepared);
            }

            fn appendMount(self: *@This(), roc_host: *abi.RocHost, scope_id: u64, to_cmd: abi.RocErasedCallable, run_on_mount: bool) CollectionError!void {
                self.signal_roc_host = roc_host;
                const allocator = Ctx.allocator(self.host_ctx);
                self.stream.reserveLifecycleScope(allocator, scope_id, self.prepared_lifecycle.capacity) catch return error.OutOfMemory;
                self.prepared_lifecycle.appendAssumeCapacity(self.stream.prepareMount(to_cmd, scope_id, run_on_mount, &self.engine.pending_roc_metrics));
            }

            fn appendOnChange(self: *@This(), roc_host: *abi.RocHost, scope_id: u64, payload: abi_view.OnChangeElem, binder_stack: []const HostBinderBinding, scope_created: bool) CollectionError!void {
                const allocator = Ctx.allocator(self.host_ctx);
                self.stream.reserveLifecycleScope(allocator, scope_id, self.prepared_lifecycle.capacity) catch return error.OutOfMemory;
                const signal = try self.bindSignalRoot(roc_host, payload.signal.*, binder_stack);
                self.prepared_lifecycle.appendAssumeCapacity(self.stream.prepareOnChange(signal, payload.to_cmd, scope_id, payload.run_initial, payload.run_initial and scope_created, &self.engine.pending_roc_metrics));
                self.signal_records.transferDescriptorRoot(signal.record);
                const journaled = self.signal_bindings.pop() orelse @panic("staged lifecycle signal binding journal underflow");
                if (journaled.record != signal.record) @panic("staged lifecycle signal binding journal transfer mismatch");
            }

            fn customAttrExists(self: *const @This(), elem_id: u64, name: []const u8) bool {
                if (self.stream.customTextAttrDescriptorExists(elem_id, name)) return true;
                for (self.prepared_attrs.items) |prepared| switch (prepared) {
                    .custom_text => |value| if (value.elem_id == elem_id and std.mem.eql(u8, value.name, name)) return true,
                    .custom_boolean => |value| if (value.elem_id == elem_id and std.mem.eql(u8, value.name, name)) return true,
                    .text, .boolean => {},
                };
                return false;
            }

            fn namedEventExists(self: *const @This(), elem_id: u64, name: []const u8) bool {
                if (self.stream.namedEventDescriptorExists(elem_id, name)) return true;
                for (self.prepared_events.items) |prepared| {
                    if (prepared.desc.elem_id != elem_id) continue;
                    const binding = prepared.desc.named() orelse continue;
                    if (std.mem.eql(u8, binding.name, name)) return true;
                }
                return false;
            }

            fn prepareNamedEventGroup(self: *@This(), elem_id: u64) CollectionError!usize {
                const allocator = Ctx.allocator(self.host_ctx);
                if (self.prepared_named_event_group_by_elem.get(elem_id)) |index| {
                    const group = &self.prepared_named_event_groups.items[index];
                    group.event_ordinals.ensureUnusedCapacity(allocator, 1) catch return error.OutOfMemory;
                    if (group.existed) self.stream.reserveExistingNamedEventIndexes(allocator, elem_id, group.event_ordinals.items.len + 1) catch return error.OutOfMemory;
                    return index;
                }
                var group = HostNodeDescriptorStream.PreparedNamedEventIndexGroup{
                    .elem_id = elem_id,
                    .existed = self.stream.namedEventIndexSlotExists(elem_id),
                };
                errdefer group.abort(allocator);
                group.event_ordinals.ensureTotalCapacity(allocator, 1) catch return error.OutOfMemory;
                if (group.existed) self.stream.reserveExistingNamedEventIndexes(allocator, elem_id, 1) catch return error.OutOfMemory;
                const index = self.prepared_named_event_groups.items.len;
                self.prepared_named_event_groups.appendAssumeCapacity(group);
                self.prepared_named_event_group_by_elem.putAssumeCapacity(elem_id, index);
                return index;
            }

            const StagedSignalRecordCtx = struct {
                collection: *Collection,
                allocator: std.mem.Allocator,

                fn retainExisting(self: @This(), token: HostSignalToken, expected_tag: std.meta.Tag(HostSignalRecordPayload)) error{OutOfMemory}!?*HostSignalRecord {
                    const persistent = self.collection.engine.signalRecordByTokenForStream(self.collection.stream, token);
                    const record = self.collection.signal_records.lookup(token, persistent) orelse return null;
                    validateExistingSignalRecord(record, expected_tag);
                    if (!self.collection.signal_records.by_token.contains(token)) {
                        if (self.collection.signal_records.token_intents.items.len >= self.collection.signal_token_capacity) return error.OutOfMemory;
                        self.collection.signal_records.rememberTokenAssumeCapacity(token, record);
                    }
                    return record.retain();
                }

                fn init(self: @This(), payload: HostSignalRecordPayload) error{OutOfMemory}!*HostSignalRecord {
                    return HostSignalRecord.tryInitOwned(
                        self.allocator,
                        self.collection.host_ctx,
                        self.collection.signal_roc_host orelse @panic("staged signal binding lacked Roc host"),
                        &self.collection.engine.pending_roc_metrics,
                        payload,
                    );
                }

                fn remember(self: @This(), record: *HostSignalRecord) error{OutOfMemory}!void {
                    const token = record.token() orelse return;
                    if (self.collection.signal_records.by_token.contains(token)) return;
                    if (self.collection.signal_records.token_intents.items.len >= self.collection.signal_token_capacity) return error.OutOfMemory;
                    self.collection.signal_records.rememberTokenAssumeCapacity(token, record);
                }
            };

            fn bindSignalRoot(self: *@This(), roc_host: *abi.RocHost, expr: abi.NodeSignalExpr, binder_stack: []const HostBinderBinding) CollectionError!HostSignalBinding {
                if (self.signal_records.descriptor_roots.items.len >= self.signal_root_capacity) return error.OutOfMemory;
                self.signal_roc_host = roc_host;
                const binding = StagedSignalRecordCtx{ .collection = self, .allocator = Ctx.allocator(self.host_ctx) };
                const record = self.engine.bindSignalExprViewWith(StagedSignalRecordCtx, binding, abi_view.SignalExpr.fromAbi(expr), binder_stack) catch return error.OutOfMemory;
                self.signal_records.ownDescriptorRootAssumeCapacity(record);
                var source_node_ids: std.ArrayListUnmanaged(u64) = .empty;
                appendSignalRecordSourceNodeIdsFallible(binding.allocator, &source_node_ids, record) catch {
                    source_node_ids.deinit(binding.allocator);
                    return error.OutOfMemory;
                };
                const result = HostSignalBinding{
                    .record = record,
                    .source_node_ids = source_node_ids.toOwnedSlice(binding.allocator) catch {
                        source_node_ids.deinit(binding.allocator);
                        return error.OutOfMemory;
                    },
                };
                self.signal_bindings.appendAssumeCapacity(result);
                return result;
            }

            const SignalPublisher = struct {
                stream: *HostNodeDescriptorStream,

                /// Publishes token during the allocation-free commit phase.
                pub fn publishToken(self: @This(), token: HostSignalToken, record: *HostSignalRecord) void {
                    self.stream.rememberSignalRecordAssumeCapacity(token, record);
                }

                /// Publishes descriptor root during the allocation-free commit phase.
                pub fn publishDescriptorRoot(self: @This(), record: *HostSignalRecord) void {
                    self.stream.incrementSignalRecordDescriptorTreeAssumeCapacity(record);
                }
            };

            /// Transfers prepared descriptor ownership into the plan-local
            /// stream without publishing persistent engine identities/scopes.
            fn materializeStream(self: *@This()) void {
                if (self.stream_materialized) @panic("staged collection stream materialized twice");
                for (self.prepared_render_order.items) |entry| switch (entry) {
                    .static => |index| self.stream.appendPreparedStaticNode(self.prepared_nodes.items[index]),
                    .signal => |index| self.stream.appendPreparedSignalDescriptor(self.prepared_signal_attrs.items[index]),
                };
                self.prepared_nodes.clearRetainingCapacity();
                self.prepared_render_order.clearRetainingCapacity();
                for (self.prepared_attrs.items) |prepared| self.stream.appendPreparedStaticAttr(prepared);
                self.prepared_attrs.clearRetainingCapacity();
                self.signal_records.commit(SignalPublisher{ .stream = self.stream });
                for (self.prepared_signal_attrs.items) |prepared| switch (prepared) {
                    .text_node => {},
                    else => self.stream.appendPreparedSignalDescriptor(prepared),
                };
                self.prepared_signal_attrs.clearRetainingCapacity();
                const event_base = self.stream.events.items.len;
                for (self.prepared_events.items) |prepared| self.stream.appendPreparedEvent(prepared);
                self.stream.publishPreparedNamedEventIndexes(self.prepared_named_event_groups.items, event_base);
                self.prepared_events.clearRetainingCapacity();
                self.prepared_named_event_groups.clearRetainingCapacity();
                for (self.prepared_lifecycle.items) |prepared| self.stream.appendPreparedLifecycle(prepared);
                self.prepared_lifecycle.clearRetainingCapacity();
                for (self.prepared_state_sites.items) |site| self.stream.appendPreparedScopeSite(site);
                for (self.prepared_states.items) |state| self.stream.appendPreparedState(state);
                self.prepared_state_sites.clearRetainingCapacity();
                self.prepared_states.clearRetainingCapacity();
                for (self.prepared_whens.items) |prepared| self.stream.appendPreparedWhen(prepared);
                self.prepared_whens.clearRetainingCapacity();
                self.stream_materialized = true;
            }

            /// Publishes only pre-reserved state. This function must remain
            /// allocation-free so preparation is the last recoverable point.
            fn commit(self: *@This()) void {
                if (self.committed) @panic("staged collection committed twice");
                if (!self.stream_materialized) self.materializeStream();
                for (self.scopes.intents.items) |intent| {
                    if (intent.id != self.engine.scopes.items.len) @panic("unsupported staged scope intent");
                    const scope: HostScope = switch (intent.key.kind) {
                        .root => .{ .scope_id = intent.id, .parent_scope_id = null, .step = .root, .active = true },
                        .component => .{ .scope_id = intent.id, .parent_scope_id = intent.key.parent_id, .step = .{ .component = .{ .site_ordinal = intent.key.ordinal } }, .active = true },
                        .when_branch => |branch| .{ .scope_id = intent.id, .parent_scope_id = intent.key.parent_id, .step = .{ .when_branch = .{ .site_ordinal = intent.key.ordinal, .branch = branch } }, .active = true },
                    };
                    self.engine.scopes.appendAssumeCapacity(scope);
                    self.engine.recordScopeCreated();
                }
                for (self.dom_identities.intents.items) |intent| {
                    const scope_id: u64 = @truncate(intent.key >> 64);
                    const ordinal: u64 = @truncate(intent.key);
                    if (intent.id != self.engine.dom_identities.items.len + 1) {
                        @panic("unsupported staged DOM identity intent");
                    }
                    self.engine.dom_identities.appendAssumeCapacity(.{
                        .elem_id = intent.id,
                        .scope_id = scope_id,
                        .ordinal = ordinal,
                        .active = true,
                    });
                    self.engine.active_dom_identity_ids.putAssumeCapacity(intent.key, intent.id);
                }
                for (self.node_identities.intents.items) |intent| {
                    const scope_id: u64 = @truncate(intent.key >> 64);
                    const ordinal: u64 = @truncate(intent.key);
                    if (intent.id != self.engine.node_identities.items.len) @panic("unsupported staged node identity intent");
                    self.engine.node_identities.appendAssumeCapacity(.{ .node_id = intent.id, .scope_id = scope_id, .ordinal = ordinal, .active = true });
                    self.engine.active_node_identity_ids.putAssumeCapacity(intent.key, intent.id);
                }
                for (self.prepared_state_cells.items) |state| {
                    while (self.engine.state_indexes_by_node_id.items.len <= state.state_id) self.engine.state_indexes_by_node_id.appendAssumeCapacity(null);
                    const state_index = self.engine.states.items.len;
                    self.engine.states.appendAssumeCapacity(state);
                    self.engine.state_indexes_by_node_id.items[@intCast(state.state_id)] = state_index;
                }
                self.prepared_state_cells.clearRetainingCapacity();
                self.scopes.committed = true;
                self.node_identities.committed = true;
                self.dom_identities.committed = true;
                self.committed = true;
            }
        };

        fn collectActiveElemDescriptorsWith(self: *Self, comptime Collection: type, collection: Collection, ctx: Ctx.Handle, roc_host: *abi.RocHost, stream: *HostNodeDescriptorStream, elem: abi.Elem, scope_id: u64, parent_elem_id: u64, ordinal: *u64, dom_ordinal: *u64, binder_stack: *std.ArrayListUnmanaged(HostBinderBinding), scope_created: bool, dirty_source_node_ids: []const u64) CollectionError!void {
            try collection.validateScope(scope_id);

            const allocator = Ctx.allocator(ctx);
            switch (abi_view.Elem.fromAbi(elem)) {
                .element => |payload| {
                    const elem_id = try collection.appendElement(scope_id, parent_elem_id, dom_ordinal, payload.tag.asSlice());
                    for (payload.attrs) |attr| {
                        try collection.appendAttr(roc_host, elem_id, attr, binder_stack.items);
                    }
                    for (payload.children) |child| {
                        try self.collectActiveElemDescriptorsWith(Collection, collection, ctx, roc_host, stream, child, scope_id, elem_id, ordinal, dom_ordinal, binder_stack, scope_created, dirty_source_node_ids);
                    }
                },
                .text => |payload| {
                    try collection.appendText(scope_id, parent_elem_id, dom_ordinal, payload.text.asSlice());
                },
                .text_signal => |payload| {
                    try collection.appendSignalText(roc_host, scope_id, parent_elem_id, dom_ordinal, payload, binder_stack.items);
                },
                .cleanup => |payload| {
                    try collection.appendCleanup(roc_host, scope_id, payload.name.asSlice());
                },
                .on_change => |payload| {
                    try collection.appendOnChange(roc_host, scope_id, payload, binder_stack.items, scope_created);
                },
                .on_mount => |payload| {
                    try collection.appendMount(roc_host, scope_id, payload.to_cmd, scope_created);
                },
                .state => |state| {
                    const binder = try collection.beginState(roc_host, scope_id, parent_elem_id, ordinal, binder_stack, state);
                    binder_stack.appendAssumeCapacity(binder);
                    try self.collectActiveElemDescriptorsWith(Collection, collection, ctx, roc_host, stream, state.child.*, scope_id, parent_elem_id, ordinal, dom_ordinal, binder_stack, scope_created, dirty_source_node_ids);
                    _ = binder_stack.pop() orelse unreachable;
                },
                .component => |payload| {
                    const component_scope = try collection.beginComponent(scope_id, parent_elem_id, ordinal, binder_stack.items);
                    const component_scope_id = component_scope.scope_id;
                    var component_ordinal: u64 = 0;
                    var component_dom_ordinal: u64 = 0;
                    try self.collectActiveElemDescriptorsWith(Collection, collection, ctx, roc_host, stream, payload.child.*, component_scope_id, parent_elem_id, &component_ordinal, &component_dom_ordinal, binder_stack, component_scope.created, dirty_source_node_ids);
                },
                .when => |when_payload| {
                    const selected = try collection.beginWhen(roc_host, scope_id, parent_elem_id, ordinal, binder_stack.items, when_payload);
                    const branch_scope_id = selected.scope.scope_id;
                    var branch_ordinal: u64 = 0;
                    const branch_elem = switch (selected.branch) {
                        .true_branch => when_payload.when_true.*,
                        .false_branch => when_payload.when_false.*,
                    };
                    var branch_dom_ordinal: u64 = 0;
                    try self.collectActiveElemDescriptorsWith(Collection, collection, ctx, roc_host, stream, branch_elem, branch_scope_id, parent_elem_id, &branch_ordinal, &branch_dom_ordinal, binder_stack, selected.scope.created, dirty_source_node_ids);
                },
                .each => |each_payload| {
                    const site_ordinal = ordinal.*;
                    const node_id = self.internNodeIdentity(Ctx.allocator(ctx), scope_id, site_ordinal) catch @panic("scope id has no host scope descriptor");
                    ordinal.* += 1;
                    stream.appendScopeSite(allocator, node_id, scope_id, site_ordinal, parent_elem_id, .each, binder_stack.items);
                    const items_binding = self.bindNodeSignal(allocator, stream, each_payload.items.*, binder_stack.items);
                    stream.appendEach(allocator, ctx, roc_host, &self.pending_roc_metrics, node_id, items_binding, each_payload.ops);
                    const each_index = stream.eaches.items.len - 1;
                    const each_desc = stream.eaches.items[stream.eaches.items.len - 1];

                    const items_value = self.evalHostSignalBinding(ctx, roc_host, &stream.eaches.items[each_index].items);
                    const each_items_cap = self.hostSignalBindingCapability(ctx, &stream.eaches.items[each_index].items);
                    assertHostValueCapabilitiesMatch(each_desc.ops.items_capability, each_items_cap, "each items extension capability did not match its signal value");
                    const items = callHostValueToHostValueListWithCapability(ctx, roc_host, each_desc.ops.items_capability, each_desc.ops.items_to_values, items_value);
                    defer items.decref(roc_host);
                    stream.eaches.items[each_index].cached_value.replace(ctx, roc_host, &self.pending_roc_metrics, items_value, each_items_cap);
                    const item_values = items.items();

                    self.scratch.each_keys.resize(allocator, item_values.len) catch @panic("out of memory");
                    defer self.scratch.each_keys.clearRetainingCapacity();
                    const keys = self.scratch.each_keys.items;

                    for (item_values, 0..) |item, index| {
                        keys[index] = callHostValueToHostValueWithCapability(ctx, roc_host, each_desc.ops.item_capability, each_desc.ops.key_of, item);
                    }

                    const diff = self.syncEachRowScopes(ctx, roc_host, scope_id, site_ordinal, keys, item_values, each_desc.ops);
                    defer diff.deinit(allocator);

                    for (diff.scope_ids, diff.row_items_changed, diff.scope_created) |row_scope_id, row_item_changed, row_created| {
                        if (!row_item_changed and !self.scopeSubtreeHasDirtyStructuralSource(&self.active_stream, row_scope_id, dirty_source_node_ids)) {
                            self.copyActiveScopeSubtreeDescriptors(ctx, roc_host, stream, row_scope_id);
                            continue;
                        }

                        const row_values = self.eachRowScopeValues(row_scope_id);
                        const row_elem = callHostValueHostValueToElemWithCapabilities(ctx, roc_host, each_desc.ops.key_capability, each_desc.ops.item_capability, each_desc.ops.row, row_values.key, row_values.item);
                        defer row_elem.decref(roc_host);

                        var row_ordinal: u64 = 0;
                        var row_dom_ordinal: u64 = 0;
                        try self.collectActiveEachRowElemDescriptorsWith(Collection, collection, ctx, roc_host, stream, each_desc, row_elem, row_scope_id, parent_elem_id, &row_ordinal, &row_dom_ordinal, binder_stack, row_created, dirty_source_node_ids);
                    }
                },
            }
        }

        /// Collects active elem descriptors from the explicitly affected graph or scope set.
        pub fn collectActiveElemDescriptors(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, stream: *HostNodeDescriptorStream, elem: abi.Elem, scope_id: u64, parent_elem_id: u64, ordinal: *u64, dom_ordinal: *u64, binder_stack: *std.ArrayListUnmanaged(HostBinderBinding), scope_created: bool, dirty_source_node_ids: []const u64) void {
            const collection = ImmediateCollectionCtx{ .engine = self, .host_ctx = ctx, .stream = stream };
            self.collectActiveElemDescriptorsWith(ImmediateCollectionCtx, collection, ctx, roc_host, stream, elem, scope_id, parent_elem_id, ordinal, dom_ordinal, binder_stack, scope_created, dirty_source_node_ids) catch @panic("immediate descriptor collection failed");
        }

        fn collectActiveElemRootDescriptorsWith(self: *Self, comptime Collection: type, collection: Collection, ctx: Ctx.Handle, roc_host: *abi.RocHost, stream: *HostNodeDescriptorStream, root: abi.Elem, dirty_source_node_ids: []const u64) CollectionError!void {
            const root_scope = try collection.rootScope();
            const root_scope_id = root_scope.scope_id;
            const allocator = Ctx.allocator(ctx);
            const binder_stack = self.scratchBinderStack(allocator, &.{});
            defer self.scratch.binder_stack.clearRetainingCapacity();
            var ordinal: u64 = 0;
            var dom_ordinal: u64 = 0;
            try self.collectActiveElemDescriptorsWith(Collection, collection, ctx, roc_host, stream, root, root_scope_id, 0, &ordinal, &dom_ordinal, binder_stack, root_scope.created, dirty_source_node_ids);
        }

        const StaticRootCounts = struct { nodes: usize = 0, attrs: usize = 0, lifecycle: usize = 0, signal_records: usize = 0, state_sites: usize = 0, component_sites: usize = 0, when_sites: usize = 0 };

        fn countSignalExprRecords(expr: abi.NodeSignalExpr) CollectionError!usize {
            return switch (abi_view.SignalExpr.fromAbi(expr)) {
                .ref, .const_value, .task_source, .interval_source, .location_source, .visibility_source, .online_source, .storage_source => 1,
                .map => |payload| std.math.add(usize, 1, try countSignalExprRecords(payload.input.*)) catch return error.ResourceLimit,
                .map2 => |payload| blk: {
                    const left = try countSignalExprRecords(payload.left.*);
                    const right = try countSignalExprRecords(payload.right.*);
                    const children = std.math.add(usize, left, right) catch return error.ResourceLimit;
                    break :blk std.math.add(usize, 1, children) catch return error.ResourceLimit;
                },
                .combine => |payload| blk: {
                    var count: usize = 1;
                    for (payload.children) |child| {
                        count = std.math.add(usize, count, try countSignalExprRecords(child)) catch return error.ResourceLimit;
                    }
                    break :blk count;
                },
            };
        }

        fn countStaticRootNodes(elem: abi.Elem) CollectionError!StaticRootCounts {
            return switch (abi_view.Elem.fromAbi(elem)) {
                .element => |payload| blk: {
                    var count = StaticRootCounts{ .nodes = 1, .attrs = payload.attrs.len };
                    for (payload.attrs) |attr| switch (abi_view.NodeAttr.fromAbi(attr)) {
                        .signal_text => |signal| count.signal_records = std.math.add(usize, count.signal_records, try countSignalExprRecords(signal.signal.*)) catch return error.ResourceLimit,
                        .signal_optional_text => |signal| count.signal_records = std.math.add(usize, count.signal_records, try countSignalExprRecords(signal.signal.*)) catch return error.ResourceLimit,
                        .signal_bool => |signal| count.signal_records = std.math.add(usize, count.signal_records, try countSignalExprRecords(signal.signal.*)) catch return error.ResourceLimit,
                        else => {},
                    };
                    for (payload.children) |child| {
                        const child_count = try countStaticRootNodes(child);
                        count.nodes = std.math.add(usize, count.nodes, child_count.nodes) catch return error.ResourceLimit;
                        count.attrs = std.math.add(usize, count.attrs, child_count.attrs) catch return error.ResourceLimit;
                        count.lifecycle = std.math.add(usize, count.lifecycle, child_count.lifecycle) catch return error.ResourceLimit;
                        count.signal_records = std.math.add(usize, count.signal_records, child_count.signal_records) catch return error.ResourceLimit;
                        count.state_sites = std.math.add(usize, count.state_sites, child_count.state_sites) catch return error.ResourceLimit;
                        count.component_sites = std.math.add(usize, count.component_sites, child_count.component_sites) catch return error.ResourceLimit;
                        count.when_sites = std.math.add(usize, count.when_sites, child_count.when_sites) catch return error.ResourceLimit;
                    }
                    break :blk count;
                },
                .text => .{ .nodes = 1 },
                .text_signal => |payload| .{ .nodes = 1, .signal_records = try countSignalExprRecords(payload.signal.*) },
                .state => |payload| blk: {
                    var count = try countStaticRootNodes(payload.child.*);
                    count.state_sites = std.math.add(usize, count.state_sites, 1) catch return error.ResourceLimit;
                    break :blk count;
                },
                .component => |payload| blk: {
                    var count = try countStaticRootNodes(payload.child.*);
                    count.component_sites = std.math.add(usize, count.component_sites, 1) catch return error.ResourceLimit;
                    break :blk count;
                },
                .when => |payload| blk: {
                    const when_false = try countStaticRootNodes(payload.when_false.*);
                    const when_true = try countStaticRootNodes(payload.when_true.*);
                    var count = StaticRootCounts{
                        .nodes = @max(when_false.nodes, when_true.nodes),
                        .attrs = @max(when_false.attrs, when_true.attrs),
                        .lifecycle = @max(when_false.lifecycle, when_true.lifecycle),
                        .signal_records = @max(when_false.signal_records, when_true.signal_records),
                        .state_sites = @max(when_false.state_sites, when_true.state_sites),
                        .component_sites = @max(when_false.component_sites, when_true.component_sites),
                        .when_sites = @max(when_false.when_sites, when_true.when_sites),
                    };
                    count.signal_records = std.math.add(usize, count.signal_records, try countSignalExprRecords(payload.condition.*)) catch return error.ResourceLimit;
                    count.when_sites = std.math.add(usize, count.when_sites, 1) catch return error.ResourceLimit;
                    count.attrs = std.math.add(usize, count.attrs, 1) catch return error.ResourceLimit;
                    break :blk count;
                },
                .cleanup, .on_mount => .{ .lifecycle = 1 },
                .on_change => |payload| .{ .lifecycle = 1, .signal_records = try countSignalExprRecords(payload.signal.*) },
                else => error.ResourceLimit,
            };
        }

        const AggregateBranchSelection = struct {
            parent_scope_id: u64,
            site_ordinal: u64,
            parent_elem_id: u64,
            retired_scope_id: u64,
            render_insert_index: usize,
            binder_bindings: []const HostBinderBinding,
            branch: HostScopeBranch,
            elem: abi.Elem,
        };

        const PreparedIdentityRetirements = struct {
            node_ids: []u64,
            dom_ids: []u64,

            fn prepare(engine: *Self, allocator: std.mem.Allocator, target_scopes: []const bool) CollectionError!@This() {
                var node_count: usize = 0;
                for (engine.node_identities.items) |identity| {
                    if (identity.scope_id >= target_scopes.len) return error.ResourceLimit;
                    if (identity.active and target_scopes[@intCast(identity.scope_id)]) node_count = std.math.add(usize, node_count, 1) catch return error.ResourceLimit;
                }
                const node_ids = allocator.alloc(u64, node_count) catch return error.OutOfMemory;
                errdefer allocator.free(node_ids);
                var node_write: usize = 0;
                for (engine.node_identities.items) |identity| if (identity.active and target_scopes[@intCast(identity.scope_id)]) {
                    node_ids[node_write] = identity.node_id;
                    node_write += 1;
                };

                var dom_count: usize = 0;
                for (engine.dom_identities.items) |identity| {
                    if (identity.scope_id >= target_scopes.len) return error.ResourceLimit;
                    if (identity.active and target_scopes[@intCast(identity.scope_id)]) dom_count = std.math.add(usize, dom_count, 1) catch return error.ResourceLimit;
                }
                const dom_ids = allocator.alloc(u64, dom_count) catch return error.OutOfMemory;
                errdefer allocator.free(dom_ids);
                var dom_write: usize = 0;
                for (engine.dom_identities.items, 1..) |identity, elem_id| if (identity.active and target_scopes[@intCast(identity.scope_id)]) {
                    dom_ids[dom_write] = elem_id;
                    dom_write += 1;
                };
                return .{ .node_ids = node_ids, .dom_ids = dom_ids };
            }

            fn prepareExactRemoval(engine: *Self, allocator: std.mem.Allocator, retired_scope_ids: []const u64, removal: *const structural_splice.PreparedRemoval) CollectionError!@This() {
                const retired_scopes = allocator.alloc(bool, engine.scopes.items.len) catch return error.OutOfMemory;
                defer allocator.free(retired_scopes);
                @memset(retired_scopes, false);
                for (retired_scope_ids) |scope_id| {
                    if (scope_id >= retired_scopes.len) return error.ResourceLimit;
                    retired_scopes[@intCast(scope_id)] = true;
                }
                const node_members = allocator.alloc(bool, engine.node_identities.items.len) catch return error.OutOfMemory;
                defer allocator.free(node_members);
                @memset(node_members, false);
                for (removal.node_indexes.scope_site_indexes.items) |site_index| {
                    if (site_index >= engine.active_stream.scope_sites.items.len) return error.ResourceLimit;
                    const node_id = engine.active_stream.scope_sites.items[site_index].node_id;
                    if (node_id >= node_members.len) return error.ResourceLimit;
                    node_members[@intCast(node_id)] = true;
                }
                var node_count: usize = 0;
                for (engine.node_identities.items) |identity| {
                    if (identity.scope_id >= retired_scopes.len) return error.ResourceLimit;
                    if (identity.active and (retired_scopes[@intCast(identity.scope_id)] or node_members[@intCast(identity.node_id)])) node_count = std.math.add(usize, node_count, 1) catch return error.ResourceLimit;
                }
                const node_ids = allocator.alloc(u64, node_count) catch return error.OutOfMemory;
                errdefer allocator.free(node_ids);
                var node_write: usize = 0;
                for (engine.node_identities.items) |identity| if (identity.active and (retired_scopes[@intCast(identity.scope_id)] or node_members[@intCast(identity.node_id)])) {
                    node_ids[node_write] = identity.node_id;
                    node_write += 1;
                };

                const dom_members = allocator.alloc(bool, engine.dom_identities.items.len + 1) catch return error.OutOfMemory;
                defer allocator.free(dom_members);
                @memset(dom_members, false);
                for (removal.scan.removed_elem_ids) |elem_id| {
                    if (elem_id == 0 or elem_id >= dom_members.len) return error.ResourceLimit;
                    dom_members[@intCast(elem_id)] = true;
                }
                var dom_count: usize = 0;
                for (engine.dom_identities.items, 1..) |identity, elem_id| {
                    if (identity.scope_id >= retired_scopes.len) return error.ResourceLimit;
                    if (identity.active and (retired_scopes[@intCast(identity.scope_id)] or dom_members[elem_id])) dom_count = std.math.add(usize, dom_count, 1) catch return error.ResourceLimit;
                }
                const dom_ids = allocator.alloc(u64, dom_count) catch return error.OutOfMemory;
                errdefer allocator.free(dom_ids);
                var dom_write: usize = 0;
                for (engine.dom_identities.items, 1..) |identity, elem_id| if (identity.active and (retired_scopes[@intCast(identity.scope_id)] or dom_members[elem_id])) {
                    dom_ids[dom_write] = elem_id;
                    dom_write += 1;
                };
                return .{ .node_ids = node_ids, .dom_ids = dom_ids };
            }

            fn apply(self: *const @This(), engine: *Self) void {
                for (self.node_ids) |node_id| {
                    const identity = &engine.node_identities.items[@intCast(node_id)];
                    if (!engine.active_node_identity_ids.remove(identityKey(identity.scope_id, identity.ordinal))) @panic("prepared node identity retirement no longer matched active index");
                    identity.active = false;
                    identity.retired_at = engine.identity_reuse_barrier;
                }
                for (self.dom_ids) |elem_id| {
                    const identity = &engine.dom_identities.items[@intCast(elem_id - 1)];
                    if (!engine.active_dom_identity_ids.remove(identityKey(identity.scope_id, identity.ordinal))) @panic("prepared DOM identity retirement no longer matched active index");
                    identity.active = false;
                    identity.retired_at = engine.identity_reuse_barrier;
                }
                engine.has_inactive_node_identities = engine.has_inactive_node_identities or self.node_ids.len != 0;
                engine.has_inactive_dom_identities = engine.has_inactive_dom_identities or self.dom_ids.len != 0;
            }

            fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                allocator.free(self.node_ids);
                allocator.free(self.dom_ids);
                self.* = undefined;
            }
        };

        const PreparedStateRetirementIndexes = struct {
            indexes_descending: []usize,

            fn descending(_: void, left: usize, right: usize) bool {
                return left > right;
            }

            fn prepare(engine: *Self, allocator: std.mem.Allocator, descriptor_indexes: []const usize) CollectionError!@This() {
                const indexes = allocator.alloc(usize, descriptor_indexes.len) catch return error.OutOfMemory;
                errdefer allocator.free(indexes);
                for (descriptor_indexes, 0..) |descriptor_index, offset| {
                    if (descriptor_index >= engine.active_stream.states.items.len) return error.ResourceLimit;
                    const node_id = engine.active_stream.states.items[descriptor_index].node_id;
                    if (node_id >= engine.state_indexes_by_node_id.items.len) return error.ResourceLimit;
                    indexes[offset] = engine.state_indexes_by_node_id.items[@intCast(node_id)] orelse return error.ResourceLimit;
                }
                std.mem.sort(usize, indexes, {}, descending);
                if (indexes.len > 1) for (indexes[1..], indexes[0 .. indexes.len - 1]) |current, previous| {
                    if (current == previous) return error.ResourceLimit;
                };
                return .{ .indexes_descending = indexes };
            }

            fn reserveRetired(self: *const @This(), allocator: std.mem.Allocator, retired: *std.ArrayListUnmanaged(HostState)) CollectionError!void {
                retired.ensureUnusedCapacity(allocator, self.indexes_descending.len) catch return error.OutOfMemory;
            }

            fn apply(self: *const @This(), engine: *Self, retired: *std.ArrayListUnmanaged(HostState)) void {
                for (self.indexes_descending) |index| {
                    const removed = engine.states.swapRemove(index);
                    engine.clearStateCellIndex(removed.state_id, index);
                    retired.appendAssumeCapacity(removed);
                    if (index < engine.states.items.len) {
                        const moved = engine.states.items[index];
                        engine.state_indexes_by_node_id.items[@intCast(moved.state_id)] = index;
                    }
                }
            }

            fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                allocator.free(self.indexes_descending);
                self.* = undefined;
            }
        };

        fn prepareRowRetirementForScopes(engine: *Self, allocator: std.mem.Allocator, scope_ids: []const u64) CollectionError!each_runtime.PreparedRowRemovals {
            var removals: std.ArrayListUnmanaged(each_runtime.RowRemoval) = .empty;
            defer removals.deinit(allocator);
            removals.ensureTotalCapacity(allocator, scope_ids.len) catch return error.OutOfMemory;
            for (scope_ids) |scope_id| {
                if (scope_id >= engine.scopes.items.len) return error.ResourceLimit;
                switch (engine.scopes.items[@intCast(scope_id)].step) {
                    .each_row => |row| removals.appendAssumeCapacity(.{ .scope_id = scope_id, .key_hash = row.key_hash }),
                    .root, .component, .when_branch => {},
                }
            }
            return each_runtime.prepareRowRemovals(allocator, engine.each_row_sites.items, engine.each_row_memberships_by_scope_id.items, removals.items) catch return error.OutOfMemory;
        }

        const PreparedEffectRetirements = struct {
            task_indexes_descending: []usize = &.{},
            retired_tasks: std.ArrayListUnmanaged(HostPendingTask) = .empty,
            cleanup_names: std.ArrayListUnmanaged([]const u8) = .empty,

            fn descending(_: void, left: usize, right: usize) bool {
                return left > right;
            }

            fn prepare(engine: *Self, allocator: std.mem.Allocator, target_scopes: []const bool, cleanup_indexes: []const usize) CollectionError!@This() {
                var self: @This() = .{};
                errdefer self.deinit(allocator, null);
                var task_count: usize = 0;
                for (engine.pending_tasks.items) |task| {
                    if (task.owner_scope_id >= target_scopes.len) return error.ResourceLimit;
                    if (target_scopes[@intCast(task.owner_scope_id)]) task_count = std.math.add(usize, task_count, 1) catch return error.ResourceLimit;
                }
                self.task_indexes_descending = allocator.alloc(usize, task_count) catch return error.OutOfMemory;
                var write: usize = 0;
                for (engine.pending_tasks.items, 0..) |task, index| if (target_scopes[@intCast(task.owner_scope_id)]) {
                    self.task_indexes_descending[write] = index;
                    write += 1;
                };
                std.mem.sort(usize, self.task_indexes_descending, {}, descending);
                self.retired_tasks.ensureUnusedCapacity(allocator, task_count) catch return error.OutOfMemory;
                self.cleanup_names.ensureTotalCapacity(allocator, cleanup_indexes.len) catch return error.OutOfMemory;
                for (cleanup_indexes) |cleanup_index| {
                    if (cleanup_index >= engine.active_stream.cleanups.items.len) return error.ResourceLimit;
                    const name = allocator.dupe(u8, engine.active_stream.cleanups.items[cleanup_index].name) catch return error.OutOfMemory;
                    self.cleanup_names.appendAssumeCapacity(name);
                }
                engine.cleanup_events.ensureUnusedCapacity(allocator, self.cleanup_names.items.len) catch return error.OutOfMemory;
                return self;
            }

            fn apply(self: *@This(), engine: *Self, ctx: Ctx.Handle) void {
                for (self.task_indexes_descending) |index| {
                    const task = effects_runtime.removePendingTaskAt(&engine.pending_tasks, index);
                    if (task.active) Ctx.sink(ctx).cancelTask(task.request_id);
                    self.retired_tasks.appendAssumeCapacity(task);
                }
                engine.cleanup_events.appendSliceAssumeCapacity(self.cleanup_names.items);
                self.cleanup_names.items.len = 0;
            }

            fn deinit(self: *@This(), allocator: std.mem.Allocator, roc_host: ?*abi.RocHost) void {
                allocator.free(self.task_indexes_descending);
                if (roc_host) |host| for (self.retired_tasks.items) |*task| effects_runtime.deinitPendingTask(allocator, host, task);
                self.retired_tasks.deinit(allocator);
                for (self.cleanup_names.items) |name| allocator.free(name);
                self.cleanup_names.deinit(allocator);
                self.* = undefined;
            }
        };

        const PreparedEachRowSubtreeRetirement = struct {
            targets: ?PreparedStructuralTargets = null,
            identities: ?PreparedIdentityRetirements = null,
            states: ?PreparedStateRetirementIndexes = null,
            rows: ?each_runtime.PreparedRowRemovals = null,
            effects: ?PreparedEffectRetirements = null,
            retired_states: std.ArrayListUnmanaged(HostState) = .empty,
            retired_steps: std.ArrayListUnmanaged(HostScopeStep) = .empty,

            fn prepare(engine: *Self, allocator: std.mem.Allocator, removed_root_scope_ids: []const u64) CollectionError!@This() {
                return prepareWithTargets(engine, allocator, removed_root_scope_ids, removed_root_scope_ids);
            }

            fn prepareWithTargets(engine: *Self, allocator: std.mem.Allocator, descriptor_root_scope_ids: []const u64, removed_root_scope_ids: []const u64) CollectionError!@This() {
                var self: @This() = .{};
                errdefer self.deinit(engine, allocator, null, null);
                self.targets = try PreparedStructuralTargets.prepare(engine, allocator, descriptor_root_scope_ids, removed_root_scope_ids);
                const target_scopes = self.targets.?.descriptor_target_scopes;
                const retirement_scope_ids = self.targets.?.scope_retirement.?.scope_ids;
                self.identities = try PreparedIdentityRetirements.prepare(engine, allocator, target_scopes);

                var state_indexes: std.ArrayListUnmanaged(usize) = .empty;
                defer state_indexes.deinit(allocator);
                state_indexes.ensureTotalCapacity(allocator, engine.active_stream.states.items.len) catch return error.OutOfMemory;
                for (engine.active_stream.states.items, 0..) |state, state_index| {
                    const node_index = engine.active_stream.nodeDescriptorIndex(state.node_id) orelse return error.ResourceLimit;
                    const site_index = node_index.scope_sites.get(.state) orelse return error.ResourceLimit;
                    if (site_index >= engine.active_stream.scope_sites.items.len) return error.ResourceLimit;
                    const owner = engine.active_stream.scope_sites.items[site_index].scope_id;
                    if (owner >= target_scopes.len) return error.ResourceLimit;
                    if (target_scopes[@intCast(owner)]) state_indexes.appendAssumeCapacity(state_index);
                }
                self.states = try PreparedStateRetirementIndexes.prepare(engine, allocator, state_indexes.items);
                try self.states.?.reserveRetired(allocator, &self.retired_states);
                self.rows = try prepareRowRetirementForScopes(engine, allocator, retirement_scope_ids);

                var cleanup_indexes: std.ArrayListUnmanaged(usize) = .empty;
                defer cleanup_indexes.deinit(allocator);
                for (target_scopes, 0..) |targeted, scope_id| if (targeted) {
                    for (engine.active_stream.lifecycleIndices(scope_id)) |lifecycle| if (lifecycle.kind == .cleanup) {
                        cleanup_indexes.append(allocator, lifecycle.index) catch return error.OutOfMemory;
                    };
                };
                self.effects = try PreparedEffectRetirements.prepare(engine, allocator, target_scopes, cleanup_indexes.items);
                self.retired_steps.ensureUnusedCapacity(allocator, retirement_scope_ids.len) catch return error.OutOfMemory;
                return self;
            }

            fn applyBeforeRowCommit(self: *@This(), engine: *Self) void {
                self.states.?.apply(engine, &self.retired_states);
                self.identities.?.apply(engine);
                var row_keys = EachRowScopeKeyLookup{ .engine = engine };
                self.rows.?.apply(&engine.each_row_sites, &engine.each_row_memberships_by_scope_id, &row_keys);
            }

            fn refineDescriptorOwnedRetirement(self: *@This(), engine: *Self, allocator: std.mem.Allocator, removal: *const structural_splice.PreparedRemoval) CollectionError!void {
                const retirement_scope_ids = self.targets.?.scope_retirement.?.scope_ids;
                var exact_identities = try PreparedIdentityRetirements.prepareExactRemoval(engine, allocator, retirement_scope_ids, removal);
                errdefer exact_identities.deinit(allocator);
                const retired_scopes = allocator.alloc(bool, engine.scopes.items.len) catch return error.OutOfMemory;
                defer allocator.free(retired_scopes);
                @memset(retired_scopes, false);
                for (retirement_scope_ids) |scope_id| retired_scopes[@intCast(scope_id)] = true;
                var exact_effects = try PreparedEffectRetirements.prepare(engine, allocator, retired_scopes, removal.node_indexes.cleanup_indexes.items);
                errdefer exact_effects.deinit(allocator, null);
                self.identities.?.deinit(allocator);
                self.identities = exact_identities;
                self.effects.?.deinit(allocator, null);
                self.effects = exact_effects;
            }

            fn applyAfterRowCommit(self: *@This(), engine: *Self) void {
                const scope_retirement = &self.targets.?.scope_retirement.?;
                for (scope_retirement.scope_ids) |scope_id| {
                    const scope = &engine.scopes.items[@intCast(scope_id)];
                    self.retired_steps.appendAssumeCapacity(scope.step);
                    scope.step = .root;
                }
                scope_retirement.applyMetadata(HostEachRowScopeStep, engine.scopes.items, engine.identity_reuse_barrier);
                engine.has_inactive_scopes = scope_retirement.scope_ids.len != 0 or engine.has_inactive_scopes;
            }

            fn applyEffectsAfterPublication(self: *@This(), engine: *Self, ctx: Ctx.Handle) void {
                self.effects.?.apply(engine, ctx);
            }

            fn deinit(self: *@This(), engine: *Self, allocator: std.mem.Allocator, ctx: ?Ctx.Handle, roc_host: ?*abi.RocHost) void {
                if (ctx) |host_ctx| if (roc_host) |host| {
                    for (self.retired_states.items) |*state| state.cell.deinit(host_ctx, host, &engine.pending_roc_metrics);
                    for (self.retired_steps.items) |*step| deinitHostScopeStep(step, host_ctx, host, &engine.pending_roc_metrics);
                };
                self.retired_states.deinit(allocator);
                self.retired_steps.deinit(allocator);
                if (self.effects) |*effects| effects.deinit(allocator, roc_host);
                if (self.rows) |*rows| rows.deinit(allocator);
                if (self.states) |*states| states.deinit(allocator);
                if (self.identities) |*identities| identities.deinit(allocator);
                if (self.targets) |*targets| targets.deinit(allocator);
                self.* = undefined;
            }
        };

        const PreparedEachRowReplacementCollection = struct {
            const RowElem = struct {
                row_index: usize,
                elem: abi.Elem,
            };
            const ReplacementRow = struct {
                row_index: usize,
                scope_id: u64,
                start: usize,
                len: usize,
            };

            engine: *Self,
            host_ctx: Ctx.Handle,
            roc_host: *abi.RocHost,
            replacement: *PreparedReplacementOwner = undefined,
            row_elems: []RowElem = &.{},
            replacement_rows: []ReplacementRow = &.{},
            committed: bool = false,

            fn prepare(engine: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, site: HostNodeScopeSiteDesc, each: HostNodeEachDesc, rows: *const each_runtime.PreparedRowSync, keys: []const HostValue, items: []const HostValue, limits: collection_budget.Limits, dirty_source_node_ids: []const u64) CollectionError!*@This() {
                if (keys.len != items.len or keys.len != rows.next_scope_ids.len) return error.ResourceLimit;
                const allocator = Ctx.allocator(ctx);
                const plan = allocator.create(@This()) catch return error.OutOfMemory;
                errdefer allocator.destroy(plan);
                plan.* = .{ .engine = engine, .host_ctx = ctx, .roc_host = roc_host };

                var changed_count: usize = 0;
                for (rows.row_items_changed) |changed| if (changed) {
                    changed_count = std.math.add(usize, changed_count, 1) catch return error.ResourceLimit;
                };
                plan.row_elems = allocator.alloc(RowElem, changed_count) catch return error.OutOfMemory;
                errdefer allocator.free(plan.row_elems);
                plan.replacement_rows = allocator.alloc(ReplacementRow, changed_count) catch return error.OutOfMemory;
                errdefer allocator.free(plan.replacement_rows);
                var evaluated: usize = 0;
                errdefer for (plan.row_elems[0..evaluated]) |*entry| entry.elem.decref(roc_host);
                var total: StaticRootCounts = .{};
                for (rows.row_items_changed, keys, items, 0..) |changed, key, item, row_index| {
                    if (!changed) continue;
                    const elem = callHostValueHostValueToElemWithCapabilities(ctx, roc_host, each.ops.key_capability, each.ops.item_capability, each.ops.row, key, item);
                    plan.row_elems[evaluated] = .{ .row_index = row_index, .elem = elem };
                    evaluated += 1;
                    try AggregateBranchCollection.addCounts(&total, try countStaticRootNodes(elem));
                }

                plan.replacement = try PreparedReplacementOwner.create(engine, ctx, roc_host, limits, total, rows.created_count);
                errdefer plan.replacement.deinit();
                const created_scope_ids = allocator.alloc(u64, rows.created_count) catch return error.OutOfMemory;
                defer allocator.free(created_scope_ids);
                var created_write: usize = 0;
                for (rows.next_scope_ids, rows.scope_created) |scope_id, created| if (created) {
                    created_scope_ids[created_write] = scope_id;
                    created_write += 1;
                };
                try plan.replacement.collection.attachExternalScopeIds(created_scope_ids);

                for (plan.row_elems, 0..) |*entry, replacement_index| {
                    const row_index = entry.row_index;
                    const row_scope_id = rows.next_scope_ids[row_index];
                    var binder_stack: std.ArrayListUnmanaged(HostBinderBinding) = .empty;
                    defer binder_stack.deinit(allocator);
                    const counts = try countStaticRootNodes(entry.elem);
                    const binder_capacity = std.math.add(usize, site.binder_bindings.len, counts.state_sites) catch return error.ResourceLimit;
                    binder_stack.ensureTotalCapacity(allocator, binder_capacity) catch return error.OutOfMemory;
                    binder_stack.appendSliceAssumeCapacity(site.binder_bindings);
                    var ordinal: u64 = 0;
                    var dom_ordinal: u64 = 0;
                    const render_start = plan.replacement.collection.prepared_render_order.items.len;
                    try engine.collectActiveEachRowElemDescriptorsWith(*StagedCollectionCtx, &plan.replacement.collection, ctx, roc_host, &plan.replacement.stream, each, entry.elem, row_scope_id, site.parent_elem_id, &ordinal, &dom_ordinal, &binder_stack, rows.scope_created[row_index], dirty_source_node_ids);
                    plan.replacement_rows[replacement_index] = .{
                        .row_index = row_index,
                        .scope_id = row_scope_id,
                        .start = render_start,
                        .len = plan.replacement.collection.prepared_render_order.items.len - render_start,
                    };
                }
                plan.replacement.collection.materializeStream();
                for (plan.row_elems) |*entry| entry.elem.decref(roc_host);
                allocator.free(plan.row_elems);
                plan.row_elems = &.{};
                return plan;
            }

            fn commit(self: *@This()) void {
                if (self.committed) @panic("prepared each replacement collection committed twice");
                self.replacement.collection.commit();
                self.committed = true;
            }

            fn deinit(self: *@This()) void {
                const allocator = Ctx.allocator(self.host_ctx);
                for (self.row_elems) |*entry| entry.elem.decref(self.roc_host);
                allocator.free(self.row_elems);
                allocator.free(self.replacement_rows);
                self.replacement.deinit();
                allocator.destroy(self);
            }
        };

        const PreparedEachRowRenderLayout = struct {
            allocator: std.mem.Allocator,
            targets: PreparedStructuralTargets,
            remove_starts: []usize,
            final_starts: []usize,
            survivor_moves: []HostEachRowRenderMove,
            removal: structural_splice.PreparedMultiRemoval,

            fn prepare(engine: *Self, allocator: std.mem.Allocator, site: HostNodeScopeSiteDesc, rows: *const each_runtime.PreparedRowSync, replacements: []const PreparedEachRowReplacementCollection.ReplacementRow) CollectionError!@This() {
                var segments: std.ArrayListUnmanaged(HostEachRowRenderSegment) = .empty;
                defer segments.deinit(allocator);
                var by_scope: std.AutoHashMapUnmanaged(u64, usize) = .empty;
                defer by_scope.deinit(allocator);
                var render_index: usize = 0;
                const each_site = HostEachSite{ .parent_scope_id = site.scope_id, .site_ordinal = site.ordinal };
                while (render_index < engine.active_stream.render_nodes.items.len) {
                    const scope_id = renderNodeScopeId(&engine.active_stream, engine.active_stream.render_nodes.items[render_index]);
                    const row_scope_id = (engine.eachSiteRowAncestorScopeId(scope_id, each_site) catch return error.ResourceLimit) orelse {
                        render_index += 1;
                        continue;
                    };
                    const start = render_index;
                    render_index += 1;
                    while (render_index < engine.active_stream.render_nodes.items.len) : (render_index += 1) {
                        const next_scope = renderNodeScopeId(&engine.active_stream, engine.active_stream.render_nodes.items[render_index]);
                        const next_row = engine.eachSiteRowAncestorScopeId(next_scope, each_site) catch return error.ResourceLimit;
                        if (next_row == null or next_row.? != row_scope_id) break;
                    }
                    const index = segments.items.len;
                    segments.append(allocator, .{ .scope_id = row_scope_id, .start = start, .len = render_index - start }) catch return error.OutOfMemory;
                    const entry = by_scope.getOrPut(allocator, row_scope_id) catch return error.OutOfMemory;
                    if (entry.found_existing) return error.ResourceLimit;
                    entry.value_ptr.* = index;
                }

                var descriptor_roots: std.ArrayListUnmanaged(u64) = .empty;
                defer descriptor_roots.deinit(allocator);
                descriptor_roots.ensureTotalCapacity(allocator, std.math.add(usize, rows.removed_scope_ids.len, replacements.len) catch return error.ResourceLimit) catch return error.OutOfMemory;
                descriptor_roots.appendSliceAssumeCapacity(rows.removed_scope_ids);
                var remove_starts_list: std.ArrayListUnmanaged(usize) = .empty;
                defer remove_starts_list.deinit(allocator);
                remove_starts_list.ensureTotalCapacity(allocator, std.math.add(usize, rows.removed_scope_ids.len, replacements.len) catch return error.ResourceLimit) catch return error.OutOfMemory;
                for (rows.removed_scope_ids) |scope_id| {
                    const segment_index = by_scope.get(scope_id) orelse return error.ResourceLimit;
                    remove_starts_list.appendAssumeCapacity(segments.items[segment_index].start);
                }
                for (replacements) |replacement| if (!rows.scope_created[replacement.row_index]) {
                    const segment_index = by_scope.get(replacement.scope_id) orelse return error.ResourceLimit;
                    remove_starts_list.appendAssumeCapacity(segments.items[segment_index].start);
                    descriptor_roots.appendAssumeCapacity(replacement.scope_id);
                };
                var targets = try PreparedStructuralTargets.prepare(engine, allocator, descriptor_roots.items, rows.removed_scope_ids);
                errdefer targets.deinit(allocator);
                const target_scopes = targets.descriptor_target_scopes;
                remove_starts_list.clearRetainingCapacity();
                var inside_target = false;
                for (engine.active_stream.render_nodes.items, 0..) |node, index| {
                    const scope_id = renderNodeScopeId(&engine.active_stream, node);
                    if (scope_id >= target_scopes.len) return error.ResourceLimit;
                    const targeted = target_scopes[@intCast(scope_id)];
                    if (targeted and !inside_target) remove_starts_list.appendAssumeCapacity(index);
                    inside_target = targeted;
                }
                const remove_starts = remove_starts_list.toOwnedSlice(allocator) catch return error.OutOfMemory;
                errdefer allocator.free(remove_starts);
                const removal = structural_splice.prepareMultiRemoval(HostNodeDescriptorStream, allocator, &engine.active_stream, remove_starts, target_scopes) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.OverlappingIntervals => return error.ResourceLimit,
                };
                errdefer {
                    var mutable = removal;
                    mutable.deinit(allocator);
                }

                const final_starts = allocator.alloc(usize, rows.next_scope_ids.len) catch return error.OutOfMemory;
                errdefer allocator.free(final_starts);
                const survivor_count = std.math.sub(usize, rows.next_scope_ids.len, replacements.len) catch return error.ResourceLimit;
                const survivor_moves = allocator.alloc(HostEachRowRenderMove, survivor_count) catch return error.OutOfMemory;
                errdefer allocator.free(survivor_moves);
                var next_start = site.render_insert_index;
                var move_write: usize = 0;
                for (rows.next_scope_ids, 0..) |scope_id, row_index| {
                    final_starts[row_index] = next_start;
                    var replacement_len: ?usize = null;
                    for (replacements) |replacement| if (replacement.row_index == row_index) {
                        replacement_len = replacement.len;
                        break;
                    };
                    if (replacement_len) |len| {
                        next_start = std.math.add(usize, next_start, len) catch return error.ResourceLimit;
                    } else {
                        const segment_index = by_scope.get(scope_id) orelse return error.ResourceLimit;
                        const segment = segments.items[segment_index];
                        survivor_moves[move_write] = .{ .old_start = segment.start, .new_start = next_start, .len = segment.len };
                        move_write += 1;
                        next_start = std.math.add(usize, next_start, segment.len) catch return error.ResourceLimit;
                    }
                }
                if (move_write != survivor_moves.len) return error.ResourceLimit;
                return .{ .allocator = allocator, .targets = targets, .remove_starts = remove_starts, .final_starts = final_starts, .survivor_moves = survivor_moves, .removal = removal };
            }

            fn deinit(self: *@This()) void {
                self.removal.deinit(self.allocator);
                self.allocator.free(self.survivor_moves);
                self.allocator.free(self.final_starts);
                self.allocator.free(self.remove_starts);
                self.targets.deinit(self.allocator);
                self.* = undefined;
            }
        };

        fn prepareRetiredStreamCapacity(engine: *Self, allocator: std.mem.Allocator, retired: *HostNodeDescriptorStream, removal: *const structural_splice.PreparedRemoval, retired_scope_ids: []const u64) CollectionError!void {
            const indexes = &removal.descriptor_indexes;
            retired.reserveRetiredStaticPublication(
                allocator,
                indexes.element_indexes.items.len,
                indexes.text_node_indexes.items.len,
                indexes.static_text_attr_indexes.items.len,
                indexes.static_bool_attr_indexes.items.len,
                indexes.signal_text_node_indexes.items.len,
                indexes.signal_text_attr_indexes.items.len,
                indexes.signal_bool_attr_indexes.items.len,
                engine.active_stream.signal_records_by_token.count(),
                indexes.event_indexes.items.len,
                removal.scan.removed_elem_ids,
                &engine.active_stream,
                removal.node_indexes.scope_site_indexes.items,
                removal.node_indexes.state_indexes.items.len,
                removal.node_indexes.when_indexes.items.len,
                removal.node_indexes.each_indexes.items.len,
            ) catch return error.OutOfMemory;
            retired.reserveRetiredCustomPublication(
                allocator,
                &engine.active_stream,
                removal.scan.removed_elem_ids,
                indexes.static_custom_text_attr_indexes.items.len,
                indexes.signal_custom_text_attr_indexes.items.len,
                indexes.signal_optional_custom_text_attr_indexes.items.len,
                indexes.static_custom_bool_attr_indexes.items.len,
                indexes.signal_custom_bool_attr_indexes.items.len,
            ) catch return error.OutOfMemory;
            retired.reserveRetiredLifecyclePublication(
                allocator,
                &engine.active_stream,
                retired_scope_ids,
                removal.node_indexes.on_change_indexes.items.len,
                removal.node_indexes.mount_indexes.items.len,
                removal.node_indexes.cleanup_indexes.items.len,
            ) catch return error.OutOfMemory;
        }

        fn collectRetiredGraphRootsForRemoval(engine: *Self, allocator: std.mem.Allocator, removal: *const structural_splice.PreparedRemoval, roots: *std.ArrayListUnmanaged(*HostSignalRecord)) CollectionError!void {
            const indexes = &removal.descriptor_indexes;
            for (indexes.signal_text_node_indexes.items) |index| roots.append(allocator, engine.active_stream.signal_text_nodes.items[index].signal.record) catch return error.OutOfMemory;
            for (indexes.signal_text_attr_indexes.items) |index| roots.append(allocator, engine.active_stream.signal_text_attrs.items[index].signal.record) catch return error.OutOfMemory;
            for (indexes.signal_custom_text_attr_indexes.items) |index| roots.append(allocator, engine.active_stream.signal_custom_text_attrs.items[index].signal.record) catch return error.OutOfMemory;
            for (indexes.signal_optional_custom_text_attr_indexes.items) |index| roots.append(allocator, engine.active_stream.signal_optional_custom_text_attrs.items[index].signal.record) catch return error.OutOfMemory;
            for (indexes.signal_bool_attr_indexes.items) |index| roots.append(allocator, engine.active_stream.signal_bool_attrs.items[index].signal.record) catch return error.OutOfMemory;
            for (indexes.signal_custom_bool_attr_indexes.items) |index| roots.append(allocator, engine.active_stream.signal_custom_bool_attrs.items[index].signal.record) catch return error.OutOfMemory;
            for (removal.node_indexes.on_change_indexes.items) |index| roots.append(allocator, engine.active_stream.on_changes.items[index].signal.record) catch return error.OutOfMemory;
            for (removal.node_indexes.when_indexes.items) |index| roots.append(allocator, engine.active_stream.whens.items[index].condition.record) catch return error.OutOfMemory;
            for (removal.node_indexes.each_indexes.items) |index| roots.append(allocator, engine.active_stream.eaches.items[index].items.record) catch return error.OutOfMemory;
        }

        fn collectReplacementGraphRootsForStream(allocator: std.mem.Allocator, stream: *HostNodeDescriptorStream, roots: *std.ArrayListUnmanaged(*HostSignalRecord)) CollectionError!void {
            for (stream.signal_text_nodes.items) |*desc| roots.append(allocator, desc.signal.record) catch return error.OutOfMemory;
            for (stream.signal_text_attrs.items) |*desc| roots.append(allocator, desc.signal.record) catch return error.OutOfMemory;
            for (stream.signal_custom_text_attrs.items) |*desc| roots.append(allocator, desc.signal.record) catch return error.OutOfMemory;
            for (stream.signal_optional_custom_text_attrs.items) |*desc| roots.append(allocator, desc.signal.record) catch return error.OutOfMemory;
            for (stream.signal_bool_attrs.items) |*desc| roots.append(allocator, desc.signal.record) catch return error.OutOfMemory;
            for (stream.signal_custom_bool_attrs.items) |*desc| roots.append(allocator, desc.signal.record) catch return error.OutOfMemory;
            for (stream.on_changes.items) |*desc| roots.append(allocator, desc.signal.record) catch return error.OutOfMemory;
            for (stream.whens.items) |*desc| roots.append(allocator, desc.condition.record) catch return error.OutOfMemory;
            for (stream.eaches.items) |*desc| roots.append(allocator, desc.items.record) catch return error.OutOfMemory;
        }

        const PreparedStructuralTargets = struct {
            descriptor_target_scopes: []bool = &.{},
            scope_retirement: ?scope_runtime.PreparedSubtreeRetirement = null,

            fn prepare(engine: *Self, allocator: std.mem.Allocator, descriptor_root_scope_ids: []const u64, retired_root_scope_ids: []const u64) CollectionError!@This() {
                var prepared: @This() = .{};
                errdefer prepared.deinit(allocator);
                prepared.descriptor_target_scopes = allocator.alloc(bool, engine.scopes.items.len) catch return error.OutOfMemory;
                @memset(prepared.descriptor_target_scopes, false);
                for (descriptor_root_scope_ids) |root_scope_id| {
                    if (root_scope_id >= engine.scopes.items.len) return error.ResourceLimit;
                    for (engine.scopes.items) |scope| {
                        if (engine.scopeIsDescendantOrSelf(scope.scope_id, root_scope_id) catch return error.ResourceLimit) {
                            prepared.descriptor_target_scopes[@intCast(scope.scope_id)] = true;
                        }
                    }
                }
                prepared.scope_retirement = scope_runtime.prepareSubtreesRetirement(HostEachRowScopeStep, allocator, engine.scopes.items, retired_root_scope_ids) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.OverlappingSubtrees => return error.ResourceLimit,
                };
                for (prepared.scope_retirement.?.scope_ids) |scope_id| {
                    if (scope_id >= prepared.descriptor_target_scopes.len or !prepared.descriptor_target_scopes[@intCast(scope_id)]) return error.ResourceLimit;
                }
                return prepared;
            }

            fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                if (self.scope_retirement) |*retirement| retirement.deinit(allocator);
                allocator.free(self.descriptor_target_scopes);
                self.* = .{};
            }
        };

        const PreparedReplacementOwner = struct {
            engine: *Self,
            host_ctx: Ctx.Handle,
            roc_host: *abi.RocHost,
            stream: HostNodeDescriptorStream = .{},
            collection: StagedCollectionCtx = undefined,

            fn create(engine: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, limits: collection_budget.Limits, counts: StaticRootCounts, expected_roots: usize) CollectionError!*@This() {
                const allocator = Ctx.allocator(ctx);
                const owner = allocator.create(@This()) catch return error.OutOfMemory;
                errdefer allocator.destroy(owner);
                owner.* = .{ .engine = engine, .host_ctx = ctx, .roc_host = roc_host };
                errdefer owner.stream.deinit(allocator, ctx, roc_host, &engine.pending_roc_metrics);
                owner.collection = try StagedCollectionCtx.init(engine, ctx, &owner.stream, limits, counts.nodes, counts.attrs, counts.lifecycle, counts.signal_records, counts.state_sites, counts.component_sites, counts.when_sites, expected_roots);
                return owner;
            }

            fn deinit(self: *@This()) void {
                const allocator = Ctx.allocator(self.host_ctx);
                self.collection.deinit();
                self.stream.deinit(allocator, self.host_ctx, self.roc_host, &self.engine.pending_roc_metrics);
                allocator.destroy(self);
            }
        };

        const PreparedStructuralDownstream = struct {
            const HostRenderPublication = if (@hasDecl(Ctx, "RenderPublication")) Ctx.RenderPublication else void;
            engine: *Self,
            host_ctx: Ctx.Handle,
            roc_host: *abi.RocHost,
            replacement: *PreparedReplacementOwner = undefined,
            replacement_scope_ids: []u64 = &.{},
            targets: ?PreparedStructuralTargets = null,
            removal: ?structural_splice.PreparedMultiRemoval = null,
            identity_retirements: ?PreparedIdentityRetirements = null,
            state_retirement: ?PreparedStateRetirementIndexes = null,
            retired_state_cells: std.ArrayListUnmanaged(HostState) = .empty,
            row_retirement: ?each_runtime.PreparedRowRemovals = null,
            effects_retirement: ?PreparedEffectRetirements = null,
            retired_stream: HostNodeDescriptorStream = .{},
            publication: ?structural_splice.PreparedPublicationDeltas = null,
            graph_release: ?active_graph.PreparedReleaseClosure(HostSignalRecord) = null,
            graph_append: ?active_graph.PreparedGraphAppend(HostSignalRecord) = null,
            sink_edits: ?active_graph.PreparedSinkRouteEdits = null,
            source_route_appends: ?active_graph.PreparedRouteAppends(u64) = null,
            text_route_appends: ?active_graph.PreparedRouteAppends(active_graph.TextSink) = null,
            bool_route_appends: ?active_graph.PreparedRouteAppends(active_graph.BoolSink) = null,
            change_route_appends: ?active_graph.PreparedRouteAppends(active_graph.ChangeSink) = null,
            structural_route_appends: ?active_graph.PreparedRouteAppends(active_graph.StructuralSink) = null,
            graph_source_route_count: usize = 0,
            render_splice: ?render_cache_mod.PreparedRenderSplice(Ctx) = null,
            render_batch: render.TransactionalBatch = .{},
            render_batch_target: ?*render.TransactionalBatch = null,
            render_batch_preflighted: bool = false,
            render_batch_published: bool = false,
            host_render_publication: ?HostRenderPublication = null,
            host_render_published: bool = false,
            retired_scope_steps: std.ArrayListUnmanaged(HostScopeStep) = .empty,

            fn addCounts(total: *StaticRootCounts, next: StaticRootCounts) CollectionError!void {
                total.nodes = std.math.add(usize, total.nodes, next.nodes) catch return error.ResourceLimit;
                total.attrs = std.math.add(usize, total.attrs, next.attrs) catch return error.ResourceLimit;
                total.lifecycle = std.math.add(usize, total.lifecycle, next.lifecycle) catch return error.ResourceLimit;
                total.signal_records = std.math.add(usize, total.signal_records, next.signal_records) catch return error.ResourceLimit;
                total.state_sites = std.math.add(usize, total.state_sites, next.state_sites) catch return error.ResourceLimit;
                total.component_sites = std.math.add(usize, total.component_sites, next.component_sites) catch return error.ResourceLimit;
                total.when_sites = std.math.add(usize, total.when_sites, next.when_sites) catch return error.ResourceLimit;
            }

            fn prepare(engine: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, selections: []const AggregateBranchSelection, limits: collection_budget.Limits, dirty_source_node_ids: []const u64) CollectionError!*@This() {
                if (selections.len == 0) return error.ResourceLimit;
                var total: StaticRootCounts = .{};
                for (selections) |selection| try addCounts(&total, try countStaticRootNodes(selection.elem));

                const allocator = Ctx.allocator(ctx);
                const plan = allocator.create(@This()) catch return error.OutOfMemory;
                errdefer allocator.destroy(plan);
                plan.* = .{ .engine = engine, .host_ctx = ctx, .roc_host = roc_host };
                errdefer plan.retired_stream.deinit(allocator, ctx, roc_host, &engine.pending_roc_metrics);
                plan.replacement = try PreparedReplacementOwner.create(engine, ctx, roc_host, limits, total, selections.len);
                errdefer plan.replacement.deinit();
                plan.replacement_scope_ids = allocator.alloc(u64, selections.len) catch return error.OutOfMemory;
                errdefer allocator.free(plan.replacement_scope_ids);

                for (selections, 0..) |selection, index| {
                    try plan.replacement.collection.validateScope(selection.parent_scope_id);
                    const branch_scope = try plan.replacement.collection.reserveWhenBranchScope(selection.parent_scope_id, selection.site_ordinal, selection.branch);
                    if (!branch_scope.created) return error.ResourceLimit;
                    plan.replacement_scope_ids[index] = branch_scope.scope_id;

                    var binder_stack: std.ArrayListUnmanaged(HostBinderBinding) = .empty;
                    defer binder_stack.deinit(allocator);
                    const branch_count = try countStaticRootNodes(selection.elem);
                    const binder_capacity = std.math.add(usize, selection.binder_bindings.len, branch_count.state_sites) catch return error.ResourceLimit;
                    binder_stack.ensureTotalCapacity(allocator, binder_capacity) catch return error.OutOfMemory;
                    binder_stack.appendSliceAssumeCapacity(selection.binder_bindings);
                    var ordinal: u64 = 0;
                    var dom_ordinal: u64 = 0;
                    try engine.collectActiveElemDescriptorsWith(*StagedCollectionCtx, &plan.replacement.collection, ctx, roc_host, &plan.replacement.stream, selection.elem, branch_scope.scope_id, selection.parent_elem_id, &ordinal, &dom_ordinal, &binder_stack, true, dirty_source_node_ids);
                }
                plan.replacement.collection.materializeStream();

                const retired_scope_ids = allocator.alloc(u64, selections.len) catch return error.OutOfMemory;
                defer allocator.free(retired_scope_ids);
                const render_insert_indexes = allocator.alloc(usize, selections.len) catch return error.OutOfMemory;
                defer allocator.free(render_insert_indexes);
                for (selections, 0..) |selection, index| {
                    retired_scope_ids[index] = selection.retired_scope_id;
                    render_insert_indexes[index] = selection.render_insert_index;
                }
                try plan.prepareDownstream(allocator, retired_scope_ids, retired_scope_ids, render_insert_indexes);
                return plan;
            }

            fn prepareDownstream(self: *@This(), allocator: std.mem.Allocator, descriptor_root_scope_ids: []const u64, retired_root_scope_ids: []const u64, render_insert_indexes: []const usize) CollectionError!void {
                self.targets = try PreparedStructuralTargets.prepare(self.engine, allocator, descriptor_root_scope_ids, retired_root_scope_ids);
                errdefer if (self.targets) |*targets| targets.deinit(allocator);
                const target_scopes = self.targets.?.descriptor_target_scopes;
                const retirement_scope_ids = self.targets.?.scope_retirement.?.scope_ids;
                self.removal = structural_splice.prepareMultiRemoval(HostNodeDescriptorStream, allocator, &self.engine.active_stream, render_insert_indexes, target_scopes) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.OverlappingIntervals => return error.ResourceLimit,
                };
                errdefer if (self.removal) |*removal| removal.deinit(allocator);
                self.identity_retirements = try PreparedIdentityRetirements.prepareExactRemoval(self.engine, allocator, retirement_scope_ids, &self.removal.?.removal);
                errdefer if (self.identity_retirements) |*retirements| retirements.deinit(allocator);
                self.state_retirement = try PreparedStateRetirementIndexes.prepare(self.engine, allocator, self.removal.?.removal.node_indexes.state_indexes.items);
                errdefer if (self.state_retirement) |*retirement| retirement.deinit(allocator);
                try self.state_retirement.?.reserveRetired(allocator, &self.retired_state_cells);
                errdefer self.retired_state_cells.deinit(allocator);
                self.row_retirement = try prepareRowRetirementForScopes(self.engine, allocator, retirement_scope_ids);
                errdefer if (self.row_retirement) |*retirement| retirement.deinit(allocator);
                const retired_scopes = allocator.alloc(bool, self.engine.scopes.items.len) catch return error.OutOfMemory;
                defer allocator.free(retired_scopes);
                @memset(retired_scopes, false);
                for (retirement_scope_ids) |scope_id| retired_scopes[@intCast(scope_id)] = true;
                self.effects_retirement = try PreparedEffectRetirements.prepare(self.engine, allocator, retired_scopes, self.removal.?.removal.node_indexes.cleanup_indexes.items);
                errdefer if (self.effects_retirement) |*effects| effects.deinit(allocator, null);
                self.retired_scope_steps.ensureUnusedCapacity(allocator, retirement_scope_ids.len) catch return error.OutOfMemory;
                errdefer self.retired_scope_steps.deinit(allocator);
                self.engine.active_stream.reserveMovedStreamPublication(allocator, &self.replacement.stream) catch return error.OutOfMemory;
                try prepareRetiredStreamCapacity(self.engine, allocator, &self.retired_stream, &self.removal.?.removal, retirement_scope_ids);
                const on_change_base = std.math.sub(usize, self.engine.active_stream.on_changes.items.len, self.removal.?.removal.node_indexes.on_change_indexes.items.len) catch return error.ResourceLimit;
                const mount_base = std.math.sub(usize, self.engine.active_stream.mounts.items.len, self.removal.?.removal.node_indexes.mount_indexes.items.len) catch return error.ResourceLimit;
                self.publication = structural_splice.preparePublicationDeltas(allocator, self.replacement.stream.render_nodes.items, &.{}, on_change_base, self.replacement.stream.on_changes.items.len, mount_base, self.replacement.stream.mounts.items.len) catch return error.OutOfMemory;
                errdefer if (self.publication) |*publication| publication.deinit(allocator);
                try self.prepareGraphRenderAndPublication(allocator);
            }

            fn prepareGraphRenderAndPublication(self: *@This(), allocator: std.mem.Allocator) CollectionError!void {
                if (self.engine.active_signal_graph.items.len != 0) {
                    self.sink_edits = try self.prepareSinkEdits(allocator);
                    errdefer if (self.sink_edits) |*edits| edits.deinit(allocator);
                    var retired_roots: std.ArrayListUnmanaged(*HostSignalRecord) = .empty;
                    defer retired_roots.deinit(allocator);
                    try collectRetiredGraphRootsForRemoval(self.engine, allocator, &self.removal.?.removal, &retired_roots);
                    self.graph_release = active_graph.prepareReleaseClosure(HostSignalRecord, allocator, self.engine.active_signal_graph.items, retired_roots.items) catch return error.OutOfMemory;
                    errdefer if (self.graph_release) |*release| release.deinit(allocator);
                    var replacement_roots: std.ArrayListUnmanaged(*HostSignalRecord) = .empty;
                    defer replacement_roots.deinit(allocator);
                    try collectReplacementGraphRootsForStream(allocator, &self.replacement.stream, &replacement_roots);
                    self.graph_append = active_graph.prepareGraphAppend(HostSignalRecord, allocator, self.engine.active_signal_graph.items, self.graph_release.?.final_record_ids, replacement_roots.items) catch return error.OutOfMemory;
                    errdefer if (self.graph_append) |*append| append.deinit(allocator);
                    try self.prepareGraphRoutes(allocator);
                }
                try self.prepareRender(allocator);
            }

            fn prepareRender(self: *@This(), allocator: std.mem.Allocator) CollectionError!void {
                if (!self.engine.render_cache.hasRoot()) return;
                errdefer {
                    self.deinitGraphRoutes(allocator);
                    if (self.graph_append) |*append| append.deinit(allocator);
                    self.graph_append = null;
                    if (self.graph_release) |*release| release.deinit(allocator);
                    self.graph_release = null;
                    if (self.sink_edits) |*edits| edits.deinit(allocator);
                    self.sink_edits = null;
                }
                var facade = BranchReplacementPlan{
                    .engine = self.engine,
                    .host_ctx = self.host_ctx,
                    .roc_host = self.roc_host,
                    .replacement_stream = self.replacement.stream,
                    .collection = self.replacement.collection,
                    .removal = self.removal.?.removal,
                };
                self.render_splice = try facade.prepareRenderTopology(allocator);
                errdefer if (self.render_splice) |*splice| splice.deinit();
                self.render_batch_target = if (comptime @hasDecl(Ctx, "renderCommandBatch")) Ctx.renderCommandBatch(self.host_ctx) else &self.render_batch;
                self.render_splice.?.wire.preflight(self.render_batch_target.?, allocator) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.ResourceLimit => return error.ResourceLimit,
                };
                self.render_batch_preflighted = true;
                errdefer self.render_batch_target.?.abort();
                if (comptime @hasDecl(Ctx, "prepareRenderPublication")) {
                    self.host_render_publication = Ctx.prepareRenderPublication(self.host_ctx, &self.render_splice.?) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.ResourceLimit => return error.ResourceLimit,
                    };
                }
            }

            fn commitCollection(self: *@This()) void {
                self.replacement.collection.commit();
            }

            fn commitGraphAssumeCapacity(self: *@This()) void {
                self.sink_edits.?.apply(
                    &self.engine.active_text_signal_routes,
                    &self.engine.active_bool_signal_routes,
                    &self.engine.active_change_signal_routes,
                    &self.engine.active_structural_signal_routes,
                );
                const release = &self.graph_release.?;
                const append = &self.graph_append.?;
                release.applyAdjacency(self.engine.active_signal_graph.items);
                release.applyDense(
                    &self.engine.active_signal_graph,
                    &self.engine.active_source_signal_routes,
                    &self.engine.active_text_signal_routes,
                    &self.engine.active_bool_signal_routes,
                    &self.engine.active_change_signal_routes,
                    &self.engine.active_structural_signal_routes,
                );
                append.commitNodes(&self.engine.active_signal_graph);
                append.commitParallelRoutes(
                    &self.engine.active_text_signal_routes,
                    &self.engine.active_bool_signal_routes,
                    &self.engine.active_change_signal_routes,
                    &self.engine.active_structural_signal_routes,
                );
                self.source_route_appends.?.apply(&self.engine.active_source_signal_routes, self.graph_source_route_count);
                const graph_count = append.finalGraphCount();
                self.text_route_appends.?.apply(&self.engine.active_text_signal_routes, graph_count);
                self.bool_route_appends.?.apply(&self.engine.active_bool_signal_routes, graph_count);
                self.change_route_appends.?.apply(&self.engine.active_change_signal_routes, graph_count);
                self.structural_route_appends.?.apply(&self.engine.active_structural_signal_routes, graph_count);
                var lifecycle = ActiveSignalGraphLifecycle{ .engine = self.engine, .ctx = self.host_ctx };
                release.releaseRetired(Ctx.allocator(self.host_ctx), &lifecycle);
            }

            fn commitRenderAssumeCapacity(self: *@This()) void {
                const splice = &(self.render_splice orelse return);
                splice.wire.stageAssumeCapacity(self.render_batch_target.?, Ctx.allocator(self.host_ctx)) catch @panic("prepared aggregate render batch violated preflight");
                splice.apply(&self.engine.render_cache);
                if (comptime @hasDecl(Ctx, "applyRenderPublication")) Ctx.applyRenderPublication(self.host_ctx, &self.host_render_publication.?);
            }

            fn publishRenderLast(self: *@This()) void {
                if (self.render_splice == null) return;
                self.render_batch_target.?.commit();
                self.render_batch_published = true;
                if (comptime @hasDecl(Ctx, "publishRenderPublication")) {
                    Ctx.publishRenderPublication(self.host_ctx, &self.host_render_publication.?);
                    self.host_render_published = true;
                }
            }

            fn commitAssumeCapacity(self: *@This()) void {
                self.commitRenderAssumeCapacity();
                if (self.graph_release != null) self.commitGraphAssumeCapacity();

                const removal = &self.removal.?.removal;
                const indexes = &removal.descriptor_indexes;
                self.engine.active_stream.commitStaticDescriptorReplacementAssumeCapacity(
                    &self.replacement.stream,
                    &self.retired_stream,
                    indexes.element_indexes.items,
                    indexes.text_node_indexes.items,
                    indexes.static_text_attr_indexes.items,
                    indexes.static_bool_attr_indexes.items,
                    indexes.signal_text_node_indexes.items,
                    indexes.signal_text_attr_indexes.items,
                    indexes.signal_bool_attr_indexes.items,
                    indexes.event_indexes.items,
                    removal.node_indexes.scope_site_indexes.items,
                    removal.node_indexes.state_indexes.items,
                    removal.node_indexes.when_indexes.items,
                    removal.node_indexes.each_indexes.items,
                );
                self.engine.active_stream.commitCustomDescriptorReplacementAssumeCapacity(
                    &self.replacement.stream,
                    &self.retired_stream,
                    indexes.static_custom_text_attr_indexes.items,
                    indexes.signal_custom_text_attr_indexes.items,
                    indexes.signal_optional_custom_text_attr_indexes.items,
                    indexes.static_custom_bool_attr_indexes.items,
                    indexes.signal_custom_bool_attr_indexes.items,
                );
                self.engine.active_stream.commitLifecycleReplacementAssumeCapacity(
                    &self.replacement.stream,
                    &self.retired_stream,
                    removal.node_indexes.on_change_indexes.items,
                    removal.node_indexes.mount_indexes.items,
                    removal.node_indexes.cleanup_indexes.items,
                );

                self.state_retirement.?.apply(self.engine, &self.retired_state_cells);
                self.replacement.collection.commit();
                self.identity_retirements.?.apply(self.engine);
                var row_keys = EachRowScopeKeyLookup{ .engine = self.engine };
                self.row_retirement.?.apply(&self.engine.each_row_sites, &self.engine.each_row_memberships_by_scope_id, &row_keys);
                const scope_retirement = &self.targets.?.scope_retirement.?;
                for (scope_retirement.scope_ids) |scope_id| {
                    const scope = &self.engine.scopes.items[@intCast(scope_id)];
                    self.retired_scope_steps.appendAssumeCapacity(scope.step);
                    scope.step = .root;
                }
                scope_retirement.applyMetadata(HostEachRowScopeStep, self.engine.scopes.items, self.engine.identity_reuse_barrier);
                self.engine.has_inactive_scopes = scope_retirement.scope_ids.len != 0 or self.engine.has_inactive_scopes;

                self.publishRenderLast();
                // Cancellations and cleanup publication may call the host, so they
                // deliberately run only after the engine/cache/host publication is visible.
                self.effects_retirement.?.apply(self.engine, self.host_ctx);
            }

            fn deinit(self: *@This()) void {
                const allocator = Ctx.allocator(self.host_ctx);
                if (self.render_batch_preflighted and !self.render_batch_published and self.render_batch_target != &self.render_batch) self.render_batch_target.?.abort();
                if (@hasDecl(Ctx, "RenderPublication")) if (self.host_render_publication) |*publication| publication.deinit();
                self.render_batch.deinit(allocator);
                if (self.render_splice) |*splice| splice.deinit();
                self.replacement.deinit();
                if (self.removal) |*removal| removal.deinit(allocator);
                if (self.state_retirement) |*retirement| retirement.deinit(allocator);
                for (self.retired_state_cells.items) |*state| state.cell.deinit(self.host_ctx, self.roc_host, &self.engine.pending_roc_metrics);
                self.retired_state_cells.deinit(allocator);
                if (self.row_retirement) |*retirement| retirement.deinit(allocator);
                if (self.effects_retirement) |*effects| effects.deinit(allocator, self.roc_host);
                if (self.publication) |*publication| publication.deinit(allocator);
                if (self.graph_append) |*append| append.deinit(allocator);
                if (self.graph_release) |*release| release.deinit(allocator);
                if (self.sink_edits) |*edits| edits.deinit(allocator);
                self.deinitGraphRoutes(allocator);
                self.retired_stream.deinit(allocator, self.host_ctx, self.roc_host, &self.engine.pending_roc_metrics);
                if (self.identity_retirements) |*retirements| retirements.deinit(allocator);
                if (self.targets) |*targets| targets.deinit(allocator);
                for (self.retired_scope_steps.items) |*step| deinitHostScopeStep(step, self.host_ctx, self.roc_host, &self.engine.pending_roc_metrics);
                self.retired_scope_steps.deinit(allocator);
                allocator.free(self.replacement_scope_ids);
                allocator.destroy(self);
            }

            fn prepareSinkEdits(self: *@This(), allocator: std.mem.Allocator) CollectionError!active_graph.PreparedSinkRouteEdits {
                var text: std.ArrayListUnmanaged(active_graph.TextSinkEdit) = .empty;
                defer text.deinit(allocator);
                var bools: std.ArrayListUnmanaged(active_graph.BoolSinkEdit) = .empty;
                defer bools.deinit(allocator);
                var structural: std.ArrayListUnmanaged(active_graph.StructuralSinkEdit) = .empty;
                defer structural.deinit(allocator);
                var changes: std.ArrayListUnmanaged(active_graph.ChangeSinkEdit) = .empty;
                defer changes.deinit(allocator);
                const removal = &self.removal.?.removal;
                const indexes = &removal.descriptor_indexes;
                var text_removals = std.math.add(usize, indexes.signal_text_node_indexes.items.len, indexes.signal_text_attr_indexes.items.len) catch return error.ResourceLimit;
                text_removals = std.math.add(usize, text_removals, indexes.signal_custom_text_attr_indexes.items.len) catch return error.ResourceLimit;
                text_removals = std.math.add(usize, text_removals, indexes.signal_optional_custom_text_attr_indexes.items.len) catch return error.ResourceLimit;
                const bool_removals = std.math.add(usize, indexes.signal_bool_attr_indexes.items.len, indexes.signal_custom_bool_attr_indexes.items.len) catch return error.ResourceLimit;
                const structural_removals = std.math.add(usize, removal.node_indexes.when_indexes.items.len, removal.node_indexes.each_indexes.items.len) catch return error.ResourceLimit;
                text.ensureTotalCapacity(allocator, std.math.mul(usize, 2, text_removals) catch return error.ResourceLimit) catch return error.OutOfMemory;
                bools.ensureTotalCapacity(allocator, std.math.mul(usize, 2, bool_removals) catch return error.ResourceLimit) catch return error.OutOfMemory;
                structural.ensureTotalCapacity(allocator, std.math.mul(usize, 2, structural_removals) catch return error.ResourceLimit) catch return error.OutOfMemory;
                changes.ensureTotalCapacity(allocator, std.math.mul(usize, 2, removal.node_indexes.on_change_indexes.items.len) catch return error.ResourceLimit) catch return error.OutOfMemory;
                BranchReplacementPlan.appendTextSinkEdits(self.engine, &text, self.engine.active_stream.signal_text_nodes.items, indexes.signal_text_node_indexes.items, .text_node);
                BranchReplacementPlan.appendTextSinkEdits(self.engine, &text, self.engine.active_stream.signal_text_attrs.items, indexes.signal_text_attr_indexes.items, .text_attr);
                BranchReplacementPlan.appendTextSinkEdits(self.engine, &text, self.engine.active_stream.signal_custom_text_attrs.items, indexes.signal_custom_text_attr_indexes.items, .custom_text_attr);
                BranchReplacementPlan.appendTextSinkEdits(self.engine, &text, self.engine.active_stream.signal_optional_custom_text_attrs.items, indexes.signal_optional_custom_text_attr_indexes.items, .custom_text_optional_attr);
                BranchReplacementPlan.appendBoolSinkEdits(self.engine, &bools, self.engine.active_stream.signal_bool_attrs.items, indexes.signal_bool_attr_indexes.items, .bool_attr);
                BranchReplacementPlan.appendBoolSinkEdits(self.engine, &bools, self.engine.active_stream.signal_custom_bool_attrs.items, indexes.signal_custom_bool_attr_indexes.items, .custom_bool_attr);
                BranchReplacementPlan.appendChangeSinkEdits(self.engine, &changes, self.engine.active_stream.on_changes.items, removal.node_indexes.on_change_indexes.items);
                BranchReplacementPlan.appendStructuralSinkEdits(self.engine, &structural, self.engine.active_stream.whens.items, removal.node_indexes.when_indexes.items, .when);
                BranchReplacementPlan.appendStructuralSinkEdits(self.engine, &structural, self.engine.active_stream.eaches.items, removal.node_indexes.each_indexes.items, .each);
                return active_graph.prepareSinkRouteEdits(
                    allocator,
                    &self.engine.active_text_signal_routes,
                    &self.engine.active_bool_signal_routes,
                    &self.engine.active_change_signal_routes,
                    &self.engine.active_structural_signal_routes,
                    text.items,
                    bools.items,
                    changes.items,
                    structural.items,
                ) catch return error.OutOfMemory;
            }

            fn prepareGraphRoutes(self: *@This(), allocator: std.mem.Allocator) CollectionError!void {
                errdefer self.deinitGraphRoutes(allocator);
                const graph_plan = &self.graph_append.?;
                const graph_count = graph_plan.finalGraphCount();
                var source: std.ArrayListUnmanaged(active_graph.RouteAppend(u64)) = .empty;
                defer source.deinit(allocator);
                var text: std.ArrayListUnmanaged(active_graph.RouteAppend(active_graph.TextSink)) = .empty;
                defer text.deinit(allocator);
                var bools: std.ArrayListUnmanaged(active_graph.RouteAppend(active_graph.BoolSink)) = .empty;
                defer bools.deinit(allocator);
                var changes: std.ArrayListUnmanaged(active_graph.RouteAppend(active_graph.ChangeSink)) = .empty;
                defer changes.deinit(allocator);
                var structural: std.ArrayListUnmanaged(active_graph.RouteAppend(active_graph.StructuralSink)) = .empty;
                defer structural.deinit(allocator);
                for (graph_plan.records, graph_plan.record_ids) |record, record_id| switch (record.payload) {
                    .ref => |source_node_id| source.append(allocator, .{ .route_index = source_node_id, .value = record_id }) catch return error.OutOfMemory,
                    else => {},
                };
                const removal = &self.removal.?.removal;
                const indexes = &removal.descriptor_indexes;
                const text_node_base = std.math.sub(usize, self.engine.active_stream.signal_text_nodes.items.len, indexes.signal_text_node_indexes.items.len) catch return error.ResourceLimit;
                for (self.replacement.stream.signal_text_nodes.items, 0..) |desc, offset| try self.appendTextRoute(allocator, &text, desc.signal.record, .{ .kind = .text_node, .index = text_node_base + offset });
                const text_attr_base = std.math.sub(usize, self.engine.active_stream.signal_text_attrs.items.len, indexes.signal_text_attr_indexes.items.len) catch return error.ResourceLimit;
                for (self.replacement.stream.signal_text_attrs.items, 0..) |desc, offset| try self.appendTextRoute(allocator, &text, desc.signal.record, .{ .kind = .text_attr, .index = text_attr_base + offset });
                const custom_text_base = std.math.sub(usize, self.engine.active_stream.signal_custom_text_attrs.items.len, indexes.signal_custom_text_attr_indexes.items.len) catch return error.ResourceLimit;
                for (self.replacement.stream.signal_custom_text_attrs.items, 0..) |desc, offset| try self.appendTextRoute(allocator, &text, desc.signal.record, .{ .kind = .custom_text_attr, .index = custom_text_base + offset });
                const optional_text_base = std.math.sub(usize, self.engine.active_stream.signal_optional_custom_text_attrs.items.len, indexes.signal_optional_custom_text_attr_indexes.items.len) catch return error.ResourceLimit;
                for (self.replacement.stream.signal_optional_custom_text_attrs.items, 0..) |desc, offset| try self.appendTextRoute(allocator, &text, desc.signal.record, .{ .kind = .custom_text_optional_attr, .index = optional_text_base + offset });
                const bool_attr_base = std.math.sub(usize, self.engine.active_stream.signal_bool_attrs.items.len, indexes.signal_bool_attr_indexes.items.len) catch return error.ResourceLimit;
                for (self.replacement.stream.signal_bool_attrs.items, 0..) |desc, offset| try self.appendBoolRoute(allocator, &bools, desc.signal.record, .{ .kind = .bool_attr, .index = bool_attr_base + offset });
                const custom_bool_base = std.math.sub(usize, self.engine.active_stream.signal_custom_bool_attrs.items.len, indexes.signal_custom_bool_attr_indexes.items.len) catch return error.ResourceLimit;
                for (self.replacement.stream.signal_custom_bool_attrs.items, 0..) |desc, offset| try self.appendBoolRoute(allocator, &bools, desc.signal.record, .{ .kind = .custom_bool_attr, .index = custom_bool_base + offset });
                const change_base = std.math.sub(usize, self.engine.active_stream.on_changes.items.len, removal.node_indexes.on_change_indexes.items.len) catch return error.ResourceLimit;
                for (self.replacement.stream.on_changes.items, 0..) |desc, offset| try self.appendChangeRoute(allocator, &changes, desc.signal.record, .{ .index = change_base + offset });
                const when_base = std.math.sub(usize, self.engine.active_stream.whens.items.len, removal.node_indexes.when_indexes.items.len) catch return error.ResourceLimit;
                for (self.replacement.stream.whens.items, 0..) |desc, offset| try self.appendStructuralRoute(allocator, &structural, desc.condition.record, .{ .kind = .when, .index = when_base + offset });
                const each_base = std.math.sub(usize, self.engine.active_stream.eaches.items.len, removal.node_indexes.each_indexes.items.len) catch return error.ResourceLimit;
                for (self.replacement.stream.eaches.items, 0..) |desc, offset| try self.appendStructuralRoute(allocator, &structural, desc.items.record, .{ .kind = .each, .index = each_base + offset });
                var source_count = self.engine.active_source_signal_routes.items.len;
                for (source.items) |entry| source_count = @max(source_count, std.math.add(usize, @intCast(entry.route_index), 1) catch return error.ResourceLimit);
                self.graph_source_route_count = source_count;
                self.source_route_appends = active_graph.prepareSourceRouteAppendsAfterRelease(allocator, &self.engine.active_source_signal_routes, self.graph_release.?.final_record_ids, source_count, source.items) catch return error.OutOfMemory;
                self.text_route_appends = active_graph.prepareRouteAppendsAfterRelease(active_graph.TextSink, allocator, &self.engine.active_text_signal_routes, self.graph_release.?.final_record_ids, graph_count, text.items) catch return error.OutOfMemory;
                self.bool_route_appends = active_graph.prepareRouteAppendsAfterRelease(active_graph.BoolSink, allocator, &self.engine.active_bool_signal_routes, self.graph_release.?.final_record_ids, graph_count, bools.items) catch return error.OutOfMemory;
                self.change_route_appends = active_graph.prepareRouteAppendsAfterRelease(active_graph.ChangeSink, allocator, &self.engine.active_change_signal_routes, self.graph_release.?.final_record_ids, graph_count, changes.items) catch return error.OutOfMemory;
                self.structural_route_appends = active_graph.prepareRouteAppendsAfterRelease(active_graph.StructuralSink, allocator, &self.engine.active_structural_signal_routes, self.graph_release.?.final_record_ids, graph_count, structural.items) catch return error.OutOfMemory;
                graph_plan.reservePublication(allocator, &self.engine.active_signal_graph) catch return error.OutOfMemory;
                graph_plan.reserveParallelRoutes(allocator, &self.engine.active_text_signal_routes, &self.engine.active_bool_signal_routes, &self.engine.active_change_signal_routes, &self.engine.active_structural_signal_routes) catch return error.OutOfMemory;
                try self.source_route_appends.?.reserveOuter(allocator, &self.engine.active_source_signal_routes, source_count);
            }

            fn appendTextRoute(self: *@This(), allocator: std.mem.Allocator, routes: *std.ArrayListUnmanaged(active_graph.RouteAppend(active_graph.TextSink)), record: *HostSignalRecord, sink: active_graph.TextSink) CollectionError!void {
                const id = self.graph_append.?.plannedRecordId(self.engine.active_signal_graph.items, record) orelse return error.ResourceLimit;
                routes.append(allocator, .{ .route_index = id, .value = sink }) catch return error.OutOfMemory;
            }
            fn appendBoolRoute(self: *@This(), allocator: std.mem.Allocator, routes: *std.ArrayListUnmanaged(active_graph.RouteAppend(active_graph.BoolSink)), record: *HostSignalRecord, sink: active_graph.BoolSink) CollectionError!void {
                const id = self.graph_append.?.plannedRecordId(self.engine.active_signal_graph.items, record) orelse return error.ResourceLimit;
                routes.append(allocator, .{ .route_index = id, .value = sink }) catch return error.OutOfMemory;
            }
            fn appendChangeRoute(self: *@This(), allocator: std.mem.Allocator, routes: *std.ArrayListUnmanaged(active_graph.RouteAppend(active_graph.ChangeSink)), record: *HostSignalRecord, sink: active_graph.ChangeSink) CollectionError!void {
                const id = self.graph_append.?.plannedRecordId(self.engine.active_signal_graph.items, record) orelse return error.ResourceLimit;
                routes.append(allocator, .{ .route_index = id, .value = sink }) catch return error.OutOfMemory;
            }
            fn appendStructuralRoute(self: *@This(), allocator: std.mem.Allocator, routes: *std.ArrayListUnmanaged(active_graph.RouteAppend(active_graph.StructuralSink)), record: *HostSignalRecord, sink: active_graph.StructuralSink) CollectionError!void {
                const id = self.graph_append.?.plannedRecordId(self.engine.active_signal_graph.items, record) orelse return error.ResourceLimit;
                routes.append(allocator, .{ .route_index = id, .value = sink }) catch return error.OutOfMemory;
            }
            fn deinitGraphRoutes(self: *@This(), allocator: std.mem.Allocator) void {
                if (self.source_route_appends) |*routes| routes.deinit(allocator);
                if (self.text_route_appends) |*routes| routes.deinit(allocator);
                if (self.bool_route_appends) |*routes| routes.deinit(allocator);
                if (self.change_route_appends) |*routes| routes.deinit(allocator);
                if (self.structural_route_appends) |*routes| routes.deinit(allocator);
                self.source_route_appends = null;
                self.text_route_appends = null;
                self.bool_route_appends = null;
                self.change_route_appends = null;
                self.structural_route_appends = null;
            }
        };

        const AggregateBranchCollection = PreparedStructuralDownstream;

        const BranchReplacementPlan = struct {
            const HostRenderPublication = if (@hasDecl(Ctx, "RenderPublication")) Ctx.RenderPublication else void;
            engine: *Self,
            host_ctx: Ctx.Handle,
            roc_host: *abi.RocHost,
            replacement_stream: HostNodeDescriptorStream = .{},
            retired_stream: HostNodeDescriptorStream = .{},
            collection: StagedCollectionCtx = undefined,
            replacement_scope_id: u64 = 0,
            retired_scope_id: u64 = 0,
            target_scopes: []bool = &.{},
            removal: ?structural_splice.PreparedRemoval = null,
            publication: ?structural_splice.PreparedPublicationDeltas = null,
            scope_retirement: ?scope_runtime.PreparedSubtreeRetirement = null,
            retired_state_cells: std.ArrayListUnmanaged(HostState) = .empty,
            state_cell_indexes: []usize = &.{},
            retired_node_identity_ids: []u64 = &.{},
            retired_dom_identity_ids: []u64 = &.{},
            row_retirement: ?each_runtime.PreparedRowRemovals = null,
            effects_retirement: ?PreparedEffectRetirements = null,
            retired_scope_steps: std.ArrayListUnmanaged(HostScopeStep) = .empty,
            sink_edits: ?active_graph.PreparedSinkRouteEdits = null,
            graph_release: ?active_graph.PreparedReleaseClosure(HostSignalRecord) = null,
            graph_append: ?active_graph.PreparedGraphAppend(HostSignalRecord) = null,
            source_route_appends: ?active_graph.PreparedRouteAppends(u64) = null,
            text_route_appends: ?active_graph.PreparedRouteAppends(active_graph.TextSink) = null,
            bool_route_appends: ?active_graph.PreparedRouteAppends(active_graph.BoolSink) = null,
            change_route_appends: ?active_graph.PreparedRouteAppends(active_graph.ChangeSink) = null,
            structural_route_appends: ?active_graph.PreparedRouteAppends(active_graph.StructuralSink) = null,
            graph_source_route_count: usize = 0,
            render_splice: ?render_cache_mod.PreparedRenderSplice(Ctx) = null,
            render_batch: render.TransactionalBatch = .{},
            render_batch_target: ?*render.TransactionalBatch = null,
            render_batch_preflighted: bool = false,
            render_batch_published: bool = false,
            host_render_publication: ?HostRenderPublication = null,
            host_render_published: bool = false,

            fn stateIndexDescending(_: void, left: usize, right: usize) bool {
                return left > right;
            }

            fn prepare(engine_ptr: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, site: HostNodeScopeSiteDesc, when: HostNodeWhenDesc, selected_branch: HostScopeBranch, limits: collection_budget.Limits, dirty_source_node_ids: []const u64) CollectionError!*@This() {
                if (site.kind != .when or site.node_id != when.node_id) return error.ResourceLimit;
                const retired_scope_id = (engine_ptr.activeWhenBranchScopeId(site.scope_id, site.ordinal, selected_branch.opposite()) catch return error.ResourceLimit) orelse return error.ResourceLimit;
                if ((engine_ptr.activeWhenBranchScopeId(site.scope_id, site.ordinal, selected_branch) catch return error.ResourceLimit) != null) return error.ResourceLimit;

                const selected_elem = switch (selected_branch) {
                    .true_branch => when.when_true,
                    .false_branch => when.when_false,
                };
                const expected = try countStaticRootNodes(selected_elem);
                const allocator = Ctx.allocator(ctx);
                const plan = allocator.create(@This()) catch return error.OutOfMemory;
                errdefer allocator.destroy(plan);
                plan.* = .{ .engine = engine_ptr, .host_ctx = ctx, .roc_host = roc_host, .retired_scope_id = retired_scope_id };
                errdefer plan.replacement_stream.deinit(allocator, ctx, roc_host, &engine_ptr.pending_roc_metrics);
                errdefer plan.retired_stream.deinit(allocator, ctx, roc_host, &engine_ptr.pending_roc_metrics);
                plan.collection = try StagedCollectionCtx.init(engine_ptr, ctx, &plan.replacement_stream, limits, expected.nodes, expected.attrs, expected.lifecycle, expected.signal_records, expected.state_sites, expected.component_sites, expected.when_sites, 1);
                errdefer plan.collection.deinit();

                const branch_scope = try plan.collection.reserveWhenBranchScope(site.scope_id, site.ordinal, selected_branch);
                if (!branch_scope.created) return error.ResourceLimit;
                plan.replacement_scope_id = branch_scope.scope_id;
                var binder_stack: std.ArrayListUnmanaged(HostBinderBinding) = .empty;
                defer binder_stack.deinit(allocator);
                const binder_capacity = std.math.add(usize, site.binder_bindings.len, expected.state_sites) catch return error.ResourceLimit;
                binder_stack.ensureTotalCapacity(allocator, binder_capacity) catch return error.OutOfMemory;
                binder_stack.appendSliceAssumeCapacity(site.binder_bindings);
                var ordinal: u64 = 0;
                var dom_ordinal: u64 = 0;
                try engine_ptr.collectActiveElemDescriptorsWith(*StagedCollectionCtx, &plan.collection, ctx, roc_host, &plan.replacement_stream, selected_elem, branch_scope.scope_id, site.parent_elem_id, &ordinal, &dom_ordinal, &binder_stack, true, dirty_source_node_ids);
                plan.collection.materializeStream();
                engine_ptr.active_stream.reserveMovedStreamPublication(allocator, &plan.replacement_stream) catch return error.OutOfMemory;

                plan.target_scopes = allocator.alloc(bool, engine_ptr.scopes.items.len) catch return error.OutOfMemory;
                errdefer allocator.free(plan.target_scopes);
                for (engine_ptr.scopes.items, 0..) |scope, index| {
                    plan.target_scopes[index] = engine_ptr.scopeIsInReplacementTarget(scope.scope_id, .{ .scope = retired_scope_id });
                }
                plan.scope_retirement = scope_runtime.prepareSubtreeRetirement(HostEachRowScopeStep, allocator, engine_ptr.scopes.items, retired_scope_id) catch return error.OutOfMemory;
                errdefer if (plan.scope_retirement) |*retirement| retirement.deinit(allocator);
                const identity_retirements = try PreparedIdentityRetirements.prepare(engine_ptr, allocator, plan.target_scopes);
                plan.retired_node_identity_ids = identity_retirements.node_ids;
                errdefer allocator.free(plan.retired_node_identity_ids);
                plan.retired_dom_identity_ids = identity_retirements.dom_ids;
                errdefer allocator.free(plan.retired_dom_identity_ids);
                plan.row_retirement = try prepareRowRetirementForScopes(engine_ptr, allocator, plan.scope_retirement.?.scope_ids);
                errdefer if (plan.row_retirement) |*retirement| retirement.deinit(allocator);
                plan.retired_scope_steps.ensureUnusedCapacity(allocator, plan.scope_retirement.?.scope_ids.len) catch return error.OutOfMemory;
                errdefer plan.retired_scope_steps.deinit(allocator);
                const render_start = engine_ptr.renderStartForReplacementTargetSet(site.render_insert_index, plan.target_scopes);
                plan.removal = structural_splice.prepareRemoval(HostNodeDescriptorStream, allocator, &engine_ptr.active_stream, render_start, plan.target_scopes) catch return error.OutOfMemory;
                errdefer if (plan.removal) |*removal| removal.deinit(allocator);
                plan.effects_retirement = try PreparedEffectRetirements.prepare(engine_ptr, allocator, plan.target_scopes, plan.removal.?.node_indexes.cleanup_indexes.items);
                errdefer if (plan.effects_retirement) |*effects| effects.deinit(allocator, null);
                const state_retirement = try PreparedStateRetirementIndexes.prepare(engine_ptr, allocator, plan.removal.?.node_indexes.state_indexes.items);
                plan.state_cell_indexes = state_retirement.indexes_descending;
                errdefer allocator.free(plan.state_cell_indexes);
                try state_retirement.reserveRetired(allocator, &plan.retired_state_cells);
                errdefer plan.retired_state_cells.deinit(allocator);
                try prepareRetiredStreamCapacity(engine_ptr, allocator, &plan.retired_stream, &plan.removal.?, plan.scope_retirement.?.scope_ids);
                const on_change_base = std.math.sub(usize, engine_ptr.active_stream.on_changes.items.len, plan.removal.?.node_indexes.on_change_indexes.items.len) catch return error.ResourceLimit;
                const mount_base = std.math.sub(usize, engine_ptr.active_stream.mounts.items.len, plan.removal.?.node_indexes.mount_indexes.items.len) catch return error.ResourceLimit;
                plan.publication = structural_splice.preparePublicationDeltas(
                    allocator,
                    plan.replacement_stream.render_nodes.items,
                    &.{},
                    on_change_base,
                    plan.replacement_stream.on_changes.items.len,
                    mount_base,
                    plan.replacement_stream.mounts.items.len,
                ) catch return error.OutOfMemory;
                errdefer if (plan.publication) |*publication| publication.deinit(allocator);
                try plan.prepareGraphAndRender(allocator);
                return plan;
            }

            fn prepareGraphAndRender(self: *@This(), allocator: std.mem.Allocator) CollectionError!void {
                errdefer {
                    if (self.render_batch_preflighted) self.render_batch_target.?.abort();
                    if (@hasDecl(Ctx, "RenderPublication")) if (self.host_render_publication) |*publication| publication.deinit();
                    self.render_batch.deinit(allocator);
                    if (self.render_splice) |*splice| splice.deinit();
                    self.deinitGraphRoutes(allocator);
                    if (self.graph_append) |*append| append.deinit(allocator);
                    if (self.graph_release) |*release| release.deinit(allocator);
                    if (self.sink_edits) |*edits| edits.deinit(allocator);
                }
                if (self.engine.active_signal_graph.items.len != 0) {
                    self.sink_edits = try self.prepareSinkEdits(allocator);
                    var retired_roots: std.ArrayListUnmanaged(*HostSignalRecord) = .empty;
                    defer retired_roots.deinit(allocator);
                    try self.collectRetiredGraphRoots(allocator, &retired_roots);
                    self.graph_release = active_graph.prepareReleaseClosure(HostSignalRecord, allocator, self.engine.active_signal_graph.items, retired_roots.items) catch return error.OutOfMemory;
                    var replacement_roots: std.ArrayListUnmanaged(*HostSignalRecord) = .empty;
                    defer replacement_roots.deinit(allocator);
                    try self.collectReplacementGraphRoots(allocator, &replacement_roots);
                    self.graph_append = active_graph.prepareGraphAppend(HostSignalRecord, allocator, self.engine.active_signal_graph.items, self.graph_release.?.final_record_ids, replacement_roots.items) catch return error.OutOfMemory;
                    try self.prepareGraphRoutes(allocator);
                }
                if (self.engine.render_cache.hasRoot()) {
                    self.render_splice = try self.prepareRenderTopology(allocator);
                    self.render_batch_target = if (comptime @hasDecl(Ctx, "renderCommandBatch")) Ctx.renderCommandBatch(self.host_ctx) else &self.render_batch;
                    self.render_splice.?.wire.preflight(self.render_batch_target.?, allocator) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.ResourceLimit => return error.ResourceLimit,
                    };
                    self.render_batch_preflighted = true;
                    if (comptime @hasDecl(Ctx, "prepareRenderPublication")) {
                        self.host_render_publication = Ctx.prepareRenderPublication(self.host_ctx, &self.render_splice.?) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.ResourceLimit => return error.ResourceLimit,
                        };
                    }
                }
            }

            fn prepareRenderTopology(self: *@This(), allocator: std.mem.Allocator) CollectionError!render_cache_mod.PreparedRenderSplice(Ctx) {
                var retired: std.AutoHashMapUnmanaged(u64, void) = .empty;
                defer retired.deinit(allocator);
                const retired_count = std.math.cast(u32, self.removal.?.scan.removed_elem_ids.len) orelse return error.ResourceLimit;
                retired.ensureUnusedCapacity(allocator, retired_count) catch return error.OutOfMemory;
                for (self.removal.?.scan.removed_elem_ids) |elem_id| retired.putAssumeCapacity(elem_id, {});
                var replacements: std.AutoHashMapUnmanaged(u64, void) = .empty;
                defer replacements.deinit(allocator);
                replacements.ensureUnusedCapacity(allocator, std.math.cast(u32, self.replacement_stream.render_nodes.items.len) orelse return error.ResourceLimit) catch return error.OutOfMemory;
                for (self.replacement_stream.render_nodes.items) |node| {
                    const result = replacements.getOrPutAssumeCapacity(node.elem_id);
                    if (result.found_existing) return error.ResourceLimit;
                    result.value_ptr.* = {};
                }

                var touched: std.AutoHashMapUnmanaged(u64, void) = .empty;
                defer touched.deinit(allocator);
                const touched_bound = std.math.add(usize, self.removal.?.scan.touched_parent_ids.len, self.replacement_stream.render_nodes.items.len) catch return error.ResourceLimit;
                touched.ensureUnusedCapacity(allocator, std.math.cast(u32, touched_bound) orelse return error.ResourceLimit) catch return error.OutOfMemory;
                for (self.removal.?.scan.touched_parent_ids) |parent_id| {
                    if (!retired.contains(parent_id) or replacements.contains(parent_id)) touched.putAssumeCapacity(parent_id, {});
                }
                var max_elem_id: u64 = 0;
                for (self.replacement_stream.render_nodes.items) |node| {
                    max_elem_id = @max(max_elem_id, node.elem_id);
                    touched.putAssumeCapacity(descriptor_stream.renderNodeParentElemId(HostNodeDescriptorStream, &self.replacement_stream, node), {});
                }

                var final_child_count: usize = 0;
                var old_child_count: usize = 0;
                var iterator = touched.keyIterator();
                while (iterator.next()) |parent_id| {
                    const parent_index = std.math.cast(usize, parent_id.*) orelse return error.ResourceLimit;
                    if (parent_index < self.engine.render_cache.nodes.items.len and self.engine.render_cache.nodes.items[parent_index].active) {
                        old_child_count = std.math.add(usize, old_child_count, self.engine.render_cache.nodes.items[parent_index].children.items.len) catch return error.ResourceLimit;
                        for (self.engine.render_cache.nodes.items[parent_index].children.items) |child_id| if (!retired.contains(child_id)) {
                            final_child_count = std.math.add(usize, final_child_count, 1) catch return error.ResourceLimit;
                        };
                    }
                    for (self.replacement_stream.render_nodes.items) |node| {
                        if (descriptor_stream.renderNodeParentElemId(HostNodeDescriptorStream, &self.replacement_stream, node) == parent_id.*) {
                            final_child_count = std.math.add(usize, final_child_count, 1) catch return error.ResourceLimit;
                        }
                    }
                }
                var wire_commands = std.math.add(usize, self.removal.?.scan.removed_elem_ids.len, self.replacement_stream.render_nodes.items.len) catch return error.ResourceLimit;
                wire_commands = std.math.add(usize, wire_commands, final_child_count) catch return error.ResourceLimit;
                wire_commands = std.math.add(usize, wire_commands, self.replacement_stream.text_nodes.items.len) catch return error.ResourceLimit;
                wire_commands = std.math.add(usize, wire_commands, self.replacement_stream.static_text_attrs.items.len) catch return error.ResourceLimit;
                wire_commands = std.math.add(usize, wire_commands, self.replacement_stream.static_bool_attrs.items.len) catch return error.ResourceLimit;
                wire_commands = std.math.add(usize, wire_commands, self.replacement_stream.signal_text_nodes.items.len) catch return error.ResourceLimit;
                wire_commands = std.math.add(usize, wire_commands, self.replacement_stream.signal_text_attrs.items.len) catch return error.ResourceLimit;
                wire_commands = std.math.add(usize, wire_commands, self.replacement_stream.signal_bool_attrs.items.len) catch return error.ResourceLimit;
                var element_count: usize = 0;
                var old_custom_count: usize = 0;
                var old_named_event_count: usize = 0;
                for (self.replacement_stream.render_nodes.items) |node| if (node.kind == .element) {
                    element_count = std.math.add(usize, element_count, 1) catch return error.ResourceLimit;
                    const index = std.math.cast(usize, node.elem_id) orelse return error.ResourceLimit;
                    if (index < self.engine.render_cache.nodes.items.len and self.engine.render_cache.nodes.items[index].active) {
                        old_custom_count = std.math.add(usize, old_custom_count, self.engine.render_cache.nodes.items[index].custom_text_attrs.items.len) catch return error.ResourceLimit;
                        old_named_event_count = std.math.add(usize, old_named_event_count, self.engine.render_cache.nodes.items[index].named_events.items.len) catch return error.ResourceLimit;
                    }
                };
                wire_commands = std.math.add(usize, wire_commands, old_custom_count) catch return error.ResourceLimit;
                wire_commands = std.math.add(usize, wire_commands, self.replacement_stream.static_custom_text_attrs.items.len) catch return error.ResourceLimit;
                wire_commands = std.math.add(usize, wire_commands, self.replacement_stream.static_custom_bool_attrs.items.len) catch return error.ResourceLimit;
                wire_commands = std.math.add(usize, wire_commands, self.replacement_stream.signal_custom_text_attrs.items.len) catch return error.ResourceLimit;
                wire_commands = std.math.add(usize, wire_commands, self.replacement_stream.signal_optional_custom_text_attrs.items.len) catch return error.ResourceLimit;
                wire_commands = std.math.add(usize, wire_commands, self.replacement_stream.signal_custom_bool_attrs.items.len) catch return error.ResourceLimit;
                wire_commands = std.math.add(usize, wire_commands, self.replacement_stream.events.items.len) catch return error.ResourceLimit;
                wire_commands = std.math.add(usize, wire_commands, old_named_event_count) catch return error.ResourceLimit;
                var fixed_event_count: usize = 0;
                for (self.replacement_stream.events.items) |event| fixed_event_count = std.math.add(usize, fixed_event_count, @intFromBool(event.fixedKind() != null)) catch return error.ResourceLimit;
                const event_base = std.math.sub(usize, self.engine.active_stream.events.items.len, self.removal.?.descriptor_indexes.event_indexes.items.len) catch return error.ResourceLimit;
                var child_links = std.math.add(usize, old_child_count, final_child_count) catch return error.ResourceLimit;
                child_links = std.math.add(usize, child_links, self.removal.?.scan.removed_elem_ids.len) catch return error.ResourceLimit;
                var splice = render_cache_mod.PreparedRenderSplice(Ctx).init(allocator, &self.engine.render_cache, .{
                    .node_capacity = std.math.add(usize, std.math.cast(usize, max_elem_id) orelse return error.ResourceLimit, 1) catch return error.ResourceLimit,
                    .new_tags = self.replacement_stream.render_nodes.items.len,
                    .removals = self.removal.?.scan.removed_elem_ids.len,
                    .creations = self.replacement_stream.render_nodes.items.len,
                    .children = touched.count(),
                    .child_links = child_links,
                    .text_fields = std.math.add(usize, std.math.add(usize, self.replacement_stream.text_nodes.items.len, self.replacement_stream.static_text_attrs.items.len) catch return error.ResourceLimit, std.math.add(usize, self.replacement_stream.signal_text_nodes.items.len, self.replacement_stream.signal_text_attrs.items.len) catch return error.ResourceLimit) catch return error.ResourceLimit,
                    .bool_fields = std.math.add(usize, self.replacement_stream.static_bool_attrs.items.len, self.replacement_stream.signal_bool_attrs.items.len) catch return error.ResourceLimit,
                    .custom_attrs = element_count,
                    .fixed_events = fixed_event_count,
                    .named_events = element_count,
                    .wire_commands = wire_commands,
                }) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.ResourceLimit => return error.ResourceLimit,
                };
                errdefer splice.deinit();
                for (self.removal.?.scan.removed_elem_ids) |elem_id| if (!replacements.contains(elem_id)) splice.addRemoval(&self.engine.render_cache, elem_id) catch return error.ResourceLimit;
                for (self.replacement_stream.render_nodes.items) |node| {
                    const tag = descriptor_stream.renderNodeTag(HostNodeDescriptorStream, &self.replacement_stream, node);
                    const index = std.math.cast(usize, node.elem_id) orelse return error.ResourceLimit;
                    if (index < self.engine.render_cache.nodes.items.len and self.engine.render_cache.nodes.items[index].active) {
                        if (!retired.contains(node.elem_id)) return error.ResourceLimit;
                        splice.addNodeReplacement(&self.engine.render_cache, node.elem_id, tag) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            else => return error.ResourceLimit,
                        };
                    } else splice.addCreation(&self.engine.render_cache, node.elem_id, tag) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return error.ResourceLimit,
                    };
                }
                iterator = touched.keyIterator();
                while (iterator.next()) |parent_id| {
                    var children: std.ArrayListUnmanaged(u64) = .empty;
                    defer children.deinit(allocator);
                    const parent_index = std.math.cast(usize, parent_id.*) orelse return error.ResourceLimit;
                    var inserted = false;
                    if (parent_index < self.engine.render_cache.nodes.items.len and self.engine.render_cache.nodes.items[parent_index].active) {
                        for (self.engine.render_cache.nodes.items[parent_index].children.items) |child_id| {
                            if (retired.contains(child_id)) {
                                if (!inserted) {
                                    try self.appendReplacementChildren(allocator, &children, parent_id.*);
                                    inserted = true;
                                }
                            } else children.append(allocator, child_id) catch return error.OutOfMemory;
                        }
                    }
                    if (!inserted) try self.appendReplacementChildren(allocator, &children, parent_id.*);
                    splice.addChildren(&self.engine.render_cache, parent_id.*, children.items) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return error.ResourceLimit,
                    };
                }
                for (self.replacement_stream.text_nodes.items) |desc| splice.addTextField(&self.engine.render_cache, desc.elem_id, .text, desc.value) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.ResourceLimit,
                };
                for (self.replacement_stream.static_text_attrs.items) |desc| splice.addTextField(&self.engine.render_cache, desc.elem_id, desc.field, desc.value) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.ResourceLimit,
                };
                for (self.replacement_stream.static_bool_attrs.items) |desc| splice.addBoolField(&self.engine.render_cache, desc.elem_id, desc.field, desc.value) catch return error.ResourceLimit;
                for (self.replacement_stream.signal_text_nodes.items) |*desc| {
                    const text = self.evalPreparedSignalText(&desc.signal, desc.read, &desc.cached_value);
                    defer text.decref(self.roc_host);
                    splice.addTextField(&self.engine.render_cache, desc.elem_id, .text, text.asSlice()) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return error.ResourceLimit,
                    };
                }
                for (self.replacement_stream.signal_text_attrs.items) |*desc| {
                    const text = self.evalPreparedSignalText(&desc.signal, desc.read, &desc.cached_value);
                    defer text.decref(self.roc_host);
                    splice.addTextField(&self.engine.render_cache, desc.elem_id, desc.field, text.asSlice()) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return error.ResourceLimit,
                    };
                }
                for (self.replacement_stream.signal_bool_attrs.items) |*desc| splice.addBoolField(&self.engine.render_cache, desc.elem_id, desc.field, self.evalPreparedSignalBool(&desc.signal, desc.read, &desc.cached_value)) catch return error.ResourceLimit;
                for (self.replacement_stream.render_nodes.items) |node| {
                    if (node.kind != .element) continue;
                    var attrs: std.ArrayListUnmanaged(render_cache_mod.CustomTextAttr) = .empty;
                    defer attrs.deinit(allocator);
                    attrs.ensureTotalCapacity(allocator, self.replacement_stream.customAttrIndices(node.elem_id).len) catch return error.OutOfMemory;
                    for (self.replacement_stream.customAttrIndices(node.elem_id)) |custom| switch (custom.kind) {
                        .static_text => {
                            const desc = self.replacement_stream.static_custom_text_attrs.items[custom.index];
                            attrs.appendAssumeCapacity(.{ .name = desc.name, .value = desc.value });
                        },
                        .static_bool => {
                            const desc = self.replacement_stream.static_custom_bool_attrs.items[custom.index];
                            if (desc.value) attrs.appendAssumeCapacity(.{ .name = desc.name, .value = "" });
                        },
                        .signal_text => {
                            const desc = &self.replacement_stream.signal_custom_text_attrs.items[custom.index];
                            const text = self.evalPreparedSignalText(&desc.signal, desc.read, &desc.cached_value);
                            defer text.decref(self.roc_host);
                            attrs.appendAssumeCapacity(.{ .name = desc.name, .value = text.asSlice() });
                        },
                        .signal_text_optional => {
                            const desc = &self.replacement_stream.signal_optional_custom_text_attrs.items[custom.index];
                            const evaluated = self.evalPreparedSignalBinding(&desc.signal);
                            const value = evaluated.value;
                            const cap = evaluated.cap;
                            assertHostValueCapabilitiesMatch(desc.present.capability, cap, "prepared optional text presence capability did not match its signal value");
                            assertHostValueCapabilitiesMatch(desc.read.capability, cap, "prepared optional text read capability did not match its signal value");
                            if (callHostValueToBoolWithCapability(self.host_ctx, self.roc_host, desc.present.capability, desc.present.read, value)) {
                                const text = callHostValueToStrWithCapability(self.host_ctx, self.roc_host, desc.read.capability, desc.read.read, value);
                                defer text.decref(self.roc_host);
                                attrs.appendAssumeCapacity(.{ .name = desc.name, .value = text.asSlice() });
                            }
                            desc.cached_value.replace(self.host_ctx, self.roc_host, &self.engine.pending_roc_metrics, value, cap);
                        },
                        .signal_bool => {
                            const desc = &self.replacement_stream.signal_custom_bool_attrs.items[custom.index];
                            if (self.evalPreparedSignalBool(&desc.signal, desc.read, &desc.cached_value)) attrs.appendAssumeCapacity(.{ .name = desc.name, .value = "" });
                        },
                    };
                    splice.addCustomAttrs(&self.engine.render_cache, node.elem_id, attrs.items) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return error.ResourceLimit,
                    };
                    var named: std.ArrayListUnmanaged(render_cache_mod.NamedEvent) = .empty;
                    defer named.deinit(allocator);
                    named.ensureTotalCapacity(allocator, self.replacement_stream.namedEventIndices(node.elem_id).len) catch return error.OutOfMemory;
                    for (self.replacement_stream.namedEventIndices(node.elem_id)) |event_index| {
                        const desc = self.replacement_stream.events.items[event_index];
                        const binding = desc.named() orelse return error.ResourceLimit;
                        const final_index = std.math.add(usize, event_base, event_index) catch return error.ResourceLimit;
                        named.appendAssumeCapacity(.{ .name = binding.name, .binding = .{
                            .event_id = std.math.add(u64, std.math.cast(u64, final_index) orelse return error.ResourceLimit, 1) catch return error.ResourceLimit,
                            .policy = binding.policy,
                            .delivery = .{ .requested = binding.delivery_request },
                            .payload_descriptor = desc.payload_descriptor,
                        } });
                    }
                    splice.addNamedEvents(&self.engine.render_cache, node.elem_id, named.items) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return error.ResourceLimit,
                    };
                }
                for (self.replacement_stream.events.items, 0..) |desc, event_index| if (desc.fixedKind()) |kind| {
                    const final_index = std.math.add(usize, event_base, event_index) catch return error.ResourceLimit;
                    splice.addFixedEvent(&self.engine.render_cache, desc.elem_id, kind, .{
                        .event_id = std.math.add(u64, std.math.cast(u64, final_index) orelse return error.ResourceLimit, 1) catch return error.ResourceLimit,
                        .delivery = .{ .requested = desc.delivery_request },
                        .payload_descriptor = desc.payload_descriptor,
                    }) catch return error.ResourceLimit;
                };
                return splice;
            }

            fn evalPreparedSignalText(self: *@This(), signal: *HostSignalBinding, read: HostTextRead, cache_slot: *HostSignalCacheSlot) abi.RocStr {
                const evaluated = self.evalPreparedSignalBinding(signal);
                const value = evaluated.value;
                const cap = evaluated.cap;
                assertHostValueCapabilitiesMatch(read.capability, cap, "prepared text read capability did not match its signal value");
                const text = callHostValueToStrWithCapability(self.host_ctx, self.roc_host, read.capability, read.read, value);
                cache_slot.replace(self.host_ctx, self.roc_host, &self.engine.pending_roc_metrics, value, cap);
                return text;
            }

            fn evalPreparedSignalBool(self: *@This(), signal: *HostSignalBinding, read: HostBoolRead, cache_slot: *HostSignalCacheSlot) bool {
                const evaluated = self.evalPreparedSignalBinding(signal);
                const value = evaluated.value;
                const cap = evaluated.cap;
                assertHostValueCapabilitiesMatch(read.capability, cap, "prepared bool read capability did not match its signal value");
                const result = callHostValueToBoolWithCapability(self.host_ctx, self.roc_host, read.capability, read.read, value);
                cache_slot.replace(self.host_ctx, self.roc_host, &self.engine.pending_roc_metrics, value, cap);
                return result;
            }

            fn evalPreparedSignalBinding(self: *@This(), signal: *HostSignalBinding) struct { value: HostValue, cap: HostValueCapability } {
                switch (signal.record.payload) {
                    .ref => |node_id| for (self.collection.prepared_state_cells.items) |state| {
                        if (state.state_id == node_id) return .{ .value = Ctx.cloneHostValue(self.host_ctx, state.cell.value), .cap = state.cell.cap };
                    },
                    else => {},
                }
                return .{
                    .value = self.engine.evalHostSignalBinding(self.host_ctx, self.roc_host, signal),
                    .cap = self.engine.hostSignalBindingCapability(self.host_ctx, signal),
                };
            }

            fn appendReplacementChildren(self: *@This(), allocator: std.mem.Allocator, children: *std.ArrayListUnmanaged(u64), parent_id: u64) CollectionError!void {
                for (self.replacement_stream.render_nodes.items) |node| {
                    if (descriptor_stream.renderNodeParentElemId(HostNodeDescriptorStream, &self.replacement_stream, node) == parent_id) children.append(allocator, node.elem_id) catch return error.OutOfMemory;
                }
            }

            fn prepareGraphRoutes(self: *@This(), allocator: std.mem.Allocator) CollectionError!void {
                const graph_plan = &self.graph_append.?;
                const graph_count = graph_plan.finalGraphCount();
                var source: std.ArrayListUnmanaged(active_graph.RouteAppend(u64)) = .empty;
                defer source.deinit(allocator);
                var text: std.ArrayListUnmanaged(active_graph.RouteAppend(active_graph.TextSink)) = .empty;
                defer text.deinit(allocator);
                var bools: std.ArrayListUnmanaged(active_graph.RouteAppend(active_graph.BoolSink)) = .empty;
                defer bools.deinit(allocator);
                var changes: std.ArrayListUnmanaged(active_graph.RouteAppend(active_graph.ChangeSink)) = .empty;
                defer changes.deinit(allocator);
                var structural: std.ArrayListUnmanaged(active_graph.RouteAppend(active_graph.StructuralSink)) = .empty;
                defer structural.deinit(allocator);
                for (graph_plan.records, graph_plan.record_ids) |record, record_id| switch (record.payload) {
                    .ref => |source_node_id| source.append(allocator, .{ .route_index = source_node_id, .value = record_id }) catch return error.OutOfMemory,
                    else => {},
                };
                const text_node_base = self.engine.active_stream.signal_text_nodes.items.len - self.removal.?.descriptor_indexes.signal_text_node_indexes.items.len;
                for (self.replacement_stream.signal_text_nodes.items, 0..) |desc, offset| try self.appendTextRoute(allocator, &text, graph_plan, desc.signal.record, .{ .kind = .text_node, .index = text_node_base + offset });
                const text_attr_base = self.engine.active_stream.signal_text_attrs.items.len - self.removal.?.descriptor_indexes.signal_text_attr_indexes.items.len;
                for (self.replacement_stream.signal_text_attrs.items, 0..) |desc, offset| try self.appendTextRoute(allocator, &text, graph_plan, desc.signal.record, .{ .kind = .text_attr, .index = text_attr_base + offset });
                const custom_text_base = self.engine.active_stream.signal_custom_text_attrs.items.len - self.removal.?.descriptor_indexes.signal_custom_text_attr_indexes.items.len;
                for (self.replacement_stream.signal_custom_text_attrs.items, 0..) |desc, offset| try self.appendTextRoute(allocator, &text, graph_plan, desc.signal.record, .{ .kind = .custom_text_attr, .index = custom_text_base + offset });
                const optional_custom_text_base = self.engine.active_stream.signal_optional_custom_text_attrs.items.len - self.removal.?.descriptor_indexes.signal_optional_custom_text_attr_indexes.items.len;
                for (self.replacement_stream.signal_optional_custom_text_attrs.items, 0..) |desc, offset| try self.appendTextRoute(allocator, &text, graph_plan, desc.signal.record, .{ .kind = .custom_text_optional_attr, .index = optional_custom_text_base + offset });
                const bool_attr_base = self.engine.active_stream.signal_bool_attrs.items.len - self.removal.?.descriptor_indexes.signal_bool_attr_indexes.items.len;
                for (self.replacement_stream.signal_bool_attrs.items, 0..) |desc, offset| try self.appendBoolRoute(allocator, &bools, graph_plan, desc.signal.record, .{ .kind = .bool_attr, .index = bool_attr_base + offset });
                const custom_bool_base = self.engine.active_stream.signal_custom_bool_attrs.items.len - self.removal.?.descriptor_indexes.signal_custom_bool_attr_indexes.items.len;
                for (self.replacement_stream.signal_custom_bool_attrs.items, 0..) |desc, offset| try self.appendBoolRoute(allocator, &bools, graph_plan, desc.signal.record, .{ .kind = .custom_bool_attr, .index = custom_bool_base + offset });
                const change_base = self.engine.active_stream.on_changes.items.len - self.removal.?.node_indexes.on_change_indexes.items.len;
                for (self.replacement_stream.on_changes.items, 0..) |desc, offset| try self.appendChangeRoute(allocator, &changes, graph_plan, desc.signal.record, .{ .index = change_base + offset });
                const when_base = self.engine.active_stream.whens.items.len - self.removal.?.node_indexes.when_indexes.items.len;
                for (self.replacement_stream.whens.items, 0..) |desc, offset| try self.appendStructuralRoute(allocator, &structural, graph_plan, desc.condition.record, .{ .kind = .when, .index = when_base + offset });
                const each_base = self.engine.active_stream.eaches.items.len - self.removal.?.node_indexes.each_indexes.items.len;
                for (self.replacement_stream.eaches.items, 0..) |desc, offset| try self.appendStructuralRoute(allocator, &structural, graph_plan, desc.items.record, .{ .kind = .each, .index = each_base + offset });
                var source_count = self.engine.active_source_signal_routes.items.len;
                for (source.items) |entry| source_count = @max(source_count, std.math.add(usize, @intCast(entry.route_index), 1) catch return error.ResourceLimit);
                self.graph_source_route_count = source_count;
                self.source_route_appends = active_graph.prepareSourceRouteAppendsAfterRelease(allocator, &self.engine.active_source_signal_routes, self.graph_release.?.final_record_ids, source_count, source.items) catch return error.OutOfMemory;
                self.text_route_appends = active_graph.prepareRouteAppends(active_graph.TextSink, allocator, &self.engine.active_text_signal_routes, graph_count, text.items) catch return error.OutOfMemory;
                self.bool_route_appends = active_graph.prepareRouteAppends(active_graph.BoolSink, allocator, &self.engine.active_bool_signal_routes, graph_count, bools.items) catch return error.OutOfMemory;
                self.change_route_appends = active_graph.prepareRouteAppends(active_graph.ChangeSink, allocator, &self.engine.active_change_signal_routes, graph_count, changes.items) catch return error.OutOfMemory;
                self.structural_route_appends = active_graph.prepareRouteAppends(active_graph.StructuralSink, allocator, &self.engine.active_structural_signal_routes, graph_count, structural.items) catch return error.OutOfMemory;
                graph_plan.reservePublication(allocator, &self.engine.active_signal_graph) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidAppend => return error.ResourceLimit,
                };
                graph_plan.reserveParallelRoutes(allocator, &self.engine.active_text_signal_routes, &self.engine.active_bool_signal_routes, &self.engine.active_change_signal_routes, &self.engine.active_structural_signal_routes) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidAppend => return error.ResourceLimit,
                };
                try self.source_route_appends.?.reserveOuter(allocator, &self.engine.active_source_signal_routes, source_count);
            }

            fn appendTextRoute(self: *@This(), allocator: std.mem.Allocator, routes: *std.ArrayListUnmanaged(active_graph.RouteAppend(active_graph.TextSink)), graph_plan: *const active_graph.PreparedGraphAppend(HostSignalRecord), record: *HostSignalRecord, sink: active_graph.TextSink) CollectionError!void {
                const id = graph_plan.plannedRecordId(self.engine.active_signal_graph.items, record) orelse return error.ResourceLimit;
                routes.append(allocator, .{ .route_index = id, .value = sink }) catch return error.OutOfMemory;
            }
            fn appendBoolRoute(self: *@This(), allocator: std.mem.Allocator, routes: *std.ArrayListUnmanaged(active_graph.RouteAppend(active_graph.BoolSink)), graph_plan: *const active_graph.PreparedGraphAppend(HostSignalRecord), record: *HostSignalRecord, sink: active_graph.BoolSink) CollectionError!void {
                const id = graph_plan.plannedRecordId(self.engine.active_signal_graph.items, record) orelse return error.ResourceLimit;
                routes.append(allocator, .{ .route_index = id, .value = sink }) catch return error.OutOfMemory;
            }
            fn appendChangeRoute(self: *@This(), allocator: std.mem.Allocator, routes: *std.ArrayListUnmanaged(active_graph.RouteAppend(active_graph.ChangeSink)), graph_plan: *const active_graph.PreparedGraphAppend(HostSignalRecord), record: *HostSignalRecord, sink: active_graph.ChangeSink) CollectionError!void {
                const id = graph_plan.plannedRecordId(self.engine.active_signal_graph.items, record) orelse return error.ResourceLimit;
                routes.append(allocator, .{ .route_index = id, .value = sink }) catch return error.OutOfMemory;
            }
            fn appendStructuralRoute(self: *@This(), allocator: std.mem.Allocator, routes: *std.ArrayListUnmanaged(active_graph.RouteAppend(active_graph.StructuralSink)), graph_plan: *const active_graph.PreparedGraphAppend(HostSignalRecord), record: *HostSignalRecord, sink: active_graph.StructuralSink) CollectionError!void {
                const id = graph_plan.plannedRecordId(self.engine.active_signal_graph.items, record) orelse return error.ResourceLimit;
                routes.append(allocator, .{ .route_index = id, .value = sink }) catch return error.OutOfMemory;
            }

            fn deinitGraphRoutes(self: *@This(), allocator: std.mem.Allocator) void {
                if (self.source_route_appends) |*routes| routes.deinit(allocator);
                if (self.text_route_appends) |*routes| routes.deinit(allocator);
                if (self.bool_route_appends) |*routes| routes.deinit(allocator);
                if (self.change_route_appends) |*routes| routes.deinit(allocator);
                if (self.structural_route_appends) |*routes| routes.deinit(allocator);
                self.source_route_appends = null;
                self.text_route_appends = null;
                self.bool_route_appends = null;
                self.change_route_appends = null;
                self.structural_route_appends = null;
            }

            fn commitGraphAssumeCapacity(self: *@This()) void {
                const release = &self.graph_release.?;
                const append = &self.graph_append.?;
                release.applyAdjacency(self.engine.active_signal_graph.items);
                release.applyDense(
                    &self.engine.active_signal_graph,
                    &self.engine.active_source_signal_routes,
                    &self.engine.active_text_signal_routes,
                    &self.engine.active_bool_signal_routes,
                    &self.engine.active_change_signal_routes,
                    &self.engine.active_structural_signal_routes,
                );
                append.commitNodes(&self.engine.active_signal_graph);
                append.commitParallelRoutes(
                    &self.engine.active_text_signal_routes,
                    &self.engine.active_bool_signal_routes,
                    &self.engine.active_change_signal_routes,
                    &self.engine.active_structural_signal_routes,
                );
                self.source_route_appends.?.apply(&self.engine.active_source_signal_routes, self.graph_source_route_count);
                const graph_count = append.finalGraphCount();
                self.text_route_appends.?.apply(&self.engine.active_text_signal_routes, graph_count);
                self.bool_route_appends.?.apply(&self.engine.active_bool_signal_routes, graph_count);
                self.change_route_appends.?.apply(&self.engine.active_change_signal_routes, graph_count);
                self.structural_route_appends.?.apply(&self.engine.active_structural_signal_routes, graph_count);
                var lifecycle = ActiveSignalGraphLifecycle{ .engine = self.engine, .ctx = self.host_ctx };
                release.releaseRetired(Ctx.allocator(self.host_ctx), &lifecycle);
            }

            fn commitRenderCacheAssumeCapacity(self: *@This()) void {
                const splice = &(self.render_splice orelse return);
                splice.wire.stageAssumeCapacity(self.render_batch_target.?, Ctx.allocator(self.host_ctx)) catch @panic("prepared render batch violated its preflight contract");
                splice.apply(&self.engine.render_cache);
            }

            fn publishRenderBatchLast(self: *@This()) void {
                if (self.render_splice == null) return;
                self.render_batch_target.?.commit();
                self.render_batch_published = true;
                if (comptime @hasDecl(Ctx, "publishRenderPublication")) {
                    Ctx.publishRenderPublication(self.host_ctx, &self.host_render_publication.?);
                    self.host_render_published = true;
                }
            }

            fn collectRetiredGraphRoots(self: *@This(), allocator: std.mem.Allocator, roots: *std.ArrayListUnmanaged(*HostSignalRecord)) CollectionError!void {
                try collectRetiredGraphRootsForRemoval(self.engine, allocator, &self.removal.?, roots);
            }

            fn collectReplacementGraphRoots(self: *@This(), allocator: std.mem.Allocator, roots: *std.ArrayListUnmanaged(*HostSignalRecord)) CollectionError!void {
                try collectReplacementGraphRootsForStream(allocator, &self.replacement_stream, roots);
            }

            fn prepareSinkEdits(self: *@This(), allocator: std.mem.Allocator) CollectionError!active_graph.PreparedSinkRouteEdits {
                var text: std.ArrayListUnmanaged(active_graph.TextSinkEdit) = .empty;
                defer text.deinit(allocator);
                var bools: std.ArrayListUnmanaged(active_graph.BoolSinkEdit) = .empty;
                defer bools.deinit(allocator);
                var structural: std.ArrayListUnmanaged(active_graph.StructuralSinkEdit) = .empty;
                defer structural.deinit(allocator);
                var changes: std.ArrayListUnmanaged(active_graph.ChangeSinkEdit) = .empty;
                defer changes.deinit(allocator);
                const indexes = &self.removal.?.descriptor_indexes;
                var text_removals = std.math.add(usize, indexes.signal_text_node_indexes.items.len, indexes.signal_text_attr_indexes.items.len) catch return error.ResourceLimit;
                text_removals = std.math.add(usize, text_removals, indexes.signal_custom_text_attr_indexes.items.len) catch return error.ResourceLimit;
                text_removals = std.math.add(usize, text_removals, indexes.signal_optional_custom_text_attr_indexes.items.len) catch return error.ResourceLimit;
                const bool_removals = std.math.add(usize, indexes.signal_bool_attr_indexes.items.len, indexes.signal_custom_bool_attr_indexes.items.len) catch return error.ResourceLimit;
                const structural_removals = std.math.add(usize, self.removal.?.node_indexes.when_indexes.items.len, self.removal.?.node_indexes.each_indexes.items.len) catch return error.ResourceLimit;
                text.ensureTotalCapacity(allocator, std.math.mul(usize, 2, text_removals) catch return error.ResourceLimit) catch return error.OutOfMemory;
                bools.ensureTotalCapacity(allocator, std.math.mul(usize, 2, bool_removals) catch return error.ResourceLimit) catch return error.OutOfMemory;
                structural.ensureTotalCapacity(allocator, std.math.mul(usize, 2, structural_removals) catch return error.ResourceLimit) catch return error.OutOfMemory;
                changes.ensureTotalCapacity(allocator, std.math.mul(usize, 2, self.removal.?.node_indexes.on_change_indexes.items.len) catch return error.ResourceLimit) catch return error.OutOfMemory;
                appendTextSinkEdits(self.engine, &text, self.engine.active_stream.signal_text_nodes.items, indexes.signal_text_node_indexes.items, .text_node);
                appendTextSinkEdits(self.engine, &text, self.engine.active_stream.signal_text_attrs.items, indexes.signal_text_attr_indexes.items, .text_attr);
                appendTextSinkEdits(self.engine, &text, self.engine.active_stream.signal_custom_text_attrs.items, indexes.signal_custom_text_attr_indexes.items, .custom_text_attr);
                appendTextSinkEdits(self.engine, &text, self.engine.active_stream.signal_optional_custom_text_attrs.items, indexes.signal_optional_custom_text_attr_indexes.items, .custom_text_optional_attr);
                appendBoolSinkEdits(self.engine, &bools, self.engine.active_stream.signal_bool_attrs.items, indexes.signal_bool_attr_indexes.items, .bool_attr);
                appendBoolSinkEdits(self.engine, &bools, self.engine.active_stream.signal_custom_bool_attrs.items, indexes.signal_custom_bool_attr_indexes.items, .custom_bool_attr);
                appendChangeSinkEdits(self.engine, &changes, self.engine.active_stream.on_changes.items, self.removal.?.node_indexes.on_change_indexes.items);
                appendStructuralSinkEdits(self.engine, &structural, self.engine.active_stream.whens.items, self.removal.?.node_indexes.when_indexes.items, .when);
                appendStructuralSinkEdits(self.engine, &structural, self.engine.active_stream.eaches.items, self.removal.?.node_indexes.each_indexes.items, .each);
                return active_graph.prepareSinkRouteEdits(
                    allocator,
                    &self.engine.active_text_signal_routes,
                    &self.engine.active_bool_signal_routes,
                    &self.engine.active_change_signal_routes,
                    &self.engine.active_structural_signal_routes,
                    text.items,
                    bools.items,
                    changes.items,
                    structural.items,
                ) catch return error.OutOfMemory;
            }

            fn appendTextSinkEdits(engine_ptr: *Self, edits: *std.ArrayListUnmanaged(active_graph.TextSinkEdit), descriptors: anytype, removal_indexes: []const usize, kind: active_graph.TextSinkKind) void {
                var live_len = descriptors.len;
                for (removal_indexes) |index| {
                    edits.appendAssumeCapacity(.{ .record_id = engine_ptr.requireActiveSignalRecordId(descriptors[index].signal.record), .kind = kind, .old_index = index });
                    const last_index = live_len - 1;
                    if (index != last_index) edits.appendAssumeCapacity(.{ .record_id = engine_ptr.requireActiveSignalRecordId(descriptors[last_index].signal.record), .kind = kind, .old_index = last_index, .new_index = index });
                    live_len = last_index;
                }
            }

            fn appendBoolSinkEdits(engine_ptr: *Self, edits: *std.ArrayListUnmanaged(active_graph.BoolSinkEdit), descriptors: anytype, removal_indexes: []const usize, kind: active_graph.BoolSinkKind) void {
                var live_len = descriptors.len;
                for (removal_indexes) |index| {
                    edits.appendAssumeCapacity(.{ .record_id = engine_ptr.requireActiveSignalRecordId(descriptors[index].signal.record), .kind = kind, .old_index = index });
                    const last_index = live_len - 1;
                    if (index != last_index) edits.appendAssumeCapacity(.{ .record_id = engine_ptr.requireActiveSignalRecordId(descriptors[last_index].signal.record), .kind = kind, .old_index = last_index, .new_index = index });
                    live_len = last_index;
                }
            }

            fn appendChangeSinkEdits(engine_ptr: *Self, edits: *std.ArrayListUnmanaged(active_graph.ChangeSinkEdit), descriptors: anytype, removal_indexes: []const usize) void {
                var live_len = descriptors.len;
                for (removal_indexes) |index| {
                    edits.appendAssumeCapacity(.{ .record_id = engine_ptr.requireActiveSignalRecordId(descriptors[index].signal.record), .old_index = index });
                    const last_index = live_len - 1;
                    if (index != last_index) edits.appendAssumeCapacity(.{ .record_id = engine_ptr.requireActiveSignalRecordId(descriptors[last_index].signal.record), .old_index = last_index, .new_index = index });
                    live_len = last_index;
                }
            }

            fn appendStructuralSinkEdits(engine_ptr: *Self, edits: *std.ArrayListUnmanaged(active_graph.StructuralSinkEdit), descriptors: anytype, removal_indexes: []const usize, comptime kind: active_graph.StructuralKind) void {
                var live_len = descriptors.len;
                for (removal_indexes) |index| {
                    const record = switch (kind) {
                        .when => descriptors[index].condition.record,
                        .each => descriptors[index].items.record,
                    };
                    edits.appendAssumeCapacity(.{ .record_id = engine_ptr.requireActiveSignalRecordId(record), .kind = kind, .old_index = index });
                    const last_index = live_len - 1;
                    if (index != last_index) {
                        const moved_record = switch (kind) {
                            .when => descriptors[last_index].condition.record,
                            .each => descriptors[last_index].items.record,
                        };
                        edits.appendAssumeCapacity(.{ .record_id = engine_ptr.requireActiveSignalRecordId(moved_record), .kind = kind, .old_index = last_index, .new_index = index });
                    }
                    live_len = last_index;
                }
            }

            fn commitStateCellsAssumeCapacity(self: *@This()) void {
                const retirement = PreparedStateRetirementIndexes{ .indexes_descending = self.state_cell_indexes };
                retirement.apply(self.engine, &self.retired_state_cells);
                self.collection.commit();
            }

            fn commitIdentityRetirement(self: *@This()) void {
                const retirements = PreparedIdentityRetirements{ .node_ids = self.retired_node_identity_ids, .dom_ids = self.retired_dom_identity_ids };
                retirements.apply(self.engine);
            }

            fn commitRowRetirement(self: *@This()) void {
                var row_keys = EachRowScopeKeyLookup{ .engine = self.engine };
                self.row_retirement.?.apply(&self.engine.each_row_sites, &self.engine.each_row_memberships_by_scope_id, &row_keys);
            }

            fn commitEffectsRetirement(self: *@This()) void {
                self.effects_retirement.?.apply(self.engine, self.host_ctx);
            }

            fn commitScopeRetirementLast(self: *@This()) void {
                for (self.scope_retirement.?.scope_ids) |scope_id| {
                    const scope = &self.engine.scopes.items[@intCast(scope_id)];
                    self.retired_scope_steps.appendAssumeCapacity(scope.step);
                    scope.step = .root;
                }
                self.scope_retirement.?.applyMetadata(HostEachRowScopeStep, self.engine.scopes.items, self.engine.identity_reuse_barrier);
                self.engine.has_inactive_scopes = self.scope_retirement.?.scope_ids.len != 0 or self.engine.has_inactive_scopes;
            }

            fn commitAssumeCapacity(self: *@This()) void {
                self.commitRenderCacheAssumeCapacity();
                if (self.sink_edits) |*edits| edits.apply(
                    &self.engine.active_text_signal_routes,
                    &self.engine.active_bool_signal_routes,
                    &self.engine.active_change_signal_routes,
                    &self.engine.active_structural_signal_routes,
                );
                if (self.graph_release != null) self.commitGraphAssumeCapacity();
                const indexes = &self.removal.?.descriptor_indexes;
                self.engine.active_stream.commitStaticDescriptorReplacementAssumeCapacity(
                    &self.replacement_stream,
                    &self.retired_stream,
                    indexes.element_indexes.items,
                    indexes.text_node_indexes.items,
                    indexes.static_text_attr_indexes.items,
                    indexes.static_bool_attr_indexes.items,
                    indexes.signal_text_node_indexes.items,
                    indexes.signal_text_attr_indexes.items,
                    indexes.signal_bool_attr_indexes.items,
                    indexes.event_indexes.items,
                    self.removal.?.node_indexes.scope_site_indexes.items,
                    self.removal.?.node_indexes.state_indexes.items,
                    self.removal.?.node_indexes.when_indexes.items,
                    self.removal.?.node_indexes.each_indexes.items,
                );
                self.engine.active_stream.commitCustomDescriptorReplacementAssumeCapacity(
                    &self.replacement_stream,
                    &self.retired_stream,
                    indexes.static_custom_text_attr_indexes.items,
                    indexes.signal_custom_text_attr_indexes.items,
                    indexes.signal_optional_custom_text_attr_indexes.items,
                    indexes.static_custom_bool_attr_indexes.items,
                    indexes.signal_custom_bool_attr_indexes.items,
                );
                self.engine.active_stream.commitLifecycleReplacementAssumeCapacity(
                    &self.replacement_stream,
                    &self.retired_stream,
                    self.removal.?.node_indexes.on_change_indexes.items,
                    self.removal.?.node_indexes.mount_indexes.items,
                    self.removal.?.node_indexes.cleanup_indexes.items,
                );
                self.commitStateCellsAssumeCapacity();
                self.commitIdentityRetirement();
                self.commitRowRetirement();
                self.commitEffectsRetirement();
                self.commitScopeRetirementLast();
                self.publishRenderBatchLast();
            }

            fn deinit(self: *@This()) void {
                const allocator = Ctx.allocator(self.host_ctx);
                if (self.render_batch_preflighted and !self.render_batch_published and self.render_batch_target != &self.render_batch) self.render_batch_target.?.abort();
                if (@hasDecl(Ctx, "RenderPublication")) if (self.host_render_publication) |*publication| publication.deinit();
                self.render_batch.deinit(allocator);
                if (self.render_splice) |*splice| splice.deinit();
                if (self.publication) |*publication| publication.deinit(allocator);
                if (self.sink_edits) |*edits| edits.deinit(allocator);
                if (self.graph_append) |*append| append.deinit(allocator);
                if (self.graph_release) |*release| release.deinit(allocator);
                self.deinitGraphRoutes(allocator);
                if (self.removal) |*removal| removal.deinit(allocator);
                if (self.scope_retirement) |*retirement| retirement.deinit(allocator);
                if (self.row_retirement) |*retirement| retirement.deinit(allocator);
                if (self.effects_retirement) |*effects| effects.deinit(allocator, self.roc_host);
                for (self.retired_scope_steps.items) |*step| deinitHostScopeStep(step, self.host_ctx, self.roc_host, &self.engine.pending_roc_metrics);
                self.retired_scope_steps.deinit(allocator);
                allocator.free(self.state_cell_indexes);
                allocator.free(self.retired_node_identity_ids);
                allocator.free(self.retired_dom_identity_ids);
                for (self.retired_state_cells.items) |*state| state.cell.deinit(self.host_ctx, self.roc_host, &self.engine.pending_roc_metrics);
                self.retired_state_cells.deinit(allocator);
                allocator.free(self.target_scopes);
                self.collection.deinit();
                self.retired_stream.deinit(allocator, self.host_ctx, self.roc_host, &self.engine.pending_roc_metrics);
                self.replacement_stream.deinit(allocator, self.host_ctx, self.roc_host, &self.engine.pending_roc_metrics);
                allocator.destroy(self);
            }
        };

        /// Transactional production seam for roots composed only of static
        /// elements and text. Unsupported variants remain on the immediate
        /// collector until their ownership operations are staged as well.
        pub fn collectStaticRootDescriptorsTransactional(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, stream: *HostNodeDescriptorStream, root: abi.Elem, limits: collection_budget.Limits) CollectionError!void {
            const expected = try countStaticRootNodes(root);
            var collection = try StagedCollectionCtx.init(self, ctx, stream, limits, expected.nodes, expected.attrs, expected.lifecycle, expected.signal_records, expected.state_sites, expected.component_sites, expected.when_sites, 1);
            defer collection.deinit();
            try self.collectActiveElemRootDescriptorsWith(*StagedCollectionCtx, &collection, ctx, roc_host, stream, root, &.{});
            collection.commit();
        }

        /// Collects active elem root descriptors from the explicitly affected graph or scope set.
        pub fn collectActiveElemRootDescriptors(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, stream: *HostNodeDescriptorStream, root: abi.Elem, dirty_source_node_ids: []const u64) void {
            const collection = ImmediateCollectionCtx{ .engine = self, .host_ctx = ctx, .stream = stream };
            self.collectActiveElemRootDescriptorsWith(ImmediateCollectionCtx, collection, ctx, roc_host, stream, root, dirty_source_node_ids) catch @panic("immediate root descriptor collection failed");
        }

        /// Clears active signal graph while retaining bounded storage where the type promises reuse.
        pub fn clearActiveSignalGraph(self: *Self, ctx: Ctx.Handle) void {
            const allocator = Ctx.allocator(ctx);
            if (self.roc_host == null) {
                if (self.active_signal_graph.items.len != 0) @panic("active signal graph cannot release records without a Roc host");
                self.active_signal_graph.items.len = 0;
                return;
            }
            var lifecycle = ActiveSignalGraphLifecycle{ .engine = self, .ctx = ctx };
            active_graph.clear(HostSignalRecord, allocator, &self.active_signal_graph, &lifecycle);
        }

        /// Clears active intervals while retaining bounded storage where the type promises reuse.
        pub fn clearActiveIntervals(self: *Self, ctx: Ctx.Handle) void {
            effects_runtime.clearActiveIntervals(Ctx, ctx, &self.active_intervals, self.roc_host);
        }

        fn ensureActiveInterval(self: *Self, ctx: Ctx.Handle, source_token: HostSignalToken, period_ms: u64) void {
            effects_runtime.ensureActiveInterval(Ctx, ctx, Ctx.allocator(ctx), &self.active_intervals, &self.next_interval_token, self.roc_host.?, source_token, period_ms);
        }

        fn removeActiveIntervalBySourceToken(self: *Self, ctx: Ctx.Handle, source_token: HostSignalToken) void {
            effects_runtime.removeActiveIntervalBySourceToken(Ctx, ctx, &self.active_intervals, self.roc_host orelse @panic("active interval cannot release token without a Roc host"), source_token);
        }

        fn syncActiveIntervalsFromGraph(self: *Self, ctx: Ctx.Handle) void {
            effects_runtime.syncActiveIntervalsFromGraph(Ctx, ctx, Ctx.allocator(ctx), &self.active_intervals, &self.next_interval_token, self.roc_host, self.active_signal_graph.items, &self.pending_roc_metrics);
        }

        /// Clears active signal routes while retaining bounded storage where the type promises reuse.
        pub fn clearActiveSignalRoutes(self: *Self, ctx: Ctx.Handle) void {
            active_graph.clearRoutes(
                Ctx.allocator(ctx),
                &self.active_source_signal_routes,
                &self.active_text_signal_routes,
                &self.active_bool_signal_routes,
                &self.active_change_signal_routes,
                &self.active_structural_signal_routes,
            );
        }

        /// Clears active sink signal routes while retaining bounded storage where the type promises reuse.
        pub fn clearActiveSinkSignalRoutes(self: *Self, ctx: Ctx.Handle) void {
            active_graph.clearSinkRoutes(
                Ctx.allocator(ctx),
                &self.active_text_signal_routes,
                &self.active_bool_signal_routes,
                &self.active_change_signal_routes,
                &self.active_structural_signal_routes,
            );
        }

        /// Returns active signal record id from the maintained active-runtime indexes.
        pub fn activeSignalRecordId(self: *Self, record: *const HostSignalRecord) ?u64 {
            return active_graph.recordId(HostSignalRecord, self.active_signal_graph.items, record);
        }

        /// Performs require active signal record id inside the shared engine while preserving transaction and changed-set invariants.
        pub fn requireActiveSignalRecordId(self: *Self, record: *const HostSignalRecord) u64 {
            return active_graph.requireRecordId(HostSignalRecord, self.active_signal_graph.items, record);
        }

        /// Appends active signal graph node using capacity that must already satisfy the caller's transaction contract.
        pub fn appendActiveSignalGraphNode(self: *Self, ctx: Ctx.Handle, record: *HostSignalRecord, rank: u64) u64 {
            const record_id = active_graph.appendNode(HostSignalRecord, Ctx.allocator(ctx), &self.active_signal_graph, record, rank);
            self.pending_roc_metrics.bump(.active_graph_records_rebuilt, 1);
            return record_id;
        }

        /// Appends active signal dependent id using capacity that must already satisfy the caller's transaction contract.
        pub fn appendActiveSignalDependentId(self: *Self, ctx: Ctx.Handle, input_record_id: u64, dependent_record_id: u64) void {
            active_graph.appendDependentId(HostSignalRecord, Ctx.allocator(ctx), self.active_signal_graph.items, input_record_id, dependent_record_id);
        }

        /// Appends active source signal route using capacity that must already satisfy the caller's transaction contract.
        pub fn appendActiveSourceSignalRoute(self: *Self, ctx: Ctx.Handle, source_node_id: u64, record_id: u64) void {
            active_graph.appendSourceRoute(Ctx.allocator(ctx), &self.active_source_signal_routes, self.node_identities.items.len, source_node_id, record_id);
        }

        /// Performs retain active signal record inside the shared engine while preserving transaction and changed-set invariants.
        pub fn retainActiveSignalRecord(self: *Self, ctx: Ctx.Handle, record: *HostSignalRecord) void {
            var lifecycle = ActiveSignalGraphLifecycle{ .engine = self, .ctx = ctx };
            const records_rebuilt = active_graph.retainRecord(
                HostSignalRecord,
                Ctx.allocator(ctx),
                &self.active_signal_graph,
                &self.active_source_signal_routes,
                self.node_identities.items.len,
                record,
                &lifecycle,
            );
            self.pending_roc_metrics.bump(.active_graph_records_rebuilt, records_rebuilt);
        }

        /// Ensures active source signal route capacity or state before publication can begin.
        pub fn ensureActiveSourceSignalRoute(self: *Self, ctx: Ctx.Handle, source_node_id: u64) *std.ArrayListUnmanaged(u64) {
            return active_graph.ensureSourceRoute(Ctx.allocator(ctx), &self.active_source_signal_routes, self.node_identities.items.len, source_node_id);
        }

        /// Ensures active text signal route capacity or state before publication can begin.
        pub fn ensureActiveTextSignalRoute(self: *Self, ctx: Ctx.Handle, record_id: u64) *std.ArrayListUnmanaged(HostActiveTextSignalSink) {
            return active_graph.ensureTextRoute(Ctx.allocator(ctx), &self.active_text_signal_routes, self.active_signal_graph.items.len, record_id);
        }

        /// Ensures active bool signal route capacity or state before publication can begin.
        pub fn ensureActiveBoolSignalRoute(self: *Self, ctx: Ctx.Handle, record_id: u64) *std.ArrayListUnmanaged(HostActiveBoolSignalSink) {
            return active_graph.ensureBoolRoute(Ctx.allocator(ctx), &self.active_bool_signal_routes, self.active_signal_graph.items.len, record_id);
        }

        /// Ensures active change signal route capacity or state before publication can begin.
        pub fn ensureActiveChangeSignalRoute(self: *Self, ctx: Ctx.Handle, record_id: u64) *std.ArrayListUnmanaged(HostActiveChangeSignalSink) {
            return active_graph.ensureChangeRoute(Ctx.allocator(ctx), &self.active_change_signal_routes, self.active_signal_graph.items.len, record_id);
        }

        /// Ensures active structural signal route capacity or state before publication can begin.
        pub fn ensureActiveStructuralSignalRoute(self: *Self, ctx: Ctx.Handle, record_id: u64) *std.ArrayListUnmanaged(HostActiveStructuralSignal) {
            return active_graph.ensureStructuralRoute(Ctx.allocator(ctx), &self.active_structural_signal_routes, self.active_signal_graph.items.len, record_id);
        }

        fn appendActiveTextSignalRoute(self: *Self, ctx: Ctx.Handle, record_id: u64, route: HostActiveTextSignalSink) void {
            active_graph.appendTextRoute(Ctx.allocator(ctx), &self.active_text_signal_routes, self.active_signal_graph.items.len, record_id, route);
        }

        fn removeActiveTextSignalRoute(self: *Self, record_id: u64, kind: HostActiveTextSignalSinkKind, index: usize) void {
            active_graph.removeTextRoute(&self.active_text_signal_routes, record_id, kind, index);
        }

        fn updateActiveTextSignalRouteIndex(self: *Self, record_id: u64, kind: HostActiveTextSignalSinkKind, old_index: usize, new_index: usize) void {
            active_graph.updateTextRouteIndex(&self.active_text_signal_routes, record_id, kind, old_index, new_index);
        }

        fn appendActiveBoolSignalRoute(self: *Self, ctx: Ctx.Handle, record_id: u64, route: HostActiveBoolSignalSink) void {
            active_graph.appendBoolRoute(Ctx.allocator(ctx), &self.active_bool_signal_routes, self.active_signal_graph.items.len, record_id, route);
        }

        fn removeActiveBoolSignalRoute(self: *Self, record_id: u64, kind: HostActiveBoolSignalSinkKind, index: usize) void {
            active_graph.removeBoolRoute(&self.active_bool_signal_routes, record_id, kind, index);
        }

        fn updateActiveBoolSignalRouteIndex(self: *Self, record_id: u64, kind: HostActiveBoolSignalSinkKind, old_index: usize, new_index: usize) void {
            active_graph.updateBoolRouteIndex(&self.active_bool_signal_routes, record_id, kind, old_index, new_index);
        }

        fn appendActiveChangeSignalRoute(self: *Self, ctx: Ctx.Handle, record_id: u64, route: HostActiveChangeSignalSink) void {
            active_graph.appendChangeRoute(Ctx.allocator(ctx), &self.active_change_signal_routes, self.active_signal_graph.items.len, record_id, route);
        }

        fn removeActiveChangeSignalRoute(self: *Self, record_id: u64, index: usize) void {
            active_graph.removeChangeRoute(&self.active_change_signal_routes, record_id, index);
        }

        fn updateActiveChangeSignalRouteIndex(self: *Self, record_id: u64, old_index: usize, new_index: usize) void {
            active_graph.updateChangeRouteIndex(&self.active_change_signal_routes, record_id, old_index, new_index);
        }

        fn appendActiveStructuralSignalRoute(self: *Self, ctx: Ctx.Handle, record_id: u64, route: HostActiveStructuralSignal) void {
            active_graph.appendStructuralRoute(Ctx.allocator(ctx), &self.active_structural_signal_routes, self.active_signal_graph.items.len, record_id, route);
        }

        fn removeActiveStructuralSignalRoute(self: *Self, record_id: u64, kind: HostActiveStructuralSignalKind, index: usize) void {
            active_graph.removeStructuralRoute(&self.active_structural_signal_routes, record_id, kind, index);
        }

        fn updateActiveStructuralSignalRouteIndex(self: *Self, record_id: u64, kind: HostActiveStructuralSignalKind, old_index: usize, new_index: usize) void {
            active_graph.updateStructuralRouteIndex(&self.active_structural_signal_routes, record_id, kind, old_index, new_index);
        }

        /// Performs rebuild active sink signal routes from stream inside the shared engine while preserving transaction and changed-set invariants.
        pub fn rebuildActiveSinkSignalRoutesFromStream(self: *Self, ctx: Ctx.Handle, stream: *const HostNodeDescriptorStream) void {
            active_graph.rebuildSinkRoutesFromStream(
                HostSignalRecord,
                Ctx.allocator(ctx),
                self.active_signal_graph.items,
                &self.active_text_signal_routes,
                &self.active_bool_signal_routes,
                &self.active_change_signal_routes,
                &self.active_structural_signal_routes,
                stream,
            );
        }

        /// Performs rebuild active signal graph from stream inside the shared engine while preserving transaction and changed-set invariants.
        pub fn rebuildActiveSignalGraphFromStream(self: *Self, ctx: Ctx.Handle, stream: *const HostNodeDescriptorStream) void {
            self.clearActiveSignalRoutes(ctx);
            self.clearActiveSignalGraph(ctx);

            var lifecycle = ActiveSignalGraphLifecycle{ .engine = self, .ctx = ctx };
            const records_rebuilt = active_graph.retainStreamRecords(
                HostSignalRecord,
                Ctx.allocator(ctx),
                &self.active_signal_graph,
                &self.active_source_signal_routes,
                self.node_identities.items.len,
                stream,
                &lifecycle,
            );
            self.pending_roc_metrics.bump(.active_graph_records_rebuilt, records_rebuilt);

            self.rebuildActiveSinkSignalRoutesFromStream(ctx, stream);
            self.syncActiveIntervalsFromGraph(ctx);
        }

        /// Performs release active signal record inside the shared engine while preserving transaction and changed-set invariants.
        pub fn releaseActiveSignalRecord(self: *Self, ctx: Ctx.Handle, record: *HostSignalRecord) void {
            var lifecycle = ActiveSignalGraphLifecycle{ .engine = self, .ctx = ctx };
            active_graph.releaseRecord(
                HostSignalRecord,
                Ctx.allocator(ctx),
                &self.active_signal_graph,
                &self.active_source_signal_routes,
                &self.active_text_signal_routes,
                &self.active_bool_signal_routes,
                &self.active_change_signal_routes,
                &self.active_structural_signal_routes,
                record,
                &lifecycle,
            );
        }

        fn deinitActiveSignalTextNodeDesc(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, desc: *HostNodeSignalTextNodeDesc) void {
            desc.cached_value.deinit(ctx, roc_host, &self.pending_roc_metrics);
            desc.signal.deinit(Ctx.allocator(ctx), ctx, roc_host, &self.pending_roc_metrics);
            releaseHostTextRead(desc.read, roc_host, &self.pending_roc_metrics);
        }

        fn deinitActiveSignalTextAttrDesc(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, desc: *HostNodeSignalTextAttrDesc) void {
            desc.cached_value.deinit(ctx, roc_host, &self.pending_roc_metrics);
            desc.signal.deinit(Ctx.allocator(ctx), ctx, roc_host, &self.pending_roc_metrics);
            releaseHostTextRead(desc.read, roc_host, &self.pending_roc_metrics);
        }

        fn deinitActiveSignalCustomTextAttrDesc(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, desc: *HostNodeSignalCustomTextAttrDesc) void {
            const allocator = Ctx.allocator(ctx);
            allocator.free(desc.name);
            desc.cached_value.deinit(ctx, roc_host, &self.pending_roc_metrics);
            desc.signal.deinit(allocator, ctx, roc_host, &self.pending_roc_metrics);
            releaseHostTextRead(desc.read, roc_host, &self.pending_roc_metrics);
        }

        fn deinitActiveSignalOptionalCustomTextAttrDesc(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, desc: *HostNodeSignalOptionalCustomTextAttrDesc) void {
            const allocator = Ctx.allocator(ctx);
            allocator.free(desc.name);
            desc.cached_value.deinit(ctx, roc_host, &self.pending_roc_metrics);
            desc.signal.deinit(allocator, ctx, roc_host, &self.pending_roc_metrics);
            releaseHostBoolRead(desc.present, roc_host, &self.pending_roc_metrics);
            releaseHostTextRead(desc.read, roc_host, &self.pending_roc_metrics);
        }

        fn deinitActiveSignalCustomBoolAttrDesc(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, desc: *HostNodeSignalCustomBoolAttrDesc) void {
            const allocator = Ctx.allocator(ctx);
            allocator.free(desc.name);
            desc.cached_value.deinit(ctx, roc_host, &self.pending_roc_metrics);
            desc.signal.deinit(allocator, ctx, roc_host, &self.pending_roc_metrics);
            releaseHostBoolRead(desc.read, roc_host, &self.pending_roc_metrics);
        }

        fn deinitActiveSignalBoolAttrDesc(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, desc: *HostNodeSignalBoolAttrDesc) void {
            desc.cached_value.deinit(ctx, roc_host, &self.pending_roc_metrics);
            desc.signal.deinit(Ctx.allocator(ctx), ctx, roc_host, &self.pending_roc_metrics);
            releaseHostBoolRead(desc.read, roc_host, &self.pending_roc_metrics);
        }

        fn deinitActiveOnChangeDesc(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, desc: *HostNodeOnChangeDesc) void {
            desc.cached_value.deinit(ctx, roc_host, &self.pending_roc_metrics);
            desc.signal.deinit(Ctx.allocator(ctx), ctx, roc_host, &self.pending_roc_metrics);
            self.pending_roc_metrics.bump(.closure_releases, 1);
            abi.decrefErasedCallable(desc.to_cmd, roc_host);
        }

        fn deinitActiveMountDesc(self: *Self, roc_host: *abi.RocHost, desc: *HostNodeMountDesc) void {
            self.pending_roc_metrics.bump(.closure_releases, 1);
            abi.decrefErasedCallable(desc.to_cmd, roc_host);
        }

        /// Evaluates scope is in replacement target using explicit scope ownership rather than DOM position or content.
        pub fn scopeIsInReplacementTarget(self: *Self, scope_id: u64, target: HostStructuralReplacementTarget) bool {
            return switch (target) {
                .scope => |root_scope_id| self.scopeIsDescendantOrSelf(scope_id, root_scope_id) catch @panic("scope descriptor referenced an unknown parent scope"),
                .each_site => |site| self.scopeIsEachSiteRowDescendantOrSelf(scope_id, site) catch @panic("scope descriptor referenced an unknown parent scope"),
            };
        }

        fn buildReplacementTargetScopeSet(self: *Self, ctx: Ctx.Handle, target: HostStructuralReplacementTarget) []const bool {
            const TargetLookup = struct {
                engine: *Self,

                /// Evaluates scope is in target using explicit scope ownership rather than DOM position or content.
                pub fn scopeIsInTarget(self_lookup: *@This(), scope_id: u64, replacement_target: HostStructuralReplacementTarget) bool {
                    return self_lookup.engine.scopeIsInReplacementTarget(scope_id, replacement_target);
                }
            };
            var lookup = TargetLookup{ .engine = self };
            return structural_splice.buildTargetScopeSet(HostScope, Ctx.allocator(ctx), &self.scratch.replacement_target_scopes, self.scopes.items, target, &lookup);
        }

        /// Returns in replacement target for an already indexed render node.
        pub fn renderNodeInReplacementTarget(self: *Self, stream: *const HostNodeDescriptorStream, node: HostRenderNode, target: HostStructuralReplacementTarget) bool {
            return self.scopeIsInReplacementTarget(renderNodeScopeId(stream, node), target);
        }

        /// Returns in replacement target set for an already indexed render node.
        pub fn renderNodeInReplacementTargetSet(self: *Self, stream: *const HostNodeDescriptorStream, node: HostRenderNode, target_scopes: []const bool) bool {
            _ = self;
            return structural_splice.scopeIsInTargetSet(target_scopes, renderNodeScopeId(stream, node));
        }

        /// Performs elem id in replacement target inside the shared engine while preserving transaction and changed-set invariants.
        pub fn elemIdInReplacementTarget(self: *Self, stream: *const HostNodeDescriptorStream, elem_id: u64, target: HostStructuralReplacementTarget) bool {
            const scope_id = elemScopeId(stream, elem_id) orelse @panic("descriptor referenced an element outside the render stream");
            return self.scopeIsInReplacementTarget(scope_id, target);
        }

        /// Performs elem id in replacement target set inside the shared engine while preserving transaction and changed-set invariants.
        pub fn elemIdInReplacementTargetSet(self: *Self, stream: *const HostNodeDescriptorStream, elem_id: u64, target_scopes: []const bool) bool {
            _ = self;
            const scope_id = elemScopeId(stream, elem_id) orelse @panic("descriptor referenced an element outside the render stream");
            return structural_splice.scopeIsInTargetSet(target_scopes, scope_id);
        }

        /// Reads node id in replacement target from the active descriptor stream using engine-owned identity.
        pub fn streamNodeIdInReplacementTarget(self: *Self, previous: *const HostNodeDescriptorStream, node_id: u64, kind: HostNodeScopeSiteKind, target: HostStructuralReplacementTarget) bool {
            const descriptor_index = previous.nodeDescriptorIndex(node_id) orelse return false;
            const site_index = descriptor_index.scope_sites.get(kind) orelse return false;
            if (site_index >= previous.scope_sites.items.len) @panic("scope site descriptor index exceeded descriptor table");
            const site = previous.scope_sites.items[site_index];
            if (site.node_id != node_id or site.kind != kind) @panic("scope site descriptor index pointed at the wrong node");
            return self.scopeIsInReplacementTarget(site.scope_id, target);
        }

        /// Reads node id in replacement target set from the active descriptor stream using engine-owned identity.
        pub fn streamNodeIdInReplacementTargetSet(self: *Self, previous: *const HostNodeDescriptorStream, node_id: u64, kind: HostNodeScopeSiteKind, target_scopes: []const bool) bool {
            _ = self;
            const descriptor_index = previous.nodeDescriptorIndex(node_id) orelse return false;
            const site_index = descriptor_index.scope_sites.get(kind) orelse return false;
            if (site_index >= previous.scope_sites.items.len) @panic("scope site descriptor index exceeded descriptor table");
            const site = previous.scope_sites.items[site_index];
            if (site.node_id != node_id or site.kind != kind) @panic("scope site descriptor index pointed at the wrong node");
            return structural_splice.scopeIsInTargetSet(target_scopes, site.scope_id);
        }

        fn appendNamedEventRemovalIndexes(self: *Self, ctx: Ctx.Handle, indexes: *std.ArrayListUnmanaged(usize), elem_id: u64) void {
            const named_event_indices = self.active_stream.namedEventIndices(elem_id);
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_remove_target, named_event_indices.len);
            for (named_event_indices) |index| {
                indexes.append(Ctx.allocator(ctx), index) catch @panic("out of memory");
            }
        }

        fn clearElemOwnedRemovalScratch(self: *Self) void {
            self.scratch.elem_owned_removal.clearRetainingCapacity();
        }

        fn removeActiveElementDescriptorAt(self: *Self, ctx: Ctx.Handle, index: usize) void {
            const allocator = Ctx.allocator(ctx);
            if (index >= self.active_stream.elements.items.len) @panic("element removal index exceeded descriptor table");
            const last_index = self.active_stream.elements.items.len - 1;
            const removed = self.active_stream.elements.items[index];
            self.active_stream.clearElementIndex(removed.elem_id, index);
            allocator.free(removed.tag);

            if (index != last_index) {
                const moved = self.active_stream.elements.items[last_index];
                self.active_stream.elements.items[index] = moved;
                self.active_stream.updateElementIndex(moved.elem_id, index);
            }
            self.active_stream.elements.items.len = last_index;
        }

        fn removeActiveTextNodeDescriptorAt(self: *Self, ctx: Ctx.Handle, index: usize) void {
            const allocator = Ctx.allocator(ctx);
            if (index >= self.active_stream.text_nodes.items.len) @panic("text node removal index exceeded descriptor table");
            const last_index = self.active_stream.text_nodes.items.len - 1;
            const removed = self.active_stream.text_nodes.items[index];
            self.active_stream.clearTextNodeIndex(removed.elem_id, index);
            allocator.free(removed.value);

            if (index != last_index) {
                const moved = self.active_stream.text_nodes.items[last_index];
                self.active_stream.text_nodes.items[index] = moved;
                self.active_stream.updateTextNodeIndex(moved.elem_id, index);
            }
            self.active_stream.text_nodes.items.len = last_index;
        }

        fn removeActiveSignalTextNodeDescriptorAt(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, index: usize) void {
            if (index >= self.active_stream.signal_text_nodes.items.len) @panic("signal text node removal index exceeded descriptor table");
            const last_index = self.active_stream.signal_text_nodes.items.len - 1;
            var removed = self.active_stream.signal_text_nodes.items[index];
            const removed_record_id = self.requireActiveSignalRecordId(removed.signal.record);
            self.removeActiveTextSignalRoute(removed_record_id, .text_node, index);
            self.active_stream.clearSignalTextNodeIndex(removed.elem_id, index);
            self.active_stream.forgetSignalRecordTree(removed.signal.record);
            self.releaseActiveSignalRecord(ctx, removed.signal.record);
            self.deinitActiveSignalTextNodeDesc(ctx, roc_host, &removed);

            if (index != last_index) {
                const moved = self.active_stream.signal_text_nodes.items[last_index];
                const moved_record_id = self.requireActiveSignalRecordId(moved.signal.record);
                self.active_stream.signal_text_nodes.items[index] = moved;
                self.updateActiveTextSignalRouteIndex(moved_record_id, .text_node, last_index, index);
                self.active_stream.updateSignalTextNodeIndex(moved.elem_id, index);
            }
            self.active_stream.signal_text_nodes.items.len = last_index;
        }

        fn removeActiveStaticTextAttrDescriptorAt(self: *Self, ctx: Ctx.Handle, index: usize) void {
            const allocator = Ctx.allocator(ctx);
            if (index >= self.active_stream.static_text_attrs.items.len) @panic("static text attr removal index exceeded descriptor table");
            const last_index = self.active_stream.static_text_attrs.items.len - 1;
            const removed = self.active_stream.static_text_attrs.items[index];
            self.active_stream.clearStaticTextAttrIndex(removed.elem_id, removed.field, index);
            allocator.free(removed.value);

            if (index != last_index) {
                const moved = self.active_stream.static_text_attrs.items[last_index];
                self.active_stream.static_text_attrs.items[index] = moved;
                self.active_stream.updateStaticTextAttrIndex(moved.elem_id, moved.field, index);
            }
            self.active_stream.static_text_attrs.items.len = last_index;
        }

        fn removeActiveSignalTextAttrDescriptorAt(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, index: usize) void {
            if (index >= self.active_stream.signal_text_attrs.items.len) @panic("signal text attr removal index exceeded descriptor table");
            const last_index = self.active_stream.signal_text_attrs.items.len - 1;
            var removed = self.active_stream.signal_text_attrs.items[index];
            const removed_record_id = self.requireActiveSignalRecordId(removed.signal.record);
            self.removeActiveTextSignalRoute(removed_record_id, .text_attr, index);
            self.active_stream.clearSignalTextAttrIndex(removed.elem_id, removed.field, index);
            self.active_stream.forgetSignalRecordTree(removed.signal.record);
            self.releaseActiveSignalRecord(ctx, removed.signal.record);
            self.deinitActiveSignalTextAttrDesc(ctx, roc_host, &removed);

            if (index != last_index) {
                const moved = self.active_stream.signal_text_attrs.items[last_index];
                const moved_record_id = self.requireActiveSignalRecordId(moved.signal.record);
                self.active_stream.signal_text_attrs.items[index] = moved;
                self.updateActiveTextSignalRouteIndex(moved_record_id, .text_attr, last_index, index);
                self.active_stream.updateSignalTextAttrIndex(moved.elem_id, moved.field, index);
            }
            self.active_stream.signal_text_attrs.items.len = last_index;
        }

        fn removeActiveStaticCustomTextAttrDescriptorsForRemovedElems(self: *Self, ctx: Ctx.Handle, removed_elem_ids: []const u64) void {
            const allocator = Ctx.allocator(ctx);
            var write_index: usize = 0;
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_remove_target, self.active_stream.static_custom_text_attrs.items.len);
            for (self.active_stream.static_custom_text_attrs.items) |desc| {
                if (u64SliceContains(removed_elem_ids, desc.elem_id)) {
                    allocator.free(desc.name);
                    allocator.free(desc.value);
                    continue;
                }
                self.active_stream.static_custom_text_attrs.items[write_index] = desc;
                write_index += 1;
            }
            self.active_stream.static_custom_text_attrs.items.len = write_index;
        }

        fn removeActiveSignalCustomTextAttrDescriptorsForRemovedElems(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, removed_elem_ids: []const u64) void {
            var write_index: usize = 0;
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_remove_target, self.active_stream.signal_custom_text_attrs.items.len);
            for (self.active_stream.signal_custom_text_attrs.items, 0..) |desc, read_index| {
                if (u64SliceContains(removed_elem_ids, desc.elem_id)) {
                    var removed = desc;
                    const record_id = self.requireActiveSignalRecordId(removed.signal.record);
                    self.removeActiveTextSignalRoute(record_id, .custom_text_attr, read_index);
                    self.active_stream.forgetSignalRecordTree(removed.signal.record);
                    self.releaseActiveSignalRecord(ctx, removed.signal.record);
                    self.deinitActiveSignalCustomTextAttrDesc(ctx, roc_host, &removed);
                    continue;
                }
                const record_id = self.requireActiveSignalRecordId(desc.signal.record);
                self.updateActiveTextSignalRouteIndex(record_id, .custom_text_attr, read_index, write_index);
                self.active_stream.signal_custom_text_attrs.items[write_index] = desc;
                write_index += 1;
            }
            self.active_stream.signal_custom_text_attrs.items.len = write_index;
        }

        fn removeActiveSignalOptionalCustomTextAttrDescriptorsForRemovedElems(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, removed_elem_ids: []const u64) void {
            var write_index: usize = 0;
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_remove_target, self.active_stream.signal_optional_custom_text_attrs.items.len);
            for (self.active_stream.signal_optional_custom_text_attrs.items, 0..) |desc, read_index| {
                if (u64SliceContains(removed_elem_ids, desc.elem_id)) {
                    var removed = desc;
                    const record_id = self.requireActiveSignalRecordId(removed.signal.record);
                    self.removeActiveTextSignalRoute(record_id, .custom_text_optional_attr, read_index);
                    self.active_stream.forgetSignalRecordTree(removed.signal.record);
                    self.releaseActiveSignalRecord(ctx, removed.signal.record);
                    self.deinitActiveSignalOptionalCustomTextAttrDesc(ctx, roc_host, &removed);
                    continue;
                }
                const record_id = self.requireActiveSignalRecordId(desc.signal.record);
                self.updateActiveTextSignalRouteIndex(record_id, .custom_text_optional_attr, read_index, write_index);
                self.active_stream.signal_optional_custom_text_attrs.items[write_index] = desc;
                write_index += 1;
            }
            self.active_stream.signal_optional_custom_text_attrs.items.len = write_index;
        }

        fn removeActiveStaticCustomBoolAttrDescriptorsForRemovedElems(self: *Self, ctx: Ctx.Handle, removed_elem_ids: []const u64) void {
            const allocator = Ctx.allocator(ctx);
            var write_index: usize = 0;
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_remove_target, self.active_stream.static_custom_bool_attrs.items.len);
            for (self.active_stream.static_custom_bool_attrs.items) |desc| {
                if (u64SliceContains(removed_elem_ids, desc.elem_id)) {
                    allocator.free(desc.name);
                    continue;
                }
                self.active_stream.static_custom_bool_attrs.items[write_index] = desc;
                write_index += 1;
            }
            self.active_stream.static_custom_bool_attrs.items.len = write_index;
        }

        fn removeActiveSignalCustomBoolAttrDescriptorsForRemovedElems(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, removed_elem_ids: []const u64) void {
            var write_index: usize = 0;
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_remove_target, self.active_stream.signal_custom_bool_attrs.items.len);
            for (self.active_stream.signal_custom_bool_attrs.items, 0..) |desc, read_index| {
                if (u64SliceContains(removed_elem_ids, desc.elem_id)) {
                    var removed = desc;
                    const record_id = self.requireActiveSignalRecordId(removed.signal.record);
                    self.removeActiveBoolSignalRoute(record_id, .custom_bool_attr, read_index);
                    self.active_stream.forgetSignalRecordTree(removed.signal.record);
                    self.releaseActiveSignalRecord(ctx, removed.signal.record);
                    self.deinitActiveSignalCustomBoolAttrDesc(ctx, roc_host, &removed);
                    continue;
                }
                const record_id = self.requireActiveSignalRecordId(desc.signal.record);
                self.updateActiveBoolSignalRouteIndex(record_id, .custom_bool_attr, read_index, write_index);
                self.active_stream.signal_custom_bool_attrs.items[write_index] = desc;
                write_index += 1;
            }
            self.active_stream.signal_custom_bool_attrs.items.len = write_index;
        }

        fn removeActiveStaticBoolAttrDescriptorAt(self: *Self, index: usize) void {
            if (index >= self.active_stream.static_bool_attrs.items.len) @panic("static bool attr removal index exceeded descriptor table");
            const last_index = self.active_stream.static_bool_attrs.items.len - 1;
            const removed = self.active_stream.static_bool_attrs.items[index];
            self.active_stream.clearStaticBoolAttrIndex(removed.elem_id, removed.field, index);

            if (index != last_index) {
                const moved = self.active_stream.static_bool_attrs.items[last_index];
                self.active_stream.static_bool_attrs.items[index] = moved;
                self.active_stream.updateStaticBoolAttrIndex(moved.elem_id, moved.field, index);
            }
            self.active_stream.static_bool_attrs.items.len = last_index;
        }

        fn removeActiveSignalBoolAttrDescriptorAt(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, index: usize) void {
            if (index >= self.active_stream.signal_bool_attrs.items.len) @panic("signal bool attr removal index exceeded descriptor table");
            const last_index = self.active_stream.signal_bool_attrs.items.len - 1;
            var removed = self.active_stream.signal_bool_attrs.items[index];
            const removed_record_id = self.requireActiveSignalRecordId(removed.signal.record);
            self.removeActiveBoolSignalRoute(removed_record_id, .bool_attr, index);
            self.active_stream.clearSignalBoolAttrIndex(removed.elem_id, removed.field, index);
            self.active_stream.forgetSignalRecordTree(removed.signal.record);
            self.releaseActiveSignalRecord(ctx, removed.signal.record);
            self.deinitActiveSignalBoolAttrDesc(ctx, roc_host, &removed);

            if (index != last_index) {
                const moved = self.active_stream.signal_bool_attrs.items[last_index];
                const moved_record_id = self.requireActiveSignalRecordId(moved.signal.record);
                self.active_stream.signal_bool_attrs.items[index] = moved;
                self.updateActiveBoolSignalRouteIndex(moved_record_id, .bool_attr, last_index, index);
                self.active_stream.updateSignalBoolAttrIndex(moved.elem_id, moved.field, index);
            }
            self.active_stream.signal_bool_attrs.items.len = last_index;
        }

        fn removeActiveOnChangeDescriptorsInTarget(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, target_scopes: []const bool) void {
            var write_index: usize = 0;
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_remove_target, self.active_stream.on_changes.items.len);
            for (self.active_stream.on_changes.items, 0..) |desc, read_index| {
                if (structural_splice.scopeIsInTargetSet(target_scopes, desc.scope_id)) {
                    var removed = desc;
                    const record_id = self.requireActiveSignalRecordId(removed.signal.record);
                    self.removeActiveChangeSignalRoute(record_id, read_index);
                    self.active_stream.forgetSignalRecordTree(removed.signal.record);
                    self.releaseActiveSignalRecord(ctx, removed.signal.record);
                    self.deinitActiveOnChangeDesc(ctx, roc_host, &removed);
                    continue;
                }
                const record_id = self.requireActiveSignalRecordId(desc.signal.record);
                self.updateActiveChangeSignalRouteIndex(record_id, read_index, write_index);
                self.active_stream.on_changes.items[write_index] = desc;
                write_index += 1;
            }
            self.active_stream.on_changes.items.len = write_index;
        }

        fn removeActiveMountDescriptorsInTarget(self: *Self, roc_host: *abi.RocHost, target_scopes: []const bool) void {
            var write_index: usize = 0;
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_remove_target, self.active_stream.mounts.items.len);
            for (self.active_stream.mounts.items) |desc| {
                if (structural_splice.scopeIsInTargetSet(target_scopes, desc.scope_id)) {
                    var removed = desc;
                    self.deinitActiveMountDesc(roc_host, &removed);
                    continue;
                }
                self.active_stream.mounts.items[write_index] = desc;
                write_index += 1;
            }
            self.active_stream.mounts.items.len = write_index;
        }

        fn removeActiveCleanupDescriptorsInTarget(self: *Self, ctx: Ctx.Handle, target_scopes: []const bool) void {
            const allocator = Ctx.allocator(ctx);
            var write_index: usize = 0;
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_remove_target, self.active_stream.cleanups.items.len);
            for (self.active_stream.cleanups.items) |desc| {
                if (structural_splice.scopeIsInTargetSet(target_scopes, desc.scope_id)) {
                    allocator.free(desc.name);
                    continue;
                }
                self.active_stream.cleanups.items[write_index] = desc;
                write_index += 1;
            }
            self.active_stream.cleanups.items.len = write_index;
        }

        fn clearActiveEventDescriptorIndex(self: *Self, desc: HostNodeEventDesc, index: usize) void {
            switch (desc.binding) {
                .fixed => |kind| self.active_stream.clearEventIndex(desc.elem_id, kind, index),
                .named => self.active_stream.clearNamedEventIndex(desc.elem_id, index),
            }
        }

        fn updateActiveEventDescriptorIndex(self: *Self, desc: HostNodeEventDesc, old_index: usize, new_index: usize) void {
            switch (desc.binding) {
                .fixed => |kind| self.active_stream.updateEventIndex(desc.elem_id, kind, new_index),
                .named => self.active_stream.updateNamedEventIndex(desc.elem_id, old_index, new_index),
            }
        }

        fn removeActiveEventDescriptorAt(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, index: usize, moved_event_elem_ids: *std.ArrayListUnmanaged(u64)) void {
            const allocator = Ctx.allocator(ctx);
            const event_count = self.active_stream.events.items.len;
            if (self.active_events.items.len != event_count) {
                if (event_count != 0) @panic("active event descriptor table is out of sync with active events");
            }
            if (index >= event_count) @panic("event removal index exceeded descriptor table");

            const last_index = event_count - 1;
            const removed = self.active_stream.events.items[index];
            if (removed.owns_payload_reducer) {
                @panic("active event descriptor retained ownership outside the active event table");
            }
            self.clearActiveEventDescriptorIndex(removed, index);
            if (removed.named()) |binding| allocator.free(binding.name);
            if (self.active_events.items.len != 0) {
                self.deinitActiveEventDesc(roc_host, self.active_events.items[index]);
            }

            if (index != last_index) {
                const moved = self.active_stream.events.items[last_index];
                self.active_stream.events.items[index] = moved;
                self.updateActiveEventDescriptorIndex(moved, last_index, index);
                appendUniqueU64(allocator, moved_event_elem_ids, moved.elem_id);
                if (self.active_events.items.len != 0) {
                    self.active_events.items[index] = self.active_events.items[last_index];
                }
            }
            self.active_stream.events.items.len = last_index;
            if (self.active_events.items.len != 0) self.active_events.items.len = last_index;
        }

        fn collectElemOwnedRemovalIndexes(self: *Self, ctx: Ctx.Handle, removed_elem_ids: []const u64) void {
            const allocator = Ctx.allocator(ctx);
            var scratch = &self.scratch.elem_owned_removal;
            scratch.assertEmpty();

            for (removed_elem_ids) |elem_id| {
                const descriptor_index = self.active_stream.elemDescriptorIndex(elem_id) orelse @panic("removed elem id had no descriptor index");
                const has_render_descriptor = descriptor_index.element != .none or descriptor_index.text_node != .none or descriptor_index.signal_text_node != .none;
                if (!has_render_descriptor) @panic("removed rendered elem id had no render-owned descriptor");

                scratch.appendDescriptorIndexes(allocator, descriptor_index);
                self.appendNamedEventRemovalIndexes(ctx, &scratch.event_indexes, elem_id);
            }

            scratch.sortDescending();
        }

        fn removeActiveElemOwnedDescriptorsForRemovedElems(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, removed_elem_ids: []const u64, moved_event_elem_ids: *std.ArrayListUnmanaged(u64)) void {
            self.collectElemOwnedRemovalIndexes(ctx, removed_elem_ids);
            defer self.clearElemOwnedRemovalScratch();

            const scratch = &self.scratch.elem_owned_removal;
            for (scratch.static_text_attr_indexes.items) |index| {
                self.removeActiveStaticTextAttrDescriptorAt(ctx, index);
            }
            for (scratch.signal_text_attr_indexes.items) |index| {
                self.removeActiveSignalTextAttrDescriptorAt(ctx, roc_host, index);
            }
            for (scratch.static_bool_attr_indexes.items) |index| {
                self.removeActiveStaticBoolAttrDescriptorAt(index);
            }
            for (scratch.signal_bool_attr_indexes.items) |index| {
                self.removeActiveSignalBoolAttrDescriptorAt(ctx, roc_host, index);
            }
            for (scratch.event_indexes.items) |index| {
                self.removeActiveEventDescriptorAt(ctx, roc_host, index, moved_event_elem_ids);
            }
            for (scratch.element_indexes.items) |index| {
                self.removeActiveElementDescriptorAt(ctx, index);
            }
            for (scratch.text_node_indexes.items) |index| {
                self.removeActiveTextNodeDescriptorAt(ctx, index);
            }
            for (scratch.signal_text_node_indexes.items) |index| {
                self.removeActiveSignalTextNodeDescriptorAt(ctx, roc_host, index);
            }
        }

        fn removeActiveScopeSiteDescriptorsInTarget(self: *Self, ctx: Ctx.Handle, target_scopes: []const bool) void {
            const allocator = Ctx.allocator(ctx);
            var write_index: usize = 0;
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_remove_target, self.active_stream.scope_sites.items.len);
            for (self.active_stream.scope_sites.items, 0..) |desc, read_index| {
                if (structural_splice.scopeIsInTargetSet(target_scopes, desc.scope_id)) {
                    self.active_stream.clearScopeSiteIndex(desc.node_id, desc.kind, read_index);
                    allocator.free(desc.binder_bindings);
                    continue;
                }
                self.active_stream.updateScopeSiteIndex(desc.node_id, desc.kind, write_index);
                self.active_stream.scope_sites.items[write_index] = desc;
                write_index += 1;
            }
            self.active_stream.scope_sites.items.len = write_index;
        }

        fn removeActiveStateDescriptorsInTarget(self: *Self, roc_host: *abi.RocHost, target_scopes: []const bool) void {
            var write_index: usize = 0;
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_remove_target, self.active_stream.states.items.len);
            for (self.active_stream.states.items, 0..) |desc, read_index| {
                if (self.streamNodeIdInReplacementTargetSet(&self.active_stream, desc.node_id, .state, target_scopes)) {
                    self.active_stream.clearStateIndex(desc.node_id, read_index);
                    self.pending_roc_metrics.bump(.closure_releases, 1);
                    abi.decrefErasedCallable(desc.initial, roc_host);
                    releaseHostValueCapability(desc.cap, roc_host, &self.pending_roc_metrics);
                    continue;
                }
                self.active_stream.updateStateIndex(desc.node_id, write_index);
                self.active_stream.states.items[write_index] = desc;
                write_index += 1;
            }
            self.active_stream.states.items.len = write_index;
        }

        fn removeActiveWhenDescriptorsInTarget(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, target_scopes: []const bool) void {
            var write_index: usize = 0;
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_remove_target, self.active_stream.whens.items.len);
            for (self.active_stream.whens.items, 0..) |desc, read_index| {
                if (self.streamNodeIdInReplacementTargetSet(&self.active_stream, desc.node_id, .when, target_scopes)) {
                    var removed = desc;
                    const record_id = self.requireActiveSignalRecordId(removed.condition.record);
                    self.removeActiveStructuralSignalRoute(record_id, .when, read_index);
                    self.active_stream.clearWhenIndex(removed.node_id, read_index);
                    self.active_stream.forgetSignalRecordTree(removed.condition.record);
                    self.releaseActiveSignalRecord(ctx, removed.condition.record);
                    removed.cached_value.deinit(ctx, roc_host, &self.pending_roc_metrics);
                    removed.condition.deinit(Ctx.allocator(ctx), ctx, roc_host, &self.pending_roc_metrics);
                    releaseHostBoolRead(removed.read, roc_host, &self.pending_roc_metrics);
                    removed.when_false.decref(roc_host);
                    removed.when_true.decref(roc_host);
                    continue;
                }
                const record_id = self.requireActiveSignalRecordId(desc.condition.record);
                self.updateActiveStructuralSignalRouteIndex(record_id, .when, read_index, write_index);
                self.active_stream.updateWhenIndex(desc.node_id, write_index);
                self.active_stream.whens.items[write_index] = desc;
                write_index += 1;
            }
            self.active_stream.whens.items.len = write_index;
        }

        fn removeActiveEachDescriptorsInTarget(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, target_scopes: []const bool) void {
            var write_index: usize = 0;
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_remove_target, self.active_stream.eaches.items.len);
            for (self.active_stream.eaches.items, 0..) |desc, read_index| {
                if (self.streamNodeIdInReplacementTargetSet(&self.active_stream, desc.node_id, .each, target_scopes)) {
                    var removed = desc;
                    const record_id = self.requireActiveSignalRecordId(removed.items.record);
                    self.removeActiveStructuralSignalRoute(record_id, .each, read_index);
                    self.active_stream.clearEachIndex(removed.node_id, read_index);
                    self.active_stream.forgetSignalRecordTree(removed.items.record);
                    self.releaseActiveSignalRecord(ctx, removed.items.record);
                    removed.cached_value.deinit(ctx, roc_host, &self.pending_roc_metrics);
                    removed.items.deinit(Ctx.allocator(ctx), ctx, roc_host, &self.pending_roc_metrics);
                    releaseHostEachOps(removed.ops, roc_host, &self.pending_roc_metrics);
                    continue;
                }
                const record_id = self.requireActiveSignalRecordId(desc.items.record);
                self.updateActiveStructuralSignalRouteIndex(record_id, .each, read_index, write_index);
                self.active_stream.updateEachIndex(desc.node_id, write_index);
                self.active_stream.eaches.items[write_index] = desc;
                write_index += 1;
            }
            self.active_stream.eaches.items.len = write_index;
        }

        fn removeActiveNonRenderDescriptorsInTarget(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, target_scopes: []const bool, removed_elem_ids: []const u64, moved_event_elem_ids: *std.ArrayListUnmanaged(u64)) void {
            self.removeActiveElemOwnedDescriptorsForRemovedElems(ctx, roc_host, removed_elem_ids, moved_event_elem_ids);
            self.removeActiveStaticCustomTextAttrDescriptorsForRemovedElems(ctx, removed_elem_ids);
            self.removeActiveSignalCustomTextAttrDescriptorsForRemovedElems(ctx, roc_host, removed_elem_ids);
            self.removeActiveSignalOptionalCustomTextAttrDescriptorsForRemovedElems(ctx, roc_host, removed_elem_ids);
            self.removeActiveStaticCustomBoolAttrDescriptorsForRemovedElems(ctx, removed_elem_ids);
            self.removeActiveSignalCustomBoolAttrDescriptorsForRemovedElems(ctx, roc_host, removed_elem_ids);
            self.removeActiveOnChangeDescriptorsInTarget(ctx, roc_host, target_scopes);
            self.removeActiveMountDescriptorsInTarget(roc_host, target_scopes);
            self.removeActiveCleanupDescriptorsInTarget(ctx, target_scopes);
            self.removeActiveStateDescriptorsInTarget(roc_host, target_scopes);
            self.removeActiveWhenDescriptorsInTarget(ctx, roc_host, target_scopes);
            self.removeActiveEachDescriptorsInTarget(ctx, roc_host, target_scopes);
            self.removeActiveScopeSiteDescriptorsInTarget(ctx, target_scopes);
        }

        fn adjustActiveScopeSiteRenderInsertIndices(self: *Self, replace_index: usize, removed_render_count: usize, replacement_render_count: usize) void {
            structural_splice.adjustScopeSiteRenderInsertIndices(self.active_stream.scope_sites.items, replace_index, removed_render_count, replacement_render_count);
        }

        fn appendReplacementEventsMoved(self: *Self, ctx: Ctx.Handle, replacement: *HostNodeDescriptorStream) void {
            const allocator = Ctx.allocator(ctx);
            const existing_event_count = self.active_stream.events.items.len;
            if (self.active_events.items.len != existing_event_count) {
                if (existing_event_count != 0) @panic("active event descriptor table is out of sync before replacement event splice");
            }

            const event_base = self.active_stream.events.items.len;
            for (replacement.events.items, 0..) |*desc, offset| {
                if (!desc.owns_payload_reducer) {
                    @panic("replacement event descriptor did not own its retained payload");
                }
                switch (desc.binding) {
                    .fixed => |kind| self.active_stream.recordEventIndex(allocator, desc.elem_id, kind, event_base + offset),
                    .named => self.active_stream.recordNamedEventIndex(allocator, desc.elem_id, event_base + offset),
                }
                self.active_events.insert(allocator, event_base + offset, .{
                    .target_node_id = desc.target_node_id,
                    .read_node_id = desc.read_node_id,
                    .payload_descriptor = desc.payload_descriptor,
                    .payload_reducer = desc.payload_reducer,
                }) catch @panic("out of memory");
                desc.owns_payload_reducer = false;
            }

            self.active_stream.events.appendSlice(allocator, replacement.events.items) catch @panic("out of memory");
            replacement.events.items.len = 0;
        }

        fn appendReplacementNonRenderDescriptorsMoved(self: *Self, ctx: Ctx.Handle, replacement: *HostNodeDescriptorStream, render_insert_offset: usize) void {
            const allocator = Ctx.allocator(ctx);

            const element_base = self.active_stream.elements.items.len;
            for (replacement.elements.items, 0..) |desc, offset| {
                self.active_stream.recordElementIndex(allocator, desc.elem_id, element_base + offset);
            }
            self.active_stream.elements.appendSlice(allocator, replacement.elements.items) catch @panic("out of memory");
            replacement.elements.items.len = 0;

            const text_node_base = self.active_stream.text_nodes.items.len;
            for (replacement.text_nodes.items, 0..) |desc, offset| {
                self.active_stream.recordTextNodeIndex(allocator, desc.elem_id, text_node_base + offset);
            }
            self.active_stream.text_nodes.appendSlice(allocator, replacement.text_nodes.items) catch @panic("out of memory");
            replacement.text_nodes.items.len = 0;

            const signal_text_node_base = self.active_stream.signal_text_nodes.items.len;
            for (replacement.signal_text_nodes.items, 0..) |desc, offset| {
                self.active_stream.recordSignalTextNodeIndex(allocator, desc.elem_id, signal_text_node_base + offset);
            }
            for (replacement.signal_text_nodes.items, 0..) |desc, offset| {
                self.active_stream.rememberSignalRecordTree(allocator, desc.signal.record);
                self.retainActiveSignalRecord(ctx, desc.signal.record);
                const record_id = self.requireActiveSignalRecordId(desc.signal.record);
                self.appendActiveTextSignalRoute(ctx, record_id, .{
                    .kind = .text_node,
                    .index = signal_text_node_base + offset,
                });
            }
            self.active_stream.signal_text_nodes.appendSlice(allocator, replacement.signal_text_nodes.items) catch @panic("out of memory");
            replacement.signal_text_nodes.items.len = 0;

            const static_text_attr_base = self.active_stream.static_text_attrs.items.len;
            for (replacement.static_text_attrs.items, 0..) |desc, offset| {
                self.active_stream.recordStaticTextAttrIndex(allocator, desc.elem_id, desc.field, static_text_attr_base + offset);
            }
            self.active_stream.static_text_attrs.appendSlice(allocator, replacement.static_text_attrs.items) catch @panic("out of memory");
            replacement.static_text_attrs.items.len = 0;

            const signal_text_attr_base = self.active_stream.signal_text_attrs.items.len;
            for (replacement.signal_text_attrs.items, 0..) |desc, offset| {
                self.active_stream.recordSignalTextAttrIndex(allocator, desc.elem_id, desc.field, signal_text_attr_base + offset);
            }
            for (replacement.signal_text_attrs.items, 0..) |desc, offset| {
                self.active_stream.rememberSignalRecordTree(allocator, desc.signal.record);
                self.retainActiveSignalRecord(ctx, desc.signal.record);
                const record_id = self.requireActiveSignalRecordId(desc.signal.record);
                self.appendActiveTextSignalRoute(ctx, record_id, .{
                    .kind = .text_attr,
                    .index = signal_text_attr_base + offset,
                });
            }
            self.active_stream.signal_text_attrs.appendSlice(allocator, replacement.signal_text_attrs.items) catch @panic("out of memory");
            replacement.signal_text_attrs.items.len = 0;

            self.active_stream.static_custom_text_attrs.appendSlice(allocator, replacement.static_custom_text_attrs.items) catch @panic("out of memory");
            replacement.static_custom_text_attrs.items.len = 0;

            const signal_custom_text_attr_base = self.active_stream.signal_custom_text_attrs.items.len;
            for (replacement.signal_custom_text_attrs.items, 0..) |desc, offset| {
                self.active_stream.rememberSignalRecordTree(allocator, desc.signal.record);
                self.retainActiveSignalRecord(ctx, desc.signal.record);
                const record_id = self.requireActiveSignalRecordId(desc.signal.record);
                self.appendActiveTextSignalRoute(ctx, record_id, .{
                    .kind = .custom_text_attr,
                    .index = signal_custom_text_attr_base + offset,
                });
            }
            self.active_stream.signal_custom_text_attrs.appendSlice(allocator, replacement.signal_custom_text_attrs.items) catch @panic("out of memory");
            replacement.signal_custom_text_attrs.items.len = 0;

            const signal_optional_custom_text_attr_base = self.active_stream.signal_optional_custom_text_attrs.items.len;
            for (replacement.signal_optional_custom_text_attrs.items, 0..) |desc, offset| {
                self.active_stream.rememberSignalRecordTree(allocator, desc.signal.record);
                self.retainActiveSignalRecord(ctx, desc.signal.record);
                const record_id = self.requireActiveSignalRecordId(desc.signal.record);
                self.appendActiveTextSignalRoute(ctx, record_id, .{
                    .kind = .custom_text_optional_attr,
                    .index = signal_optional_custom_text_attr_base + offset,
                });
            }
            self.active_stream.signal_optional_custom_text_attrs.appendSlice(allocator, replacement.signal_optional_custom_text_attrs.items) catch @panic("out of memory");
            replacement.signal_optional_custom_text_attrs.items.len = 0;

            self.active_stream.static_custom_bool_attrs.appendSlice(allocator, replacement.static_custom_bool_attrs.items) catch @panic("out of memory");
            replacement.static_custom_bool_attrs.items.len = 0;

            const signal_custom_bool_attr_base = self.active_stream.signal_custom_bool_attrs.items.len;
            for (replacement.signal_custom_bool_attrs.items, 0..) |desc, offset| {
                self.active_stream.rememberSignalRecordTree(allocator, desc.signal.record);
                self.retainActiveSignalRecord(ctx, desc.signal.record);
                const record_id = self.requireActiveSignalRecordId(desc.signal.record);
                self.appendActiveBoolSignalRoute(ctx, record_id, .{
                    .kind = .custom_bool_attr,
                    .index = signal_custom_bool_attr_base + offset,
                });
            }
            self.active_stream.signal_custom_bool_attrs.appendSlice(allocator, replacement.signal_custom_bool_attrs.items) catch @panic("out of memory");
            replacement.signal_custom_bool_attrs.items.len = 0;

            const static_bool_attr_base = self.active_stream.static_bool_attrs.items.len;
            for (replacement.static_bool_attrs.items, 0..) |desc, offset| {
                self.active_stream.recordStaticBoolAttrIndex(allocator, desc.elem_id, desc.field, static_bool_attr_base + offset);
            }
            self.active_stream.static_bool_attrs.appendSlice(allocator, replacement.static_bool_attrs.items) catch @panic("out of memory");
            replacement.static_bool_attrs.items.len = 0;

            const signal_bool_attr_base = self.active_stream.signal_bool_attrs.items.len;
            for (replacement.signal_bool_attrs.items, 0..) |desc, offset| {
                self.active_stream.recordSignalBoolAttrIndex(allocator, desc.elem_id, desc.field, signal_bool_attr_base + offset);
            }
            for (replacement.signal_bool_attrs.items, 0..) |desc, offset| {
                self.active_stream.rememberSignalRecordTree(allocator, desc.signal.record);
                self.retainActiveSignalRecord(ctx, desc.signal.record);
                const record_id = self.requireActiveSignalRecordId(desc.signal.record);
                self.appendActiveBoolSignalRoute(ctx, record_id, .{
                    .kind = .bool_attr,
                    .index = signal_bool_attr_base + offset,
                });
            }
            self.active_stream.signal_bool_attrs.appendSlice(allocator, replacement.signal_bool_attrs.items) catch @panic("out of memory");
            replacement.signal_bool_attrs.items.len = 0;

            const on_change_base = self.active_stream.on_changes.items.len;
            for (replacement.on_changes.items, 0..) |desc, offset| {
                self.active_stream.rememberSignalRecordTree(allocator, desc.signal.record);
                self.retainActiveSignalRecord(ctx, desc.signal.record);
                const record_id = self.requireActiveSignalRecordId(desc.signal.record);
                self.appendActiveChangeSignalRoute(ctx, record_id, .{
                    .index = on_change_base + offset,
                });
            }
            self.active_stream.on_changes.appendSlice(allocator, replacement.on_changes.items) catch @panic("out of memory");
            replacement.on_changes.items.len = 0;

            self.active_stream.mounts.appendSlice(allocator, replacement.mounts.items) catch @panic("out of memory");
            replacement.mounts.items.len = 0;

            self.active_stream.cleanups.appendSlice(allocator, replacement.cleanups.items) catch @panic("out of memory");
            replacement.cleanups.items.len = 0;

            self.appendReplacementEventsMoved(ctx, replacement);

            const scope_site_base = self.active_stream.scope_sites.items.len;
            for (replacement.scope_sites.items) |*desc| {
                desc.render_insert_index += render_insert_offset;
            }
            for (replacement.scope_sites.items, 0..) |desc, offset| {
                self.active_stream.recordScopeSiteIndex(allocator, desc.node_id, desc.kind, scope_site_base + offset);
            }
            self.active_stream.scope_sites.appendSlice(allocator, replacement.scope_sites.items) catch @panic("out of memory");
            replacement.scope_sites.items.len = 0;

            const state_base = self.active_stream.states.items.len;
            for (replacement.states.items, 0..) |desc, offset| {
                self.active_stream.recordStateIndex(allocator, desc.node_id, state_base + offset);
            }
            self.active_stream.states.appendSlice(allocator, replacement.states.items) catch @panic("out of memory");
            replacement.states.items.len = 0;

            const when_base = self.active_stream.whens.items.len;
            for (replacement.whens.items, 0..) |desc, offset| {
                self.active_stream.recordWhenIndex(allocator, desc.node_id, when_base + offset);
                self.active_stream.rememberSignalRecordTree(allocator, desc.condition.record);
                self.retainActiveSignalRecord(ctx, desc.condition.record);
                const record_id = self.requireActiveSignalRecordId(desc.condition.record);
                self.appendActiveStructuralSignalRoute(ctx, record_id, .{
                    .kind = .when,
                    .index = when_base + offset,
                });
            }
            self.active_stream.whens.appendSlice(allocator, replacement.whens.items) catch @panic("out of memory");
            replacement.whens.items.len = 0;

            const each_base = self.active_stream.eaches.items.len;
            for (replacement.eaches.items, 0..) |desc, offset| {
                self.active_stream.recordEachIndex(allocator, desc.node_id, each_base + offset);
                self.active_stream.rememberSignalRecordTree(allocator, desc.items.record);
                self.retainActiveSignalRecord(ctx, desc.items.record);
                const record_id = self.requireActiveSignalRecordId(desc.items.record);
                self.appendActiveStructuralSignalRoute(ctx, record_id, .{
                    .kind = .each,
                    .index = each_base + offset,
                });
            }
            self.active_stream.eaches.appendSlice(allocator, replacement.eaches.items) catch @panic("out of memory");
            replacement.eaches.items.len = 0;
        }

        fn validateActiveRenderDescriptorIntegrity(self: *Self) void {
            for (self.active_stream.render_nodes.items) |node| {
                const found = switch (node.kind) {
                    .element => findElementDesc(&self.active_stream, node.elem_id) != null,
                    .text => findTextNodeDesc(&self.active_stream, node.elem_id) != null,
                    .signal_text => findSignalTextNodeDesc(&self.active_stream, node.elem_id) != null,
                };
                if (!found) {
                    var message: [128]u8 = undefined;
                    const rendered = std.fmt.bufPrint(
                        &message,
                        "active render node {d} with kind {s} has no matching descriptor",
                        .{ node.elem_id, @tagName(node.kind) },
                    ) catch "active render node has no matching descriptor";
                    @panic(rendered);
                }
                const parent_elem_id = renderNodeParentElemId(&self.active_stream, node);
                if (parent_elem_id != 0 and
                    findElementDesc(&self.active_stream, parent_elem_id) == null and
                    findTextNodeDesc(&self.active_stream, parent_elem_id) == null and
                    findSignalTextNodeDesc(&self.active_stream, parent_elem_id) == null)
                {
                    @panic("active render node referenced a missing parent descriptor");
                }
            }
        }

        /// Performs splice active stream replacing target inside the shared engine while preserving transaction and changed-set invariants.
        pub fn spliceActiveStreamReplacingTarget(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, target: HostStructuralReplacementTarget, render_insert_index: usize, replacement: *HostNodeDescriptorStream) HostStructuralSplice {
            return self.spliceActiveStreamReplacingTargetWithOptions(ctx, roc_host, target, render_insert_index, replacement, null, true);
        }

        /// Performs splice active stream replacing target with options inside the shared engine while preserving transaction and changed-set invariants.
        pub fn spliceActiveStreamReplacingTargetWithOptions(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, target: HostStructuralReplacementTarget, render_insert_index: usize, replacement: *HostNodeDescriptorStream, child_insert_hint: ?HostRenderChildInsertHint, refresh_suffix_indexes: bool) HostStructuralSplice {
            return self.spliceActiveStreamReplacingTargetWithScopeSet(ctx, roc_host, target, render_insert_index, replacement, child_insert_hint, refresh_suffix_indexes, null);
        }

        // Snapshot the replacement-target scope set while the replaced scope
        // subtree is still live. A when-arm swap disposes the outgoing branch
        // scopes before its splice runs, and a removal scan classifying old
        // render nodes against the post-disposal scope tree under-collects:
        // the outgoing arm's descriptors survive while their (already reused)
        // elem ids re-register, tripping the duplicate-descriptor-index panic.
        /// Performs snapshot replacement target scope set inside the shared engine while preserving transaction and changed-set invariants.
        pub fn snapshotReplacementTargetScopeSet(self: *Self, ctx: Ctx.Handle, target: HostStructuralReplacementTarget) []const bool {
            const built = self.buildReplacementTargetScopeSet(ctx, target);
            const copy = Ctx.allocator(ctx).dupe(bool, built) catch @panic("out of memory");
            self.scratch.replacement_target_scopes.clearRetainingCapacity();
            return copy;
        }

        /// Performs splice active stream replacing scope with scope snapshot inside the shared engine while preserving transaction and changed-set invariants.
        pub fn spliceActiveStreamReplacingScopeWithScopeSnapshot(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, replaced_scope_id: u64, render_insert_index: usize, replacement: *HostNodeDescriptorStream, target_scopes_snapshot: []const bool) HostStructuralSplice {
            return self.spliceActiveStreamReplacingTargetWithScopeSet(ctx, roc_host, .{ .scope = replaced_scope_id }, render_insert_index, replacement, null, true, target_scopes_snapshot);
        }

        fn renderStartForReplacementTargetSet(self: *Self, render_insert_hint: usize, target_scopes: []const bool) usize {
            var render_index = render_insert_hint;
            while (render_index < self.active_stream.render_nodes.items.len) : (render_index += 1) {
                const node = self.active_stream.render_nodes.items[render_index];
                if (structural_splice.scopeIsInTargetSet(target_scopes, renderNodeScopeId(&self.active_stream, node))) return render_index;
            }
            return render_insert_hint;
        }

        fn replacementTargetHasNonContiguousDomDescendants(self: *Self, ctx: Ctx.Handle, render_insert_hint: usize, target_scopes: []const bool) bool {
            const allocator = Ctx.allocator(ctx);
            const render_start = self.renderStartForReplacementTargetSet(render_insert_hint, target_scopes);
            const removal_scan = structural_splice.collectRenderRemovalScan(HostNodeDescriptorStream, allocator, &self.active_stream, render_start, target_scopes);
            defer removal_scan.deinit(allocator);
            if (removal_scan.removed_render_count == 0) return false;

            var extra_descendants: std.ArrayListUnmanaged(u64) = .empty;
            defer extra_descendants.deinit(allocator);

            const contiguous_end = render_start + removal_scan.removed_render_count;
            for (self.active_stream.render_nodes.items[contiguous_end..]) |node| {
                const parent_elem_id = renderNodeParentElemId(&self.active_stream, node);
                if (u64SliceContains(removal_scan.removed_elem_ids, parent_elem_id) or u64SliceContains(extra_descendants.items, parent_elem_id)) {
                    extra_descendants.append(allocator, node.elem_id) catch @panic("out of memory");
                    return true;
                }
            }
            return false;
        }

        fn spliceActiveStreamReplacingTargetWithScopeSet(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, target: HostStructuralReplacementTarget, render_insert_index: usize, replacement: *HostNodeDescriptorStream, child_insert_hint: ?HostRenderChildInsertHint, refresh_suffix_indexes: bool, prebuilt_target_scopes: ?[]const bool) HostStructuralSplice {
            const allocator = Ctx.allocator(ctx);
            const target_scopes = prebuilt_target_scopes orelse self.buildReplacementTargetScopeSet(ctx, target);
            defer if (prebuilt_target_scopes == null) self.scratch.replacement_target_scopes.clearRetainingCapacity();

            const render_start = self.renderStartForReplacementTargetSet(render_insert_index, target_scopes);
            const removal_scan = structural_splice.collectRenderRemovalScan(HostNodeDescriptorStream, allocator, &self.active_stream, render_start, target_scopes);
            errdefer removal_scan.deinit(allocator);
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_splice, removal_scan.target_scan_count);

            const removed_render_nodes = self.active_stream.render_nodes.items[render_start..][0..removal_scan.removed_render_count];
            const replacement_render_count = replacement.render_nodes.items.len;
            const on_change_count = replacement.on_changes.items.len;
            const mount_count = replacement.mounts.items.len;
            const replacement_elem_ids = structural_splice.renderElemIds(allocator, replacement.render_nodes.items);
            errdefer allocator.free(replacement_elem_ids);
            var moved_event_elem_ids: std.ArrayListUnmanaged(u64) = .empty;
            errdefer moved_event_elem_ids.deinit(allocator);

            self.active_stream.replaceRenderRangeWithStreamOptions(allocator, render_start, removed_render_nodes, replacement, child_insert_hint, refresh_suffix_indexes, &self.pending_roc_metrics);
            self.removeActiveNonRenderDescriptorsInTarget(ctx, roc_host, target_scopes, removal_scan.removed_elem_ids, &moved_event_elem_ids);
            self.adjustActiveScopeSiteRenderInsertIndices(render_start, removal_scan.removed_render_count, replacement_render_count);
            const on_change_start = self.active_stream.on_changes.items.len;
            const replacement_on_change_indices = structural_splice.indexRange(allocator, on_change_start, on_change_count);
            errdefer allocator.free(replacement_on_change_indices);
            const mount_start = self.active_stream.mounts.items.len;
            const replacement_mount_indices = structural_splice.indexRange(allocator, mount_start, mount_count);
            errdefer allocator.free(replacement_mount_indices);
            self.appendReplacementNonRenderDescriptorsMoved(ctx, replacement, render_start);
            self.validateActiveRenderDescriptorIntegrity();

            return .{
                .removed_elem_ids = removal_scan.removed_elem_ids,
                .touched_parent_ids = removal_scan.touched_parent_ids,
                .replacement_elem_ids = replacement_elem_ids,
                .moved_event_elem_ids = moved_event_elem_ids.toOwnedSlice(allocator) catch @panic("out of memory"),
                .replacement_on_change_indices = replacement_on_change_indices,
                .replacement_mount_indices = replacement_mount_indices,
            };
        }

        /// Performs splice active stream replacing scope inside the shared engine while preserving transaction and changed-set invariants.
        pub fn spliceActiveStreamReplacingScope(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, replaced_scope_id: u64, render_insert_index: usize, replacement: *HostNodeDescriptorStream) HostStructuralSplice {
            return self.spliceActiveStreamReplacingTarget(ctx, roc_host, .{ .scope = replaced_scope_id }, render_insert_index, replacement);
        }

        /// Performs splice active stream replacing scope with options inside the shared engine while preserving transaction and changed-set invariants.
        pub fn spliceActiveStreamReplacingScopeWithOptions(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, replaced_scope_id: u64, render_insert_index: usize, replacement: *HostNodeDescriptorStream, child_insert_hint: ?HostRenderChildInsertHint, refresh_suffix_indexes: bool) HostStructuralSplice {
            return self.spliceActiveStreamReplacingTargetWithOptions(ctx, roc_host, .{ .scope = replaced_scope_id }, render_insert_index, replacement, child_insert_hint, refresh_suffix_indexes);
        }

        /// Replaces signal expr cache and clone while releasing displaced ownership exactly once.
        pub fn replaceSignalExprCacheAndClone(self: *Self, ctx: Ctx.Handle, cache_slot: *HostSignalCacheSlot, roc_host: *abi.RocHost, value: HostValue, cap: HostValueCapability) HostValue {
            cache_slot.replace(ctx, roc_host, &self.pending_roc_metrics, value, cap);
            return self.cloneCachedSignalValue(ctx, cache_slot);
        }

        /// Performs eval effect source initial inside the shared engine while preserving transaction and changed-set invariants.
        pub fn evalEffectSourceInitial(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, cache_slot: *HostSignalCacheSlot, initial: abi.RocErasedCallable, cap: HostValueCapability) HostValue {
            switch (cache_slot.*) {
                .present => return self.cloneCachedSignalValue(ctx, cache_slot),
                .absent => {
                    const value = erased_calls.callValueInitThunk(roc_host, initial);
                    return self.replaceSignalExprCacheAndClone(ctx, cache_slot, roc_host, value, cap);
                },
            }
        }

        /// Performs eval location source initial inside the shared engine while preserving transaction and changed-set invariants.
        pub fn evalLocationSourceInitial(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, payload: *HostSignalLocationSourceRecord) HostValue {
            switch (payload.cached_value) {
                .present => return self.cloneCachedSignalValue(ctx, &payload.cached_value),
                .absent => {
                    const raw_payload = Ctx.initialLocationPayload(ctx, roc_host, payload.payload_cap);
                    const value = callHostValueToHostValueWithCapability(ctx, roc_host, payload.payload_cap, payload.from_payload, raw_payload);
                    return self.replaceSignalExprCacheAndClone(ctx, &payload.cached_value, roc_host, value, payload.cap);
                },
            }
        }

        /// Performs eval visibility source initial inside the shared engine while preserving transaction and changed-set invariants.
        pub fn evalVisibilitySourceInitial(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, payload: *HostSignalVisibilitySourceRecord) HostValue {
            switch (payload.cached_value) {
                .present => return self.cloneCachedSignalValue(ctx, &payload.cached_value),
                .absent => {
                    const raw_payload = Ctx.initialVisibilityPayload(ctx, roc_host, payload.payload_cap);
                    const value = callHostValueToHostValueWithCapability(ctx, roc_host, payload.payload_cap, payload.from_payload, raw_payload);
                    return self.replaceSignalExprCacheAndClone(ctx, &payload.cached_value, roc_host, value, payload.cap);
                },
            }
        }

        /// Performs eval online source initial inside the shared engine while preserving transaction and changed-set invariants.
        pub fn evalOnlineSourceInitial(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, payload: *HostSignalOnlineSourceRecord) HostValue {
            switch (payload.cached_value) {
                .present => return self.cloneCachedSignalValue(ctx, &payload.cached_value),
                .absent => {
                    const raw_payload = Ctx.initialOnlinePayload(ctx, roc_host, payload.payload_cap);
                    const value = callHostValueToHostValueWithCapability(ctx, roc_host, payload.payload_cap, payload.from_payload, raw_payload);
                    return self.replaceSignalExprCacheAndClone(ctx, &payload.cached_value, roc_host, value, payload.cap);
                },
            }
        }

        /// Performs eval storage source initial inside the shared engine while preserving transaction and changed-set invariants.
        pub fn evalStorageSourceInitial(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, payload: *HostSignalStorageSourceRecord) HostValue {
            switch (payload.cached_value) {
                .present => return self.cloneCachedSignalValue(ctx, &payload.cached_value),
                .absent => {
                    const raw_payload = Ctx.initialStoragePayload(ctx, roc_host, payload.area, payload.key, payload.payload_cap);
                    const value = callHostValueToHostValueWithCapability(ctx, roc_host, payload.payload_cap, payload.from_payload, raw_payload);
                    return self.replaceSignalExprCacheAndClone(ctx, &payload.cached_value, roc_host, value, payload.cap);
                },
            }
        }

        /// Performs eval host signal record inside the shared engine while preserving transaction and changed-set invariants.
        pub fn evalHostSignalRecord(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, record: *HostSignalRecord) HostValue {
            switch (record.payload) {
                .ref => |node_id| return Ctx.stateValueByNodeId(ctx, node_id),
                .const_value => |*payload| {
                    const value = erased_calls.callValueInitThunk(roc_host, payload.init);
                    return self.replaceSignalExprCacheAndClone(ctx, &payload.cached_value, roc_host, value, payload.cap);
                },
                .map => |*payload| {
                    const input = self.evalHostSignalRecord(ctx, roc_host, payload.input);
                    defer self.dropHostSignalRecordValue(ctx, roc_host, payload.input, input);
                    self.recordDerivedCall();
                    const input_cap = self.hostSignalRecordCapability(ctx, payload.input);
                    const value = callHostValueToHostValueWithCapability(ctx, roc_host, input_cap, payload.transform, input);
                    return self.replaceSignalExprCacheAndClone(ctx, &payload.cached_value, roc_host, value, payload.cap);
                },
                .map2 => |*payload| {
                    const left = self.evalHostSignalRecord(ctx, roc_host, payload.left);
                    defer self.dropHostSignalRecordValue(ctx, roc_host, payload.left, left);
                    const right = self.evalHostSignalRecord(ctx, roc_host, payload.right);
                    defer self.dropHostSignalRecordValue(ctx, roc_host, payload.right, right);
                    self.recordDerivedCall();
                    const left_cap = self.hostSignalRecordCapability(ctx, payload.left);
                    const right_cap = self.hostSignalRecordCapability(ctx, payload.right);
                    const value = callHostValueHostValueToHostValueWithCapabilities(ctx, roc_host, left_cap, right_cap, payload.transform, left, right);
                    return self.replaceSignalExprCacheAndClone(ctx, &payload.cached_value, roc_host, value, payload.cap);
                },
                .combine => |*payload| {
                    const allocator = Ctx.allocator(ctx);
                    var values: std.ArrayListUnmanaged(HostValue) = .empty;
                    errdefer {
                        for (payload.children, values.items) |child, value| {
                            self.dropHostSignalRecordValue(ctx, roc_host, child, value);
                        }
                        values.deinit(allocator);
                    }
                    for (payload.children) |child| {
                        values.append(allocator, self.evalHostSignalRecord(ctx, roc_host, child)) catch @panic("out of memory");
                    }
                    const list = HostValueList.fromSlice(values.items, roc_host);
                    defer list.decref(roc_host);
                    self.recordDerivedCall();
                    const input_cap = if (payload.children.len == 0) payload.cap else self.hostSignalRecordCapability(ctx, payload.children[0]);
                    const value = callHostValueListToHostValueWithCapability(ctx, roc_host, input_cap, payload.transform, list);
                    for (payload.children, values.items) |child, child_value| {
                        self.dropHostSignalRecordValue(ctx, roc_host, child, child_value);
                    }
                    values.deinit(allocator);
                    return self.replaceSignalExprCacheAndClone(ctx, &payload.cached_value, roc_host, value, payload.cap);
                },
                .task_source => |*payload| {
                    return self.evalEffectSourceInitial(ctx, roc_host, &payload.cached_value, payload.initial, payload.cap);
                },
                .interval_source => |*payload| {
                    return self.evalEffectSourceInitial(ctx, roc_host, &payload.cached_value, payload.initial, payload.cap);
                },
                .location_source => |*payload| {
                    return self.evalLocationSourceInitial(ctx, roc_host, payload);
                },
                .visibility_source => |*payload| {
                    return self.evalVisibilitySourceInitial(ctx, roc_host, payload);
                },
                .online_source => |*payload| {
                    return self.evalOnlineSourceInitial(ctx, roc_host, payload);
                },
                .storage_source => |*payload| {
                    return self.evalStorageSourceInitial(ctx, roc_host, payload);
                },
            }
        }

        /// Performs eval host signal binding inside the shared engine while preserving transaction and changed-set invariants.
        pub fn evalHostSignalBinding(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, signal: *HostSignalBinding) HostValue {
            return self.evalHostSignalRecord(ctx, roc_host, signal.record);
        }

        /// Performs eval signal text field inside the shared engine while preserving transaction and changed-set invariants.
        pub fn evalSignalTextField(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, elem_id: u64, field: RenderTextField, signal: *HostSignalBinding, read: HostTextRead, cache_slot: *HostSignalCacheSlot) bool {
            const value = self.evalHostSignalBinding(ctx, roc_host, signal);
            const signal_cap = self.hostSignalBindingCapability(ctx, signal);
            assertHostValueCapabilitiesMatch(read.capability, signal_cap, "text read extension capability did not match its signal value");
            const text = callHostValueToStrWithCapability(ctx, roc_host, read.capability, read.read, value);
            defer text.decref(roc_host);
            const changed = self.applyRenderTextField(ctx, elem_id, field, text.asSlice());
            cache_slot.replace(ctx, roc_host, &self.pending_roc_metrics, value, signal_cap);
            return changed;
        }

        /// Performs eval signal text attr inside the shared engine while preserving transaction and changed-set invariants.
        pub fn evalSignalTextAttr(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, elem_id: u64, name: []const u8, signal: *HostSignalBinding, read: HostTextRead, cache_slot: *HostSignalCacheSlot) bool {
            const value = self.evalHostSignalBinding(ctx, roc_host, signal);
            const signal_cap = self.hostSignalBindingCapability(ctx, signal);
            assertHostValueCapabilitiesMatch(read.capability, signal_cap, "text attr read extension capability did not match its signal value");
            const text = callHostValueToStrWithCapability(ctx, roc_host, read.capability, read.read, value);
            defer text.decref(roc_host);
            const changed = self.applyRenderTextAttr(ctx, elem_id, name, text.asSlice());
            cache_slot.replace(ctx, roc_host, &self.pending_roc_metrics, value, signal_cap);
            return changed;
        }

        fn applySignalOptionalTextAttrValue(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, elem_id: u64, name: []const u8, value: HostValue, signal_cap: HostValueCapability, present: HostBoolRead, read: HostTextRead) bool {
            assertHostValueCapabilitiesMatch(present.capability, signal_cap, "optional text attr presence read extension capability did not match its signal value");
            assertHostValueCapabilitiesMatch(read.capability, signal_cap, "optional text attr read extension capability did not match its signal value");
            if (!callHostValueToBoolWithCapability(ctx, roc_host, present.capability, present.read, value)) {
                return self.clearRenderTextAttr(ctx, elem_id, name);
            }
            const text = callHostValueToStrWithCapability(ctx, roc_host, read.capability, read.read, value);
            defer text.decref(roc_host);
            return self.applyRenderTextAttr(ctx, elem_id, name, text.asSlice());
        }

        /// Performs eval signal optional text attr inside the shared engine while preserving transaction and changed-set invariants.
        pub fn evalSignalOptionalTextAttr(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, elem_id: u64, name: []const u8, signal: *HostSignalBinding, present: HostBoolRead, read: HostTextRead, cache_slot: *HostSignalCacheSlot) bool {
            const value = self.evalHostSignalBinding(ctx, roc_host, signal);
            const signal_cap = self.hostSignalBindingCapability(ctx, signal);
            const changed = self.applySignalOptionalTextAttrValue(ctx, roc_host, elem_id, name, value, signal_cap, present, read);
            cache_slot.replace(ctx, roc_host, &self.pending_roc_metrics, value, signal_cap);
            return changed;
        }

        /// Performs eval signal bool field inside the shared engine while preserving transaction and changed-set invariants.
        pub fn evalSignalBoolField(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, elem_id: u64, field: RenderBoolField, signal: *HostSignalBinding, read: HostBoolRead, cache_slot: *HostSignalCacheSlot) bool {
            const value = self.evalHostSignalBinding(ctx, roc_host, signal);
            const signal_cap = self.hostSignalBindingCapability(ctx, signal);
            assertHostValueCapabilitiesMatch(read.capability, signal_cap, "bool read extension capability did not match its signal value");
            const bool_value = callHostValueToBoolWithCapability(ctx, roc_host, read.capability, read.read, value);
            const changed = self.applyRenderBoolField(ctx, elem_id, field, bool_value);
            cache_slot.replace(ctx, roc_host, &self.pending_roc_metrics, value, signal_cap);
            return changed;
        }

        /// Performs eval signal bool attr inside the shared engine while preserving transaction and changed-set invariants.
        pub fn evalSignalBoolAttr(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, elem_id: u64, name: []const u8, signal: *HostSignalBinding, read: HostBoolRead, cache_slot: *HostSignalCacheSlot) bool {
            const value = self.evalHostSignalBinding(ctx, roc_host, signal);
            const signal_cap = self.hostSignalBindingCapability(ctx, signal);
            assertHostValueCapabilitiesMatch(read.capability, signal_cap, "bool attr read extension capability did not match its signal value");
            const bool_value = callHostValueToBoolWithCapability(ctx, roc_host, read.capability, read.read, value);
            const changed = self.applyRenderBoolAttr(ctx, elem_id, name, bool_value);
            cache_slot.replace(ctx, roc_host, &self.pending_roc_metrics, value, signal_cap);
            return changed;
        }

        /// Performs eval dirty signal text field inside the shared engine while preserving transaction and changed-set invariants.
        pub fn evalDirtySignalTextField(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, elem_id: u64, field: RenderTextField, signal: *HostSignalBinding, read: HostTextRead, cache_slot: *HostSignalCacheSlot, dirty_source_node_ids: []const u64, dirty_generation: u64) bool {
            const result = self.evalDirtyHostSignalBinding(ctx, roc_host, signal, dirty_source_node_ids, dirty_generation);
            const cap = self.hostSignalBindingCapability(ctx, signal);
            assertHostValueCapabilitiesMatch(read.capability, cap, "dirty text read extension capability did not match its signal value");
            if (!result.changed) {
                callHostValueToUnitWithCapability(ctx, roc_host, cap, hv.hostValueCapabilityDrop(cap), result.value);
                return false;
            }
            if (!self.updateDirtySignalCache(ctx, roc_host, cache_slot, result.value, cap)) return false;
            const text = callHostValueToStrWithCapability(ctx, roc_host, read.capability, read.read, result.value);
            defer text.decref(roc_host);
            return self.applyRenderTextField(ctx, elem_id, field, text.asSlice());
        }

        /// Performs eval dirty signal text attr inside the shared engine while preserving transaction and changed-set invariants.
        pub fn evalDirtySignalTextAttr(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, elem_id: u64, name: []const u8, signal: *HostSignalBinding, read: HostTextRead, cache_slot: *HostSignalCacheSlot, dirty_source_node_ids: []const u64, dirty_generation: u64) bool {
            const result = self.evalDirtyHostSignalBinding(ctx, roc_host, signal, dirty_source_node_ids, dirty_generation);
            const cap = self.hostSignalBindingCapability(ctx, signal);
            assertHostValueCapabilitiesMatch(read.capability, cap, "dirty text attr read extension capability did not match its signal value");
            if (!result.changed) {
                callHostValueToUnitWithCapability(ctx, roc_host, cap, hv.hostValueCapabilityDrop(cap), result.value);
                return false;
            }
            if (!self.updateDirtySignalCache(ctx, roc_host, cache_slot, result.value, cap)) return false;
            const text = callHostValueToStrWithCapability(ctx, roc_host, read.capability, read.read, result.value);
            defer text.decref(roc_host);
            return self.applyRenderTextAttr(ctx, elem_id, name, text.asSlice());
        }

        /// Performs eval dirty signal optional text attr inside the shared engine while preserving transaction and changed-set invariants.
        pub fn evalDirtySignalOptionalTextAttr(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, elem_id: u64, name: []const u8, signal: *HostSignalBinding, present: HostBoolRead, read: HostTextRead, cache_slot: *HostSignalCacheSlot, dirty_source_node_ids: []const u64, dirty_generation: u64) bool {
            const result = self.evalDirtyHostSignalBinding(ctx, roc_host, signal, dirty_source_node_ids, dirty_generation);
            const cap = self.hostSignalBindingCapability(ctx, signal);
            assertHostValueCapabilitiesMatch(present.capability, cap, "dirty optional text attr presence read extension capability did not match its signal value");
            assertHostValueCapabilitiesMatch(read.capability, cap, "dirty optional text attr read extension capability did not match its signal value");
            if (!result.changed) {
                callHostValueToUnitWithCapability(ctx, roc_host, cap, hv.hostValueCapabilityDrop(cap), result.value);
                return false;
            }
            if (!self.updateDirtySignalCache(ctx, roc_host, cache_slot, result.value, cap)) return false;
            return self.applySignalOptionalTextAttrValue(ctx, roc_host, elem_id, name, result.value, cap, present, read);
        }

        /// Performs eval dirty signal bool field inside the shared engine while preserving transaction and changed-set invariants.
        pub fn evalDirtySignalBoolField(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, elem_id: u64, field: RenderBoolField, signal: *HostSignalBinding, read: HostBoolRead, cache_slot: *HostSignalCacheSlot, dirty_source_node_ids: []const u64, dirty_generation: u64) bool {
            const result = self.evalDirtyHostSignalBinding(ctx, roc_host, signal, dirty_source_node_ids, dirty_generation);
            const cap = self.hostSignalBindingCapability(ctx, signal);
            assertHostValueCapabilitiesMatch(read.capability, cap, "dirty bool read extension capability did not match its signal value");
            if (!result.changed) {
                callHostValueToUnitWithCapability(ctx, roc_host, cap, hv.hostValueCapabilityDrop(cap), result.value);
                return false;
            }
            if (!self.updateDirtySignalCache(ctx, roc_host, cache_slot, result.value, cap)) return false;
            return self.applyRenderBoolField(ctx, elem_id, field, callHostValueToBoolWithCapability(ctx, roc_host, read.capability, read.read, result.value));
        }

        /// Performs eval dirty signal bool attr inside the shared engine while preserving transaction and changed-set invariants.
        pub fn evalDirtySignalBoolAttr(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, elem_id: u64, name: []const u8, signal: *HostSignalBinding, read: HostBoolRead, cache_slot: *HostSignalCacheSlot, dirty_source_node_ids: []const u64, dirty_generation: u64) bool {
            const result = self.evalDirtyHostSignalBinding(ctx, roc_host, signal, dirty_source_node_ids, dirty_generation);
            const cap = self.hostSignalBindingCapability(ctx, signal);
            assertHostValueCapabilitiesMatch(read.capability, cap, "dirty bool attr read extension capability did not match its signal value");
            if (!result.changed) {
                callHostValueToUnitWithCapability(ctx, roc_host, cap, hv.hostValueCapabilityDrop(cap), result.value);
                return false;
            }
            if (!self.updateDirtySignalCache(ctx, roc_host, cache_slot, result.value, cap)) return false;
            return self.applyRenderBoolAttr(ctx, elem_id, name, callHostValueToBoolWithCapability(ctx, roc_host, read.capability, read.read, result.value));
        }

        /// Performs eval structural signal text field inside the shared engine while preserving transaction and changed-set invariants.
        pub fn evalStructuralSignalTextField(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, elem_id: u64, field: RenderTextField, signal: *HostSignalBinding, read: HostTextRead, cache_slot: *HostSignalCacheSlot, dirty_source_node_ids: []const u64, dirty_generation: u64) bool {
            if (dirty_generation != 0 and sourceNodeIdsIntersect(signal.source_node_ids, dirty_source_node_ids)) {
                return self.evalDirtySignalTextField(ctx, roc_host, elem_id, field, signal, read, cache_slot, dirty_source_node_ids, dirty_generation);
            }
            return self.evalSignalTextField(ctx, roc_host, elem_id, field, signal, read, cache_slot);
        }

        /// Performs eval structural signal text attr inside the shared engine while preserving transaction and changed-set invariants.
        pub fn evalStructuralSignalTextAttr(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, elem_id: u64, name: []const u8, signal: *HostSignalBinding, read: HostTextRead, cache_slot: *HostSignalCacheSlot, dirty_source_node_ids: []const u64, dirty_generation: u64) bool {
            if (dirty_generation != 0 and sourceNodeIdsIntersect(signal.source_node_ids, dirty_source_node_ids)) {
                return self.evalDirtySignalTextAttr(ctx, roc_host, elem_id, name, signal, read, cache_slot, dirty_source_node_ids, dirty_generation);
            }
            return self.evalSignalTextAttr(ctx, roc_host, elem_id, name, signal, read, cache_slot);
        }

        /// Performs eval structural signal optional text attr inside the shared engine while preserving transaction and changed-set invariants.
        pub fn evalStructuralSignalOptionalTextAttr(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, elem_id: u64, name: []const u8, signal: *HostSignalBinding, present: HostBoolRead, read: HostTextRead, cache_slot: *HostSignalCacheSlot, dirty_source_node_ids: []const u64, dirty_generation: u64) bool {
            if (dirty_generation != 0 and sourceNodeIdsIntersect(signal.source_node_ids, dirty_source_node_ids)) {
                return self.evalDirtySignalOptionalTextAttr(ctx, roc_host, elem_id, name, signal, present, read, cache_slot, dirty_source_node_ids, dirty_generation);
            }
            return self.evalSignalOptionalTextAttr(ctx, roc_host, elem_id, name, signal, present, read, cache_slot);
        }

        /// Performs eval structural signal bool field inside the shared engine while preserving transaction and changed-set invariants.
        pub fn evalStructuralSignalBoolField(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, elem_id: u64, field: RenderBoolField, signal: *HostSignalBinding, read: HostBoolRead, cache_slot: *HostSignalCacheSlot, dirty_source_node_ids: []const u64, dirty_generation: u64) bool {
            if (dirty_generation != 0 and sourceNodeIdsIntersect(signal.source_node_ids, dirty_source_node_ids)) {
                return self.evalDirtySignalBoolField(ctx, roc_host, elem_id, field, signal, read, cache_slot, dirty_source_node_ids, dirty_generation);
            }
            return self.evalSignalBoolField(ctx, roc_host, elem_id, field, signal, read, cache_slot);
        }

        /// Performs eval structural signal bool attr inside the shared engine while preserving transaction and changed-set invariants.
        pub fn evalStructuralSignalBoolAttr(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, elem_id: u64, name: []const u8, signal: *HostSignalBinding, read: HostBoolRead, cache_slot: *HostSignalCacheSlot, dirty_source_node_ids: []const u64, dirty_generation: u64) bool {
            if (dirty_generation != 0 and sourceNodeIdsIntersect(signal.source_node_ids, dirty_source_node_ids)) {
                return self.evalDirtySignalBoolAttr(ctx, roc_host, elem_id, name, signal, read, cache_slot, dirty_source_node_ids, dirty_generation);
            }
            return self.evalSignalBoolAttr(ctx, roc_host, elem_id, name, signal, read, cache_slot);
        }

        /// Performs eval dirty host signal record inside the shared engine while preserving transaction and changed-set invariants.
        pub fn evalDirtyHostSignalRecord(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, record: *HostSignalRecord, dirty_source_node_ids: []const u64, dirty_generation: u64) HostSignalEvalResult {
            if (dirty_generation == 0) @panic("dirty signal evaluation used generation 0");
            debugPhase(ctx, .eval_dirty_signal);
            if (self.cloneMemoizedDirtySignalResult(ctx, record, dirty_generation)) |result| return result;

            switch (record.payload) {
                .ref => |node_id| {
                    debugPhase(ctx, .eval_dirty_ref);
                    return .{
                        .value = Ctx.stateValueByNodeId(ctx, node_id),
                        .changed = u64SliceContains(dirty_source_node_ids, node_id),
                    };
                },
                .const_value => |*payload| {
                    if (payload.cached_value == .absent) {
                        debugPhase(ctx, .eval_dirty_const_initialize);
                        const value = erased_calls.callValueInitThunk(roc_host, payload.init);
                        return self.rememberDirtySignalResult(record, dirty_generation, self.updateDirtySignalExprCache(ctx, roc_host, &payload.cached_value, value, payload.cap));
                    }
                    debugPhase(ctx, .eval_dirty_const_cached);
                    return self.rememberDirtySignalResult(record, dirty_generation, .{
                        .value = self.cloneCachedSignalValue(ctx, &payload.cached_value),
                        .changed = false,
                    });
                },
                .map => |*payload| {
                    const cache_was_absent = payload.cached_value == .absent;
                    debugPhase(ctx, .eval_dirty_map_input);
                    const input = self.evalDirtyHostSignalRecord(ctx, roc_host, payload.input, dirty_source_node_ids, dirty_generation);
                    defer self.dropHostSignalRecordValue(ctx, roc_host, payload.input, input.value);
                    if (!input.changed and !cache_was_absent) {
                        debugPhase(ctx, .eval_dirty_map_cached);
                        return self.rememberDirtySignalResult(record, dirty_generation, .{ .value = self.cloneCachedSignalValue(ctx, &payload.cached_value), .changed = false });
                    }

                    self.recordDerivedCall();
                    debugPhase(ctx, .eval_dirty_map_transform);
                    const input_cap = self.hostSignalRecordCapability(ctx, payload.input);
                    const value = callHostValueToHostValueWithCapability(ctx, roc_host, input_cap, payload.transform, input.value);
                    debugPhase(ctx, .eval_dirty_map_cache);
                    return self.rememberDirtySignalResult(record, dirty_generation, self.updateDirtySignalExprCache(ctx, roc_host, &payload.cached_value, value, payload.cap));
                },
                .map2 => |*payload| {
                    const cache_was_absent = payload.cached_value == .absent;
                    debugPhase(ctx, .eval_dirty_map2_left);
                    const left = self.evalDirtyHostSignalRecord(ctx, roc_host, payload.left, dirty_source_node_ids, dirty_generation);
                    defer self.dropHostSignalRecordValue(ctx, roc_host, payload.left, left.value);
                    debugPhase(ctx, .eval_dirty_map2_right);
                    const right = self.evalDirtyHostSignalRecord(ctx, roc_host, payload.right, dirty_source_node_ids, dirty_generation);
                    defer self.dropHostSignalRecordValue(ctx, roc_host, payload.right, right.value);
                    if (!left.changed and !right.changed and !cache_was_absent) {
                        debugPhase(ctx, .eval_dirty_map2_cached);
                        return self.rememberDirtySignalResult(record, dirty_generation, .{ .value = self.cloneCachedSignalValue(ctx, &payload.cached_value), .changed = false });
                    }

                    self.recordDerivedCall();
                    debugPhase(ctx, .eval_dirty_map2_transform);
                    const left_cap = self.hostSignalRecordCapability(ctx, payload.left);
                    const right_cap = self.hostSignalRecordCapability(ctx, payload.right);
                    const value = callHostValueHostValueToHostValueWithCapabilities(ctx, roc_host, left_cap, right_cap, payload.transform, left.value, right.value);
                    debugPhase(ctx, .eval_dirty_map2_cache);
                    return self.rememberDirtySignalResult(record, dirty_generation, self.updateDirtySignalExprCache(ctx, roc_host, &payload.cached_value, value, payload.cap));
                },
                .combine => |*payload| {
                    const cache_was_absent = payload.cached_value == .absent;
                    const allocator = Ctx.allocator(ctx);
                    var values: std.ArrayListUnmanaged(HostValue) = .empty;
                    errdefer {
                        for (payload.children[0..values.items.len], values.items) |child, value| {
                            self.dropHostSignalRecordValue(ctx, roc_host, child, value);
                        }
                        values.deinit(allocator);
                    }

                    var any_changed = false;
                    for (payload.children) |child| {
                        debugPhase(ctx, .eval_dirty_combine_child);
                        const child_result = self.evalDirtyHostSignalRecord(ctx, roc_host, child, dirty_source_node_ids, dirty_generation);
                        any_changed = any_changed or child_result.changed;
                        values.append(allocator, child_result.value) catch @panic("out of memory");
                    }

                    if (!any_changed and !cache_was_absent) {
                        debugPhase(ctx, .eval_dirty_combine_cached);
                        for (payload.children, values.items) |child, value| {
                            self.dropHostSignalRecordValue(ctx, roc_host, child, value);
                        }
                        values.deinit(allocator);
                        return self.rememberDirtySignalResult(record, dirty_generation, .{ .value = self.cloneCachedSignalValue(ctx, &payload.cached_value), .changed = false });
                    }

                    const list = HostValueList.fromSlice(values.items, roc_host);
                    defer list.decref(roc_host);
                    self.recordDerivedCall();
                    debugPhase(ctx, .eval_dirty_combine_transform);
                    const input_cap = if (payload.children.len == 0) payload.cap else self.hostSignalRecordCapability(ctx, payload.children[0]);
                    const value = callHostValueListToHostValueWithCapability(ctx, roc_host, input_cap, payload.transform, list);
                    debugPhase(ctx, .eval_dirty_combine_cache);
                    for (payload.children, values.items) |child, child_value| {
                        self.dropHostSignalRecordValue(ctx, roc_host, child, child_value);
                    }
                    values.deinit(allocator);
                    return self.rememberDirtySignalResult(record, dirty_generation, self.updateDirtySignalExprCache(ctx, roc_host, &payload.cached_value, value, payload.cap));
                },
                .task_source => |*payload| {
                    debugPhase(ctx, .eval_dirty_task_source);
                    return self.rememberDirtySignalResult(record, dirty_generation, .{
                        .value = self.cloneCachedSignalValue(ctx, &payload.cached_value),
                        .changed = record.last_dirty_generation == dirty_generation and record.last_dirty_changed,
                    });
                },
                .interval_source => |*payload| {
                    debugPhase(ctx, .eval_dirty_interval_source);
                    return self.rememberDirtySignalResult(record, dirty_generation, .{
                        .value = self.cloneCachedSignalValue(ctx, &payload.cached_value),
                        .changed = record.last_dirty_generation == dirty_generation and record.last_dirty_changed,
                    });
                },
                .location_source => |*payload| {
                    debugPhase(ctx, .eval_dirty_location_source);
                    return self.rememberDirtySignalResult(record, dirty_generation, .{
                        .value = self.cloneCachedSignalValue(ctx, &payload.cached_value),
                        .changed = record.last_dirty_generation == dirty_generation and record.last_dirty_changed,
                    });
                },
                .visibility_source => |*payload| {
                    debugPhase(ctx, .eval_dirty_visibility_source);
                    return self.rememberDirtySignalResult(record, dirty_generation, .{
                        .value = self.cloneCachedSignalValue(ctx, &payload.cached_value),
                        .changed = record.last_dirty_generation == dirty_generation and record.last_dirty_changed,
                    });
                },
                .online_source => |*payload| {
                    debugPhase(ctx, .eval_dirty_online_source);
                    return self.rememberDirtySignalResult(record, dirty_generation, .{
                        .value = self.cloneCachedSignalValue(ctx, &payload.cached_value),
                        .changed = record.last_dirty_generation == dirty_generation and record.last_dirty_changed,
                    });
                },
                .storage_source => |*payload| {
                    debugPhase(ctx, .eval_dirty_storage_source);
                    return self.rememberDirtySignalResult(record, dirty_generation, .{
                        .value = self.cloneCachedSignalValue(ctx, &payload.cached_value),
                        .changed = record.last_dirty_generation == dirty_generation and record.last_dirty_changed,
                    });
                },
            }
        }

        /// Performs eval dirty host signal binding inside the shared engine while preserving transaction and changed-set invariants.
        pub fn evalDirtyHostSignalBinding(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, signal: *HostSignalBinding, dirty_source_node_ids: []const u64, dirty_generation: u64) HostSignalEvalResult {
            return self.evalDirtyHostSignalRecord(ctx, roc_host, signal.record, dirty_source_node_ids, dirty_generation);
        }

        /// Returns a borrowed slice backed by engine scratch. Callers must not free
        /// it, and it stays valid only until the next dirty propagation.
        pub fn propagateDirtyActiveSignals(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, allocator: std.mem.Allocator, dirty_source_node_ids: []const u64, dirty_generation: u64) []const u64 {
            self.identity_reuse_barrier = dirty_generation;
            _ = allocator;
            const dirty_record_ids = self.scratchDirtyActiveSignalRecordIdsForSources(ctx, dirty_source_node_ids);
            return self.propagateDirtyActiveSignalRecordIds(ctx, roc_host, dirty_record_ids, dirty_source_node_ids, dirty_generation);
        }

        /// Returns a borrowed slice backed by engine scratch. Callers must not free
        /// it, and it stays valid only until the next dirty propagation.
        pub fn propagateDirtyActiveSignalRecordIds(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, dirty_record_ids: []const u64, dirty_source_node_ids: []const u64, dirty_generation: u64) []const u64 {
            const allocator = Ctx.allocator(ctx);
            var changed_record_ids = &self.scratch.dirty_changed_record_ids;
            changed_record_ids.clearRetainingCapacity();

            for (dirty_record_ids) |record_id| {
                const record = self.active_signal_graph.items[@intCast(record_id)].record;
                debugPhase(ctx, .propagate_record_before_eval);
                const result = self.evalDirtyHostSignalRecord(ctx, roc_host, record, dirty_source_node_ids, dirty_generation);
                if (result.changed) {
                    changed_record_ids.append(allocator, record_id) catch @panic("out of memory");
                }
                debugPhase(ctx, .propagate_record_before_drop);
                self.dropHostSignalRecordValue(ctx, roc_host, record, result.value);
            }

            return changed_record_ids.items;
        }

        /// Collects dirty structural signals from the explicitly affected graph or scope set.
        pub fn collectDirtyStructuralSignals(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, allocator: std.mem.Allocator, dirty_source_node_ids: []const u64, changed_record_ids: []const u64, dirty_generation: u64) []HostDirtyStructuralSignal {
            var dirty_structural_signals: std.ArrayListUnmanaged(HostDirtyStructuralSignal) = .empty;
            errdefer {
                for (dirty_structural_signals.items) |*change| change.abortPendingWhenCache(ctx, roc_host, &self.pending_roc_metrics);
                dirty_structural_signals.deinit(allocator);
            }

            for (changed_record_ids) |record_id| {
                const route_index: usize = @intCast(record_id);
                if (route_index >= self.active_structural_signal_routes.items.len) continue;

                for (self.active_structural_signal_routes.items[route_index].items) |route| {
                    switch (route.kind) {
                        .when => {
                            const desc = &self.active_stream.whens.items[route.index];
                            const site = self.activeScopeSiteByNodeId(desc.node_id, .when) orelse @panic("active when descriptor had no scope site");
                            const result = self.evalDirtyHostSignalBinding(ctx, roc_host, &desc.condition, dirty_source_node_ids, dirty_generation);
                            const cap = self.hostSignalBindingCapability(ctx, &desc.condition);
                            assertHostValueCapabilitiesMatch(desc.read.capability, cap, "dirty when read extension capability did not match its signal value");
                            if (!result.changed) {
                                callHostValueToUnitWithCapability(ctx, roc_host, cap, hv.hostValueCapabilityDrop(cap), result.value);
                                continue;
                            }
                            const active_branch: HostScopeBranch = if (callHostValueToBoolWithCapability(ctx, roc_host, desc.read.capability, desc.read.read, result.value)) .true_branch else .false_branch;
                            const changed = switch (desc.cached_value) {
                                .absent => true,
                                .present => |cached| !cached.valueEquals(ctx, roc_host, result.value),
                            };
                            if (!changed) {
                                callHostValueToUnitWithCapability(ctx, roc_host, cap, hv.hostValueCapabilityDrop(cap), result.value);
                                self.recordSignalPrune();
                                continue;
                            }
                            var change = HostDirtyStructuralSignal{
                                .kind = .when,
                                .node_id = desc.node_id,
                                .scope_id = site.scope_id,
                                .ordinal = site.ordinal,
                                .record = desc.condition.record,
                                .branch = active_branch,
                                .pending_when_cache = HostValueCell.initRetained(result.value, cap, &self.pending_roc_metrics),
                            };
                            dirty_structural_signals.append(allocator, change) catch {
                                change.abortPendingWhenCache(ctx, roc_host, &self.pending_roc_metrics);
                                @panic("out of memory");
                            };
                        },
                        .each => {
                            const desc = &self.active_stream.eaches.items[route.index];
                            const site = self.activeScopeSiteByNodeId(desc.node_id, .each) orelse @panic("active each descriptor had no scope site");
                            const result = self.evalDirtyHostSignalBinding(ctx, roc_host, &desc.items, dirty_source_node_ids, dirty_generation);
                            const cap = self.hostSignalBindingCapability(ctx, &desc.items);
                            if (!result.changed) {
                                callHostValueToUnitWithCapability(ctx, roc_host, cap, hv.hostValueCapabilityDrop(cap), result.value);
                                continue;
                            }
                            if (self.updateDirtySignalCache(ctx, roc_host, &desc.cached_value, result.value, cap)) {
                                dirty_structural_signals.append(allocator, .{
                                    .kind = .each,
                                    .node_id = desc.node_id,
                                    .scope_id = site.scope_id,
                                    .ordinal = site.ordinal,
                                    .record = desc.items.record,
                                }) catch @panic("out of memory");
                            }
                        },
                    }
                }
            }

            return dirty_structural_signals.toOwnedSlice(allocator) catch @panic("out of memory");
        }

        /// Performs state index by node id inside the shared engine while preserving transaction and changed-set invariants.
        pub fn stateIndexByNodeId(self: *Self, node_id: u64) ?usize {
            if (node_id >= self.state_indexes_by_node_id.items.len) return null;
            const state_index = self.state_indexes_by_node_id.items[@intCast(node_id)] orelse return null;
            if (state_index >= self.states.items.len) @panic("state cell index exceeded state table");
            const state = self.states.items[state_index];
            if (!state.active or state.state_id != node_id) @panic("state cell index pointed at the wrong state");
            return state_index;
        }

        /// Returns the exact app-compiled capability that owns the requested state cell.
        pub fn stateCapability(self: *Self, node_id: u64) StateLookupError!HostValueCapability {
            const state_index = self.stateIndexByNodeId(node_id) orelse return StateLookupError.MissingActiveState;
            return self.states.items[state_index].cell.cap;
        }

        /// Returns active event reducer by index from the maintained active-runtime indexes.
        pub fn activeEventReducerByIndex(self: *Self, event_index: usize) ActiveEventLookupError!HostEventReducer {
            if (event_index >= self.active_events.items.len) return ActiveEventLookupError.MissingActiveEvent;
            return self.active_events.items[event_index].payload_reducer;
        }

        /// Returns active scope site by node id from the maintained active-runtime indexes.
        pub fn activeScopeSiteByNodeId(self: *Self, node_id: u64, kind: HostNodeScopeSiteKind) ?HostNodeScopeSiteDesc {
            const descriptor_index = self.active_stream.nodeDescriptorIndex(node_id) orelse return null;
            const scope_site_index = descriptor_index.scope_sites.get(kind) orelse return null;
            if (scope_site_index >= self.active_stream.scope_sites.items.len) @panic("active scope site index exceeded descriptor table");
            const site = self.active_stream.scope_sites.items[scope_site_index];
            if (site.node_id != node_id or site.kind != kind) @panic("active scope site index pointed at the wrong node");
            return site;
        }

        /// Returns active when index by node id from the maintained active-runtime indexes.
        pub fn activeWhenIndexByNodeId(self: *Self, node_id: u64) ?usize {
            const descriptor_index = self.active_stream.nodeDescriptorIndex(node_id) orelse return null;
            const when_index = descriptor_index.when.get() orelse return null;
            if (when_index >= self.active_stream.whens.items.len) @panic("active when index exceeded descriptor table");
            if (self.active_stream.whens.items[when_index].node_id != node_id) @panic("active when index pointed at the wrong node");
            return when_index;
        }

        /// Returns active each index by node id from the maintained active-runtime indexes.
        pub fn activeEachIndexByNodeId(self: *Self, node_id: u64) ?usize {
            const descriptor_index = self.active_stream.nodeDescriptorIndex(node_id) orelse return null;
            const each_index = descriptor_index.each.get() orelse return null;
            if (each_index >= self.active_stream.eaches.items.len) @panic("active each index exceeded descriptor table");
            if (self.active_stream.eaches.items[each_index].node_id != node_id) @panic("active each index pointed at the wrong node");
            return each_index;
        }

        /// Records slice contains in the metrics or lifecycle state owned by this operation.
        pub fn recordSliceContains(records: []const *HostSignalRecord, record: *HostSignalRecord) bool {
            return active_graph.recordSliceContains(HostSignalRecord, records, record);
        }

        /// Returns active when branch scope id from the maintained active-runtime indexes.
        pub fn activeWhenBranchScopeId(self: *Self, parent_scope_id: u64, site_ordinal: u64, branch: HostScopeBranch) scope_tree.Error!?u64 {
            return scope_tree.activeWhenBranch(HostEachRowScopeStep, self.scopes.items, parent_scope_id, site_ordinal, branch);
        }

        /// Performs validate scope id inside the shared engine while preserving transaction and changed-set invariants.
        pub fn validateScopeId(self: *Self, scope_id: u64) scope_tree.Error!void {
            return scope_tree.validate(HostEachRowScopeStep, self.scopes.items, scope_id);
        }

        /// Performs intern root scope inside the shared engine while preserving transaction and changed-set invariants.
        pub fn internRootScope(self: *Self, allocator: std.mem.Allocator) scope_tree.Error!scope_tree.InternResult {
            const result = try scope_tree.internRoot(HostEachRowScopeStep, allocator, &self.scopes);
            if (result.created) self.recordScopeCreated();
            return result;
        }

        /// Performs intern component scope inside the shared engine while preserving transaction and changed-set invariants.
        pub fn internComponentScope(self: *Self, allocator: std.mem.Allocator, parent_scope_id: u64, site_ordinal: u64) scope_tree.Error!scope_tree.InternResult {
            const result = try scope_tree.internComponent(HostEachRowScopeStep, allocator, &self.scopes, parent_scope_id, site_ordinal, self.identity_reuse_barrier);
            if (result.created) self.recordScopeCreated();
            return result;
        }

        /// Performs intern when branch scope inside the shared engine while preserving transaction and changed-set invariants.
        pub fn internWhenBranchScope(self: *Self, allocator: std.mem.Allocator, parent_scope_id: u64, site_ordinal: u64, branch: HostScopeBranch) scope_tree.Error!scope_tree.InternResult {
            const result = try scope_tree.internWhenBranch(HostEachRowScopeStep, allocator, &self.scopes, parent_scope_id, site_ordinal, branch, self.identity_reuse_barrier);
            if (result.created) self.recordScopeCreated();
            return result;
        }

        /// Performs intern node identity inside the shared engine while preserving transaction and changed-set invariants.
        pub fn internNodeIdentity(self: *Self, allocator: std.mem.Allocator, scope_id: u64, ordinal: u64) IdentityInternError!u64 {
            try self.validateScopeId(scope_id);
            const key = identityKey(scope_id, ordinal);
            if (self.active_node_identity_ids.get(key)) |node_id| return node_id;
            self.active_node_identity_ids.ensureUnusedCapacity(allocator, 1) catch return IdentityInternError.OutOfMemory;
            const node_id = blk: {
                if (!self.has_inactive_node_identities and (self.node_identities.items.len == 0 or identityCanAppend(self.node_identities.items[self.node_identities.items.len - 1], scope_id, ordinal))) {
                    break :blk try identity_table.appendFreshNode(allocator, &self.node_identities, scope_id, ordinal);
                }
                break :blk try identity_table.internNode(allocator, &self.node_identities, scope_id, ordinal, self.identity_reuse_barrier);
            };
            self.active_node_identity_ids.putAssumeCapacity(key, node_id);
            return node_id;
        }

        /// Performs intern dom identity inside the shared engine while preserving transaction and changed-set invariants.
        pub fn internDomIdentity(self: *Self, allocator: std.mem.Allocator, scope_id: u64, ordinal: u64) IdentityInternError!u64 {
            try self.validateScopeId(scope_id);
            const key = identityKey(scope_id, ordinal);
            if (self.active_dom_identity_ids.get(key)) |elem_id| return elem_id;
            self.active_dom_identity_ids.ensureUnusedCapacity(allocator, 1) catch return IdentityInternError.OutOfMemory;
            const elem_id = blk: {
                if (!self.has_inactive_dom_identities and (self.dom_identities.items.len == 0 or identityCanAppend(self.dom_identities.items[self.dom_identities.items.len - 1], scope_id, ordinal))) {
                    break :blk try identity_table.appendFreshDom(allocator, &self.dom_identities, scope_id, ordinal);
                }
                break :blk try identity_table.internDom(allocator, &self.dom_identities, scope_id, ordinal, self.identity_reuse_barrier, ActiveDomIds{ .stream = &self.active_stream });
            };
            self.active_dom_identity_ids.putAssumeCapacity(key, elem_id);
            return elem_id;
        }

        /// Returns active each row scopes from the maintained active-runtime indexes.
        pub fn activeEachRowScopes(self: *Self, allocator: std.mem.Allocator, parent_scope_id: u64, site_ordinal: u64) scope_tree.Error![]u64 {
            try self.validateScopeId(parent_scope_id);
            const site_index = self.activeEachRowSiteIndex(parent_scope_id, site_ordinal) orelse {
                return allocator.alloc(u64, 0) catch return scope_tree.Error.OutOfMemory;
            };
            return allocator.dupe(u64, self.each_row_sites.items[site_index].scope_ids.items) catch return scope_tree.Error.OutOfMemory;
        }

        /// Performs each row scope key equals inside the shared engine while preserving transaction and changed-set invariants.
        pub fn eachRowScopeKeyEquals(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, scope_id: u64, key: HostValue, key_cap: HostValueCapability) bool {
            self.recordEachKeyReuseCompare();
            return scope_runtime.eachRowKeyEquals(self.scopes.items, ctx, roc_host, scope_id, key, key_cap);
        }

        /// Performs each row scope key value inside the shared engine while preserving transaction and changed-set invariants.
        pub fn eachRowScopeKeyValue(self: *Self, scope_id: u64) HostValue {
            return scope_runtime.eachRowKeyValue(self.scopes.items, scope_id);
        }

        /// Performs each row scope key hash inside the shared engine while preserving transaction and changed-set invariants.
        pub fn eachRowScopeKeyHash(self: *Self, scope_id: u64) u64 {
            return scope_runtime.eachRowKeyHash(self.scopes.items, scope_id);
        }

        /// Reports whether h each key value is present in maintained state.
        pub fn hashEachKeyValue(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, key_text: abi.RocErasedCallable, key_cap: HostValueCapability, key: HostValue) u64 {
            self.recordEachKeyHash();
            const text = callHostValueToStrWithCapability(ctx, roc_host, key_cap, key_text, key);
            defer text.decref(roc_host);
            return hashEachKeyText(text.asSlice());
        }

        /// Rejects a duplicate keyed row at the narrow reconciliation boundary with a bounded diagnostic.
        pub fn failDuplicateEachKey(
            self: *Self,
            ctx: Ctx.Handle,
            roc_host: *abi.RocHost,
            key_text: abi.RocErasedCallable,
            key_cap: HostValueCapability,
            parent_scope_id: u64,
            site_ordinal: u64,
            first_index: usize,
            second_index: usize,
            key: HostValue,
        ) noreturn {
            _ = self;
            const text = callHostValueToStrWithCapability(ctx, roc_host, key_cap, key_text, key);
            var buf: [512]u8 = undefined;
            const msg = formatEachDuplicateKeyDiagnostic(&buf, parent_scope_id, site_ordinal, first_index, second_index, text.asSlice());
            text.decref(roc_host);
            if (comptime @hasDecl(Ctx, "failWithMessage")) {
                Ctx.failWithMessage(ctx, msg);
            }
            @panic(msg);
        }

        /// Performs each keys equal inside the shared engine while preserving transaction and changed-set invariants.
        pub fn eachKeysEqual(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, ops: HostEachOps, left: HostValue, right: HostValue) bool {
            self.recordEachKeyDuplicateCompare();
            const key_cap = ops.key_capability;
            return callHostValueHostValueToBoolWithCapability(ctx, roc_host, key_cap, hv.hostValueCapabilityEq(key_cap), left, right);
        }

        /// Performs each site row ancestor scope id inside the shared engine while preserving transaction and changed-set invariants.
        pub fn eachSiteRowAncestorScopeId(self: *Self, scope_id: u64, site: HostEachSite) scope_tree.Error!?u64 {
            return scope_tree.eachSiteRowAncestor(HostEachRowScopeStep, self.scopes.items, scope_id, site.parent_scope_id, site.site_ordinal);
        }

        /// Evaluates scope is descendant or self using explicit scope ownership rather than DOM position or content.
        pub fn scopeIsDescendantOrSelf(self: *Self, scope_id: u64, root_scope_id: u64) scope_tree.Error!bool {
            return scope_tree.descendantOrSelf(HostEachRowScopeStep, self.scopes.items, scope_id, root_scope_id);
        }

        fn scopeDepth(self: *Self, scope_id: u64) usize {
            var depth: usize = 0;
            var current: ?u64 = scope_id;
            while (current) |id| {
                if (id >= self.scopes.items.len) return std.math.maxInt(usize);
                const scope = self.scopes.items[@intCast(id)];
                current = scope.parent_scope_id;
                if (current != null) depth += 1;
            }
            return depth;
        }

        fn resolveStateCommandTarget(self: *Self, owner_scope_id: u64, binder_token: HostBinderToken) u64 {
            var target_node_id: ?u64 = null;
            var target_depth: usize = 0;

            for (self.active_stream.scope_sites.items) |site| {
                if (site.kind != .state) continue;
                if (!(self.scopeIsDescendantOrSelf(owner_scope_id, site.scope_id) catch @panic("state command owner referenced an unknown scope"))) continue;

                var matching_state: ?HostNodeStateDesc = null;
                for (self.active_stream.states.items) |state| {
                    if (state.node_id == site.node_id) {
                        matching_state = state;
                        break;
                    }
                }
                const state = matching_state orelse continue;
                if (retained_values.hostSignalTokenFromCallable(state.initial) != binder_token) continue;

                const depth = self.scopeDepth(site.scope_id);
                if (target_node_id == null or depth > target_depth) {
                    target_node_id = site.node_id;
                    target_depth = depth;
                }
            }

            return target_node_id orelse @panic("UpdateState referenced a state binder outside the command's active scope");
        }

        /// Evaluates scope is each site row descendant or self using explicit scope ownership rather than DOM position or content.
        pub fn scopeIsEachSiteRowDescendantOrSelf(self: *Self, scope_id: u64, site: HostEachSite) scope_tree.Error!bool {
            return scope_tree.eachSiteRowDescendantOrSelf(HostEachRowScopeStep, self.scopes.items, scope_id, site.parent_scope_id, site.site_ordinal);
        }

        /// Performs each diff preserves survivor render order inside the shared engine while preserving transaction and changed-set invariants.
        pub fn eachDiffPreservesSurvivorRenderOrder(old_render_rows: []const u64, next_scope_ids: []const u64) bool {
            return each_runtime.diffPreservesSurvivorRenderOrder(old_render_rows, next_scope_ids);
        }

        /// Returns active each row render segments in render order from the maintained active-runtime indexes.
        pub fn activeEachRowRenderSegmentsInRenderOrder(self: *Self, allocator: std.mem.Allocator, site: HostEachSite) []HostEachRowRenderSegment {
            var segments: std.ArrayListUnmanaged(HostEachRowRenderSegment) = .empty;
            errdefer segments.deinit(allocator);
            var segment_indexes_by_scope: std.AutoHashMapUnmanaged(u64, usize) = .{};
            defer segment_indexes_by_scope.deinit(allocator);

            self.recordStreamNodesScannedBy(.stream_nodes_scanned_render_scope, self.active_stream.render_nodes.items.len);
            var render_index: usize = 0;
            while (render_index < self.active_stream.render_nodes.items.len) {
                const node = self.active_stream.render_nodes.items[render_index];
                const scope_id = renderNodeScopeId(&self.active_stream, node);
                const row_scope_id = (self.eachSiteRowAncestorScopeId(scope_id, site) catch @panic("scope descriptor referenced an unknown parent scope")) orelse {
                    render_index += 1;
                    continue;
                };
                const start = render_index;
                render_index += 1;
                while (render_index < self.active_stream.render_nodes.items.len) : (render_index += 1) {
                    const next_node = self.active_stream.render_nodes.items[render_index];
                    const next_scope_id = renderNodeScopeId(&self.active_stream, next_node);
                    const next_row_scope_id = self.eachSiteRowAncestorScopeId(next_scope_id, site) catch @panic("scope descriptor referenced an unknown parent scope");
                    if (next_row_scope_id == null or next_row_scope_id.? != row_scope_id) break;
                }

                const segment_index = segments.items.len;
                segments.append(allocator, .{
                    .scope_id = row_scope_id,
                    .start = start,
                    .len = render_index - start,
                }) catch @panic("out of memory");
                const entry = segment_indexes_by_scope.getOrPut(allocator, row_scope_id) catch @panic("out of memory");
                if (!entry.found_existing) entry.value_ptr.* = segment_index;
            }

            return segments.toOwnedSlice(allocator) catch @panic("out of memory");
        }

        /// Performs each render segment scope ids inside the shared engine while preserving transaction and changed-set invariants.
        pub fn eachRenderSegmentScopeIds(allocator: std.mem.Allocator, segments: []const HostEachRowRenderSegment) []u64 {
            return each_runtime.renderSegmentScopeIds(allocator, segments);
        }

        /// Performs each diff is pure permutation inside the shared engine while preserving transaction and changed-set invariants.
        pub fn eachDiffIsPurePermutation(self: *Self, old_render_rows: []const u64, diff: HostKeyedRowDiffResult, dirty_source_node_ids: []const u64) bool {
            if (diff.rows_created != 0 or diff.rows_removed != 0) return false;
            if (diff.scope_ids.len != old_render_rows.len) return false;
            for (diff.scope_ids, diff.row_items_changed) |scope_id, row_item_changed| {
                if (row_item_changed) return false;
                if (!u64SliceContains(old_render_rows, scope_id)) return false;
                if (self.scopeSubtreeHasDirtyStructuralSource(&self.active_stream, scope_id, dirty_source_node_ids)) return false;
            }
            return true;
        }

        /// Applies dirty each permutation moves after preparation has fixed semantics and reserved fallible growth.
        pub fn applyDirtyEachPermutationMoves(self: *Self, ctx: Ctx.Handle, site: HostNodeScopeSiteDesc, next_scope_ids: []const u64) render.Counts {
            if (site.kind != .each) @panic("dirty each permutation move received a non-each site");

            const allocator = Ctx.allocator(ctx);
            const each_site = HostEachSite{ .parent_scope_id = site.scope_id, .site_ordinal = site.ordinal };
            var segments: std.ArrayListUnmanaged(HostEachRowRenderSegment) = .empty;
            defer segments.deinit(allocator);
            var segment_indexes_by_scope: std.AutoHashMapUnmanaged(u64, usize) = .{};
            defer segment_indexes_by_scope.deinit(allocator);

            var render_index: usize = 0;
            while (render_index < self.active_stream.render_nodes.items.len) {
                const node = self.active_stream.render_nodes.items[render_index];
                const scope_id = renderNodeScopeId(&self.active_stream, node);
                const row_scope_id = (self.eachSiteRowAncestorScopeId(scope_id, each_site) catch @panic("scope descriptor referenced an unknown parent scope")) orelse {
                    render_index += 1;
                    continue;
                };
                const start = render_index;
                render_index += 1;
                while (render_index < self.active_stream.render_nodes.items.len) : (render_index += 1) {
                    const next_node = self.active_stream.render_nodes.items[render_index];
                    const next_scope_id = renderNodeScopeId(&self.active_stream, next_node);
                    const next_row_scope_id = self.eachSiteRowAncestorScopeId(next_scope_id, each_site) catch @panic("scope descriptor referenced an unknown parent scope");
                    if (next_row_scope_id == null or next_row_scope_id.? != row_scope_id) break;
                }

                const segment_index = segments.items.len;
                segments.append(allocator, .{
                    .scope_id = row_scope_id,
                    .start = start,
                    .len = render_index - start,
                }) catch @panic("out of memory");
                const entry = segment_indexes_by_scope.getOrPut(allocator, row_scope_id) catch @panic("out of memory");
                if (entry.found_existing) @panic("each row render nodes were split across multiple segments");
                entry.value_ptr.* = segment_index;
            }

            if (segments.items.len != next_scope_ids.len) @panic("pure each permutation did not cover every rendered row");
            if (segments.items.len == 0) return .{};

            const region_start = segments.items[0].start;
            var expected_start = region_start;
            var total_len: usize = 0;
            for (segments.items) |segment| {
                if (segment.start != expected_start) @panic("each row render segments were not contiguous");
                expected_start += segment.len;
                total_len += segment.len;
            }

            var moves_by_scope: std.AutoHashMapUnmanaged(u64, HostEachRowRenderMove) = .{};
            defer moves_by_scope.deinit(allocator);
            const reordered_nodes = allocator.alloc(HostRenderNode, total_len) catch @panic("out of memory");
            defer allocator.free(reordered_nodes);

            var write_index: usize = 0;
            for (next_scope_ids) |scope_id| {
                const segment_index = segment_indexes_by_scope.get(scope_id) orelse @panic("pure each permutation referenced a row without render nodes");
                const segment = segments.items[segment_index];
                const next_start = region_start + write_index;
                @memcpy(reordered_nodes[write_index..][0..segment.len], self.active_stream.render_nodes.items[segment.start..][0..segment.len]);
                moves_by_scope.put(allocator, scope_id, .{
                    .old_start = segment.start,
                    .new_start = next_start,
                    .len = segment.len,
                }) catch @panic("out of memory");
                write_index += segment.len;
            }

            if (write_index != total_len) @panic("pure each permutation wrote the wrong render-node count");
            @memcpy(self.active_stream.render_nodes.items[region_start..][0..total_len], reordered_nodes);

            var reordered_region_children: std.ArrayListUnmanaged(u64) = .empty;
            defer reordered_region_children.deinit(allocator);
            for (self.active_stream.render_nodes.items[region_start..][0..total_len]) |node| {
                if (renderNodeParentElemId(&self.active_stream, node) == site.parent_elem_id) {
                    reordered_region_children.append(allocator, node.elem_id) catch @panic("out of memory");
                }
            }

            var reordered_parent_children: std.ArrayListUnmanaged(u64) = .empty;
            defer reordered_parent_children.deinit(allocator);
            var inserted_region = false;
            const region_end = region_start + total_len;
            const old_parent_children = streamDirectChildrenInto(allocator, &self.active_stream, site.parent_elem_id, &self.scratch.stream_direct_children);
            for (old_parent_children) |child_id| {
                const child_render_index = self.active_stream.renderNodeIndex(child_id) orelse @panic("parent child had no render index");
                const child_in_region = child_render_index >= region_start and child_render_index < region_end;
                if (child_in_region) {
                    if (!inserted_region) {
                        reordered_parent_children.appendSlice(allocator, reordered_region_children.items) catch @panic("out of memory");
                        inserted_region = true;
                    }
                    continue;
                }
                reordered_parent_children.append(allocator, child_id) catch @panic("out of memory");
            }
            if (!inserted_region and reordered_region_children.items.len != 0) {
                reordered_parent_children.appendSlice(allocator, reordered_region_children.items) catch @panic("out of memory");
            }
            self.active_stream.replaceRenderChildrenIndex(allocator, site.parent_elem_id, reordered_parent_children.items);
            self.active_stream.refreshRenderIndexesInRange(allocator, region_start, total_len, &self.pending_roc_metrics);

            for (self.active_stream.scope_sites.items) |*scope_site| {
                const row_scope_id = (self.eachSiteRowAncestorScopeId(scope_site.scope_id, each_site) catch @panic("scope descriptor referenced an unknown parent scope")) orelse continue;
                const move = moves_by_scope.get(row_scope_id) orelse @panic("scope site referenced a row missing from pure each permutation");
                if (scope_site.render_insert_index < move.old_start) @panic("scope site insertion point preceded its row render segment");
                const offset = scope_site.render_insert_index - move.old_start;
                if (offset > move.len) @panic("scope site insertion point exceeded its row render segment");
                scope_site.render_insert_index = move.new_start + offset;
            }

            var counts: render.Counts = .{};
            const children = streamDirectChildrenInto(allocator, &self.active_stream, site.parent_elem_id, &self.scratch.stream_direct_children);
            self.replaceRenderChildrenForMoves(ctx, site.parent_elem_id, children, &counts);
            if (comptime enable_runtime_metrics) self.render_metrics.addCommandCounts(counts);
            return counts;
        }

        /// Performs render insert index for each row ranges inside the shared engine while preserving transaction and changed-set invariants.
        pub fn renderInsertIndexForEachRowRanges(site: HostNodeScopeSiteDesc, row_ranges: *const std.AutoHashMapUnmanaged(u64, HostEachRowRenderSegment), next_scope_ids: []const u64, row_index: usize) usize {
            return each_runtime.renderInsertIndexForRowRanges(site.render_insert_index, row_ranges, next_scope_ids, row_index);
        }

        /// Performs render append index for each row ranges inside the shared engine while preserving transaction and changed-set invariants.
        pub fn renderAppendIndexForEachRowRanges(site: HostNodeScopeSiteDesc, row_ranges: *const std.AutoHashMapUnmanaged(u64, HostEachRowRenderSegment)) usize {
            var append_index = site.render_insert_index;
            var range_iterator = row_ranges.iterator();
            while (range_iterator.next()) |entry| {
                append_index = @max(append_index, entry.value_ptr.start + entry.value_ptr.len);
            }
            return append_index;
        }

        /// Performs child insertion index for each row ranges inside the shared engine while preserving transaction and changed-set invariants.
        pub fn childInsertionIndexForEachRowRanges(self: *Self, allocator: std.mem.Allocator, site: HostNodeScopeSiteDesc, row_ranges: *const std.AutoHashMapUnmanaged(u64, HostEachRowRenderSegment), render_insert_index: usize) usize {
            const each_site = HostEachSite{ .parent_scope_id = site.scope_id, .site_ordinal = site.ordinal };
            const children = streamDirectChildrenInto(allocator, &self.active_stream, site.parent_elem_id, &self.scratch.stream_direct_children);

            var child_index: usize = 0;
            for (children) |child_id| {
                const child_scope_id = elemScopeId(&self.active_stream, child_id) orelse @panic("each row child had no scope");
                const row_scope_id = (self.eachSiteRowAncestorScopeId(child_scope_id, each_site) catch @panic("scope descriptor referenced an unknown parent scope")) orelse continue;
                const range = row_ranges.get(row_scope_id) orelse @panic("each row child had no render range");
                if (range.start >= render_insert_index) break;
                child_index += 1;
            }
            return child_index;
        }

        /// Performs each site parent has only row children inside the shared engine while preserving transaction and changed-set invariants.
        pub fn eachSiteParentHasOnlyRowChildren(self: *Self, allocator: std.mem.Allocator, site: HostNodeScopeSiteDesc, old_render_segments: []const HostEachRowRenderSegment) bool {
            const each_site = HostEachSite{ .parent_scope_id = site.scope_id, .site_ordinal = site.ordinal };
            const children = streamDirectChildrenInto(allocator, &self.active_stream, site.parent_elem_id, &self.scratch.stream_direct_children);
            if (children.len != old_render_segments.len) return false;

            for (children, old_render_segments) |child_id, segment| {
                const child_scope_id = elemScopeId(&self.active_stream, child_id) orelse return false;
                const row_scope_id = (self.eachSiteRowAncestorScopeId(child_scope_id, each_site) catch @panic("scope descriptor referenced an unknown parent scope")) orelse return false;
                if (row_scope_id != segment.scope_id) return false;
            }
            return true;
        }

        /// Performs adjust each row render ranges inside the shared engine while preserving transaction and changed-set invariants.
        pub fn adjustEachRowRenderRanges(row_ranges: *std.AutoHashMapUnmanaged(u64, HostEachRowRenderSegment), replace_index: usize, removed_count: usize, replacement_count: usize) void {
            each_runtime.adjustRenderRanges(row_ranges, replace_index, removed_count, replacement_count);
        }

        /// Performs update each row render range inside the shared engine while preserving transaction and changed-set invariants.
        pub fn updateEachRowRenderRange(row_ranges: *std.AutoHashMapUnmanaged(u64, HostEachRowRenderSegment), allocator: std.mem.Allocator, scope_id: u64, render_insert_index: usize, removed_count: usize, replacement_count: usize) void {
            each_runtime.updateRenderRange(row_ranges, allocator, scope_id, render_insert_index, removed_count, replacement_count);
        }

        /// Applies dirty each row scope splices after preparation has fixed semantics and reserved fallible growth.
        pub fn applyDirtyEachRowScopeSplices(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, site: HostNodeScopeSiteDesc, each: HostNodeEachDesc, old_render_segments: []const HostEachRowRenderSegment, diff: HostKeyedRowDiffResult, append_created_rows_for_later_moves: bool, dirty_source_node_ids: []const u64, dirty_generation: u64) render.Counts {
            const allocator = Ctx.allocator(ctx);
            var row_ranges = &self.scratch.each_row_ranges;
            row_ranges.clearRetainingCapacity();
            defer row_ranges.clearRetainingCapacity();
            for (old_render_segments) |segment| {
                const entry = row_ranges.getOrPut(allocator, segment.scope_id) catch @panic("out of memory");
                if (entry.found_existing) @panic("each row render range index received duplicate row scopes");
                entry.value_ptr.* = segment;
            }

            var removed_elem_ids = &self.scratch.each_removed_elem_ids;
            removed_elem_ids.clearRetainingCapacity();
            defer removed_elem_ids.clearRetainingCapacity();
            var touched_parent_ids = &self.scratch.each_touched_parent_ids;
            touched_parent_ids.clearRetainingCapacity();
            defer touched_parent_ids.clearRetainingCapacity();
            var replacement_elem_ids = &self.scratch.each_replacement_elem_ids;
            replacement_elem_ids.clearRetainingCapacity();
            defer replacement_elem_ids.clearRetainingCapacity();
            var moved_event_elem_ids = &self.scratch.each_moved_event_elem_ids;
            moved_event_elem_ids.clearRetainingCapacity();
            defer moved_event_elem_ids.clearRetainingCapacity();
            var replacement_on_change_indices = &self.scratch.each_replacement_on_change_indices;
            replacement_on_change_indices.clearRetainingCapacity();
            defer replacement_on_change_indices.clearRetainingCapacity();
            var replacement_mount_indices = &self.scratch.each_replacement_mount_indices;
            replacement_mount_indices.clearRetainingCapacity();
            defer replacement_mount_indices.clearRetainingCapacity();
            const defer_render_index_suffixes = self.eachSiteParentHasOnlyRowChildren(allocator, site, old_render_segments);
            var deferred_render_index_refresh_start: ?usize = null;
            var spliced_any = false;

            for (diff.removed_scope_ids) |removed_scope_id| {
                var empty_stream: HostNodeDescriptorStream = .{};
                const removed_range = row_ranges.get(removed_scope_id);
                const render_insert_index = if (removed_range) |range| range.start else site.render_insert_index;
                const splice = if (defer_render_index_suffixes)
                    self.spliceActiveStreamReplacingScopeWithOptions(ctx, roc_host, removed_scope_id, render_insert_index, &empty_stream, null, false)
                else
                    self.spliceActiveStreamReplacingScope(ctx, roc_host, removed_scope_id, render_insert_index, &empty_stream);
                defer splice.deinit(allocator);
                if (defer_render_index_suffixes and splice.removed_elem_ids.len != splice.replacement_elem_ids.len) {
                    const suffix_start = render_insert_index + splice.replacement_elem_ids.len;
                    deferred_render_index_refresh_start = if (deferred_render_index_refresh_start) |start| @min(start, suffix_start) else suffix_start;
                }
                updateEachRowRenderRange(row_ranges, allocator, removed_scope_id, render_insert_index, splice.removed_elem_ids.len, splice.replacement_elem_ids.len);

                removed_elem_ids.appendSlice(allocator, splice.removed_elem_ids) catch @panic("out of memory");
                for (splice.touched_parent_ids) |parent_id| {
                    appendUniqueU64(allocator, touched_parent_ids, parent_id);
                }
                replacement_elem_ids.appendSlice(allocator, splice.replacement_elem_ids) catch @panic("out of memory");
                for (splice.moved_event_elem_ids) |elem_id| {
                    appendUniqueU64(allocator, moved_event_elem_ids, elem_id);
                }
                replacement_on_change_indices.appendSlice(allocator, splice.replacement_on_change_indices) catch @panic("out of memory");
                replacement_mount_indices.appendSlice(allocator, splice.replacement_mount_indices) catch @panic("out of memory");
                spliced_any = true;
            }

            // Removing every old row can shift this each site's insertion point
            // before replacement rows are collected. Other diffs must retain the
            // descriptor supplied by the dirty-source pass: a newly mounted outer
            // branch can temporarily reuse the node id of an older active site.
            const insertion_site = if (diff.removed_scope_ids.len != 0 and row_ranges.count() == 0)
                self.activeScopeSiteByNodeId(site.node_id, .each) orelse @panic("active each site disappeared after removing every row")
            else
                site;

            for (diff.scope_ids, diff.row_items_changed, diff.scope_created, 0..) |row_scope_id, row_item_changed, row_created, row_index| {
                if (!row_item_changed and !self.scopeSubtreeHasDirtyStructuralSource(&self.active_stream, row_scope_id, dirty_source_node_ids)) {
                    continue;
                }

                var row_stream: HostNodeDescriptorStream = .{};
                defer row_stream.deinit(allocator, ctx, roc_host, &self.pending_roc_metrics);
                self.collectActiveEachSingleRowDescriptors(ctx, roc_host, &row_stream, site, each, row_scope_id, row_created, dirty_source_node_ids);

                const append_created_row = append_created_rows_for_later_moves and defer_render_index_suffixes and row_created;
                const render_insert_index = if (append_created_row)
                    renderAppendIndexForEachRowRanges(insertion_site, row_ranges)
                else
                    renderInsertIndexForEachRowRanges(insertion_site, row_ranges, diff.scope_ids, row_index);
                const splice = if (defer_render_index_suffixes) splice: {
                    const child_insertion_index = self.childInsertionIndexForEachRowRanges(allocator, insertion_site, row_ranges, render_insert_index);
                    const child_insert_hint = HostRenderChildInsertHint{
                        .parent_elem_id = insertion_site.parent_elem_id,
                        .insertion_index = child_insertion_index,
                    };
                    break :splice self.spliceActiveStreamReplacingScopeWithOptions(ctx, roc_host, row_scope_id, render_insert_index, &row_stream, child_insert_hint, false);
                } else self.spliceActiveStreamReplacingScope(ctx, roc_host, row_scope_id, render_insert_index, &row_stream);
                defer splice.deinit(allocator);
                if (defer_render_index_suffixes and splice.removed_elem_ids.len != splice.replacement_elem_ids.len) {
                    const suffix_start = render_insert_index + splice.replacement_elem_ids.len;
                    deferred_render_index_refresh_start = if (deferred_render_index_refresh_start) |start| @min(start, suffix_start) else suffix_start;
                }
                updateEachRowRenderRange(row_ranges, allocator, row_scope_id, render_insert_index, splice.removed_elem_ids.len, splice.replacement_elem_ids.len);

                removed_elem_ids.appendSlice(allocator, splice.removed_elem_ids) catch @panic("out of memory");
                for (splice.touched_parent_ids) |parent_id| {
                    appendUniqueU64(allocator, touched_parent_ids, parent_id);
                }
                replacement_elem_ids.appendSlice(allocator, splice.replacement_elem_ids) catch @panic("out of memory");
                for (splice.moved_event_elem_ids) |elem_id| {
                    appendUniqueU64(allocator, moved_event_elem_ids, elem_id);
                }
                replacement_on_change_indices.appendSlice(allocator, splice.replacement_on_change_indices) catch @panic("out of memory");
                replacement_mount_indices.appendSlice(allocator, splice.replacement_mount_indices) catch @panic("out of memory");
                spliced_any = true;
            }

            if (!spliced_any) return .{};
            if (defer_render_index_suffixes) {
                if (deferred_render_index_refresh_start) |refresh_start| {
                    self.active_stream.refreshRenderIndexesFrom(allocator, refresh_start, &self.pending_roc_metrics);
                }
            }

            const merged_splice = HostStructuralSplice{
                .removed_elem_ids = removed_elem_ids.items,
                .touched_parent_ids = touched_parent_ids.items,
                .replacement_elem_ids = replacement_elem_ids.items,
                .moved_event_elem_ids = moved_event_elem_ids.items,
                .replacement_on_change_indices = replacement_on_change_indices.items,
                .replacement_mount_indices = replacement_mount_indices.items,
            };
            const target = HostStructuralReplacementTarget{ .each_site = .{ .parent_scope_id = site.scope_id, .site_ordinal = site.ordinal } };
            return self.applySplicedStructuralNodeDescriptorTarget(ctx, roc_host, merged_splice, .{
                .removed = target,
                .replacement = target,
            }, dirty_source_node_ids, dirty_generation);
        }

        /// Applies dirty each mixed row splices and moves after preparation has fixed semantics and reserved fallible growth.
        pub fn applyDirtyEachMixedRowSplicesAndMoves(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, site: HostNodeScopeSiteDesc, each: HostNodeEachDesc, old_render_segments: []const HostEachRowRenderSegment, diff: HostKeyedRowDiffResult, dirty_source_node_ids: []const u64, dirty_generation: u64) render.Counts {
            var counts = self.applyDirtyEachRowScopeSplices(ctx, roc_host, site, each, old_render_segments, diff, true, dirty_source_node_ids, dirty_generation);
            counts.addAll(self.applyDirtyEachPermutationMoves(ctx, site, diff.scope_ids));
            return counts;
        }

        /// Performs eval on change initial inside the shared engine while preserving transaction and changed-set invariants.
        pub fn evalOnChangeInitial(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, desc: *HostNodeOnChangeDesc) void {
            const value = self.evalHostSignalBinding(ctx, roc_host, &desc.signal);
            desc.cached_value.replace(ctx, roc_host, &self.pending_roc_metrics, value, self.hostSignalBindingCapability(ctx, &desc.signal));
        }

        /// Performs eval on change initial command inside the shared engine while preserving transaction and changed-set invariants.
        pub fn evalOnChangeInitialCommand(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, desc: *HostNodeOnChangeDesc) render.Counts {
            const pending = self.evalOnChangeInitialPendingCommand(ctx, roc_host, desc) orelse return .{};
            defer pending.cmd.decref(roc_host);
            return self.runCommand(ctx, roc_host, pending.scope_id, pending.cmd);
        }

        fn evalOnChangeInitialPendingCommand(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, desc: *HostNodeOnChangeDesc) ?HostPendingOnChangeCommand {
            if (!desc.run_initial_pending) return null;
            desc.run_initial_pending = false;

            const cap = self.hostSignalBindingCapability(ctx, &desc.signal);
            const value = self.cloneCachedSignalValue(ctx, &desc.cached_value);
            defer callHostValueToUnitWithCapability(ctx, roc_host, cap, hv.hostValueCapabilityDrop(cap), value);

            const cmd = callHostValueToCmdWithCapability(ctx, roc_host, cap, desc.to_cmd, value);
            cmd.incref(1);
            cmd.decref(roc_host);
            return .{ .scope_id = desc.scope_id, .cmd = cmd };
        }

        fn runPendingOnChangeCommands(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, pending_commands: []const HostPendingOnChangeCommand) render.Counts {
            var counts: render.Counts = .{};
            for (pending_commands) |pending| {
                counts.addAll(self.runCommand(ctx, roc_host, pending.scope_id, pending.cmd));
            }
            return counts;
        }

        /// Runs active on change initial command indices using the host semantics and measurement boundaries defined by this module.
        pub fn runActiveOnChangeInitialCommandIndices(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, indices: []const usize) render.Counts {
            const allocator = Ctx.allocator(ctx);
            var pending_commands: std.ArrayListUnmanaged(HostPendingOnChangeCommand) = .empty;
            defer {
                for (pending_commands.items) |pending| pending.cmd.decref(roc_host);
                pending_commands.deinit(allocator);
            }

            self.recordStreamNodesScannedBy(.stream_nodes_scanned_on_change, indices.len);
            for (indices) |on_change_index| {
                if (on_change_index >= self.active_stream.on_changes.items.len) @panic("on_change descriptor index exceeded active descriptor stream");
                if (self.evalOnChangeInitialPendingCommand(ctx, roc_host, &self.active_stream.on_changes.items[on_change_index])) |pending| {
                    pending_commands.append(allocator, pending) catch @panic("out of memory");
                }
            }
            return self.runPendingOnChangeCommands(ctx, roc_host, pending_commands.items);
        }

        /// Runs active on change initial commands using the host semantics and measurement boundaries defined by this module.
        pub fn runActiveOnChangeInitialCommands(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost) render.Counts {
            const allocator = Ctx.allocator(ctx);
            var pending_commands: std.ArrayListUnmanaged(HostPendingOnChangeCommand) = .empty;
            defer {
                for (pending_commands.items) |pending| pending.cmd.decref(roc_host);
                pending_commands.deinit(allocator);
            }

            self.recordStreamNodesScannedBy(.stream_nodes_scanned_on_change, self.active_stream.on_changes.items.len);
            for (self.active_stream.on_changes.items) |*desc| {
                if (self.evalOnChangeInitialPendingCommand(ctx, roc_host, desc)) |pending| {
                    pending_commands.append(allocator, pending) catch @panic("out of memory");
                }
            }
            return self.runPendingOnChangeCommands(ctx, roc_host, pending_commands.items);
        }

        /// Performs eval mount command inside the shared engine while preserving transaction and changed-set invariants.
        pub fn evalMountCommand(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, desc: *HostNodeMountDesc) render.Counts {
            if (!desc.run_on_mount) return .{};
            desc.run_on_mount = false;

            const cmd = erased_calls.callUnitToCmd(roc_host, desc.to_cmd);
            defer cmd.decref(roc_host);
            return self.runCommand(ctx, roc_host, desc.scope_id, cmd);
        }

        /// Runs active mount command indices using the host semantics and measurement boundaries defined by this module.
        pub fn runActiveMountCommandIndices(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, indices: []const usize) render.Counts {
            var counts: render.Counts = .{};
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_mounts, indices.len);
            for (indices) |mount_index| {
                if (mount_index >= self.active_stream.mounts.items.len) @panic("mount descriptor index exceeded active descriptor stream");
                counts.addAll(self.evalMountCommand(ctx, roc_host, &self.active_stream.mounts.items[mount_index]));
            }
            return counts;
        }

        /// Runs active mount commands using the host semantics and measurement boundaries defined by this module.
        pub fn runActiveMountCommands(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost) render.Counts {
            var counts: render.Counts = .{};
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_mounts, self.active_stream.mounts.items.len);
            for (self.active_stream.mounts.items) |*desc| {
                counts.addAll(self.evalMountCommand(ctx, roc_host, desc));
            }
            return counts;
        }

        /// Applies structural event bindings after preparation has fixed semantics and reserved fallible growth.
        pub fn applyStructuralEventBindings(self: *Self, ctx: Ctx.Handle, stream: *const HostNodeDescriptorStream, seen: []const bool, counts: *render.Counts) void {
            if (firstEventDescriptorElemOutsideSeen(stream, seen) != null) {
                @panic("event descriptor referenced element outside structural render stream");
            }
            for (seen, 0..) |is_seen, index| {
                if (index == 0 or !is_seen) continue;

                for (render_event_kinds) |kind| {
                    const next_binding = fixedEventBindingForElemKind(stream, @intCast(index), kind);
                    self.applyRenderEventBinding(ctx, @intCast(index), kind, next_binding, counts);
                }
                self.applyStructuralNamedEventBindingsForElem(ctx, stream, @intCast(index), counts);
            }
        }

        /// Applies structural event bindings for seen after preparation has fixed semantics and reserved fallible growth.
        pub fn applyStructuralEventBindingsForSeen(self: *Self, ctx: Ctx.Handle, stream: *const HostNodeDescriptorStream, seen: []const bool, counts: *render.Counts) void {
            for (seen, 0..) |is_seen, index| {
                if (index == 0 or !is_seen) continue;

                for (render_event_kinds) |kind| {
                    const next_binding = fixedEventBindingForElemKind(stream, @intCast(index), kind);
                    self.applyRenderEventBinding(ctx, @intCast(index), kind, next_binding, counts);
                }
                self.applyStructuralNamedEventBindingsForElem(ctx, stream, @intCast(index), counts);
            }
        }

        /// Performs fixed event binding for elem kind inside the shared engine while preserving transaction and changed-set invariants.
        pub fn fixedEventBindingForElemKind(stream: *const HostNodeDescriptorStream, elem_id: u64, kind: RenderEventKind) ?HostRequiredEventBinding {
            const descriptor_index = stream.elemDescriptorIndex(elem_id) orelse return null;
            const event_index = descriptor_index.events.get(kind) orelse return null;
            if (event_index >= stream.events.items.len) @panic("event descriptor index exceeded descriptor table");
            const desc = stream.events.items[event_index];
            const fixed_kind = desc.fixedKind() orelse @panic("fixed event descriptor index pointed at a named event");
            if (desc.elem_id != elem_id or fixed_kind != kind) @panic("fixed event descriptor index pointed at the wrong event");
            return .{ .event_id = @intCast(event_index + 1), .delivery = .{ .requested = desc.delivery_request }, .payload_descriptor = desc.payload_descriptor };
        }

        /// Performs named event binding for elem name inside the shared engine while preserving transaction and changed-set invariants.
        pub fn namedEventBindingForElemName(stream: *const HostNodeDescriptorStream, elem_id: u64, name: []const u8) ?HostRequiredEventBinding {
            for (stream.namedEventIndices(elem_id)) |index| {
                if (index >= stream.events.items.len) @panic("named event index exceeded descriptor table");
                const desc = stream.events.items[index];
                const binding = desc.named() orelse @panic("named event index pointed at a fixed event descriptor");
                if (desc.elem_id == elem_id and std.mem.eql(u8, binding.name, name)) {
                    return .{
                        .event_id = @intCast(index + 1),
                        .policy = binding.policy,
                        .delivery = .{ .requested = binding.delivery_request },
                        .payload_descriptor = desc.payload_descriptor,
                    };
                }
            }
            return null;
        }

        /// Applies structural named event bindings for elem after preparation has fixed semantics and reserved fallible growth.
        pub fn applyStructuralNamedEventBindingsForElem(self: *Self, ctx: Ctx.Handle, stream: *const HostNodeDescriptorStream, elem_id: u64, counts: *render.Counts) void {
            var cache_index: usize = 0;
            while (self.render_cache.namedEventNameAt(elem_id, cache_index)) |name| {
                if (namedEventBindingForElemName(stream, elem_id, name) == null) {
                    self.applyRenderNamedEventBinding(ctx, elem_id, name, null, counts);
                    continue;
                }
                cache_index += 1;
            }

            const named_event_indices = stream.namedEventIndices(elem_id);
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_events, named_event_indices.len);
            for (named_event_indices) |index| {
                if (index >= stream.events.items.len) @panic("named event index exceeded descriptor table");
                const desc = stream.events.items[index];
                const binding = desc.named() orelse @panic("named event index pointed at a fixed event descriptor");
                if (desc.elem_id != elem_id) @panic("named event index pointed at the wrong element");
                const event_id: u64 = @intCast(index + 1);
                self.applyRenderNamedEventBinding(ctx, elem_id, binding.name, .{
                    .event_id = event_id,
                    .policy = binding.policy,
                    .delivery = .{ .requested = binding.delivery_request },
                    .payload_descriptor = desc.payload_descriptor,
                }, counts);
            }
        }

        /// Returns active event binding for elem kind from the maintained active-runtime indexes.
        pub fn activeEventBindingForElemKind(self: *Self, elem_id: u64, kind: RenderEventKind) ?HostRequiredEventBinding {
            const descriptor_index = self.active_stream.elemDescriptorIndex(elem_id) orelse return null;
            const event_index = descriptor_index.events.get(kind) orelse return null;
            if (event_index >= self.active_stream.events.items.len) @panic("active event descriptor index exceeded descriptor table");
            const desc = self.active_stream.events.items[event_index];
            const fixed_kind = desc.fixedKind() orelse @panic("active fixed event descriptor index pointed at a named event");
            if (desc.elem_id != elem_id or fixed_kind != kind) @panic("active event descriptor index pointed at the wrong event");
            return .{ .event_id = @intCast(event_index + 1), .delivery = .{ .requested = desc.delivery_request }, .payload_descriptor = desc.payload_descriptor };
        }

        /// Applies structural event bindings for elem after preparation has fixed semantics and reserved fallible growth.
        pub fn applyStructuralEventBindingsForElem(self: *Self, ctx: Ctx.Handle, elem_id: u64, counts: *render.Counts) void {
            for (render_event_kinds) |kind| {
                const next_binding = self.activeEventBindingForElemKind(elem_id, kind);
                self.applyRenderEventBinding(ctx, elem_id, kind, next_binding, counts);
            }
            self.applyStructuralNamedEventBindingsForElem(ctx, &self.active_stream, elem_id, counts);
        }

        /// Applies active stream event bindings after preparation has fixed semantics and reserved fallible growth.
        pub fn applyActiveStreamEventBindings(self: *Self, ctx: Ctx.Handle, counts: *render.Counts) void {
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_events, self.active_stream.render_nodes.items.len);
            for (self.active_stream.render_nodes.items) |node| {
                if (node.kind != .element) continue;
                self.applyStructuralEventBindingsForElem(ctx, node.elem_id, counts);
            }
        }

        /// Applies active stream text attr for elem after preparation has fixed semantics and reserved fallible growth.
        pub fn applyActiveStreamTextAttrForElem(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, elem_id: u64, field: RenderTextField, descriptor_index: HostElemDescriptorIndex, counts: *render.Counts, dirty_source_node_ids: []const u64, dirty_generation: u64) void {
            if (descriptor_index.static_text_attrs.get(field)) |attr_index| {
                if (attr_index >= self.active_stream.static_text_attrs.items.len) @panic("active static text attr index exceeded descriptor table");
                const desc = self.active_stream.static_text_attrs.items[attr_index];
                if (desc.elem_id != elem_id or desc.field != field) @panic("active static text attr index pointed at the wrong field");
                if (self.applyRenderTextField(ctx, desc.elem_id, desc.field, desc.value)) {
                    counts.addTextField(desc.field);
                }
            }

            if (descriptor_index.signal_text_attrs.get(field)) |attr_index| {
                if (attr_index >= self.active_stream.signal_text_attrs.items.len) @panic("active signal text attr index exceeded descriptor table");
                const desc = &self.active_stream.signal_text_attrs.items[attr_index];
                if (desc.elem_id != elem_id or desc.field != field) @panic("active signal text attr index pointed at the wrong field");
                if (self.evalStructuralSignalTextField(ctx, roc_host, desc.elem_id, desc.field, &desc.signal, desc.read, &desc.cached_value, dirty_source_node_ids, dirty_generation)) {
                    counts.addTextField(desc.field);
                }
            }
        }

        /// Clears render text attrs missing from stream while retaining bounded storage where the type promises reuse.
        pub fn clearRenderTextAttrsMissingFromStream(self: *Self, ctx: Ctx.Handle, stream: *const HostNodeDescriptorStream, elem_id: u64, counts: *render.Counts) void {
            var index: usize = 0;
            while (self.render_cache.customTextAttrNameAt(elem_id, index)) |name| {
                if (streamHasCustomTextAttr(stream, elem_id, name)) {
                    index += 1;
                    continue;
                }
                if (self.clearRenderTextAttr(ctx, elem_id, name)) {
                    counts.addTextAttr();
                }
            }
        }

        /// Applies active stream custom text attrs for elem after preparation has fixed semantics and reserved fallible growth.
        pub fn applyActiveStreamCustomTextAttrsForElem(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, elem_id: u64, counts: *render.Counts, dirty_source_node_ids: []const u64, dirty_generation: u64) void {
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_apply, self.active_stream.static_custom_text_attrs.items.len);
            for (self.active_stream.static_custom_text_attrs.items) |desc| {
                if (desc.elem_id != elem_id) continue;
                if (self.applyRenderTextAttr(ctx, desc.elem_id, desc.name, desc.value)) {
                    counts.addTextAttr();
                }
            }

            self.recordStreamNodesScannedBy(.stream_nodes_scanned_apply, self.active_stream.signal_custom_text_attrs.items.len);
            for (self.active_stream.signal_custom_text_attrs.items) |*desc| {
                if (desc.elem_id != elem_id) continue;
                if (self.evalStructuralSignalTextAttr(ctx, roc_host, desc.elem_id, desc.name, &desc.signal, desc.read, &desc.cached_value, dirty_source_node_ids, dirty_generation)) {
                    counts.addTextAttr();
                }
            }

            self.recordStreamNodesScannedBy(.stream_nodes_scanned_apply, self.active_stream.signal_optional_custom_text_attrs.items.len);
            for (self.active_stream.signal_optional_custom_text_attrs.items) |*desc| {
                if (desc.elem_id != elem_id) continue;
                if (self.evalStructuralSignalOptionalTextAttr(ctx, roc_host, desc.elem_id, desc.name, &desc.signal, desc.present, desc.read, &desc.cached_value, dirty_source_node_ids, dirty_generation)) {
                    counts.addTextAttr();
                }
            }

            self.recordStreamNodesScannedBy(.stream_nodes_scanned_apply, self.active_stream.static_custom_bool_attrs.items.len);
            for (self.active_stream.static_custom_bool_attrs.items) |desc| {
                if (desc.elem_id != elem_id) continue;
                if (self.applyRenderBoolAttr(ctx, desc.elem_id, desc.name, desc.value)) {
                    counts.addTextAttr();
                }
            }

            self.recordStreamNodesScannedBy(.stream_nodes_scanned_apply, self.active_stream.signal_custom_bool_attrs.items.len);
            for (self.active_stream.signal_custom_bool_attrs.items) |*desc| {
                if (desc.elem_id != elem_id) continue;
                if (self.evalStructuralSignalBoolAttr(ctx, roc_host, desc.elem_id, desc.name, &desc.signal, desc.read, &desc.cached_value, dirty_source_node_ids, dirty_generation)) {
                    counts.addTextAttr();
                }
            }
        }

        fn applyActiveStreamCustomAttrsForElemSet(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, seen: []const bool, counts: *render.Counts, dirty_source_node_ids: []const u64, dirty_generation: u64) void {
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_apply, self.active_stream.static_custom_text_attrs.items.len);
            for (self.active_stream.static_custom_text_attrs.items) |desc| {
                if (desc.elem_id >= seen.len or !seen[@intCast(desc.elem_id)]) continue;
                if (self.applyRenderTextAttr(ctx, desc.elem_id, desc.name, desc.value)) counts.addTextAttr();
            }
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_apply, self.active_stream.signal_custom_text_attrs.items.len);
            for (self.active_stream.signal_custom_text_attrs.items) |*desc| {
                if (desc.elem_id >= seen.len or !seen[@intCast(desc.elem_id)]) continue;
                if (self.evalStructuralSignalTextAttr(ctx, roc_host, desc.elem_id, desc.name, &desc.signal, desc.read, &desc.cached_value, dirty_source_node_ids, dirty_generation)) counts.addTextAttr();
            }
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_apply, self.active_stream.signal_optional_custom_text_attrs.items.len);
            for (self.active_stream.signal_optional_custom_text_attrs.items) |*desc| {
                if (desc.elem_id >= seen.len or !seen[@intCast(desc.elem_id)]) continue;
                if (self.evalStructuralSignalOptionalTextAttr(ctx, roc_host, desc.elem_id, desc.name, &desc.signal, desc.present, desc.read, &desc.cached_value, dirty_source_node_ids, dirty_generation)) counts.addTextAttr();
            }
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_apply, self.active_stream.static_custom_bool_attrs.items.len);
            for (self.active_stream.static_custom_bool_attrs.items) |desc| {
                if (desc.elem_id >= seen.len or !seen[@intCast(desc.elem_id)]) continue;
                if (self.applyRenderBoolAttr(ctx, desc.elem_id, desc.name, desc.value)) counts.addTextAttr();
            }
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_apply, self.active_stream.signal_custom_bool_attrs.items.len);
            for (self.active_stream.signal_custom_bool_attrs.items) |*desc| {
                if (desc.elem_id >= seen.len or !seen[@intCast(desc.elem_id)]) continue;
                if (self.evalStructuralSignalBoolAttr(ctx, roc_host, desc.elem_id, desc.name, &desc.signal, desc.read, &desc.cached_value, dirty_source_node_ids, dirty_generation)) counts.addTextAttr();
            }
        }

        /// Applies active stream bool attr for elem after preparation has fixed semantics and reserved fallible growth.
        pub fn applyActiveStreamBoolAttrForElem(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, elem_id: u64, field: RenderBoolField, descriptor_index: HostElemDescriptorIndex, counts: *render.Counts, dirty_source_node_ids: []const u64, dirty_generation: u64) void {
            if (descriptor_index.static_bool_attrs.get(field)) |attr_index| {
                if (attr_index >= self.active_stream.static_bool_attrs.items.len) @panic("active static bool attr index exceeded descriptor table");
                const desc = self.active_stream.static_bool_attrs.items[attr_index];
                if (desc.elem_id != elem_id or desc.field != field) @panic("active static bool attr index pointed at the wrong field");
                if (self.applyRenderBoolField(ctx, desc.elem_id, desc.field, desc.value)) {
                    counts.addBoolField(desc.field);
                }
            }

            if (descriptor_index.signal_bool_attrs.get(field)) |attr_index| {
                if (attr_index >= self.active_stream.signal_bool_attrs.items.len) @panic("active signal bool attr index exceeded descriptor table");
                const desc = &self.active_stream.signal_bool_attrs.items[attr_index];
                if (desc.elem_id != elem_id or desc.field != field) @panic("active signal bool attr index pointed at the wrong field");
                if (self.evalStructuralSignalBoolField(ctx, roc_host, desc.elem_id, desc.field, &desc.signal, desc.read, &desc.cached_value, dirty_source_node_ids, dirty_generation)) {
                    counts.addBoolField(desc.field);
                }
            }
        }

        fn applyActiveStreamFieldsForElemOptions(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, elem_id: u64, counts: *render.Counts, dirty_source_node_ids: []const u64, dirty_generation: u64, apply_custom_attrs: bool) void {
            const descriptor_index = self.active_stream.elemDescriptorIndex(elem_id) orelse @panic("active render node had no descriptor index");
            const text_fields = [_]RenderTextField{ .text, .role, .label, .test_id, .value, .class };
            const bool_fields = [_]RenderBoolField{ .checked, .disabled };

            for (text_fields) |field| {
                if (!streamHasTextField(&self.active_stream, elem_id, field) and self.clearRenderTextField(ctx, elem_id, field)) {
                    counts.addTextField(field);
                }
            }
            for (bool_fields) |field| {
                if (!streamHasBoolField(&self.active_stream, elem_id, field) and self.clearRenderBoolField(ctx, elem_id, field)) {
                    counts.addBoolField(field);
                }
            }
            self.clearRenderTextAttrsMissingFromStream(ctx, &self.active_stream, elem_id, counts);

            if (descriptor_index.text_node.get()) |text_index| {
                if (text_index >= self.active_stream.text_nodes.items.len) @panic("active text node index exceeded descriptor table");
                const desc = self.active_stream.text_nodes.items[text_index];
                if (desc.elem_id != elem_id) @panic("active text node index pointed at the wrong elem id");
                if (self.applyRenderTextField(ctx, desc.elem_id, .text, desc.value)) {
                    counts.addTextField(.text);
                }
            }

            if (descriptor_index.signal_text_node.get()) |signal_text_index| {
                if (signal_text_index >= self.active_stream.signal_text_nodes.items.len) @panic("active signal text node index exceeded descriptor table");
                const desc = &self.active_stream.signal_text_nodes.items[signal_text_index];
                if (desc.elem_id != elem_id) @panic("active signal text node index pointed at the wrong elem id");
                if (self.evalStructuralSignalTextField(ctx, roc_host, desc.elem_id, .text, &desc.signal, desc.read, &desc.cached_value, dirty_source_node_ids, dirty_generation)) {
                    counts.addTextField(.text);
                }
            }

            for (text_fields) |field| {
                self.applyActiveStreamTextAttrForElem(ctx, roc_host, elem_id, field, descriptor_index, counts, dirty_source_node_ids, dirty_generation);
            }
            if (apply_custom_attrs) self.applyActiveStreamCustomTextAttrsForElem(ctx, roc_host, elem_id, counts, dirty_source_node_ids, dirty_generation);
            for (bool_fields) |field| {
                self.applyActiveStreamBoolAttrForElem(ctx, roc_host, elem_id, field, descriptor_index, counts, dirty_source_node_ids, dirty_generation);
            }
        }

        /// Applies active stream fields for elem after preparation has fixed semantics and reserved fallible growth.
        pub fn applyActiveStreamFieldsForElem(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, elem_id: u64, counts: *render.Counts, dirty_source_node_ids: []const u64, dirty_generation: u64) void {
            self.applyActiveStreamFieldsForElemOptions(ctx, roc_host, elem_id, counts, dirty_source_node_ids, dirty_generation, true);
        }

        /// Applies structural node descriptor target after preparation has fixed semantics and reserved fallible growth.
        pub fn applyStructuralNodeDescriptorTarget(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, stream: *HostNodeDescriptorStream, targets: HostStructuralPatchTargets) render.Counts {
            if (!self.hasRenderRoot()) @panic("structural DOM patch requested before initial DOM root creation");

            const allocator = Ctx.allocator(ctx);
            const max_elem_id = @max(maxRenderElemId(&self.active_stream), maxRenderElemId(stream));
            const required_child_table_len: usize = @intCast(max_elem_id + 1);
            const child_table_len = required_child_table_len;
            self.ensureRenderNodeCapacity(ctx, required_child_table_len);

            var seen = allocator.alloc(bool, child_table_len) catch @panic("out of memory");
            defer allocator.free(seen);
            @memset(seen, false);

            var touched_parents: std.ArrayListUnmanaged(u64) = .empty;
            defer touched_parents.deinit(allocator);

            var counts: render.Counts = .{};

            self.recordStreamNodesScannedBy(.stream_nodes_scanned_apply, stream.render_nodes.items.len);
            for (stream.render_nodes.items) |node| {
                if (!self.renderNodeInReplacementTarget(stream, node, targets.replacement)) continue;
                if (node.elem_id >= child_table_len) @panic("render node exceeded structural DOM patch table");

                const parent_elem_id = renderNodeParentElemId(stream, node);
                if (parent_elem_id >= child_table_len) @panic("render node referenced parent outside structural DOM patch table");

                const tag = renderNodeTag(stream, node);
                if (self.activeRenderNodeTagDiffers(node.elem_id, tag)) {
                    self.removeRenderNode(ctx, node.elem_id, &counts);
                }
                self.ensureRenderNode(ctx, node.elem_id, tag, &counts);
                seen[@intCast(node.elem_id)] = true;
                appendUniqueU64(allocator, &touched_parents, parent_elem_id);
            }

            self.recordStreamNodesScannedBy(.stream_nodes_scanned_apply, self.active_stream.render_nodes.items.len);
            for (self.active_stream.render_nodes.items) |node| {
                if (!self.renderNodeInReplacementTarget(&self.active_stream, node, targets.removed)) continue;
                if (node.elem_id < seen.len and seen[@intCast(node.elem_id)]) continue;
                if (!self.hasActiveRenderNode(node.elem_id)) continue;
                self.removeRenderNode(ctx, node.elem_id, &counts);
            }

            for (touched_parents.items) |parent_elem_id| {
                const children = streamDirectChildrenInto(allocator, stream, parent_elem_id, &self.scratch.stream_direct_children);
                self.replaceRenderChildren(ctx, parent_elem_id, children, &counts);
            }

            const text_fields = [_]RenderTextField{ .text, .role, .label, .test_id, .value, .class };
            const bool_fields = [_]RenderBoolField{ .checked, .disabled };
            for (seen, 0..) |is_seen, index| {
                if (index == 0 or !is_seen) continue;
                const elem_id: u64 = @intCast(index);

                for (text_fields) |field| {
                    if (!streamHasTextField(stream, elem_id, field) and self.clearRenderTextField(ctx, elem_id, field)) {
                        counts.addTextField(field);
                    }
                }
                for (bool_fields) |field| {
                    if (!streamHasBoolField(stream, elem_id, field) and self.clearRenderBoolField(ctx, elem_id, field)) {
                        counts.addBoolField(field);
                    }
                }
                self.clearRenderTextAttrsMissingFromStream(ctx, stream, elem_id, &counts);
            }

            self.recordStreamNodesScannedBy(.stream_nodes_scanned_apply, stream.text_nodes.items.len);
            for (stream.text_nodes.items) |desc| {
                if (desc.elem_id < seen.len and seen[@intCast(desc.elem_id)] and self.applyRenderTextField(ctx, desc.elem_id, .text, desc.value)) {
                    counts.addTextField(.text);
                }
            }
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_apply, stream.signal_text_nodes.items.len);
            for (stream.signal_text_nodes.items) |*desc| {
                if (desc.elem_id < seen.len and seen[@intCast(desc.elem_id)] and self.evalSignalTextField(ctx, roc_host, desc.elem_id, .text, &desc.signal, desc.read, &desc.cached_value)) {
                    counts.addTextField(.text);
                }
            }
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_apply, stream.static_text_attrs.items.len);
            for (stream.static_text_attrs.items) |desc| {
                if (desc.elem_id < seen.len and seen[@intCast(desc.elem_id)] and self.applyRenderTextField(ctx, desc.elem_id, desc.field, desc.value)) {
                    counts.addTextField(desc.field);
                }
            }
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_apply, stream.signal_text_attrs.items.len);
            for (stream.signal_text_attrs.items) |*desc| {
                if (desc.elem_id < seen.len and seen[@intCast(desc.elem_id)] and self.evalSignalTextField(ctx, roc_host, desc.elem_id, desc.field, &desc.signal, desc.read, &desc.cached_value)) {
                    counts.addTextField(desc.field);
                }
            }
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_apply, stream.static_custom_text_attrs.items.len);
            for (stream.static_custom_text_attrs.items) |desc| {
                if (desc.elem_id < seen.len and seen[@intCast(desc.elem_id)] and self.applyRenderTextAttr(ctx, desc.elem_id, desc.name, desc.value)) {
                    counts.addTextAttr();
                }
            }
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_apply, stream.signal_custom_text_attrs.items.len);
            for (stream.signal_custom_text_attrs.items) |*desc| {
                if (desc.elem_id < seen.len and seen[@intCast(desc.elem_id)] and self.evalSignalTextAttr(ctx, roc_host, desc.elem_id, desc.name, &desc.signal, desc.read, &desc.cached_value)) {
                    counts.addTextAttr();
                }
            }
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_apply, stream.signal_optional_custom_text_attrs.items.len);
            for (stream.signal_optional_custom_text_attrs.items) |*desc| {
                if (desc.elem_id < seen.len and seen[@intCast(desc.elem_id)] and self.evalSignalOptionalTextAttr(ctx, roc_host, desc.elem_id, desc.name, &desc.signal, desc.present, desc.read, &desc.cached_value)) {
                    counts.addTextAttr();
                }
            }
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_apply, stream.static_custom_bool_attrs.items.len);
            for (stream.static_custom_bool_attrs.items) |desc| {
                if (desc.elem_id < seen.len and seen[@intCast(desc.elem_id)] and self.applyRenderBoolAttr(ctx, desc.elem_id, desc.name, desc.value)) {
                    counts.addTextAttr();
                }
            }
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_apply, stream.signal_custom_bool_attrs.items.len);
            for (stream.signal_custom_bool_attrs.items) |*desc| {
                if (desc.elem_id < seen.len and seen[@intCast(desc.elem_id)] and self.evalSignalBoolAttr(ctx, roc_host, desc.elem_id, desc.name, &desc.signal, desc.read, &desc.cached_value)) {
                    counts.addTextAttr();
                }
            }
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_apply, stream.static_bool_attrs.items.len);
            for (stream.static_bool_attrs.items) |desc| {
                if (desc.elem_id < seen.len and seen[@intCast(desc.elem_id)] and self.applyRenderBoolField(ctx, desc.elem_id, desc.field, desc.value)) {
                    counts.addBoolField(desc.field);
                }
            }
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_apply, stream.signal_bool_attrs.items.len);
            for (stream.signal_bool_attrs.items) |*desc| {
                if (desc.elem_id < seen.len and seen[@intCast(desc.elem_id)] and self.evalSignalBoolField(ctx, roc_host, desc.elem_id, desc.field, &desc.signal, desc.read, &desc.cached_value)) {
                    counts.addBoolField(desc.field);
                }
            }
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_apply, stream.on_changes.items.len);
            for (stream.on_changes.items) |*desc| {
                if (self.scopeIsInReplacementTarget(desc.scope_id, targets.replacement)) {
                    self.evalOnChangeInitial(ctx, roc_host, desc);
                }
            }

            self.applyStructuralEventBindingsForSeen(ctx, stream, seen, &counts);
            self.debugAssertRenderCacheMatchesStream(ctx, stream);
            self.debugAssertRenderCacheMatchesSink(ctx);

            self.rebuildActiveSignalGraphFromStream(ctx, stream);
            if (comptime enable_runtime_metrics) self.render_metrics.addCommandCounts(counts);
            return counts;
        }

        /// Applies node descriptor stream after preparation has fixed semantics and reserved fallible growth.
        pub fn applyNodeDescriptorStream(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, stream: *HostNodeDescriptorStream) render.Counts {
            var counts: render.Counts = .{};
            counts.addHostReset();
            self.resetRenderTree(ctx);
            self.ensureRenderNodeCapacity(ctx, @intCast(maxRenderElemId(stream) + 1));

            for (stream.render_nodes.items) |node| {
                switch (node.kind) {
                    .element => {
                        const desc = findElementDesc(stream, node.elem_id) orelse @panic("render node referenced missing element descriptor");
                        self.appendRenderNode(ctx, desc.elem_id, desc.parent_elem_id, desc.tag);
                        counts.addCreateElement();
                        counts.addAppendChild();
                    },
                    .text => {
                        const desc = findTextNodeDesc(stream, node.elem_id) orelse @panic("render node referenced missing text descriptor");
                        self.appendRenderNode(ctx, desc.elem_id, desc.parent_elem_id, "text");
                        counts.addCreateElement();
                        counts.addAppendChild();
                        if (self.applyRenderTextField(ctx, desc.elem_id, .text, desc.value)) {
                            counts.addTextField(.text);
                        }
                    },
                    .signal_text => {
                        const desc = findSignalTextNodeDescMutable(stream, node.elem_id) orelse @panic("render node referenced missing signal text descriptor");
                        self.appendRenderNode(ctx, desc.elem_id, desc.parent_elem_id, "text");
                        counts.addCreateElement();
                        counts.addAppendChild();
                        if (self.evalSignalTextField(ctx, roc_host, desc.elem_id, .text, &desc.signal, desc.read, &desc.cached_value)) {
                            counts.addTextField(.text);
                        }
                    },
                }
            }

            for (stream.static_text_attrs.items) |desc| {
                if (self.applyRenderTextField(ctx, desc.elem_id, desc.field, desc.value)) {
                    counts.addTextField(desc.field);
                }
            }
            for (stream.signal_text_attrs.items) |*desc| {
                if (self.evalSignalTextField(ctx, roc_host, desc.elem_id, desc.field, &desc.signal, desc.read, &desc.cached_value)) {
                    counts.addTextField(desc.field);
                }
            }
            for (stream.static_custom_text_attrs.items) |desc| {
                if (self.applyRenderTextAttr(ctx, desc.elem_id, desc.name, desc.value)) {
                    counts.addTextAttr();
                }
            }
            for (stream.signal_custom_text_attrs.items) |*desc| {
                if (self.evalSignalTextAttr(ctx, roc_host, desc.elem_id, desc.name, &desc.signal, desc.read, &desc.cached_value)) {
                    counts.addTextAttr();
                }
            }
            for (stream.signal_optional_custom_text_attrs.items) |*desc| {
                if (self.evalSignalOptionalTextAttr(ctx, roc_host, desc.elem_id, desc.name, &desc.signal, desc.present, desc.read, &desc.cached_value)) {
                    counts.addTextAttr();
                }
            }
            for (stream.static_custom_bool_attrs.items) |desc| {
                if (self.applyRenderBoolAttr(ctx, desc.elem_id, desc.name, desc.value)) {
                    counts.addTextAttr();
                }
            }
            for (stream.signal_custom_bool_attrs.items) |*desc| {
                if (self.evalSignalBoolAttr(ctx, roc_host, desc.elem_id, desc.name, &desc.signal, desc.read, &desc.cached_value)) {
                    counts.addTextAttr();
                }
            }
            for (stream.static_bool_attrs.items) |desc| {
                if (self.applyRenderBoolField(ctx, desc.elem_id, desc.field, desc.value)) {
                    counts.addBoolField(desc.field);
                }
            }
            for (stream.signal_bool_attrs.items) |*desc| {
                if (self.evalSignalBoolField(ctx, roc_host, desc.elem_id, desc.field, &desc.signal, desc.read, &desc.cached_value)) {
                    counts.addBoolField(desc.field);
                }
            }
            for (stream.on_changes.items) |*desc| {
                self.evalOnChangeInitial(ctx, roc_host, desc);
            }
            for (stream.events.items, 0..) |desc, index| {
                const event_id: u64 = @intCast(index + 1);
                switch (desc.binding) {
                    .fixed => |kind| self.applyRenderEventBinding(ctx, desc.elem_id, kind, .{ .event_id = event_id, .delivery = .{ .requested = desc.delivery_request }, .payload_descriptor = desc.payload_descriptor }, &counts),
                    .named => |binding| self.applyRenderNamedEventBinding(ctx, desc.elem_id, binding.name, .{
                        .event_id = event_id,
                        .policy = binding.policy,
                        .delivery = .{ .requested = binding.delivery_request },
                        .payload_descriptor = desc.payload_descriptor,
                    }, &counts),
                }
            }

            self.debugAssertRenderCacheMatchesStream(ctx, stream);
            self.debugAssertRenderCacheMatchesSink(ctx);
            self.rebuildActiveSignalGraphFromStream(ctx, stream);
            if (comptime enable_runtime_metrics) self.render_metrics.addCommandCounts(counts);
            return counts;
        }

        /// Applies spliced structural node descriptor target after preparation has fixed semantics and reserved fallible growth.
        pub fn applySplicedStructuralNodeDescriptorTarget(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, splice: HostStructuralSplice, targets: HostStructuralPatchTargets, dirty_source_node_ids: []const u64, dirty_generation: u64) render.Counts {
            _ = targets;
            if (!self.hasRenderRoot()) @panic("structural DOM patch requested before initial DOM root creation");

            const allocator = Ctx.allocator(ctx);
            var max_elem_id: u64 = 0;
            for (splice.removed_elem_ids) |elem_id| {
                max_elem_id = @max(max_elem_id, elem_id);
            }
            for (splice.replacement_elem_ids) |elem_id| {
                max_elem_id = @max(max_elem_id, elem_id);
            }
            const required_child_table_len: usize = @intCast(max_elem_id + 1);
            const child_table_len = required_child_table_len;
            self.ensureRenderNodeCapacity(ctx, required_child_table_len);

            var seen = allocator.alloc(bool, child_table_len) catch @panic("out of memory");
            defer allocator.free(seen);
            @memset(seen, false);
            var replacement_members = allocator.alloc(bool, child_table_len) catch @panic("out of memory");
            defer allocator.free(replacement_members);
            @memset(replacement_members, false);
            for (splice.replacement_elem_ids) |elem_id| replacement_members[@intCast(elem_id)] = true;
            var removed_members = allocator.alloc(bool, child_table_len) catch @panic("out of memory");
            defer allocator.free(removed_members);
            @memset(removed_members, false);
            for (splice.removed_elem_ids) |elem_id| removed_members[@intCast(elem_id)] = true;

            var touched_parents: std.ArrayListUnmanaged(u64) = .empty;
            defer touched_parents.deinit(allocator);
            var touched_parent_set: std.AutoHashMapUnmanaged(u64, void) = .empty;
            defer touched_parent_set.deinit(allocator);
            for (splice.touched_parent_ids) |parent_id| {
                const entry = touched_parent_set.getOrPut(allocator, parent_id) catch @panic("out of memory");
                if (!entry.found_existing) touched_parents.append(allocator, parent_id) catch @panic("out of memory");
            }

            var counts: render.Counts = .{};

            self.recordStreamNodesScannedBy(.stream_nodes_scanned_splice, splice.replacement_elem_ids.len);
            for (splice.replacement_elem_ids) |elem_id| {
                if (elem_id >= child_table_len) @panic("render node exceeded structural DOM patch table");

                const parent_elem_id = streamElemParentElemId(&self.active_stream, elem_id);
                const parent_available = parent_elem_id == 0 or
                    (parent_elem_id < replacement_members.len and replacement_members[@intCast(parent_elem_id)]) or
                    (self.hasActiveRenderNode(parent_elem_id) and
                        !(parent_elem_id < removed_members.len and removed_members[@intCast(parent_elem_id)]));
                if (!parent_available) {
                    @panic("render node referenced unavailable parent in structural DOM splice");
                }

                const tag = streamElemTag(&self.active_stream, elem_id);
                if (self.activeRenderNodeTagDiffers(elem_id, tag)) {
                    self.removeRenderNode(ctx, elem_id, &counts);
                }
                self.ensureRenderNode(ctx, elem_id, tag, &counts);
                seen[@intCast(elem_id)] = true;
                const entry = touched_parent_set.getOrPut(allocator, parent_elem_id) catch @panic("out of memory");
                if (!entry.found_existing) touched_parents.append(allocator, parent_elem_id) catch @panic("out of memory");
            }

            for (splice.removed_elem_ids) |elem_id| {
                if (elem_id < seen.len and seen[@intCast(elem_id)]) continue;
                if (!self.hasActiveRenderNode(elem_id)) continue;
                self.removeRenderNode(ctx, elem_id, &counts);
            }

            for (touched_parents.items) |parent_elem_id| {
                const children = streamDirectChildrenInto(allocator, &self.active_stream, parent_elem_id, &self.scratch.stream_direct_children);
                self.replaceRenderChildren(ctx, parent_elem_id, children, &counts);
            }

            for (splice.replacement_elem_ids) |elem_id| {
                self.applyActiveStreamFieldsForElemOptions(ctx, roc_host, elem_id, &counts, dirty_source_node_ids, dirty_generation, false);
            }
            self.applyActiveStreamCustomAttrsForElemSet(ctx, roc_host, seen, &counts, dirty_source_node_ids, dirty_generation);
            var event_binding_elem_ids: std.ArrayListUnmanaged(u64) = .empty;
            defer event_binding_elem_ids.deinit(allocator);
            var event_binding_elem_set: std.AutoHashMapUnmanaged(u64, void) = .empty;
            defer event_binding_elem_set.deinit(allocator);
            for (splice.replacement_elem_ids) |elem_id| {
                const entry = event_binding_elem_set.getOrPut(allocator, elem_id) catch @panic("out of memory");
                if (!entry.found_existing) event_binding_elem_ids.append(allocator, elem_id) catch @panic("out of memory");
            }
            for (touched_parents.items) |parent_elem_id| {
                const children = streamDirectChildrenInto(allocator, &self.active_stream, parent_elem_id, &self.scratch.stream_direct_children);
                for (children) |child_id| {
                    const entry = event_binding_elem_set.getOrPut(allocator, child_id) catch @panic("out of memory");
                    if (!entry.found_existing) event_binding_elem_ids.append(allocator, child_id) catch @panic("out of memory");
                }
            }
            for (splice.moved_event_elem_ids) |elem_id| {
                const entry = event_binding_elem_set.getOrPut(allocator, elem_id) catch @panic("out of memory");
                if (!entry.found_existing) event_binding_elem_ids.append(allocator, elem_id) catch @panic("out of memory");
            }
            for (event_binding_elem_ids.items) |elem_id| {
                if (!self.hasActiveRenderNode(elem_id)) continue;
                self.applyStructuralEventBindingsForElem(ctx, elem_id, &counts);
            }

            self.recordStreamNodesScannedBy(.stream_nodes_scanned_splice, splice.replacement_on_change_indices.len);
            for (splice.replacement_on_change_indices) |on_change_index| {
                if (on_change_index >= self.active_stream.on_changes.items.len) @panic("structural splice on_change index exceeded active descriptor stream");
                const desc = &self.active_stream.on_changes.items[on_change_index];
                self.evalOnChangeInitial(ctx, roc_host, desc);
            }

            self.debugAssertRenderCacheMatchesStream(ctx, &self.active_stream);
            self.debugAssertRenderCacheMatchesSink(ctx);
            counts.addAll(self.runActiveOnChangeInitialCommandIndices(ctx, roc_host, splice.replacement_on_change_indices));
            counts.addAll(self.runActiveMountCommandIndices(ctx, roc_host, splice.replacement_mount_indices));
            if (comptime enable_runtime_metrics) self.render_metrics.addCommandCounts(counts);
            return counts;
        }

        /// Applies structural node descriptor stream after preparation has fixed semantics and reserved fallible growth.
        pub fn applyStructuralNodeDescriptorStream(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, stream: *HostNodeDescriptorStream) render.Counts {
            if (!self.hasRenderRoot()) @panic("structural DOM patch requested before initial DOM root creation");

            const allocator = Ctx.allocator(ctx);
            const max_elem_id = @max(maxRenderElemId(&self.active_stream), maxRenderElemId(stream));
            const required_child_table_len: usize = @intCast(max_elem_id + 1);
            const child_table_len = required_child_table_len;
            self.ensureRenderNodeCapacity(ctx, required_child_table_len);

            var seen = allocator.alloc(bool, child_table_len) catch @panic("out of memory");
            defer allocator.free(seen);
            @memset(seen, false);

            var next_children = allocator.alloc(std.ArrayListUnmanaged(u64), child_table_len) catch @panic("out of memory");
            defer {
                for (next_children) |*children| {
                    children.deinit(allocator);
                }
                allocator.free(next_children);
            }
            for (next_children) |*children| {
                children.* = .empty;
            }

            var counts: render.Counts = .{};

            for (stream.render_nodes.items) |node| {
                if (node.elem_id >= child_table_len) @panic("render node exceeded structural DOM patch table");

                const parent_elem_id = renderNodeParentElemId(stream, node);
                if (parent_elem_id >= child_table_len) @panic("render node referenced parent outside structural DOM patch table");

                const tag = renderNodeTag(stream, node);
                if (self.activeRenderNodeTagDiffers(node.elem_id, tag)) {
                    self.removeRenderNode(ctx, node.elem_id, &counts);
                }
                self.ensureRenderNode(ctx, node.elem_id, tag, &counts);
                seen[@intCast(node.elem_id)] = true;

                next_children[@intCast(parent_elem_id)].append(allocator, node.elem_id) catch @panic("out of memory");
            }

            for (self.active_stream.render_nodes.items) |node| {
                const still_rendered = node.elem_id < seen.len and seen[@intCast(node.elem_id)];
                if (!still_rendered and self.hasActiveRenderNode(node.elem_id)) self.removeRenderNode(ctx, node.elem_id, &counts);
            }

            for (next_children, 0..) |*children, index| {
                const accepts_children = index == 0 or (index < seen.len and seen[index]);
                if (!accepts_children) continue;
                self.replaceRenderChildren(ctx, @intCast(index), children.items, &counts);
            }

            const text_fields = [_]RenderTextField{ .text, .role, .label, .test_id, .value, .class };
            const bool_fields = [_]RenderBoolField{ .checked, .disabled };
            for (seen, 0..) |is_seen, index| {
                if (index == 0 or !is_seen) continue;
                const elem_id: u64 = @intCast(index);

                for (text_fields) |field| {
                    if (!streamHasTextField(stream, elem_id, field) and self.clearRenderTextField(ctx, elem_id, field)) {
                        counts.addTextField(field);
                    }
                }
                for (bool_fields) |field| {
                    if (!streamHasBoolField(stream, elem_id, field) and self.clearRenderBoolField(ctx, elem_id, field)) {
                        counts.addBoolField(field);
                    }
                }
                self.clearRenderTextAttrsMissingFromStream(ctx, stream, elem_id, &counts);
            }

            for (stream.text_nodes.items) |desc| {
                if (self.applyRenderTextField(ctx, desc.elem_id, .text, desc.value)) {
                    counts.addTextField(.text);
                }
            }
            for (stream.signal_text_nodes.items) |*desc| {
                if (self.evalSignalTextField(ctx, roc_host, desc.elem_id, .text, &desc.signal, desc.read, &desc.cached_value)) {
                    counts.addTextField(.text);
                }
            }
            for (stream.static_text_attrs.items) |desc| {
                if (self.applyRenderTextField(ctx, desc.elem_id, desc.field, desc.value)) {
                    counts.addTextField(desc.field);
                }
            }
            for (stream.signal_text_attrs.items) |*desc| {
                if (self.evalSignalTextField(ctx, roc_host, desc.elem_id, desc.field, &desc.signal, desc.read, &desc.cached_value)) {
                    counts.addTextField(desc.field);
                }
            }
            for (stream.static_custom_text_attrs.items) |desc| {
                if (self.applyRenderTextAttr(ctx, desc.elem_id, desc.name, desc.value)) {
                    counts.addTextAttr();
                }
            }
            for (stream.signal_custom_text_attrs.items) |*desc| {
                if (self.evalSignalTextAttr(ctx, roc_host, desc.elem_id, desc.name, &desc.signal, desc.read, &desc.cached_value)) {
                    counts.addTextAttr();
                }
            }
            for (stream.signal_optional_custom_text_attrs.items) |*desc| {
                if (self.evalSignalOptionalTextAttr(ctx, roc_host, desc.elem_id, desc.name, &desc.signal, desc.present, desc.read, &desc.cached_value)) {
                    counts.addTextAttr();
                }
            }
            for (stream.static_custom_bool_attrs.items) |desc| {
                if (self.applyRenderBoolAttr(ctx, desc.elem_id, desc.name, desc.value)) {
                    counts.addTextAttr();
                }
            }
            for (stream.signal_custom_bool_attrs.items) |*desc| {
                if (self.evalSignalBoolAttr(ctx, roc_host, desc.elem_id, desc.name, &desc.signal, desc.read, &desc.cached_value)) {
                    counts.addTextAttr();
                }
            }
            for (stream.static_bool_attrs.items) |desc| {
                if (self.applyRenderBoolField(ctx, desc.elem_id, desc.field, desc.value)) {
                    counts.addBoolField(desc.field);
                }
            }
            for (stream.signal_bool_attrs.items) |*desc| {
                if (self.evalSignalBoolField(ctx, roc_host, desc.elem_id, desc.field, &desc.signal, desc.read, &desc.cached_value)) {
                    counts.addBoolField(desc.field);
                }
            }
            for (stream.on_changes.items) |*desc| {
                self.evalOnChangeInitial(ctx, roc_host, desc);
            }

            self.applyStructuralEventBindings(ctx, stream, seen, &counts);
            self.debugAssertRenderCacheMatchesStream(ctx, stream);
            self.debugAssertRenderCacheMatchesSink(ctx);

            self.rebuildActiveSignalGraphFromStream(ctx, stream);
            if (comptime enable_runtime_metrics) self.render_metrics.addCommandCounts(counts);
            return counts;
        }

        /// Performs rerender active root inside the shared engine while preserving transaction and changed-set invariants.
        pub fn rerenderActiveRoot(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, dirty_source_node_ids: []const u64) render.Counts {
            const root = self.root_elem orelse @panic("host render requested before Roc root Elem was initialized");
            const allocator = Ctx.allocator(ctx);

            var next_stream: HostNodeDescriptorStream = .{};
            errdefer next_stream.deinit(allocator, ctx, roc_host, &self.pending_roc_metrics);
            self.collectActiveElemRootDescriptors(ctx, roc_host, &next_stream, root, dirty_source_node_ids);

            var counts = if (!self.hasRenderRoot())
                self.applyNodeDescriptorStream(ctx, roc_host, &next_stream)
            else
                self.applyStructuralNodeDescriptorStream(ctx, roc_host, &next_stream);

            self.rebuildActiveEventsFromStream(ctx, &next_stream);
            self.active_stream.deinit(allocator, ctx, roc_host, &self.pending_roc_metrics);
            self.active_stream = next_stream;

            const on_change_initial_counts = self.runActiveOnChangeInitialCommands(ctx, roc_host);
            const mount_counts = self.runActiveMountCommands(ctx, roc_host);
            if (comptime enable_runtime_metrics) self.render_metrics.addCommandCounts(on_change_initial_counts);
            if (comptime enable_runtime_metrics) self.render_metrics.addCommandCounts(mount_counts);
            counts.addAll(on_change_initial_counts);
            counts.addAll(mount_counts);
            return counts;
        }

        /// Performs rerender active root with reset inside the shared engine while preserving transaction and changed-set invariants.
        pub fn rerenderActiveRootWithReset(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, dirty_source_node_ids: []const u64) render.Counts {
            const root = self.root_elem orelse @panic("host render requested before Roc root Elem was initialized");
            const allocator = Ctx.allocator(ctx);

            var next_stream: HostNodeDescriptorStream = .{};
            errdefer next_stream.deinit(allocator, ctx, roc_host, &self.pending_roc_metrics);
            self.collectActiveElemRootDescriptors(ctx, roc_host, &next_stream, root, dirty_source_node_ids);

            var counts = self.applyNodeDescriptorStream(ctx, roc_host, &next_stream);

            self.rebuildActiveEventsFromStream(ctx, &next_stream);
            self.active_stream.deinit(allocator, ctx, roc_host, &self.pending_roc_metrics);
            self.active_stream = next_stream;

            const on_change_initial_counts = self.runActiveOnChangeInitialCommands(ctx, roc_host);
            const mount_counts = self.runActiveMountCommands(ctx, roc_host);
            if (comptime enable_runtime_metrics) self.render_metrics.addCommandCounts(on_change_initial_counts);
            if (comptime enable_runtime_metrics) self.render_metrics.addCommandCounts(mount_counts);
            counts.addAll(on_change_initial_counts);
            counts.addAll(mount_counts);
            return counts;
        }

        /// Applies dirty structural signals locally after preparation has fixed semantics and reserved fallible growth.
        pub fn applyDirtyStructuralSignalsLocally(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, dirty_source_node_ids: []const u64, dirty_generation: u64, changes: []HostDirtyStructuralSignal) render.Counts {
            const DirtyStructuralOrder = struct {
                engine: *Self,

                /// Performs less than inside the shared engine while preserving transaction and changed-set invariants.
                pub fn lessThan(order: @This(), lhs: HostDirtyStructuralSignal, rhs: HostDirtyStructuralSignal) bool {
                    const lhs_depth = order.engine.scopeDepth(lhs.scope_id);
                    const rhs_depth = order.engine.scopeDepth(rhs.scope_id);
                    if (lhs_depth != rhs_depth) return lhs_depth < rhs_depth;
                    if (lhs.scope_id != rhs.scope_id) return lhs.scope_id < rhs.scope_id;
                    if (lhs.ordinal != rhs.ordinal) return lhs.ordinal < rhs.ordinal;
                    if (@intFromEnum(lhs.kind) != @intFromEnum(rhs.kind)) return @intFromEnum(lhs.kind) < @intFromEnum(rhs.kind);
                    return lhs.node_id < rhs.node_id;
                }
            };

            std.mem.sort(HostDirtyStructuralSignal, changes, DirtyStructuralOrder{ .engine = self }, DirtyStructuralOrder.lessThan);

            var total_counts: render.Counts = .{};
            var applied_any = false;
            const event_count_before = self.active_stream.events.items.len;

            for (changes) |*change| {
                var replacement_stream: HostNodeDescriptorStream = .{};
                defer replacement_stream.deinit(Ctx.allocator(ctx), ctx, roc_host, &self.pending_roc_metrics);
                const splice_and_targets: HostStructuralSpliceAndTargets = switch (change.kind) {
                    .when => when_target: {
                        const site = self.activeScopeSiteByNodeId(change.node_id, .when) orelse {
                            if (applied_any) continue;
                            @panic("dirty when structural site is not active");
                        };
                        if (site.scope_id != change.scope_id or site.ordinal != change.ordinal) {
                            if (applied_any) continue;
                            @panic("dirty when structural site identity changed before apply");
                        }
                        const when_index = self.activeWhenIndexByNodeId(change.node_id) orelse {
                            if (applied_any) continue;
                            @panic("dirty when descriptor is not active");
                        };
                        const when_desc = self.active_stream.whens.items[when_index];
                        if (when_desc.condition.record != change.record) {
                            if (applied_any) continue;
                            @panic("dirty when descriptor identity changed before apply");
                        }
                        const active_branch = change.branch orelse @panic("dirty when structural signal did not record its active branch");
                        const replaced_scope_id = (self.activeWhenBranchScopeId(site.scope_id, site.ordinal, active_branch.opposite()) catch @panic("scope id has no host scope descriptor")) orelse {
                            if (applied_any) continue;
                            total_counts.addAll(self.rerenderActiveRootWithReset(ctx, roc_host, dirty_source_node_ids));
                            const committed_when_index = self.activeWhenIndexByNodeId(change.node_id) orelse @panic("rerendered dirty when descriptor disappeared");
                            change.commitPendingWhenCache(&self.active_stream.whens.items[committed_when_index].cached_value, ctx, roc_host, &self.pending_roc_metrics);
                            return total_counts;
                        };
                        const existing_replacement_scope_id = self.activeWhenBranchScopeId(site.scope_id, site.ordinal, active_branch) catch @panic("scope id has no host scope descriptor");
                        const target_scopes_snapshot = self.snapshotReplacementTargetScopeSet(ctx, .{ .scope = replaced_scope_id });
                        defer Ctx.allocator(ctx).free(target_scopes_snapshot);
                        if (self.replacementTargetHasNonContiguousDomDescendants(ctx, site.render_insert_index, target_scopes_snapshot)) {
                            total_counts.addAll(self.rerenderActiveRootWithReset(ctx, roc_host, dirty_source_node_ids));
                            const committed_when_index = self.activeWhenIndexByNodeId(change.node_id) orelse @panic("rerendered dirty when descriptor disappeared");
                            change.commitPendingWhenCache(&self.active_stream.whens.items[committed_when_index].cached_value, ctx, roc_host, &self.pending_roc_metrics);
                            return total_counts;
                        }
                        if (existing_replacement_scope_id) |replacement_scope_id| {
                            self.disposeScopeSubtree(ctx, roc_host, replaced_scope_id);
                            const splice = self.spliceActiveStreamReplacingScopeWithScopeSnapshot(ctx, roc_host, replaced_scope_id, site.render_insert_index, &replacement_stream, target_scopes_snapshot);
                            break :when_target .{
                                .splice = splice,
                                .targets = HostStructuralPatchTargets{
                                    .removed = .{ .scope = replaced_scope_id },
                                    .replacement = .{ .scope = replacement_scope_id },
                                },
                            };
                        }
                        const replacement_scope_id = self.collectActiveWhenBranchDescriptors(ctx, roc_host, &replacement_stream, site, when_desc, active_branch, dirty_source_node_ids);
                        const splice = self.spliceActiveStreamReplacingScopeWithScopeSnapshot(ctx, roc_host, replaced_scope_id, site.render_insert_index, &replacement_stream, target_scopes_snapshot);
                        break :when_target .{
                            .splice = splice,
                            .targets = HostStructuralPatchTargets{
                                .removed = .{ .scope = replaced_scope_id },
                                .replacement = .{ .scope = replacement_scope_id },
                            },
                        };
                    },
                    .each => {
                        const site = self.activeScopeSiteByNodeId(change.node_id, .each) orelse {
                            if (applied_any) continue;
                            @panic("dirty each structural site is not active");
                        };
                        if (site.scope_id != change.scope_id or site.ordinal != change.ordinal) {
                            if (applied_any) continue;
                            @panic("dirty each structural site identity changed before apply");
                        }
                        const each_index = self.activeEachIndexByNodeId(change.node_id) orelse {
                            if (applied_any) continue;
                            @panic("dirty each descriptor is not active");
                        };
                        const each_desc = self.active_stream.eaches.items[each_index];
                        if (each_desc.items.record != change.record) {
                            if (applied_any) continue;
                            @panic("dirty each descriptor identity changed before apply");
                        }
                        const each_site = HostEachSite{ .parent_scope_id = site.scope_id, .site_ordinal = site.ordinal };
                        const allocator = Ctx.allocator(ctx);
                        const old_active_rows = self.activeEachRowScopes(allocator, site.scope_id, site.ordinal) catch @panic("scope id has no host scope descriptor");
                        defer allocator.free(old_active_rows);
                        const old_render_segments = self.activeEachRowRenderSegmentsInRenderOrder(allocator, each_site);
                        defer allocator.free(old_render_segments);
                        const old_render_rows = eachRenderSegmentScopeIds(allocator, old_render_segments);
                        defer allocator.free(old_render_rows);
                        const old_target_scopes = self.snapshotReplacementTargetScopeSet(ctx, .{ .each_site = each_site });
                        defer allocator.free(old_target_scopes);
                        const diff = self.syncActiveEachRowScopes(ctx, roc_host, site, each_desc);
                        defer diff.deinit(allocator);

                        const replaces_all_rows = diff.removed_scope_ids.len == old_render_rows.len and
                            diff.rows_created == diff.scope_ids.len and
                            (diff.removed_scope_ids.len != 0 or diff.scope_ids.len != 0);
                        if (replaces_all_rows) {
                            var replacement_rows: HostNodeDescriptorStream = .{};
                            defer replacement_rows.deinit(allocator, ctx, roc_host, &self.pending_roc_metrics);
                            self.collectActiveEachRowDescriptorsFromDiff(ctx, roc_host, &replacement_rows, site, each_desc, diff, dirty_source_node_ids);
                            const target = HostStructuralReplacementTarget{ .each_site = each_site };
                            const render_insert_index = if (old_render_segments.len == 0) site.render_insert_index else old_render_segments[0].start;
                            const splice = self.spliceActiveStreamReplacingTargetWithScopeSet(ctx, roc_host, target, render_insert_index, &replacement_rows, null, true, old_target_scopes);
                            defer splice.deinit(allocator);
                            total_counts.addAll(self.applySplicedStructuralNodeDescriptorTarget(ctx, roc_host, splice, .{
                                .removed = target,
                                .replacement = target,
                            }, dirty_source_node_ids, dirty_generation));
                            applied_any = true;
                            continue;
                        }

                        const existing_row_count = diff.scope_ids.len - @as(usize, @intCast(diff.rows_created));
                        var appends_created_suffix = diff.removed_scope_ids.len == 0 and diff.rows_created > 1;
                        for (diff.scope_created, 0..) |created, row_index| {
                            if (created != (row_index >= existing_row_count)) appends_created_suffix = false;
                        }
                        if (appends_created_suffix) {
                            var appended_rows: HostNodeDescriptorStream = .{};
                            defer appended_rows.deinit(allocator, ctx, roc_host, &self.pending_roc_metrics);
                            for (diff.scope_ids[existing_row_count..]) |row_scope_id| {
                                self.collectActiveEachSingleRowDescriptors(ctx, roc_host, &appended_rows, site, each_desc, row_scope_id, true, dirty_source_node_ids);
                            }
                            const first_created_scope = diff.scope_ids[existing_row_count];
                            const render_insert_index = if (old_render_segments.len == 0) site.render_insert_index else old_render_segments[old_render_segments.len - 1].start + old_render_segments[old_render_segments.len - 1].len;
                            const target = HostStructuralReplacementTarget{ .scope = first_created_scope };
                            const splice = self.spliceActiveStreamReplacingTargetWithScopeSet(ctx, roc_host, target, render_insert_index, &appended_rows, null, true, null);
                            defer splice.deinit(allocator);
                            total_counts.addAll(self.applySplicedStructuralNodeDescriptorTarget(ctx, roc_host, splice, .{
                                .removed = target,
                                .replacement = target,
                            }, dirty_source_node_ids, dirty_generation));
                            applied_any = true;
                            continue;
                        }

                        var changed_row_count: usize = 0;
                        for (diff.row_items_changed) |changed| changed_row_count += @intFromBool(changed);
                        if (diff.rows_created == 0 and diff.removed_scope_ids.len == 0 and changed_row_count > 1) {
                            var replacement_rows: HostNodeDescriptorStream = .{};
                            defer replacement_rows.deinit(allocator, ctx, roc_host, &self.pending_roc_metrics);
                            for (diff.scope_ids) |row_scope_id| {
                                self.collectActiveEachSingleRowDescriptors(ctx, roc_host, &replacement_rows, site, each_desc, row_scope_id, false, dirty_source_node_ids);
                            }
                            const target = HostStructuralReplacementTarget{ .each_site = each_site };
                            const render_insert_index = if (old_render_segments.len == 0) site.render_insert_index else old_render_segments[0].start;
                            const splice = self.spliceActiveStreamReplacingTargetWithScopeSet(ctx, roc_host, target, render_insert_index, &replacement_rows, null, true, old_target_scopes);
                            defer splice.deinit(allocator);
                            total_counts.addAll(self.applySplicedStructuralNodeDescriptorTarget(ctx, roc_host, splice, .{
                                .removed = target,
                                .replacement = target,
                            }, dirty_source_node_ids, dirty_generation));
                            applied_any = true;
                            continue;
                        }

                        if (old_active_rows.len == old_render_rows.len and Self.eachDiffPreservesSurvivorRenderOrder(old_render_rows, diff.scope_ids)) {
                            const counts = self.applyDirtyEachRowScopeSplices(ctx, roc_host, site, each_desc, old_render_segments, diff, false, dirty_source_node_ids, dirty_generation);
                            total_counts.addAll(counts);
                            applied_any = true;
                            continue;
                        }

                        if (old_active_rows.len == old_render_rows.len and self.eachDiffIsPurePermutation(old_render_rows, diff, dirty_source_node_ids)) {
                            const counts = self.applyDirtyEachPermutationMoves(ctx, site, diff.scope_ids);
                            total_counts.addAll(counts);
                            applied_any = true;
                            continue;
                        }

                        if (old_active_rows.len == old_render_rows.len) {
                            const counts = self.applyDirtyEachMixedRowSplicesAndMoves(ctx, roc_host, site, each_desc, old_render_segments, diff, dirty_source_node_ids, dirty_generation);
                            total_counts.addAll(counts);
                            applied_any = true;
                            continue;
                        }

                        total_counts.addAll(self.rerenderActiveRoot(ctx, roc_host, dirty_source_node_ids));
                        return total_counts;
                    },
                };
                defer splice_and_targets.splice.deinit(Ctx.allocator(ctx));

                const counts = self.applySplicedStructuralNodeDescriptorTarget(ctx, roc_host, splice_and_targets.splice, splice_and_targets.targets, dirty_source_node_ids, dirty_generation);
                if (change.kind == .when) {
                    const when_index = self.activeWhenIndexByNodeId(change.node_id) orelse @panic("committed dirty when descriptor disappeared");
                    change.commitPendingWhenCache(&self.active_stream.whens.items[when_index].cached_value, ctx, roc_host, &self.pending_roc_metrics);
                }
                total_counts.addAll(counts);
                applied_any = true;
            }

            if (applied_any) {
                const event_count_after = self.active_stream.events.items.len;
                if (event_count_after != event_count_before) {
                    self.applyActiveStreamEventBindings(ctx, &total_counts);
                }
            }

            return total_counts;
        }

        const PreparedDirtyWhenSet = struct {
            selected_indexes: []usize,
            subsumed_indexes: []usize,

            fn prepare(engine: *Self, allocator: std.mem.Allocator, changes: []const HostDirtyStructuralSignal) CollectionError!@This() {
                const ordered = allocator.alloc(usize, changes.len) catch return error.OutOfMemory;
                errdefer allocator.free(ordered);
                for (ordered, 0..) |*index, i| index.* = i;

                const Order = struct {
                    engine: *Self,
                    changes: []const HostDirtyStructuralSignal,

                    fn lessThan(order: @This(), lhs_index: usize, rhs_index: usize) bool {
                        const lhs = order.changes[lhs_index];
                        const rhs = order.changes[rhs_index];
                        const lhs_depth = order.engine.scopeDepth(lhs.scope_id);
                        const rhs_depth = order.engine.scopeDepth(rhs.scope_id);
                        if (lhs_depth != rhs_depth) return lhs_depth < rhs_depth;
                        if (lhs.scope_id != rhs.scope_id) return lhs.scope_id < rhs.scope_id;
                        if (lhs.ordinal != rhs.ordinal) return lhs.ordinal < rhs.ordinal;
                        return lhs.node_id < rhs.node_id;
                    }
                };
                std.mem.sort(usize, ordered, Order{ .engine = engine, .changes = changes }, Order.lessThan);

                var selected = std.ArrayListUnmanaged(usize).empty;
                errdefer selected.deinit(allocator);
                var subsumed = std.ArrayListUnmanaged(usize).empty;
                errdefer subsumed.deinit(allocator);
                selected.ensureTotalCapacity(allocator, changes.len) catch return error.OutOfMemory;
                subsumed.ensureTotalCapacity(allocator, changes.len) catch return error.OutOfMemory;

                var replacement_roots = std.AutoHashMapUnmanaged(u64, void).empty;
                defer replacement_roots.deinit(allocator);
                const change_count: u32 = std.math.cast(u32, changes.len) orelse return error.ResourceLimit;
                replacement_roots.ensureTotalCapacity(allocator, change_count) catch return error.OutOfMemory;
                var replaces_root = false;

                for (ordered) |index| {
                    const change = changes[index];
                    if (change.kind != .when) return error.ResourceLimit;

                    var covered = replaces_root;
                    var ancestor: ?u64 = change.scope_id;
                    while (!covered and ancestor != null) {
                        const scope_id = ancestor.?;
                        if (replacement_roots.contains(scope_id)) {
                            covered = true;
                            break;
                        }
                        if (scope_id >= engine.scopes.items.len) return error.ResourceLimit;
                        ancestor = engine.scopes.items[@intCast(scope_id)].parent_scope_id;
                    }
                    if (covered) {
                        subsumed.appendAssumeCapacity(index);
                        continue;
                    }

                    selected.appendAssumeCapacity(index);
                    const branch = change.branch orelse return error.ResourceLimit;
                    const replacement_root = engine.activeWhenBranchScopeId(change.scope_id, change.ordinal, branch.opposite()) catch return error.ResourceLimit;
                    if (replacement_root) |scope_id| {
                        replacement_roots.putAssumeCapacity(scope_id, {});
                    } else {
                        replaces_root = true;
                    }
                }

                const selected_indexes = selected.toOwnedSlice(allocator) catch return error.OutOfMemory;
                errdefer allocator.free(selected_indexes);
                const subsumed_indexes = subsumed.toOwnedSlice(allocator) catch return error.OutOfMemory;
                allocator.free(ordered);
                return .{
                    .selected_indexes = selected_indexes,
                    .subsumed_indexes = subsumed_indexes,
                };
            }

            fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                allocator.free(self.selected_indexes);
                allocator.free(self.subsumed_indexes);
                self.* = undefined;
            }
        };

        /// Applies dirty when structural signals after preparation has fixed semantics and reserved fallible growth.
        pub fn applyDirtyWhenStructuralSignals(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, dirty_source_node_ids: []const u64, dirty_generation: u64, changes: []HostDirtyStructuralSignal) render.Counts {
            for (changes) |change| {
                if (change.kind != .when) @panic("non-when structural change reached when-only test helper");
            }
            if (self.tryApplyPreparedDirtyWhenSet(ctx, roc_host, dirty_source_node_ids, changes) catch @panic("failed to prepare atomic dirty-when transaction")) |counts| return counts;
            return self.applyDirtyStructuralSignalsLocally(ctx, roc_host, dirty_source_node_ids, dirty_generation, changes);
        }

        fn tryApplyPreparedDirtyWhenSet(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, dirty_source_node_ids: []const u64, changes: []HostDirtyStructuralSignal) CollectionError!?render.Counts {
            if (changes.len == 0 or !self.render_cache.hasRoot()) return null;
            const allocator = Ctx.allocator(ctx);
            var normalized = try PreparedDirtyWhenSet.prepare(self, allocator, changes);
            defer normalized.deinit(allocator);
            if (normalized.selected_indexes.len == 0) return null;

            const selections = allocator.alloc(AggregateBranchSelection, normalized.selected_indexes.len) catch return error.OutOfMemory;
            defer allocator.free(selections);
            for (normalized.selected_indexes, 0..) |change_index, selection_index| {
                const change = changes[change_index];
                const site = self.activeScopeSiteByNodeId(change.node_id, .when) orelse return null;
                if (site.scope_id != change.scope_id or site.ordinal != change.ordinal) return null;
                const when_index = self.activeWhenIndexByNodeId(change.node_id) orelse return null;
                const when_desc = self.active_stream.whens.items[when_index];
                if (when_desc.condition.record != change.record) return null;
                const branch = change.branch orelse return error.ResourceLimit;
                const retired_scope_id = (self.activeWhenBranchScopeId(site.scope_id, site.ordinal, branch.opposite()) catch return error.ResourceLimit) orelse return null;
                // Reusing a previously active branch requires a different ownership
                // transfer plan; retain the legacy path until that case is staged.
                if ((self.activeWhenBranchScopeId(site.scope_id, site.ordinal, branch) catch return error.ResourceLimit) != null) return null;
                selections[selection_index] = .{
                    .parent_scope_id = site.scope_id,
                    .site_ordinal = site.ordinal,
                    .parent_elem_id = site.parent_elem_id,
                    .retired_scope_id = retired_scope_id,
                    .render_insert_index = site.render_insert_index,
                    .binder_bindings = site.binder_bindings,
                    .branch = branch,
                    .elem = switch (branch) {
                        .true_branch => when_desc.when_true,
                        .false_branch => when_desc.when_false,
                    },
                };
            }

            const plan = try AggregateBranchCollection.prepare(self, ctx, roc_host, selections, .{}, dirty_source_node_ids);
            defer plan.deinit();
            var counts = plan.render_splice.?.wire.counts();
            plan.commitAssumeCapacity();
            for (normalized.selected_indexes) |change_index| {
                const change = &changes[change_index];
                const when_index = self.activeWhenIndexByNodeId(change.node_id) orelse @panic("published dirty when descriptor disappeared");
                change.commitPendingWhenCache(&self.active_stream.whens.items[when_index].cached_value, ctx, roc_host, &self.pending_roc_metrics);
            }
            for (normalized.subsumed_indexes) |change_index| changes[change_index].abortPendingWhenCache(ctx, roc_host, &self.pending_roc_metrics);
            // These callbacks can allocate and trigger user effects, so they run
            // only after the atomic engine/cache/host publication above.
            counts.addAll(self.runActiveOnChangeInitialCommandIndices(ctx, roc_host, plan.publication.?.replacement_on_change_indices));
            counts.addAll(self.runActiveMountCommandIndices(ctx, roc_host, plan.publication.?.replacement_mount_indices));
            return counts;
        }

        /// Appends pending task using capacity that must already satisfy the caller's transaction contract.
        pub fn appendPendingTask(self: *Self, ctx: Ctx.Handle, owner_scope_id: u64, task_token: HostSignalToken, task_name: []const u8, request: []const u8) u64 {
            return effects_runtime.appendPendingTask(Ctx.allocator(ctx), &self.pending_tasks, &self.next_task_request_id, self.roc_host.?, owner_scope_id, task_token, task_name, request);
        }

        /// Resolves pending task index by name from the bounded task registry without scanning unrelated work.
        pub fn pendingTaskIndexByName(self: *Self, name: []const u8) ?usize {
            return effects_runtime.pendingTaskIndexByName(self.pending_tasks.items, name);
        }

        /// Removes pending task at and releases the ownership attached to that live entry.
        pub fn removePendingTaskAt(self: *Self, index: usize) HostPendingTask {
            return effects_runtime.removePendingTaskAt(&self.pending_tasks, index);
        }

        /// Returns active task record by name from the maintained active-runtime indexes.
        pub fn activeTaskRecordByName(self: *Self, name: []const u8) ?*HostSignalRecord {
            return effects_runtime.activeTaskRecordByName(self.active_signal_graph.items, name);
        }

        /// Returns active interval record by period from the maintained active-runtime indexes.
        pub fn activeIntervalRecordByPeriod(self: *Self, period_ms: u64) ?*HostSignalRecord {
            return effects_runtime.activeIntervalRecordByPeriod(self.active_signal_graph.items, period_ms);
        }

        /// Performs rebuild active events from stream inside the shared engine while preserving transaction and changed-set invariants.
        pub fn rebuildActiveEventsFromStream(self: *Self, ctx: Ctx.Handle, stream: *HostNodeDescriptorStream) void {
            const allocator = Ctx.allocator(ctx);
            self.clearActiveEvents() catch @panic("active event table cannot release retained payloads without a Roc host");

            for (stream.events.items) |*desc| {
                if (!desc.owns_payload_reducer) @panic("event descriptor payload reducer ownership was already transferred");
                self.active_events.append(allocator, .{
                    .target_node_id = desc.target_node_id,
                    .read_node_id = desc.read_node_id,
                    .payload_descriptor = desc.payload_descriptor,
                    .payload_reducer = desc.payload_reducer,
                }) catch @panic("out of memory");
                desc.owns_payload_reducer = false;
            }
        }

        /// Performs update effect source cache slot inside the shared engine while preserving transaction and changed-set invariants.
        pub fn updateEffectSourceCacheSlot(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, cache_slot: *HostSignalCacheSlot, value: HostValue, cap: HostValueCapability) bool {
            switch (cache_slot.*) {
                .absent => {
                    debugPhase(ctx, .effect_cache_initialize);
                    cache_slot.replace(ctx, roc_host, &self.pending_roc_metrics, value, cap);
                    return true;
                },
                .present => |*cached| {
                    debugPhase(ctx, .effect_cache_compare);
                    if (cached.valueEquals(ctx, roc_host, value)) {
                        debugPhase(ctx, .effect_cache_drop_equal);
                        cached.dropIncoming(ctx, roc_host, value);
                        self.recordSignalPrune();
                        return false;
                    }
                    debugPhase(ctx, .effect_cache_replace);
                    cached.replaceValue(ctx, roc_host, value);
                    return true;
                },
            }
        }

        /// Performs update effect source cache inside the shared engine while preserving transaction and changed-set invariants.
        pub fn updateEffectSourceCache(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, record: *HostSignalRecord, value: HostValue) bool {
            const source = record.effectSource() orelse @panic("effect source update targeted a non-source signal record");
            return self.updateEffectSourceCacheSlot(ctx, roc_host, source.cachedSlot(), value, source.capability());
        }

        /// Applies dirty signal batch after preparation has fixed semantics and reserved fallible growth.
        pub fn applyDirtySignalBatch(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, dirty_source_node_ids: []const u64, changed_record_ids: []const u64, dirty_generation: u64) render.Counts {
            const allocator = Ctx.allocator(ctx);
            const stable_changed_record_ids = allocator.dupe(u64, changed_record_ids) catch @panic("out of memory");
            defer allocator.free(stable_changed_record_ids);

            var pending_on_change_commands: std.ArrayListUnmanaged(HostPendingOnChangeCommand) = .empty;
            defer {
                for (pending_on_change_commands.items) |pending| {
                    pending.cmd.decref(roc_host);
                }
                pending_on_change_commands.deinit(allocator);
            }

            var deferred_storage_effects: std.ArrayListUnmanaged(HostDeferredStorageEffect) = .empty;
            defer {
                for (deferred_storage_effects.items) |effect| allocator.free(effect.key);
                deferred_storage_effects.deinit(allocator);
            }
            var deferred_location_effect = false;

            debugPhase(ctx, .collect_dirty_sinks);
            var counts = self.collectDirtyRenderSinksAndCommands(
                ctx,
                roc_host,
                dirty_source_node_ids,
                stable_changed_record_ids,
                dirty_generation,
                &pending_on_change_commands,
            );

            debugPhase(ctx, .collect_dirty_structure);
            const dirty_structural_signals = self.collectDirtyStructuralSignals(ctx, roc_host, allocator, dirty_source_node_ids, stable_changed_record_ids, dirty_generation);
            defer {
                for (dirty_structural_signals) |*change| change.abortPendingWhenCache(ctx, roc_host, &self.pending_roc_metrics);
                allocator.free(dirty_structural_signals);
            }
            if (dirty_structural_signals.len != 0) {
                debugPhase(ctx, .apply_dirty_structure);
                counts.addAll(self.applyDirtyStructuralSignalsLocally(ctx, roc_host, dirty_source_node_ids, dirty_generation, dirty_structural_signals));
            }
            debugPhase(ctx, .apply_dirty_commands);
            counts.addAll(self.runPendingOnChangeCommandsDeferringSourceEffects(
                ctx,
                roc_host,
                pending_on_change_commands.items,
                &deferred_location_effect,
                &deferred_storage_effects,
            ));
            debugPhase(ctx, .flush_deferred_effects);
            counts.addAll(self.flushDeferredSourceEffects(ctx, roc_host, deferred_location_effect, deferred_storage_effects.items));
            debugPhase(ctx, .dirty_batch_complete);
            return counts;
        }

        /// Dispatches effect source value through validated routing and dependency-ordered propagation.
        pub fn dispatchEffectSourceValue(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, record: *HostSignalRecord, value: HostValue) render.Counts {
            debugPhase(ctx, .dispatch_effect_source);
            if (!self.updateEffectSourceCache(ctx, roc_host, record, value)) return .{};

            self.recordDispatch();
            var metrics = self.pending_roc_metrics;
            metrics.bump(.dirty_source_roots, 1);
            self.pending_roc_metrics = metrics;
            const dirty_generation = self.nextDirtySignalGeneration();
            record.last_dirty_generation = dirty_generation;
            record.last_dirty_changed = true;

            const record_id = self.requireActiveSignalRecordId(record);
            const roots = [_]u64{record_id};
            const dirty_record_ids = self.scratchDirtyActiveSignalRecordIdsForRoots(ctx, &roots);

            debugPhase(ctx, .dispatch_effect_propagate);
            const changed_record_ids = self.propagateDirtyActiveSignalRecordIds(ctx, roc_host, dirty_record_ids, &.{}, dirty_generation);
            debugPhase(ctx, .dispatch_effect_apply);
            return self.applyDirtySignalBatch(ctx, roc_host, &.{}, changed_record_ids, dirty_generation);
        }

        fn locationSnapshotFromCommandPayload(payload: anytype) boundary.LocationSnapshot {
            return .{
                .path = payload.path.asSlice(),
                .query = payload.query.asSlice(),
                .hash = payload.hash.asSlice(),
            };
        }

        fn storageAreaFromCommand(area_id: u64) boundary.StorageArea {
            return boundary.StorageArea.fromId(area_id) orelse @panic("storage command referenced an unknown storage area");
        }

        /// Dispatches current location sources through validated routing and dependency-ordered propagation.
        pub fn dispatchCurrentLocationSources(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost) render.Counts {
            const allocator = Ctx.allocator(ctx);
            var root_record_ids: std.ArrayListUnmanaged(u64) = .empty;
            defer root_record_ids.deinit(allocator);

            const dirty_generation = self.nextDirtySignalGeneration();
            for (self.active_signal_graph.items, 0..) |node, index| {
                const payload = node.record.locationSource() orelse continue;
                const raw_payload = Ctx.initialLocationPayload(ctx, roc_host, payload.payload_cap);
                const next = callHostValueToHostValueWithCapability(ctx, roc_host, payload.payload_cap, payload.from_payload, raw_payload);
                if (!self.updateEffectSourceCache(ctx, roc_host, node.record, next)) continue;

                node.record.last_dirty_generation = dirty_generation;
                node.record.last_dirty_changed = true;
                root_record_ids.append(allocator, @intCast(index)) catch @panic("out of memory");
            }

            if (root_record_ids.items.len == 0) return .{};

            self.recordDispatch();
            var metrics = self.pending_roc_metrics;
            metrics.bump(.dirty_source_roots, @intCast(root_record_ids.items.len));
            self.pending_roc_metrics = metrics;

            const dirty_record_ids = self.scratchDirtyActiveSignalRecordIdsForRoots(ctx, root_record_ids.items);
            const changed_record_ids = self.propagateDirtyActiveSignalRecordIds(ctx, roc_host, dirty_record_ids, &.{}, dirty_generation);
            return self.applyDirtySignalBatch(ctx, roc_host, &.{}, changed_record_ids, dirty_generation);
        }

        /// Dispatches current visibility sources through validated routing and dependency-ordered propagation.
        pub fn dispatchCurrentVisibilitySources(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost) render.Counts {
            const allocator = Ctx.allocator(ctx);
            var root_record_ids: std.ArrayListUnmanaged(u64) = .empty;
            defer root_record_ids.deinit(allocator);

            const dirty_generation = self.nextDirtySignalGeneration();
            for (self.active_signal_graph.items, 0..) |node, index| {
                const payload = node.record.visibilitySource() orelse continue;
                const raw_payload = Ctx.initialVisibilityPayload(ctx, roc_host, payload.payload_cap);
                const next = callHostValueToHostValueWithCapability(ctx, roc_host, payload.payload_cap, payload.from_payload, raw_payload);
                if (!self.updateEffectSourceCache(ctx, roc_host, node.record, next)) continue;

                node.record.last_dirty_generation = dirty_generation;
                node.record.last_dirty_changed = true;
                root_record_ids.append(allocator, @intCast(index)) catch @panic("out of memory");
            }

            if (root_record_ids.items.len == 0) return .{};

            self.recordDispatch();
            var metrics = self.pending_roc_metrics;
            metrics.bump(.dirty_source_roots, @intCast(root_record_ids.items.len));
            self.pending_roc_metrics = metrics;

            const dirty_record_ids = self.scratchDirtyActiveSignalRecordIdsForRoots(ctx, root_record_ids.items);
            const changed_record_ids = self.propagateDirtyActiveSignalRecordIds(ctx, roc_host, dirty_record_ids, &.{}, dirty_generation);
            return self.applyDirtySignalBatch(ctx, roc_host, &.{}, changed_record_ids, dirty_generation);
        }

        /// Dispatches current online sources through validated routing and dependency-ordered propagation.
        pub fn dispatchCurrentOnlineSources(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost) render.Counts {
            const allocator = Ctx.allocator(ctx);
            var root_record_ids: std.ArrayListUnmanaged(u64) = .empty;
            defer root_record_ids.deinit(allocator);

            const dirty_generation = self.nextDirtySignalGeneration();
            for (self.active_signal_graph.items, 0..) |node, index| {
                const payload = node.record.onlineSource() orelse continue;
                const raw_payload = Ctx.initialOnlinePayload(ctx, roc_host, payload.payload_cap);
                const next = callHostValueToHostValueWithCapability(ctx, roc_host, payload.payload_cap, payload.from_payload, raw_payload);
                if (!self.updateEffectSourceCache(ctx, roc_host, node.record, next)) continue;

                node.record.last_dirty_generation = dirty_generation;
                node.record.last_dirty_changed = true;
                root_record_ids.append(allocator, @intCast(index)) catch @panic("out of memory");
            }

            if (root_record_ids.items.len == 0) return .{};

            self.recordDispatch();
            var metrics = self.pending_roc_metrics;
            metrics.bump(.dirty_source_roots, @intCast(root_record_ids.items.len));
            self.pending_roc_metrics = metrics;

            const dirty_record_ids = self.scratchDirtyActiveSignalRecordIdsForRoots(ctx, root_record_ids.items);
            const changed_record_ids = self.propagateDirtyActiveSignalRecordIds(ctx, roc_host, dirty_record_ids, &.{}, dirty_generation);
            return self.applyDirtySignalBatch(ctx, roc_host, &.{}, changed_record_ids, dirty_generation);
        }

        /// Dispatches current storage sources through validated routing and dependency-ordered propagation.
        pub fn dispatchCurrentStorageSources(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, area: boundary.StorageArea, key: []const u8) render.Counts {
            const allocator = Ctx.allocator(ctx);
            var root_record_ids: std.ArrayListUnmanaged(u64) = .empty;
            defer root_record_ids.deinit(allocator);

            const dirty_generation = self.nextDirtySignalGeneration();
            for (self.active_signal_graph.items, 0..) |node, index| {
                const payload = node.record.storageSource() orelse continue;
                if (payload.area != area or !std.mem.eql(u8, payload.key, key)) continue;

                const raw_payload = Ctx.initialStoragePayload(ctx, roc_host, payload.area, payload.key, payload.payload_cap);
                const next = callHostValueToHostValueWithCapability(ctx, roc_host, payload.payload_cap, payload.from_payload, raw_payload);
                if (!self.updateEffectSourceCache(ctx, roc_host, node.record, next)) continue;

                node.record.last_dirty_generation = dirty_generation;
                node.record.last_dirty_changed = true;
                root_record_ids.append(allocator, @intCast(index)) catch @panic("out of memory");
            }

            if (root_record_ids.items.len == 0) return .{};

            self.recordDispatch();
            var metrics = self.pending_roc_metrics;
            metrics.bump(.dirty_source_roots, @intCast(root_record_ids.items.len));
            self.pending_roc_metrics = metrics;

            const dirty_record_ids = self.scratchDirtyActiveSignalRecordIdsForRoots(ctx, root_record_ids.items);
            const changed_record_ids = self.propagateDirtyActiveSignalRecordIds(ctx, roc_host, dirty_record_ids, &.{}, dirty_generation);
            return self.applyDirtySignalBatch(ctx, roc_host, &.{}, changed_record_ids, dirty_generation);
        }

        /// Publishes a location change and refreshes active location sources in the same engine turn.
        pub fn navigateLocationCommand(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, kind: NavigationKind, location: boundary.LocationSnapshot) render.Counts {
            Ctx.sink(ctx).navigate(kind, location);
            return self.dispatchCurrentLocationSources(ctx, roc_host);
        }

        /// Sets storage text command at the narrow host or engine boundary that owns the mutation.
        pub fn setStorageTextCommand(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, payload: anytype) render.Counts {
            const area = storageAreaFromCommand(payload.area);
            const key = payload.key.asSlice();
            Ctx.sink(ctx).setStorageText(area, key, payload.value.asSlice());
            return self.dispatchCurrentStorageSources(ctx, roc_host, area, key);
        }

        /// Sets document title command at the narrow host or engine boundary that owns the mutation.
        pub fn setDocumentTitleCommand(_: *Self, ctx: Ctx.Handle, payload: anytype) render.Counts {
            Ctx.sink(ctx).setDocumentTitle(payload.title.asSlice());
            return .{};
        }

        /// Removes storage command and releases the ownership attached to that live entry.
        pub fn removeStorageCommand(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, payload: anytype) render.Counts {
            const area = storageAreaFromCommand(payload.area);
            const key = payload.key.asSlice();
            Ctx.sink(ctx).removeStorage(area, key);
            return self.dispatchCurrentStorageSources(ctx, roc_host, area, key);
        }

        /// Performs start task command inside the shared engine while preserving transaction and changed-set invariants.
        pub fn startTaskCommand(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, owner_scope_id: u64, cmd: erased_calls.StartTaskCmd) render.Counts {
            const task_token = retained_values.hostSignalTokenFromCallable(cmd.task_token);
            const record = self.activeTaskRecordByToken(task_token) orelse {
                if (self.activeTaskRecordByName(cmd.task_name.asSlice()) != null) {
                    @panic("StartTask token did not match the active task source with the same name");
                }
                if (comptime @hasDecl(Ctx, "debugInactiveTask")) {
                    Ctx.debugInactiveTask(ctx, cmd.task_name.asSlice());
                }
                @panic("StartTask referenced a task source that is not active");
            };
            const task_payload = record.requireTaskSource();
            if (!std.mem.eql(u8, task_payload.name, cmd.task_name.asSlice())) {
                @panic("StartTask task name does not match the referenced task source");
            }

            const request_value = erased_calls.callValueInitThunk(roc_host, cmd.request_init);
            defer callHostValueToUnitWithCapability(ctx, roc_host, cmd.request_read.capability, hv.hostValueCapabilityDrop(cmd.request_read.capability), request_value);
            const request = callHostValueToStrWithCapability(ctx, roc_host, cmd.request_read.capability, cmd.request_read.read, request_value);
            defer request.decref(roc_host);

            self.cancelPendingTasksByTaskToken(ctx, task_token);
            _ = effects_runtime.appendAndStartPendingTask(Ctx, ctx, Ctx.allocator(ctx), &self.pending_tasks, &self.next_task_request_id, self.roc_host.?, owner_scope_id, task_token, cmd.task_name.asSlice(), request.asSlice());

            if (task_payload.reset_on_start) {
                const loading = erased_calls.callValueInitThunk(roc_host, task_payload.initial);
                return self.dispatchEffectSourceValue(ctx, roc_host, record, loading);
            }

            return .{};
        }

        /// Performs update state command inside the shared engine while preserving transaction and changed-set invariants.
        pub fn updateStateCommand(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, owner_scope_id: u64, cmd: erased_calls.UpdateStateCmd) render.Counts {
            const binder_token = retained_values.hostSignalTokenFromCallable(cmd.binder);
            const target_node_id = self.resolveStateCommandTarget(owner_scope_id, binder_token);
            const state_cap = Ctx.stateCapability(ctx, target_node_id);
            assertHostValueCapabilitiesMatch(cmd.update.capability, state_cap, "state command value capability did not match its target state");

            if (!Ctx.updateStateValue(ctx, roc_host, target_node_id, cmd.update.value)) {
                self.recordSignalPrune();
                return .{};
            }

            self.recordDispatch();
            var metrics = self.pending_roc_metrics;
            metrics.bump(.dirty_source_roots, 1);
            self.pending_roc_metrics = metrics;

            const dirty_source_node_ids = [_]u64{target_node_id};
            const dirty_generation = self.nextDirtySignalGeneration();
            const dirty_record_ids = self.scratchDirtyActiveSignalRecordIdsForSources(ctx, &dirty_source_node_ids);
            const changed_record_ids = self.propagateDirtyActiveSignalRecordIds(ctx, roc_host, dirty_record_ids, &dirty_source_node_ids, dirty_generation);
            return self.applyDirtySignalBatch(ctx, roc_host, &dirty_source_node_ids, changed_record_ids, dirty_generation);
        }

        /// Runs command using the host semantics and measurement boundaries defined by this module.
        pub fn runCommand(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, owner_scope_id: u64, cmd: erased_calls.Cmd) render.Counts {
            return switch (cmd.tag) {
                .Noop => .{},
                .PushState => blk: {
                    const payload = cmd.payload_push_state();
                    break :blk self.navigateLocationCommand(ctx, roc_host, .push, locationSnapshotFromCommandPayload(&payload));
                },
                .RemoveStorage => self.removeStorageCommand(ctx, roc_host, cmd.payload_remove_storage()),
                .ReplaceState => blk: {
                    const payload = cmd.payload_replace_state();
                    break :blk self.navigateLocationCommand(ctx, roc_host, .replace, locationSnapshotFromCommandPayload(&payload));
                },
                .SetStorageText => self.setStorageTextCommand(ctx, roc_host, cmd.payload_set_storage_text()),
                .StartTask => self.startTaskCommand(ctx, roc_host, owner_scope_id, cmd.payload_start_task()),
                .SetDocumentTitle => self.setDocumentTitleCommand(ctx, cmd.payload_set_document_title()),
                .UpdateState => self.updateStateCommand(ctx, roc_host, owner_scope_id, cmd.payload_update_state()),
            };
        }

        fn tickIntervalRecord(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, record: *HostSignalRecord) render.Counts {
            const interval_payload = record.requireIntervalSource();
            const current = self.evalHostSignalRecord(ctx, roc_host, record);
            defer self.dropHostSignalRecordValue(ctx, roc_host, record, current);
            const next = callHostValueToHostValueWithCapability(ctx, roc_host, interval_payload.cap, interval_payload.tick, current);
            return self.dispatchEffectSourceValue(ctx, roc_host, record, next);
        }

        /// Advances interval source through the shared propagation queue.
        pub fn tickIntervalSource(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, period_ms: u64) render.Counts {
            const record = self.activeIntervalRecordByPeriod(period_ms) orelse @panic("tick_interval matched no active interval source");
            return self.tickIntervalRecord(ctx, roc_host, record);
        }

        /// Advances interval source by runtime token through the shared propagation queue.
        pub fn tickIntervalSourceByRuntimeToken(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, token: u64) render.Counts {
            const source_token = self.activeIntervalSourceTokenByRuntimeToken(token) orelse @panic("timer tick referenced an inactive interval token");
            const record = self.activeIntervalRecordByToken(source_token) orelse @panic("timer tick matched no active interval source");
            return self.tickIntervalRecord(ctx, roc_host, record);
        }

        /// Performs eval dirty on change command inside the shared engine while preserving transaction and changed-set invariants.
        pub fn evalDirtyOnChangeCommand(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, desc: *HostNodeOnChangeDesc, dirty_source_node_ids: []const u64, dirty_generation: u64) ?HostPendingOnChangeCommand {
            const result = self.evalDirtyHostSignalBinding(ctx, roc_host, &desc.signal, dirty_source_node_ids, dirty_generation);
            const cap = self.hostSignalBindingCapability(ctx, &desc.signal);
            if (!result.changed) {
                callHostValueToUnitWithCapability(ctx, roc_host, cap, hv.hostValueCapabilityDrop(cap), result.value);
                return null;
            }
            if (!self.updateDirtySignalCache(ctx, roc_host, &desc.cached_value, result.value, cap)) return null;

            const value = self.cloneCachedSignalValue(ctx, &desc.cached_value);
            defer callHostValueToUnitWithCapability(ctx, roc_host, cap, hv.hostValueCapabilityDrop(cap), value);
            const cmd = callHostValueToCmdWithCapability(ctx, roc_host, cap, desc.to_cmd, value);
            cmd.incref(1);
            cmd.decref(roc_host);
            return .{ .scope_id = desc.scope_id, .cmd = cmd };
        }

        /// Performs eval dirty on change inside the shared engine while preserving transaction and changed-set invariants.
        pub fn evalDirtyOnChange(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, desc: *HostNodeOnChangeDesc, dirty_source_node_ids: []const u64, dirty_generation: u64) render.Counts {
            const pending = self.evalDirtyOnChangeCommand(ctx, roc_host, desc, dirty_source_node_ids, dirty_generation) orelse return .{};
            const cmd = pending.cmd;
            defer cmd.decref(roc_host);
            return self.runCommand(ctx, roc_host, pending.scope_id, cmd);
        }

        fn collectDirtyRenderSinksAndCommands(
            self: *Self,
            ctx: Ctx.Handle,
            roc_host: *abi.RocHost,
            dirty_source_node_ids: []const u64,
            changed_record_ids: []const u64,
            dirty_generation: u64,
            pending_on_change_commands: *std.ArrayListUnmanaged(HostPendingOnChangeCommand),
        ) render.Counts {
            var counts: render.Counts = .{};
            const allocator = Ctx.allocator(ctx);

            for (changed_record_ids) |record_id| {
                const route_index: usize = @intCast(record_id);
                if (route_index < self.active_text_signal_routes.items.len) {
                    for (self.active_text_signal_routes.items[route_index].items) |route| {
                        switch (route.kind) {
                            .text_node => {
                                const desc = &self.active_stream.signal_text_nodes.items[route.index];
                                if (self.evalDirtySignalTextField(ctx, roc_host, desc.elem_id, .text, &desc.signal, desc.read, &desc.cached_value, dirty_source_node_ids, dirty_generation)) {
                                    counts.addTextField(.text);
                                }
                            },
                            .text_attr => {
                                const desc = &self.active_stream.signal_text_attrs.items[route.index];
                                if (self.evalDirtySignalTextField(ctx, roc_host, desc.elem_id, desc.field, &desc.signal, desc.read, &desc.cached_value, dirty_source_node_ids, dirty_generation)) {
                                    counts.addTextField(desc.field);
                                }
                            },
                            .custom_text_attr => {
                                const desc = &self.active_stream.signal_custom_text_attrs.items[route.index];
                                if (self.evalDirtySignalTextAttr(ctx, roc_host, desc.elem_id, desc.name, &desc.signal, desc.read, &desc.cached_value, dirty_source_node_ids, dirty_generation)) {
                                    counts.addTextAttr();
                                }
                            },
                            .custom_text_optional_attr => {
                                const desc = &self.active_stream.signal_optional_custom_text_attrs.items[route.index];
                                if (self.evalDirtySignalOptionalTextAttr(ctx, roc_host, desc.elem_id, desc.name, &desc.signal, desc.present, desc.read, &desc.cached_value, dirty_source_node_ids, dirty_generation)) {
                                    counts.addTextAttr();
                                }
                            },
                        }
                    }
                }

                if (route_index < self.active_bool_signal_routes.items.len) {
                    for (self.active_bool_signal_routes.items[route_index].items) |route| {
                        switch (route.kind) {
                            .bool_attr => {
                                const desc = &self.active_stream.signal_bool_attrs.items[route.index];
                                if (self.evalDirtySignalBoolField(ctx, roc_host, desc.elem_id, desc.field, &desc.signal, desc.read, &desc.cached_value, dirty_source_node_ids, dirty_generation)) {
                                    counts.addBoolField(desc.field);
                                }
                            },
                            .custom_bool_attr => {
                                const desc = &self.active_stream.signal_custom_bool_attrs.items[route.index];
                                if (self.evalDirtySignalBoolAttr(ctx, roc_host, desc.elem_id, desc.name, &desc.signal, desc.read, &desc.cached_value, dirty_source_node_ids, dirty_generation)) {
                                    counts.addTextAttr();
                                }
                            },
                        }
                    }
                }

                if (route_index < self.active_change_signal_routes.items.len) {
                    for (self.active_change_signal_routes.items[route_index].items) |route| {
                        const desc = &self.active_stream.on_changes.items[route.index];
                        if (self.evalDirtyOnChangeCommand(ctx, roc_host, desc, dirty_source_node_ids, dirty_generation)) |pending| {
                            pending_on_change_commands.append(allocator, pending) catch @panic("out of memory");
                        }
                    }
                }
            }

            if (comptime enable_runtime_metrics) self.render_metrics.addCommandCounts(counts);
            return counts;
        }

        fn runPendingOnChangeCommandsDeferringSourceEffects(
            self: *Self,
            ctx: Ctx.Handle,
            roc_host: *abi.RocHost,
            pending_on_change_commands: []const HostPendingOnChangeCommand,
            deferred_location_effect: *bool,
            deferred_storage_effects: *std.ArrayListUnmanaged(HostDeferredStorageEffect),
        ) render.Counts {
            var counts: render.Counts = .{};
            const allocator = Ctx.allocator(ctx);

            for (pending_on_change_commands) |pending| {
                if (pending.scope_id >= self.scopes.items.len or !self.scopes.items[@intCast(pending.scope_id)].active) {
                    if (pending.cmd.tag == .UpdateState) {
                        const update = pending.cmd.payload_update_state().update;
                        callHostValueToUnitWithCapability(ctx, roc_host, update.capability, hv.hostValueCapabilityDrop(update.capability), update.value);
                    }
                    continue;
                }
                switch (pending.cmd.tag) {
                    .PushState => {
                        const payload = pending.cmd.payload_push_state();
                        const location = locationSnapshotFromCommandPayload(&payload);
                        Ctx.sink(ctx).navigate(.push, location);
                        deferred_location_effect.* = true;
                    },
                    .ReplaceState => {
                        const payload = pending.cmd.payload_replace_state();
                        const location = locationSnapshotFromCommandPayload(&payload);
                        Ctx.sink(ctx).navigate(.replace, location);
                        deferred_location_effect.* = true;
                    },
                    .SetStorageText => {
                        const payload = pending.cmd.payload_set_storage_text();
                        const area = storageAreaFromCommand(payload.area);
                        const key = payload.key.asSlice();
                        Ctx.sink(ctx).setStorageText(area, key, payload.value.asSlice());
                        deferred_storage_effects.append(allocator, .{ .area = area, .key = allocator.dupe(u8, key) catch @panic("out of memory") }) catch @panic("out of memory");
                    },
                    .RemoveStorage => {
                        const payload = pending.cmd.payload_remove_storage();
                        const area = storageAreaFromCommand(payload.area);
                        const key = payload.key.asSlice();
                        Ctx.sink(ctx).removeStorage(area, key);
                        deferred_storage_effects.append(allocator, .{ .area = area, .key = allocator.dupe(u8, key) catch @panic("out of memory") }) catch @panic("out of memory");
                    },
                    else => counts.addAll(self.runCommand(ctx, roc_host, pending.scope_id, pending.cmd)),
                }
            }

            if (comptime enable_runtime_metrics) self.render_metrics.addCommandCounts(counts);
            return counts;
        }

        fn flushDeferredSourceEffects(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, deferred_location_effect: bool, deferred_storage_effects: []const HostDeferredStorageEffect) render.Counts {
            var counts: render.Counts = .{};
            if (deferred_location_effect) counts.addAll(self.dispatchCurrentLocationSources(ctx, roc_host));
            for (deferred_storage_effects) |effect| {
                counts.addAll(self.dispatchCurrentStorageSources(ctx, roc_host, effect.area, effect.key));
            }
            return counts;
        }

        /// Applies dirty render sinks after preparation has fixed semantics and reserved fallible growth.
        pub fn applyDirtyRenderSinks(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, dirty_source_node_ids: []const u64, changed_record_ids: []const u64, dirty_generation: u64) render.Counts {
            const allocator = Ctx.allocator(ctx);
            var pending_on_change_commands: std.ArrayListUnmanaged(HostPendingOnChangeCommand) = .empty;
            defer {
                for (pending_on_change_commands.items) |pending| {
                    pending.cmd.decref(roc_host);
                }
                pending_on_change_commands.deinit(allocator);
            }
            var deferred_storage_effects: std.ArrayListUnmanaged(HostDeferredStorageEffect) = .empty;
            defer {
                for (deferred_storage_effects.items) |effect| allocator.free(effect.key);
                deferred_storage_effects.deinit(allocator);
            }
            var deferred_location_effect = false;
            var counts = self.collectDirtyRenderSinksAndCommands(
                ctx,
                roc_host,
                dirty_source_node_ids,
                changed_record_ids,
                dirty_generation,
                &pending_on_change_commands,
            );
            counts.addAll(self.runPendingOnChangeCommandsDeferringSourceEffects(
                ctx,
                roc_host,
                pending_on_change_commands.items,
                &deferred_location_effect,
                &deferred_storage_effects,
            ));
            counts.addAll(self.flushDeferredSourceEffects(ctx, roc_host, deferred_location_effect, deferred_storage_effects.items));
            return counts;
        }
    };
}

const VerifyCtxHost = struct {
    allocator: std.mem.Allocator,
    render_batch: render.TransactionalBatch = .{},
    state_capability: HostValueCapability = std.mem.zeroes(HostValueCapability),
    cancelled_tasks: usize = 0,

    /// Produces an independently owned copy through the value's app-compiled capability.
    pub fn cloneHostValue(_: *@This(), value: HostValue) HostValue {
        return value;
    }

    /// Opens a checked capability frame for an app-compiled erased call.
    pub fn pushHostValueCapabilities(_: *@This(), _: []const HostValueCapability) void {}

    /// Closes the current capability frame after an app-compiled erased call.
    pub fn popHostValueCapabilities(_: *@This()) void {}
};

test "structural event validation rejects descriptors outside seen render stream" {
    const allocator = std.testing.allocator;
    var stream: HostNodeDescriptorStream = .{};
    defer stream.events.deinit(allocator);

    const binder: HostBinderToken = @ptrFromInt(0x1000);
    try stream.events.append(allocator, .{
        .elem_id = 5,
        .binding = .{ .fixed = .click },
        .binder_token = binder,
        .target_node_id = 1,
        .read_binder_token = binder,
        .read_node_id = 1,
        .payload_descriptor = BoundaryPayloadDescriptor.init(.unit, .none),
        .payload_reducer = undefined,
        .owns_payload_reducer = false,
    });

    const missing = [_]bool{ true, true, false, false, false, false };
    try std.testing.expectEqual(@as(?u64, 5), firstEventDescriptorElemOutsideSeen(&stream, &missing));

    const seen = [_]bool{ false, false, false, false, false, true };
    try std.testing.expectEqual(@as(?u64, null), firstEventDescriptorElemOutsideSeen(&stream, &seen));
}

const VerifySink = struct {
    ctx: *VerifyCtxHost,
    /// Stages a complete render-surface reset in the host command sink.
    pub fn reset(_: VerifySink) void {}
    /// Emits the already-decided command that attaches a newly created render node.
    pub fn appendNode(_: VerifySink, _: u64, _: u64, _: []const u8) void {}
    /// Ensures the host render surface contains the engine-selected node and tag.
    pub fn ensureNode(_: VerifySink, _: u64, _: []const u8) void {}
    /// Emits removal of a node whose owning scope has already been disposed by the engine.
    pub fn removeNode(_: VerifySink, _: u64) void {}
    /// Publishes the engine-selected child order for one parent.
    pub fn replaceChildren(_: VerifySink, _: u64, _: []const u64) void {}
    /// Publishes a moves-only child reorder without rebuilding surviving row structure.
    pub fn replaceChildrenForMoves(_: VerifySink, _: u64, _: []const u64) void {}
    /// Applies an engine-decided text field value to one render node.
    pub fn applyTextField(_: VerifySink, _: u64, _: RenderTextField, _: []const u8) void {}
    /// Applies an engine-decided custom text attribute to one render node.
    pub fn applyTextAttr(_: VerifySink, _: u64, _: []const u8, _: []const u8) void {}
    /// Applies an engine-decided boolean field value to one render node.
    pub fn applyBoolField(_: VerifySink, _: u64, _: RenderBoolField, _: bool) void {}
    /// Clears an engine-decided text field from one render node.
    pub fn clearTextField(_: VerifySink, _: u64, _: RenderTextField) void {}
    /// Clears an engine-decided custom text attribute from one render node.
    pub fn clearTextAttr(_: VerifySink, _: u64, _: []const u8) void {}
    /// Clears an engine-decided boolean field from one render node.
    pub fn clearBoolField(_: VerifySink, _: u64, _: RenderBoolField) void {}
    /// Publishes a validated canonical event binding selected by the engine.
    pub fn bindEvent(_: VerifySink, _: u64, _: render_cache_mod.EventBindingKey, _: HostRequiredEventBinding) void {}
    /// Removes a host event registration whose engine-owned binding is no longer active.
    pub fn clearEvent(_: VerifySink, _: u64, _: render_cache_mod.EventBindingKey) void {}
    /// Starts the bounded host registration for an engine-owned interval source.
    pub fn startInterval(_: VerifySink, _: u64, _: u64) void {}
    /// Cancels the host registration for an interval whose owning scope is no longer active.
    pub fn cancelInterval(_: VerifySink, _: u64) void {}
    /// Starts bounded asynchronous host work for an engine-issued task request.
    pub fn startTask(_: VerifySink, _: u64, _: []const u8, _: []const u8) void {}
    /// Cancels host work for a task request retired by engine lifecycle policy.
    pub fn cancelTask(self: VerifySink, _: u64) void {
        self.ctx.cancelled_tasks += 1;
    }
    /// Applies an engine-issued storage write without deriving storage semantics.
    pub fn setStorageText(_: VerifySink, _: boundary.StorageArea, _: []const u8, _: []const u8) void {}
    /// Applies an engine-issued storage removal without deriving storage semantics.
    pub fn removeStorage(_: VerifySink, _: boundary.StorageArea, _: []const u8) void {}
    /// Applies an engine-issued browser-history command without deriving routing semantics.
    pub fn navigate(_: VerifySink, _: NavigationKind, _: boundary.LocationSnapshot) void {}
    /// Applies the document title already selected by graph propagation.
    pub fn setDocumentTitle(_: VerifySink, _: []const u8) void {}
    /// Checks that the host render surface matches the engine's committed node metadata.
    pub fn debugAssertNode(_: VerifySink, _: u64, _: bool, _: ?[]const u8, _: ?u64, _: []const u64, _: ?u64, _: ?u64, _: ?u64, _: ?u64, _: ?u64, _: ?u64, _: ?u64) void {}
};

const VerifyCtx = struct {
    pub const Handle = *VerifyCtxHost;
    pub const RegistryOps = hv.RegistryOps();
    pub const Metrics = RuntimeMetrics;
    pub const Sink = VerifySink;

    /// Creates the host's zeroed metric accumulator for a new engine operation.
    pub fn zeroMetrics() Metrics {
        return zeroRuntimeMetrics();
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
        return 0;
    }

    /// Replaces a state source value in the verification host.
    pub fn updateStateValue(_: Handle, _: *abi.RocHost, _: u64, _: HostValue) bool {
        return true;
    }

    /// Returns the exact app-compiled capability that owns the requested state cell.
    pub fn stateCapability(ctx: Handle, _: u64) HostValueCapability {
        return ctx.state_capability;
    }

    /// Materializes the mount-time browser location through the source's owning capability.
    pub fn initialLocationPayload(_: Handle, _: *abi.RocHost, _: HostValueCapability) HostValue {
        return 0;
    }

    /// Materializes one declared storage key through the source's owning capability.
    pub fn initialStoragePayload(_: Handle, _: *abi.RocHost, _: boundary.StorageArea, _: []const u8, _: HostValueCapability) HostValue {
        return 0;
    }

    /// Materializes the mount-time visibility state through the source's owning capability.
    pub fn initialVisibilityPayload(_: Handle, _: *abi.RocHost, _: HostValueCapability) HostValue {
        return 0;
    }

    /// Materializes the mount-time online state through the source's owning capability.
    pub fn initialOnlinePayload(_: Handle, _: *abi.RocHost, _: HostValueCapability) HostValue {
        return 0;
    }

    /// Returns the thin render-command sink used by the shared engine.
    pub fn sink(ctx: Handle) Sink {
        return .{ .ctx = ctx };
    }
};

fn borrowedVerifyElemList(items: []const abi.Elem) abi.RocList(abi.Elem) {
    if (items.len == 0) return abi.RocList(abi.Elem).empty();
    return .{
        .elements_ptr = @constCast(items.ptr),
        .length = items.len,
        .capacity_or_alloc_ptr = items.len << 1,
    };
}

fn borrowedVerifyAttrList(items: []const abi.NodeAttr) abi.RocList(abi.NodeAttr) {
    if (items.len == 0) return abi.RocList(abi.NodeAttr).empty();
    return .{ .elements_ptr = @constCast(items.ptr), .length = items.len, .capacity_or_alloc_ptr = items.len << 1 };
}

fn borrowedVerifySignalExprList(items: []const abi.NodeSignalExpr) abi.RocList(abi.NodeSignalExpr) {
    if (items.len == 0) return abi.RocList(abi.NodeSignalExpr).empty();
    return .{ .elements_ptr = @constCast(items.ptr), .length = items.len, .capacity_or_alloc_ptr = items.len << 1 };
}

fn verifyStaticRoot(attrs: []const abi.NodeAttr, children: []const abi.Elem) abi.Elem {
    return .{
        .payload = .{ .element = .{
            .attrs = borrowedVerifyAttrList(attrs),
            .children = borrowedVerifyElemList(children),
            .tag = abi.RocStr.fromSlice("div", undefined),
        } },
        .tag = .Element,
    };
}

/// Builds a test element whose nested lists obey Roc ownership rules. Use this
/// for values retained by descriptors; the borrowed helper is immediate-only.
fn ownedVerifyStaticRoot(roc_host: *abi.RocHost, attrs: []const abi.NodeAttr, children: []const abi.Elem) abi.Elem {
    for (attrs) |attr| attr.incref(1);
    for (children) |child| child.incref(1);
    return .{
        .payload = .{ .element = .{
            .attrs = abi.RocList(abi.NodeAttr).fromSlice(attrs, roc_host),
            .children = abi.RocList(abi.Elem).fromSlice(children, roc_host),
            .tag = abi.RocStr.fromSlice("div", roc_host),
        } },
        .tag = .Element,
    };
}

fn decrefOwnedVerifySignalExprBox(expr: *abi.NodeSignalExpr, roc_host: *abi.RocHost) void {
    const Drop = struct {
        fn drop(data: ?*anyopaque, host: *abi.RocHost) callconv(.c) void {
            const payload: *abi.NodeSignalExpr = @ptrCast(@alignCast(data.?));
            payload.decref(host);
        }
    };
    abi.decrefBoxWith(@ptrCast(expr), @alignOf(abi.NodeSignalExpr), true, Drop.drop, roc_host);
}

fn boxOwnedVerifyElem(roc_host: *abi.RocHost, elem: abi.Elem) *abi.Elem {
    const raw = abi.allocateBox(@sizeOf(abi.Elem), @alignOf(abi.Elem), true, roc_host);
    const boxed: *abi.Elem = @ptrCast(@alignCast(raw));
    boxed.* = elem;
    return boxed;
}

fn decrefOwnedVerifyElemBox(elem: *abi.Elem, roc_host: *abi.RocHost) void {
    const Drop = struct {
        fn drop(data: ?*anyopaque, host: *abi.RocHost) callconv(.c) void {
            const payload: *abi.Elem = @ptrCast(@alignCast(data.?));
            payload.decref(host);
        }
    };
    abi.decrefBoxWith(@ptrCast(elem), @alignOf(abi.Elem), true, Drop.drop, roc_host);
}

fn boxOwnedVerifySignalExpr(roc_host: *abi.RocHost, expr: abi.NodeSignalExpr) *abi.NodeSignalExpr {
    expr.incref(1);
    const raw = abi.allocateBox(@sizeOf(abi.NodeSignalExpr), @alignOf(abi.NodeSignalExpr), true, roc_host);
    const boxed: *abi.NodeSignalExpr = @ptrCast(@alignCast(raw));
    boxed.* = expr;
    return boxed;
}

fn ownedVerifyStateRoot(roc_host: *abi.RocHost, binder: abi.RocErasedCallable, capability_callable: abi.RocErasedCallable, child: abi.Elem) abi.Elem {
    abi.increfErasedCallable(binder, 2);
    abi.increfErasedCallable(capability_callable, 3);
    return .{ .payload = .{ .state = .{
        .binder = binder,
        .cap = .{ .clone = capability_callable, .drop = capability_callable, .eq = capability_callable },
        .child = boxOwnedVerifyElem(roc_host, child),
        .initial = binder,
    } }, .tag = .State };
}

const OwnedAggregateGraphRoot = struct {
    allocator: std.mem.Allocator,
    roc_host: *abi.RocHost,
    value_callable: abi.RocErasedCallable,
    first_false_callable: abi.RocErasedCallable,
    first_true_callable: abi.RocErasedCallable,
    second_false_callable: abi.RocErasedCallable,
    second_true_callable: abi.RocErasedCallable,
    first_false_transform: abi.RocErasedCallable,
    first_true_transform: abi.RocErasedCallable,
    second_false_transform: abi.RocErasedCallable,
    second_true_transform: abi.RocErasedCallable,
    bool_callable: abi.RocErasedCallable,
    text_callable: abi.RocErasedCallable,
    first_condition: *abi.NodeSignalExpr,
    first_false: *abi.Elem,
    first_true: *abi.Elem,
    second_false: *abi.Elem,
    second_true: *abi.Elem,
    root: abi.Elem,

    fn signalBranch(self: *@This(), label: []const u8, binder: abi.RocErasedCallable, transform: abi.RocErasedCallable) *abi.Elem {
        const state_capability = HostValueCapability{ .clone = binder, .drop = binder, .eq = binder };
        const result_capability = HostValueCapability{ .clone = transform, .drop = transform, .eq = transform };
        const read = HostTextRead{ .capability = result_capability, .read = self.text_callable };
        const input = boxOwnedVerifySignalExpr(self.roc_host, .{ .payload = .{ .ref = binder }, .tag = .Ref });
        const signal = boxOwnedVerifySignalExpr(self.roc_host, .{ .payload = .{ .map = .{ ._0 = transform, ._1 = input, ._2 = transform, ._3 = result_capability } }, .tag = .Map });
        decrefOwnedVerifySignalExprBox(input, self.roc_host);
        var static_text = verifyStaticText();
        static_text.payload.text = abi.RocStr.fromSlice(label, self.roc_host);
        const signal_text = abi.Elem{ .payload = .{ .text_signal = .{ .read = read, .signal = signal } }, .tag = .TextSignal };
        const element = ownedVerifyStaticRoot(self.roc_host, &.{}, &.{ static_text, signal_text });
        static_text.decref(self.roc_host);
        signal_text.decref(self.roc_host);
        abi.increfErasedCallable(binder, 5);
        return boxOwnedVerifyElem(self.roc_host, .{ .payload = .{ .state = .{
            .binder = binder,
            .cap = state_capability,
            .child = boxOwnedVerifyElem(self.roc_host, element),
            .initial = binder,
        } }, .tag = .State });
    }

    fn initWithShape(allocator: std.mem.Allocator, roc_host: *abi.RocHost, nested: bool) !*@This() {
        const self = try allocator.create(@This());
        errdefer allocator.destroy(self);
        self.* = undefined;
        self.allocator = allocator;
        self.roc_host = roc_host;
        self.value_callable = abi.rocErasedCallableAllocate(roc_host, verifyStateCallable, null, 0) orelse return error.OutOfMemory;
        errdefer abi.decrefErasedCallable(self.value_callable, roc_host);
        self.first_false_callable = abi.rocErasedCallableAllocate(roc_host, verifyStateCallable, null, 0) orelse return error.OutOfMemory;
        errdefer abi.decrefErasedCallable(self.first_false_callable, roc_host);
        self.first_true_callable = abi.rocErasedCallableAllocate(roc_host, verifyStateCallable, null, 0) orelse return error.OutOfMemory;
        errdefer abi.decrefErasedCallable(self.first_true_callable, roc_host);
        self.second_false_callable = abi.rocErasedCallableAllocate(roc_host, verifyStateCallable, null, 0) orelse return error.OutOfMemory;
        errdefer abi.decrefErasedCallable(self.second_false_callable, roc_host);
        self.second_true_callable = abi.rocErasedCallableAllocate(roc_host, verifyStateCallable, null, 0) orelse return error.OutOfMemory;
        errdefer abi.decrefErasedCallable(self.second_true_callable, roc_host);
        self.first_false_transform = abi.rocErasedCallableAllocate(roc_host, verifyStateCallable, null, 0) orelse return error.OutOfMemory;
        errdefer abi.decrefErasedCallable(self.first_false_transform, roc_host);
        self.first_true_transform = abi.rocErasedCallableAllocate(roc_host, verifyStateCallable, null, 0) orelse return error.OutOfMemory;
        errdefer abi.decrefErasedCallable(self.first_true_transform, roc_host);
        self.second_false_transform = abi.rocErasedCallableAllocate(roc_host, verifyStateCallable, null, 0) orelse return error.OutOfMemory;
        errdefer abi.decrefErasedCallable(self.second_false_transform, roc_host);
        self.second_true_transform = abi.rocErasedCallableAllocate(roc_host, verifyStateCallable, null, 0) orelse return error.OutOfMemory;
        errdefer abi.decrefErasedCallable(self.second_true_transform, roc_host);
        self.bool_callable = abi.rocErasedCallableAllocate(roc_host, verifyBoolCallable, null, 0) orelse return error.OutOfMemory;
        errdefer abi.decrefErasedCallable(self.bool_callable, roc_host);
        self.text_callable = abi.rocErasedCallableAllocate(roc_host, verifyTextCallable, null, 0) orelse return error.OutOfMemory;
        errdefer abi.decrefErasedCallable(self.text_callable, roc_host);
        self.first_false = self.signalBranch("first-new", self.first_false_callable, self.first_false_transform);
        self.first_true = self.signalBranch("first-old", self.first_true_callable, self.first_true_transform);
        self.second_false = self.signalBranch("second-new", self.second_false_callable, self.second_false_transform);
        self.second_true = self.signalBranch("second-old", self.second_true_callable, self.second_true_transform);
        const condition_capability = HostValueCapability{ .clone = self.value_callable, .drop = self.value_callable, .eq = self.value_callable };
        const condition = abi.NodeSignalExpr{ .payload = .{ .const_value = .{ ._0 = self.value_callable, ._1 = self.value_callable, ._2 = condition_capability } }, .tag = .ConstValue };
        self.first_condition = boxOwnedVerifySignalExpr(roc_host, condition);
        const bool_read = HostBoolRead{ .capability = condition_capability, .read = self.bool_callable };
        var nested_box: ?*abi.Elem = null;
        defer if (nested_box) |boxed| decrefOwnedVerifyElemBox(boxed, roc_host);
        const first_true = if (nested) blk: {
            var inner_when = abi.Elem{ .payload = .{ .when = .{ .condition = self.first_condition, .read = bool_read, .when_false = self.second_false, .when_true = self.first_true } }, .tag = .When };
            inner_when.incref(1);
            nested_box = boxOwnedVerifyElem(roc_host, inner_when);
            break :blk nested_box.?;
        } else self.first_true;
        const first_when = abi.Elem{ .payload = .{ .when = .{ .condition = self.first_condition, .read = bool_read, .when_false = self.first_false, .when_true = first_true } }, .tag = .When };
        const second_when = abi.Elem{ .payload = .{ .when = .{ .condition = self.first_condition, .read = bool_read, .when_false = self.second_false, .when_true = self.second_true } }, .tag = .When };
        var separator = verifyStaticText();
        separator.payload.text = abi.RocStr.fromSlice("separator", roc_host);
        self.root = if (nested)
            ownedVerifyStaticRoot(roc_host, &.{}, &.{first_when})
        else
            ownedVerifyStaticRoot(roc_host, &.{}, &.{ first_when, separator, second_when });
        decrefOwnedVerifySignalExprBox(self.first_condition, roc_host);
        decrefOwnedVerifyElemBox(self.first_false, roc_host);
        decrefOwnedVerifyElemBox(self.first_true, roc_host);
        decrefOwnedVerifyElemBox(self.second_false, roc_host);
        decrefOwnedVerifyElemBox(self.second_true, roc_host);
        return self;
    }

    fn init(allocator: std.mem.Allocator, roc_host: *abi.RocHost) !*@This() {
        return initWithShape(allocator, roc_host, false);
    }

    fn initNested(allocator: std.mem.Allocator, roc_host: *abi.RocHost) !*@This() {
        return initWithShape(allocator, roc_host, true);
    }

    fn deinit(self: *@This()) void {
        self.root.decref(self.roc_host);
        abi.decrefErasedCallable(self.text_callable, self.roc_host);
        abi.decrefErasedCallable(self.bool_callable, self.roc_host);
        abi.decrefErasedCallable(self.second_true_transform, self.roc_host);
        abi.decrefErasedCallable(self.second_false_transform, self.roc_host);
        abi.decrefErasedCallable(self.first_true_transform, self.roc_host);
        abi.decrefErasedCallable(self.first_false_transform, self.roc_host);
        abi.decrefErasedCallable(self.second_true_callable, self.roc_host);
        abi.decrefErasedCallable(self.second_false_callable, self.roc_host);
        abi.decrefErasedCallable(self.first_true_callable, self.roc_host);
        abi.decrefErasedCallable(self.first_false_callable, self.roc_host);
        abi.decrefErasedCallable(self.value_callable, self.roc_host);
        self.allocator.destroy(self);
    }
};

fn verifyStaticText() abi.Elem {
    return .{ .payload = .{ .text = abi.RocStr.fromSlice("hello", undefined) }, .tag = .Text };
}

test "owned retained element fixture keeps nested Roc lists alive" {
    var env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&env);
    const attr = abi.NodeAttr{ .payload = .{ .static_bool = .{
        .field = .{ .id = @intFromEnum(RenderBoolField.disabled) },
        .name = abi.RocStr.empty(),
        .value = true,
    } }, .tag = .StaticBool };
    const child = verifyStaticText();
    const elem = ownedVerifyStaticRoot(&roc_host, &.{attr}, &.{child});
    elem.incref(1);
    elem.decref(&roc_host);
    try std.testing.expectEqual(@as(usize, 1), elem.payload_element().attrs.items().len);
    try std.testing.expectEqual(@as(usize, 1), elem.payload_element().children.items().len);
    try std.testing.expect(elem.payload_element().attrs.items()[0].payload_static_bool().value);
    elem.decref(&roc_host);
}

test "owned aggregate graph root ingests two signal branches around a survivor" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&roc_env);
    const fixture = try OwnedAggregateGraphRoot.init(std.testing.allocator, &roc_host);
    defer fixture.deinit();
    try std.testing.expectEqual(fixture.first_condition.payload_const_value()._0, fixture.first_condition.payload_const_value()._1);
    _ = abi_view.SignalExpr.fromAbi(fixture.first_condition.*);
    var ctx = VerifyCtxHost{ .allocator = std.testing.allocator };
    var engine = Engine(VerifyCtx).init();
    var stream: HostNodeDescriptorStream = .{};
    defer {
        stream.deinit(ctx.allocator, &ctx, &roc_host, &engine.pending_roc_metrics);
        deinitVerifyStateEngine(&engine, &ctx, &roc_host);
    }

    const expected = try Engine(VerifyCtx).countStaticRootNodes(fixture.root);
    try std.testing.expectEqual(@as(usize, 6), expected.signal_records);
    try engine.collectStaticRootDescriptorsTransactional(&ctx, &roc_host, &stream, fixture.root, .{});
    try std.testing.expectEqual(@as(usize, 2), stream.whens.items.len);
    try std.testing.expectEqual(@as(usize, 2), stream.signal_text_nodes.items.len);
    try std.testing.expectEqual(@as(usize, 5), stream.text_nodes.items.len + stream.signal_text_nodes.items.len);
    try std.testing.expect(stream.whens.items[0].node_id < stream.whens.items[1].node_id);
    const separator = for (stream.text_nodes.items) |desc| {
        if (std.mem.eql(u8, desc.value, "separator")) break desc;
    } else return error.TestUnexpectedResult;
    const separator_index = stream.renderNodeIndex(separator.elem_id).?;
    var signals_before: usize = 0;
    var signals_after: usize = 0;
    for (stream.signal_text_nodes.items) |desc| {
        const index = stream.renderNodeIndex(desc.elem_id).?;
        if (index < separator_index) signals_before += 1 else signals_after += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), signals_before);
    try std.testing.expectEqual(@as(usize, 1), signals_after);
}

fn verifyErasedCallable(_: *abi.RocHost, _: ?[*]u8, _: ?[*]const u8, _: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {}

fn verifyEachKeyTextCallable(roc_host: *abi.RocHost, result: ?[*]u8, args: ?[*]const u8, _: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const input: *const erased_calls.ErasedHostValueUnaryArgs = @ptrCast(@alignCast(args.?));
    const text = switch (input.arg0) {
        1 => "one",
        2 => "two",
        3 => "three",
        4 => "four",
        else => "other",
    };
    const out: *abi.RocStr = @ptrCast(@alignCast(result.?));
    out.* = abi.RocStr.fromSlice(text, roc_host);
}

fn verifyEachValueEqCallable(_: *abi.RocHost, result: ?[*]u8, args: ?[*]const u8, _: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const input: *const erased_calls.ErasedHostValueBinaryArgs = @ptrCast(@alignCast(args.?));
    const out: *usize = @ptrCast(@alignCast(result.?));
    out.* = @intFromBool(input.arg0 == input.arg1);
}

fn verifyEachRowElemCallable(roc_host: *abi.RocHost, result: ?[*]u8, args: ?[*]const u8, _: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const input: *const erased_calls.ErasedHostValueBinaryArgs = @ptrCast(@alignCast(args.?));
    var elem = verifyStaticText();
    elem.payload.text = abi.RocStr.fromSlice(if (input.arg1 == 201) "changed" else "created", roc_host);
    const out: *abi.Elem = @ptrCast(@alignCast(result.?));
    out.* = elem;
}

var verifyStateInitCalls: usize = 0;

fn verifyStateCallable(_: *abi.RocHost, result: ?[*]u8, _: ?[*]const u8, _: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    if (result) |bytes| {
        const value: *HostValue = @ptrCast(@alignCast(bytes));
        value.* = 42;
        verifyStateInitCalls += 1;
    }
}

fn verifyBoolCallable(_: *abi.RocHost, result: ?[*]u8, _: ?[*]const u8, _: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    if (result) |bytes| bytes[0] = 1;
}

var verifyTextReadCalls: usize = 0;

fn verifyTextCallable(roc_host: *abi.RocHost, result: ?[*]u8, _: ?[*]const u8, _: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    verifyTextReadCalls += 1;
    if (result) |bytes| {
        const text: *abi.RocStr = @ptrCast(@alignCast(bytes));
        text.* = abi.RocStr.fromSlice("signal", roc_host);
    }
}

fn deinitVerifyStaticEngine(engine: *Engine(VerifyCtx), ctx: *VerifyCtxHost) void {
    engine.scopes.deinit(std.testing.allocator);
    engine.dom_identities.deinit(std.testing.allocator);
    engine.active_dom_identity_ids.deinit(std.testing.allocator);
    engine.deinitScratch(ctx);
}

fn deinitVerifyStateEngine(engine: *Engine(VerifyCtx), ctx: *VerifyCtxHost, roc_host: *abi.RocHost) void {
    effects_runtime.clearPendingTasks(VerifyCtx, ctx, ctx.allocator, &engine.pending_tasks, roc_host);
    effects_runtime.deinitCleanupEvents(ctx.allocator, &engine.cleanup_events);
    for (engine.states.items) |*state| state.cell.deinit(ctx, roc_host, &engine.pending_roc_metrics);
    engine.states.deinit(ctx.allocator);
    engine.state_indexes_by_node_id.deinit(ctx.allocator);
    engine.node_identities.deinit(ctx.allocator);
    engine.active_node_identity_ids.deinit(ctx.allocator);
    for (engine.scopes.items) |*scope| if (scope.active) deinitHostScopeStep(&scope.step, ctx, roc_host, &engine.pending_roc_metrics);
    engine.clearEachRowSites(ctx.allocator);
    deinitVerifyStaticEngine(engine, ctx);
}

test "provisional each-row scopes abort and publish without partial scope mutation" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&env);
    const callable = abi.rocErasedCallableAllocate(&roc_host, verifyErasedCallable, null, 0).?;
    defer abi.decrefErasedCallable(callable, &roc_host);
    const capability = HostValueCapability{ .clone = callable, .drop = callable, .eq = callable };

    const Runner = struct {
        fn run(host: *abi.RocHost, cap: HostValueCapability, fail_at: ?usize) !usize {
            var fault = FaultAllocator.init(std.testing.allocator);
            var ctx = VerifyCtxHost{ .allocator = fault.allocator() };
            var engine = Engine(VerifyCtx).init();
            defer deinitVerifyStateEngine(&engine, &ctx, host);
            _ = try engine.internRootScope(ctx.allocator);
            fault.configure(fail_at);
            var overlay = scope_runtime.PreparedEachRowScopes.init(ctx.allocator, engine.scopes.items);
            defer overlay.deinit();

            const first = overlay.prepareRow(&engine.scopes, &ctx, host, &engine.pending_roc_metrics, 0, 9, 101, 11, 21, cap, cap);
            if (first) |first_id| {
                const second = overlay.prepareRow(&engine.scopes, &ctx, host, &engine.pending_roc_metrics, 0, 9, 202, 12, 22, cap, cap);
                if (second) |second_id| {
                    try std.testing.expectEqual(@as(u64, 1), first_id);
                    try std.testing.expectEqual(@as(u64, 2), second_id);
                    try std.testing.expectEqual(@as(usize, 1), engine.scopes.items.len);
                    const attempts = fault.attempts;
                    fault.configure(1);
                    overlay.commit(&engine.scopes);
                    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
                    try std.testing.expectEqual(@as(usize, 3), engine.scopes.items.len);
                    try std.testing.expectEqual(@as(u64, 101), scope_runtime.eachRowConst(engine.scopes.items, first_id).key_hash);
                    try std.testing.expectEqual(@as(u64, 202), scope_runtime.eachRowConst(engine.scopes.items, second_id).key_hash);
                    return attempts;
                } else |err| {
                    try std.testing.expectEqual(error.OutOfMemory, err);
                }
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
            }
            try std.testing.expectEqual(@as(usize, 1), engine.scopes.items.len);
            overlay.abort(&ctx, host, &engine.pending_roc_metrics);
            try std.testing.expectEqual(@as(usize, 1), engine.scopes.items.len);

            fault.configure(null);
            const retry_first = try overlay.prepareRow(&engine.scopes, &ctx, host, &engine.pending_roc_metrics, 0, 9, 101, 11, 21, cap, cap);
            const retry_second = try overlay.prepareRow(&engine.scopes, &ctx, host, &engine.pending_roc_metrics, 0, 9, 202, 12, 22, cap, cap);
            try std.testing.expectEqual(@as(u64, 1), retry_first);
            try std.testing.expectEqual(@as(u64, 2), retry_second);
            overlay.commit(&engine.scopes);
            try std.testing.expectEqual(@as(usize, 3), engine.scopes.items.len);
            return fault.attempts;
        }
    };

    const attempts = try Runner.run(&roc_host, capability, null);
    var failures: usize = 0;
    for (1..attempts + 1) |fail_at| {
        _ = try Runner.run(&roc_host, capability, fail_at);
        failures += 1;
    }
    try std.testing.expectEqual(attempts, failures);
}

test "staged collection accepts external provisional row scopes without id collisions" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var fault = FaultAllocator.init(std.testing.allocator);
    var ctx = VerifyCtxHost{ .allocator = fault.allocator() };
    var engine = Engine(VerifyCtx).init();
    defer {
        engine.node_identities.deinit(ctx.allocator);
        engine.active_node_identity_ids.deinit(ctx.allocator);
        engine.state_indexes_by_node_id.deinit(ctx.allocator);
        deinitVerifyStaticEngine(&engine, &ctx);
    }
    _ = try engine.internRootScope(ctx.allocator);
    var stream: HostNodeDescriptorStream = .{};
    defer stream.deinit(ctx.allocator, &ctx, undefined, &engine.pending_roc_metrics);
    var collection = try Engine(VerifyCtx).StagedCollectionCtx.init(&engine, &ctx, &stream, .{}, 0, 0, 0, 0, 0, 0, 1, 2);
    defer collection.deinit();
    fault.configure(1);
    try collection.attachExternalScopeIds(&.{ 1, 2 });
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try collection.validateScope(1);
    try collection.validateScope(2);
    const child = try collection.reserveWhenBranchScope(1, 9, .true_branch);
    try std.testing.expectEqual(@as(u64, 3), child.scope_id);
    try std.testing.expectEqual(@as(usize, 1), engine.scopes.items.len);
}

test "prepared each-row subtree retirement is atomic and allocation free" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&env);
    const callable = abi.rocErasedCallableAllocate(&roc_host, verifyErasedCallable, null, 0).?;
    defer abi.decrefErasedCallable(callable, &roc_host);
    const capability = HostValueCapability{ .clone = callable, .drop = callable, .eq = callable };

    const Runner = struct {
        fn run(host: *abi.RocHost, cap: HostValueCapability, fail_at: ?usize) !usize {
            var fault = FaultAllocator.init(std.testing.allocator);
            var ctx = VerifyCtxHost{ .allocator = fault.allocator() };
            var engine = Engine(VerifyCtx).init();
            defer deinitVerifyStateEngine(&engine, &ctx, host);
            _ = try engine.internRootScope(ctx.allocator);
            const row_scope_id = engine.createEachRowScope(&ctx, 0, 7, 99, 10, 20, cap, cap);
            const site_index = engine.activeEachRowSiteIndex(0, 7).?;
            const old_scope_len = engine.scopes.items.len;
            const old_rows = engine.each_row_sites.items[site_index].scope_ids.items.len;

            fault.configure(fail_at);
            var prepared = Engine(VerifyCtx).PreparedEachRowSubtreeRetirement.prepare(&engine, ctx.allocator, &.{row_scope_id}) catch |err| {
                try std.testing.expect(err == error.OutOfMemory or err == error.ResourceLimit);
                try std.testing.expectEqual(old_scope_len, engine.scopes.items.len);
                try std.testing.expect(engine.scopes.items[@intCast(row_scope_id)].active);
                try std.testing.expectEqual(old_rows, engine.each_row_sites.items[site_index].scope_ids.items.len);
                const attempts = fault.attempts;
                fault.configure(null);
                var retry = try Engine(VerifyCtx).PreparedEachRowSubtreeRetirement.prepare(&engine, ctx.allocator, &.{row_scope_id});
                fault.configure(1);
                retry.applyBeforeRowCommit(&engine);
                retry.applyAfterRowCommit(&engine);
                retry.applyEffectsAfterPublication(&engine, &ctx);
                try std.testing.expectEqual(@as(usize, 0), fault.attempts);
                fault.configure(null);
                retry.deinit(&engine, ctx.allocator, &ctx, host);
                return attempts;
            };
            const attempts = fault.attempts;
            fault.configure(1);
            prepared.applyBeforeRowCommit(&engine);
            prepared.applyAfterRowCommit(&engine);
            prepared.applyEffectsAfterPublication(&engine, &ctx);
            try std.testing.expectEqual(@as(usize, 0), fault.attempts);
            try std.testing.expect(!engine.scopes.items[@intCast(row_scope_id)].active);
            try std.testing.expectEqual(@as(usize, 0), engine.each_row_sites.items[site_index].scope_ids.items.len);
            fault.configure(null);
            prepared.deinit(&engine, ctx.allocator, &ctx, host);
            return attempts;
        }
    };

    const attempts = try Runner.run(&roc_host, capability, null);
    var failures: usize = 0;
    for (1..attempts + 1) |fail_at| {
        _ = try Runner.run(&roc_host, capability, fail_at);
        failures += 1;
    }
    try std.testing.expectEqual(attempts, failures);
}

test "each descriptor targets preserve changed row scope ownership" {
    var env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&env);
    const callable = abi.rocErasedCallableAllocate(&roc_host, verifyErasedCallable, null, 0).?;
    defer abi.decrefErasedCallable(callable, &roc_host);
    const capability = HostValueCapability{ .clone = callable, .drop = callable, .eq = callable };
    var ctx = VerifyCtxHost{ .allocator = std.testing.allocator };
    var engine = Engine(VerifyCtx).init();
    defer deinitVerifyStateEngine(&engine, &ctx, &roc_host);
    _ = try engine.internRootScope(ctx.allocator);
    const changed_scope_id = engine.createEachRowScope(&ctx, 0, 7, 10, 1, 101, capability, capability);
    const removed_scope_id = engine.createEachRowScope(&ctx, 0, 7, 20, 2, 202, capability, capability);
    const site_index = engine.activeEachRowSiteIndex(0, 7).?;

    var prepared = try Engine(VerifyCtx).PreparedEachRowSubtreeRetirement.prepareWithTargets(
        &engine,
        ctx.allocator,
        &.{ changed_scope_id, removed_scope_id },
        &.{removed_scope_id},
    );
    try std.testing.expect(prepared.targets.?.descriptor_target_scopes[@intCast(changed_scope_id)]);
    try std.testing.expect(prepared.targets.?.descriptor_target_scopes[@intCast(removed_scope_id)]);
    try std.testing.expectEqualSlices(u64, &.{removed_scope_id}, prepared.targets.?.scope_retirement.?.scope_ids);
    prepared.applyBeforeRowCommit(&engine);
    prepared.applyAfterRowCommit(&engine);
    try std.testing.expect(engine.scopes.items[@intCast(changed_scope_id)].active);
    try std.testing.expect(!engine.scopes.items[@intCast(removed_scope_id)].active);
    try std.testing.expectEqualSlices(u64, &.{changed_scope_id}, engine.each_row_sites.items[site_index].scope_ids.items);
    const values = engine.eachRowScopeValues(changed_scope_id);
    try std.testing.expectEqual(@as(HostValue, 1), values.key);
    try std.testing.expectEqual(@as(HostValue, 101), values.item);
    prepared.deinit(&engine, ctx.allocator, &ctx, &roc_host);
}

test "engine prepared each sync atomically removes reuses changes and creates rows" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&env);
    const noop = abi.rocErasedCallableAllocate(&roc_host, verifyErasedCallable, null, 0).?;
    defer abi.decrefErasedCallable(noop, &roc_host);
    const eq = abi.rocErasedCallableAllocate(&roc_host, verifyEachValueEqCallable, null, 0).?;
    defer abi.decrefErasedCallable(eq, &roc_host);
    const key_text = abi.rocErasedCallableAllocate(&roc_host, verifyEachKeyTextCallable, null, 0).?;
    defer abi.decrefErasedCallable(key_text, &roc_host);
    const state_init = abi.rocErasedCallableAllocate(&roc_host, verifyStateCallable, null, 0).?;
    defer abi.decrefErasedCallable(state_init, &roc_host);
    const row_builder = abi.rocErasedCallableAllocate(&roc_host, verifyEachRowElemCallable, null, 0).?;
    defer abi.decrefErasedCallable(row_builder, &roc_host);
    const capability = HostValueCapability{ .clone = noop, .drop = noop, .eq = eq };
    const ops = std.mem.zeroInit(HostEachOps, .{
        .item_capability = capability,
        .items_capability = capability,
        .items_to_values = noop,
        .key_capability = capability,
        .key_of = noop,
        .key_text = key_text,
        .row = row_builder,
    });

    const Runner = struct {
        fn prepareReplacement(engine: *Engine(VerifyCtx), ctx: *VerifyCtxHost, host: *abi.RocHost, each_ops: HostEachOps, rows: *const each_runtime.PreparedRowSync, keys: []const HostValue, items: []const HostValue) !*Engine(VerifyCtx).PreparedEachRowReplacementCollection {
            const site = HostNodeScopeSiteDesc{ .node_id = 0, .scope_id = 0, .ordinal = 44, .parent_elem_id = 0, .render_insert_index = 0, .kind = .each, .binder_bindings = &.{} };
            const each = HostNodeEachDesc{ .node_id = 0, .items = undefined, .ops = each_ops };
            return Engine(VerifyCtx).PreparedEachRowReplacementCollection.prepare(engine, ctx, host, site, each, rows, keys, items, .{}, &.{});
        }

        fn prepareLayout(engine: *Engine(VerifyCtx), allocator: std.mem.Allocator, rows: *const each_runtime.PreparedRowSync, replacement: *const Engine(VerifyCtx).PreparedEachRowReplacementCollection) !Engine(VerifyCtx).PreparedEachRowRenderLayout {
            const site = HostNodeScopeSiteDesc{ .node_id = 0, .scope_id = 0, .ordinal = 44, .parent_elem_id = 0, .render_insert_index = 0, .kind = .each, .binder_bindings = &.{} };
            return Engine(VerifyCtx).PreparedEachRowRenderLayout.prepare(engine, allocator, site, rows, replacement.replacement_rows);
        }

        fn retry(engine: *Engine(VerifyCtx), ctx: *VerifyCtxHost, host: *abi.RocHost, each_ops: HostEachOps, site_index: usize, keys: []const HostValue, items: []const HostValue) !void {
            var hooks = Engine(VerifyCtx).PreparedEachRowSyncHooks.init(engine, ctx, host, each_ops);
            var rows = try each_runtime.PreparedRowSync.prepare(ctx.allocator, &engine.each_row_sites, &engine.each_row_memberships_by_scope_id, site_index, 0, 44, keys, items, &hooks);
            var retirement = try Engine(VerifyCtx).PreparedEachRowSubtreeRetirement.prepare(engine, ctx.allocator, rows.removed_scope_ids);
            const replacement = try prepareReplacement(engine, ctx, host, each_ops, &rows, keys, items);
            try std.testing.expectEqual(@as(usize, 2), replacement.replacement.stream.text_nodes.items.len);
            try std.testing.expectEqualDeep(&[_]Engine(VerifyCtx).PreparedEachRowReplacementCollection.ReplacementRow{
                .{ .row_index = 0, .scope_id = 2, .start = 0, .len = 1 },
                .{ .row_index = 2, .scope_id = 4, .start = 1, .len = 1 },
            }, replacement.replacement_rows);
            var layout = try prepareLayout(engine, ctx.allocator, &rows, replacement);
            try retirement.refineDescriptorOwnedRetirement(engine, ctx.allocator, &layout.removal.removal);
            try std.testing.expectEqualSlices(usize, &.{0}, layout.remove_starts);
            try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, layout.final_starts);
            try std.testing.expect(layout.targets.descriptor_target_scopes[1]);
            try std.testing.expect(layout.targets.descriptor_target_scopes[2]);
            try std.testing.expectEqualSlices(u64, &.{1}, layout.targets.scope_retirement.?.scope_ids);
            layout.deinit();
            replacement.deinit();
            retirement.applyBeforeRowCommit(engine);
            var diff = rows.commit(&engine.each_row_sites, &engine.each_row_memberships_by_scope_id, keys, items, &hooks);
            retirement.applyAfterRowCommit(engine);
            retirement.applyEffectsAfterPublication(engine, ctx);
            diff.deinit(ctx.allocator);
            rows.deinit();
            hooks.deinit();
            retirement.deinit(engine, ctx.allocator, ctx, host);
        }

        fn run(host: *abi.RocHost, state_initializer: abi.RocErasedCallable, each_ops: HostEachOps, fail_at: ?usize) !usize {
            var fault = FaultAllocator.init(std.testing.allocator);
            var ctx = VerifyCtxHost{ .allocator = fault.allocator() };
            var engine = Engine(VerifyCtx).init();
            defer {
                engine.active_stream.deinit(ctx.allocator, &ctx, host, &engine.pending_roc_metrics);
                deinitVerifyStateEngine(&engine, &ctx, host);
                for (engine.pending_tasks.items) |*task| effects_runtime.deinitPendingTask(ctx.allocator, host, task);
                engine.pending_tasks.deinit(ctx.allocator);
            }
            _ = try engine.internRootScope(ctx.allocator);
            const removed_scope_id = engine.createEachRowScope(&ctx, 0, 44, hashEachKeyText("one"), 1, 100, each_ops.key_capability, each_ops.item_capability);
            _ = engine.createEachRowScope(&ctx, 0, 44, hashEachKeyText("two"), 2, 200, each_ops.key_capability, each_ops.item_capability);
            _ = engine.createEachRowScope(&ctx, 0, 44, hashEachKeyText("three"), 3, 300, each_ops.key_capability, each_ops.item_capability);
            const retired_node_id = try engine.internNodeIdentity(ctx.allocator, removed_scope_id, 71);
            const retired_elem_id = try engine.internDomIdentity(ctx.allocator, removed_scope_id, 72);
            const changed_elem_id = try engine.internDomIdentity(ctx.allocator, 2, 72);
            const persistent_changed_node_id = try engine.internNodeIdentity(ctx.allocator, 2, 99);
            const unchanged_elem_id = try engine.internDomIdentity(ctx.allocator, 3, 72);
            engine.active_stream.appendTextNode(ctx.allocator, retired_elem_id, 0, removed_scope_id, "old-one");
            engine.active_stream.appendTextNode(ctx.allocator, changed_elem_id, 0, 2, "old-two");
            engine.active_stream.appendTextNode(ctx.allocator, unchanged_elem_id, 0, 3, "old-three");
            engine.active_stream.appendScopeSiteAt(ctx.allocator, retired_node_id, removed_scope_id, 73, 0, 0, .state, &.{});
            engine.active_stream.appendState(ctx.allocator, host, &engine.pending_roc_metrics, retired_node_id, state_initializer, each_ops.item_capability);
            engine.ensureStateFromDesc(&ctx, host, engine.active_stream.states.items[0]);
            engine.active_stream.appendCleanup(ctx.allocator, removed_scope_id, "each-cleanup");
            engine.roc_host = host;
            _ = engine.appendPendingTask(&ctx, removed_scope_id, each_ops.row.?, "each-task", "request");
            _ = engine.appendPendingTask(&ctx, 2, each_ops.row.?, "changed-row-task", "request");
            const site_index = engine.activeEachRowSiteIndex(0, 44).?;
            const old_ids = try ctx.allocator.dupe(u64, engine.each_row_sites.items[site_index].scope_ids.items);
            defer ctx.allocator.free(old_ids);
            const keys = [_]HostValue{ 2, 3, 4 };
            const items = [_]HostValue{ 201, 300, 400 };

            fault.configure(fail_at);
            var hooks = Engine(VerifyCtx).PreparedEachRowSyncHooks.init(&engine, &ctx, host, each_ops);
            var rows = each_runtime.PreparedRowSync.prepare(ctx.allocator, &engine.each_row_sites, &engine.each_row_memberships_by_scope_id, site_index, 0, 44, &keys, &items, &hooks) catch |err| {
                hooks.deinit();
                try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expectEqualSlices(u64, old_ids, engine.each_row_sites.items[site_index].scope_ids.items);
                try std.testing.expectEqual(@as(usize, 4), engine.scopes.items.len);
                try std.testing.expect(engine.node_identities.items[@intCast(retired_node_id)].active);
                try std.testing.expect(engine.dom_identities.items[@intCast(retired_elem_id - 1)].active);
                try std.testing.expectEqual(@as(usize, 0), ctx.cancelled_tasks);
                try std.testing.expectEqual(@as(usize, 0), engine.cleanup_events.items.len);
                try std.testing.expectEqual(@as(usize, 2), engine.pending_tasks.items.len);
                try std.testing.expect(engine.pending_tasks.items[0].active);
                try std.testing.expectEqual(@as(usize, 1), engine.states.items.len);
                try std.testing.expect(engine.states.items[0].active);
                const failed_attempts = fault.attempts;
                fault.configure(null);
                try retry(&engine, &ctx, host, each_ops, site_index, &keys, &items);
                try std.testing.expectEqualSlices(u64, &.{ 2, 3, 4 }, engine.each_row_sites.items[site_index].scope_ids.items);
                return failed_attempts;
            };
            var retirement = Engine(VerifyCtx).PreparedEachRowSubtreeRetirement.prepare(&engine, ctx.allocator, rows.removed_scope_ids) catch |err| {
                rows.abort(&hooks);
                rows.deinit();
                hooks.deinit();
                try std.testing.expect(err == error.OutOfMemory or err == error.ResourceLimit);
                try std.testing.expectEqualSlices(u64, old_ids, engine.each_row_sites.items[site_index].scope_ids.items);
                try std.testing.expectEqual(@as(usize, 4), engine.scopes.items.len);
                try std.testing.expect(engine.node_identities.items[@intCast(retired_node_id)].active);
                try std.testing.expect(engine.dom_identities.items[@intCast(retired_elem_id - 1)].active);
                try std.testing.expectEqual(@as(usize, 0), ctx.cancelled_tasks);
                try std.testing.expectEqual(@as(usize, 0), engine.cleanup_events.items.len);
                try std.testing.expectEqual(@as(usize, 2), engine.pending_tasks.items.len);
                try std.testing.expect(engine.pending_tasks.items[0].active);
                try std.testing.expectEqual(@as(usize, 1), engine.states.items.len);
                try std.testing.expect(engine.states.items[0].active);
                const failed_attempts = fault.attempts;
                fault.configure(null);
                try retry(&engine, &ctx, host, each_ops, site_index, &keys, &items);
                try std.testing.expectEqualSlices(u64, &.{ 2, 3, 4 }, engine.each_row_sites.items[site_index].scope_ids.items);
                return failed_attempts;
            };
            const replacement = prepareReplacement(&engine, &ctx, host, each_ops, &rows, &keys, &items) catch |err| {
                retirement.deinit(&engine, ctx.allocator, null, null);
                rows.abort(&hooks);
                rows.deinit();
                hooks.deinit();
                try std.testing.expect(err == error.OutOfMemory or err == error.ResourceLimit);
                try std.testing.expectEqualSlices(u64, old_ids, engine.each_row_sites.items[site_index].scope_ids.items);
                try std.testing.expectEqual(@as(usize, 4), engine.scopes.items.len);
                const failed_attempts = fault.attempts;
                fault.configure(null);
                try retry(&engine, &ctx, host, each_ops, site_index, &keys, &items);
                return failed_attempts;
            };
            try std.testing.expectEqual(@as(usize, 2), replacement.replacement.stream.text_nodes.items.len);
            try std.testing.expectEqualStrings("changed", replacement.replacement.stream.text_nodes.items[0].value);
            try std.testing.expectEqualStrings("created", replacement.replacement.stream.text_nodes.items[1].value);
            try std.testing.expectEqual(@as(usize, 0), replacement.replacement_rows[0].row_index);
            try std.testing.expectEqual(@as(usize, 2), replacement.replacement_rows[1].row_index);
            var layout = prepareLayout(&engine, ctx.allocator, &rows, replacement) catch |err| {
                replacement.deinit();
                retirement.deinit(&engine, ctx.allocator, null, null);
                rows.abort(&hooks);
                rows.deinit();
                hooks.deinit();
                try std.testing.expect(err == error.OutOfMemory or err == error.ResourceLimit);
                try std.testing.expectEqualSlices(u64, old_ids, engine.each_row_sites.items[site_index].scope_ids.items);
                const failed_attempts = fault.attempts;
                fault.configure(null);
                try retry(&engine, &ctx, host, each_ops, site_index, &keys, &items);
                return failed_attempts;
            };
            retirement.refineDescriptorOwnedRetirement(&engine, ctx.allocator, &layout.removal.removal) catch |err| {
                layout.deinit();
                replacement.deinit();
                retirement.deinit(&engine, ctx.allocator, null, null);
                rows.abort(&hooks);
                rows.deinit();
                hooks.deinit();
                try std.testing.expect(err == error.OutOfMemory or err == error.ResourceLimit);
                try std.testing.expect(engine.node_identities.items[@intCast(persistent_changed_node_id)].active);
                try std.testing.expectEqual(@as(usize, 2), engine.pending_tasks.items.len);
                const failed_attempts = fault.attempts;
                fault.configure(null);
                try retry(&engine, &ctx, host, each_ops, site_index, &keys, &items);
                return failed_attempts;
            };
            try std.testing.expectEqualSlices(usize, &.{0}, layout.remove_starts);
            try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, layout.final_starts);
            try std.testing.expectEqual(@as(usize, 1), layout.survivor_moves.len);
            try std.testing.expect(layout.targets.descriptor_target_scopes[removed_scope_id]);
            try std.testing.expect(layout.targets.descriptor_target_scopes[2]);
            try std.testing.expect(!layout.targets.descriptor_target_scopes[3]);
            try std.testing.expectEqualSlices(u64, &.{removed_scope_id}, layout.targets.scope_retirement.?.scope_ids);
            layout.deinit();
            replacement.deinit();
            const attempts = fault.attempts;
            fault.configure(1);
            retirement.applyBeforeRowCommit(&engine);
            var diff = rows.commit(&engine.each_row_sites, &engine.each_row_memberships_by_scope_id, &keys, &items, &hooks);
            retirement.applyAfterRowCommit(&engine);
            retirement.applyEffectsAfterPublication(&engine, &ctx);
            try std.testing.expectEqual(@as(usize, 0), fault.attempts);
            try std.testing.expect(engine.node_identities.items[@intCast(persistent_changed_node_id)].active);
            try std.testing.expectEqual(@as(usize, 1), engine.pending_tasks.items.len);
            try std.testing.expectEqualStrings("changed-row-task", engine.pending_tasks.items[0].task_name);
            try std.testing.expectEqualSlices(u64, &.{ 2, 3, 4 }, diff.scope_ids);
            try std.testing.expectEqualSlices(bool, &.{ true, false, true }, diff.row_items_changed);
            try std.testing.expectEqualSlices(bool, &.{ false, false, true }, diff.scope_created);
            try std.testing.expectEqual(@as(u64, 201), engine.eachRowScopeValues(2).item);
            try std.testing.expectEqual(@as(u64, 400), engine.eachRowScopeValues(4).item);
            try std.testing.expect(!engine.scopes.items[1].active);
            try std.testing.expect(!engine.node_identities.items[@intCast(retired_node_id)].active);
            try std.testing.expect(!engine.dom_identities.items[@intCast(retired_elem_id - 1)].active);
            try std.testing.expectEqual(@as(usize, 1), engine.cleanup_events.items.len);
            try std.testing.expectEqualStrings("each-cleanup", engine.cleanup_events.items[0]);
            try std.testing.expectEqual(@as(usize, 1), ctx.cancelled_tasks);
            try std.testing.expectEqual(@as(usize, 0), engine.states.items.len);
            fault.configure(null);
            diff.deinit(ctx.allocator);
            rows.deinit();
            hooks.deinit();
            retirement.deinit(&engine, ctx.allocator, &ctx, host);
            return attempts;
        }
    };

    const attempts = try Runner.run(&roc_host, state_init, ops, null);
    var failures: usize = 0;
    for (1..attempts + 1) |fail_at| {
        _ = try Runner.run(&roc_host, state_init, ops, fail_at);
        failures += 1;
    }
    try std.testing.expectEqual(attempts, failures);
}

test "dirty when cache remains detached until commit and abort releases it" {
    var env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&env);
    const callable = abi.rocErasedCallableAllocate(&roc_host, verifyStateCallable, null, 0).?;
    defer abi.decrefErasedCallable(callable, &roc_host);
    const cap = HostValueCapability{ .clone = callable, .drop = callable, .eq = callable };
    var ctx = VerifyCtxHost{ .allocator = std.testing.allocator };
    var metrics = zeroRuntimeMetrics();
    var slot = HostSignalCacheSlot{ .present = HostValueCell.initRetained(1, cap, &metrics) };
    defer slot.deinit(&ctx, &roc_host, &metrics);

    var aborted = HostDirtyStructuralSignal{
        .kind = .when,
        .node_id = 1,
        .scope_id = 0,
        .ordinal = 0,
        .record = undefined,
        .pending_when_cache = HostValueCell.initRetained(2, cap, &metrics),
    };
    aborted.abortPendingWhenCache(&ctx, &roc_host, &metrics);
    try std.testing.expectEqual(@as(HostValue, 1), slot.present.value);
    try std.testing.expect(aborted.pending_when_cache == null);

    var committed = HostDirtyStructuralSignal{
        .kind = .when,
        .node_id = 1,
        .scope_id = 0,
        .ordinal = 0,
        .record = undefined,
        .pending_when_cache = HostValueCell.initRetained(3, cap, &metrics),
    };
    committed.commitPendingWhenCache(&slot, &ctx, &roc_host, &metrics);
    try std.testing.expectEqual(@as(HostValue, 3), slot.present.value);
    try std.testing.expect(committed.pending_when_cache == null);
    try std.testing.expectEqual(metrics.closure_retains, metrics.closure_releases + 3);
}

test "static root counts nested signal attribute records" {
    const capability = std.mem.zeroes(HostValueCapability);
    var left = abi.NodeSignalExpr{ .payload = .{ .ref = @ptrFromInt(0x1000) }, .tag = .Ref };
    var right = abi.NodeSignalExpr{ .payload = .{ .ref = @ptrFromInt(0x2000) }, .tag = .Ref };
    const map2_token: abi.RocErasedCallable = @ptrFromInt(0x3000);
    const map2 = abi.NodeSignalExpr{ .payload = .{ .map2 = .{
        ._0 = map2_token,
        ._1 = &left,
        ._2 = &right,
        ._3 = map2_token,
        ._4 = capability,
    } }, .tag = .Map2 };
    const tail = abi.NodeSignalExpr{ .payload = .{ .ref = @ptrFromInt(0x4000) }, .tag = .Ref };
    var children = [_]abi.NodeSignalExpr{ map2, tail };
    const combine_token: abi.RocErasedCallable = @ptrFromInt(0x5000);
    var combine = abi.NodeSignalExpr{ .payload = .{ .combine = .{
        ._0 = combine_token,
        ._1 = borrowedVerifySignalExprList(&children),
        ._2 = combine_token,
        ._3 = capability,
    } }, .tag = .Combine };
    const attr = abi.NodeAttr{ .payload = .{ .signal_text = .{
        .field = .{ .id = @intFromEnum(RenderTextField.label) },
        .name = abi.RocStr.empty(),
        .read = std.mem.zeroes(HostTextRead),
        .signal = &combine,
    } }, .tag = .SignalText };
    const root = verifyStaticRoot(&.{attr}, &.{});

    const count = try Engine(VerifyCtx).countStaticRootNodes(root);
    try std.testing.expectEqual(@as(usize, 1), count.nodes);
    try std.testing.expectEqual(@as(usize, 1), count.attrs);
    try std.testing.expectEqual(@as(usize, 5), count.signal_records);
}

test "staged collection preflights signal records separately from descriptor roots" {
    var ctx = VerifyCtxHost{ .allocator = std.testing.allocator };
    var engine = Engine(VerifyCtx).init();
    defer deinitVerifyStaticEngine(&engine, &ctx);
    var stream: HostNodeDescriptorStream = .{};
    var roc_host: abi.RocHost = undefined;
    defer stream.deinit(std.testing.allocator, &ctx, &roc_host, &engine.pending_roc_metrics);

    var collection = try Engine(VerifyCtx).StagedCollectionCtx.init(&engine, &ctx, &stream, .{}, 1, 2, 0, 5, 0, 0, 0, 1);
    defer collection.deinit();
    try std.testing.expectEqual(@as(usize, 5), collection.signal_token_capacity);
    try std.testing.expectEqual(@as(usize, 5), collection.signal_root_capacity);
    try std.testing.expect(collection.signal_records.token_intents.capacity >= 5);
    try std.testing.expect(collection.signal_records.descriptor_roots.capacity >= 5);
    try std.testing.expect(collection.signal_bindings.capacity >= 5);
}

test "staged signal record publication is allocation free" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var fault = FaultAllocator.init(std.testing.allocator);
    var ctx = VerifyCtxHost{ .allocator = fault.allocator() };
    var engine = Engine(VerifyCtx).init();
    defer deinitVerifyStaticEngine(&engine, &ctx);
    var stream: HostNodeDescriptorStream = .{};
    var roc_host: abi.RocHost = undefined;
    defer stream.deinit(ctx.allocator, &ctx, &roc_host, &engine.pending_roc_metrics);

    var collection = try Engine(VerifyCtx).StagedCollectionCtx.init(&engine, &ctx, &stream, .{}, 0, 1, 0, 2, 0, 0, 0, 1);
    defer collection.deinit();
    const capability = std.mem.zeroes(HostValueCapability);
    const child_token: HostSignalToken = @ptrFromInt(0x6000);
    const root_token: HostSignalToken = @ptrFromInt(0x7000);
    var child = HostSignalRecord{ .ref_count = 1, .payload = .{ .const_value = .{
        .init = child_token,
        .cap = capability,
    } } };
    var root = HostSignalRecord{ .ref_count = 1, .payload = .{ .map = .{
        .input = &child,
        .transform = root_token,
        .cap = capability,
    } } };
    collection.signal_records.rememberTokenAssumeCapacity(child_token, &child);
    collection.signal_records.rememberTokenAssumeCapacity(root_token, &root);
    collection.signal_records.ownDescriptorRootAssumeCapacity(&root);
    collection.signal_records.transferDescriptorRoot(&root);

    fault.configure(1);
    collection.commit();
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expect(collection.signal_records.committed);
    try std.testing.expect(stream.signalRecordByToken(child_token) == &child);
    try std.testing.expect(stream.signalRecordByToken(root_token) == &root);

    stream.forgetSignalRecordTree(&root);
    try std.testing.expect(stream.signalRecordByToken(child_token) == null);
    try std.testing.expect(stream.signalRecordByToken(root_token) == null);
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
}

test "staged fixed event publication is allocation free" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var fault = FaultAllocator.init(std.testing.allocator);
    var ctx = VerifyCtxHost{ .allocator = fault.allocator() };
    var engine = Engine(VerifyCtx).init();
    defer deinitVerifyStaticEngine(&engine, &ctx);
    var stream: HostNodeDescriptorStream = .{};
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&roc_env);
    defer stream.deinit(ctx.allocator, &ctx, &roc_host, &engine.pending_roc_metrics);
    var collection = try Engine(VerifyCtx).StagedCollectionCtx.init(&engine, &ctx, &stream, .{}, 1, 1, 0, 0, 0, 0, 0, 1);
    defer collection.deinit();

    const binder: HostBinderToken = @ptrFromInt(0x8000);
    const extraction_bytes = EventExtractionPlanKind.none.bytes();
    const attr = abi.NodeAttr{ .payload = .{ .on = .{
        .kind = .{ .id = @intFromEnum(RenderEventKind.pointer_down) },
        .msg = .{
            .binder = binder,
            .read_binder = binder,
            .event_extraction_plan = .{ .bytes = .{ .elements_ptr = @constCast(extraction_bytes.ptr), .length = extraction_bytes.len, .capacity_or_alloc_ptr = extraction_bytes.len << 1 } },
            .payload_reducer = std.mem.zeroes(HostEventReducer),
        },
        .name = abi.RocStr.empty(),
        .delivery = .{ .native = false },
        .policy = std.mem.zeroes(abi.NodeEventBindingPolicy),
    } }, .tag = .On };
    try collection.appendAttr(&roc_host, 1, attr, &.{.{ .token = binder, .node_id = 9 }});
    fault.configure(1);
    collection.commit();
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqual(@as(usize, 1), stream.events.items.len);
    try std.testing.expectEqual(@as(?usize, 0), stream.elemDescriptorIndex(1).?.events.get(.pointer_down));
    try std.testing.expectEqual(@as(u64, 9), stream.events.items[0].target_node_id);
}

test "staged named event sweeps allocation failures and retries without visibility" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    const binder: HostBinderToken = @ptrFromInt(0x8100);
    const extraction_bytes = EventExtractionPlanKind.none.bytes();
    const attr = abi.NodeAttr{ .payload = .{ .on = .{
        .kind = .{ .id = 0 },
        .msg = .{
            .binder = binder,
            .read_binder = binder,
            .event_extraction_plan = .{ .bytes = .{ .elements_ptr = @constCast(extraction_bytes.ptr), .length = extraction_bytes.len, .capacity_or_alloc_ptr = extraction_bytes.len << 1 } },
            .payload_reducer = std.mem.zeroes(HostEventReducer),
        },
        .name = abi.RocStr.fromSlice("keydown", undefined),
        .delivery = .{ .native = false },
        .policy = std.mem.zeroes(abi.NodeEventBindingPolicy),
    } }, .tag = .On };

    var counter = FaultAllocator.init(std.testing.allocator);
    var counter_ctx = VerifyCtxHost{ .allocator = counter.allocator() };
    var counter_engine = Engine(VerifyCtx).init();
    var counter_stream: HostNodeDescriptorStream = .{};
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&roc_env);
    {
        var collection = try Engine(VerifyCtx).StagedCollectionCtx.init(&counter_engine, &counter_ctx, &counter_stream, .{}, 1, 1, 0, 0, 0, 0, 0, 1);
        defer collection.deinit();
        counter.configure(null);
        try collection.appendAttr(&roc_host, 1, attr, &.{.{ .token = binder, .node_id = 9 }});
    }
    const attempts = counter.attempts;
    counter_stream.deinit(counter_ctx.allocator, &counter_ctx, &roc_host, &counter_engine.pending_roc_metrics);
    deinitVerifyStaticEngine(&counter_engine, &counter_ctx);
    try std.testing.expect(attempts >= 2);

    for (1..attempts + 1) |failure_number| {
        var fault = FaultAllocator.init(std.testing.allocator);
        var ctx = VerifyCtxHost{ .allocator = fault.allocator() };
        var engine = Engine(VerifyCtx).init();
        var stream: HostNodeDescriptorStream = .{};
        defer {
            stream.deinit(ctx.allocator, &ctx, &roc_host, &engine.pending_roc_metrics);
            deinitVerifyStaticEngine(&engine, &ctx);
        }
        var collection = try Engine(VerifyCtx).StagedCollectionCtx.init(&engine, &ctx, &stream, .{}, 1, 1, 0, 0, 0, 0, 0, 1);
        defer collection.deinit();

        fault.configure(failure_number);
        try std.testing.expectError(error.OutOfMemory, collection.appendAttr(&roc_host, 1, attr, &.{.{ .token = binder, .node_id = 9 }}));
        try std.testing.expectEqual(@as(usize, 0), stream.events.items.len);
        try std.testing.expectEqual(@as(usize, 0), stream.namedEventIndices(1).len);
        try std.testing.expectEqual(engine.pending_roc_metrics.closure_retains, engine.pending_roc_metrics.closure_releases);

        fault.configure(null);
        try collection.appendAttr(&roc_host, 1, attr, &.{.{ .token = binder, .node_id = 9 }});
        collection.commit();
        try std.testing.expectEqual(@as(usize, 1), stream.events.items.len);
        try std.testing.expectEqualSlices(usize, &.{0}, stream.namedEventIndices(1));
        try std.testing.expectEqualStrings("keydown", stream.events.items[0].named().?.name);
        try std.testing.expectEqual(@as(u64, 9), stream.events.items[0].target_node_id);
    }
}

test "transactional component and state root sweeps failures and publishes initializer once" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&roc_env);
    const callable = abi.rocErasedCallableAllocate(&roc_host, verifyStateCallable, null, 0).?;
    defer abi.decrefErasedCallable(callable, &roc_host);
    const capability = HostValueCapability{ .clone = callable, .drop = callable, .eq = callable };
    const extraction_bytes = EventExtractionPlanKind.none.bytes();
    const named_attr = abi.NodeAttr{ .payload = .{ .on = .{
        .kind = .{ .id = 0 },
        .msg = .{
            .binder = callable,
            .read_binder = callable,
            .event_extraction_plan = .{ .bytes = .{ .elements_ptr = @constCast(extraction_bytes.ptr), .length = extraction_bytes.len, .capacity_or_alloc_ptr = extraction_bytes.len << 1 } },
            .payload_reducer = std.mem.zeroes(HostEventReducer),
        },
        .name = abi.RocStr.fromSlice("keydown", undefined),
        .delivery = .{ .native = false },
        .policy = std.mem.zeroes(abi.NodeEventBindingPolicy),
    } }, .tag = .On };
    var child = verifyStaticRoot(&.{named_attr}, &.{});
    var state_root = abi.Elem{ .payload = .{ .state = .{
        .binder = callable,
        .cap = capability,
        .child = &child,
        .initial = callable,
    } }, .tag = .State };
    const component_root = abi.Elem{ .payload = .{ .component = .{ .child = &state_root } }, .tag = .Component };

    var counter = FaultAllocator.init(std.testing.allocator);
    var counter_ctx = VerifyCtxHost{ .allocator = counter.allocator() };
    var counter_engine = Engine(VerifyCtx).init();
    var counter_stream: HostNodeDescriptorStream = .{};
    verifyStateInitCalls = 0;
    try counter_engine.collectStaticRootDescriptorsTransactional(&counter_ctx, &roc_host, &counter_stream, component_root, .{});
    const attempts = counter.attempts;
    try std.testing.expectEqual(@as(usize, 1), verifyStateInitCalls);
    counter_stream.deinit(counter_ctx.allocator, &counter_ctx, &roc_host, &counter_engine.pending_roc_metrics);
    deinitVerifyStateEngine(&counter_engine, &counter_ctx, &roc_host);
    try std.testing.expect(attempts != 0);

    for (1..attempts + 1) |failure_number| {
        var fault = FaultAllocator.init(std.testing.allocator);
        fault.configure(failure_number);
        var ctx = VerifyCtxHost{ .allocator = fault.allocator() };
        var engine = Engine(VerifyCtx).init();
        var stream: HostNodeDescriptorStream = .{};
        defer {
            stream.deinit(ctx.allocator, &ctx, &roc_host, &engine.pending_roc_metrics);
            deinitVerifyStateEngine(&engine, &ctx, &roc_host);
        }
        verifyStateInitCalls = 0;
        try std.testing.expectError(error.OutOfMemory, engine.collectStaticRootDescriptorsTransactional(&ctx, &roc_host, &stream, component_root, .{}));
        try std.testing.expectEqual(@as(usize, 0), engine.node_identities.items.len);
        try std.testing.expectEqual(@as(usize, 0), engine.states.items.len);
        try std.testing.expectEqual(@as(usize, 0), stream.scope_sites.items.len);
        try std.testing.expectEqual(@as(usize, 0), stream.states.items.len);
        try std.testing.expectEqual(@as(usize, 0), stream.elements.items.len);
        try std.testing.expectEqual(@as(usize, 0), stream.events.items.len);
        const calls_before_retry = verifyStateInitCalls;

        fault.configure(null);
        try engine.collectStaticRootDescriptorsTransactional(&ctx, &roc_host, &stream, component_root, .{});
        try std.testing.expectEqual(calls_before_retry + 1, verifyStateInitCalls);
        try std.testing.expectEqual(@as(usize, 2), engine.node_identities.items.len);
        try std.testing.expectEqual(@as(usize, 2), engine.scopes.items.len);
        try std.testing.expectEqual(@as(usize, 1), engine.states.items.len);
        try std.testing.expectEqual(@as(HostValue, 42), engine.states.items[0].cell.value);
        try std.testing.expectEqual(@as(usize, 2), stream.scope_sites.items.len);
        try std.testing.expectEqual(@as(usize, 1), stream.states.items.len);
        try std.testing.expectEqualStrings("div", stream.elements.items[0].tag);
        try std.testing.expectEqualStrings("keydown", stream.events.items[0].named().?.name);
        try std.testing.expectEqualSlices(usize, &.{0}, stream.namedEventIndices(1));
    }
}

test "transactional initial when root sweeps failures and evaluates once" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&roc_env);
    const value_callable = abi.rocErasedCallableAllocate(&roc_host, verifyStateCallable, null, 0).?;
    defer abi.decrefErasedCallable(value_callable, &roc_host);
    const bool_callable = abi.rocErasedCallableAllocate(&roc_host, verifyBoolCallable, null, 0).?;
    defer abi.decrefErasedCallable(bool_callable, &roc_host);
    const capability = HostValueCapability{ .clone = value_callable, .drop = value_callable, .eq = value_callable };
    var condition = abi.NodeSignalExpr{ .payload = .{ .const_value = .{
        ._0 = value_callable,
        ._1 = value_callable,
        ._2 = capability,
    } }, .tag = .ConstValue };
    var when_false = verifyStaticText();
    when_false.payload.text = abi.RocStr.fromSlice("no", undefined);
    var when_true = verifyStaticText();
    when_true.payload.text = abi.RocStr.fromSlice("yes", undefined);
    const root = abi.Elem{ .payload = .{ .when = .{
        .condition = &condition,
        .read = .{ .capability = capability, .read = bool_callable },
        .when_false = &when_false,
        .when_true = &when_true,
    } }, .tag = .When };

    var counter = FaultAllocator.init(std.testing.allocator);
    var counter_ctx = VerifyCtxHost{ .allocator = counter.allocator() };
    var counter_engine = Engine(VerifyCtx).init();
    var counter_stream: HostNodeDescriptorStream = .{};
    verifyStateInitCalls = 0;
    try counter_engine.collectStaticRootDescriptorsTransactional(&counter_ctx, &roc_host, &counter_stream, root, .{});
    const attempts = counter.attempts;
    try std.testing.expectEqual(@as(usize, 1), verifyStateInitCalls);
    counter_stream.deinit(counter_ctx.allocator, &counter_ctx, &roc_host, &counter_engine.pending_roc_metrics);
    deinitVerifyStateEngine(&counter_engine, &counter_ctx, &roc_host);

    for (1..attempts + 1) |failure_number| {
        var fault = FaultAllocator.init(std.testing.allocator);
        fault.configure(failure_number);
        var ctx = VerifyCtxHost{ .allocator = fault.allocator() };
        var engine = Engine(VerifyCtx).init();
        var stream: HostNodeDescriptorStream = .{};
        defer {
            stream.deinit(ctx.allocator, &ctx, &roc_host, &engine.pending_roc_metrics);
            deinitVerifyStateEngine(&engine, &ctx, &roc_host);
        }
        verifyStateInitCalls = 0;
        try std.testing.expectError(error.OutOfMemory, engine.collectStaticRootDescriptorsTransactional(&ctx, &roc_host, &stream, root, .{}));
        try std.testing.expectEqual(@as(usize, 0), engine.scopes.items.len);
        try std.testing.expectEqual(@as(usize, 0), engine.node_identities.items.len);
        try std.testing.expectEqual(@as(usize, 0), stream.whens.items.len);
        try std.testing.expectEqual(@as(usize, 0), stream.text_nodes.items.len);
        const calls_before_retry = verifyStateInitCalls;

        fault.configure(null);
        try engine.collectStaticRootDescriptorsTransactional(&ctx, &roc_host, &stream, root, .{});
        try std.testing.expectEqual(calls_before_retry + 1, verifyStateInitCalls);
        try std.testing.expectEqual(@as(usize, 2), engine.scopes.items.len);
        try std.testing.expectEqual(@as(usize, 1), engine.node_identities.items.len);
        try std.testing.expectEqual(@as(usize, 1), stream.whens.items.len);
        try std.testing.expectEqualStrings("yes", stream.text_nodes.items[0].value);
    }
}

test "branch replacement preparation leaves the active branch unpublished" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&roc_env);
    const value_callable = abi.rocErasedCallableAllocate(&roc_host, verifyStateCallable, null, 0).?;
    defer abi.decrefErasedCallable(value_callable, &roc_host);
    const bool_callable = abi.rocErasedCallableAllocate(&roc_host, verifyBoolCallable, null, 0).?;
    defer abi.decrefErasedCallable(bool_callable, &roc_host);
    const state_callable = abi.rocErasedCallableAllocate(&roc_host, verifyStateCallable, null, 0).?;
    defer abi.decrefErasedCallable(state_callable, &roc_host);
    const state_capability_callable = abi.rocErasedCallableAllocate(&roc_host, verifyErasedCallable, null, 0).?;
    defer abi.decrefErasedCallable(state_capability_callable, &roc_host);
    const text_callable = abi.rocErasedCallableAllocate(&roc_host, verifyTextCallable, null, 0).?;
    defer abi.decrefErasedCallable(text_callable, &roc_host);
    const capability = HostValueCapability{ .clone = value_callable, .drop = value_callable, .eq = value_callable };
    const state_capability = HostValueCapability{ .clone = state_capability_callable, .drop = state_capability_callable, .eq = state_capability_callable };
    const false_text_read = HostTextRead{ .capability = state_capability, .read = text_callable };
    const false_bool_read = HostBoolRead{ .capability = state_capability, .read = bool_callable };
    const true_text_read = HostTextRead{ .capability = capability, .read = text_callable };
    const true_bool_read = HostBoolRead{ .capability = capability, .read = bool_callable };
    var condition = abi.NodeSignalExpr{ .payload = .{ .const_value = .{
        ._0 = value_callable,
        ._1 = value_callable,
        ._2 = capability,
    } }, .tag = .ConstValue };
    const false_signal_expr = boxOwnedVerifySignalExpr(&roc_host, .{ .payload = .{ .ref = state_callable }, .tag = .Ref });
    defer decrefOwnedVerifySignalExprBox(false_signal_expr, &roc_host);
    const true_signal_expr = boxOwnedVerifySignalExpr(&roc_host, condition);
    defer decrefOwnedVerifySignalExprBox(true_signal_expr, &roc_host);
    const false_attrs = [_]abi.NodeAttr{
        .{ .payload = .{ .static_text = .{ .field = .{ .id = @intFromEnum(RenderTextField.label) }, .name = abi.RocStr.empty(), .value = abi.RocStr.fromSlice("off", undefined) } }, .tag = .StaticText },
        .{ .payload = .{ .static_bool = .{ .field = .{ .id = @intFromEnum(RenderBoolField.disabled) }, .name = abi.RocStr.empty(), .value = true } }, .tag = .StaticBool },
        .{ .payload = .{ .signal_bool = .{ .field = .{ .id = @intFromEnum(RenderBoolField.checked) }, .name = abi.RocStr.empty(), .read = false_bool_read, .signal = false_signal_expr } }, .tag = .SignalBool },
        .{ .payload = .{ .signal_text = .{ .field = .{ .id = @intFromEnum(RenderTextField.role) }, .name = abi.RocStr.empty(), .read = false_text_read, .signal = false_signal_expr } }, .tag = .SignalText },
        .{ .payload = .{ .static_text = .{ .field = .{ .id = abi_view.node_text_field_custom }, .name = abi.RocStr.fromSlice("data-mode", undefined), .value = abi.RocStr.fromSlice("off", undefined) } }, .tag = .StaticText },
        .{ .payload = .{ .static_bool = .{ .field = .{ .id = abi_view.node_bool_field_custom }, .name = abi.RocStr.fromSlice("aria-busy", undefined), .value = true } }, .tag = .StaticBool },
        .{ .payload = .{ .signal_text = .{ .field = .{ .id = abi_view.node_text_field_custom }, .name = abi.RocStr.fromSlice("data-live", undefined), .read = false_text_read, .signal = false_signal_expr } }, .tag = .SignalText },
        .{ .payload = .{ .text_optional_signal = .{ .field = .{ .id = abi_view.node_text_field_custom }, .name = abi.RocStr.fromSlice("data-maybe", undefined), .present = false_bool_read, .read = false_text_read, .signal = false_signal_expr } }, .tag = .TextOptionalSignal },
        .{ .payload = .{ .signal_bool = .{ .field = .{ .id = abi_view.node_bool_field_custom }, .name = abi.RocStr.fromSlice("aria-live", undefined), .read = false_bool_read, .signal = false_signal_expr } }, .tag = .SignalBool },
    };
    const true_attrs = [_]abi.NodeAttr{
        .{ .payload = .{ .static_text = .{ .field = .{ .id = @intFromEnum(RenderTextField.label) }, .name = abi.RocStr.empty(), .value = abi.RocStr.fromSlice("on", undefined) } }, .tag = .StaticText },
        .{ .payload = .{ .static_bool = .{ .field = .{ .id = @intFromEnum(RenderBoolField.disabled) }, .name = abi.RocStr.empty(), .value = false } }, .tag = .StaticBool },
        .{ .payload = .{ .signal_bool = .{ .field = .{ .id = @intFromEnum(RenderBoolField.checked) }, .name = abi.RocStr.empty(), .read = true_bool_read, .signal = true_signal_expr } }, .tag = .SignalBool },
        .{ .payload = .{ .signal_text = .{ .field = .{ .id = @intFromEnum(RenderTextField.role) }, .name = abi.RocStr.empty(), .read = true_text_read, .signal = true_signal_expr } }, .tag = .SignalText },
        .{ .payload = .{ .static_text = .{ .field = .{ .id = abi_view.node_text_field_custom }, .name = abi.RocStr.fromSlice("data-mode", undefined), .value = abi.RocStr.fromSlice("on", undefined) } }, .tag = .StaticText },
        .{ .payload = .{ .static_bool = .{ .field = .{ .id = abi_view.node_bool_field_custom }, .name = abi.RocStr.fromSlice("aria-busy", undefined), .value = false } }, .tag = .StaticBool },
        .{ .payload = .{ .signal_text = .{ .field = .{ .id = abi_view.node_text_field_custom }, .name = abi.RocStr.fromSlice("data-live", undefined), .read = true_text_read, .signal = true_signal_expr } }, .tag = .SignalText },
        .{ .payload = .{ .text_optional_signal = .{ .field = .{ .id = abi_view.node_text_field_custom }, .name = abi.RocStr.fromSlice("data-maybe", undefined), .present = true_bool_read, .read = true_text_read, .signal = true_signal_expr } }, .tag = .TextOptionalSignal },
        .{ .payload = .{ .signal_bool = .{ .field = .{ .id = abi_view.node_bool_field_custom }, .name = abi.RocStr.fromSlice("aria-live", undefined), .read = true_bool_read, .signal = true_signal_expr } }, .tag = .SignalBool },
    };
    var false_text = verifyStaticText();
    false_text.payload.text = abi.RocStr.fromSlice("no", undefined);
    var true_text = verifyStaticText();
    true_text.payload.text = abi.RocStr.fromSlice("yes", undefined);
    const false_signal_text = abi.Elem{ .payload = .{ .text_signal = .{ .read = false_text_read, .signal = false_signal_expr } }, .tag = .TextSignal };
    const true_signal_text = abi.Elem{ .payload = .{ .text_signal = .{ .read = true_text_read, .signal = true_signal_expr } }, .tag = .TextSignal };
    const false_on_change = abi.Elem{ .payload = .{ .on_change_initial = .{ .signal = false_signal_expr, .to_cmd = state_callable } }, .tag = .OnChangeInitial };
    const true_on_change = abi.Elem{ .payload = .{ .on_change_initial = .{ .signal = true_signal_expr, .to_cmd = state_callable } }, .tag = .OnChangeInitial };
    const false_mount = abi.Elem{ .payload = .{ .on_mount = .{ .to_cmd = state_callable } }, .tag = .OnMount };
    const true_mount = abi.Elem{ .payload = .{ .on_mount = .{ .to_cmd = state_callable } }, .tag = .OnMount };
    const false_cleanup = abi.Elem{ .payload = .{ .cleanup = .{ .cleanup = abi.RocStr.fromSlice("branch-cleanup", undefined) } }, .tag = .Cleanup };
    const true_cleanup = abi.Elem{ .payload = .{ .cleanup = .{ .cleanup = abi.RocStr.fromSlice("branch-cleanup-new", undefined) } }, .tag = .Cleanup };
    const false_element = ownedVerifyStaticRoot(&roc_host, &false_attrs, &.{ false_text, false_signal_text, false_on_change, false_mount, false_cleanup });
    var when_false = ownedVerifyStateRoot(&roc_host, state_callable, state_capability_callable, false_element);
    const true_element = ownedVerifyStaticRoot(&roc_host, &true_attrs, &.{ true_text, true_signal_text, true_on_change, true_mount, true_cleanup });
    var when_true = ownedVerifyStateRoot(&roc_host, state_callable, state_capability_callable, true_element);
    const root = abi.Elem{ .payload = .{ .when = .{
        .condition = &condition,
        .read = .{ .capability = capability, .read = bool_callable },
        .when_false = &when_false,
        .when_true = &when_true,
    } }, .tag = .When };

    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    const Runner = struct {
        fn run(root_elem: abi.Elem, host: *abi.RocHost, row_capability: HostValueCapability, failure_number: ?usize) !usize {
            var fault = FaultAllocator.init(std.testing.allocator);
            var ctx = VerifyCtxHost{ .allocator = fault.allocator() };
            var engine = Engine(VerifyCtx).init();
            var stream: HostNodeDescriptorStream = .{};
            defer {
                ctx.render_batch.deinit(ctx.allocator);
                if (engine.active_signal_graph.items.len != 0) {
                    engine.clearActiveSignalRoutes(&ctx);
                    engine.clearActiveSignalGraph(&ctx);
                }
                engine.active_signal_graph.deinit(ctx.allocator);
                engine.active_source_signal_routes.deinit(ctx.allocator);
                engine.active_text_signal_routes.deinit(ctx.allocator);
                engine.active_bool_signal_routes.deinit(ctx.allocator);
                engine.active_change_signal_routes.deinit(ctx.allocator);
                engine.active_structural_signal_routes.deinit(ctx.allocator);
                stream.deinit(ctx.allocator, &ctx, host, &engine.pending_roc_metrics);
                engine.active_stream.deinit(ctx.allocator, &ctx, host, &engine.pending_roc_metrics);
                engine.deinitRenderCache(&ctx);
                deinitVerifyStateEngine(&engine, &ctx, host);
            }
            try engine.collectStaticRootDescriptorsTransactional(&ctx, host, &stream, root_elem, .{});
            engine.active_stream = stream;
            stream = .{};
            engine.roc_host = host;
            engine.rebuildActiveSignalGraphFromStream(&ctx, &engine.active_stream);
            engine.resetRenderTree(&ctx);
            engine.appendRenderNode(&ctx, 1, 0, "div");
            engine.appendRenderNode(&ctx, 2, 1, "text");
            engine.appendRenderNode(&ctx, 3, 1, "text");
            const retired_row_scope_id = engine.createEachRowScope(&ctx, 1, 77, 55, 101, 202, row_capability, row_capability);
            const scope_len = engine.scopes.items.len;
            const identity_len = engine.dom_identities.items.len;
            const text_len = engine.active_stream.text_nodes.items.len;
            const retained_before = engine.pending_roc_metrics.closure_retains - engine.pending_roc_metrics.closure_releases;
            const text_reads_before = verifyTextReadCalls;
            fault.configure(failure_number);
            const prepared = Engine(VerifyCtx).BranchReplacementPlan.prepare(&engine, &ctx, host, engine.active_stream.scope_sites.items[0], engine.active_stream.whens.items[0], .false_branch, .{}, &.{});
            if (failure_number == null) {
                var plan = try prepared;
                const attempts = fault.attempts;
                try std.testing.expectEqual(@as(usize, 1), plan.replacement_stream.elements.items.len);
                try std.testing.expectEqual(@as(usize, 3), plan.replacement_stream.render_nodes.items.len);
                try std.testing.expectEqual(@as(usize, 1), plan.replacement_stream.text_nodes.items.len);
                try std.testing.expectEqualStrings("no", plan.replacement_stream.text_nodes.items[0].value);
                try std.testing.expectEqual(engine.scopes.items[1].scope_id, plan.retired_scope_id);
                try std.testing.expect(plan.target_scopes[@intCast(plan.retired_scope_id)]);
                try std.testing.expectEqualSlices(u64, &.{ retired_row_scope_id, plan.retired_scope_id }, plan.scope_retirement.?.scope_ids);
                try std.testing.expectEqual(@as(usize, 1), plan.row_retirement.?.rows.len);
                try std.testing.expectEqual(@as(usize, 0), plan.effects_retirement.?.task_indexes_descending.len);
                try std.testing.expectEqual(@as(usize, 1), plan.effects_retirement.?.cleanup_names.items.len);
                try std.testing.expectEqualStrings("branch-cleanup-new", plan.effects_retirement.?.cleanup_names.items[0]);
                try std.testing.expectEqual(@as(usize, 4), plan.sink_edits.?.text.len);
                try std.testing.expectEqual(@as(usize, 2), plan.sink_edits.?.bools.len);
                try std.testing.expectEqual(@as(usize, 1), plan.sink_edits.?.changes.len);
                try std.testing.expect(plan.graph_release != null);
                try std.testing.expect(plan.graph_append != null);
                try std.testing.expect(plan.graph_append.?.records.len != 0);
                try std.testing.expect(plan.render_splice != null);
                try std.testing.expectEqual(@as(usize, 3), plan.render_splice.?.removals.items.len);
                try std.testing.expectEqual(@as(usize, 3), plan.render_splice.?.creations.items.len);
                try std.testing.expectEqual(@as(usize, 0), plan.render_batch.published.commands.len());
                try std.testing.expectEqual(@as(usize, 0), plan.render_batch.staged.commands.len());
                try std.testing.expectEqual(text_reads_before + 4, verifyTextReadCalls);
                try std.testing.expect(engine.scopes.items[@intCast(plan.retired_scope_id)].active);
                try std.testing.expectEqualSlices(u64, &.{ 1, 2, 3 }, plan.removal.?.scan.removed_elem_ids);
                try std.testing.expectEqualSlices(usize, &.{0}, plan.removal.?.descriptor_indexes.element_indexes.items);
                try std.testing.expectEqualSlices(usize, &.{0}, plan.removal.?.descriptor_indexes.text_node_indexes.items);
                try std.testing.expectEqualSlices(usize, &.{0}, plan.removal.?.descriptor_indexes.static_text_attr_indexes.items);
                try std.testing.expectEqualSlices(usize, &.{0}, plan.removal.?.descriptor_indexes.static_bool_attr_indexes.items);
                try std.testing.expectEqualSlices(usize, &.{0}, plan.removal.?.descriptor_indexes.signal_bool_attr_indexes.items);
                try std.testing.expectEqualSlices(usize, &.{0}, plan.removal.?.descriptor_indexes.signal_text_attr_indexes.items);
                try std.testing.expectEqualSlices(usize, &.{0}, plan.removal.?.descriptor_indexes.signal_text_node_indexes.items);
                try std.testing.expectEqualSlices(usize, &.{0}, plan.removal.?.descriptor_indexes.static_custom_text_attr_indexes.items);
                try std.testing.expectEqualSlices(usize, &.{0}, plan.removal.?.descriptor_indexes.signal_custom_text_attr_indexes.items);
                try std.testing.expectEqualSlices(usize, &.{0}, plan.removal.?.descriptor_indexes.signal_optional_custom_text_attr_indexes.items);
                try std.testing.expectEqualSlices(usize, &.{0}, plan.removal.?.descriptor_indexes.static_custom_bool_attr_indexes.items);
                try std.testing.expectEqualSlices(usize, &.{0}, plan.removal.?.descriptor_indexes.signal_custom_bool_attr_indexes.items);
                try std.testing.expectEqualSlices(usize, &.{0}, plan.removal.?.node_indexes.on_change_indexes.items);
                try std.testing.expectEqualSlices(usize, &.{0}, plan.removal.?.node_indexes.mount_indexes.items);
                try std.testing.expectEqualSlices(usize, &.{0}, plan.removal.?.node_indexes.cleanup_indexes.items);
                try std.testing.expectEqual(@as(usize, 1), plan.replacement_stream.on_changes.items.len);
                try std.testing.expectEqual(@as(usize, 1), plan.replacement_stream.mounts.items.len);
                try std.testing.expectEqual(@as(usize, 1), plan.replacement_stream.cleanups.items.len);
                try std.testing.expectEqualStrings("branch-cleanup", plan.replacement_stream.cleanups.items[0].name);
                try std.testing.expectEqualSlices(u64, &.{ 4, 5, 6 }, plan.publication.?.replacement_elem_ids);
                try std.testing.expectEqual(@as(usize, 1), plan.state_cell_indexes.len);
                try std.testing.expect(plan.retired_node_identity_ids.len != 0);
                try std.testing.expect(plan.retired_dom_identity_ids.len != 0);
                const retired_node_id = plan.retired_node_identity_ids[0];
                const retired_elem_id = plan.retired_dom_identity_ids[0];
                const old_state_id = engine.states.items[plan.state_cell_indexes[0]].state_id;
                const replacement_state_id = plan.replacement_stream.states.items[0].node_id;
                const replacement_signal_record = plan.replacement_stream.signal_bool_attrs.items[0].signal.record;
                const planned_signal_record_id = plan.graph_append.?.plannedRecordId(engine.active_signal_graph.items, replacement_signal_record) orelse return error.TestUnexpectedResult;
                const planned_text_attr_record_id = plan.graph_append.?.plannedRecordId(engine.active_signal_graph.items, plan.replacement_stream.signal_text_attrs.items[0].signal.record) orelse return error.TestUnexpectedResult;
                const planned_text_node_record_id = plan.graph_append.?.plannedRecordId(engine.active_signal_graph.items, plan.replacement_stream.signal_text_nodes.items[0].signal.record) orelse return error.TestUnexpectedResult;
                const planned_custom_text_record_id = plan.graph_append.?.plannedRecordId(engine.active_signal_graph.items, plan.replacement_stream.signal_custom_text_attrs.items[0].signal.record) orelse return error.TestUnexpectedResult;
                const planned_optional_text_record_id = plan.graph_append.?.plannedRecordId(engine.active_signal_graph.items, plan.replacement_stream.signal_optional_custom_text_attrs.items[0].signal.record) orelse return error.TestUnexpectedResult;
                const planned_custom_bool_record_id = plan.graph_append.?.plannedRecordId(engine.active_signal_graph.items, plan.replacement_stream.signal_custom_bool_attrs.items[0].signal.record) orelse return error.TestUnexpectedResult;
                const planned_change_record_id = plan.graph_append.?.plannedRecordId(engine.active_signal_graph.items, plan.replacement_stream.on_changes.items[0].signal.record) orelse return error.TestUnexpectedResult;
                const replacement_record_refs_before_graph = replacement_signal_record.ref_count;
                fault.configure(1);
                plan.commitAssumeCapacity();
                try std.testing.expectEqual(@as(usize, 0), fault.attempts);
                try std.testing.expectEqual(@as(usize, 0), ctx.render_batch.staged.commands.len());
                try std.testing.expect(ctx.render_batch.published.commands.len() != 0);
                try std.testing.expectEqualStrings("div", engine.render_cache.nodes.items[4].tag.?);
                try std.testing.expectEqualStrings("no", engine.render_cache.nodes.items[5].text.?);
                try std.testing.expectEqualStrings("signal", engine.render_cache.nodes.items[6].text.?);
                try std.testing.expect(engine.render_cache.nodes.items[4].checked.?);
                try std.testing.expectEqualStrings("signal", engine.render_cache.nodes.items[4].role.?);
                try std.testing.expectEqualSlices(u64, &.{4}, engine.render_cache.nodes.items[0].children.items);
                try std.testing.expectEqualSlices(u64, &.{ 5, 6 }, engine.render_cache.nodes.items[4].children.items);
                try std.testing.expectEqual(@as(?u64, planned_signal_record_id), replacement_signal_record.active_graph_id);
                try std.testing.expectEqual(replacement_record_refs_before_graph + 1, replacement_signal_record.ref_count);
                try std.testing.expectEqual(@as(u64, 0), engine.active_signal_graph.items[@intCast(planned_signal_record_id)].rank);
                try std.testing.expectEqualSlices(u64, &.{}, engine.active_signal_graph.items[@intCast(planned_signal_record_id)].dependents);
                const replacement_source_route = engine.active_source_signal_routes.items[@intCast(replacement_state_id)].items;
                try std.testing.expectEqual(@as(usize, 7), replacement_source_route.len);
                const expected_source_records = [_]u64{ planned_text_node_record_id, planned_text_attr_record_id, planned_signal_record_id, planned_custom_text_record_id, planned_optional_text_record_id, planned_custom_bool_record_id, planned_change_record_id };
                for (&expected_source_records) |record_id| {
                    try std.testing.expect(std.mem.indexOfScalar(u64, replacement_source_route, record_id) != null);
                }
                for (replacement_source_route) |record_id| try std.testing.expect(record_id < engine.active_signal_graph.items.len);
                try std.testing.expectEqual(@as(usize, 1), engine.active_text_signal_routes.items[@intCast(planned_text_node_record_id)].items.len);
                try std.testing.expectEqual(@as(usize, 1), engine.active_text_signal_routes.items[@intCast(planned_text_attr_record_id)].items.len);
                try std.testing.expectEqual(@as(usize, 1), engine.active_bool_signal_routes.items[@intCast(planned_signal_record_id)].items.len);
                try std.testing.expectEqual(@as(usize, 1), engine.active_text_signal_routes.items[@intCast(planned_custom_text_record_id)].items.len);
                try std.testing.expectEqual(@as(usize, 1), engine.active_text_signal_routes.items[@intCast(planned_optional_text_record_id)].items.len);
                try std.testing.expectEqual(@as(usize, 1), engine.active_bool_signal_routes.items[@intCast(planned_custom_bool_record_id)].items.len);
                try std.testing.expectEqual(@as(usize, 1), engine.active_change_signal_routes.items[@intCast(planned_change_record_id)].items.len);
                try std.testing.expectEqual(@as(usize, 1), engine.cleanup_events.items.len);
                try std.testing.expectEqualStrings("branch-cleanup-new", engine.cleanup_events.items[0]);
                try std.testing.expect(!engine.scopes.items[@intCast(retired_row_scope_id)].active);
                try std.testing.expect(!engine.scopes.items[@intCast(plan.retired_scope_id)].active);
                try std.testing.expectEqual(@as(?HostEachRowMembership, null), engine.each_row_memberships_by_scope_id.items[@intCast(retired_row_scope_id)]);
                try std.testing.expect(!engine.node_identities.items[@intCast(retired_node_id)].active);
                try std.testing.expect(!engine.dom_identities.items[@intCast(retired_elem_id - 1)].active);
                try std.testing.expectEqual(@as(usize, 1), plan.retired_state_cells.items.len);
                try std.testing.expectEqual(old_state_id, plan.retired_state_cells.items[0].state_id);
                try std.testing.expectEqual(replacement_state_id, engine.states.items[0].state_id);
                try std.testing.expectEqual(@as(?usize, 0), engine.state_indexes_by_node_id.items[@intCast(replacement_state_id)]);
                try std.testing.expectEqual(@as(?usize, null), engine.state_indexes_by_node_id.items[@intCast(old_state_id)]);
                try std.testing.expectEqualStrings("no", engine.active_stream.text_nodes.items[0].value);
                try std.testing.expectEqualStrings("yes", plan.retired_stream.text_nodes.items[0].value);
                try std.testing.expectEqualStrings("off", engine.active_stream.static_text_attrs.items[0].value);
                try std.testing.expect(engine.active_stream.static_bool_attrs.items[0].value);
                try std.testing.expectEqual(@as(usize, 1), engine.active_stream.signal_bool_attrs.items.len);
                try std.testing.expectEqual(@as(usize, 1), plan.retired_stream.signal_bool_attrs.items.len);
                try std.testing.expectEqual(@as(usize, 1), engine.active_stream.signal_text_attrs.items.len);
                try std.testing.expectEqual(@as(usize, 1), engine.active_stream.signal_text_nodes.items.len);
                try std.testing.expectEqual(@as(usize, 1), engine.active_stream.on_changes.items.len);
                try std.testing.expectEqual(@as(usize, 1), engine.active_stream.mounts.items.len);
                try std.testing.expectEqual(@as(usize, 1), engine.active_stream.cleanups.items.len);
                try std.testing.expect(engine.active_stream.on_changes.items[0].run_initial);
                try std.testing.expect(engine.active_stream.on_changes.items[0].run_initial_pending);
                try std.testing.expect(engine.active_stream.mounts.items[0].run_on_mount);
                try std.testing.expectEqualStrings("branch-cleanup", engine.active_stream.cleanups.items[0].name);
                try std.testing.expectEqual(@as(usize, 1), plan.retired_stream.on_changes.items.len);
                try std.testing.expectEqual(@as(usize, 1), plan.retired_stream.mounts.items.len);
                try std.testing.expectEqual(@as(usize, 1), plan.retired_stream.cleanups.items.len);
                switch (engine.active_stream.signal_bool_attrs.items[0].signal.record.payload) {
                    .ref => |node_id| try std.testing.expectEqual(replacement_state_id, node_id),
                    else => return error.TestUnexpectedResult,
                }
                try std.testing.expectEqual(@as(?usize, 0), engine.active_stream.elemDescriptorIndex(4).?.signal_bool_attrs.get(.checked));
                try std.testing.expectEqual(@as(?usize, 0), engine.active_stream.elemDescriptorIndex(4).?.signal_text_attrs.get(.role));
                try std.testing.expectEqual(@as(?usize, 0), engine.active_stream.elemDescriptorIndex(4).?.element.get());
                try std.testing.expectEqual(@as(?usize, 0), engine.active_stream.elemDescriptorIndex(5).?.text_node.get());
                try std.testing.expectEqual(@as(?usize, 0), engine.active_stream.elemDescriptorIndex(6).?.signal_text_node.get());
                fault.configure(null);
                plan.deinit();
                try std.testing.expect(ctx.render_batch.published.commands.len() != 0);
                // Six replacement signal descriptor caches each retain their
                // three-callable capability after publication; retirement
                // still releases the six branch-owned closures measured here.
                try std.testing.expectEqual(retained_before - 6 + 18, engine.pending_roc_metrics.closure_retains - engine.pending_roc_metrics.closure_releases);
                return attempts;
            }
            try std.testing.expectError(error.OutOfMemory, prepared);
            try std.testing.expectEqual(@as(usize, 1), fault.induced_failures);
            try std.testing.expectEqual(scope_len, engine.scopes.items.len);
            try std.testing.expectEqual(identity_len, engine.dom_identities.items.len);
            try std.testing.expectEqual(text_len, engine.active_stream.text_nodes.items.len);
            try std.testing.expectEqual(retained_before, engine.pending_roc_metrics.closure_retains - engine.pending_roc_metrics.closure_releases);
            try std.testing.expectEqual(@as(usize, 0), ctx.render_batch.published.commands.len());
            try std.testing.expectEqual(@as(usize, 0), ctx.render_batch.staged.commands.len());

            fault.configure(null);
            const retry_text_reads_before = verifyTextReadCalls;
            var retry = try Engine(VerifyCtx).BranchReplacementPlan.prepare(&engine, &ctx, host, engine.active_stream.scope_sites.items[0], engine.active_stream.whens.items[0], .false_branch, .{}, &.{});
            try std.testing.expectEqual(retry_text_reads_before + 4, verifyTextReadCalls);
            retry.deinit();
            try std.testing.expectEqualSlices(u64, &.{1}, engine.render_cache.nodes.items[0].children.items);
            try std.testing.expectEqualStrings("div", engine.render_cache.nodes.items[1].tag.?);
            try std.testing.expectEqual(@as(usize, 0), ctx.render_batch.published.commands.len());
            try std.testing.expectEqual(scope_len, engine.scopes.items.len);
            try std.testing.expectEqual(identity_len, engine.dom_identities.items.len);
            try std.testing.expectEqual(text_len, engine.active_stream.text_nodes.items.len);
            return 0;
        }
    };

    const attempts = try Runner.run(root, &roc_host, capability, null);
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| _ = try Runner.run(root, &roc_host, capability, failure_number);
    try std.testing.expect(abi.isUniqueBox(@ptrCast(when_false.payload_state().child)));
    try std.testing.expect(abi.isUniqueBox(@ptrCast(when_true.payload_state().child)));
    when_false.decref(&roc_host);
    when_true.decref(&roc_host);
}

test "transactional static engine root sweeps every allocation and retries cleanly" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&roc_env);
    const signal_callable = abi.rocErasedCallableAllocate(&roc_host, verifyErasedCallable, null, 0);
    defer abi.decrefErasedCallable(signal_callable, &roc_host);
    var signal_expr = abi.NodeSignalExpr{ .payload = .{ .const_value = .{
        ._0 = signal_callable,
        ._1 = signal_callable,
        ._2 = std.mem.zeroes(HostValueCapability),
    } }, .tag = .ConstValue };
    const signal_attr = abi.NodeAttr{ .payload = .{ .signal_text = .{
        .field = .{ .id = @intFromEnum(RenderTextField.value) },
        .name = abi.RocStr.empty(),
        .read = std.mem.zeroes(HostTextRead),
        .signal = &signal_expr,
    } }, .tag = .SignalText };
    const signal_bool_attr = abi.NodeAttr{ .payload = .{ .signal_bool = .{
        .field = .{ .id = @intFromEnum(RenderBoolField.checked) },
        .name = abi.RocStr.empty(),
        .read = std.mem.zeroes(HostBoolRead),
        .signal = &signal_expr,
    } }, .tag = .SignalBool };
    const signal_custom_text_attr = abi.NodeAttr{ .payload = .{ .signal_text = .{
        .field = .{ .id = abi_view.node_text_field_custom },
        .name = abi.RocStr.fromSlice("data-live", undefined),
        .read = std.mem.zeroes(HostTextRead),
        .signal = &signal_expr,
    } }, .tag = .SignalText };
    const signal_custom_bool_attr = abi.NodeAttr{ .payload = .{ .signal_bool = .{
        .field = .{ .id = abi_view.node_bool_field_custom },
        .name = abi.RocStr.fromSlice("aria-live", undefined),
        .read = std.mem.zeroes(HostBoolRead),
        .signal = &signal_expr,
    } }, .tag = .SignalBool };
    const signal_optional_text_attr = abi.NodeAttr{ .payload = .{ .text_optional_signal = .{
        .field = .{ .id = abi_view.node_text_field_custom },
        .name = abi.RocStr.fromSlice("data-maybe", undefined),
        .present = std.mem.zeroes(HostBoolRead),
        .read = std.mem.zeroes(HostTextRead),
        .signal = &signal_expr,
    } }, .tag = .TextOptionalSignal };
    const child = verifyStaticText();
    const signal_child = abi.Elem{ .payload = .{ .text_signal = .{
        .read = std.mem.zeroes(HostTextRead),
        .signal = &signal_expr,
    } }, .tag = .TextSignal };
    const attr = abi.NodeAttr{
        .payload = .{ .static_text = .{
            .field = .{ .id = @intFromEnum(RenderTextField.label) },
            .name = abi.RocStr.empty(),
            .value = abi.RocStr.fromSlice("ready", undefined),
        } },
        .tag = .StaticText,
    };
    const bool_attr = abi.NodeAttr{
        .payload = .{ .static_bool = .{
            .field = .{ .id = @intFromEnum(RenderBoolField.disabled) },
            .name = abi.RocStr.empty(),
            .value = true,
        } },
        .tag = .StaticBool,
    };
    const custom_text_attr = abi.NodeAttr{
        .payload = .{ .static_text = .{
            .field = .{ .id = abi_view.node_text_field_custom },
            .name = abi.RocStr.fromSlice("data-state", undefined),
            .value = abi.RocStr.fromSlice("ready", undefined),
        } },
        .tag = .StaticText,
    };
    const custom_bool_attr = abi.NodeAttr{
        .payload = .{ .static_bool = .{
            .field = .{ .id = abi_view.node_bool_field_custom },
            .name = abi.RocStr.fromSlice("aria-hidden", undefined),
            .value = true,
        } },
        .tag = .StaticBool,
    };
    const root = verifyStaticRoot(&.{ attr, bool_attr, custom_text_attr, custom_bool_attr, signal_attr, signal_bool_attr, signal_custom_text_attr, signal_custom_bool_attr, signal_optional_text_attr }, &.{ child, signal_child });

    var counter = FaultAllocator.init(std.testing.allocator);
    var counter_ctx = VerifyCtxHost{ .allocator = counter.allocator() };
    var counted_engine = Engine(VerifyCtx).init();
    var counted_stream: HostNodeDescriptorStream = .{};
    try counted_engine.collectStaticRootDescriptorsTransactional(&counter_ctx, &roc_host, &counted_stream, root, .{});
    const successful_attempts = counter.attempts;
    counted_stream.deinit(std.testing.allocator, &counter_ctx, &roc_host, &counted_engine.pending_roc_metrics);
    deinitVerifyStaticEngine(&counted_engine, &counter_ctx);
    try std.testing.expect(successful_attempts != 0);

    for (1..successful_attempts + 1) |failure_number| {
        var fault = FaultAllocator.init(std.testing.allocator);
        fault.configure(failure_number);
        var ctx = VerifyCtxHost{ .allocator = fault.allocator() };
        var engine = Engine(VerifyCtx).init();
        var stream: HostNodeDescriptorStream = .{};
        defer {
            stream.deinit(std.testing.allocator, &ctx, &roc_host, &engine.pending_roc_metrics);
            deinitVerifyStaticEngine(&engine, &ctx);
        }

        try std.testing.expectError(error.OutOfMemory, engine.collectStaticRootDescriptorsTransactional(&ctx, &roc_host, &stream, root, .{}));
        try std.testing.expectEqual(@as(usize, 0), engine.scopes.items.len);
        try std.testing.expectEqual(@as(usize, 0), engine.dom_identities.items.len);
        try std.testing.expectEqual(@as(u32, 0), engine.active_dom_identity_ids.count());
        try std.testing.expect(stream.elemDescriptorIndex(1) == null);
        try std.testing.expect(findElementDesc(&stream, 1) == null);
        try std.testing.expect(findTextNodeDesc(&stream, 2) == null);
        try std.testing.expectEqual(@as(usize, 0), stream.signal_text_nodes.items.len);
        try std.testing.expect(!streamHasTextField(&stream, 1, .label));
        try std.testing.expect(!streamHasBoolField(&stream, 1, .disabled));
        try std.testing.expect(!stream.customTextAttrDescriptorExists(1, "data-state"));
        try std.testing.expect(!stream.customTextAttrDescriptorExists(1, "aria-hidden"));
        try std.testing.expectEqual(@as(usize, 0), stream.signal_text_attrs.items.len);
        try std.testing.expectEqual(@as(usize, 0), stream.signal_bool_attrs.items.len);
        try std.testing.expectEqual(@as(usize, 0), stream.signal_custom_text_attrs.items.len);
        try std.testing.expectEqual(@as(usize, 0), stream.signal_custom_bool_attrs.items.len);
        try std.testing.expectEqual(@as(usize, 0), stream.signal_optional_custom_text_attrs.items.len);
        try std.testing.expect(!stream.customTextAttrDescriptorExists(1, "data-live"));
        try std.testing.expect(stream.signalRecordByToken(signal_callable.?) == null);
        try std.testing.expectEqual(engine.pending_roc_metrics.closure_retains, engine.pending_roc_metrics.closure_releases);

        fault.configure(null);
        try engine.collectStaticRootDescriptorsTransactional(&ctx, &roc_host, &stream, root, .{});
        try std.testing.expectEqual(@as(usize, 1), engine.scopes.items.len);
        try std.testing.expectEqual(@as(usize, 3), engine.dom_identities.items.len);
        try std.testing.expectEqualStrings("div", findElementDesc(&stream, 1).?.tag);
        try std.testing.expectEqualStrings("hello", findTextNodeDesc(&stream, 2).?.value);
        try std.testing.expectEqual(@as(usize, 1), stream.signal_text_nodes.items.len);
        try std.testing.expectEqual(@as(u64, 3), stream.signal_text_nodes.items[0].elem_id);
        try std.testing.expect(streamHasTextField(&stream, 1, .label));
        try std.testing.expect(streamHasBoolField(&stream, 1, .disabled));
        try std.testing.expect(stream.customTextAttrDescriptorExists(1, "data-state"));
        try std.testing.expect(stream.customTextAttrDescriptorExists(1, "aria-hidden"));
        try std.testing.expectEqual(@as(usize, 1), stream.signal_text_attrs.items.len);
        try std.testing.expectEqual(@as(usize, 1), stream.signal_bool_attrs.items.len);
        try std.testing.expectEqual(@as(usize, 1), stream.signal_custom_text_attrs.items.len);
        try std.testing.expectEqual(@as(usize, 1), stream.signal_custom_bool_attrs.items.len);
        try std.testing.expectEqual(@as(usize, 1), stream.signal_optional_custom_text_attrs.items.len);
        try std.testing.expect(stream.customTextAttrDescriptorExists(1, "data-live"));
        try std.testing.expect(stream.signalRecordByToken(signal_callable.?) != null);
    }
}

test "transactional lifecycle root sweeps preparation and retries without publication" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&roc_env);
    const callable = abi.rocErasedCallableAllocate(&roc_host, verifyErasedCallable, null, 0).?;
    defer abi.decrefErasedCallable(callable, &roc_host);
    var signal = abi.NodeSignalExpr{ .payload = .{ .const_value = .{ ._0 = callable, ._1 = callable, ._2 = std.mem.zeroes(HostValueCapability) } }, .tag = .ConstValue };
    const on_change = abi.Elem{ .payload = .{ .on_change = .{ .signal = &signal, .to_cmd = callable } }, .tag = .OnChange };
    const mount = abi.Elem{ .payload = .{ .on_mount = .{ .to_cmd = callable } }, .tag = .OnMount };
    const cleanup = abi.Elem{ .payload = .{ .cleanup = .{ .cleanup = abi.RocStr.fromSlice("dispose", undefined) } }, .tag = .Cleanup };
    const root = verifyStaticRoot(&.{}, &.{ on_change, mount, cleanup });

    const Runner = struct {
        fn run(root_elem: abi.Elem, host: *abi.RocHost, failure_number: ?usize) !usize {
            var fault = FaultAllocator.init(std.testing.allocator);
            fault.configure(failure_number);
            var ctx = VerifyCtxHost{ .allocator = fault.allocator() };
            var engine = Engine(VerifyCtx).init();
            var stream: HostNodeDescriptorStream = .{};
            defer {
                stream.deinit(ctx.allocator, &ctx, host, &engine.pending_roc_metrics);
                deinitVerifyStateEngine(&engine, &ctx, host);
            }
            const result = engine.collectStaticRootDescriptorsTransactional(&ctx, host, &stream, root_elem, .{});
            if (failure_number) |_| {
                try std.testing.expectError(error.OutOfMemory, result);
                try std.testing.expectEqual(@as(usize, 0), stream.on_changes.items.len);
                try std.testing.expectEqual(@as(usize, 0), stream.mounts.items.len);
                try std.testing.expectEqual(@as(usize, 0), stream.cleanups.items.len);
                fault.configure(null);
                try engine.collectStaticRootDescriptorsTransactional(&ctx, host, &stream, root_elem, .{});
                try std.testing.expectEqual(@as(usize, 1), stream.on_changes.items.len);
                try std.testing.expectEqual(@as(usize, 1), stream.mounts.items.len);
                try std.testing.expectEqual(@as(usize, 1), stream.cleanups.items.len);
                return 0;
            }
            try result;
            try std.testing.expectEqualDeep(&[_]descriptor_stream.LifecycleDescriptorIndex{
                .{ .kind = .on_change, .index = 0 },
                .{ .kind = .mount, .index = 0 },
                .{ .kind = .cleanup, .index = 0 },
            }, stream.lifecycleIndices(0));
            return fault.attempts;
        }
    };
    const attempts = try Runner.run(root, &roc_host, null);
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| _ = try Runner.run(root, &roc_host, failure_number);
}

test "transactional engine root resource limits preserve state and allow retry" {
    const child = verifyStaticText();
    const root = verifyStaticRoot(&.{}, &.{child});
    var roc_host: abi.RocHost = undefined;
    var ctx = VerifyCtxHost{ .allocator = std.testing.allocator };
    var engine = Engine(VerifyCtx).init();
    var stream: HostNodeDescriptorStream = .{};
    defer {
        stream.deinit(std.testing.allocator, &ctx, &roc_host, &engine.pending_roc_metrics);
        deinitVerifyStaticEngine(&engine, &ctx);
    }

    try std.testing.expectError(error.ResourceLimit, engine.collectStaticRootDescriptorsTransactional(&ctx, &roc_host, &stream, root, .{ .nodes = 1 }));
    try std.testing.expectEqual(@as(usize, 0), engine.scopes.items.len);
    try std.testing.expectEqual(@as(usize, 0), engine.dom_identities.items.len);
    try std.testing.expect(stream.elemDescriptorIndex(1) == null);

    try engine.collectStaticRootDescriptorsTransactional(&ctx, &roc_host, &stream, root, .{});
    try std.testing.expectEqual(@as(usize, 2), engine.dom_identities.items.len);
    try std.testing.expectEqualStrings("hello", findTextNodeDesc(&stream, 2).?.value);
}

test "dirty when set preparation normalizes nested changes without mutation" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var engine = Engine(VerifyCtx).init();
    defer engine.scopes.deinit(std.testing.allocator);

    const root = try engine.internRootScope(std.testing.allocator);
    const outer_old = try engine.internWhenBranchScope(std.testing.allocator, root.scope_id, 10, .false_branch);
    _ = try engine.internWhenBranchScope(std.testing.allocator, outer_old.scope_id, 11, .false_branch);
    _ = try engine.internWhenBranchScope(std.testing.allocator, root.scope_id, 20, .false_branch);

    var changes = [_]HostDirtyStructuralSignal{
        .{ .kind = .when, .node_id = 11, .scope_id = outer_old.scope_id, .ordinal = 11, .record = undefined, .branch = .true_branch },
        .{ .kind = .when, .node_id = 20, .scope_id = root.scope_id, .ordinal = 20, .record = undefined, .branch = .true_branch },
        .{ .kind = .when, .node_id = 10, .scope_id = root.scope_id, .ordinal = 10, .record = undefined, .branch = .true_branch },
    };

    var baseline_fault = FaultAllocator.init(std.testing.allocator);
    var baseline = try Engine(VerifyCtx).PreparedDirtyWhenSet.prepare(&engine, baseline_fault.allocator(), &changes);
    const attempts = baseline_fault.attempts;
    try std.testing.expect(attempts != 0);
    try std.testing.expectEqualSlices(usize, &.{ 2, 1 }, baseline.selected_indexes);
    try std.testing.expectEqualSlices(usize, &.{0}, baseline.subsumed_indexes);
    baseline.deinit(baseline_fault.allocator());

    for (1..attempts + 1) |failure_number| {
        var fault = FaultAllocator.init(std.testing.allocator);
        fault.configure(failure_number);
        try std.testing.expectError(error.OutOfMemory, Engine(VerifyCtx).PreparedDirtyWhenSet.prepare(&engine, fault.allocator(), &changes));
        try std.testing.expectEqual(@as(?HostScopeBranch, .true_branch), changes[0].branch);
        try std.testing.expectEqual(outer_old.scope_id, changes[0].scope_id);
    }

    var retry = try Engine(VerifyCtx).PreparedDirtyWhenSet.prepare(&engine, std.testing.allocator, &changes);
    defer retry.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(usize, &.{ 2, 1 }, retry.selected_indexes);
    try std.testing.expectEqualSlices(usize, &.{0}, retry.subsumed_indexes);
}

test "staged collection reserves multiple external branch scopes atomically" {
    var ctx = VerifyCtxHost{ .allocator = std.testing.allocator };
    var engine = Engine(VerifyCtx).init();
    defer engine.scopes.deinit(std.testing.allocator);
    _ = try engine.internRootScope(std.testing.allocator);
    var roc_host: abi.RocHost = undefined;
    var stream: HostNodeDescriptorStream = .{};
    defer stream.deinit(std.testing.allocator, &ctx, &roc_host, &engine.pending_roc_metrics);

    var collection = try Engine(VerifyCtx).StagedCollectionCtx.init(&engine, &ctx, &stream, .{}, 0, 0, 0, 0, 0, 0, 0, 2);
    defer collection.deinit();
    const first = try collection.reserveWhenBranchScope(0, 1, .true_branch);
    const second = try collection.reserveWhenBranchScope(0, 2, .false_branch);
    try std.testing.expect(first.created);
    try std.testing.expect(second.created);
    try std.testing.expect(first.scope_id != second.scope_id);
    try std.testing.expectEqual(@as(usize, 1), engine.scopes.items.len);

    collection.commit();
    try std.testing.expectEqual(@as(usize, 3), engine.scopes.items.len);
    try std.testing.expectEqual(first.scope_id, engine.scopes.items[1].scope_id);
    try std.testing.expectEqual(second.scope_id, engine.scopes.items[2].scope_id);
}

test "aggregate branch collection sweeps allocation failures without publication" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    const Runner = struct {
        fn run(failure_number: ?usize, live_count: usize) !usize {
            var fault = FaultAllocator.init(std.testing.allocator);
            var ctx = VerifyCtxHost{ .allocator = fault.allocator() };
            var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.default() };
            var roc_host = abi.makeRocHost(&roc_env);
            const fixture = try OwnedAggregateGraphRoot.init(std.testing.allocator, &roc_host);
            defer fixture.deinit();
            ctx.state_capability = .{ .clone = fixture.value_callable, .drop = fixture.value_callable, .eq = fixture.value_callable };
            var engine = Engine(VerifyCtx).init();
            defer {
                if (engine.active_signal_graph.items.len != 0) {
                    engine.clearActiveSignalRoutes(&ctx);
                    engine.clearActiveSignalGraph(&ctx);
                }
                engine.active_stream.deinit(ctx.allocator, &ctx, &roc_host, &engine.pending_roc_metrics);
                engine.active_signal_graph.deinit(ctx.allocator);
                engine.active_source_signal_routes.deinit(ctx.allocator);
                engine.active_text_signal_routes.deinit(ctx.allocator);
                engine.active_bool_signal_routes.deinit(ctx.allocator);
                engine.active_change_signal_routes.deinit(ctx.allocator);
                engine.active_structural_signal_routes.deinit(ctx.allocator);
                ctx.render_batch.deinit(ctx.allocator);
                engine.deinitRenderCache(&ctx);
                effects_runtime.clearPendingTasks(VerifyCtx, &ctx, ctx.allocator, &engine.pending_tasks, &roc_host);
                engine.pending_tasks.deinit(ctx.allocator);
                effects_runtime.deinitCleanupEvents(ctx.allocator, &engine.cleanup_events);
                for (engine.states.items) |*state| state.cell.deinit(&ctx, &roc_host, &engine.pending_roc_metrics);
                engine.states.deinit(ctx.allocator);
                engine.state_indexes_by_node_id.deinit(ctx.allocator);
                engine.node_identities.deinit(ctx.allocator);
                engine.active_node_identity_ids.deinit(ctx.allocator);
                for (engine.scopes.items) |*scope| if (scope.active) deinitHostScopeStep(&scope.step, &ctx, &roc_host, &engine.pending_roc_metrics);
                engine.clearEachRowSites(ctx.allocator);
                engine.scopes.deinit(ctx.allocator);
                engine.dom_identities.deinit(ctx.allocator);
                engine.active_dom_identity_ids.deinit(ctx.allocator);
                engine.deinitScratch(&ctx);
            }
            var initial_stream: HostNodeDescriptorStream = .{};
            try engine.collectStaticRootDescriptorsTransactional(&ctx, &roc_host, &initial_stream, fixture.root, .{});
            engine.active_stream = initial_stream;
            initial_stream = .{};
            engine.roc_host = &roc_host;
            _ = engine.applyNodeDescriptorStream(&ctx, &roc_host, &engine.active_stream);
            try std.testing.expect(engine.render_cache.hasRoot());
            try std.testing.expectEqual(@as(usize, 0), ctx.render_batch.staged.commands.len());
            try std.testing.expectEqual(@as(usize, 0), ctx.render_batch.published.commands.len());
            try std.testing.expectEqual(@as(usize, 5), engine.active_signal_graph.items.len);
            try std.testing.expectEqual(@as(usize, 2), engine.active_stream.whens.items.len);
            try std.testing.expectEqual(@as(usize, 2), engine.active_stream.signal_text_nodes.items.len);
            const first_when = engine.active_stream.whens.items[0];
            const second_when = engine.active_stream.whens.items[1];
            const first_site = engine.active_stream.scope_sites.items[engine.active_stream.nodeDescriptorIndex(first_when.node_id).?.scope_sites.when.get().?];
            const second_site = engine.active_stream.scope_sites.items[engine.active_stream.nodeDescriptorIndex(second_when.node_id).?.scope_sites.when.get().?];
            const first_old = (try engine.activeWhenBranchScopeId(first_site.scope_id, first_site.ordinal, .true_branch)).?;
            const second_old = (try engine.activeWhenBranchScopeId(second_site.scope_id, second_site.ordinal, .true_branch)).?;
            _ = engine.appendPendingTask(&ctx, first_old, fixture.first_true_callable.?, "retired-branch-task", "request");
            const old_graph_len = engine.active_signal_graph.items.len;
            const old_first_record = engine.active_stream.signal_text_nodes.items[0].signal.record;
            const old_second_record = engine.active_stream.signal_text_nodes.items[1].signal.record;
            const old_first_id = old_first_record.active_graph_id.?;
            const old_second_id = old_second_record.active_graph_id.?;
            const old_scope_len = engine.scopes.items.len;
            const old_state_len = engine.states.items.len;
            const old_render_len = engine.active_stream.render_nodes.items.len;
            const old_root_children = try std.testing.allocator.dupe(u64, engine.render_cache.nodes.items[1].children.items);
            defer std.testing.allocator.free(old_root_children);
            try std.testing.expectEqual(@as(usize, 1), engine.active_text_signal_routes.items[@intCast(old_first_id)].items.len);
            try std.testing.expectEqual(@as(usize, 1), engine.active_text_signal_routes.items[@intCast(old_second_id)].items.len);
            const selections = [_]Engine(VerifyCtx).AggregateBranchSelection{
                .{ .parent_scope_id = first_site.scope_id, .site_ordinal = first_site.ordinal, .parent_elem_id = first_site.parent_elem_id, .retired_scope_id = first_old, .render_insert_index = first_site.render_insert_index, .binder_bindings = first_site.binder_bindings, .branch = .false_branch, .elem = first_when.when_false },
                .{ .parent_scope_id = second_site.scope_id, .site_ordinal = second_site.ordinal, .parent_elem_id = second_site.parent_elem_id, .retired_scope_id = second_old, .render_insert_index = second_site.render_insert_index, .binder_bindings = second_site.binder_bindings, .branch = .false_branch, .elem = second_when.when_false },
            };

            if (live_count != 0) {
                const cache_cap = HostValueCapability{ .clone = fixture.value_callable, .drop = fixture.value_callable, .eq = fixture.value_callable };
                var changes = [_]HostDirtyStructuralSignal{
                    .{ .kind = .when, .node_id = first_when.node_id, .scope_id = first_site.scope_id, .ordinal = first_site.ordinal, .record = first_when.condition.record, .branch = .false_branch, .pending_when_cache = HostValueCell.initRetained(0, cache_cap, &engine.pending_roc_metrics) },
                    .{ .kind = .when, .node_id = second_when.node_id, .scope_id = second_site.scope_id, .ordinal = second_site.ordinal, .record = second_when.condition.record, .branch = .false_branch, .pending_when_cache = HostValueCell.initRetained(0, cache_cap, &engine.pending_roc_metrics) },
                };
                defer for (&changes) |*change| change.abortPendingWhenCache(&ctx, &roc_host, &engine.pending_roc_metrics);
                const dirty_changes = changes[0..live_count];
                fault.configure(failure_number);
                const maybe_counts = engine.tryApplyPreparedDirtyWhenSet(&ctx, &roc_host, &.{}, dirty_changes) catch |err| {
                    try std.testing.expectEqual(error.OutOfMemory, err);
                    try std.testing.expectEqualSlices(u64, old_root_children, engine.render_cache.nodes.items[1].children.items);
                    try std.testing.expectEqual(old_graph_len, engine.active_signal_graph.items.len);
                    try std.testing.expectEqual(@as(usize, 1), engine.pending_tasks.items.len);
                    try std.testing.expectEqual(@as(usize, 0), ctx.cancelled_tasks);
                    for (dirty_changes) |change| try std.testing.expect(change.pending_when_cache != null);
                    const attempts = fault.attempts;
                    fault.configure(null);
                    const retry_counts = (try engine.tryApplyPreparedDirtyWhenSet(&ctx, &roc_host, &.{}, dirty_changes)).?;
                    try std.testing.expect(retry_counts.total != 0);
                    for (dirty_changes) |change| try std.testing.expect(change.pending_when_cache == null);
                    try std.testing.expectEqual(@as(usize, 1), ctx.cancelled_tasks);
                    return attempts;
                };
                try std.testing.expect(maybe_counts.?.total != 0);
                for (dirty_changes) |change| try std.testing.expect(change.pending_when_cache == null);
                try std.testing.expectEqual(@as(usize, 1), ctx.cancelled_tasks);
                return fault.attempts;
            }

            fault.configure(failure_number);
            const prepared = Engine(VerifyCtx).AggregateBranchCollection.prepare(&engine, &ctx, &roc_host, &selections, .{}, &.{}) catch |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expectEqual(old_graph_len, engine.active_signal_graph.items.len);
                try std.testing.expectEqual(@as(?u64, old_first_id), old_first_record.active_graph_id);
                try std.testing.expectEqual(@as(?u64, old_second_id), old_second_record.active_graph_id);
                try std.testing.expectEqual(old_scope_len, engine.scopes.items.len);
                try std.testing.expectEqual(old_state_len, engine.states.items.len);
                try std.testing.expectEqual(old_render_len, engine.active_stream.render_nodes.items.len);
                try std.testing.expect(engine.scopes.items[@intCast(first_old)].active);
                try std.testing.expect(engine.scopes.items[@intCast(second_old)].active);
                try std.testing.expectEqual(@as(usize, 1), engine.pending_tasks.items.len);
                try std.testing.expectEqual(@as(usize, 0), ctx.cancelled_tasks);
                try std.testing.expectEqualSlices(u64, old_root_children, engine.render_cache.nodes.items[1].children.items);
                try std.testing.expectEqual(@as(usize, 0), ctx.render_batch.staged.commands.len());
                try std.testing.expectEqual(@as(usize, 0), ctx.render_batch.published.commands.len());
                const attempts = fault.attempts;
                fault.configure(null);
                const retry = try Engine(VerifyCtx).AggregateBranchCollection.prepare(&engine, &ctx, &roc_host, &selections, .{}, &.{});
                defer retry.deinit();
                try std.testing.expectEqual(@as(usize, 2), retry.replacement.stream.signal_text_nodes.items.len);
                try std.testing.expect(retry.graph_release.?.steps.len != 0);
                try std.testing.expectEqual(@as(usize, 4), retry.graph_append.?.records.len);
                try std.testing.expect(retry.render_splice != null);
                try std.testing.expect(retry.render_splice.?.wire.commands.items.len != 0);
                return attempts;
            };
            const attempts = fault.attempts;
            defer prepared.deinit();
            try std.testing.expectEqual(@as(usize, 2), prepared.replacement.stream.signal_text_nodes.items.len);
            try std.testing.expectEqual(@as(usize, 2), prepared.removal.?.removal.descriptor_indexes.signal_text_node_indexes.items.len);
            try std.testing.expect(prepared.graph_release.?.steps.len != 0);
            try std.testing.expectEqual(@as(usize, 4), prepared.graph_append.?.records.len);
            try std.testing.expect(prepared.render_splice != null);
            const first_new = prepared.replacement.stream.signal_text_nodes.items[0].signal.record;
            const second_new = prepared.replacement.stream.signal_text_nodes.items[1].signal.record;
            const first_input = switch (first_new.payload) {
                .map => |payload| payload.input,
                else => return error.TestUnexpectedResult,
            };
            const second_input = switch (second_new.payload) {
                .map => |payload| payload.input,
                else => return error.TestUnexpectedResult,
            };
            const first_new_id = prepared.graph_append.?.plannedRecordId(engine.active_signal_graph.items, first_new).?;
            const second_new_id = prepared.graph_append.?.plannedRecordId(engine.active_signal_graph.items, second_new).?;
            const first_input_id = prepared.graph_append.?.plannedRecordId(engine.active_signal_graph.items, first_input).?;
            const second_input_id = prepared.graph_append.?.plannedRecordId(engine.active_signal_graph.items, second_input).?;
            const first_new_scope = prepared.replacement_scope_ids[0];
            const second_new_scope = prepared.replacement_scope_ids[1];
            try std.testing.expect(first_new_id != second_new_id);
            const first_refs = first_new.ref_count;
            const second_refs = second_new.ref_count;
            const first_input_refs = first_input.ref_count;
            const second_input_refs = second_input.ref_count;
            fault.configure(1);
            prepared.commitAssumeCapacity();
            try std.testing.expectEqual(@as(usize, 0), fault.attempts);
            try std.testing.expectEqual(@as(usize, 0), ctx.render_batch.staged.commands.len());
            try std.testing.expect(ctx.render_batch.published.commands.len() != 0);
            try std.testing.expect(!engine.scopes.items[@intCast(first_old)].active);
            try std.testing.expect(!engine.scopes.items[@intCast(second_old)].active);
            try std.testing.expect(engine.scopes.items[@intCast(first_new_scope)].active);
            try std.testing.expect(engine.scopes.items[@intCast(second_new_scope)].active);
            try std.testing.expectEqual(@as(usize, 2), engine.active_stream.signal_text_nodes.items.len);
            try std.testing.expectEqual(@as(usize, 0), engine.pending_tasks.items.len);
            try std.testing.expectEqual(@as(usize, 1), ctx.cancelled_tasks);
            try std.testing.expectEqual(old_graph_len, engine.active_signal_graph.items.len);
            try std.testing.expectEqual(@as(?u64, null), old_first_record.active_graph_id);
            try std.testing.expectEqual(@as(?u64, null), old_second_record.active_graph_id);
            try std.testing.expectEqual(@as(?u64, first_new_id), first_new.active_graph_id);
            try std.testing.expectEqual(@as(?u64, second_new_id), second_new.active_graph_id);
            try std.testing.expectEqual(first_refs + 1, first_new.ref_count);
            try std.testing.expectEqual(second_refs + 1, second_new.ref_count);
            try std.testing.expectEqual(first_input_refs + 1, first_input.ref_count);
            try std.testing.expectEqual(second_input_refs + 1, second_input.ref_count);
            try std.testing.expectEqual(@as(u64, 1), active_graph.rank(HostSignalRecord, engine.active_signal_graph.items, first_new_id));
            try std.testing.expectEqual(@as(u64, 1), active_graph.rank(HostSignalRecord, engine.active_signal_graph.items, second_new_id));
            try std.testing.expect(std.mem.indexOfScalar(u64, active_graph.dependentIds(HostSignalRecord, engine.active_signal_graph.items, first_input_id), first_new_id) != null);
            try std.testing.expect(std.mem.indexOfScalar(u64, active_graph.dependentIds(HostSignalRecord, engine.active_signal_graph.items, second_input_id), second_new_id) != null);
            const first_source_id = switch (first_input.payload) {
                .ref => |source_id| source_id,
                else => return error.TestUnexpectedResult,
            };
            const second_source_id = switch (second_input.payload) {
                .ref => |source_id| source_id,
                else => return error.TestUnexpectedResult,
            };
            try std.testing.expect(std.mem.indexOfScalar(u64, engine.active_source_signal_routes.items[@intCast(first_source_id)].items, first_input_id) != null);
            try std.testing.expect(std.mem.indexOfScalar(u64, engine.active_source_signal_routes.items[@intCast(second_source_id)].items, second_input_id) != null);
            try std.testing.expectEqual(@as(usize, 1), engine.active_text_signal_routes.items[@intCast(first_new_id)].items.len);
            try std.testing.expectEqual(@as(usize, 1), engine.active_text_signal_routes.items[@intCast(second_new_id)].items.len);
            return attempts;
        }
    };

    const attempts = try Runner.run(null, 0);
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| _ = try Runner.run(failure_number, 0);
    for (1..3) |live_count| {
        const live_attempts = try Runner.run(null, live_count);
        try std.testing.expect(live_attempts != 0);
        for (1..live_attempts + 1) |failure_number| _ = try Runner.run(failure_number, live_count);
    }
}

test "nested live when transaction subsumes inner change atomically" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    const Runner = struct {
        fn run(failure_number: ?usize) !usize {
            var fault = FaultAllocator.init(std.testing.allocator);
            var ctx = VerifyCtxHost{ .allocator = fault.allocator() };
            var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.default() };
            var roc_host = abi.makeRocHost(&roc_env);
            const fixture = try OwnedAggregateGraphRoot.initNested(std.testing.allocator, &roc_host);
            defer fixture.deinit();
            ctx.state_capability = .{ .clone = fixture.value_callable, .drop = fixture.value_callable, .eq = fixture.value_callable };
            var engine = Engine(VerifyCtx).init();
            defer {
                if (engine.active_signal_graph.items.len != 0) {
                    engine.clearActiveSignalRoutes(&ctx);
                    engine.clearActiveSignalGraph(&ctx);
                }
                engine.active_stream.deinit(ctx.allocator, &ctx, &roc_host, &engine.pending_roc_metrics);
                engine.active_signal_graph.deinit(ctx.allocator);
                engine.active_source_signal_routes.deinit(ctx.allocator);
                engine.active_text_signal_routes.deinit(ctx.allocator);
                engine.active_bool_signal_routes.deinit(ctx.allocator);
                engine.active_change_signal_routes.deinit(ctx.allocator);
                engine.active_structural_signal_routes.deinit(ctx.allocator);
                ctx.render_batch.deinit(ctx.allocator);
                engine.deinitRenderCache(&ctx);
                effects_runtime.clearPendingTasks(VerifyCtx, &ctx, ctx.allocator, &engine.pending_tasks, &roc_host);
                engine.pending_tasks.deinit(ctx.allocator);
                effects_runtime.deinitCleanupEvents(ctx.allocator, &engine.cleanup_events);
                for (engine.states.items) |*state| state.cell.deinit(&ctx, &roc_host, &engine.pending_roc_metrics);
                engine.states.deinit(ctx.allocator);
                engine.state_indexes_by_node_id.deinit(ctx.allocator);
                engine.node_identities.deinit(ctx.allocator);
                engine.active_node_identity_ids.deinit(ctx.allocator);
                for (engine.scopes.items) |*scope| if (scope.active) deinitHostScopeStep(&scope.step, &ctx, &roc_host, &engine.pending_roc_metrics);
                engine.clearEachRowSites(ctx.allocator);
                engine.scopes.deinit(ctx.allocator);
                engine.dom_identities.deinit(ctx.allocator);
                engine.active_dom_identity_ids.deinit(ctx.allocator);
                engine.deinitScratch(&ctx);
            }
            var stream: HostNodeDescriptorStream = .{};
            try engine.collectStaticRootDescriptorsTransactional(&ctx, &roc_host, &stream, fixture.root, .{});
            engine.active_stream = stream;
            stream = .{};
            engine.roc_host = &roc_host;
            _ = engine.applyNodeDescriptorStream(&ctx, &roc_host, &engine.active_stream);
            try std.testing.expectEqual(@as(usize, 2), engine.active_stream.whens.items.len);
            try std.testing.expectEqual(@as(usize, 1), engine.active_stream.signal_text_nodes.items.len);
            const outer_when = engine.active_stream.whens.items[0];
            const inner_when = engine.active_stream.whens.items[1];
            const outer_site = engine.active_stream.scope_sites.items[engine.active_stream.nodeDescriptorIndex(outer_when.node_id).?.scope_sites.when.get().?];
            const inner_site = engine.active_stream.scope_sites.items[engine.active_stream.nodeDescriptorIndex(inner_when.node_id).?.scope_sites.when.get().?];
            const outer_old = (try engine.activeWhenBranchScopeId(outer_site.scope_id, outer_site.ordinal, .true_branch)).?;
            const inner_old = (try engine.activeWhenBranchScopeId(inner_site.scope_id, inner_site.ordinal, .true_branch)).?;
            try std.testing.expect(try engine.scopeIsDescendantOrSelf(inner_old, outer_old));
            _ = engine.appendPendingTask(&ctx, inner_old, fixture.first_true_callable.?, "nested-task", "request");
            const old_graph_len = engine.active_signal_graph.items.len;
            const old_inner_record = engine.active_stream.signal_text_nodes.items[0].signal.record;
            const old_inner_id = old_inner_record.active_graph_id.?;
            const old_children = try std.testing.allocator.dupe(u64, engine.render_cache.nodes.items[1].children.items);
            defer std.testing.allocator.free(old_children);
            const cap = HostValueCapability{ .clone = fixture.value_callable, .drop = fixture.value_callable, .eq = fixture.value_callable };
            var changes = [_]HostDirtyStructuralSignal{
                .{ .kind = .when, .node_id = outer_when.node_id, .scope_id = outer_site.scope_id, .ordinal = outer_site.ordinal, .record = outer_when.condition.record, .branch = .false_branch, .pending_when_cache = HostValueCell.initRetained(0, cap, &engine.pending_roc_metrics) },
                .{ .kind = .when, .node_id = inner_when.node_id, .scope_id = inner_site.scope_id, .ordinal = inner_site.ordinal, .record = inner_when.condition.record, .branch = .false_branch, .pending_when_cache = HostValueCell.initRetained(0, cap, &engine.pending_roc_metrics) },
            };
            defer for (&changes) |*change| change.abortPendingWhenCache(&ctx, &roc_host, &engine.pending_roc_metrics);
            fault.configure(failure_number);
            const result = engine.tryApplyPreparedDirtyWhenSet(&ctx, &roc_host, &.{}, &changes) catch |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expectEqual(old_graph_len, engine.active_signal_graph.items.len);
                try std.testing.expectEqual(@as(?u64, old_inner_id), old_inner_record.active_graph_id);
                try std.testing.expectEqualSlices(u64, old_children, engine.render_cache.nodes.items[1].children.items);
                try std.testing.expectEqual(@as(usize, 1), engine.pending_tasks.items.len);
                try std.testing.expectEqual(@as(usize, 0), ctx.cancelled_tasks);
                for (changes) |change| try std.testing.expect(change.pending_when_cache != null);
                const attempts = fault.attempts;
                fault.configure(null);
                try std.testing.expect((try engine.tryApplyPreparedDirtyWhenSet(&ctx, &roc_host, &.{}, &changes)) != null);
                try verifyCommitted(&engine, &ctx, &changes, old_inner_record);
                return attempts;
            };
            try std.testing.expect(result != null);
            try verifyCommitted(&engine, &ctx, &changes, old_inner_record);
            return fault.attempts;
        }

        fn verifyCommitted(engine: *Engine(VerifyCtx), ctx: *VerifyCtxHost, changes: []const HostDirtyStructuralSignal, old_inner_record: *HostSignalRecord) !void {
            for (changes) |change| try std.testing.expect(change.pending_when_cache == null);
            try std.testing.expectEqual(@as(usize, 1), engine.active_stream.whens.items.len);
            try std.testing.expectEqual(@as(?u64, null), old_inner_record.active_graph_id);
            try std.testing.expectEqual(@as(usize, 3), engine.active_signal_graph.items.len);
            const next_record = engine.active_stream.signal_text_nodes.items[0].signal.record;
            const next_id = next_record.active_graph_id.?;
            try std.testing.expectEqual(@as(u64, 1), active_graph.rank(HostSignalRecord, engine.active_signal_graph.items, next_id));
            try std.testing.expectEqual(@as(usize, 1), engine.active_text_signal_routes.items[@intCast(next_id)].items.len);
            try std.testing.expect(next_record.active_use_count != 0);
            try std.testing.expectEqual(@as(usize, 0), engine.pending_tasks.items.len);
            try std.testing.expectEqual(@as(usize, 1), ctx.cancelled_tasks);
            try std.testing.expect(ctx.render_batch.published.commands.len() != 0);
            var found_outer_result = false;
            for (engine.active_stream.text_nodes.items) |text_node| found_outer_result = found_outer_result or std.mem.eql(u8, text_node.value, "first-new");
            try std.testing.expect(found_outer_result);
        }
    };

    const attempts = try Runner.run(null);
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| _ = try Runner.run(failure_number);
    _ = try Runner.run(attempts + 1);
}

comptime {
    verifyCtx(VerifyCtx);
    std.debug.assert(@sizeOf(NoMetrics) == 0);
    _ = Engine(VerifyCtx);
}
