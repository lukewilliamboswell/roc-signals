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
pub const HostDirtyStructuralSignal = active_graph.DirtyStructuralSignal;

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

pub fn findElementDesc(stream: *const HostNodeDescriptorStream, elem_id: u64) ?HostElementDesc {
    return descriptor_stream.findElementDesc(HostNodeDescriptorStream, stream, elem_id);
}

pub fn findTextNodeDesc(stream: *const HostNodeDescriptorStream, elem_id: u64) ?HostNodeTextNodeDesc {
    return descriptor_stream.findTextNodeDesc(HostNodeDescriptorStream, stream, elem_id);
}

pub fn findSignalTextNodeDesc(stream: *const HostNodeDescriptorStream, elem_id: u64) ?HostNodeSignalTextNodeDesc {
    return descriptor_stream.findSignalTextNodeDesc(HostNodeDescriptorStream, stream, elem_id);
}

pub fn findSignalTextNodeDescMutable(stream: *HostNodeDescriptorStream, elem_id: u64) ?*HostNodeSignalTextNodeDesc {
    return descriptor_stream.findSignalTextNodeDescMutable(HostNodeDescriptorStream, stream, elem_id);
}

pub fn streamHasTextField(stream: *const HostNodeDescriptorStream, elem_id: u64, field: RenderTextField) bool {
    return descriptor_stream.streamHasTextField(HostNodeDescriptorStream, stream, elem_id, field);
}

pub fn streamHasCustomTextAttr(stream: *const HostNodeDescriptorStream, elem_id: u64, name: []const u8) bool {
    return descriptor_stream.streamHasCustomTextAttr(HostNodeDescriptorStream, stream, elem_id, name);
}

pub fn streamHasBoolField(stream: *const HostNodeDescriptorStream, elem_id: u64, field: RenderBoolField) bool {
    return descriptor_stream.streamHasBoolField(HostNodeDescriptorStream, stream, elem_id, field);
}

pub fn maxRenderElemId(stream: *const HostNodeDescriptorStream) u64 {
    return descriptor_stream.maxRenderElemId(HostNodeDescriptorStream, stream);
}

pub fn renderNodeTag(stream: *const HostNodeDescriptorStream, node: HostRenderNode) []const u8 {
    return descriptor_stream.renderNodeTag(HostNodeDescriptorStream, stream, node);
}

pub fn streamElemTag(stream: *const HostNodeDescriptorStream, elem_id: u64) []const u8 {
    return descriptor_stream.streamElemTag(HostNodeDescriptorStream, stream, elem_id);
}

pub fn renderNodeParentElemId(stream: *const HostNodeDescriptorStream, node: HostRenderNode) u64 {
    return descriptor_stream.renderNodeParentElemId(HostNodeDescriptorStream, stream, node);
}

pub fn streamElemParentElemId(stream: *const HostNodeDescriptorStream, elem_id: u64) u64 {
    return descriptor_stream.streamElemParentElemId(HostNodeDescriptorStream, stream, elem_id);
}

pub fn streamDirectChildren(allocator: std.mem.Allocator, stream: *const HostNodeDescriptorStream, parent_elem_id: u64) []u64 {
    return descriptor_stream.streamDirectChildren(HostNodeDescriptorStream, allocator, stream, parent_elem_id);
}

pub fn streamDirectChildrenInto(allocator: std.mem.Allocator, stream: *const HostNodeDescriptorStream, parent_elem_id: u64, children: *std.ArrayListUnmanaged(u64)) []const u64 {
    return descriptor_stream.streamDirectChildrenInto(HostNodeDescriptorStream, allocator, stream, parent_elem_id, children);
}

pub fn renderNodeScopeId(stream: *const HostNodeDescriptorStream, node: HostRenderNode) u64 {
    return descriptor_stream.renderNodeScopeId(HostNodeDescriptorStream, stream, node);
}

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

pub fn resolveNodeBinderRef(binder_stack: []const HostBinderBinding, token: HostBinderToken) u64 {
    var index = binder_stack.len;
    while (index > 0) {
        index -= 1;
        const binding = binder_stack[index];
        if (binding.token == token) return binding.node_id;
    }
    @panic("Node.BinderRef referenced a state binder outside the active scope");
}

pub fn renderTextFieldFromAbi(field: u64) RenderTextField {
    return abi_view.textFieldFromAbi(field);
}

pub fn renderBoolFieldFromAbi(field: u64) RenderBoolField {
    return abi_view.boolFieldFromAbi(field);
}

pub fn renderEventKindFromAbi(kind: u64) RenderEventKind {
    return abi_view.eventKindFromAbi(kind);
}

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

            pub fn ensureInterval(self: *@This(), source_token: HostSignalToken, period_ms: u64) void {
                self.engine.ensureActiveInterval(self.ctx, source_token, period_ms);
            }

            pub fn removeInterval(self: *@This(), source_token: HostSignalToken) void {
                self.engine.removeActiveIntervalBySourceToken(self.ctx, source_token);
            }

            pub fn releaseRecord(self: *@This(), record: *HostSignalRecord) void {
                record.release(Ctx.allocator(self.ctx), self.ctx, self.engine.roc_host.?, &self.engine.pending_roc_metrics);
            }
        };

        const EachRowScopeKeyLookup = struct {
            engine: *Self,

            pub fn rowKeyHash(self: *@This(), scope_id: u64) u64 {
                return self.engine.eachRowScopeKeyHash(scope_id);
            }
        };

        const EachRowSync = struct {
            engine: *Self,
            ctx: Ctx.Handle,
            roc_host: *abi.RocHost,
            ops: HostEachOps,

            pub fn recordEachSync(self: *@This(), next_len: usize, existing_len: usize) void {
                self.engine.recordEachSync(next_len, existing_len);
            }

            pub fn hashKey(self: *@This(), key: HostValue) u64 {
                return self.engine.hashEachKeyValue(self.ctx, self.roc_host, self.ops.key_text, self.ops.key_capability, key);
            }

            pub fn nextKeysEqual(self: *@This(), left: HostValue, right: HostValue) bool {
                return self.engine.eachKeysEqual(self.ctx, self.roc_host, self.ops, left, right);
            }

            pub fn existingKeyEquals(self: *@This(), scope_id: u64, key: HostValue) bool {
                return self.engine.eachRowScopeKeyEquals(self.ctx, self.roc_host, scope_id, key, self.ops.key_capability);
            }

            pub fn rowItemEquals(self: *@This(), scope_id: u64, item: HostValue) bool {
                return self.engine.eachRowScopeItemEquals(self.ctx, self.roc_host, scope_id, item, self.ops.item_capability);
            }

            pub fn replaceRowKey(self: *@This(), scope_id: u64, key_hash: u64, key: HostValue) void {
                self.engine.replaceEachRowScopeKey(self.ctx, self.roc_host, scope_id, key_hash, key, self.ops.key_capability);
            }

            pub fn replaceRowItem(self: *@This(), scope_id: u64, item: HostValue) void {
                self.engine.replaceEachRowScopeItemWithCapability(self.ctx, self.roc_host, scope_id, item, self.ops.item_capability);
            }

            pub fn dropIncomingKey(self: *@This(), key: HostValue) void {
                callHostValueToUnitWithCapability(self.ctx, self.roc_host, self.ops.key_capability, hv.hostValueCapabilityDrop(self.ops.key_capability), key);
            }

            pub fn dropIncomingItem(self: *@This(), item: HostValue) void {
                callHostValueToUnitWithCapability(self.ctx, self.roc_host, self.ops.item_capability, hv.hostValueCapabilityDrop(self.ops.item_capability), item);
            }

            pub fn createRow(self: *@This(), parent_scope_id: u64, site_ordinal: u64, key_hash: u64, key: HostValue, item: HostValue) u64 {
                return self.engine.createEachRowScope(self.ctx, parent_scope_id, site_ordinal, key_hash, key, item, self.ops.key_capability, self.ops.item_capability);
            }

            pub fn disposeScope(self: *@This(), scope_id: u64) void {
                self.engine.disposeScopeSubtree(self.ctx, self.roc_host, scope_id);
            }

            pub fn rowKeyHash(self: *@This(), scope_id: u64) u64 {
                return self.engine.eachRowScopeKeyHash(scope_id);
            }

            pub fn recordRows(self: *@This(), rows_reused: u64, rows_created: u64, rows_removed: u64) void {
                var metrics = self.engine.pending_roc_metrics;
                metrics.bump(.rows_reused, rows_reused);
                metrics.bump(.rows_created, rows_created);
                metrics.bump(.rows_removed, rows_removed);
                self.engine.pending_roc_metrics = metrics;
            }

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

        const ScopeIdentityDeactivation = struct {
            engine: *Self,
            ctx: Ctx.Handle,
            roc_host: *abi.RocHost,

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

            pub fn appendCleanupEvents(self: *@This(), scope_id: u64) void {
                for (self.engine.active_stream.cleanups.items) |cleanup| {
                    if (cleanup.scope_id == scope_id) {
                        self.engine.appendCleanupEvent(self.ctx, cleanup.name);
                    }
                }
            }

            pub fn cancelPendingTasks(self: *@This(), scope_id: u64) void {
                self.engine.cancelPendingTasksInScopeSubtree(self.ctx, scope_id);
            }

            pub fn deactivateDomIdentities(self: *@This(), scope_id: u64) void {
                var ordinal: u64 = 0;
                while (self.engine.active_dom_identity_ids.fetchRemove(identityKey(scope_id, ordinal))) |entry| : (ordinal += 1) {
                    const identity = &self.engine.dom_identities.items[@intCast(entry.value - 1)];
                    identity.active = false;
                    identity.retired_at = self.engine.identity_reuse_barrier;
                    self.engine.has_inactive_dom_identities = true;
                }
            }

            pub fn removeEachRow(self: *@This(), scope_id: u64, key_hash: u64) void {
                self.engine.removeEachRowFromSiteIndex(scope_id, key_hash);
            }

            pub fn deinitScopeStep(self: *@This(), step: *HostScopeStep) void {
                deinitHostScopeStep(step, self.ctx, self.roc_host, &self.engine.pending_roc_metrics);
            }

            pub fn recordScopeDisposed(self: *@This()) void {
                self.engine.has_inactive_scopes = true;
                var metrics = self.engine.pending_roc_metrics;
                metrics.bump(.scopes_disposed, 1);
                self.engine.pending_roc_metrics = metrics;
            }
        };

        const ActiveDomIds = struct {
            stream: *const HostNodeDescriptorStream,

            pub fn elemIdIsActive(self: @This(), elem_id: u64) bool {
                const index = self.stream.elemDescriptorIndex(elem_id) orelse return false;
                return elemDescriptorIndexActive(index);
            }
        };

        pub fn init() Self {
            return .{};
        }

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

        fn debugPhase(ctx: Ctx.Handle, phase: u32) void {
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

        pub fn recordDispatch(self: *Self) void {
            if (comptime !enable_runtime_metrics) return;
            self.dispatch_metrics.events_processed += 1;
            self.dispatch_metrics.recompute_batches += 1;
        }

        pub fn recordStreamNodesScanned(self: *Self, count: usize) void {
            self.pending_roc_metrics.bump(.stream_nodes_scanned, @intCast(count));
        }

        pub fn recordStreamNodesScannedBy(self: *Self, comptime field: RuntimeMetrics.Field, count: usize) void {
            var metrics = self.pending_roc_metrics;
            metrics.bump(.stream_nodes_scanned, @intCast(count));
            metrics.bump(field, @intCast(count));
            self.pending_roc_metrics = metrics;
        }

        pub fn recordScopeCreated(self: *Self) void {
            var metrics = self.pending_roc_metrics;
            metrics.bump(.scopes_created, 1);
            self.pending_roc_metrics = metrics;
        }

        pub fn recordEachKeyCompare(self: *Self) void {
            var metrics = self.pending_roc_metrics;
            metrics.bump(.each_key_compares, 1);
            self.pending_roc_metrics = metrics;
        }

        pub fn recordEachKeyHash(self: *Self) void {
            var metrics = self.pending_roc_metrics;
            metrics.bump(.each_key_compares, 1);
            metrics.bump(.each_key_hashes, 1);
            self.pending_roc_metrics = metrics;
        }

        pub fn recordEachKeyReuseCompare(self: *Self) void {
            var metrics = self.pending_roc_metrics;
            metrics.bump(.each_key_compares, 1);
            metrics.bump(.each_key_reuse_compares, 1);
            self.pending_roc_metrics = metrics;
        }

        pub fn recordEachKeyDuplicateCompare(self: *Self) void {
            var metrics = self.pending_roc_metrics;
            metrics.bump(.each_key_compares, 1);
            metrics.bump(.each_key_duplicate_compares, 1);
            self.pending_roc_metrics = metrics;
        }

        pub fn recordEachItemCompare(self: *Self) void {
            var metrics = self.pending_roc_metrics;
            metrics.bump(.each_item_compares, 1);
            self.pending_roc_metrics = metrics;
        }

        pub fn recordEachSync(self: *Self, key_count: usize, existing_count: usize) void {
            var metrics = self.pending_roc_metrics;
            metrics.bump(.each_syncs, 1);
            metrics.bump(.each_sync_keys, @intCast(key_count));
            metrics.bump(.each_sync_existing_rows, @intCast(existing_count));
            self.pending_roc_metrics = metrics;
        }

        pub fn noteStaleTaskResolutionIgnored(self: *Self) void {
            var metrics = self.pending_roc_metrics;
            metrics.bump(.stale_task_results_ignored, 1);
            self.pending_roc_metrics = metrics;
        }

        pub fn deinitRenderCache(self: *Self, ctx: Ctx.Handle) void {
            self.render_cache.deinit(ctx);
        }

        pub fn hasRenderRoot(self: *const Self) bool {
            return self.render_cache.hasRoot();
        }

        pub fn hasActiveRenderNode(self: *const Self, elem_id: u64) bool {
            return self.render_cache.hasActiveNode(elem_id);
        }

        pub fn resetRenderTree(self: *Self, ctx: Ctx.Handle) void {
            self.render_cache.reset(ctx);
        }

        pub fn appendRenderNode(self: *Self, ctx: Ctx.Handle, elem_id: u64, parent_elem_id: u64, tag: []const u8) void {
            self.render_cache.appendNode(ctx, elem_id, parent_elem_id, tag);
        }

        pub fn ensureRenderNode(self: *Self, ctx: Ctx.Handle, elem_id: u64, tag: []const u8, counts: *render.Counts) void {
            self.render_cache.ensureNode(ctx, elem_id, tag, counts);
        }

        pub fn activeRenderNodeTagDiffers(self: *const Self, elem_id: u64, tag: []const u8) bool {
            return self.render_cache.activeNodeTagDiffers(elem_id, tag);
        }

        pub fn removeRenderNode(self: *Self, ctx: Ctx.Handle, elem_id: u64, counts: *render.Counts) void {
            self.render_cache.removeNode(ctx, elem_id, counts);
        }

        pub fn replaceRenderChildren(self: *Self, ctx: Ctx.Handle, parent_elem_id: u64, next_child_ids: []const u64, counts: *render.Counts) void {
            self.render_cache.replaceChildren(ctx, parent_elem_id, next_child_ids, counts);
        }

        pub fn replaceRenderChildrenForMoves(self: *Self, ctx: Ctx.Handle, parent_elem_id: u64, next_child_ids: []const u64, counts: *render.Counts) void {
            self.render_cache.replaceChildrenForMoves(ctx, parent_elem_id, next_child_ids, counts);
        }

        pub fn applyRenderEventBinding(self: *Self, ctx: Ctx.Handle, elem_id: u64, kind: RenderEventKind, binding: ?HostRequiredEventBinding, counts: *render.Counts) void {
            self.render_cache.applyEventBinding(ctx, elem_id, kind, binding, counts);
        }

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

        pub fn debugAssertRenderCacheMatchesSink(self: *Self, ctx: Ctx.Handle) void {
            self.render_cache.debugAssertMatchesSink(ctx);
        }

        pub fn applyRenderTextField(self: *Self, ctx: Ctx.Handle, elem_id: u64, field: RenderTextField, value: []const u8) bool {
            return self.render_cache.applyTextField(ctx, elem_id, field, value);
        }

        pub fn applyRenderTextAttr(self: *Self, ctx: Ctx.Handle, elem_id: u64, name: []const u8, value: []const u8) bool {
            return self.render_cache.applyTextAttr(ctx, elem_id, name, value);
        }

        pub fn applyRenderBoolAttr(self: *Self, ctx: Ctx.Handle, elem_id: u64, name: []const u8, value: bool) bool {
            if (value) {
                return self.applyRenderTextAttr(ctx, elem_id, name, "");
            }
            return self.clearRenderTextAttr(ctx, elem_id, name);
        }

        pub fn applyRenderBoolField(self: *Self, ctx: Ctx.Handle, elem_id: u64, field: RenderBoolField, value: bool) bool {
            return self.render_cache.applyBoolField(ctx, elem_id, field, value);
        }

        pub fn clearRenderTextField(self: *Self, ctx: Ctx.Handle, elem_id: u64, field: RenderTextField) bool {
            return self.render_cache.clearTextField(ctx, elem_id, field);
        }

        pub fn clearRenderTextAttr(self: *Self, ctx: Ctx.Handle, elem_id: u64, name: []const u8) bool {
            return self.render_cache.clearTextAttr(ctx, elem_id, name);
        }

        pub fn clearRenderBoolField(self: *Self, ctx: Ctx.Handle, elem_id: u64, field: RenderBoolField) bool {
            return self.render_cache.clearBoolField(ctx, elem_id, field);
        }

        pub fn clearEventDescriptors(self: *Self) void {
            self.event_descriptors.items.len = 0;
        }

        pub fn deinitActiveEventDesc(self: *Self, roc_host: *abi.RocHost, desc: ActiveEventDesc) void {
            releaseHostEventReducer(desc.payload_reducer, roc_host, &self.pending_roc_metrics);
        }

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

        pub fn deactivateState(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, node_id: u64) void {
            const state_index = self.stateIndexByNodeId(node_id) orelse return;
            const state = &self.states.items[state_index];
            state.cell.deinit(ctx, roc_host, &self.pending_roc_metrics);
            state.active = false;
            self.clearStateCellIndex(node_id, state_index);
        }

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

        pub fn cleanupEventCount(self: *const Self, name: []const u8) u64 {
            return effects_runtime.cleanupEventCount(self.cleanup_events.items, name);
        }

        pub fn activeTaskRecordByToken(self: *Self, token: HostSignalToken) ?*HostSignalRecord {
            return effects_runtime.activeTaskRecordByToken(self.active_signal_graph.items, token);
        }

        pub fn activeIntervalRecordCountByPeriod(self: *const Self, period_ms: u64) u64 {
            return effects_runtime.activeIntervalRecordCountByPeriod(self.active_signal_graph.items, period_ms);
        }

        pub fn activeIntervalRecordByToken(self: *Self, source_token: HostSignalToken) ?*HostSignalRecord {
            return effects_runtime.activeIntervalRecordByToken(self.active_signal_graph.items, source_token);
        }

        pub fn activeIntervalSourceTokenByRuntimeToken(self: *Self, token: u64) ?HostSignalToken {
            return effects_runtime.activeIntervalSourceTokenByRuntimeToken(self.active_intervals.items, token);
        }

        pub fn pendingTaskCountByName(self: *const Self, name: []const u8) u64 {
            return effects_runtime.pendingTaskCountByName(self.pending_tasks.items, name);
        }

        pub fn pendingTaskIndexByRequestId(self: *Self, request_id: u64) ?usize {
            return effects_runtime.pendingTaskIndexByRequestId(self.pending_tasks.items, request_id);
        }

        pub fn classifyTaskResolution(self: *Self, request_id: u64) TaskResolutionClass {
            if (self.pendingTaskIndexByRequestId(request_id) != null) return .pending;
            // Any previously issued, no-longer-pending id is benign here. That
            // deliberately covers both canceled/superseded async work and double
            // resolves of already-completed tasks; hosts should reject ids that
            // were never issued before calling into the engine.
            if (request_id != 0 and request_id < self.next_task_request_id) return .superseded;
            return .unknown;
        }

        pub fn sourceSignalIdsForEvent(self: *Self, event_id: u64) EventLookupError![]const u64 {
            return active_graph.sourceSignalIdsForEvent(self.signal_event_routes.items, event_id);
        }

        pub fn eventPayloadDescriptor(self: *Self, event_id: u64) EventLookupError!BoundaryPayloadDescriptor {
            return active_graph.eventPayloadDescriptor(self.event_descriptors.items, event_id);
        }

        pub fn signalIdsForState(self: *Self, state_id: u64) SignalLookupError![]const u64 {
            return active_graph.signalIdsForState(self.signal_routes.items, state_id);
        }

        pub fn dependentSignalIdsForSignal(self: *Self, signal_id: u64) SignalLookupError![]const u64 {
            return active_graph.dependentSignalIdsForSignal(self.signal_dependents.items, signal_id);
        }

        pub fn signalRank(self: *Self, signal_id: u64) SignalLookupError!u64 {
            return active_graph.signalRank(self.signal_descriptors.items, signal_id);
        }

        pub fn nextDirtySignalGeneration(self: *Self) u64 {
            if (self.dirty_signal_generation == std.math.maxInt(u64)) {
                @panic("host dirty signal generation overflowed");
            }
            self.dirty_signal_generation += 1;
            self.identity_reuse_barrier = self.dirty_signal_generation;
            return self.dirty_signal_generation;
        }

        pub fn activeSignalRank(self: *Self, record_id: u64) u64 {
            return active_graph.rank(HostSignalRecord, self.active_signal_graph.items, record_id);
        }

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

        pub fn recordDerivedCall(self: *Self) void {
            var metrics = self.pending_roc_metrics;
            metrics.bump(.derived_calls_into_roc, 1);
            self.pending_roc_metrics = metrics;
        }

        pub fn recordSignalPrune(self: *Self) void {
            var metrics = self.pending_roc_metrics;
            metrics.bump(.propagation_prunes, 1);
            self.pending_roc_metrics = metrics;
        }

        pub fn cloneCachedSignalValue(self: *Self, ctx: Ctx.Handle, cache_slot: *const HostSignalCacheSlot) HostValue {
            _ = self;
            debugPhase(ctx, 409);
            return switch (cache_slot.*) {
                .absent => @panic("cached signal expression value was requested before initialization"),
                .present => |cached| Ctx.cloneHostValue(ctx, cached.value),
            };
        }

        pub fn updateDirtySignalExprCache(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, cache_slot: *HostSignalCacheSlot, value: HostValue, cap: HostValueCapability) HostSignalEvalResult {
            switch (cache_slot.*) {
                .absent => {
                    debugPhase(ctx, 450);
                    return .{
                        .value = self.replaceSignalExprCacheAndClone(ctx, cache_slot, roc_host, value, cap),
                        .changed = true,
                    };
                },
                .present => |*cached| {
                    debugPhase(ctx, 451);
                    const values_equal = cached.valueEquals(ctx, roc_host, value);
                    if (values_equal) {
                        debugPhase(ctx, 452);
                        cached.dropIncoming(ctx, roc_host, value);
                        self.recordSignalPrune();
                        debugPhase(ctx, 453);
                        return .{ .value = Ctx.cloneHostValue(ctx, cached.value), .changed = false };
                    }

                    debugPhase(ctx, 454);
                    cached.replaceValue(ctx, roc_host, value);
                    debugPhase(ctx, 455);
                    return .{ .value = Ctx.cloneHostValue(ctx, cached.value), .changed = true };
                },
            }
        }

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

        pub fn cloneMemoizedDirtySignalResult(self: *Self, ctx: Ctx.Handle, record: *HostSignalRecord, dirty_generation: u64) ?HostSignalEvalResult {
            if (record.last_dirty_generation != dirty_generation) return null;

            const cache_slot = record.cachedSlot() orelse return null;
            return .{
                .value = self.cloneCachedSignalValue(ctx, cache_slot),
                .changed = record.last_dirty_changed,
            };
        }

        pub fn rememberDirtySignalResult(_: *Self, record: *HostSignalRecord, dirty_generation: u64, result: HostSignalEvalResult) HostSignalEvalResult {
            record.last_dirty_generation = dirty_generation;
            record.last_dirty_changed = result.changed;
            return result;
        }

        pub fn hostSignalRecordCapability(_: *Self, ctx: Ctx.Handle, record: *const HostSignalRecord) HostValueCapability {
            return record.capability(Ctx, ctx);
        }

        pub fn hostSignalBindingCapability(self: *Self, ctx: Ctx.Handle, signal: *const HostSignalBinding) HostValueCapability {
            return self.hostSignalRecordCapability(ctx, signal.record);
        }

        pub fn dropHostSignalRecordValue(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, record: *const HostSignalRecord, value: HostValue) void {
            const cap = self.hostSignalRecordCapability(ctx, record);
            callHostValueToUnitWithCapability(ctx, roc_host, cap, hv.hostValueCapabilityDrop(cap), value);
        }

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

        pub fn bindNodeSignalExpr(self: *Self, allocator: std.mem.Allocator, stream: *HostNodeDescriptorStream, expr: abi.NodeSignalExpr, binder_stack: []const HostBinderBinding) *HostSignalRecord {
            return self.bindSignalExprView(allocator, stream, abi_view.SignalExpr.fromAbi(expr), binder_stack);
        }

        fn bindSignalExprView(self: *Self, allocator: std.mem.Allocator, stream: *HostNodeDescriptorStream, expr: abi_view.SignalExpr, binder_stack: []const HostBinderBinding) *HostSignalRecord {
            return switch (expr) {
                .ref => |payload| blk: {
                    const token = payload.binder.callable;
                    const node_id = resolveNodeBinderRef(binder_stack, token);
                    break :blk HostSignalRecord.init(allocator, .{ .ref = node_id });
                },
                .const_value => |payload| blk: {
                    const token = payload.token.callable;
                    if (self.retainExistingSignalRecordForStream(allocator, stream, token, .const_value)) |record| {
                        break :blk record;
                    }

                    const record = HostSignalRecord.init(allocator, .{ .const_value = .{
                        .init = retainHostCallable(payload.init, &self.pending_roc_metrics),
                        .cap = retainHostValueCapability(payload.capability, &self.pending_roc_metrics),
                    } });
                    stream.rememberSignalRecord(allocator, record);
                    break :blk record;
                },
                .map => |payload| blk: {
                    const token = payload.token.callable;
                    if (self.retainExistingSignalRecordForStream(allocator, stream, token, .map)) |record| {
                        break :blk record;
                    }

                    const input = self.bindSignalExprView(allocator, stream, abi_view.SignalExpr.fromAbi(payload.input.*), binder_stack);
                    const record = HostSignalRecord.init(allocator, .{ .map = .{
                        .input = input,
                        .transform = retainHostCallable(payload.transform, &self.pending_roc_metrics),
                        .cap = retainHostValueCapability(payload.capability, &self.pending_roc_metrics),
                    } });
                    stream.rememberSignalRecord(allocator, record);
                    break :blk record;
                },
                .map2 => |payload| blk: {
                    const token = payload.token.callable;
                    if (self.retainExistingSignalRecordForStream(allocator, stream, token, .map2)) |record| {
                        break :blk record;
                    }

                    const left = self.bindSignalExprView(allocator, stream, abi_view.SignalExpr.fromAbi(payload.left.*), binder_stack);
                    const right = self.bindSignalExprView(allocator, stream, abi_view.SignalExpr.fromAbi(payload.right.*), binder_stack);
                    const record = HostSignalRecord.init(allocator, .{ .map2 = .{
                        .left = left,
                        .right = right,
                        .transform = retainHostCallable(payload.transform, &self.pending_roc_metrics),
                        .cap = retainHostValueCapability(payload.capability, &self.pending_roc_metrics),
                    } });
                    stream.rememberSignalRecord(allocator, record);
                    break :blk record;
                },
                .combine => |payload| blk: {
                    const token = payload.token.callable;
                    if (self.retainExistingSignalRecordForStream(allocator, stream, token, .combine)) |record| {
                        break :blk record;
                    }

                    const children = allocator.alloc(*HostSignalRecord, payload.children.len) catch @panic("out of memory");
                    for (payload.children, children) |child, *dest| {
                        dest.* = self.bindSignalExprView(allocator, stream, abi_view.SignalExpr.fromAbi(child), binder_stack);
                    }
                    const record = HostSignalRecord.init(allocator, .{ .combine = .{
                        .children = children,
                        .transform = retainHostCallable(payload.transform, &self.pending_roc_metrics),
                        .cap = retainHostValueCapability(payload.capability, &self.pending_roc_metrics),
                    } });
                    stream.rememberSignalRecord(allocator, record);
                    break :blk record;
                },
                .task_source => |payload| blk: {
                    const token = payload.token.callable;
                    if (self.retainExistingSignalRecordForStream(allocator, stream, token, .task_source)) |record| {
                        break :blk record;
                    }

                    const record = HostSignalRecord.init(allocator, .{ .task_source = .{
                        .name = allocator.dupe(u8, payload.name.asSlice()) catch @panic("out of memory"),
                        .payload_cap = retainHostValueCapability(payload.payload_capability, &self.pending_roc_metrics),
                        .initial = retainHostCallable(payload.initial, &self.pending_roc_metrics),
                        .done = retainHostCallable(payload.done, &self.pending_roc_metrics),
                        .failed = retainHostCallable(payload.failed, &self.pending_roc_metrics),
                        .cap = retainHostValueCapability(payload.capability, &self.pending_roc_metrics),
                        .reset_on_start = payload.reset_on_start,
                    } });
                    stream.rememberSignalRecord(allocator, record);
                    break :blk record;
                },
                .interval_source => |payload| blk: {
                    const token = payload.token.callable;
                    if (self.retainExistingSignalRecordForStream(allocator, stream, token, .interval_source)) |record| {
                        break :blk record;
                    }

                    const record = HostSignalRecord.init(allocator, .{ .interval_source = .{
                        .period_ms = payload.period_ms,
                        .initial = retainHostCallable(payload.initial, &self.pending_roc_metrics),
                        .tick = retainHostCallable(payload.tick, &self.pending_roc_metrics),
                        .cap = retainHostValueCapability(payload.capability, &self.pending_roc_metrics),
                    } });
                    stream.rememberSignalRecord(allocator, record);
                    break :blk record;
                },
                .location_source => |payload| blk: {
                    const token = payload.token.callable;
                    if (self.retainExistingSignalRecordForStream(allocator, stream, token, .location_source)) |record| {
                        break :blk record;
                    }

                    const record = HostSignalRecord.init(allocator, .{ .location_source = .{
                        .payload_cap = retainHostValueCapability(payload.payload_capability, &self.pending_roc_metrics),
                        .from_payload = retainHostCallable(payload.from_payload, &self.pending_roc_metrics),
                        .cap = retainHostValueCapability(payload.capability, &self.pending_roc_metrics),
                    } });
                    stream.rememberSignalRecord(allocator, record);
                    break :blk record;
                },
                .visibility_source => |payload| blk: {
                    const token = payload.token.callable;
                    if (self.retainExistingSignalRecordForStream(allocator, stream, token, .visibility_source)) |record| {
                        break :blk record;
                    }

                    const record = HostSignalRecord.init(allocator, .{ .visibility_source = .{
                        .payload_cap = retainHostValueCapability(payload.payload_capability, &self.pending_roc_metrics),
                        .from_payload = retainHostCallable(payload.from_payload, &self.pending_roc_metrics),
                        .cap = retainHostValueCapability(payload.capability, &self.pending_roc_metrics),
                    } });
                    stream.rememberSignalRecord(allocator, record);
                    break :blk record;
                },
                .online_source => |payload| blk: {
                    const token = payload.token.callable;
                    if (self.retainExistingSignalRecordForStream(allocator, stream, token, .online_source)) |record| {
                        break :blk record;
                    }

                    const record = HostSignalRecord.init(allocator, .{ .online_source = .{
                        .payload_cap = retainHostValueCapability(payload.payload_capability, &self.pending_roc_metrics),
                        .from_payload = retainHostCallable(payload.from_payload, &self.pending_roc_metrics),
                        .cap = retainHostValueCapability(payload.capability, &self.pending_roc_metrics),
                    } });
                    stream.rememberSignalRecord(allocator, record);
                    break :blk record;
                },
                .storage_source => |payload| blk: {
                    const token = payload.token.callable;
                    if (self.retainExistingSignalRecordForStream(allocator, stream, token, .storage_source)) |record| {
                        break :blk record;
                    }

                    const key_copy = allocator.dupe(u8, payload.key.asSlice()) catch @panic("out of memory");
                    errdefer allocator.free(key_copy);
                    const record = HostSignalRecord.init(allocator, .{ .storage_source = .{
                        .area = payload.area,
                        .key = key_copy,
                        .payload_cap = retainHostValueCapability(payload.payload_capability, &self.pending_roc_metrics),
                        .from_payload = retainHostCallable(payload.from_payload, &self.pending_roc_metrics),
                        .cap = retainHostValueCapability(payload.capability, &self.pending_roc_metrics),
                    } });
                    stream.rememberSignalRecord(allocator, record);
                    break :blk record;
                },
            };
        }

        pub fn bindNodeSignal(self: *Self, allocator: std.mem.Allocator, stream: *HostNodeDescriptorStream, expr: abi.NodeSignalExpr, binder_stack: []const HostBinderBinding) HostSignalBinding {
            const record = self.bindNodeSignalExpr(allocator, stream, expr, binder_stack);
            var source_node_ids: std.ArrayListUnmanaged(u64) = .empty;
            appendSignalRecordSourceNodeIds(allocator, &source_node_ids, record);
            return .{
                .record = record,
                .source_node_ids = source_node_ids.toOwnedSlice(allocator) catch @panic("out of memory"),
            };
        }

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

        pub fn renderNodeInScopeSubtree(self: *Self, stream: *const HostNodeDescriptorStream, node: HostRenderNode, root_scope_id: u64) bool {
            return self.scopeIsDescendantOrSelf(renderNodeScopeId(stream, node), root_scope_id) catch @panic("scope descriptor referenced an unknown parent scope");
        }

        pub fn firstRenderIndexInScopeSubtree(self: *Self, stream: *const HostNodeDescriptorStream, root_scope_id: u64) ?usize {
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_render_scope, stream.render_nodes.items.len);
            for (stream.render_nodes.items, 0..) |node, index| {
                if (self.renderNodeInScopeSubtree(stream, node, root_scope_id)) return index;
            }
            return null;
        }

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

        pub fn cloneHostSignalCacheSlot(self: *Self, ctx: Ctx.Handle, slot: HostSignalCacheSlot, metrics: anytype) HostSignalCacheSlot {
            _ = self;
            return slot.cloneRetained(ctx, metrics);
        }

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

        pub fn deinitPendingTask(self: *Self, ctx: Ctx.Handle, task: *HostPendingTask) void {
            effects_runtime.deinitPendingTask(Ctx.allocator(ctx), self.roc_host.?, task);
        }

        pub fn cancelPendingTask(self: *Self, ctx: Ctx.Handle, task: *HostPendingTask) void {
            effects_runtime.cancelPendingTask(Ctx, ctx, Ctx.allocator(ctx), self.roc_host.?, task);
        }

        pub fn clearPendingTasks(self: *Self, ctx: Ctx.Handle) void {
            effects_runtime.clearPendingTasks(Ctx, ctx, Ctx.allocator(ctx), &self.pending_tasks, self.roc_host);
        }

        pub fn cancelPendingTasksByTaskToken(self: *Self, ctx: Ctx.Handle, task_token: HostSignalToken) void {
            effects_runtime.cancelPendingTasksByTaskToken(Ctx, ctx, Ctx.allocator(ctx), &self.pending_tasks, self.roc_host, task_token);
        }

        pub fn cancelPendingTasksInScopeSubtree(self: *Self, ctx: Ctx.Handle, scope_id: u64) void {
            const ScopeLookup = struct {
                engine: *Self,

                pub fn descendantOrSelf(self_lookup: *@This(), task_scope_id: u64, root_scope_id: u64) bool {
                    return self_lookup.engine.scopeIsDescendantOrSelf(task_scope_id, root_scope_id) catch @panic("scope descriptor referenced an unknown parent scope");
                }
            };
            var scope_lookup = ScopeLookup{ .engine = self };
            effects_runtime.cancelPendingTasksInScopeSubtree(Ctx, ctx, Ctx.allocator(ctx), &self.pending_tasks, self.roc_host, scope_id, &scope_lookup);
        }

        pub fn appendCleanupEvent(self: *Self, ctx: Ctx.Handle, name: []const u8) void {
            effects_runtime.appendCleanupEvent(Ctx.allocator(ctx), &self.cleanup_events, name);
        }

        pub fn disposeScopeSubtree(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, scope_id: u64) void {
            var disposal = ScopeDisposal{ .engine = self, .ctx = ctx, .roc_host = roc_host };
            scope_runtime.disposeSubtree(HostEachRowScopeStep, self.scopes.items, scope_id, self.identity_reuse_barrier, &disposal);
        }

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

        pub fn eachRowScopeItemEquals(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, scope_id: u64, item: HostValue, item_cap: HostValueCapability) bool {
            self.recordEachItemCompare();
            return scope_runtime.eachRowItemEquals(self.scopes.items, ctx, roc_host, scope_id, item, item_cap);
        }

        pub fn replaceEachRowScopeKey(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, scope_id: u64, key_hash: u64, key: HostValue, key_cap: HostValueCapability) void {
            scope_runtime.replaceEachRowKey(self.scopes.items, ctx, roc_host, &self.pending_roc_metrics, scope_id, key_hash, key, key_cap);
        }

        pub fn replaceEachRowScopeItemWithCapability(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, scope_id: u64, item: HostValue, item_cap: HostValueCapability) void {
            scope_runtime.replaceEachRowItem(self.scopes.items, ctx, roc_host, &self.pending_roc_metrics, scope_id, item, item_cap);
        }

        pub fn eachRowScopeValues(self: *Self, scope_id: u64) EachRowValues {
            return scope_runtime.eachRowValues(self.scopes.items, scope_id);
        }

        pub fn syncEachRowScopes(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, parent_scope_id: u64, site_ordinal: u64, keys: []const HostValue, items: []const HostValue, ops: HostEachOps) HostKeyedRowDiffResult {
            self.validateScopeId(parent_scope_id) catch @panic("scope id has no host scope descriptor");
            const allocator = Ctx.allocator(ctx);
            const site_index = self.ensureEachRowSiteIndex(allocator, parent_scope_id, site_ordinal);
            var sync = EachRowSync{ .engine = self, .ctx = ctx, .roc_host = roc_host, .ops = ops };
            return each_runtime.syncRows(allocator, &self.each_row_sites, &self.each_row_memberships_by_scope_id, site_index, parent_scope_id, site_ordinal, keys, items, &sync);
        }

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

        pub fn collectActiveEachRowDescriptors(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, stream: *HostNodeDescriptorStream, site: HostNodeScopeSiteDesc, each: HostNodeEachDesc, dirty_source_node_ids: []const u64) void {
            const allocator = Ctx.allocator(ctx);
            const diff = self.syncActiveEachRowScopes(ctx, roc_host, site, each);
            defer diff.deinit(allocator);
            self.collectActiveEachRowDescriptorsFromDiff(ctx, roc_host, stream, site, each, diff, dirty_source_node_ids);
        }

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
        };

        const StagedCollectionCtx = struct {
            engine: *Self,
            host_ctx: Ctx.Handle,
            stream: *HostNodeDescriptorStream,
            budget: collection_budget.StreamBudget,
            scopes: collection_plan.ScopeOverlay = .{},
            dom_identities: collection_plan.IdentityOverlay = .{},
            prepared_nodes: std.ArrayListUnmanaged(HostNodeDescriptorStream.PreparedStaticNode) = .empty,
            committed: bool = false,

            fn init(engine_ptr: *Self, host_ctx: Ctx.Handle, stream: *HostNodeDescriptorStream, limits: collection_budget.Limits, expected_nodes: usize) CollectionError!@This() {
                var self = @This(){
                    .engine = engine_ptr,
                    .host_ctx = host_ctx,
                    .stream = stream,
                    .budget = collection_budget.StreamBudget.init(limits) catch return error.ResourceLimit,
                };
                errdefer self.deinit();
                const allocator = Ctx.allocator(host_ctx);
                self.scopes.prepare(allocator, 1) catch return error.OutOfMemory;
                if (expected_nodes > limits.nodes) return error.ResourceLimit;
                self.dom_identities.prepare(allocator, expected_nodes) catch return error.OutOfMemory;
                self.prepared_nodes.ensureTotalCapacity(allocator, expected_nodes) catch return error.OutOfMemory;
                self.engine.scopes.ensureUnusedCapacity(allocator, 1) catch return error.OutOfMemory;
                self.engine.dom_identities.ensureUnusedCapacity(allocator, expected_nodes) catch return error.OutOfMemory;
                self.engine.active_dom_identity_ids.ensureUnusedCapacity(allocator, @intCast(expected_nodes)) catch return error.OutOfMemory;
                const highest_elem_id = std.math.add(u64, @intCast(self.engine.dom_identities.items.len), @as(u64, @intCast(expected_nodes))) catch return error.ResourceLimit;
                self.stream.reservePreparedStaticNodes(allocator, expected_nodes, highest_elem_id) catch return error.OutOfMemory;
                return self;
            }

            fn deinit(self: *@This()) void {
                const allocator = Ctx.allocator(self.host_ctx);
                if (!self.committed) {
                    var index = self.prepared_nodes.items.len;
                    while (index != 0) {
                        index -= 1;
                        self.prepared_nodes.items[index].abort(allocator);
                    }
                    self.scopes.abort();
                    self.dom_identities.abort();
                }
                self.prepared_nodes.deinit(allocator);
                self.scopes.deinit(allocator);
                self.dom_identities.deinit(allocator);
            }

            fn rootScope(self: *@This()) CollectionError!scope_tree.InternResult {
                const key: collection_plan.ScopeKey = .{ .parent_id = 0, .ordinal = 0, .kind = 0 };
                const active_id: ?u64 = if (self.engine.scopes.items.len != 0) 0 else null;
                const scope_id = self.scopes.reserve(key, active_id, &.{0}) catch |err| switch (err) {
                    error.NoCapacity => return error.OutOfMemory,
                    error.NoAvailableScope => return error.ResourceLimit,
                };
                return .{ .scope_id = scope_id, .created = active_id == null };
            }

            fn validateScope(self: *@This(), scope_id: u64) CollectionError!void {
                const root_key: collection_plan.ScopeKey = .{ .parent_id = 0, .ordinal = 0, .kind = 0 };
                if (self.scopes.lookup(root_key, null) == scope_id) return;
                self.engine.validateScopeId(scope_id) catch return error.ResourceLimit;
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

            fn appendElement(self: *@This(), scope_id: u64, parent_elem_id: u64, dom_ordinal: *u64, tag: []const u8) CollectionError!u64 {
                const descriptor_bytes = std.math.add(usize, @sizeOf(HostElementDesc), tag.len) catch return error.ResourceLimit;
                try self.budget.charge(1, descriptor_bytes);
                const elem_id = try self.reserveDomIdentity(scope_id, dom_ordinal.*);
                const prepared = self.stream.prepareElement(Ctx.allocator(self.host_ctx), elem_id, parent_elem_id, scope_id, tag) catch return error.OutOfMemory;
                self.prepared_nodes.appendAssumeCapacity(prepared);
                dom_ordinal.* += 1;
                return elem_id;
            }

            fn appendText(self: *@This(), scope_id: u64, parent_elem_id: u64, dom_ordinal: *u64, value: []const u8) CollectionError!void {
                const descriptor_bytes = std.math.add(usize, @sizeOf(HostNodeTextNodeDesc), value.len) catch return error.ResourceLimit;
                try self.budget.charge(1, descriptor_bytes);
                const elem_id = try self.reserveDomIdentity(scope_id, dom_ordinal.*);
                const prepared = self.stream.prepareTextNode(Ctx.allocator(self.host_ctx), elem_id, parent_elem_id, scope_id, value) catch return error.OutOfMemory;
                self.prepared_nodes.appendAssumeCapacity(prepared);
                dom_ordinal.* += 1;
            }
        };

        fn collectActiveElemDescriptorsWith(self: *Self, comptime Collection: type, collection: Collection, ctx: Ctx.Handle, roc_host: *abi.RocHost, stream: *HostNodeDescriptorStream, elem: abi.Elem, scope_id: u64, parent_elem_id: u64, ordinal: *u64, dom_ordinal: *u64, binder_stack: *std.ArrayListUnmanaged(HostBinderBinding), scope_created: bool, dirty_source_node_ids: []const u64) CollectionError!void {
            try collection.validateScope(scope_id);

            const allocator = Ctx.allocator(ctx);
            switch (abi_view.Elem.fromAbi(elem)) {
                .element => |payload| {
                    const elem_id = try collection.appendElement(scope_id, parent_elem_id, dom_ordinal, payload.tag.asSlice());
                    for (payload.attrs) |attr| {
                        self.collectNodeAttrDescriptor(ctx, roc_host, stream, elem_id, attr, binder_stack.items);
                    }
                    for (payload.children) |child| {
                        try self.collectActiveElemDescriptorsWith(Collection, collection, ctx, roc_host, stream, child, scope_id, elem_id, ordinal, dom_ordinal, binder_stack, scope_created, dirty_source_node_ids);
                    }
                },
                .text => |payload| {
                    try collection.appendText(scope_id, parent_elem_id, dom_ordinal, payload.text.asSlice());
                },
                .text_signal => |payload| {
                    const elem_id = self.internDomIdentity(Ctx.allocator(ctx), scope_id, dom_ordinal.*) catch @panic("scope id has no host scope descriptor");
                    dom_ordinal.* += 1;
                    const signal = self.bindNodeSignal(allocator, stream, payload.signal.*, binder_stack.items);
                    stream.appendSignalTextNode(allocator, ctx, roc_host, &self.pending_roc_metrics, elem_id, parent_elem_id, scope_id, signal, payload.read);
                },
                .cleanup => |payload| {
                    stream.appendCleanup(allocator, scope_id, payload.name.asSlice());
                },
                .on_change => |payload| {
                    const signal = self.bindNodeSignal(allocator, stream, payload.signal.*, binder_stack.items);
                    stream.appendOnChange(allocator, ctx, roc_host, &self.pending_roc_metrics, scope_id, signal, payload.to_cmd, payload.run_initial, payload.run_initial and scope_created);
                },
                .on_mount => |payload| {
                    stream.appendMount(allocator, roc_host, &self.pending_roc_metrics, scope_id, payload.to_cmd, scope_created);
                },
                .state => |state| {
                    const site_ordinal = ordinal.*;
                    const node_id = self.internNodeIdentity(Ctx.allocator(ctx), scope_id, site_ordinal) catch @panic("scope id has no host scope descriptor");
                    ordinal.* += 1;
                    stream.appendScopeSite(allocator, node_id, scope_id, site_ordinal, parent_elem_id, .state, binder_stack.items);
                    stream.appendState(allocator, roc_host, &self.pending_roc_metrics, node_id, state.initial, state.capability);
                    self.ensureStateFromDesc(ctx, roc_host, stream.states.items[stream.states.items.len - 1]);
                    const binder_token = state.binder.callable;
                    binder_stack.append(allocator, .{ .token = binder_token, .node_id = node_id }) catch @panic("out of memory");
                    try self.collectActiveElemDescriptorsWith(Collection, collection, ctx, roc_host, stream, state.child.*, scope_id, parent_elem_id, ordinal, dom_ordinal, binder_stack, scope_created, dirty_source_node_ids);
                    _ = binder_stack.pop() orelse unreachable;
                },
                .component => |payload| {
                    const site_ordinal = ordinal.*;
                    const node_id = self.internNodeIdentity(Ctx.allocator(ctx), scope_id, site_ordinal) catch @panic("scope id has no host scope descriptor");
                    ordinal.* += 1;
                    stream.appendScopeSite(allocator, node_id, scope_id, site_ordinal, parent_elem_id, .component, binder_stack.items);
                    const component_scope = self.internComponentScope(Ctx.allocator(ctx), scope_id, site_ordinal) catch @panic("scope id has no host scope descriptor");
                    const component_scope_id = component_scope.scope_id;
                    var component_ordinal: u64 = 0;
                    var component_dom_ordinal: u64 = 0;
                    try self.collectActiveElemDescriptorsWith(Collection, collection, ctx, roc_host, stream, payload.child.*, component_scope_id, parent_elem_id, &component_ordinal, &component_dom_ordinal, binder_stack, component_scope.created, dirty_source_node_ids);
                },
                .when => |when_payload| {
                    const site_ordinal = ordinal.*;
                    const node_id = self.internNodeIdentity(Ctx.allocator(ctx), scope_id, site_ordinal) catch @panic("scope id has no host scope descriptor");
                    ordinal.* += 1;
                    stream.appendScopeSite(allocator, node_id, scope_id, site_ordinal, parent_elem_id, .when, binder_stack.items);
                    const condition_binding = self.bindNodeSignal(allocator, stream, when_payload.condition.*, binder_stack.items);
                    stream.appendWhen(allocator, ctx, roc_host, &self.pending_roc_metrics, node_id, condition_binding, when_payload.read, when_payload.when_false.*, when_payload.when_true.*);

                    const when_index = stream.whens.items.len - 1;
                    const when_desc = &stream.whens.items[when_index];
                    const condition = self.evalHostSignalBinding(ctx, roc_host, &when_desc.condition);
                    const condition_cap = self.hostSignalBindingCapability(ctx, &when_desc.condition);
                    assertHostValueCapabilitiesMatch(when_desc.read.capability, condition_cap, "when read extension capability did not match its signal value");
                    const active_branch: HostScopeBranch = if (callHostValueToBoolWithCapability(ctx, roc_host, when_desc.read.capability, when_desc.read.read, condition)) .true_branch else .false_branch;
                    when_desc.cached_value.replace(ctx, roc_host, &self.pending_roc_metrics, condition, condition_cap);
                    if (self.activeWhenBranchScopeId(scope_id, site_ordinal, active_branch.opposite()) catch @panic("scope id has no host scope descriptor")) |inactive_scope_id| {
                        self.disposeScopeSubtree(ctx, roc_host, inactive_scope_id);
                    }
                    const branch_scope = self.internWhenBranchScope(Ctx.allocator(ctx), scope_id, site_ordinal, active_branch) catch @panic("scope id has no host scope descriptor");
                    const branch_scope_id = branch_scope.scope_id;
                    var branch_ordinal: u64 = 0;
                    const branch_elem = switch (active_branch) {
                        .true_branch => when_payload.when_true.*,
                        .false_branch => when_payload.when_false.*,
                    };
                    var branch_dom_ordinal: u64 = 0;
                    try self.collectActiveElemDescriptorsWith(Collection, collection, ctx, roc_host, stream, branch_elem, branch_scope_id, parent_elem_id, &branch_ordinal, &branch_dom_ordinal, binder_stack, branch_scope.created, dirty_source_node_ids);
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

        pub fn collectActiveElemRootDescriptors(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, stream: *HostNodeDescriptorStream, root: abi.Elem, dirty_source_node_ids: []const u64) void {
            const collection = ImmediateCollectionCtx{ .engine = self, .host_ctx = ctx, .stream = stream };
            self.collectActiveElemRootDescriptorsWith(ImmediateCollectionCtx, collection, ctx, roc_host, stream, root, dirty_source_node_ids) catch @panic("immediate root descriptor collection failed");
        }

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

        pub fn clearActiveSinkSignalRoutes(self: *Self, ctx: Ctx.Handle) void {
            active_graph.clearSinkRoutes(
                Ctx.allocator(ctx),
                &self.active_text_signal_routes,
                &self.active_bool_signal_routes,
                &self.active_change_signal_routes,
                &self.active_structural_signal_routes,
            );
        }

        pub fn activeSignalRecordId(self: *Self, record: *const HostSignalRecord) ?u64 {
            return active_graph.recordId(HostSignalRecord, self.active_signal_graph.items, record);
        }

        pub fn requireActiveSignalRecordId(self: *Self, record: *const HostSignalRecord) u64 {
            return active_graph.requireRecordId(HostSignalRecord, self.active_signal_graph.items, record);
        }

        pub fn appendActiveSignalGraphNode(self: *Self, ctx: Ctx.Handle, record: *HostSignalRecord, rank: u64) u64 {
            const record_id = active_graph.appendNode(HostSignalRecord, Ctx.allocator(ctx), &self.active_signal_graph, record, rank);
            self.pending_roc_metrics.bump(.active_graph_records_rebuilt, 1);
            return record_id;
        }

        pub fn appendActiveSignalDependentId(self: *Self, ctx: Ctx.Handle, input_record_id: u64, dependent_record_id: u64) void {
            active_graph.appendDependentId(HostSignalRecord, Ctx.allocator(ctx), self.active_signal_graph.items, input_record_id, dependent_record_id);
        }

        pub fn appendActiveSourceSignalRoute(self: *Self, ctx: Ctx.Handle, source_node_id: u64, record_id: u64) void {
            active_graph.appendSourceRoute(Ctx.allocator(ctx), &self.active_source_signal_routes, self.node_identities.items.len, source_node_id, record_id);
        }

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

        pub fn ensureActiveSourceSignalRoute(self: *Self, ctx: Ctx.Handle, source_node_id: u64) *std.ArrayListUnmanaged(u64) {
            return active_graph.ensureSourceRoute(Ctx.allocator(ctx), &self.active_source_signal_routes, self.node_identities.items.len, source_node_id);
        }

        pub fn ensureActiveTextSignalRoute(self: *Self, ctx: Ctx.Handle, record_id: u64) *std.ArrayListUnmanaged(HostActiveTextSignalSink) {
            return active_graph.ensureTextRoute(Ctx.allocator(ctx), &self.active_text_signal_routes, self.active_signal_graph.items.len, record_id);
        }

        pub fn ensureActiveBoolSignalRoute(self: *Self, ctx: Ctx.Handle, record_id: u64) *std.ArrayListUnmanaged(HostActiveBoolSignalSink) {
            return active_graph.ensureBoolRoute(Ctx.allocator(ctx), &self.active_bool_signal_routes, self.active_signal_graph.items.len, record_id);
        }

        pub fn ensureActiveChangeSignalRoute(self: *Self, ctx: Ctx.Handle, record_id: u64) *std.ArrayListUnmanaged(HostActiveChangeSignalSink) {
            return active_graph.ensureChangeRoute(Ctx.allocator(ctx), &self.active_change_signal_routes, self.active_signal_graph.items.len, record_id);
        }

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

        pub fn scopeIsInReplacementTarget(self: *Self, scope_id: u64, target: HostStructuralReplacementTarget) bool {
            return switch (target) {
                .scope => |root_scope_id| self.scopeIsDescendantOrSelf(scope_id, root_scope_id) catch @panic("scope descriptor referenced an unknown parent scope"),
                .each_site => |site| self.scopeIsEachSiteRowDescendantOrSelf(scope_id, site) catch @panic("scope descriptor referenced an unknown parent scope"),
            };
        }

        fn buildReplacementTargetScopeSet(self: *Self, ctx: Ctx.Handle, target: HostStructuralReplacementTarget) []const bool {
            const TargetLookup = struct {
                engine: *Self,

                pub fn scopeIsInTarget(self_lookup: *@This(), scope_id: u64, replacement_target: HostStructuralReplacementTarget) bool {
                    return self_lookup.engine.scopeIsInReplacementTarget(scope_id, replacement_target);
                }
            };
            var lookup = TargetLookup{ .engine = self };
            return structural_splice.buildTargetScopeSet(HostScope, Ctx.allocator(ctx), &self.scratch.replacement_target_scopes, self.scopes.items, target, &lookup);
        }

        pub fn renderNodeInReplacementTarget(self: *Self, stream: *const HostNodeDescriptorStream, node: HostRenderNode, target: HostStructuralReplacementTarget) bool {
            return self.scopeIsInReplacementTarget(renderNodeScopeId(stream, node), target);
        }

        pub fn renderNodeInReplacementTargetSet(self: *Self, stream: *const HostNodeDescriptorStream, node: HostRenderNode, target_scopes: []const bool) bool {
            _ = self;
            return structural_splice.scopeIsInTargetSet(target_scopes, renderNodeScopeId(stream, node));
        }

        pub fn elemIdInReplacementTarget(self: *Self, stream: *const HostNodeDescriptorStream, elem_id: u64, target: HostStructuralReplacementTarget) bool {
            const scope_id = elemScopeId(stream, elem_id) orelse @panic("descriptor referenced an element outside the render stream");
            return self.scopeIsInReplacementTarget(scope_id, target);
        }

        pub fn elemIdInReplacementTargetSet(self: *Self, stream: *const HostNodeDescriptorStream, elem_id: u64, target_scopes: []const bool) bool {
            _ = self;
            const scope_id = elemScopeId(stream, elem_id) orelse @panic("descriptor referenced an element outside the render stream");
            return structural_splice.scopeIsInTargetSet(target_scopes, scope_id);
        }

        pub fn streamNodeIdInReplacementTarget(self: *Self, previous: *const HostNodeDescriptorStream, node_id: u64, kind: HostNodeScopeSiteKind, target: HostStructuralReplacementTarget) bool {
            const descriptor_index = previous.nodeDescriptorIndex(node_id) orelse return false;
            const site_index = descriptor_index.scope_sites.get(kind) orelse return false;
            if (site_index >= previous.scope_sites.items.len) @panic("scope site descriptor index exceeded descriptor table");
            const site = previous.scope_sites.items[site_index];
            if (site.node_id != node_id or site.kind != kind) @panic("scope site descriptor index pointed at the wrong node");
            return self.scopeIsInReplacementTarget(site.scope_id, target);
        }

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

        pub fn spliceActiveStreamReplacingTarget(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, target: HostStructuralReplacementTarget, render_insert_index: usize, replacement: *HostNodeDescriptorStream) HostStructuralSplice {
            return self.spliceActiveStreamReplacingTargetWithOptions(ctx, roc_host, target, render_insert_index, replacement, null, true);
        }

        pub fn spliceActiveStreamReplacingTargetWithOptions(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, target: HostStructuralReplacementTarget, render_insert_index: usize, replacement: *HostNodeDescriptorStream, child_insert_hint: ?HostRenderChildInsertHint, refresh_suffix_indexes: bool) HostStructuralSplice {
            return self.spliceActiveStreamReplacingTargetWithScopeSet(ctx, roc_host, target, render_insert_index, replacement, child_insert_hint, refresh_suffix_indexes, null);
        }

        // Snapshot the replacement-target scope set while the replaced scope
        // subtree is still live. A when-arm swap disposes the outgoing branch
        // scopes before its splice runs, and a removal scan classifying old
        // render nodes against the post-disposal scope tree under-collects:
        // the outgoing arm's descriptors survive while their (already reused)
        // elem ids re-register, tripping the duplicate-descriptor-index panic.
        pub fn snapshotReplacementTargetScopeSet(self: *Self, ctx: Ctx.Handle, target: HostStructuralReplacementTarget) []const bool {
            const built = self.buildReplacementTargetScopeSet(ctx, target);
            const copy = Ctx.allocator(ctx).dupe(bool, built) catch @panic("out of memory");
            self.scratch.replacement_target_scopes.clearRetainingCapacity();
            return copy;
        }

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

        pub fn spliceActiveStreamReplacingScope(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, replaced_scope_id: u64, render_insert_index: usize, replacement: *HostNodeDescriptorStream) HostStructuralSplice {
            return self.spliceActiveStreamReplacingTarget(ctx, roc_host, .{ .scope = replaced_scope_id }, render_insert_index, replacement);
        }

        pub fn spliceActiveStreamReplacingScopeWithOptions(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, replaced_scope_id: u64, render_insert_index: usize, replacement: *HostNodeDescriptorStream, child_insert_hint: ?HostRenderChildInsertHint, refresh_suffix_indexes: bool) HostStructuralSplice {
            return self.spliceActiveStreamReplacingTargetWithOptions(ctx, roc_host, .{ .scope = replaced_scope_id }, render_insert_index, replacement, child_insert_hint, refresh_suffix_indexes);
        }

        pub fn replaceSignalExprCacheAndClone(self: *Self, ctx: Ctx.Handle, cache_slot: *HostSignalCacheSlot, roc_host: *abi.RocHost, value: HostValue, cap: HostValueCapability) HostValue {
            cache_slot.replace(ctx, roc_host, &self.pending_roc_metrics, value, cap);
            return self.cloneCachedSignalValue(ctx, cache_slot);
        }

        pub fn evalEffectSourceInitial(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, cache_slot: *HostSignalCacheSlot, initial: abi.RocErasedCallable, cap: HostValueCapability) HostValue {
            switch (cache_slot.*) {
                .present => return self.cloneCachedSignalValue(ctx, cache_slot),
                .absent => {
                    const value = erased_calls.callValueInitThunk(roc_host, initial);
                    return self.replaceSignalExprCacheAndClone(ctx, cache_slot, roc_host, value, cap);
                },
            }
        }

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

        pub fn evalHostSignalBinding(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, signal: *HostSignalBinding) HostValue {
            return self.evalHostSignalRecord(ctx, roc_host, signal.record);
        }

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

        pub fn evalSignalOptionalTextAttr(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, elem_id: u64, name: []const u8, signal: *HostSignalBinding, present: HostBoolRead, read: HostTextRead, cache_slot: *HostSignalCacheSlot) bool {
            const value = self.evalHostSignalBinding(ctx, roc_host, signal);
            const signal_cap = self.hostSignalBindingCapability(ctx, signal);
            const changed = self.applySignalOptionalTextAttrValue(ctx, roc_host, elem_id, name, value, signal_cap, present, read);
            cache_slot.replace(ctx, roc_host, &self.pending_roc_metrics, value, signal_cap);
            return changed;
        }

        pub fn evalSignalBoolField(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, elem_id: u64, field: RenderBoolField, signal: *HostSignalBinding, read: HostBoolRead, cache_slot: *HostSignalCacheSlot) bool {
            const value = self.evalHostSignalBinding(ctx, roc_host, signal);
            const signal_cap = self.hostSignalBindingCapability(ctx, signal);
            assertHostValueCapabilitiesMatch(read.capability, signal_cap, "bool read extension capability did not match its signal value");
            const bool_value = callHostValueToBoolWithCapability(ctx, roc_host, read.capability, read.read, value);
            const changed = self.applyRenderBoolField(ctx, elem_id, field, bool_value);
            cache_slot.replace(ctx, roc_host, &self.pending_roc_metrics, value, signal_cap);
            return changed;
        }

        pub fn evalSignalBoolAttr(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, elem_id: u64, name: []const u8, signal: *HostSignalBinding, read: HostBoolRead, cache_slot: *HostSignalCacheSlot) bool {
            const value = self.evalHostSignalBinding(ctx, roc_host, signal);
            const signal_cap = self.hostSignalBindingCapability(ctx, signal);
            assertHostValueCapabilitiesMatch(read.capability, signal_cap, "bool attr read extension capability did not match its signal value");
            const bool_value = callHostValueToBoolWithCapability(ctx, roc_host, read.capability, read.read, value);
            const changed = self.applyRenderBoolAttr(ctx, elem_id, name, bool_value);
            cache_slot.replace(ctx, roc_host, &self.pending_roc_metrics, value, signal_cap);
            return changed;
        }

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

        pub fn evalStructuralSignalTextField(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, elem_id: u64, field: RenderTextField, signal: *HostSignalBinding, read: HostTextRead, cache_slot: *HostSignalCacheSlot, dirty_source_node_ids: []const u64, dirty_generation: u64) bool {
            if (dirty_generation != 0 and sourceNodeIdsIntersect(signal.source_node_ids, dirty_source_node_ids)) {
                return self.evalDirtySignalTextField(ctx, roc_host, elem_id, field, signal, read, cache_slot, dirty_source_node_ids, dirty_generation);
            }
            return self.evalSignalTextField(ctx, roc_host, elem_id, field, signal, read, cache_slot);
        }

        pub fn evalStructuralSignalTextAttr(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, elem_id: u64, name: []const u8, signal: *HostSignalBinding, read: HostTextRead, cache_slot: *HostSignalCacheSlot, dirty_source_node_ids: []const u64, dirty_generation: u64) bool {
            if (dirty_generation != 0 and sourceNodeIdsIntersect(signal.source_node_ids, dirty_source_node_ids)) {
                return self.evalDirtySignalTextAttr(ctx, roc_host, elem_id, name, signal, read, cache_slot, dirty_source_node_ids, dirty_generation);
            }
            return self.evalSignalTextAttr(ctx, roc_host, elem_id, name, signal, read, cache_slot);
        }

        pub fn evalStructuralSignalOptionalTextAttr(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, elem_id: u64, name: []const u8, signal: *HostSignalBinding, present: HostBoolRead, read: HostTextRead, cache_slot: *HostSignalCacheSlot, dirty_source_node_ids: []const u64, dirty_generation: u64) bool {
            if (dirty_generation != 0 and sourceNodeIdsIntersect(signal.source_node_ids, dirty_source_node_ids)) {
                return self.evalDirtySignalOptionalTextAttr(ctx, roc_host, elem_id, name, signal, present, read, cache_slot, dirty_source_node_ids, dirty_generation);
            }
            return self.evalSignalOptionalTextAttr(ctx, roc_host, elem_id, name, signal, present, read, cache_slot);
        }

        pub fn evalStructuralSignalBoolField(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, elem_id: u64, field: RenderBoolField, signal: *HostSignalBinding, read: HostBoolRead, cache_slot: *HostSignalCacheSlot, dirty_source_node_ids: []const u64, dirty_generation: u64) bool {
            if (dirty_generation != 0 and sourceNodeIdsIntersect(signal.source_node_ids, dirty_source_node_ids)) {
                return self.evalDirtySignalBoolField(ctx, roc_host, elem_id, field, signal, read, cache_slot, dirty_source_node_ids, dirty_generation);
            }
            return self.evalSignalBoolField(ctx, roc_host, elem_id, field, signal, read, cache_slot);
        }

        pub fn evalStructuralSignalBoolAttr(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, elem_id: u64, name: []const u8, signal: *HostSignalBinding, read: HostBoolRead, cache_slot: *HostSignalCacheSlot, dirty_source_node_ids: []const u64, dirty_generation: u64) bool {
            if (dirty_generation != 0 and sourceNodeIdsIntersect(signal.source_node_ids, dirty_source_node_ids)) {
                return self.evalDirtySignalBoolAttr(ctx, roc_host, elem_id, name, signal, read, cache_slot, dirty_source_node_ids, dirty_generation);
            }
            return self.evalSignalBoolAttr(ctx, roc_host, elem_id, name, signal, read, cache_slot);
        }

        pub fn evalDirtyHostSignalRecord(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, record: *HostSignalRecord, dirty_source_node_ids: []const u64, dirty_generation: u64) HostSignalEvalResult {
            if (dirty_generation == 0) @panic("dirty signal evaluation used generation 0");
            debugPhase(ctx, 400);
            if (self.cloneMemoizedDirtySignalResult(ctx, record, dirty_generation)) |result| return result;

            switch (record.payload) {
                .ref => |node_id| {
                    debugPhase(ctx, 401);
                    return .{
                        .value = Ctx.stateValueByNodeId(ctx, node_id),
                        .changed = u64SliceContains(dirty_source_node_ids, node_id),
                    };
                },
                .const_value => |*payload| {
                    if (payload.cached_value == .absent) {
                        debugPhase(ctx, 402);
                        const value = erased_calls.callValueInitThunk(roc_host, payload.init);
                        return self.rememberDirtySignalResult(record, dirty_generation, self.updateDirtySignalExprCache(ctx, roc_host, &payload.cached_value, value, payload.cap));
                    }
                    debugPhase(ctx, 403);
                    return self.rememberDirtySignalResult(record, dirty_generation, .{
                        .value = self.cloneCachedSignalValue(ctx, &payload.cached_value),
                        .changed = false,
                    });
                },
                .map => |*payload| {
                    const cache_was_absent = payload.cached_value == .absent;
                    debugPhase(ctx, 420);
                    const input = self.evalDirtyHostSignalRecord(ctx, roc_host, payload.input, dirty_source_node_ids, dirty_generation);
                    defer self.dropHostSignalRecordValue(ctx, roc_host, payload.input, input.value);
                    if (!input.changed and !cache_was_absent) {
                        debugPhase(ctx, 423);
                        return self.rememberDirtySignalResult(record, dirty_generation, .{ .value = self.cloneCachedSignalValue(ctx, &payload.cached_value), .changed = false });
                    }

                    self.recordDerivedCall();
                    debugPhase(ctx, 421);
                    const input_cap = self.hostSignalRecordCapability(ctx, payload.input);
                    const value = callHostValueToHostValueWithCapability(ctx, roc_host, input_cap, payload.transform, input.value);
                    debugPhase(ctx, 422);
                    return self.rememberDirtySignalResult(record, dirty_generation, self.updateDirtySignalExprCache(ctx, roc_host, &payload.cached_value, value, payload.cap));
                },
                .map2 => |*payload| {
                    const cache_was_absent = payload.cached_value == .absent;
                    debugPhase(ctx, 430);
                    const left = self.evalDirtyHostSignalRecord(ctx, roc_host, payload.left, dirty_source_node_ids, dirty_generation);
                    defer self.dropHostSignalRecordValue(ctx, roc_host, payload.left, left.value);
                    debugPhase(ctx, 431);
                    const right = self.evalDirtyHostSignalRecord(ctx, roc_host, payload.right, dirty_source_node_ids, dirty_generation);
                    defer self.dropHostSignalRecordValue(ctx, roc_host, payload.right, right.value);
                    if (!left.changed and !right.changed and !cache_was_absent) {
                        debugPhase(ctx, 434);
                        return self.rememberDirtySignalResult(record, dirty_generation, .{ .value = self.cloneCachedSignalValue(ctx, &payload.cached_value), .changed = false });
                    }

                    self.recordDerivedCall();
                    debugPhase(ctx, 432);
                    const left_cap = self.hostSignalRecordCapability(ctx, payload.left);
                    const right_cap = self.hostSignalRecordCapability(ctx, payload.right);
                    const value = callHostValueHostValueToHostValueWithCapabilities(ctx, roc_host, left_cap, right_cap, payload.transform, left.value, right.value);
                    debugPhase(ctx, 433);
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
                        debugPhase(ctx, 440);
                        const child_result = self.evalDirtyHostSignalRecord(ctx, roc_host, child, dirty_source_node_ids, dirty_generation);
                        any_changed = any_changed or child_result.changed;
                        values.append(allocator, child_result.value) catch @panic("out of memory");
                    }

                    if (!any_changed and !cache_was_absent) {
                        debugPhase(ctx, 443);
                        for (payload.children, values.items) |child, value| {
                            self.dropHostSignalRecordValue(ctx, roc_host, child, value);
                        }
                        values.deinit(allocator);
                        return self.rememberDirtySignalResult(record, dirty_generation, .{ .value = self.cloneCachedSignalValue(ctx, &payload.cached_value), .changed = false });
                    }

                    const list = HostValueList.fromSlice(values.items, roc_host);
                    defer list.decref(roc_host);
                    self.recordDerivedCall();
                    debugPhase(ctx, 441);
                    const input_cap = if (payload.children.len == 0) payload.cap else self.hostSignalRecordCapability(ctx, payload.children[0]);
                    const value = callHostValueListToHostValueWithCapability(ctx, roc_host, input_cap, payload.transform, list);
                    debugPhase(ctx, 442);
                    for (payload.children, values.items) |child, child_value| {
                        self.dropHostSignalRecordValue(ctx, roc_host, child, child_value);
                    }
                    values.deinit(allocator);
                    return self.rememberDirtySignalResult(record, dirty_generation, self.updateDirtySignalExprCache(ctx, roc_host, &payload.cached_value, value, payload.cap));
                },
                .task_source => |*payload| {
                    debugPhase(ctx, 410);
                    return self.rememberDirtySignalResult(record, dirty_generation, .{
                        .value = self.cloneCachedSignalValue(ctx, &payload.cached_value),
                        .changed = record.last_dirty_generation == dirty_generation and record.last_dirty_changed,
                    });
                },
                .interval_source => |*payload| {
                    debugPhase(ctx, 411);
                    return self.rememberDirtySignalResult(record, dirty_generation, .{
                        .value = self.cloneCachedSignalValue(ctx, &payload.cached_value),
                        .changed = record.last_dirty_generation == dirty_generation and record.last_dirty_changed,
                    });
                },
                .location_source => |*payload| {
                    debugPhase(ctx, 412);
                    return self.rememberDirtySignalResult(record, dirty_generation, .{
                        .value = self.cloneCachedSignalValue(ctx, &payload.cached_value),
                        .changed = record.last_dirty_generation == dirty_generation and record.last_dirty_changed,
                    });
                },
                .visibility_source => |*payload| {
                    debugPhase(ctx, 414);
                    return self.rememberDirtySignalResult(record, dirty_generation, .{
                        .value = self.cloneCachedSignalValue(ctx, &payload.cached_value),
                        .changed = record.last_dirty_generation == dirty_generation and record.last_dirty_changed,
                    });
                },
                .online_source => |*payload| {
                    debugPhase(ctx, 415);
                    return self.rememberDirtySignalResult(record, dirty_generation, .{
                        .value = self.cloneCachedSignalValue(ctx, &payload.cached_value),
                        .changed = record.last_dirty_generation == dirty_generation and record.last_dirty_changed,
                    });
                },
                .storage_source => |*payload| {
                    debugPhase(ctx, 413);
                    return self.rememberDirtySignalResult(record, dirty_generation, .{
                        .value = self.cloneCachedSignalValue(ctx, &payload.cached_value),
                        .changed = record.last_dirty_generation == dirty_generation and record.last_dirty_changed,
                    });
                },
            }
        }

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
                debugPhase(ctx, 331);
                const result = self.evalDirtyHostSignalRecord(ctx, roc_host, record, dirty_source_node_ids, dirty_generation);
                if (result.changed) {
                    changed_record_ids.append(allocator, record_id) catch @panic("out of memory");
                }
                debugPhase(ctx, 332);
                self.dropHostSignalRecordValue(ctx, roc_host, record, result.value);
            }

            return changed_record_ids.items;
        }

        pub fn collectDirtyStructuralSignals(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, allocator: std.mem.Allocator, dirty_source_node_ids: []const u64, changed_record_ids: []const u64, dirty_generation: u64) []HostDirtyStructuralSignal {
            var dirty_structural_signals: std.ArrayListUnmanaged(HostDirtyStructuralSignal) = .empty;
            errdefer dirty_structural_signals.deinit(allocator);

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
                            if (self.updateDirtySignalCache(ctx, roc_host, &desc.cached_value, result.value, cap)) {
                                dirty_structural_signals.append(allocator, .{
                                    .kind = .when,
                                    .node_id = desc.node_id,
                                    .scope_id = site.scope_id,
                                    .ordinal = site.ordinal,
                                    .record = desc.condition.record,
                                    .branch = active_branch,
                                }) catch @panic("out of memory");
                            }
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

        pub fn stateIndexByNodeId(self: *Self, node_id: u64) ?usize {
            if (node_id >= self.state_indexes_by_node_id.items.len) return null;
            const state_index = self.state_indexes_by_node_id.items[@intCast(node_id)] orelse return null;
            if (state_index >= self.states.items.len) @panic("state cell index exceeded state table");
            const state = self.states.items[state_index];
            if (!state.active or state.state_id != node_id) @panic("state cell index pointed at the wrong state");
            return state_index;
        }

        pub fn stateCapability(self: *Self, node_id: u64) StateLookupError!HostValueCapability {
            const state_index = self.stateIndexByNodeId(node_id) orelse return StateLookupError.MissingActiveState;
            return self.states.items[state_index].cell.cap;
        }

        pub fn activeEventReducerByIndex(self: *Self, event_index: usize) ActiveEventLookupError!HostEventReducer {
            if (event_index >= self.active_events.items.len) return ActiveEventLookupError.MissingActiveEvent;
            return self.active_events.items[event_index].payload_reducer;
        }

        pub fn activeScopeSiteByNodeId(self: *Self, node_id: u64, kind: HostNodeScopeSiteKind) ?HostNodeScopeSiteDesc {
            const descriptor_index = self.active_stream.nodeDescriptorIndex(node_id) orelse return null;
            const scope_site_index = descriptor_index.scope_sites.get(kind) orelse return null;
            if (scope_site_index >= self.active_stream.scope_sites.items.len) @panic("active scope site index exceeded descriptor table");
            const site = self.active_stream.scope_sites.items[scope_site_index];
            if (site.node_id != node_id or site.kind != kind) @panic("active scope site index pointed at the wrong node");
            return site;
        }

        pub fn activeWhenIndexByNodeId(self: *Self, node_id: u64) ?usize {
            const descriptor_index = self.active_stream.nodeDescriptorIndex(node_id) orelse return null;
            const when_index = descriptor_index.when.get() orelse return null;
            if (when_index >= self.active_stream.whens.items.len) @panic("active when index exceeded descriptor table");
            if (self.active_stream.whens.items[when_index].node_id != node_id) @panic("active when index pointed at the wrong node");
            return when_index;
        }

        pub fn activeEachIndexByNodeId(self: *Self, node_id: u64) ?usize {
            const descriptor_index = self.active_stream.nodeDescriptorIndex(node_id) orelse return null;
            const each_index = descriptor_index.each.get() orelse return null;
            if (each_index >= self.active_stream.eaches.items.len) @panic("active each index exceeded descriptor table");
            if (self.active_stream.eaches.items[each_index].node_id != node_id) @panic("active each index pointed at the wrong node");
            return each_index;
        }

        pub fn recordSliceContains(records: []const *HostSignalRecord, record: *HostSignalRecord) bool {
            return active_graph.recordSliceContains(HostSignalRecord, records, record);
        }

        pub fn activeWhenBranchScopeId(self: *Self, parent_scope_id: u64, site_ordinal: u64, branch: HostScopeBranch) scope_tree.Error!?u64 {
            return scope_tree.activeWhenBranch(HostEachRowScopeStep, self.scopes.items, parent_scope_id, site_ordinal, branch);
        }

        pub fn validateScopeId(self: *Self, scope_id: u64) scope_tree.Error!void {
            return scope_tree.validate(HostEachRowScopeStep, self.scopes.items, scope_id);
        }

        pub fn internRootScope(self: *Self, allocator: std.mem.Allocator) scope_tree.Error!scope_tree.InternResult {
            const result = try scope_tree.internRoot(HostEachRowScopeStep, allocator, &self.scopes);
            if (result.created) self.recordScopeCreated();
            return result;
        }

        pub fn internComponentScope(self: *Self, allocator: std.mem.Allocator, parent_scope_id: u64, site_ordinal: u64) scope_tree.Error!scope_tree.InternResult {
            const result = try scope_tree.internComponent(HostEachRowScopeStep, allocator, &self.scopes, parent_scope_id, site_ordinal, self.identity_reuse_barrier);
            if (result.created) self.recordScopeCreated();
            return result;
        }

        pub fn internWhenBranchScope(self: *Self, allocator: std.mem.Allocator, parent_scope_id: u64, site_ordinal: u64, branch: HostScopeBranch) scope_tree.Error!scope_tree.InternResult {
            const result = try scope_tree.internWhenBranch(HostEachRowScopeStep, allocator, &self.scopes, parent_scope_id, site_ordinal, branch, self.identity_reuse_barrier);
            if (result.created) self.recordScopeCreated();
            return result;
        }

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

        pub fn activeEachRowScopes(self: *Self, allocator: std.mem.Allocator, parent_scope_id: u64, site_ordinal: u64) scope_tree.Error![]u64 {
            try self.validateScopeId(parent_scope_id);
            const site_index = self.activeEachRowSiteIndex(parent_scope_id, site_ordinal) orelse {
                return allocator.alloc(u64, 0) catch return scope_tree.Error.OutOfMemory;
            };
            return allocator.dupe(u64, self.each_row_sites.items[site_index].scope_ids.items) catch return scope_tree.Error.OutOfMemory;
        }

        pub fn eachRowScopeKeyEquals(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, scope_id: u64, key: HostValue, key_cap: HostValueCapability) bool {
            self.recordEachKeyReuseCompare();
            return scope_runtime.eachRowKeyEquals(self.scopes.items, ctx, roc_host, scope_id, key, key_cap);
        }

        pub fn eachRowScopeKeyValue(self: *Self, scope_id: u64) HostValue {
            return scope_runtime.eachRowKeyValue(self.scopes.items, scope_id);
        }

        pub fn eachRowScopeKeyHash(self: *Self, scope_id: u64) u64 {
            return scope_runtime.eachRowKeyHash(self.scopes.items, scope_id);
        }

        pub fn hashEachKeyValue(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, key_text: abi.RocErasedCallable, key_cap: HostValueCapability, key: HostValue) u64 {
            self.recordEachKeyHash();
            const text = callHostValueToStrWithCapability(ctx, roc_host, key_cap, key_text, key);
            defer text.decref(roc_host);
            return hashEachKeyText(text.asSlice());
        }

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

        pub fn eachKeysEqual(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, ops: HostEachOps, left: HostValue, right: HostValue) bool {
            self.recordEachKeyDuplicateCompare();
            const key_cap = ops.key_capability;
            return callHostValueHostValueToBoolWithCapability(ctx, roc_host, key_cap, hv.hostValueCapabilityEq(key_cap), left, right);
        }

        pub fn eachSiteRowAncestorScopeId(self: *Self, scope_id: u64, site: HostEachSite) scope_tree.Error!?u64 {
            return scope_tree.eachSiteRowAncestor(HostEachRowScopeStep, self.scopes.items, scope_id, site.parent_scope_id, site.site_ordinal);
        }

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

        pub fn scopeIsEachSiteRowDescendantOrSelf(self: *Self, scope_id: u64, site: HostEachSite) scope_tree.Error!bool {
            return scope_tree.eachSiteRowDescendantOrSelf(HostEachRowScopeStep, self.scopes.items, scope_id, site.parent_scope_id, site.site_ordinal);
        }

        pub fn eachDiffPreservesSurvivorRenderOrder(old_render_rows: []const u64, next_scope_ids: []const u64) bool {
            return each_runtime.diffPreservesSurvivorRenderOrder(old_render_rows, next_scope_ids);
        }

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

        pub fn eachRenderSegmentScopeIds(allocator: std.mem.Allocator, segments: []const HostEachRowRenderSegment) []u64 {
            return each_runtime.renderSegmentScopeIds(allocator, segments);
        }

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

        pub fn renderInsertIndexForEachRowRanges(site: HostNodeScopeSiteDesc, row_ranges: *const std.AutoHashMapUnmanaged(u64, HostEachRowRenderSegment), next_scope_ids: []const u64, row_index: usize) usize {
            return each_runtime.renderInsertIndexForRowRanges(site.render_insert_index, row_ranges, next_scope_ids, row_index);
        }

        pub fn renderAppendIndexForEachRowRanges(site: HostNodeScopeSiteDesc, row_ranges: *const std.AutoHashMapUnmanaged(u64, HostEachRowRenderSegment)) usize {
            var append_index = site.render_insert_index;
            var range_iterator = row_ranges.iterator();
            while (range_iterator.next()) |entry| {
                append_index = @max(append_index, entry.value_ptr.start + entry.value_ptr.len);
            }
            return append_index;
        }

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

        pub fn adjustEachRowRenderRanges(row_ranges: *std.AutoHashMapUnmanaged(u64, HostEachRowRenderSegment), replace_index: usize, removed_count: usize, replacement_count: usize) void {
            each_runtime.adjustRenderRanges(row_ranges, replace_index, removed_count, replacement_count);
        }

        pub fn updateEachRowRenderRange(row_ranges: *std.AutoHashMapUnmanaged(u64, HostEachRowRenderSegment), allocator: std.mem.Allocator, scope_id: u64, render_insert_index: usize, removed_count: usize, replacement_count: usize) void {
            each_runtime.updateRenderRange(row_ranges, allocator, scope_id, render_insert_index, removed_count, replacement_count);
        }

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

        pub fn applyDirtyEachMixedRowSplicesAndMoves(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, site: HostNodeScopeSiteDesc, each: HostNodeEachDesc, old_render_segments: []const HostEachRowRenderSegment, diff: HostKeyedRowDiffResult, dirty_source_node_ids: []const u64, dirty_generation: u64) render.Counts {
            var counts = self.applyDirtyEachRowScopeSplices(ctx, roc_host, site, each, old_render_segments, diff, true, dirty_source_node_ids, dirty_generation);
            counts.addAll(self.applyDirtyEachPermutationMoves(ctx, site, diff.scope_ids));
            return counts;
        }

        pub fn evalOnChangeInitial(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, desc: *HostNodeOnChangeDesc) void {
            const value = self.evalHostSignalBinding(ctx, roc_host, &desc.signal);
            desc.cached_value.replace(ctx, roc_host, &self.pending_roc_metrics, value, self.hostSignalBindingCapability(ctx, &desc.signal));
        }

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

        pub fn evalMountCommand(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, desc: *HostNodeMountDesc) render.Counts {
            if (!desc.run_on_mount) return .{};
            desc.run_on_mount = false;

            const cmd = erased_calls.callUnitToCmd(roc_host, desc.to_cmd);
            defer cmd.decref(roc_host);
            return self.runCommand(ctx, roc_host, desc.scope_id, cmd);
        }

        pub fn runActiveMountCommandIndices(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, indices: []const usize) render.Counts {
            var counts: render.Counts = .{};
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_mounts, indices.len);
            for (indices) |mount_index| {
                if (mount_index >= self.active_stream.mounts.items.len) @panic("mount descriptor index exceeded active descriptor stream");
                counts.addAll(self.evalMountCommand(ctx, roc_host, &self.active_stream.mounts.items[mount_index]));
            }
            return counts;
        }

        pub fn runActiveMountCommands(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost) render.Counts {
            var counts: render.Counts = .{};
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_mounts, self.active_stream.mounts.items.len);
            for (self.active_stream.mounts.items) |*desc| {
                counts.addAll(self.evalMountCommand(ctx, roc_host, desc));
            }
            return counts;
        }

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

        pub fn fixedEventBindingForElemKind(stream: *const HostNodeDescriptorStream, elem_id: u64, kind: RenderEventKind) ?HostRequiredEventBinding {
            const descriptor_index = stream.elemDescriptorIndex(elem_id) orelse return null;
            const event_index = descriptor_index.events.get(kind) orelse return null;
            if (event_index >= stream.events.items.len) @panic("event descriptor index exceeded descriptor table");
            const desc = stream.events.items[event_index];
            const fixed_kind = desc.fixedKind() orelse @panic("fixed event descriptor index pointed at a named event");
            if (desc.elem_id != elem_id or fixed_kind != kind) @panic("fixed event descriptor index pointed at the wrong event");
            return .{ .event_id = @intCast(event_index + 1), .delivery = .{ .requested = desc.delivery_request }, .payload_descriptor = desc.payload_descriptor };
        }

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

        pub fn activeEventBindingForElemKind(self: *Self, elem_id: u64, kind: RenderEventKind) ?HostRequiredEventBinding {
            const descriptor_index = self.active_stream.elemDescriptorIndex(elem_id) orelse return null;
            const event_index = descriptor_index.events.get(kind) orelse return null;
            if (event_index >= self.active_stream.events.items.len) @panic("active event descriptor index exceeded descriptor table");
            const desc = self.active_stream.events.items[event_index];
            const fixed_kind = desc.fixedKind() orelse @panic("active fixed event descriptor index pointed at a named event");
            if (desc.elem_id != elem_id or fixed_kind != kind) @panic("active event descriptor index pointed at the wrong event");
            return .{ .event_id = @intCast(event_index + 1), .delivery = .{ .requested = desc.delivery_request }, .payload_descriptor = desc.payload_descriptor };
        }

        pub fn applyStructuralEventBindingsForElem(self: *Self, ctx: Ctx.Handle, elem_id: u64, counts: *render.Counts) void {
            for (render_event_kinds) |kind| {
                const next_binding = self.activeEventBindingForElemKind(elem_id, kind);
                self.applyRenderEventBinding(ctx, elem_id, kind, next_binding, counts);
            }
            self.applyStructuralNamedEventBindingsForElem(ctx, &self.active_stream, elem_id, counts);
        }

        pub fn applyActiveStreamEventBindings(self: *Self, ctx: Ctx.Handle, counts: *render.Counts) void {
            self.recordStreamNodesScannedBy(.stream_nodes_scanned_events, self.active_stream.render_nodes.items.len);
            for (self.active_stream.render_nodes.items) |node| {
                if (node.kind != .element) continue;
                self.applyStructuralEventBindingsForElem(ctx, node.elem_id, counts);
            }
        }

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

        pub fn applyActiveStreamFieldsForElem(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, elem_id: u64, counts: *render.Counts, dirty_source_node_ids: []const u64, dirty_generation: u64) void {
            self.applyActiveStreamFieldsForElemOptions(ctx, roc_host, elem_id, counts, dirty_source_node_ids, dirty_generation, true);
        }

        pub fn applyStructuralNodeDescriptorTarget(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, stream: *HostNodeDescriptorStream, targets: HostStructuralPatchTargets) render.Counts {
            if (!self.hasRenderRoot()) @panic("structural DOM patch requested before initial DOM root creation");

            const allocator = Ctx.allocator(ctx);
            const max_elem_id = @max(maxRenderElemId(&self.active_stream), maxRenderElemId(stream));
            const required_child_table_len: usize = @intCast(max_elem_id + 1);
            const child_table_len = required_child_table_len;

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

        pub fn applyNodeDescriptorStream(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, stream: *HostNodeDescriptorStream) render.Counts {
            var counts: render.Counts = .{};
            counts.addHostReset();
            self.resetRenderTree(ctx);

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

        pub fn applyStructuralNodeDescriptorStream(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, stream: *HostNodeDescriptorStream) render.Counts {
            if (!self.hasRenderRoot()) @panic("structural DOM patch requested before initial DOM root creation");

            const allocator = Ctx.allocator(ctx);
            const max_elem_id = @max(maxRenderElemId(&self.active_stream), maxRenderElemId(stream));
            const required_child_table_len: usize = @intCast(max_elem_id + 1);
            const child_table_len = required_child_table_len;

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

        pub fn applyDirtyStructuralSignalsLocally(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, dirty_source_node_ids: []const u64, dirty_generation: u64, changes: []const HostDirtyStructuralSignal) render.Counts {
            const DirtyStructuralOrder = struct {
                engine: *Self,

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

            const dirty_allocator = Ctx.allocator(ctx);
            const ordered_changes = dirty_allocator.dupe(HostDirtyStructuralSignal, changes) catch @panic("out of memory");
            defer dirty_allocator.free(ordered_changes);
            std.mem.sort(HostDirtyStructuralSignal, ordered_changes, DirtyStructuralOrder{ .engine = self }, DirtyStructuralOrder.lessThan);

            var total_counts: render.Counts = .{};
            var applied_any = false;
            const event_count_before = self.active_stream.events.items.len;

            for (ordered_changes) |change| {
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
                            return total_counts;
                        };
                        const existing_replacement_scope_id = self.activeWhenBranchScopeId(site.scope_id, site.ordinal, active_branch) catch @panic("scope id has no host scope descriptor");

                        const target_scopes_snapshot = self.snapshotReplacementTargetScopeSet(ctx, .{ .scope = replaced_scope_id });
                        defer Ctx.allocator(ctx).free(target_scopes_snapshot);
                        if (self.replacementTargetHasNonContiguousDomDescendants(ctx, site.render_insert_index, target_scopes_snapshot)) {
                            total_counts.addAll(self.rerenderActiveRootWithReset(ctx, roc_host, dirty_source_node_ids));
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

        pub fn applyDirtyWhenStructuralSignals(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, dirty_source_node_ids: []const u64, dirty_generation: u64, changes: []const HostDirtyStructuralSignal) render.Counts {
            for (changes) |change| {
                if (change.kind != .when) @panic("non-when structural change reached when-only test helper");
            }
            return self.applyDirtyStructuralSignalsLocally(ctx, roc_host, dirty_source_node_ids, dirty_generation, changes);
        }

        pub fn appendPendingTask(self: *Self, ctx: Ctx.Handle, owner_scope_id: u64, task_token: HostSignalToken, task_name: []const u8, request: []const u8) u64 {
            return effects_runtime.appendPendingTask(Ctx.allocator(ctx), &self.pending_tasks, &self.next_task_request_id, self.roc_host.?, owner_scope_id, task_token, task_name, request);
        }

        pub fn pendingTaskIndexByName(self: *Self, name: []const u8) ?usize {
            return effects_runtime.pendingTaskIndexByName(self.pending_tasks.items, name);
        }

        pub fn removePendingTaskAt(self: *Self, index: usize) HostPendingTask {
            return effects_runtime.removePendingTaskAt(&self.pending_tasks, index);
        }

        pub fn activeTaskRecordByName(self: *Self, name: []const u8) ?*HostSignalRecord {
            return effects_runtime.activeTaskRecordByName(self.active_signal_graph.items, name);
        }

        pub fn activeIntervalRecordByPeriod(self: *Self, period_ms: u64) ?*HostSignalRecord {
            return effects_runtime.activeIntervalRecordByPeriod(self.active_signal_graph.items, period_ms);
        }

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

        pub fn updateEffectSourceCacheSlot(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, cache_slot: *HostSignalCacheSlot, value: HostValue, cap: HostValueCapability) bool {
            switch (cache_slot.*) {
                .absent => {
                    debugPhase(ctx, 301);
                    cache_slot.replace(ctx, roc_host, &self.pending_roc_metrics, value, cap);
                    return true;
                },
                .present => |*cached| {
                    debugPhase(ctx, 310);
                    if (cached.valueEquals(ctx, roc_host, value)) {
                        debugPhase(ctx, 311);
                        cached.dropIncoming(ctx, roc_host, value);
                        self.recordSignalPrune();
                        return false;
                    }
                    debugPhase(ctx, 312);
                    cached.replaceValue(ctx, roc_host, value);
                    return true;
                },
            }
        }

        pub fn updateEffectSourceCache(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, record: *HostSignalRecord, value: HostValue) bool {
            const source = record.effectSource() orelse @panic("effect source update targeted a non-source signal record");
            return self.updateEffectSourceCacheSlot(ctx, roc_host, source.cachedSlot(), value, source.capability());
        }

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

            debugPhase(ctx, 350);
            var counts = self.collectDirtyRenderSinksAndCommands(
                ctx,
                roc_host,
                dirty_source_node_ids,
                stable_changed_record_ids,
                dirty_generation,
                &pending_on_change_commands,
            );

            debugPhase(ctx, 360);
            const dirty_structural_signals = self.collectDirtyStructuralSignals(ctx, roc_host, allocator, dirty_source_node_ids, stable_changed_record_ids, dirty_generation);
            defer allocator.free(dirty_structural_signals);
            if (dirty_structural_signals.len != 0) {
                debugPhase(ctx, 370);
                counts.addAll(self.applyDirtyStructuralSignalsLocally(ctx, roc_host, dirty_source_node_ids, dirty_generation, dirty_structural_signals));
            }
            debugPhase(ctx, 361);
            counts.addAll(self.runPendingOnChangeCommandsDeferringSourceEffects(
                ctx,
                roc_host,
                pending_on_change_commands.items,
                &deferred_location_effect,
                &deferred_storage_effects,
            ));
            debugPhase(ctx, 362);
            counts.addAll(self.flushDeferredSourceEffects(ctx, roc_host, deferred_location_effect, deferred_storage_effects.items));
            debugPhase(ctx, 363);
            return counts;
        }

        pub fn dispatchEffectSourceValue(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, record: *HostSignalRecord, value: HostValue) render.Counts {
            debugPhase(ctx, 300);
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

            debugPhase(ctx, 330);
            const changed_record_ids = self.propagateDirtyActiveSignalRecordIds(ctx, roc_host, dirty_record_ids, &.{}, dirty_generation);
            debugPhase(ctx, 340);
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

        pub fn navigateLocationCommand(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, kind: NavigationKind, location: boundary.LocationSnapshot) render.Counts {
            Ctx.sink(ctx).navigate(kind, location);
            return self.dispatchCurrentLocationSources(ctx, roc_host);
        }

        pub fn setStorageTextCommand(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, payload: anytype) render.Counts {
            const area = storageAreaFromCommand(payload.area);
            const key = payload.key.asSlice();
            Ctx.sink(ctx).setStorageText(area, key, payload.value.asSlice());
            return self.dispatchCurrentStorageSources(ctx, roc_host, area, key);
        }

        pub fn setDocumentTitleCommand(_: *Self, ctx: Ctx.Handle, payload: anytype) render.Counts {
            Ctx.sink(ctx).setDocumentTitle(payload.title.asSlice());
            return .{};
        }

        pub fn removeStorageCommand(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, payload: anytype) render.Counts {
            const area = storageAreaFromCommand(payload.area);
            const key = payload.key.asSlice();
            Ctx.sink(ctx).removeStorage(area, key);
            return self.dispatchCurrentStorageSources(ctx, roc_host, area, key);
        }

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

        pub fn tickIntervalSource(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, period_ms: u64) render.Counts {
            const record = self.activeIntervalRecordByPeriod(period_ms) orelse @panic("tick_interval matched no active interval source");
            return self.tickIntervalRecord(ctx, roc_host, record);
        }

        pub fn tickIntervalSourceByRuntimeToken(self: *Self, ctx: Ctx.Handle, roc_host: *abi.RocHost, token: u64) render.Counts {
            const source_token = self.activeIntervalSourceTokenByRuntimeToken(token) orelse @panic("timer tick referenced an inactive interval token");
            const record = self.activeIntervalRecordByToken(source_token) orelse @panic("timer tick matched no active interval source");
            return self.tickIntervalRecord(ctx, roc_host, record);
        }

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

const VerifyCtxHost = struct {};

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
    pub fn reset(_: VerifySink) void {}
    pub fn appendNode(_: VerifySink, _: u64, _: u64, _: []const u8) void {}
    pub fn ensureNode(_: VerifySink, _: u64, _: []const u8) void {}
    pub fn removeNode(_: VerifySink, _: u64) void {}
    pub fn replaceChildren(_: VerifySink, _: u64, _: []const u64) void {}
    pub fn replaceChildrenForMoves(_: VerifySink, _: u64, _: []const u64) void {}
    pub fn applyTextField(_: VerifySink, _: u64, _: RenderTextField, _: []const u8) void {}
    pub fn applyTextAttr(_: VerifySink, _: u64, _: []const u8, _: []const u8) void {}
    pub fn applyBoolField(_: VerifySink, _: u64, _: RenderBoolField, _: bool) void {}
    pub fn clearTextField(_: VerifySink, _: u64, _: RenderTextField) void {}
    pub fn clearTextAttr(_: VerifySink, _: u64, _: []const u8) void {}
    pub fn clearBoolField(_: VerifySink, _: u64, _: RenderBoolField) void {}
    pub fn bindEvent(_: VerifySink, _: u64, _: render_cache_mod.EventBindingKey, _: HostRequiredEventBinding) void {}
    pub fn clearEvent(_: VerifySink, _: u64, _: render_cache_mod.EventBindingKey) void {}
    pub fn startInterval(_: VerifySink, _: u64, _: u64) void {}
    pub fn cancelInterval(_: VerifySink, _: u64) void {}
    pub fn startTask(_: VerifySink, _: u64, _: []const u8, _: []const u8) void {}
    pub fn cancelTask(_: VerifySink, _: u64) void {}
    pub fn navigate(_: VerifySink, _: NavigationKind, _: boundary.LocationSnapshot) void {}
    pub fn setDocumentTitle(_: VerifySink, _: []const u8) void {}
    pub fn debugAssertNode(_: VerifySink, _: u64, _: bool, _: ?[]const u8, _: ?u64, _: []const u64, _: ?u64, _: ?u64, _: ?u64, _: ?u64, _: ?u64, _: ?u64, _: ?u64) void {}
};

const VerifyCtx = struct {
    pub const Handle = *VerifyCtxHost;
    pub const RegistryOps = hv.RegistryOps();
    pub const Metrics = RuntimeMetrics;
    pub const Sink = VerifySink;

    pub fn zeroMetrics() Metrics {
        return zeroRuntimeMetrics();
    }

    pub fn allocator(_: Handle) std.mem.Allocator {
        return std.heap.page_allocator;
    }

    pub fn cloneHostValue(_: Handle, value: HostValue) HostValue {
        return value;
    }

    pub fn pushHostValueCapabilities(_: Handle, _: []const HostValueCapability) void {}

    pub fn popHostValueCapabilities(_: Handle) void {}

    pub fn stateValueByNodeId(_: Handle, _: u64) HostValue {
        return 0;
    }

    pub fn stateCapability(_: Handle, _: u64) HostValueCapability {
        return undefined;
    }

    pub fn initialLocationPayload(_: Handle, _: *abi.RocHost, _: HostValueCapability) HostValue {
        return 0;
    }

    pub fn initialStoragePayload(_: Handle, _: *abi.RocHost, _: boundary.StorageArea, _: []const u8, _: HostValueCapability) HostValue {
        return 0;
    }

    pub fn sink(_: Handle) Sink {
        return .{};
    }
};

comptime {
    verifyCtx(VerifyCtx);
    std.debug.assert(@sizeOf(NoMetrics) == 0);
    _ = Engine(VerifyCtx);
}
