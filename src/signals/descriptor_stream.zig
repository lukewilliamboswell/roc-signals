//! Decoder and owned snapshot model for Roc UI descriptor streams.

const std = @import("std");
const abi = @import("roc_platform_abi.zig");
const boundary = @import("boundary.zig");
const render = @import("render_commands.zig");
const render_sink = @import("render_sink.zig");
const retained = @import("retained_values.zig");
const roles = @import("callable_roles.zig");
const signal_records = @import("signal_records.zig");
const ids = @import("ids.zig");

pub const NodeId = ids.NodeId;
pub const ElemId = ids.ElemId;
pub const ScopeId = ids.ScopeId;
pub const SiteOrdinal = ids.SiteOrdinal;

/// Errors a stream reservation can raise: the allocator refused (`OutOfMemory`) or an
/// index/count computation exceeded its arithmetic bound (`ResourceLimit`).
pub const ReserveError = std.mem.Allocator.Error || error{ResourceLimit};

pub const TextField = render.TextField;
pub const BoolField = render.BoolField;
pub const EventKind = render.EventKind;
pub const EventPolicy = render.EventPolicy;
pub const EventDeliveryRequest = render_sink.EventDeliveryRequest;
pub const BoundaryPayloadDescriptor = boundary.BoundaryPayloadDescriptor;
pub const HostSignalBinding = signal_records.Binding;
pub const HostSignalCacheSlot = signal_records.CacheSlot;
pub const HostValueCapability = retained.HostValueCapability;
pub const HostTextRead = retained.HostTextRead;
pub const HostBoolRead = retained.HostBoolRead;
pub const HostEventReducer = retained.HostEventReducer;
pub const HostEachOps = retained.HostEachOps;

pub const ScopeSiteKind = enum {
    component,
    state,
    when,
    each,
};

pub const RenderNodeKind = enum {
    element,
    text,
    signal_text,
};

fn asElemId(value: anytype) ElemId {
    return if (@TypeOf(value) == ElemId) value else ElemId.fromRaw(value);
}

fn identityRaw(value: anytype) u64 {
    return switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => value,
        else => value.raw(),
    };
}

pub const RenderNode = struct {
    elem_id: ElemId,
    kind: RenderNodeKind,
};

pub const RenderChildInsertHint = struct {
    parent_elem_id: ElemId,
    insertion_index: usize,
};

pub const ElementDesc = struct {
    elem_id: ElemId,
    parent_elem_id: ElemId,
    scope_id: ScopeId,
    tag: []const u8,
};

pub const TextNodeDesc = struct {
    elem_id: ElemId,
    parent_elem_id: ElemId,
    scope_id: ScopeId,
    value: []const u8,
};

pub const StaticTextAttrDesc = struct {
    elem_id: ElemId,
    field: TextField,
    value: []const u8,
};

pub const StaticCustomTextAttrDesc = struct {
    elem_id: ElemId,
    name: []const u8,
    value: []const u8,
};

pub const StaticCustomBoolAttrDesc = struct {
    elem_id: ElemId,
    name: []const u8,
    value: bool,
};

pub const StaticBoolAttrDesc = struct {
    elem_id: ElemId,
    field: BoolField,
    value: bool,
};

pub const MountDesc = struct {
    scope_id: ScopeId,
    to_cmd: roles.CommandBuilder,
    run_on_mount: bool,

    /// Releases every resource owned by this value and leaves no retained host or Roc ownership behind.
    pub fn deinit(self: MountDesc, roc_host: *abi.RocHost, metrics: anytype) void {
        metrics.bump(.closure_releases, 1);
        abi.decrefErasedCallable(self.to_cmd.toAbi(), roc_host);
    }
};

pub const CleanupDesc = struct {
    scope_id: ScopeId,
    name: []const u8,
};

/// Boxed state initializer shared by `Ui.state` and its references.
pub const BinderToken = retained.HostSignalToken;

/// Binds a state binder token to the node id it resolves to within a scope.
pub const BinderBinding = struct {
    token: BinderToken,
    node_id: NodeId,
};

pub const ScopeSiteDesc = struct {
    node_id: NodeId,
    scope_id: ScopeId,
    ordinal: SiteOrdinal,
    parent_elem_id: ElemId,
    render_insert_index: usize,
    kind: ScopeSiteKind,
    binder_bindings: []BinderBinding,
};

pub const SignalTextNodeDesc = struct {
    elem_id: ElemId,
    parent_elem_id: ElemId,
    scope_id: ScopeId,
    signal: HostSignalBinding,
    read: HostTextRead,
    cached_value: HostSignalCacheSlot = .absent,

    /// Releases every resource owned by this value and leaves no retained host or Roc ownership behind.
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype) void {
        deinitSignalTextFields(&self.signal, &self.cached_value, self.read, allocator, ctx, roc_host, metrics);
    }
};

pub const SignalTextAttrDesc = struct {
    elem_id: ElemId,
    field: TextField,
    signal: HostSignalBinding,
    read: HostTextRead,
    cached_value: HostSignalCacheSlot = .absent,

    /// Releases every resource owned by this value and leaves no retained host or Roc ownership behind.
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype) void {
        deinitSignalTextFields(&self.signal, &self.cached_value, self.read, allocator, ctx, roc_host, metrics);
    }
};

pub const SignalCustomTextAttrDesc = struct {
    elem_id: ElemId,
    name: []const u8,
    signal: HostSignalBinding,
    read: HostTextRead,
    cached_value: HostSignalCacheSlot = .absent,

    /// Releases every resource owned by this value and leaves no retained host or Roc ownership behind.
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype) void {
        allocator.free(self.name);
        deinitSignalTextFields(&self.signal, &self.cached_value, self.read, allocator, ctx, roc_host, metrics);
    }
};

pub const SignalOptionalCustomTextAttrDesc = struct {
    elem_id: ElemId,
    name: []const u8,
    signal: HostSignalBinding,
    present: HostBoolRead,
    read: HostTextRead,
    cached_value: HostSignalCacheSlot = .absent,

    /// Releases every resource owned by this value and leaves no retained host or Roc ownership behind.
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype) void {
        allocator.free(self.name);
        deinitSignalOptionalTextFields(&self.signal, &self.cached_value, self.present, self.read, allocator, ctx, roc_host, metrics);
    }
};

pub const SignalCustomBoolAttrDesc = struct {
    elem_id: ElemId,
    name: []const u8,
    signal: HostSignalBinding,
    read: HostBoolRead,
    cached_value: HostSignalCacheSlot = .absent,

    /// Releases every resource owned by this value and leaves no retained host or Roc ownership behind.
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype) void {
        allocator.free(self.name);
        deinitSignalBoolFields(&self.signal, &self.cached_value, self.read, allocator, ctx, roc_host, metrics);
    }
};

pub const CustomAttrValueKind = enum {
    text,
    bool,
};

pub const CustomAttrKind = enum {
    static_text,
    signal_text,
    signal_text_optional,
    static_bool,
    signal_bool,

    /// Maintains value kind within the indexed descriptor stream used by both hosts.
    pub fn valueKind(self: CustomAttrKind) CustomAttrValueKind {
        return switch (self) {
            .static_text, .signal_text, .signal_text_optional => .text,
            .static_bool, .signal_bool => .bool,
        };
    }
};

pub const CustomAttrRef = struct {
    kind: CustomAttrKind,
    index: usize,
    elem_id: ElemId,
    name: []const u8,

    /// Maintains matches within the indexed descriptor stream used by both hosts.
    pub fn matches(self: CustomAttrRef, elem_id: u64, name: []const u8) bool {
        return self.elem_id.raw() == elem_id and std.mem.eql(u8, self.name, name);
    }
};

const CustomAttrKey = struct {
    elem_id: ElemId,
    name: []const u8,
};

const CustomAttrKeyContext = struct {
    /// Reports whether h is present in maintained state.
    pub fn hash(_: @This(), key: CustomAttrKey) u64 {
        return std.hash.Wyhash.hash(key.elem_id.raw(), key.name);
    }

    /// Compares values through their owning capability rather than inspecting erased bytes.
    pub fn eql(_: @This(), left: CustomAttrKey, right: CustomAttrKey) bool {
        return left.elem_id == right.elem_id and std.mem.eql(u8, left.name, right.name);
    }
};

pub const CustomAttrDescriptorIndex = struct {
    kind: CustomAttrKind,
    index: usize,
};

pub const LifecycleDescriptorKind = enum { on_change, mount, cleanup };

pub const LifecycleDescriptorIndex = struct {
    kind: LifecycleDescriptorKind,
    index: usize,
};

/// Stable descriptor identities owned directly by one explicit runtime scope.
///
/// Element and node ids survive dense descriptor-array swap removal, so this
/// index can select one retiring subtree without scanning any descriptor
/// family. Attribute and event ownership is reached through the element id;
/// state and structural ownership is reached through the node id. Lifecycle
/// descriptors keep their existing specialized per-scope index.
pub const ScopeDescriptorOwnership = struct {
    elem_ids: std.ArrayListUnmanaged(ElemId) = .empty,
    node_ids: std.ArrayListUnmanaged(NodeId) = .empty,

    /// Releases the scope-local identity lists.
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.elem_ids.deinit(allocator);
        self.node_ids.deinit(allocator);
        self.* = .{};
    }
};

const CustomAttrKeySet = std.HashMapUnmanaged(CustomAttrKey, CustomAttrDescriptorIndex, CustomAttrKeyContext, 80);

pub const SignalBoolAttrDesc = struct {
    elem_id: ElemId,
    field: BoolField,
    signal: HostSignalBinding,
    read: HostBoolRead,
    cached_value: HostSignalCacheSlot = .absent,

    /// Releases every resource owned by this value and leaves no retained host or Roc ownership behind.
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype) void {
        deinitSignalBoolFields(&self.signal, &self.cached_value, self.read, allocator, ctx, roc_host, metrics);
    }
};

pub const OnChangeDesc = struct {
    scope_id: ScopeId,
    run_initial: bool,
    run_initial_pending: bool,
    signal: HostSignalBinding,
    to_cmd: roles.CommandBuilder,
    cached_value: HostSignalCacheSlot = .absent,

    /// Releases every resource owned by this value and leaves no retained host or Roc ownership behind.
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype) void {
        self.cached_value.deinit(ctx, roc_host, metrics);
        self.signal.deinit(allocator, ctx, roc_host, metrics);
        metrics.bump(.closure_releases, 1);
        abi.decrefErasedCallable(self.to_cmd.toAbi(), roc_host);
    }
};

pub const NamedEventBinding = struct {
    name: []const u8,
    policy: EventPolicy,
    delivery_request: EventDeliveryRequest = .auto,
};

pub const EventBinding = union(enum) {
    fixed: EventKind,
    named: NamedEventBinding,
};

pub const EventDesc = struct {
    elem_id: ElemId,
    binding: EventBinding,
    delivery_request: EventDeliveryRequest = .auto,
    binder_token: BinderToken,
    target_node_id: NodeId,
    read_binder_token: BinderToken,
    read_node_id: NodeId,
    payload_descriptor: BoundaryPayloadDescriptor,
    payload_reducer: HostEventReducer,
    owns_payload_reducer: bool = true,

    /// Maintains fixed kind within the indexed descriptor stream used by both hosts.
    pub fn fixedKind(self: EventDesc) ?EventKind {
        return switch (self.binding) {
            .fixed => |kind| kind,
            .named => null,
        };
    }

    /// Maintains named within the indexed descriptor stream used by both hosts.
    pub fn named(self: EventDesc) ?NamedEventBinding {
        return switch (self.binding) {
            .fixed => null,
            .named => |binding| binding,
        };
    }

    /// Releases every resource owned by this value and leaves no retained host or Roc ownership behind.
    pub fn deinit(self: EventDesc, allocator: std.mem.Allocator, roc_host: *abi.RocHost, metrics: anytype) void {
        if (self.named()) |binding| allocator.free(binding.name);
        if (self.owns_payload_reducer) releaseHostEventReducer(self.payload_reducer, roc_host, metrics);
    }
};

pub const StateDesc = struct {
    node_id: NodeId,
    initial: roles.Initializer,
    cap: HostValueCapability,

    /// Releases every resource owned by this value and leaves no retained host or Roc ownership behind.
    pub fn deinit(self: StateDesc, roc_host: *abi.RocHost, metrics: anytype) void {
        metrics.bump(.closure_releases, 1);
        abi.decrefErasedCallable(self.initial.toAbi(), roc_host);
        releaseHostValueCapability(self.cap, roc_host, metrics);
    }
};

pub const WhenDesc = struct {
    node_id: NodeId,
    condition: HostSignalBinding,
    ops: retained.HostWhenOps,
    cached_value: HostSignalCacheSlot = .absent,

    /// Releases every resource owned by this value and leaves no retained host or Roc ownership behind.
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype) void {
        self.cached_value.deinit(ctx, roc_host, metrics);
        self.condition.deinit(allocator, ctx, roc_host, metrics);
        retained.releaseHostWhenOps(self.ops, roc_host, metrics);
    }
};

pub const EachDesc = struct {
    node_id: NodeId,
    items: HostSignalBinding,
    ops: HostEachOps,
    cached_value: HostSignalCacheSlot = .absent,

    /// Releases every resource owned by this value and leaves no retained host or Roc ownership behind.
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype) void {
        self.cached_value.deinit(ctx, roc_host, metrics);
        self.items.deinit(allocator, ctx, roc_host, metrics);
        releaseHostEachOps(self.ops, roc_host, metrics);
    }
};

pub const HostSignalToken = signal_records.HostSignalToken;
const SignalRecord = signal_records.Record;

const retainHostTextRead = retained.retainHostTextRead;
const releaseHostTextRead = retained.releaseHostTextRead;
const retainHostBoolRead = retained.retainHostBoolRead;
const releaseHostBoolRead = retained.releaseHostBoolRead;
const retainHostEventReducer = retained.retainHostEventReducer;
const releaseHostEventReducer = retained.releaseHostEventReducer;
const retainHostValueCapability = retained.retainHostValueCapability;
const releaseHostValueCapability = retained.releaseHostValueCapability;
const retainHostEachOps = retained.retainHostEachOps;
const releaseHostEachOps = retained.releaseHostEachOps;

fn deinitSignalTextFields(signal: *HostSignalBinding, cache_slot: *HostSignalCacheSlot, read: HostTextRead, allocator: std.mem.Allocator, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype) void {
    cache_slot.deinit(ctx, roc_host, metrics);
    signal.deinit(allocator, ctx, roc_host, metrics);
    releaseHostTextRead(read, roc_host, metrics);
}

fn deinitSignalOptionalTextFields(signal: *HostSignalBinding, cache_slot: *HostSignalCacheSlot, present: HostBoolRead, read: HostTextRead, allocator: std.mem.Allocator, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype) void {
    cache_slot.deinit(ctx, roc_host, metrics);
    signal.deinit(allocator, ctx, roc_host, metrics);
    releaseHostBoolRead(present, roc_host, metrics);
    releaseHostTextRead(read, roc_host, metrics);
}

fn deinitSignalBoolFields(signal: *HostSignalBinding, cache_slot: *HostSignalCacheSlot, read: HostBoolRead, allocator: std.mem.Allocator, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype) void {
    cache_slot.deinit(ctx, roc_host, metrics);
    signal.deinit(allocator, ctx, roc_host, metrics);
    releaseHostBoolRead(read, roc_host, metrics);
}

fn rollbackSignalTextAppend(signal: HostSignalBinding, read: HostTextRead, allocator: std.mem.Allocator, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype) void {
    var owned_signal = signal;
    var cache_slot: HostSignalCacheSlot = .absent;
    deinitSignalTextFields(&owned_signal, &cache_slot, read, allocator, ctx, roc_host, metrics);
}

fn rollbackSignalOptionalTextAppend(signal: HostSignalBinding, present: HostBoolRead, read: HostTextRead, allocator: std.mem.Allocator, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype) void {
    var owned_signal = signal;
    var cache_slot: HostSignalCacheSlot = .absent;
    deinitSignalOptionalTextFields(&owned_signal, &cache_slot, present, read, allocator, ctx, roc_host, metrics);
}

fn rollbackSignalBoolAppend(signal: HostSignalBinding, read: HostBoolRead, allocator: std.mem.Allocator, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype) void {
    var owned_signal = signal;
    var cache_slot: HostSignalCacheSlot = .absent;
    deinitSignalBoolFields(&owned_signal, &cache_slot, read, allocator, ctx, roc_host, metrics);
}

const StreamRenderNode = RenderNode;
const StreamElementDesc = ElementDesc;
const StreamTextNodeDesc = TextNodeDesc;
const StreamSignalTextNodeDesc = SignalTextNodeDesc;

/// Maintains custom attr refs within the indexed descriptor stream used by both hosts.
pub fn CustomAttrRefs(comptime StreamType: type) type {
    return struct {
        stream: *const StreamType,
        kind: CustomAttrKind = .static_text,
        index: usize = 0,

        /// Returns next from maintained local structure without a full-tree scan.
        pub fn next(self: *@This()) ?CustomAttrRef {
            while (true) {
                switch (self.kind) {
                    .static_text => {
                        if (self.index < self.stream.static_custom_text_attrs.items.len) {
                            const index = self.index;
                            const desc = self.stream.static_custom_text_attrs.items[self.index];
                            self.index += 1;
                            return .{ .kind = .static_text, .index = index, .elem_id = asElemId(desc.elem_id), .name = desc.name };
                        }
                        self.kind = .signal_text;
                        self.index = 0;
                    },
                    .signal_text => {
                        if (self.index < self.stream.signal_custom_text_attrs.items.len) {
                            const index = self.index;
                            const desc = self.stream.signal_custom_text_attrs.items[self.index];
                            self.index += 1;
                            return .{ .kind = .signal_text, .index = index, .elem_id = asElemId(desc.elem_id), .name = desc.name };
                        }
                        self.kind = .signal_text_optional;
                        self.index = 0;
                    },
                    .signal_text_optional => {
                        if (self.index < self.stream.signal_optional_custom_text_attrs.items.len) {
                            const index = self.index;
                            const desc = self.stream.signal_optional_custom_text_attrs.items[self.index];
                            self.index += 1;
                            return .{ .kind = .signal_text_optional, .index = index, .elem_id = asElemId(desc.elem_id), .name = desc.name };
                        }
                        self.kind = .static_bool;
                        self.index = 0;
                    },
                    .static_bool => {
                        if (self.index < self.stream.static_custom_bool_attrs.items.len) {
                            const index = self.index;
                            const desc = self.stream.static_custom_bool_attrs.items[self.index];
                            self.index += 1;
                            return .{ .kind = .static_bool, .index = index, .elem_id = asElemId(desc.elem_id), .name = desc.name };
                        }
                        self.kind = .signal_bool;
                        self.index = 0;
                    },
                    .signal_bool => {
                        if (self.index < self.stream.signal_custom_bool_attrs.items.len) {
                            const index = self.index;
                            const desc = self.stream.signal_custom_bool_attrs.items[self.index];
                            self.index += 1;
                            return .{ .kind = .signal_bool, .index = index, .elem_id = asElemId(desc.elem_id), .name = desc.name };
                        }
                        return null;
                    },
                }
            }
        }
    };
}

/// Maintains custom attr refs within the indexed descriptor stream used by both hosts.
pub fn customAttrRefs(comptime StreamType: type, stream: *const StreamType) CustomAttrRefs(StreamType) {
    return .{ .stream = stream };
}

// Stream methods keep the public method names while delegating to the generic
// helpers below; these aliases avoid method/helper name collisions.
const appendCleanupImpl = appendCleanup;
const appendElementImpl = appendElement;
const appendRenderChildImpl = appendRenderChild;
const appendScopeSiteImpl = appendScopeSite;
const appendScopeSiteAtImpl = appendScopeSiteAt;
const appendStaticBoolAttrImpl = appendStaticBoolAttr;
const appendStaticCustomBoolAttrImpl = appendStaticCustomBoolAttr;
const appendStaticCustomTextAttrImpl = appendStaticCustomTextAttr;
const appendStaticTextAttrImpl = appendStaticTextAttr;
const appendTextNodeImpl = appendTextNode;
const childInsertionIndexForRenderIndexImpl = childInsertionIndexForRenderIndex;
const clearEachIndexImpl = clearEachIndex;
const clearElementIndexImpl = clearElementIndex;
const clearEventIndexImpl = clearEventIndex;
const clearNamedEventIndexImpl = clearNamedEventIndex;
const clearRenderChildrenImpl = clearRenderChildren;
const clearRenderNodeIndexImpl = clearRenderNodeIndex;
const clearScopeSiteIndexImpl = clearScopeSiteIndex;
const clearSignalBoolAttrIndexImpl = clearSignalBoolAttrIndex;
const clearSignalTextAttrIndexImpl = clearSignalTextAttrIndex;
const clearSignalTextNodeIndexImpl = clearSignalTextNodeIndex;
const clearStateIndexImpl = clearStateIndex;
const clearStaticBoolAttrIndexImpl = clearStaticBoolAttrIndex;
const clearStaticTextAttrIndexImpl = clearStaticTextAttrIndex;
const clearTextNodeIndexImpl = clearTextNodeIndex;
const clearWhenIndexImpl = clearWhenIndex;
const customTextAttrDescriptorExistsImpl = customTextAttrDescriptorExists;
const elemDescriptorIndexImpl = elemDescriptorIndex;
const ensureElemDescriptorIndexImpl = ensureElemDescriptorIndex;
const ensureFirstRenderChildSlotImpl = ensureFirstRenderChildSlot;
const ensureLastRenderChildSlotImpl = ensureLastRenderChildSlot;
const ensureNextRenderSiblingSlotImpl = ensureNextRenderSiblingSlot;
const ensurePreviousRenderSiblingSlotImpl = ensurePreviousRenderSiblingSlot;
const ensureNodeDescriptorIndexImpl = ensureNodeDescriptorIndex;
const ensureRenderMetadataImpl = ensureRenderMetadata;
const firstRenderChildImpl = firstRenderChild;
const insertRenderChildrenImpl = insertRenderChildren;
const lastRenderChildImpl = lastRenderChild;
const nextRenderSiblingImpl = nextRenderSibling;
const previousRenderSiblingImpl = previousRenderSibling;
const namedEventIndicesImpl = namedEventIndices;
const nodeDescriptorIndexImpl = nodeDescriptorIndex;
const recordEachIndexImpl = recordEachIndex;
const recordElementIndexImpl = recordElementIndex;
const recordEventIndexImpl = recordEventIndex;
const recordNamedEventIndexImpl = recordNamedEventIndex;
const recordRenderNodeIndexImpl = recordRenderNodeIndex;
const recordScopeSiteIndexImpl = recordScopeSiteIndex;
const recordSignalBoolAttrIndexImpl = recordSignalBoolAttrIndex;
const recordSignalTextAttrIndexImpl = recordSignalTextAttrIndex;
const recordSignalTextNodeIndexImpl = recordSignalTextNodeIndex;
const recordStateIndexImpl = recordStateIndex;
const recordStaticBoolAttrIndexImpl = recordStaticBoolAttrIndex;
const recordStaticTextAttrIndexImpl = recordStaticTextAttrIndex;
const recordTextNodeIndexImpl = recordTextNodeIndex;
const recordWhenIndexImpl = recordWhenIndex;
const refreshRenderIndexesFromImpl = refreshRenderIndexesFrom;
const refreshRenderIndexesInRangeImpl = refreshRenderIndexesInRange;
const removeRenderChildImpl = removeRenderChild;
const moveRenderSiblingRangeBeforeImpl = moveRenderSiblingRangeBefore;
const removeRenderMetadataIfEmptyImpl = removeRenderMetadataIfEmpty;
const renderNodeIndexImpl = renderNodeIndex;
const replaceRenderChildrenIndexImpl = replaceRenderChildrenIndex;
const updateEachIndexImpl = updateEachIndex;
const updateElementIndexImpl = updateElementIndex;
const updateEventIndexImpl = updateEventIndex;
const updateNamedEventIndexImpl = updateNamedEventIndex;
const updateRenderNodeIndexImpl = updateRenderNodeIndex;
const updateScopeSiteIndexImpl = updateScopeSiteIndex;
const updateSignalBoolAttrIndexImpl = updateSignalBoolAttrIndex;
const updateSignalTextAttrIndexImpl = updateSignalTextAttrIndex;
const updateSignalTextNodeIndexImpl = updateSignalTextNodeIndex;
const updateStateIndexImpl = updateStateIndex;
const updateStaticBoolAttrIndexImpl = updateStaticBoolAttrIndex;
const updateStaticTextAttrIndexImpl = updateStaticTextAttrIndex;
const updateTextNodeIndexImpl = updateTextNodeIndex;
const updateWhenIndexImpl = updateWhenIndex;

pub const Stream = struct {
    pub const RenderNode = StreamRenderNode;
    pub const ElementDesc = StreamElementDesc;
    pub const TextNodeDesc = StreamTextNodeDesc;
    pub const SignalTextNodeDesc = StreamSignalTextNodeDesc;

    render_nodes: std.ArrayListUnmanaged(StreamRenderNode) = .empty,
    elements: std.ArrayListUnmanaged(StreamElementDesc) = .empty,
    text_nodes: std.ArrayListUnmanaged(StreamTextNodeDesc) = .empty,
    signal_text_nodes: std.ArrayListUnmanaged(StreamSignalTextNodeDesc) = .empty,
    static_text_attrs: std.ArrayListUnmanaged(StaticTextAttrDesc) = .empty,
    signal_text_attrs: std.ArrayListUnmanaged(SignalTextAttrDesc) = .empty,
    static_custom_text_attrs: std.ArrayListUnmanaged(StaticCustomTextAttrDesc) = .empty,
    signal_custom_text_attrs: std.ArrayListUnmanaged(SignalCustomTextAttrDesc) = .empty,
    signal_optional_custom_text_attrs: std.ArrayListUnmanaged(SignalOptionalCustomTextAttrDesc) = .empty,
    static_custom_bool_attrs: std.ArrayListUnmanaged(StaticCustomBoolAttrDesc) = .empty,
    signal_custom_bool_attrs: std.ArrayListUnmanaged(SignalCustomBoolAttrDesc) = .empty,
    static_bool_attrs: std.ArrayListUnmanaged(StaticBoolAttrDesc) = .empty,
    signal_bool_attrs: std.ArrayListUnmanaged(SignalBoolAttrDesc) = .empty,
    on_changes: std.ArrayListUnmanaged(OnChangeDesc) = .empty,
    mounts: std.ArrayListUnmanaged(MountDesc) = .empty,
    cleanups: std.ArrayListUnmanaged(CleanupDesc) = .empty,
    events: std.ArrayListUnmanaged(EventDesc) = .empty,
    scope_sites: std.ArrayListUnmanaged(ScopeSiteDesc) = .empty,
    states: std.ArrayListUnmanaged(StateDesc) = .empty,
    whens: std.ArrayListUnmanaged(WhenDesc) = .empty,
    eaches: std.ArrayListUnmanaged(EachDesc) = .empty,
    signal_records_by_token: std.AutoHashMapUnmanaged(HostSignalToken, *SignalRecord) = .{},
    signal_record_descriptor_uses_by_token: std.AutoHashMapUnmanaged(HostSignalToken, usize) = .{},
    custom_attr_keys: CustomAttrKeySet = .empty,
    custom_attr_indices_by_elem_id: std.ArrayListUnmanaged(std.ArrayListUnmanaged(CustomAttrDescriptorIndex)) = .empty,
    lifecycle_indices_by_scope_id: std.ArrayListUnmanaged(std.ArrayListUnmanaged(LifecycleDescriptorIndex)) = .empty,
    scope_descriptor_ownership: std.ArrayListUnmanaged(ScopeDescriptorOwnership) = .empty,
    custom_attr_index_active: bool = false,
    render_metadata_by_elem_id: std.AutoHashMapUnmanaged(u64, RenderElemIndex) = .{},
    named_event_indices_by_elem_id: std.ArrayListUnmanaged(std.ArrayListUnmanaged(usize)) = .empty,
    descriptor_indexes_by_elem_id: std.ArrayListUnmanaged(ElemDescriptorIndex) = .empty,
    descriptor_indexes_by_node_id: std.ArrayListUnmanaged(NodeDescriptorIndex) = .empty,
    next_elem_id: u64 = 1,

    /// Reserves every outer destination touched when moving a materialized
    /// replacement stream into this stream. Logical lengths remain unchanged.
    pub fn reserveMovedStreamPublication(self: *Stream, allocator: std.mem.Allocator, replacement: *const Stream) ReserveError!void {
        try self.render_nodes.ensureUnusedCapacity(allocator, replacement.render_nodes.items.len);
        try self.elements.ensureUnusedCapacity(allocator, replacement.elements.items.len);
        try self.text_nodes.ensureUnusedCapacity(allocator, replacement.text_nodes.items.len);
        try self.signal_text_nodes.ensureUnusedCapacity(allocator, replacement.signal_text_nodes.items.len);
        try self.static_text_attrs.ensureUnusedCapacity(allocator, replacement.static_text_attrs.items.len);
        try self.signal_text_attrs.ensureUnusedCapacity(allocator, replacement.signal_text_attrs.items.len);
        try self.static_custom_text_attrs.ensureUnusedCapacity(allocator, replacement.static_custom_text_attrs.items.len);
        try self.signal_custom_text_attrs.ensureUnusedCapacity(allocator, replacement.signal_custom_text_attrs.items.len);
        try self.signal_optional_custom_text_attrs.ensureUnusedCapacity(allocator, replacement.signal_optional_custom_text_attrs.items.len);
        try self.static_custom_bool_attrs.ensureUnusedCapacity(allocator, replacement.static_custom_bool_attrs.items.len);
        try self.signal_custom_bool_attrs.ensureUnusedCapacity(allocator, replacement.signal_custom_bool_attrs.items.len);
        try self.static_bool_attrs.ensureUnusedCapacity(allocator, replacement.static_bool_attrs.items.len);
        try self.signal_bool_attrs.ensureUnusedCapacity(allocator, replacement.signal_bool_attrs.items.len);
        try self.on_changes.ensureUnusedCapacity(allocator, replacement.on_changes.items.len);
        try self.mounts.ensureUnusedCapacity(allocator, replacement.mounts.items.len);
        try self.cleanups.ensureUnusedCapacity(allocator, replacement.cleanups.items.len);
        try self.events.ensureUnusedCapacity(allocator, replacement.events.items.len);
        try self.scope_sites.ensureUnusedCapacity(allocator, replacement.scope_sites.items.len);
        try self.states.ensureUnusedCapacity(allocator, replacement.states.items.len);
        try self.whens.ensureUnusedCapacity(allocator, replacement.whens.items.len);
        try self.eaches.ensureUnusedCapacity(allocator, replacement.eaches.items.len);
        try self.signal_records_by_token.ensureUnusedCapacity(allocator, @intCast(replacement.signal_records_by_token.count()));
        try self.signal_record_descriptor_uses_by_token.ensureUnusedCapacity(allocator, @intCast(replacement.signal_record_descriptor_uses_by_token.count()));
        var custom_attrs = std.math.add(usize, replacement.static_custom_text_attrs.items.len, replacement.signal_custom_text_attrs.items.len) catch return error.ResourceLimit;
        custom_attrs = std.math.add(usize, custom_attrs, replacement.signal_optional_custom_text_attrs.items.len) catch return error.ResourceLimit;
        custom_attrs = std.math.add(usize, custom_attrs, replacement.static_custom_bool_attrs.items.len) catch return error.ResourceLimit;
        custom_attrs = std.math.add(usize, custom_attrs, replacement.signal_custom_bool_attrs.items.len) catch return error.ResourceLimit;
        try self.custom_attr_keys.ensureUnusedCapacity(allocator, @intCast(custom_attrs));
        for (replacement.custom_attr_indices_by_elem_id.items, 0..) |indexes, elem_id| {
            if (indexes.items.len != 0) try self.reservePreparedCustomAttrElem(allocator, elem_id, indexes.items.len);
        }
        for (replacement.lifecycle_indices_by_scope_id.items, 0..) |indexes, scope_id| {
            if (indexes.items.len != 0) try self.reserveLifecycleScope(allocator, ScopeId.fromIndex(scope_id), indexes.items.len);
        }
        for (replacement.scope_descriptor_ownership.items, 0..) |ownership, scope_id| {
            if (ownership.elem_ids.items.len == 0 and ownership.node_ids.items.len == 0) continue;
            try self.reserveScopeDescriptorOwnership(
                allocator,
                ScopeId.fromIndex(scope_id),
                ownership.elem_ids.items.len,
                ownership.node_ids.items.len,
            );
        }
        try self.render_metadata_by_elem_id.ensureUnusedCapacity(allocator, @intCast(replacement.render_metadata_by_elem_id.count()));

        var highest_elem_id: usize = 0;
        for (replacement.render_nodes.items) |node| highest_elem_id = @max(highest_elem_id, node.elem_id.index());
        const elem_index_len = std.math.add(usize, highest_elem_id, 1) catch return error.ResourceLimit;
        try self.descriptor_indexes_by_elem_id.ensureTotalCapacity(allocator, elem_index_len);
        try self.named_event_indices_by_elem_id.ensureTotalCapacity(allocator, elem_index_len);

        var highest_node_id: usize = 0;
        for (replacement.scope_sites.items) |site| highest_node_id = @max(highest_node_id, site.node_id.index());
        const node_index_len = if (replacement.scope_sites.items.len == 0) self.descriptor_indexes_by_node_id.items.len else std.math.add(usize, highest_node_id, 1) catch return error.ResourceLimit;
        try self.descriptor_indexes_by_node_id.ensureTotalCapacity(allocator, node_index_len);

        for (replacement.named_event_indices_by_elem_id.items, 0..) |replacement_indexes, elem_id| {
            if (replacement_indexes.items.len == 0 or elem_id >= self.named_event_indices_by_elem_id.items.len) continue;
            try self.named_event_indices_by_elem_id.items[elem_id].ensureUnusedCapacity(allocator, replacement_indexes.items.len);
        }
    }

    /// Reserves ownership storage for descriptors displaced by a prepared
    /// structural replacement. Publication may then move, rather than free,
    /// every removed payload while faults are armed.
    pub fn reserveRetiredStaticPublication(
        self: *Stream,
        allocator: std.mem.Allocator,
        element_count: usize,
        text_count: usize,
        static_text_count: usize,
        static_bool_count: usize,
        signal_text_node_count: usize,
        signal_text_count: usize,
        signal_bool_count: usize,
        signal_record_count: usize,
        event_count: usize,
        removed_elem_ids: []const u64,
        source: *const Stream,
        scope_site_indexes: []const usize,
        state_count: usize,
        when_count: usize,
        each_count: usize,
    ) ReserveError!void {
        try self.render_nodes.ensureUnusedCapacity(allocator, removed_elem_ids.len);
        try self.elements.ensureUnusedCapacity(allocator, element_count);
        try self.text_nodes.ensureUnusedCapacity(allocator, text_count);
        try self.static_text_attrs.ensureUnusedCapacity(allocator, static_text_count);
        try self.static_bool_attrs.ensureUnusedCapacity(allocator, static_bool_count);
        try self.signal_text_nodes.ensureUnusedCapacity(allocator, signal_text_node_count);
        try self.signal_text_attrs.ensureUnusedCapacity(allocator, signal_text_count);
        try self.signal_bool_attrs.ensureUnusedCapacity(allocator, signal_bool_count);
        try self.reservePreparedSignalRecordPublication(allocator, signal_record_count);
        try self.events.ensureUnusedCapacity(allocator, event_count);
        var highest_elem_id: usize = 0;
        for (removed_elem_ids) |elem_id| highest_elem_id = @max(highest_elem_id, std.math.cast(usize, elem_id) orelse return error.ResourceLimit);
        const index_len = if (removed_elem_ids.len == 0) 0 else std.math.add(usize, highest_elem_id, 1) catch return error.ResourceLimit;
        try self.descriptor_indexes_by_elem_id.ensureTotalCapacity(allocator, index_len);
        try self.named_event_indices_by_elem_id.ensureTotalCapacity(allocator, index_len);
        while (self.descriptor_indexes_by_elem_id.items.len < index_len) self.descriptor_indexes_by_elem_id.appendAssumeCapacity(.{});
        while (self.named_event_indices_by_elem_id.items.len < index_len) self.named_event_indices_by_elem_id.appendAssumeCapacity(.empty);
        for (removed_elem_ids) |elem_id| {
            try self.named_event_indices_by_elem_id.items[@intCast(elem_id)].ensureUnusedCapacity(allocator, source.namedEventIndices(ElemId.fromRaw(elem_id)).len);
        }
        try self.scope_sites.ensureUnusedCapacity(allocator, scope_site_indexes.len);
        try self.states.ensureUnusedCapacity(allocator, state_count);
        try self.whens.ensureUnusedCapacity(allocator, when_count);
        try self.eaches.ensureUnusedCapacity(allocator, each_count);
        var highest_node_id: usize = 0;
        for (scope_site_indexes) |index| highest_node_id = @max(highest_node_id, source.scope_sites.items[index].node_id.index());
        const node_index_len = if (scope_site_indexes.len == 0) 0 else std.math.add(usize, highest_node_id, 1) catch return error.ResourceLimit;
        try self.descriptor_indexes_by_node_id.ensureTotalCapacity(allocator, node_index_len);
        while (self.descriptor_indexes_by_node_id.items.len < node_index_len) self.descriptor_indexes_by_node_id.appendAssumeCapacity(.{});
    }

    /// Reserves ownership and index storage for custom descriptors retired by a
    /// structural transaction. Exact indexes come from the maintained per-element index.
    pub fn reserveRetiredCustomPublication(
        self: *Stream,
        allocator: std.mem.Allocator,
        source: *const Stream,
        removed_elem_ids: []const u64,
        static_text_count: usize,
        signal_text_count: usize,
        optional_text_count: usize,
        static_bool_count: usize,
        signal_bool_count: usize,
    ) ReserveError!void {
        try self.static_custom_text_attrs.ensureUnusedCapacity(allocator, static_text_count);
        try self.signal_custom_text_attrs.ensureUnusedCapacity(allocator, signal_text_count);
        try self.signal_optional_custom_text_attrs.ensureUnusedCapacity(allocator, optional_text_count);
        try self.static_custom_bool_attrs.ensureUnusedCapacity(allocator, static_bool_count);
        try self.signal_custom_bool_attrs.ensureUnusedCapacity(allocator, signal_bool_count);
        const signal_count = std.math.add(usize, signal_text_count, optional_text_count) catch return error.ResourceLimit;
        const all_signal_count = std.math.add(usize, signal_count, signal_bool_count) catch return error.ResourceLimit;
        try self.reservePreparedSignalRecordPublication(allocator, all_signal_count);
        const total_text = std.math.add(usize, static_text_count, signal_text_count) catch return error.ResourceLimit;
        const total_optional = std.math.add(usize, total_text, optional_text_count) catch return error.ResourceLimit;
        const total_bool = std.math.add(usize, total_optional, static_bool_count) catch return error.ResourceLimit;
        const total = std.math.add(usize, total_bool, signal_bool_count) catch return error.ResourceLimit;
        try self.custom_attr_keys.ensureUnusedCapacity(allocator, std.math.cast(u32, total) orelse return error.ResourceLimit);
        for (removed_elem_ids) |elem_id| {
            try self.reservePreparedCustomAttrElem(allocator, elem_id, source.customAttrIndices(ElemId.fromRaw(elem_id)).len);
        }
        self.custom_attr_index_active = true;
    }

    /// Moves custom descriptor families and repairs both ownership indexes without allocation.
    pub fn commitCustomDescriptorReplacementAssumeCapacity(
        self: *Stream,
        replacement: *Stream,
        retired: *Stream,
        static_text_indexes: []const usize,
        signal_text_indexes: []const usize,
        optional_text_indexes: []const usize,
        static_bool_indexes: []const usize,
        signal_bool_indexes: []const usize,
    ) void {
        self.retireStaticCustomTextAssumeCapacity(retired, static_text_indexes);
        self.retireSignalCustomTextAssumeCapacity(retired, signal_text_indexes);
        self.retireSignalOptionalCustomTextAssumeCapacity(retired, optional_text_indexes);
        self.retireStaticCustomBoolAssumeCapacity(retired, static_bool_indexes);
        self.retireSignalCustomBoolAssumeCapacity(retired, signal_bool_indexes);

        for (replacement.static_custom_text_attrs.items) |desc| {
            const index = self.static_custom_text_attrs.items.len;
            self.static_custom_text_attrs.appendAssumeCapacity(desc);
            self.recordPreparedCustomAttrIndex(desc.elem_id, desc.name, .{ .kind = .static_text, .index = index });
        }
        replacement.static_custom_text_attrs.items.len = 0;
        for (replacement.signal_custom_text_attrs.items) |desc| {
            replacement.forgetSignalRecordTree(desc.signal.record);
            self.rememberSignalRecordTreeAssumeCapacity(desc.signal.record);
            const index = self.signal_custom_text_attrs.items.len;
            self.signal_custom_text_attrs.appendAssumeCapacity(desc);
            self.recordPreparedCustomAttrIndex(desc.elem_id, desc.name, .{ .kind = .signal_text, .index = index });
        }
        replacement.signal_custom_text_attrs.items.len = 0;
        for (replacement.signal_optional_custom_text_attrs.items) |desc| {
            replacement.forgetSignalRecordTree(desc.signal.record);
            self.rememberSignalRecordTreeAssumeCapacity(desc.signal.record);
            const index = self.signal_optional_custom_text_attrs.items.len;
            self.signal_optional_custom_text_attrs.appendAssumeCapacity(desc);
            self.recordPreparedCustomAttrIndex(desc.elem_id, desc.name, .{ .kind = .signal_text_optional, .index = index });
        }
        replacement.signal_optional_custom_text_attrs.items.len = 0;
        for (replacement.static_custom_bool_attrs.items) |desc| {
            const index = self.static_custom_bool_attrs.items.len;
            self.static_custom_bool_attrs.appendAssumeCapacity(desc);
            self.recordPreparedCustomAttrIndex(desc.elem_id, desc.name, .{ .kind = .static_bool, .index = index });
        }
        replacement.static_custom_bool_attrs.items.len = 0;
        for (replacement.signal_custom_bool_attrs.items) |desc| {
            replacement.forgetSignalRecordTree(desc.signal.record);
            self.rememberSignalRecordTreeAssumeCapacity(desc.signal.record);
            const index = self.signal_custom_bool_attrs.items.len;
            self.signal_custom_bool_attrs.appendAssumeCapacity(desc);
            self.recordPreparedCustomAttrIndex(desc.elem_id, desc.name, .{ .kind = .signal_bool, .index = index });
        }
        replacement.signal_custom_bool_attrs.items.len = 0;
    }

    /// Reserves ownership for lifecycle descriptors retired by a structural transaction.
    pub fn reserveRetiredLifecyclePublication(self: *Stream, allocator: std.mem.Allocator, source: *const Stream, target_scope_ids: []const ScopeId, on_change_count: usize, mount_count: usize, cleanup_count: usize) ReserveError!void {
        try self.on_changes.ensureUnusedCapacity(allocator, on_change_count);
        try self.mounts.ensureUnusedCapacity(allocator, mount_count);
        try self.cleanups.ensureUnusedCapacity(allocator, cleanup_count);
        try self.reservePreparedSignalRecordPublication(allocator, on_change_count);
        for (target_scope_ids) |scope_id| try self.reserveLifecycleScope(allocator, scope_id, source.lifecycleIndices(scope_id).len);
    }

    /// Retires and publishes lifecycle descriptor ownership without allocation.
    pub fn commitLifecycleReplacementAssumeCapacity(self: *Stream, replacement: *Stream, retired: *Stream, on_change_indexes: []const usize, mount_indexes: []const usize, cleanup_indexes: []const usize) void {
        for (on_change_indexes) |index| {
            const removed = self.on_changes.swapRemove(index);
            self.removeLifecycleIndex(removed.scope_id.raw(), .{ .kind = .on_change, .index = index });
            self.forgetSignalRecordTree(removed.signal.record);
            retired.rememberSignalRecordTreeAssumeCapacity(removed.signal.record);
            const retired_index = retired.on_changes.items.len;
            retired.on_changes.appendAssumeCapacity(removed);
            retired.recordLifecycleAssumeCapacity(removed.scope_id, .{ .kind = .on_change, .index = retired_index });
            if (index < self.on_changes.items.len) {
                const moved = self.on_changes.items[index];
                self.updateLifecycleIndex(moved.scope_id.raw(), .on_change, self.on_changes.items.len, index);
            }
        }
        for (mount_indexes) |index| {
            const removed = self.mounts.swapRemove(index);
            self.removeLifecycleIndex(removed.scope_id.raw(), .{ .kind = .mount, .index = index });
            const retired_index = retired.mounts.items.len;
            retired.mounts.appendAssumeCapacity(removed);
            retired.recordLifecycleAssumeCapacity(removed.scope_id, .{ .kind = .mount, .index = retired_index });
            if (index < self.mounts.items.len) self.updateLifecycleIndex(self.mounts.items[index].scope_id.raw(), .mount, self.mounts.items.len, index);
        }
        for (cleanup_indexes) |index| {
            const removed = self.cleanups.swapRemove(index);
            self.removeLifecycleIndex(removed.scope_id.raw(), .{ .kind = .cleanup, .index = index });
            const retired_index = retired.cleanups.items.len;
            retired.cleanups.appendAssumeCapacity(removed);
            retired.recordLifecycleAssumeCapacity(removed.scope_id, .{ .kind = .cleanup, .index = retired_index });
            if (index < self.cleanups.items.len) self.updateLifecycleIndex(self.cleanups.items[index].scope_id.raw(), .cleanup, self.cleanups.items.len, index);
        }
        for (replacement.on_changes.items) |desc| {
            replacement.forgetSignalRecordTree(desc.signal.record);
            self.rememberSignalRecordTreeAssumeCapacity(desc.signal.record);
            const index = self.on_changes.items.len;
            self.on_changes.appendAssumeCapacity(desc);
            self.recordLifecycleAssumeCapacity(desc.scope_id, .{ .kind = .on_change, .index = index });
        }
        replacement.on_changes.items.len = 0;
        for (replacement.mounts.items) |desc| {
            const index = self.mounts.items.len;
            self.mounts.appendAssumeCapacity(desc);
            self.recordLifecycleAssumeCapacity(desc.scope_id, .{ .kind = .mount, .index = index });
        }
        replacement.mounts.items.len = 0;
        for (replacement.cleanups.items) |desc| {
            const index = self.cleanups.items.len;
            self.cleanups.appendAssumeCapacity(desc);
            self.recordLifecycleAssumeCapacity(desc.scope_id, .{ .kind = .cleanup, .index = index });
        }
        replacement.cleanups.items.len = 0;
    }

    /// Moves the element/text/fixed-static descriptor families according to a
    /// fully prepared removal plan. All destination and index capacity must be
    /// reserved before this allocation-free publication boundary.
    pub fn commitStaticDescriptorReplacementAssumeCapacity(
        self: *Stream,
        replacement: *Stream,
        retired: *Stream,
        element_indexes: []const usize,
        text_indexes: []const usize,
        static_text_indexes: []const usize,
        static_bool_indexes: []const usize,
        signal_text_node_indexes: []const usize,
        signal_text_indexes: []const usize,
        signal_bool_indexes: []const usize,
        event_indexes: []const usize,
        scope_site_indexes: []const usize,
        state_indexes: []const usize,
        when_indexes: []const usize,
        each_indexes: []const usize,
    ) void {
        for (element_indexes) |index| {
            const removed = self.elements.swapRemove(index);
            self.forgetScopeElem(removed.scope_id, removed.elem_id);
            self.clearElementIndex(removed.elem_id.raw(), index);
            retired.elements.appendAssumeCapacity(removed);
            if (index < self.elements.items.len) self.updateElementIndex(self.elements.items[index].elem_id.raw(), index);
        }
        for (text_indexes) |index| {
            const removed = self.text_nodes.swapRemove(index);
            self.forgetScopeElem(removed.scope_id, removed.elem_id);
            self.clearTextNodeIndex(removed.elem_id.raw(), index);
            retired.text_nodes.appendAssumeCapacity(removed);
            if (index < self.text_nodes.items.len) self.updateTextNodeIndex(self.text_nodes.items[index].elem_id.raw(), index);
        }
        for (static_text_indexes) |index| {
            const removed = self.static_text_attrs.swapRemove(index);
            self.clearStaticTextAttrIndex(removed.elem_id.raw(), removed.field, index);
            retired.static_text_attrs.appendAssumeCapacity(removed);
            if (index < self.static_text_attrs.items.len) {
                const moved = self.static_text_attrs.items[index];
                self.updateStaticTextAttrIndex(moved.elem_id.raw(), moved.field, index);
            }
        }
        for (static_bool_indexes) |index| {
            const removed = self.static_bool_attrs.swapRemove(index);
            self.clearStaticBoolAttrIndex(removed.elem_id.raw(), removed.field, index);
            retired.static_bool_attrs.appendAssumeCapacity(removed);
            if (index < self.static_bool_attrs.items.len) {
                const moved = self.static_bool_attrs.items[index];
                self.updateStaticBoolAttrIndex(moved.elem_id.raw(), moved.field, index);
            }
        }
        for (signal_text_node_indexes) |index| {
            const removed = self.signal_text_nodes.swapRemove(index);
            self.forgetScopeElem(removed.scope_id, removed.elem_id);
            self.clearSignalTextNodeIndex(removed.elem_id.raw(), index);
            self.forgetSignalRecordTree(removed.signal.record);
            retired.rememberSignalRecordTreeAssumeCapacity(removed.signal.record);
            retired.signal_text_nodes.appendAssumeCapacity(removed);
            if (index < self.signal_text_nodes.items.len) self.updateSignalTextNodeIndex(self.signal_text_nodes.items[index].elem_id.raw(), index);
        }
        for (signal_text_indexes) |index| {
            const removed = self.signal_text_attrs.swapRemove(index);
            self.clearSignalTextAttrIndex(removed.elem_id.raw(), removed.field, index);
            self.forgetSignalRecordTree(removed.signal.record);
            retired.rememberSignalRecordTreeAssumeCapacity(removed.signal.record);
            retired.signal_text_attrs.appendAssumeCapacity(removed);
            if (index < self.signal_text_attrs.items.len) {
                const moved = self.signal_text_attrs.items[index];
                self.updateSignalTextAttrIndex(moved.elem_id.raw(), moved.field, index);
            }
        }
        for (signal_bool_indexes) |index| {
            const removed = self.signal_bool_attrs.swapRemove(index);
            self.clearSignalBoolAttrIndex(removed.elem_id.raw(), removed.field, index);
            self.forgetSignalRecordTree(removed.signal.record);
            retired.rememberSignalRecordTreeAssumeCapacity(removed.signal.record);
            retired.signal_bool_attrs.appendAssumeCapacity(removed);
            if (index < self.signal_bool_attrs.items.len) {
                const moved = self.signal_bool_attrs.items[index];
                self.updateSignalBoolAttrIndex(moved.elem_id.raw(), moved.field, index);
            }
        }
        for (event_indexes) |index| {
            const removed = self.events.swapRemove(index);
            if (removed.fixedKind()) |kind| {
                self.clearEventIndex(removed.elem_id.raw(), kind, index);
                const retired_index = retired.events.items.len;
                retired.events.appendAssumeCapacity(removed);
                setFreshIndex(retired.descriptor_indexes_by_elem_id.items[removed.elem_id.index()].events.slot(kind), retired_index);
            } else {
                self.clearNamedEventIndex(removed.elem_id.raw(), index);
                const retired_index = retired.events.items.len;
                retired.events.appendAssumeCapacity(removed);
                retired.named_event_indices_by_elem_id.items[removed.elem_id.index()].appendAssumeCapacity(retired_index);
            }
            if (index < self.events.items.len) {
                const moved = self.events.items[index];
                if (moved.fixedKind()) |kind| self.updateEventIndex(moved.elem_id.raw(), kind, index) else self.updateNamedEventIndex(moved.elem_id.raw(), self.events.items.len, index);
            }
        }
        for (state_indexes) |index| {
            const removed = self.states.swapRemove(index);
            self.clearStateIndex(removed.node_id.raw(), index);
            const retired_index = retired.states.items.len;
            retired.states.appendAssumeCapacity(removed);
            setFreshIndex(&retired.descriptor_indexes_by_node_id.items[removed.node_id.index()].state, retired_index);
            if (index < self.states.items.len) self.updateStateIndex(self.states.items[index].node_id.raw(), index);
        }
        for (when_indexes) |index| {
            const removed = self.whens.swapRemove(index);
            self.clearWhenIndex(removed.node_id.raw(), index);
            self.forgetSignalRecordTree(removed.condition.record);
            const retired_index = retired.whens.items.len;
            retired.rememberSignalRecordTreeAssumeCapacity(removed.condition.record);
            retired.whens.appendAssumeCapacity(removed);
            setFreshIndex(&retired.descriptor_indexes_by_node_id.items[removed.node_id.index()].when, retired_index);
            if (index < self.whens.items.len) self.updateWhenIndex(self.whens.items[index].node_id.raw(), index);
        }
        for (each_indexes) |index| {
            const removed = self.eaches.swapRemove(index);
            self.clearEachIndex(removed.node_id.raw(), index);
            self.forgetSignalRecordTree(removed.items.record);
            const retired_index = retired.eaches.items.len;
            retired.rememberSignalRecordTreeAssumeCapacity(removed.items.record);
            retired.eaches.appendAssumeCapacity(removed);
            setFreshIndex(&retired.descriptor_indexes_by_node_id.items[removed.node_id.index()].each, retired_index);
            if (index < self.eaches.items.len) self.updateEachIndex(self.eaches.items[index].node_id.raw(), index);
        }
        for (scope_site_indexes) |index| {
            const removed = self.scope_sites.swapRemove(index);
            self.forgetScopeNode(removed.scope_id, removed.node_id);
            self.clearScopeSiteIndex(removed.node_id.raw(), removed.kind, index);
            const retired_index = retired.scope_sites.items.len;
            retired.scope_sites.appendAssumeCapacity(removed);
            setFreshIndex(retired.descriptor_indexes_by_node_id.items[removed.node_id.index()].scope_sites.slot(removed.kind), retired_index);
            if (index < self.scope_sites.items.len) {
                const moved = self.scope_sites.items[index];
                self.updateScopeSiteIndex(moved.node_id.raw(), moved.kind, index);
            }
        }

        for (replacement.elements.items) |desc| {
            const index = self.elements.items.len;
            self.elements.appendAssumeCapacity(desc);
            while (self.descriptor_indexes_by_elem_id.items.len <= desc.elem_id.index()) self.descriptor_indexes_by_elem_id.appendAssumeCapacity(.{});
            setFreshIndex(&self.descriptor_indexes_by_elem_id.items[desc.elem_id.index()].element, index);
        }
        replacement.elements.items.len = 0;
        for (replacement.text_nodes.items) |desc| {
            const index = self.text_nodes.items.len;
            self.text_nodes.appendAssumeCapacity(desc);
            while (self.descriptor_indexes_by_elem_id.items.len <= desc.elem_id.index()) self.descriptor_indexes_by_elem_id.appendAssumeCapacity(.{});
            setFreshIndex(&self.descriptor_indexes_by_elem_id.items[desc.elem_id.index()].text_node, index);
        }
        replacement.text_nodes.items.len = 0;
        for (replacement.static_text_attrs.items) |desc| {
            const index = self.static_text_attrs.items.len;
            self.static_text_attrs.appendAssumeCapacity(desc);
            setFreshIndex(self.descriptor_indexes_by_elem_id.items[desc.elem_id.index()].static_text_attrs.slot(desc.field), index);
        }
        replacement.static_text_attrs.items.len = 0;
        for (replacement.static_bool_attrs.items) |desc| {
            const index = self.static_bool_attrs.items.len;
            self.static_bool_attrs.appendAssumeCapacity(desc);
            setFreshIndex(self.descriptor_indexes_by_elem_id.items[desc.elem_id.index()].static_bool_attrs.slot(desc.field), index);
        }
        replacement.static_bool_attrs.items.len = 0;
        for (replacement.signal_text_nodes.items) |desc| {
            const index = self.signal_text_nodes.items.len;
            self.signal_text_nodes.appendAssumeCapacity(desc);
            self.rememberSignalRecordTreeAssumeCapacity(desc.signal.record);
            while (self.descriptor_indexes_by_elem_id.items.len <= desc.elem_id.index()) self.descriptor_indexes_by_elem_id.appendAssumeCapacity(.{});
            setFreshIndex(&self.descriptor_indexes_by_elem_id.items[desc.elem_id.index()].signal_text_node, index);
        }
        replacement.signal_text_nodes.items.len = 0;
        for (replacement.signal_text_attrs.items) |desc| {
            const index = self.signal_text_attrs.items.len;
            self.signal_text_attrs.appendAssumeCapacity(desc);
            self.rememberSignalRecordTreeAssumeCapacity(desc.signal.record);
            setFreshIndex(self.descriptor_indexes_by_elem_id.items[desc.elem_id.index()].signal_text_attrs.slot(desc.field), index);
        }
        replacement.signal_text_attrs.items.len = 0;
        for (replacement.signal_bool_attrs.items) |desc| {
            const index = self.signal_bool_attrs.items.len;
            self.signal_bool_attrs.appendAssumeCapacity(desc);
            self.rememberSignalRecordTreeAssumeCapacity(desc.signal.record);
            setFreshIndex(self.descriptor_indexes_by_elem_id.items[desc.elem_id.index()].signal_bool_attrs.slot(desc.field), index);
        }
        replacement.signal_bool_attrs.items.len = 0;
        const event_base = self.events.items.len;
        for (replacement.events.items, 0..) |desc, offset| {
            const index = event_base + offset;
            self.events.appendAssumeCapacity(desc);
            while (self.descriptor_indexes_by_elem_id.items.len <= desc.elem_id.index()) self.descriptor_indexes_by_elem_id.appendAssumeCapacity(.{});
            if (desc.fixedKind()) |kind| setFreshIndex(self.descriptor_indexes_by_elem_id.items[desc.elem_id.index()].events.slot(kind), index);
        }
        replacement.events.items.len = 0;
        for (replacement.named_event_indices_by_elem_id.items, 0..) |*replacement_indexes, elem_id| {
            if (replacement_indexes.items.len == 0) continue;
            while (self.named_event_indices_by_elem_id.items.len <= elem_id) self.named_event_indices_by_elem_id.appendAssumeCapacity(.empty);
            const destination = &self.named_event_indices_by_elem_id.items[elem_id];
            for (replacement_indexes.items) |*index| index.* += event_base;
            if (destination.capacity == 0 and destination.items.len == 0) {
                destination.* = replacement_indexes.*;
                replacement_indexes.* = .empty;
            } else {
                destination.appendSliceAssumeCapacity(replacement_indexes.items);
                replacement_indexes.clearRetainingCapacity();
            }
        }
        for (replacement.scope_sites.items) |desc| {
            const index = self.scope_sites.items.len;
            self.scope_sites.appendAssumeCapacity(desc);
            while (self.descriptor_indexes_by_node_id.items.len <= desc.node_id.index()) self.descriptor_indexes_by_node_id.appendAssumeCapacity(.{});
            setFreshIndex(self.descriptor_indexes_by_node_id.items[desc.node_id.index()].scope_sites.slot(desc.kind), index);
        }
        replacement.scope_sites.items.len = 0;
        for (replacement.states.items) |desc| {
            const index = self.states.items.len;
            self.states.appendAssumeCapacity(desc);
            setFreshIndex(&self.descriptor_indexes_by_node_id.items[desc.node_id.index()].state, index);
        }
        replacement.states.items.len = 0;
        for (replacement.whens.items) |desc| {
            const index = self.whens.items.len;
            self.whens.appendAssumeCapacity(desc);
            self.rememberSignalRecordTreeAssumeCapacity(desc.condition.record);
            setFreshIndex(&self.descriptor_indexes_by_node_id.items[desc.node_id.index()].when, index);
        }
        replacement.whens.items.len = 0;
        for (replacement.eaches.items) |desc| {
            const index = self.eaches.items.len;
            self.eaches.appendAssumeCapacity(desc);
            self.rememberSignalRecordTreeAssumeCapacity(desc.items.record);
            setFreshIndex(&self.descriptor_indexes_by_node_id.items[desc.node_id.index()].each, index);
        }
        replacement.eaches.items.len = 0;
        for (replacement.scope_descriptor_ownership.items, 0..) |*source, scope_index| {
            if (source.elem_ids.items.len == 0 and source.node_ids.items.len == 0) continue;
            const destination = &self.scope_descriptor_ownership.items[scope_index];
            destination.elem_ids.appendSliceAssumeCapacity(source.elem_ids.items);
            destination.node_ids.appendSliceAssumeCapacity(source.node_ids.items);
            source.elem_ids.clearRetainingCapacity();
            source.node_ids.clearRetainingCapacity();
        }
    }

    /// Publishes the render-node membership of a sparse structural edit.
    ///
    /// The dense array is only an unordered descriptor pool on this path:
    /// removed ids are swap-retired and replacement nodes append into reserved
    /// capacity. Durable parent/sibling links remain the render-order authority
    /// and are intentionally left for the prepared sparse order journal. New
    /// top-level roots therefore enter detached, while links wholly inside a
    /// replacement subtree transfer with that subtree.
    pub fn commitSparseRenderNodesAssumeCapacity(self: *Stream, replacement: *Stream, retired: *Stream, removed_elem_ids: []const u64) void {
        commitSparseRenderNodes(Stream, self, replacement, retired, removed_elem_ids);
    }

    /// Drops detached metadata left by sparse render-node retirement.
    /// Reused ids have a replacement render-node index and deliberately retain
    /// their newly published metadata.
    pub fn finishSparseRenderNodeRetirement(self: *Stream, removed_elem_ids: []const u64) void {
        finishSparseRenderNodeRetirementImpl(Stream, self, removed_elem_ids);
    }

    fn rememberSignalRecordTreeAssumeCapacity(self: *Stream, record: *SignalRecord) void {
        const Context = struct {
            stream: *Stream,
            fn visit(ctx: @This(), current: *SignalRecord) void {
                const token = current.token() orelse return;
                ctx.stream.rememberSignalRecordAssumeCapacity(token, current);
                const entry = ctx.stream.signal_record_descriptor_uses_by_token.getOrPutAssumeCapacity(token);
                if (entry.found_existing) entry.value_ptr.* += 1 else entry.value_ptr.* = 1;
            }
        };
        signal_records.walkTree(Context, .{ .stream = self }, record, Context.visit);
    }

    /// Publishes every token and descriptor-use edge in a prepared signal tree
    /// using capacity reserved before commit. This also covers descriptors that
    /// reuse persistent records rather than constructing transaction-local ones.
    pub fn rememberPreparedSignalRecordTreeAssumeCapacity(self: *Stream, record: *SignalRecord) void {
        self.rememberSignalRecordTreeAssumeCapacity(record);
    }

    /// Commits the minimal one-text replacement using only pre-reserved
    /// storage. The replacement stream receives the displaced descriptor and
    /// therefore owns its string after the swap.
    pub fn commitSingleTextReplacementAssumeCapacity(self: *Stream, replacement: *Stream, removed_elem_id: u64) void {
        if (replacement.text_nodes.items.len != 1 or replacement.render_nodes.items.len != 1) @panic("single-text splice received a non-text replacement");
        const old_index = self.elemDescriptorIndex(removed_elem_id) orelse @panic("single-text splice target is not indexed");
        const text_index = old_index.text_node.get() orelse @panic("single-text splice target is not text");
        const old_render_index = self.renderNodeIndex(removed_elem_id) orelse @panic("single-text splice target is not rendered");
        const new_elem_id = replacement.text_nodes.items[0].elem_id;

        const displaced_text = self.text_nodes.items[text_index];
        const replacement_text = replacement.text_nodes.items[0];
        self.text_nodes.items[text_index] = replacement.text_nodes.items[0];
        replacement.text_nodes.items[0] = displaced_text;
        const displaced_render = self.render_nodes.items[old_render_index];
        self.render_nodes.items[old_render_index] = replacement.render_nodes.items[0];
        replacement.render_nodes.items[0] = displaced_render;

        clearIndex(&self.descriptor_indexes_by_elem_id.items[@intCast(removed_elem_id)].text_node, text_index);
        while (self.descriptor_indexes_by_elem_id.items.len <= new_elem_id) self.descriptor_indexes_by_elem_id.appendAssumeCapacity(.{});
        setFreshIndex(&self.descriptor_indexes_by_elem_id.items[@intCast(new_elem_id)].text_node, text_index);
        const removed_metadata = self.render_metadata_by_elem_id.fetchRemove(removed_elem_id) orelse @panic("single-text splice target lacked render metadata");
        var replacement_metadata = removed_metadata.value;
        replacement_metadata.render_node = old_render_index;
        self.render_metadata_by_elem_id.putAssumeCapacity(new_elem_id, replacement_metadata);
        self.forgetScopeElem(displaced_text.scope_id, displaced_text.elem_id);
        self.recordScopeElemAssumeCapacity(replacement_text.scope_id, replacement_text.elem_id);
        self.next_elem_id = @max(self.next_elem_id, new_elem_id + 1);
    }

    /// Ensures elem descriptor index capacity or state before publication can begin.
    pub fn ensureElemDescriptorIndex(self: *Stream, allocator: std.mem.Allocator, elem_id: ElemId) *ElemDescriptorIndex {
        return ensureElemDescriptorIndexImpl(Stream, self, allocator, elem_id);
    }

    /// Maintains elem descriptor index within the indexed descriptor stream used by both hosts.
    pub fn elemDescriptorIndex(self: *const Stream, elem_id: ElemId) ?ElemDescriptorIndex {
        return elemDescriptorIndexImpl(Stream, self, elem_id);
    }

    /// Ensures node descriptor index capacity or state before publication can begin.
    pub fn ensureNodeDescriptorIndex(self: *Stream, allocator: std.mem.Allocator, node_id: NodeId) *NodeDescriptorIndex {
        return ensureNodeDescriptorIndexImpl(Stream, self, allocator, node_id);
    }

    /// Maintains node descriptor index within the indexed descriptor stream used by both hosts.
    pub fn nodeDescriptorIndex(self: *const Stream, node_id: NodeId) ?NodeDescriptorIndex {
        return nodeDescriptorIndexImpl(Stream, self, node_id);
    }

    /// Ensures render metadata capacity or state before publication can begin.
    pub fn ensureRenderMetadata(self: *Stream, allocator: std.mem.Allocator, elem_id: ElemId) *RenderElemIndex {
        return ensureRenderMetadataImpl(Stream, self, allocator, elem_id);
    }

    /// Removes metadata if empty while preserving indexes for unaffected render nodes.
    pub fn removeRenderMetadataIfEmpty(self: *Stream, elem_id: ElemId) void {
        removeRenderMetadataIfEmptyImpl(Stream, self, elem_id);
    }

    /// Returns index for an already indexed render node.
    pub fn renderNodeIndex(self: *const Stream, elem_id: ElemId) ?usize {
        return renderNodeIndexImpl(Stream, self, elem_id);
    }

    /// Resolves a raw engine elem id at generic structural-planning seams.
    pub fn renderNodeIndexRaw(self: *const Stream, elem_id: u64) ?usize {
        return renderNodeIndexImpl(Stream, self, ElemId.fromRaw(elem_id));
    }

    /// Records the dense render node descriptor index used for O(1) runtime lookup.
    pub fn recordRenderNodeIndex(self: *Stream, allocator: std.mem.Allocator, elem_id: ElemId, index: usize) void {
        recordRenderNodeIndexImpl(Stream, self, allocator, elem_id, index);
    }

    /// Updates the dense render node descriptor index after a local structural splice.
    pub fn updateRenderNodeIndex(self: *Stream, elem_id: ElemId, index: usize) void {
        updateRenderNodeIndexImpl(Stream, self, elem_id, index);
    }

    /// Clears render node index while retaining bounded storage where the type promises reuse.
    pub fn clearRenderNodeIndex(self: *Stream, elem_id: ElemId, expected: usize) void {
        clearRenderNodeIndexImpl(Stream, self, elem_id, expected);
    }

    /// Ensures first render child slot capacity or state before publication can begin.
    pub fn ensureFirstRenderChildSlot(self: *Stream, allocator: std.mem.Allocator, parent_elem_id: ElemId) *?ElemId {
        return ensureFirstRenderChildSlotImpl(Stream, self, allocator, parent_elem_id);
    }

    /// Ensures last render child slot capacity or state before publication can begin.
    pub fn ensureLastRenderChildSlot(self: *Stream, allocator: std.mem.Allocator, parent_elem_id: ElemId) *?ElemId {
        return ensureLastRenderChildSlotImpl(Stream, self, allocator, parent_elem_id);
    }

    /// Ensures next render sibling slot capacity or state before publication can begin.
    pub fn ensureNextRenderSiblingSlot(self: *Stream, allocator: std.mem.Allocator, elem_id: ElemId) *?ElemId {
        return ensureNextRenderSiblingSlotImpl(Stream, self, allocator, elem_id);
    }

    /// Ensures the reverse sibling-link slot used by sparse structural splices.
    pub fn ensurePreviousRenderSiblingSlot(self: *Stream, allocator: std.mem.Allocator, elem_id: ElemId) *?ElemId {
        return ensurePreviousRenderSiblingSlotImpl(Stream, self, allocator, elem_id);
    }

    /// Maintains first render child within the indexed descriptor stream used by both hosts.
    pub fn firstRenderChild(self: *const Stream, parent_elem_id: ElemId) ?ElemId {
        return firstRenderChildImpl(Stream, self, parent_elem_id);
    }

    /// Returns last render child retained for observability or local structural traversal.
    pub fn lastRenderChild(self: *const Stream, parent_elem_id: ElemId) ?ElemId {
        return lastRenderChildImpl(Stream, self, parent_elem_id);
    }

    /// Returns next render sibling from maintained local structure without a full-tree scan.
    pub fn nextRenderSibling(self: *const Stream, elem_id: ElemId) ?ElemId {
        return nextRenderSiblingImpl(Stream, self, elem_id);
    }

    /// Returns the previous sibling without scanning the parent's child list.
    pub fn previousRenderSibling(self: *const Stream, elem_id: ElemId) ?ElemId {
        return previousRenderSiblingImpl(Stream, self, elem_id);
    }

    /// Appends render child using capacity that must already satisfy the caller's transaction contract.
    pub fn appendRenderChild(self: *Stream, allocator: std.mem.Allocator, parent_elem_id: ElemId, elem_id: ElemId) void {
        appendRenderChildImpl(Stream, self, allocator, parent_elem_id, elem_id);
    }

    /// Clears render children while retaining bounded storage where the type promises reuse.
    pub fn clearRenderChildren(self: *Stream, parent_elem_id: ElemId) void {
        clearRenderChildrenImpl(Stream, self, parent_elem_id);
    }

    /// Removes child while preserving indexes for unaffected render nodes.
    pub fn removeRenderChild(self: *Stream, parent_elem_id: ElemId, elem_id: ElemId) void {
        removeRenderChildImpl(Stream, self, parent_elem_id, elem_id);
    }

    /// Moves one already-linked contiguous sibling range before an anchor.
    ///
    /// The caller must establish that `first_elem_id...last_elem_id` is a
    /// contiguous child range of `parent_elem_id`, and that `before_elem_id`
    /// is either null or a child outside that range. The operation mutates no
    /// dense render-node storage and allocates nothing, so a prepared Rows
    /// transition can publish a validated move without scanning siblings.
    pub fn moveRenderSiblingRangeBefore(self: *Stream, parent_elem_id: ElemId, first_elem_id: ElemId, last_elem_id: ElemId, before_elem_id: ?ElemId) RenderSiblingMoveWork {
        return moveRenderSiblingRangeBeforeImpl(Stream, self, parent_elem_id, first_elem_id, last_elem_id, before_elem_id);
    }

    /// Inserts children into prepared render metadata for the affected subtree.
    pub fn insertRenderChildren(self: *Stream, allocator: std.mem.Allocator, parent_elem_id: ElemId, index: usize, elem_ids: []const ElemId) void {
        insertRenderChildrenImpl(Stream, self, allocator, parent_elem_id, index, elem_ids);
    }

    /// Replaces children index for the affected parent without rebuilding unrelated tree state.
    pub fn replaceRenderChildrenIndex(self: *Stream, allocator: std.mem.Allocator, parent_elem_id: ElemId, elem_ids: []const ElemId) void {
        replaceRenderChildrenIndexImpl(Stream, self, allocator, parent_elem_id, elem_ids);
    }

    /// Maintains child insertion index for render index within the indexed descriptor stream used by both hosts.
    pub fn childInsertionIndexForRenderIndex(self: *const Stream, parent_elem_id: ElemId, render_insert_index: usize) usize {
        return childInsertionIndexForRenderIndexImpl(Stream, self, parent_elem_id, render_insert_index);
    }

    /// Refreshes indexes from only across the range affected by a structural splice.
    pub fn refreshRenderIndexesFrom(self: *Stream, allocator: std.mem.Allocator, start_index: usize, metrics: anytype) void {
        refreshRenderIndexesFromImpl(Stream, self, allocator, start_index, metrics);
    }

    /// Refreshes indexes in range only across the range affected by a structural splice.
    pub fn refreshRenderIndexesInRange(self: *Stream, allocator: std.mem.Allocator, start_index: usize, count: usize, metrics: anytype) void {
        refreshRenderIndexesInRangeImpl(Stream, self, allocator, start_index, count, metrics);
    }

    /// Maintains move replacement render children within the indexed descriptor stream used by both hosts.
    pub fn moveReplacementRenderChildren(self: *Stream, allocator: std.mem.Allocator, replacement: *Stream, elem_id: u64) void {
        self.clearRenderChildren(elem_id);
        const first_child = replacement.firstRenderChild(elem_id) orelse return;
        self.ensureFirstRenderChildSlot(allocator, elem_id).* = first_child;
        self.ensureLastRenderChildSlot(allocator, elem_id).* = replacement.lastRenderChild(elem_id) orelse @panic("replacement child index was missing its last child");

        var child: ?u64 = first_child;
        while (child) |child_id| {
            const next = replacement.nextRenderSibling(child_id);
            self.ensurePreviousRenderSiblingSlot(allocator, child_id).* = replacement.previousRenderSibling(child_id);
            self.ensureNextRenderSiblingSlot(allocator, child_id).* = next;
            child = next;
        }

        if (replacement.render_metadata_by_elem_id.getPtr(elem_id)) |replacement_metadata| {
            replacement_metadata.first_child = null;
            replacement_metadata.last_child = null;
        }
        replacement.removeRenderMetadataIfEmpty(elem_id);
    }

    /// Replaces range with stream for the affected parent without rebuilding unrelated tree state.
    pub fn replaceRenderRangeWithStream(self: *Stream, allocator: std.mem.Allocator, render_start: usize, removed_nodes: []const StreamRenderNode, replacement: *Stream, metrics: anytype) void {
        self.replaceRenderRangeWithStreamOptions(allocator, render_start, removed_nodes, replacement, null, true, metrics);
    }

    /// Replaces range with stream options for the affected parent without rebuilding unrelated tree state.
    pub fn replaceRenderRangeWithStreamOptions(self: *Stream, allocator: std.mem.Allocator, render_start: usize, removed_nodes: []const StreamRenderNode, replacement: *Stream, child_insert_hint: ?RenderChildInsertHint, refresh_suffix_indexes: bool, metrics: anytype) void {
        const ChildInsert = struct {
            parent_elem_id: u64,
            insertion_index: usize,
            elem_ids: std.ArrayListUnmanaged(u64) = .empty,

            fn deinit(insert: *@This(), alloc: std.mem.Allocator) void {
                insert.elem_ids.deinit(alloc);
                insert.* = undefined;
            }
        };

        var child_inserts: std.ArrayListUnmanaged(ChildInsert) = .empty;
        defer {
            for (child_inserts.items) |*insert| {
                insert.deinit(allocator);
            }
            child_inserts.deinit(allocator);
        }

        if (!refresh_suffix_indexes) {
            self.refreshRenderIndexesInRange(allocator, render_start, removed_nodes.len, metrics);
        }

        var removed_elem_set: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer removed_elem_set.deinit(allocator);
        removed_elem_set.ensureTotalCapacity(allocator, @intCast(removed_nodes.len)) catch @panic("out of memory");
        for (removed_nodes) |node| removed_elem_set.putAssumeCapacity(node.elem_id, {});

        for (removed_nodes, render_start..) |node, index| {
            const parent_elem_id = renderNodeParentElemId(Stream, self, node);
            if (!removed_elem_set.contains(parent_elem_id)) {
                self.removeRenderChild(parent_elem_id, node.elem_id);
            }
            self.clearRenderChildren(node.elem_id);
            self.clearRenderNodeIndex(node.elem_id, index);
        }

        for (replacement.render_nodes.items) |node| {
            const parent_elem_id = renderNodeParentElemId(Stream, replacement, node);
            const parent_in_replacement = parent_elem_id != 0 and replacement.renderNodeIndex(parent_elem_id) != null;
            if (!parent_in_replacement) {
                var group_index: ?usize = null;
                for (child_inserts.items, 0..) |insert, index| {
                    if (insert.parent_elem_id == parent_elem_id) {
                        group_index = index;
                        break;
                    }
                }

                const index = group_index orelse index: {
                    const insertion_index = if (child_insert_hint) |hint| hint_index: {
                        if (hint.parent_elem_id == parent_elem_id) break :hint_index hint.insertion_index;
                        break :hint_index self.childInsertionIndexForRenderIndex(parent_elem_id, render_start);
                    } else self.childInsertionIndexForRenderIndex(parent_elem_id, render_start);
                    child_inserts.append(allocator, .{
                        .parent_elem_id = parent_elem_id,
                        .insertion_index = insertion_index,
                    }) catch @panic("out of memory");
                    break :index child_inserts.items.len - 1;
                };
                child_inserts.items[index].elem_ids.append(allocator, node.elem_id) catch @panic("out of memory");
            }
            self.moveReplacementRenderChildren(allocator, replacement, node.elem_id);
        }

        for (child_inserts.items) |insert| {
            self.insertRenderChildren(allocator, insert.parent_elem_id, insert.insertion_index, insert.elem_ids.items);
            if (insert.elem_ids.items.len != 0 and self.firstRenderChild(insert.parent_elem_id) == null) {
                @panic("render child insertion did not update parent child index");
            }
        }

        const replacement_render_count = replacement.render_nodes.items.len;
        self.render_nodes.replaceRange(allocator, render_start, removed_nodes.len, replacement.render_nodes.items) catch @panic("out of memory");
        replacement.render_nodes.items.len = 0;
        self.refreshRenderIndexesInRange(allocator, render_start, replacement_render_count, metrics);
        if (refresh_suffix_indexes and removed_nodes.len != replacement_render_count) {
            self.refreshRenderIndexesFrom(allocator, render_start + replacement_render_count, metrics);
        }
    }

    /// Records the dense element descriptor index used for O(1) runtime lookup.
    pub fn recordElementIndex(self: *Stream, allocator: std.mem.Allocator, elem_id: u64, index: usize) void {
        recordElementIndexImpl(Stream, self, allocator, elem_id, index);
    }

    /// Updates the dense element descriptor index after a local structural splice.
    pub fn updateElementIndex(self: *Stream, elem_id: u64, index: usize) void {
        updateElementIndexImpl(Stream, self, elem_id, index);
    }

    /// Clears element index while retaining bounded storage where the type promises reuse.
    pub fn clearElementIndex(self: *Stream, elem_id: u64, expected: usize) void {
        clearElementIndexImpl(Stream, self, elem_id, expected);
    }

    /// Records the dense text node descriptor index used for O(1) runtime lookup.
    pub fn recordTextNodeIndex(self: *Stream, allocator: std.mem.Allocator, elem_id: u64, index: usize) void {
        recordTextNodeIndexImpl(Stream, self, allocator, elem_id, index);
    }

    /// Updates the dense text node descriptor index after a local structural splice.
    pub fn updateTextNodeIndex(self: *Stream, elem_id: u64, index: usize) void {
        updateTextNodeIndexImpl(Stream, self, elem_id, index);
    }

    /// Clears text node index while retaining bounded storage where the type promises reuse.
    pub fn clearTextNodeIndex(self: *Stream, elem_id: u64, expected: usize) void {
        clearTextNodeIndexImpl(Stream, self, elem_id, expected);
    }

    /// Records the dense signal text node descriptor index used for O(1) runtime lookup.
    pub fn recordSignalTextNodeIndex(self: *Stream, allocator: std.mem.Allocator, elem_id: u64, index: usize) void {
        recordSignalTextNodeIndexImpl(Stream, self, allocator, elem_id, index);
    }

    /// Updates the dense signal text node descriptor index after a local structural splice.
    pub fn updateSignalTextNodeIndex(self: *Stream, elem_id: u64, index: usize) void {
        updateSignalTextNodeIndexImpl(Stream, self, elem_id, index);
    }

    /// Clears signal text node index while retaining bounded storage where the type promises reuse.
    pub fn clearSignalTextNodeIndex(self: *Stream, elem_id: u64, expected: usize) void {
        clearSignalTextNodeIndexImpl(Stream, self, elem_id, expected);
    }

    /// Records the dense static text attr descriptor index used for O(1) runtime lookup.
    pub fn recordStaticTextAttrIndex(self: *Stream, allocator: std.mem.Allocator, elem_id: u64, field: TextField, index: usize) void {
        recordStaticTextAttrIndexImpl(Stream, self, allocator, elem_id, field, index);
    }

    /// Updates the dense static text attr descriptor index after a local structural splice.
    pub fn updateStaticTextAttrIndex(self: *Stream, elem_id: u64, field: TextField, index: usize) void {
        updateStaticTextAttrIndexImpl(Stream, self, elem_id, field, index);
    }

    /// Clears static text attr index while retaining bounded storage where the type promises reuse.
    pub fn clearStaticTextAttrIndex(self: *Stream, elem_id: u64, field: TextField, expected: usize) void {
        clearStaticTextAttrIndexImpl(Stream, self, elem_id, field, expected);
    }

    /// Records the dense signal text attr descriptor index used for O(1) runtime lookup.
    pub fn recordSignalTextAttrIndex(self: *Stream, allocator: std.mem.Allocator, elem_id: u64, field: TextField, index: usize) void {
        recordSignalTextAttrIndexImpl(Stream, self, allocator, elem_id, field, index);
    }

    /// Updates the dense signal text attr descriptor index after a local structural splice.
    pub fn updateSignalTextAttrIndex(self: *Stream, elem_id: u64, field: TextField, index: usize) void {
        updateSignalTextAttrIndexImpl(Stream, self, elem_id, field, index);
    }

    /// Clears signal text attr index while retaining bounded storage where the type promises reuse.
    pub fn clearSignalTextAttrIndex(self: *Stream, elem_id: u64, field: TextField, expected: usize) void {
        clearSignalTextAttrIndexImpl(Stream, self, elem_id, field, expected);
    }

    /// Records the dense static bool attr descriptor index used for O(1) runtime lookup.
    pub fn recordStaticBoolAttrIndex(self: *Stream, allocator: std.mem.Allocator, elem_id: u64, field: BoolField, index: usize) void {
        recordStaticBoolAttrIndexImpl(Stream, self, allocator, elem_id, field, index);
    }

    /// Updates the dense static bool attr descriptor index after a local structural splice.
    pub fn updateStaticBoolAttrIndex(self: *Stream, elem_id: u64, field: BoolField, index: usize) void {
        updateStaticBoolAttrIndexImpl(Stream, self, elem_id, field, index);
    }

    /// Clears static bool attr index while retaining bounded storage where the type promises reuse.
    pub fn clearStaticBoolAttrIndex(self: *Stream, elem_id: u64, field: BoolField, expected: usize) void {
        clearStaticBoolAttrIndexImpl(Stream, self, elem_id, field, expected);
    }

    /// Records the dense signal bool attr descriptor index used for O(1) runtime lookup.
    pub fn recordSignalBoolAttrIndex(self: *Stream, allocator: std.mem.Allocator, elem_id: u64, field: BoolField, index: usize) void {
        recordSignalBoolAttrIndexImpl(Stream, self, allocator, elem_id, field, index);
    }

    /// Updates the dense signal bool attr descriptor index after a local structural splice.
    pub fn updateSignalBoolAttrIndex(self: *Stream, elem_id: u64, field: BoolField, index: usize) void {
        updateSignalBoolAttrIndexImpl(Stream, self, elem_id, field, index);
    }

    /// Clears signal bool attr index while retaining bounded storage where the type promises reuse.
    pub fn clearSignalBoolAttrIndex(self: *Stream, elem_id: u64, field: BoolField, expected: usize) void {
        clearSignalBoolAttrIndexImpl(Stream, self, elem_id, field, expected);
    }

    /// Records the dense event descriptor index used for O(1) runtime lookup.
    pub fn recordEventIndex(self: *Stream, allocator: std.mem.Allocator, elem_id: ElemId, kind: EventKind, index: usize) void {
        recordEventIndexImpl(Stream, self, allocator, elem_id, kind, index);
    }

    /// Updates the dense event descriptor index after a local structural splice.
    pub fn updateEventIndex(self: *Stream, elem_id: u64, kind: EventKind, index: usize) void {
        updateEventIndexImpl(Stream, self, elem_id, kind, index);
    }

    /// Clears event index while retaining bounded storage where the type promises reuse.
    pub fn clearEventIndex(self: *Stream, elem_id: u64, kind: EventKind, expected: usize) void {
        clearEventIndexImpl(Stream, self, elem_id, kind, expected);
    }

    /// Records the dense named event descriptor index used for O(1) runtime lookup.
    pub fn recordNamedEventIndex(self: *Stream, allocator: std.mem.Allocator, elem_id: ElemId, index: usize) void {
        recordNamedEventIndexImpl(Stream, self, allocator, elem_id, index);
    }

    /// Updates the dense named event descriptor index after a local structural splice.
    pub fn updateNamedEventIndex(self: *Stream, elem_id: u64, old_index: usize, new_index: usize) void {
        updateNamedEventIndexImpl(Stream, self, elem_id, old_index, new_index);
    }

    /// Clears named event index while retaining bounded storage where the type promises reuse.
    pub fn clearNamedEventIndex(self: *Stream, elem_id: u64, expected: usize) void {
        clearNamedEventIndexImpl(Stream, self, elem_id, expected);
    }

    /// Maintains named event indices within the indexed descriptor stream used by both hosts.
    pub fn namedEventIndices(self: *const Stream, elem_id: ElemId) []const usize {
        return namedEventIndicesImpl(Stream, self, elem_id);
    }

    /// Records the dense scope site descriptor index used for O(1) runtime lookup.
    pub fn recordScopeSiteIndex(self: *Stream, allocator: std.mem.Allocator, node_id: u64, kind: ScopeSiteKind, index: usize) void {
        recordScopeSiteIndexImpl(Stream, self, allocator, node_id, kind, index);
    }

    /// Updates the dense scope site descriptor index after a local structural splice.
    pub fn updateScopeSiteIndex(self: *Stream, node_id: u64, kind: ScopeSiteKind, index: usize) void {
        updateScopeSiteIndexImpl(Stream, self, node_id, kind, index);
    }

    /// Clears scope site index while retaining bounded storage where the type promises reuse.
    pub fn clearScopeSiteIndex(self: *Stream, node_id: u64, kind: ScopeSiteKind, expected: usize) void {
        clearScopeSiteIndexImpl(Stream, self, node_id, kind, expected);
    }

    /// Records the dense state descriptor index used for O(1) runtime lookup.
    pub fn recordStateIndex(self: *Stream, allocator: std.mem.Allocator, node_id: u64, index: usize) void {
        recordStateIndexImpl(Stream, self, allocator, node_id, index);
    }

    /// Updates the dense state descriptor index after a local structural splice.
    pub fn updateStateIndex(self: *Stream, node_id: u64, index: usize) void {
        updateStateIndexImpl(Stream, self, node_id, index);
    }

    /// Clears state index while retaining bounded storage where the type promises reuse.
    pub fn clearStateIndex(self: *Stream, node_id: u64, expected: usize) void {
        clearStateIndexImpl(Stream, self, node_id, expected);
    }

    /// Records the dense when descriptor index used for O(1) runtime lookup.
    pub fn recordWhenIndex(self: *Stream, allocator: std.mem.Allocator, node_id: u64, index: usize) void {
        recordWhenIndexImpl(Stream, self, allocator, node_id, index);
    }

    /// Updates the dense when descriptor index after a local structural splice.
    pub fn updateWhenIndex(self: *Stream, node_id: u64, index: usize) void {
        updateWhenIndexImpl(Stream, self, node_id, index);
    }

    /// Clears when index while retaining bounded storage where the type promises reuse.
    pub fn clearWhenIndex(self: *Stream, node_id: u64, expected: usize) void {
        clearWhenIndexImpl(Stream, self, node_id, expected);
    }

    /// Records the dense each descriptor index used for O(1) runtime lookup.
    pub fn recordEachIndex(self: *Stream, allocator: std.mem.Allocator, node_id: u64, index: usize) void {
        recordEachIndexImpl(Stream, self, allocator, node_id, index);
    }

    /// Updates the dense each descriptor index after a local structural splice.
    pub fn updateEachIndex(self: *Stream, node_id: u64, index: usize) void {
        updateEachIndexImpl(Stream, self, node_id, index);
    }

    /// Clears each index while retaining bounded storage where the type promises reuse.
    pub fn clearEachIndex(self: *Stream, node_id: u64, expected: usize) void {
        clearEachIndexImpl(Stream, self, node_id, expected);
    }

    /// Releases every resource owned by this value and leaves no retained host or Roc ownership behind.
    pub fn deinit(self: *Stream, allocator: std.mem.Allocator, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype) void {
        self.render_nodes.deinit(allocator);

        for (self.elements.items) |desc| {
            allocator.free(desc.tag);
        }
        self.elements.deinit(allocator);

        for (self.text_nodes.items) |desc| {
            allocator.free(desc.value);
        }
        self.text_nodes.deinit(allocator);

        for (self.signal_text_nodes.items) |*desc| {
            desc.deinit(allocator, ctx, roc_host, metrics);
        }
        self.signal_text_nodes.deinit(allocator);

        for (self.static_text_attrs.items) |desc| {
            allocator.free(desc.value);
        }
        self.static_text_attrs.deinit(allocator);

        for (self.signal_text_attrs.items) |*desc| {
            desc.deinit(allocator, ctx, roc_host, metrics);
        }
        self.signal_text_attrs.deinit(allocator);

        for (self.static_custom_text_attrs.items) |desc| {
            allocator.free(desc.name);
            allocator.free(desc.value);
        }
        self.static_custom_text_attrs.deinit(allocator);

        for (self.signal_custom_text_attrs.items) |*desc| {
            desc.deinit(allocator, ctx, roc_host, metrics);
        }
        self.signal_custom_text_attrs.deinit(allocator);

        for (self.signal_optional_custom_text_attrs.items) |*desc| {
            desc.deinit(allocator, ctx, roc_host, metrics);
        }
        self.signal_optional_custom_text_attrs.deinit(allocator);

        for (self.static_custom_bool_attrs.items) |desc| {
            allocator.free(desc.name);
        }
        self.static_custom_bool_attrs.deinit(allocator);

        for (self.signal_custom_bool_attrs.items) |*desc| {
            desc.deinit(allocator, ctx, roc_host, metrics);
        }
        self.signal_custom_bool_attrs.deinit(allocator);

        self.static_bool_attrs.deinit(allocator);

        for (self.signal_bool_attrs.items) |*desc| {
            desc.deinit(allocator, ctx, roc_host, metrics);
        }
        self.signal_bool_attrs.deinit(allocator);

        for (self.on_changes.items) |*desc| {
            desc.deinit(allocator, ctx, roc_host, metrics);
        }
        self.on_changes.deinit(allocator);

        for (self.mounts.items) |desc| {
            desc.deinit(roc_host, metrics);
        }
        self.mounts.deinit(allocator);

        for (self.cleanups.items) |desc| {
            allocator.free(desc.name);
        }
        self.cleanups.deinit(allocator);

        for (self.events.items) |desc| {
            desc.deinit(allocator, roc_host, metrics);
        }
        self.events.deinit(allocator);
        deinitNamedEventIndexLists(Stream, self, allocator);

        for (self.scope_sites.items) |desc| {
            allocator.free(desc.binder_bindings);
        }
        self.scope_sites.deinit(allocator);

        for (self.states.items) |desc| {
            desc.deinit(roc_host, metrics);
        }
        self.states.deinit(allocator);

        for (self.whens.items) |*desc| {
            desc.deinit(allocator, ctx, roc_host, metrics);
        }
        self.whens.deinit(allocator);

        for (self.eaches.items) |*desc| {
            desc.deinit(allocator, ctx, roc_host, metrics);
        }
        self.eaches.deinit(allocator);

        self.signal_records_by_token.deinit(allocator);
        self.signal_record_descriptor_uses_by_token.deinit(allocator);
        self.custom_attr_keys.deinit(allocator);
        for (self.custom_attr_indices_by_elem_id.items) |*indexes| indexes.deinit(allocator);
        self.custom_attr_indices_by_elem_id.deinit(allocator);
        for (self.lifecycle_indices_by_scope_id.items) |*indexes| indexes.deinit(allocator);
        self.lifecycle_indices_by_scope_id.deinit(allocator);
        for (self.scope_descriptor_ownership.items) |*ownership| ownership.deinit(allocator);
        self.scope_descriptor_ownership.deinit(allocator);
        self.render_metadata_by_elem_id.deinit(allocator);
        self.descriptor_indexes_by_elem_id.deinit(allocator);
        self.descriptor_indexes_by_node_id.deinit(allocator);

        self.* = .{};
    }

    /// Maintains signal record by token within the indexed descriptor stream used by both hosts.
    pub fn signalRecordByToken(self: *Stream, token: HostSignalToken) ?*SignalRecord {
        return self.signal_records_by_token.get(token);
    }

    /// Maintains reserve prepared signal record publication within the indexed descriptor stream used by both hosts.
    pub fn reservePreparedSignalRecordPublication(self: *Stream, allocator: std.mem.Allocator, additional_records: usize) std.mem.Allocator.Error!void {
        try self.signal_records_by_token.ensureUnusedCapacity(allocator, @intCast(additional_records));
        try self.signal_record_descriptor_uses_by_token.ensureUnusedCapacity(allocator, @intCast(additional_records));
    }

    /// Maintains remember signal record assume capacity within the indexed descriptor stream used by both hosts.
    pub fn rememberSignalRecordAssumeCapacity(self: *Stream, token: HostSignalToken, record: *SignalRecord) void {
        const entry = self.signal_records_by_token.getOrPutAssumeCapacity(token);
        if (entry.found_existing) {
            if (entry.value_ptr.* != record) @panic("signal token was bound to multiple host records");
            return;
        }
        entry.value_ptr.* = record;
    }

    /// Maintains increment signal record descriptor tree assume capacity within the indexed descriptor stream used by both hosts.
    pub fn incrementSignalRecordDescriptorTreeAssumeCapacity(self: *Stream, root: *SignalRecord) void {
        const Context = struct {
            stream: *Stream,

            fn visit(ctx: @This(), current: *SignalRecord) void {
                const token = current.token() orelse return;
                const entry = ctx.stream.signal_record_descriptor_uses_by_token.getOrPutAssumeCapacity(token);
                if (entry.found_existing) {
                    entry.value_ptr.* += 1;
                } else {
                    entry.value_ptr.* = 1;
                }
            }
        };
        signal_records.walkTree(Context, .{ .stream = self }, root, Context.visit);
    }

    /// Maintains remember signal record within the indexed descriptor stream used by both hosts.
    pub fn rememberSignalRecord(self: *Stream, allocator: std.mem.Allocator, record: *SignalRecord) void {
        const token = record.token() orelse return;
        const entry = self.signal_records_by_token.getOrPut(allocator, token) catch @panic("out of memory");
        if (entry.found_existing) {
            if (entry.value_ptr.* != record) @panic("signal token was bound to multiple host records");
            return;
        }
        entry.value_ptr.* = record;
    }

    fn incrementSignalRecordDescriptorUse(self: *Stream, allocator: std.mem.Allocator, record: *SignalRecord) void {
        const token = record.token() orelse return;
        const key = token;
        const entry = self.signal_record_descriptor_uses_by_token.getOrPut(allocator, key) catch @panic("out of memory");
        if (entry.found_existing) {
            entry.value_ptr.* += 1;
        } else {
            entry.value_ptr.* = 1;
        }
    }

    fn decrementSignalRecordDescriptorUse(self: *Stream, record: *SignalRecord) void {
        const token = record.token() orelse return;
        const key = token;
        const count = self.signal_record_descriptor_uses_by_token.getPtr(key) orelse @panic("signal token descriptor use underflow");
        if (count.* == 0) @panic("signal token descriptor use underflow");
        count.* -= 1;
        if (count.* != 0) return;

        _ = self.signal_record_descriptor_uses_by_token.fetchRemove(key) orelse @panic("signal token descriptor use disappeared during removal");
        const existing = self.signal_records_by_token.get(key) orelse @panic("signal token descriptor use had no record");
        if (existing != record) @panic("signal token descriptor use pointed at the wrong record");
        _ = self.signal_records_by_token.fetchRemove(key) orelse @panic("signal token record disappeared during removal");
    }

    /// Maintains remember signal record tree within the indexed descriptor stream used by both hosts.
    pub fn rememberSignalRecordTree(self: *Stream, allocator: std.mem.Allocator, record: *SignalRecord) void {
        const Context = struct {
            stream: *Stream,
            allocator: std.mem.Allocator,

            fn visit(ctx: @This(), current: *SignalRecord) void {
                ctx.stream.rememberSignalRecord(ctx.allocator, current);
                ctx.stream.incrementSignalRecordDescriptorUse(ctx.allocator, current);
            }
        };
        signal_records.walkTree(Context, .{ .stream = self, .allocator = allocator }, record, Context.visit);
    }

    /// Maintains forget signal record tree within the indexed descriptor stream used by both hosts.
    pub fn forgetSignalRecordTree(self: *Stream, record: *SignalRecord) void {
        const Context = struct {
            stream: *Stream,

            fn visit(ctx: @This(), current: *SignalRecord) void {
                ctx.stream.decrementSignalRecordDescriptorUse(current);
            }
        };
        signal_records.walkTree(Context, .{ .stream = self }, record, Context.visit);
    }

    /// Appends element using capacity that must already satisfy the caller's transaction contract.
    pub fn appendElement(self: *Stream, allocator: std.mem.Allocator, elem_id: ElemId, parent_elem_id: ElemId, scope_id: ScopeId, tag: []const u8) ElemId {
        self.reserveScopeDescriptorOwnership(allocator, scope_id, 1, 0) catch @panic("out of memory");
        const result = appendElementImpl(Stream, self, allocator, elem_id, parent_elem_id, scope_id, tag);
        self.recordScopeElemAssumeCapacity(scope_id, elem_id);
        return result;
    }

    /// Appends text node using capacity that must already satisfy the caller's transaction contract.
    pub fn appendTextNode(self: *Stream, allocator: std.mem.Allocator, elem_id: ElemId, parent_elem_id: ElemId, scope_id: ScopeId, value: []const u8) void {
        self.reserveScopeDescriptorOwnership(allocator, scope_id, 1, 0) catch @panic("out of memory");
        appendTextNodeImpl(Stream, self, allocator, elem_id, parent_elem_id, scope_id, value);
        self.recordScopeElemAssumeCapacity(scope_id, elem_id);
    }

    pub const PreparedStaticNode = union(enum) {
        const Payload = struct { elem_id: ElemId, parent_elem_id: ElemId, scope_id: ScopeId, text: []u8 };
        element: Payload,
        text: Payload,

        /// Drops provisional resources and restores the plan to an unpublished state.
        pub fn abort(self: @This(), allocator: std.mem.Allocator) void {
            switch (self) {
                inline else => |prepared| allocator.free(prepared.text),
            }
        }
    };

    /// Reserves every container touched by a batch of prepared static nodes.
    /// Logical stream state is unchanged; callers may then prepare strings and
    /// publish the whole batch without allocating during publication.
    pub fn reservePreparedStaticNodes(self: *Stream, allocator: std.mem.Allocator, additional: usize, highest_elem_id: u64) ReserveError!void {
        try self.render_nodes.ensureUnusedCapacity(allocator, additional);
        try self.elements.ensureUnusedCapacity(allocator, additional);
        try self.text_nodes.ensureUnusedCapacity(allocator, additional);
        const highest_index = std.math.cast(usize, highest_elem_id) orelse return error.ResourceLimit;
        const descriptor_len = std.math.add(usize, highest_index, 1) catch return error.ResourceLimit;
        if (descriptor_len > self.descriptor_indexes_by_elem_id.items.len) {
            try self.descriptor_indexes_by_elem_id.ensureTotalCapacity(allocator, descriptor_len);
        }
        const metadata_entries = std.math.mul(usize, additional, 2) catch return error.ResourceLimit;
        try self.render_metadata_by_elem_id.ensureUnusedCapacity(allocator, @intCast(metadata_entries));
    }

    pub const PreparedStaticAttr = union(enum) {
        text: struct { elem_id: ElemId, field: TextField, value: []u8 },
        boolean: struct { elem_id: ElemId, field: BoolField, value: bool },
        custom_text: struct { elem_id: ElemId, name: []u8, value: []u8 },
        custom_boolean: struct { elem_id: ElemId, name: []u8, value: bool },

        /// Drops provisional resources and restores the plan to an unpublished state.
        pub fn abort(self: @This(), allocator: std.mem.Allocator) void {
            switch (self) {
                .text => |prepared| allocator.free(prepared.value),
                .boolean => {},
                .custom_text => |prepared| {
                    allocator.free(prepared.name);
                    allocator.free(prepared.value);
                },
                .custom_boolean => |prepared| allocator.free(prepared.name),
            }
        }
    };

    /// Owns a fully retained dynamic descriptor until transactional
    /// publication transfers it into the stream. Aborting releases the
    /// binding, cached value, and read callable exactly as a published
    /// descriptor would during stream teardown.
    pub const PreparedSignalDescriptor = union(enum) {
        text_node: StreamSignalTextNodeDesc,
        text_attr: SignalTextAttrDesc,
        bool_attr: SignalBoolAttrDesc,
        custom_text_attr: SignalCustomTextAttrDesc,
        optional_custom_text_attr: SignalOptionalCustomTextAttrDesc,
        custom_bool_attr: SignalCustomBoolAttrDesc,

        /// Drops provisional resources and restores the plan to an unpublished state.
        pub fn abort(self: *@This(), allocator: std.mem.Allocator, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype) void {
            switch (self.*) {
                .text_node => |*desc| desc.deinit(allocator, ctx, roc_host, metrics),
                .text_attr => |*desc| desc.deinit(allocator, ctx, roc_host, metrics),
                .bool_attr => |*desc| desc.deinit(allocator, ctx, roc_host, metrics),
                .custom_text_attr => |*desc| desc.deinit(allocator, ctx, roc_host, metrics),
                .optional_custom_text_attr => |*desc| desc.deinit(allocator, ctx, roc_host, metrics),
                .custom_bool_attr => |*desc| desc.deinit(allocator, ctx, roc_host, metrics),
            }
        }
    };

    /// Owns a lifecycle descriptor until an allocation-free transaction commit transfers it.
    pub const PreparedLifecycleDescriptor = union(enum) {
        on_change: OnChangeDesc,
        mount: MountDesc,
        cleanup: CleanupDesc,

        /// Releases provisional signal, callable, or copied-name ownership on abort.
        pub fn abort(self: *@This(), allocator: std.mem.Allocator, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype) void {
            switch (self.*) {
                .on_change => |*desc| desc.deinit(allocator, ctx, roc_host, metrics),
                .mount => |desc| desc.deinit(roc_host, metrics),
                .cleanup => |desc| allocator.free(desc.name),
            }
        }
    };

    pub const PreparedEventDescriptor = struct {
        desc: EventDesc,

        /// Drops provisional resources and restores the plan to an unpublished state.
        pub fn abort(self: @This(), allocator: std.mem.Allocator, roc_host: *abi.RocHost, metrics: anytype) void {
            self.desc.deinit(allocator, roc_host, metrics);
        }
    };

    pub const PreparedNamedEventIndexGroup = struct {
        elem_id: ElemId,
        existed: bool,
        event_ordinals: std.ArrayListUnmanaged(usize) = .empty,

        /// Drops provisional resources and restores the plan to an unpublished state.
        pub fn abort(self: *@This(), allocator: std.mem.Allocator) void {
            self.event_ordinals.deinit(allocator);
            self.* = undefined;
        }
    };

    pub const PreparedScopeSite = struct {
        desc: ScopeSiteDesc,

        /// Drops provisional resources and restores the plan to an unpublished state.
        pub fn abort(self: @This(), allocator: std.mem.Allocator) void {
            allocator.free(self.desc.binder_bindings);
        }
    };

    pub const PreparedState = struct {
        desc: StateDesc,

        /// Drops provisional resources and restores the plan to an unpublished state.
        pub fn abort(self: @This(), roc_host: *abi.RocHost, metrics: anytype) void {
            self.desc.deinit(roc_host, metrics);
        }
    };

    pub const PreparedWhen = struct {
        desc: WhenDesc,

        /// Drops provisional resources and restores the plan to an unpublished state.
        pub fn abort(self: *@This(), allocator: std.mem.Allocator, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype) void {
            self.desc.deinit(allocator, ctx, roc_host, metrics);
        }
    };

    pub const PreparedEach = struct {
        desc: EachDesc,

        /// Drops provisional keyed-list descriptor ownership before publication.
        pub fn abort(self: *@This(), allocator: std.mem.Allocator, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype) void {
            self.desc.deinit(allocator, ctx, roc_host, metrics);
        }
    };

    /// Reserves keyed-list descriptor and node-index storage for allocation-free publication.
    pub fn reservePreparedEaches(self: *Stream, allocator: std.mem.Allocator, additional: usize, highest_node_id: u64) ReserveError!void {
        try self.eaches.ensureUnusedCapacity(allocator, additional);
        const highest_index = std.math.cast(usize, highest_node_id) orelse return error.ResourceLimit;
        const descriptor_len = std.math.add(usize, highest_index, 1) catch return error.ResourceLimit;
        if (descriptor_len > self.descriptor_indexes_by_node_id.items.len) try self.descriptor_indexes_by_node_id.ensureTotalCapacity(allocator, descriptor_len);
    }

    /// Retains one keyed-list descriptor in preparation-owned storage.
    pub fn prepareEach(_: *const Stream, node_id: NodeId, items: HostSignalBinding, ops: HostEachOps, metrics: anytype) PreparedEach {
        return .{ .desc = .{
            .node_id = node_id,
            .items = items,
            .ops = retainHostEachOps(ops, metrics),
        } };
    }

    /// Publishes one fully prepared keyed-list descriptor without allocation.
    pub fn appendPreparedEach(self: *Stream, prepared: PreparedEach) void {
        const node_id = prepared.desc.node_id;
        while (self.descriptor_indexes_by_node_id.items.len <= node_id.index()) self.descriptor_indexes_by_node_id.appendAssumeCapacity(.{});
        const each_index = self.eaches.items.len;
        self.eaches.appendAssumeCapacity(prepared.desc);
        setFreshIndex(&self.descriptor_indexes_by_node_id.items[node_id.index()].each, each_index);
    }

    /// Maintains reserve prepared whens within the indexed descriptor stream used by both hosts.
    pub fn reservePreparedWhens(self: *Stream, allocator: std.mem.Allocator, additional: usize, highest_node_id: u64) ReserveError!void {
        try self.whens.ensureUnusedCapacity(allocator, additional);
        const highest_index = std.math.cast(usize, highest_node_id) orelse return error.ResourceLimit;
        const descriptor_len = std.math.add(usize, highest_index, 1) catch return error.ResourceLimit;
        if (descriptor_len > self.descriptor_indexes_by_node_id.items.len) try self.descriptor_indexes_by_node_id.ensureTotalCapacity(allocator, descriptor_len);
    }

    /// Maintains prepare when within the indexed descriptor stream used by both hosts.
    pub fn prepareWhen(_: *const Stream, node_id: NodeId, condition: HostSignalBinding, ops: retained.HostWhenOps, metrics: anytype) PreparedWhen {
        return .{ .desc = .{
            .node_id = node_id,
            .condition = condition,
            .ops = retained.retainHostWhenOps(ops, metrics),
        } };
    }

    /// Appends prepared when using capacity that must already satisfy the caller's transaction contract.
    pub fn appendPreparedWhen(self: *Stream, prepared: PreparedWhen) void {
        const node_id = prepared.desc.node_id;
        while (self.descriptor_indexes_by_node_id.items.len <= node_id.index()) self.descriptor_indexes_by_node_id.appendAssumeCapacity(.{});
        const index = self.whens.items.len;
        self.whens.appendAssumeCapacity(prepared.desc);
        setFreshIndex(&self.descriptor_indexes_by_node_id.items[node_id.index()].when, index);
    }

    /// Maintains reserve prepared state sites within the indexed descriptor stream used by both hosts.
    pub fn reservePreparedStateSites(self: *Stream, allocator: std.mem.Allocator, additional: usize, highest_node_id: u64) ReserveError!void {
        try self.scope_sites.ensureUnusedCapacity(allocator, additional);
        try self.states.ensureUnusedCapacity(allocator, additional);
        const highest_index = std.math.cast(usize, highest_node_id) orelse return error.ResourceLimit;
        const descriptor_len = std.math.add(usize, highest_index, 1) catch return error.ResourceLimit;
        if (descriptor_len > self.descriptor_indexes_by_node_id.items.len) try self.descriptor_indexes_by_node_id.ensureTotalCapacity(allocator, descriptor_len);
    }

    /// Maintains prepare scope site within the indexed descriptor stream used by both hosts.
    pub fn prepareScopeSite(self: *Stream, allocator: std.mem.Allocator, node_id: NodeId, scope_id: ScopeId, ordinal: SiteOrdinal, parent_elem_id: ElemId, kind: ScopeSiteKind, binder_bindings: []const BinderBinding) ReserveError!PreparedScopeSite {
        return .{ .desc = .{
            .node_id = node_id,
            .scope_id = scope_id,
            .ordinal = ordinal,
            .parent_elem_id = parent_elem_id,
            .render_insert_index = self.render_nodes.items.len,
            .kind = kind,
            .binder_bindings = try allocator.dupe(BinderBinding, binder_bindings),
        } };
    }

    /// Maintains prepare state within the indexed descriptor stream used by both hosts.
    pub fn prepareState(_: *const Stream, node_id: NodeId, initial: roles.Initializer, cap: HostValueCapability, metrics: anytype) PreparedState {
        _ = retainHostValueCapability(cap, metrics);
        abi.increfErasedCallable(initial.toAbi(), 1);
        metrics.bump(.closure_retains, 1);
        return .{ .desc = .{ .node_id = node_id, .initial = initial, .cap = cap } };
    }

    /// Appends prepared state site using capacity that must already satisfy the caller's transaction contract.
    pub fn appendPreparedStateSite(self: *Stream, site: PreparedScopeSite, state: PreparedState) void {
        const node_id = site.desc.node_id;
        if (state.desc.node_id != node_id or site.desc.kind != .state) @panic("prepared state site mismatch");
        self.appendPreparedScopeSite(site);
        self.appendPreparedState(state);
    }

    /// Appends prepared state using capacity that must already satisfy the caller's transaction contract.
    pub fn appendPreparedState(self: *Stream, state: PreparedState) void {
        const node_id = state.desc.node_id;
        const state_index = self.states.items.len;
        self.states.appendAssumeCapacity(state.desc);
        setFreshIndex(&self.descriptor_indexes_by_node_id.items[node_id.index()].state, state_index);
    }

    /// Appends prepared scope site using capacity that must already satisfy the caller's transaction contract.
    pub fn appendPreparedScopeSite(self: *Stream, site: PreparedScopeSite) void {
        const node_id = site.desc.node_id;
        while (self.descriptor_indexes_by_node_id.items.len <= node_id.index()) self.descriptor_indexes_by_node_id.appendAssumeCapacity(.{});
        const site_index = self.scope_sites.items.len;
        self.scope_sites.appendAssumeCapacity(site.desc);
        setFreshIndex(self.descriptor_indexes_by_node_id.items[node_id.index()].scope_sites.slot(site.desc.kind), site_index);
        self.recordScopeNodeAssumeCapacity(site.desc.scope_id, node_id);
    }

    /// Maintains reserve prepared events within the indexed descriptor stream used by both hosts.
    pub fn reservePreparedEvents(self: *Stream, allocator: std.mem.Allocator, additional: usize, highest_elem_id: u64) ReserveError!void {
        try self.events.ensureUnusedCapacity(allocator, additional);
        const highest_index = std.math.cast(usize, highest_elem_id) orelse return error.ResourceLimit;
        const descriptor_len = std.math.add(usize, highest_index, 1) catch return error.ResourceLimit;
        if (descriptor_len > self.descriptor_indexes_by_elem_id.items.len) try self.descriptor_indexes_by_elem_id.ensureTotalCapacity(allocator, descriptor_len);
        if (descriptor_len > self.named_event_indices_by_elem_id.items.len) try self.named_event_indices_by_elem_id.ensureTotalCapacity(allocator, descriptor_len);
    }

    /// Maintains named event index slot exists within the indexed descriptor stream used by both hosts.
    pub fn namedEventIndexSlotExists(self: *const Stream, elem_id: u64) bool {
        return elem_id < self.named_event_indices_by_elem_id.items.len;
    }

    /// Maintains reserve existing named event indexes within the indexed descriptor stream used by both hosts.
    pub fn reserveExistingNamedEventIndexes(self: *Stream, allocator: std.mem.Allocator, elem_id: u64, additional: usize) ReserveError!void {
        if (!self.namedEventIndexSlotExists(elem_id)) return;
        const slot = &self.named_event_indices_by_elem_id.items[@intCast(elem_id)];
        const total = std.math.add(usize, slot.items.len, additional) catch return error.ResourceLimit;
        try slot.ensureTotalCapacity(allocator, total);
    }

    /// Appends prepared event using capacity that must already satisfy the caller's transaction contract.
    pub fn appendPreparedEvent(self: *Stream, prepared: PreparedEventDescriptor) void {
        const desc = prepared.desc;
        while (self.descriptor_indexes_by_elem_id.items.len <= desc.elem_id.index()) self.descriptor_indexes_by_elem_id.appendAssumeCapacity(.{});
        const index = self.events.items.len;
        self.events.appendAssumeCapacity(desc);
        if (desc.fixedKind()) |kind| setFreshIndex(self.descriptor_indexes_by_elem_id.items[desc.elem_id.index()].events.slot(kind), index);
    }

    /// Publishes prepared named event indexes during the allocation-free commit phase.
    pub fn publishPreparedNamedEventIndexes(self: *Stream, groups: []PreparedNamedEventIndexGroup, event_base: usize) void {
        for (groups) |*group| {
            while (self.named_event_indices_by_elem_id.items.len <= group.elem_id.index()) self.named_event_indices_by_elem_id.appendAssumeCapacity(.empty);
            const slot = &self.named_event_indices_by_elem_id.items[group.elem_id.index()];
            for (group.event_ordinals.items) |*ordinal| ordinal.* += event_base;
            if (group.existed) {
                slot.appendSliceAssumeCapacity(group.event_ordinals.items);
                group.event_ordinals.clearRetainingCapacity();
            } else {
                if (slot.items.len != 0 or slot.capacity != 0) @panic("new named event index slot was already initialized");
                slot.* = group.event_ordinals;
                group.event_ordinals = .empty;
            }
        }
    }

    /// Maintains reserve prepared signal text nodes within the indexed descriptor stream used by both hosts.
    pub fn reservePreparedSignalTextNodes(self: *Stream, allocator: std.mem.Allocator, additional: usize, highest_elem_id: u64) ReserveError!void {
        try self.render_nodes.ensureUnusedCapacity(allocator, additional);
        try self.signal_text_nodes.ensureUnusedCapacity(allocator, additional);
        const highest_index = std.math.cast(usize, highest_elem_id) orelse return error.ResourceLimit;
        const descriptor_len = std.math.add(usize, highest_index, 1) catch return error.ResourceLimit;
        if (descriptor_len > self.descriptor_indexes_by_elem_id.items.len) try self.descriptor_indexes_by_elem_id.ensureTotalCapacity(allocator, descriptor_len);
        const metadata_entries = std.math.mul(usize, additional, 2) catch return error.ResourceLimit;
        try self.render_metadata_by_elem_id.ensureUnusedCapacity(allocator, @intCast(metadata_entries));
    }

    /// Maintains reserve prepared signal attrs within the indexed descriptor stream used by both hosts.
    pub fn reservePreparedSignalAttrs(self: *Stream, allocator: std.mem.Allocator, additional: usize, highest_elem_id: u64) ReserveError!void {
        try self.signal_text_attrs.ensureUnusedCapacity(allocator, additional);
        try self.signal_bool_attrs.ensureUnusedCapacity(allocator, additional);
        try self.signal_custom_text_attrs.ensureUnusedCapacity(allocator, additional);
        try self.signal_optional_custom_text_attrs.ensureUnusedCapacity(allocator, additional);
        try self.signal_custom_bool_attrs.ensureUnusedCapacity(allocator, additional);
        const descriptor_len = std.math.add(usize, @as(usize, @intCast(highest_elem_id)), 1) catch return error.ResourceLimit;
        if (descriptor_len > self.descriptor_indexes_by_elem_id.items.len) {
            try self.descriptor_indexes_by_elem_id.ensureTotalCapacity(allocator, descriptor_len);
        }
    }

    /// Publishes a prepared fixed signal attribute using capacity reserved by
    /// `reservePreparedSignalAttrs`. Ownership transfers to the stream.
    pub fn appendPreparedSignalDescriptor(self: *Stream, prepared: PreparedSignalDescriptor) void {
        const elem_id = switch (prepared) {
            inline else => |desc| desc.elem_id,
        };
        while (self.descriptor_indexes_by_elem_id.items.len <= elem_id.index()) {
            self.descriptor_indexes_by_elem_id.appendAssumeCapacity(.{});
        }
        const descriptor = &self.descriptor_indexes_by_elem_id.items[elem_id.index()];
        switch (prepared) {
            .text_node => |desc| {
                const render_index = self.render_nodes.items.len;
                const index = self.signal_text_nodes.items.len;
                self.render_nodes.appendAssumeCapacity(.{ .elem_id = desc.elem_id, .kind = .signal_text });
                self.signal_text_nodes.appendAssumeCapacity(desc);
                setFreshIndex(&descriptor.signal_text_node, index);
                const elem_entry = self.render_metadata_by_elem_id.getOrPutAssumeCapacity(desc.elem_id.raw());
                if (!elem_entry.found_existing) elem_entry.value_ptr.* = .{};
                elem_entry.value_ptr.render_node = render_index;
                const parent_entry = self.render_metadata_by_elem_id.getOrPutAssumeCapacity(desc.parent_elem_id.raw());
                if (!parent_entry.found_existing) parent_entry.value_ptr.* = .{};
                const last = parent_entry.value_ptr.last_child;
                elem_entry.value_ptr.previous_sibling = last;
                elem_entry.value_ptr.next_sibling = null;
                if (last) |last_child| {
                    self.render_metadata_by_elem_id.getPtr(last_child.raw()).?.next_sibling = desc.elem_id;
                } else {
                    parent_entry.value_ptr.first_child = desc.elem_id;
                }
                parent_entry.value_ptr.last_child = desc.elem_id;
                self.recordScopeElemAssumeCapacity(desc.scope_id, desc.elem_id);
                self.next_elem_id += 1;
            },
            .text_attr => |desc| {
                const index = self.signal_text_attrs.items.len;
                self.signal_text_attrs.appendAssumeCapacity(desc);
                setFreshIndex(descriptor.signal_text_attrs.slot(desc.field), index);
            },
            .bool_attr => |desc| {
                const index = self.signal_bool_attrs.items.len;
                self.signal_bool_attrs.appendAssumeCapacity(desc);
                setFreshIndex(descriptor.signal_bool_attrs.slot(desc.field), index);
            },
            .custom_text_attr => |desc| {
                const index = self.signal_custom_text_attrs.items.len;
                self.signal_custom_text_attrs.appendAssumeCapacity(desc);
                self.recordPreparedCustomAttrIndex(desc.elem_id, desc.name, .{ .kind = .signal_text, .index = index });
            },
            .optional_custom_text_attr => |desc| {
                const index = self.signal_optional_custom_text_attrs.items.len;
                self.signal_optional_custom_text_attrs.appendAssumeCapacity(desc);
                self.recordPreparedCustomAttrIndex(desc.elem_id, desc.name, .{ .kind = .signal_text_optional, .index = index });
            },
            .custom_bool_attr => |desc| {
                const index = self.signal_custom_bool_attrs.items.len;
                self.signal_custom_bool_attrs.appendAssumeCapacity(desc);
                self.recordPreparedCustomAttrIndex(desc.elem_id, desc.name, .{ .kind = .signal_bool, .index = index });
            },
        }
    }

    /// Maintains reserve prepared static attrs within the indexed descriptor stream used by both hosts.
    pub fn reservePreparedStaticAttrs(self: *Stream, allocator: std.mem.Allocator, additional: usize) std.mem.Allocator.Error!void {
        try self.static_text_attrs.ensureUnusedCapacity(allocator, additional);
        try self.static_bool_attrs.ensureUnusedCapacity(allocator, additional);
        try self.static_custom_text_attrs.ensureUnusedCapacity(allocator, additional);
        try self.static_custom_bool_attrs.ensureUnusedCapacity(allocator, additional);
    }

    /// Maintains prepare static text attr within the indexed descriptor stream used by both hosts.
    pub fn prepareStaticTextAttr(_: *Stream, allocator: std.mem.Allocator, elem_id: ElemId, field: TextField, value: []const u8) std.mem.Allocator.Error!PreparedStaticAttr {
        return .{ .text = .{ .elem_id = elem_id, .field = field, .value = try allocator.dupe(u8, value) } };
    }

    /// Maintains prepare static bool attr within the indexed descriptor stream used by both hosts.
    pub fn prepareStaticBoolAttr(_: *Stream, elem_id: ElemId, field: BoolField, value: bool) PreparedStaticAttr {
        return .{ .boolean = .{ .elem_id = elem_id, .field = field, .value = value } };
    }

    /// Maintains prepare static custom text attr within the indexed descriptor stream used by both hosts.
    pub fn prepareStaticCustomTextAttr(_: *Stream, allocator: std.mem.Allocator, elem_id: ElemId, name: []const u8, value: []const u8) std.mem.Allocator.Error!PreparedStaticAttr {
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        return .{ .custom_text = .{ .elem_id = elem_id, .name = name_copy, .value = try allocator.dupe(u8, value) } };
    }

    /// Maintains prepare static custom bool attr within the indexed descriptor stream used by both hosts.
    pub fn prepareStaticCustomBoolAttr(_: *Stream, allocator: std.mem.Allocator, elem_id: ElemId, name: []const u8, value: bool) std.mem.Allocator.Error!PreparedStaticAttr {
        return .{ .custom_boolean = .{ .elem_id = elem_id, .name = try allocator.dupe(u8, name), .value = value } };
    }

    /// Reserves authoritative custom descriptor index publication.
    pub fn reservePreparedCustomAttrIndex(self: *Stream, allocator: std.mem.Allocator, additional: usize) ReserveError!void {
        try tryActivateCustomAttrIndex(Stream, self, allocator);
        try self.custom_attr_keys.ensureUnusedCapacity(allocator, @intCast(additional));
    }

    /// Reserves a conservative number of ownership entries for one element without changing
    /// the committed index if allocation fails. Callers may reserve the whole transaction's
    /// custom-attribute bound when its exact per-element distribution is not yet known.
    pub fn reservePreparedCustomAttrElem(self: *Stream, allocator: std.mem.Allocator, elem_id: u64, additional: usize) ReserveError!void {
        if (additional == 0) return;
        const elem_index = std.math.cast(usize, elem_id) orelse return error.ResourceLimit;
        const required = std.math.add(usize, elem_index, 1) catch return error.ResourceLimit;
        if (elem_index < self.custom_attr_indices_by_elem_id.items.len) {
            try self.custom_attr_indices_by_elem_id.items[elem_index].ensureUnusedCapacity(allocator, additional);
            return;
        }
        var prepared_indexes: std.ArrayListUnmanaged(CustomAttrDescriptorIndex) = .empty;
        errdefer prepared_indexes.deinit(allocator);
        try prepared_indexes.ensureUnusedCapacity(allocator, additional);
        try self.custom_attr_indices_by_elem_id.ensureTotalCapacity(allocator, required);
        while (self.custom_attr_indices_by_elem_id.items.len < elem_index) self.custom_attr_indices_by_elem_id.appendAssumeCapacity(.empty);
        self.custom_attr_indices_by_elem_id.appendAssumeCapacity(prepared_indexes);
    }

    /// Reserves exactly one element-local index slot for one custom attribute
    /// descriptor being collected. Collection must use this narrow operation:
    /// reserving a transaction-wide bound in every element's private list
    /// makes preparation quadratic in the number of attributes.
    pub fn reservePreparedCustomAttrEntry(self: *Stream, allocator: std.mem.Allocator, elem_id: u64) ReserveError!void {
        try self.reservePreparedCustomAttrElem(allocator, elem_id, 1);
    }

    fn recordPreparedCustomAttrIndex(self: *Stream, elem_id: ElemId, name: []const u8, index: CustomAttrDescriptorIndex) void {
        // Reservations are fallible preparation; the maintained index only
        // becomes authoritative when an entry is published allocation-free.
        self.custom_attr_index_active = true;
        self.custom_attr_keys.putAssumeCapacity(.{ .elem_id = elem_id, .name = name }, index);
        self.custom_attr_indices_by_elem_id.items[elem_id.index()].appendAssumeCapacity(index);
    }

    /// Appends prepared static attr using capacity that must already satisfy the caller's transaction contract.
    pub fn appendPreparedStaticAttr(self: *Stream, prepared: PreparedStaticAttr) void {
        switch (prepared) {
            .text => |value| {
                const index = self.static_text_attrs.items.len;
                self.static_text_attrs.appendAssumeCapacity(.{ .elem_id = value.elem_id, .field = value.field, .value = value.value });
                setFreshIndex(self.descriptor_indexes_by_elem_id.items[value.elem_id.index()].static_text_attrs.slot(value.field), index);
            },
            .boolean => |value| {
                const index = self.static_bool_attrs.items.len;
                self.static_bool_attrs.appendAssumeCapacity(.{ .elem_id = value.elem_id, .field = value.field, .value = value.value });
                setFreshIndex(self.descriptor_indexes_by_elem_id.items[value.elem_id.index()].static_bool_attrs.slot(value.field), index);
            },
            .custom_text => |value| {
                const index = self.static_custom_text_attrs.items.len;
                self.static_custom_text_attrs.appendAssumeCapacity(.{ .elem_id = value.elem_id, .name = value.name, .value = value.value });
                self.recordPreparedCustomAttrIndex(value.elem_id, value.name, .{ .kind = .static_text, .index = index });
            },
            .custom_boolean => |value| {
                const index = self.static_custom_bool_attrs.items.len;
                self.static_custom_bool_attrs.appendAssumeCapacity(.{ .elem_id = value.elem_id, .name = value.name, .value = value.value });
                self.recordPreparedCustomAttrIndex(value.elem_id, value.name, .{ .kind = .static_bool, .index = index });
            },
        }
    }

    fn prepareStaticNode(self: *Stream, allocator: std.mem.Allocator, elem_id: ElemId, parent_elem_id: ElemId, scope_id: ScopeId, text: []const u8, kind: RenderNodeKind) ReserveError!PreparedStaticNode {
        _ = std.math.add(u64, self.next_elem_id, 1) catch return error.ResourceLimit;
        const copy = try allocator.dupe(u8, text);
        errdefer allocator.free(copy);
        try self.render_nodes.ensureUnusedCapacity(allocator, 1);
        switch (kind) {
            .element => try self.elements.ensureUnusedCapacity(allocator, 1),
            .text => try self.text_nodes.ensureUnusedCapacity(allocator, 1),
            .signal_text => unreachable,
        }
        const descriptor_len = std.math.add(usize, elem_id.index(), 1) catch return error.ResourceLimit;
        if (descriptor_len > self.descriptor_indexes_by_elem_id.items.len) {
            try self.descriptor_indexes_by_elem_id.ensureTotalCapacity(allocator, descriptor_len);
        }
        try self.render_metadata_by_elem_id.ensureUnusedCapacity(allocator, 2);
        return switch (kind) {
            .element => .{ .element = .{ .elem_id = elem_id, .parent_elem_id = parent_elem_id, .scope_id = scope_id, .text = copy } },
            .text => .{ .text = .{ .elem_id = elem_id, .parent_elem_id = parent_elem_id, .scope_id = scope_id, .text = copy } },
            .signal_text => unreachable,
        };
    }

    /// Maintains prepare element within the indexed descriptor stream used by both hosts.
    pub fn prepareElement(self: *Stream, allocator: std.mem.Allocator, elem_id: ElemId, parent_elem_id: ElemId, scope_id: ScopeId, tag: []const u8) ReserveError!PreparedStaticNode {
        return self.prepareStaticNode(allocator, elem_id, parent_elem_id, scope_id, tag, .element);
    }

    /// Maintains prepare text node within the indexed descriptor stream used by both hosts.
    pub fn prepareTextNode(self: *Stream, allocator: std.mem.Allocator, elem_id: ElemId, parent_elem_id: ElemId, scope_id: ScopeId, value: []const u8) ReserveError!PreparedStaticNode {
        return self.prepareStaticNode(allocator, elem_id, parent_elem_id, scope_id, value, .text);
    }

    /// Appends prepared static node using capacity that must already satisfy the caller's transaction contract.
    pub fn appendPreparedStaticNode(self: *Stream, prepared_node: PreparedStaticNode) void {
        const prepared = switch (prepared_node) {
            inline else => |value| value,
        };
        while (self.descriptor_indexes_by_elem_id.items.len <= prepared.elem_id.index()) {
            self.descriptor_indexes_by_elem_id.appendAssumeCapacity(.{});
        }
        const render_index = self.render_nodes.items.len;
        self.render_nodes.appendAssumeCapacity(.{ .elem_id = prepared.elem_id, .kind = switch (prepared_node) {
            .element => .element,
            .text => .text,
        } });
        const descriptor = &self.descriptor_indexes_by_elem_id.items[prepared.elem_id.index()];
        switch (prepared_node) {
            .element => {
                const index = self.elements.items.len;
                self.elements.appendAssumeCapacity(.{ .elem_id = prepared.elem_id, .parent_elem_id = prepared.parent_elem_id, .scope_id = prepared.scope_id, .tag = prepared.text });
                setFreshIndex(&descriptor.element, index);
            },
            .text => {
                const index = self.text_nodes.items.len;
                self.text_nodes.appendAssumeCapacity(.{ .elem_id = prepared.elem_id, .parent_elem_id = prepared.parent_elem_id, .scope_id = prepared.scope_id, .value = prepared.text });
                setFreshIndex(&descriptor.text_node, index);
            },
        }
        const elem_entry = self.render_metadata_by_elem_id.getOrPutAssumeCapacity(prepared.elem_id.raw());
        if (!elem_entry.found_existing) elem_entry.value_ptr.* = .{};
        elem_entry.value_ptr.render_node = render_index;
        const parent_entry = self.render_metadata_by_elem_id.getOrPutAssumeCapacity(prepared.parent_elem_id.raw());
        if (!parent_entry.found_existing) parent_entry.value_ptr.* = .{};
        const last = parent_entry.value_ptr.last_child;
        elem_entry.value_ptr.previous_sibling = last;
        elem_entry.value_ptr.next_sibling = null;
        if (last) |last_child| {
            self.render_metadata_by_elem_id.getPtr(last_child.raw()).?.next_sibling = prepared.elem_id;
        } else {
            parent_entry.value_ptr.first_child = prepared.elem_id;
        }
        parent_entry.value_ptr.last_child = prepared.elem_id;
        self.recordScopeElemAssumeCapacity(prepared.scope_id, prepared.elem_id);
        self.next_elem_id += 1;
    }

    /// Appends signal text node using capacity that must already satisfy the caller's transaction contract.
    pub fn appendSignalTextNode(self: *Stream, allocator: std.mem.Allocator, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype, elem_id: ElemId, parent_elem_id: ElemId, scope_id: ScopeId, signal: HostSignalBinding, read: HostTextRead) void {
        self.reserveScopeDescriptorOwnership(allocator, scope_id, 1, 0) catch @panic("out of memory");
        self.next_elem_id += 1;
        self.rememberSignalRecordTree(allocator, signal.record);
        const retained_read = retainHostTextRead(read, metrics);
        const signal_text_node_index = self.signal_text_nodes.items.len;
        const render_index = self.render_nodes.items.len;

        self.render_nodes.append(allocator, .{ .elem_id = elem_id, .kind = .signal_text }) catch {
            rollbackSignalTextAppend(signal, retained_read, allocator, ctx, roc_host, metrics);
            @panic("out of memory");
        };
        self.signal_text_nodes.append(allocator, .{
            .elem_id = elem_id,
            .parent_elem_id = parent_elem_id,
            .scope_id = scope_id,
            .signal = signal,
            .read = retained_read,
        }) catch {
            rollbackSignalTextAppend(signal, retained_read, allocator, ctx, roc_host, metrics);
            @panic("out of memory");
        };
        self.recordSignalTextNodeIndex(allocator, elem_id.raw(), signal_text_node_index);
        self.recordRenderNodeIndex(allocator, elem_id, render_index);
        self.appendRenderChild(allocator, parent_elem_id, elem_id);
        self.recordScopeElemAssumeCapacity(scope_id, elem_id);
    }

    /// Appends static text attr using capacity that must already satisfy the caller's transaction contract.
    pub fn appendStaticTextAttr(self: *Stream, allocator: std.mem.Allocator, elem_id: ElemId, field: TextField, value: []const u8) void {
        appendStaticTextAttrImpl(Stream, self, allocator, elem_id, field, value);
    }

    /// Appends signal text attr using capacity that must already satisfy the caller's transaction contract.
    pub fn appendSignalTextAttr(self: *Stream, allocator: std.mem.Allocator, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype, elem_id: ElemId, field: TextField, signal: HostSignalBinding, read: HostTextRead) void {
        self.rememberSignalRecordTree(allocator, signal.record);
        const retained_read = retainHostTextRead(read, metrics);
        const attr_index = self.signal_text_attrs.items.len;
        self.signal_text_attrs.append(allocator, .{
            .elem_id = elem_id,
            .field = field,
            .signal = signal,
            .read = retained_read,
        }) catch {
            rollbackSignalTextAppend(signal, retained_read, allocator, ctx, roc_host, metrics);
            @panic("out of memory");
        };
        self.recordSignalTextAttrIndex(allocator, elem_id.raw(), field, attr_index);
    }

    /// Maintains custom text attr descriptor exists within the indexed descriptor stream used by both hosts.
    pub fn customTextAttrDescriptorExists(self: *const Stream, elem_id: ElemId, name: []const u8) bool {
        return customTextAttrDescriptorExistsImpl(Stream, self, elem_id, name);
    }

    /// Resolves a custom attribute to its authoritative family and dense index.
    pub fn customAttrDescriptorIndex(self: *const Stream, elem_id: ElemId, name: []const u8) ?CustomAttrDescriptorIndex {
        if (!self.custom_attr_index_active) return null;
        return self.custom_attr_keys.get(.{ .elem_id = elem_id, .name = name });
    }

    /// Removes one exact custom index before retiring its owned descriptor.
    pub fn removeCustomAttrIndex(self: *Stream, elem_id: u64, name: []const u8, expected: CustomAttrDescriptorIndex) void {
        const removed = self.custom_attr_keys.fetchRemove(.{ .elem_id = ElemId.fromRaw(elem_id), .name = name }) orelse @panic("custom attribute index removal missed its descriptor");
        if (removed.value.kind != expected.kind or removed.value.index != expected.index) @panic("custom attribute index removal mismatched its descriptor");
        if (elem_id >= self.custom_attr_indices_by_elem_id.items.len) @panic("custom attribute per-element removal missed its descriptor");
        var indexes = &self.custom_attr_indices_by_elem_id.items[@intCast(elem_id)];
        for (indexes.items, 0..) |candidate, position| {
            if (candidate.kind == expected.kind and candidate.index == expected.index) {
                _ = indexes.swapRemove(position);
                return;
            }
        }
        @panic("custom attribute per-element removal missed its exact descriptor");
    }

    /// Patches the dense index of a descriptor moved by swap removal.
    pub fn updateCustomAttrIndex(self: *Stream, elem_id: u64, name: []const u8, kind: CustomAttrKind, old_index: usize, new_index: usize) void {
        const index = self.custom_attr_keys.getPtr(.{ .elem_id = ElemId.fromRaw(elem_id), .name = name }) orelse @panic("moved custom attribute missed its index");
        if (index.kind != kind or index.index != old_index) @panic("moved custom attribute index was stale");
        index.index = new_index;
        if (elem_id >= self.custom_attr_indices_by_elem_id.items.len) @panic("moved custom attribute missed its per-element index");
        for (self.custom_attr_indices_by_elem_id.items[@intCast(elem_id)].items) |*candidate| {
            if (candidate.kind == kind and candidate.index == old_index) {
                candidate.index = new_index;
                return;
            }
        }
        @panic("moved custom attribute per-element index was stale");
    }

    /// Returns exact custom descriptors owned by one rendered element.
    pub fn customAttrIndices(self: *const Stream, elem_id: ElemId) []const CustomAttrDescriptorIndex {
        if (!self.custom_attr_index_active or elem_id.index() >= self.custom_attr_indices_by_elem_id.items.len) return &.{};
        return self.custom_attr_indices_by_elem_id.items[elem_id.index()].items;
    }

    fn retireStaticCustomTextAssumeCapacity(self: *Stream, retired: *Stream, indexes: []const usize) void {
        for (indexes) |index| {
            const removed = self.static_custom_text_attrs.swapRemove(index);
            self.removeCustomAttrIndex(removed.elem_id.raw(), removed.name, .{ .kind = .static_text, .index = index });
            const retired_index = retired.static_custom_text_attrs.items.len;
            retired.static_custom_text_attrs.appendAssumeCapacity(removed);
            retired.recordPreparedCustomAttrIndex(removed.elem_id, removed.name, .{ .kind = .static_text, .index = retired_index });
            if (index < self.static_custom_text_attrs.items.len) {
                const moved = self.static_custom_text_attrs.items[index];
                self.updateCustomAttrIndex(moved.elem_id.raw(), moved.name, .static_text, self.static_custom_text_attrs.items.len, index);
            }
        }
    }

    fn retireSignalCustomTextAssumeCapacity(self: *Stream, retired: *Stream, indexes: []const usize) void {
        for (indexes) |index| {
            const removed = self.signal_custom_text_attrs.swapRemove(index);
            self.removeCustomAttrIndex(removed.elem_id.raw(), removed.name, .{ .kind = .signal_text, .index = index });
            self.forgetSignalRecordTree(removed.signal.record);
            retired.rememberSignalRecordTreeAssumeCapacity(removed.signal.record);
            const retired_index = retired.signal_custom_text_attrs.items.len;
            retired.signal_custom_text_attrs.appendAssumeCapacity(removed);
            retired.recordPreparedCustomAttrIndex(removed.elem_id, removed.name, .{ .kind = .signal_text, .index = retired_index });
            if (index < self.signal_custom_text_attrs.items.len) {
                const moved = self.signal_custom_text_attrs.items[index];
                self.updateCustomAttrIndex(moved.elem_id.raw(), moved.name, .signal_text, self.signal_custom_text_attrs.items.len, index);
            }
        }
    }

    fn retireSignalOptionalCustomTextAssumeCapacity(self: *Stream, retired: *Stream, indexes: []const usize) void {
        for (indexes) |index| {
            const removed = self.signal_optional_custom_text_attrs.swapRemove(index);
            self.removeCustomAttrIndex(removed.elem_id.raw(), removed.name, .{ .kind = .signal_text_optional, .index = index });
            self.forgetSignalRecordTree(removed.signal.record);
            retired.rememberSignalRecordTreeAssumeCapacity(removed.signal.record);
            const retired_index = retired.signal_optional_custom_text_attrs.items.len;
            retired.signal_optional_custom_text_attrs.appendAssumeCapacity(removed);
            retired.recordPreparedCustomAttrIndex(removed.elem_id, removed.name, .{ .kind = .signal_text_optional, .index = retired_index });
            if (index < self.signal_optional_custom_text_attrs.items.len) {
                const moved = self.signal_optional_custom_text_attrs.items[index];
                self.updateCustomAttrIndex(moved.elem_id.raw(), moved.name, .signal_text_optional, self.signal_optional_custom_text_attrs.items.len, index);
            }
        }
    }

    fn retireStaticCustomBoolAssumeCapacity(self: *Stream, retired: *Stream, indexes: []const usize) void {
        for (indexes) |index| {
            const removed = self.static_custom_bool_attrs.swapRemove(index);
            self.removeCustomAttrIndex(removed.elem_id.raw(), removed.name, .{ .kind = .static_bool, .index = index });
            const retired_index = retired.static_custom_bool_attrs.items.len;
            retired.static_custom_bool_attrs.appendAssumeCapacity(removed);
            retired.recordPreparedCustomAttrIndex(removed.elem_id, removed.name, .{ .kind = .static_bool, .index = retired_index });
            if (index < self.static_custom_bool_attrs.items.len) {
                const moved = self.static_custom_bool_attrs.items[index];
                self.updateCustomAttrIndex(moved.elem_id.raw(), moved.name, .static_bool, self.static_custom_bool_attrs.items.len, index);
            }
        }
    }

    fn retireSignalCustomBoolAssumeCapacity(self: *Stream, retired: *Stream, indexes: []const usize) void {
        for (indexes) |index| {
            const removed = self.signal_custom_bool_attrs.swapRemove(index);
            self.removeCustomAttrIndex(removed.elem_id.raw(), removed.name, .{ .kind = .signal_bool, .index = index });
            self.forgetSignalRecordTree(removed.signal.record);
            retired.rememberSignalRecordTreeAssumeCapacity(removed.signal.record);
            const retired_index = retired.signal_custom_bool_attrs.items.len;
            retired.signal_custom_bool_attrs.appendAssumeCapacity(removed);
            retired.recordPreparedCustomAttrIndex(removed.elem_id, removed.name, .{ .kind = .signal_bool, .index = retired_index });
            if (index < self.signal_custom_bool_attrs.items.len) {
                const moved = self.signal_custom_bool_attrs.items[index];
                self.updateCustomAttrIndex(moved.elem_id.raw(), moved.name, .signal_bool, self.signal_custom_bool_attrs.items.len, index);
            }
        }
    }

    /// Appends static custom text attr using capacity that must already satisfy the caller's transaction contract.
    pub fn appendStaticCustomTextAttr(self: *Stream, allocator: std.mem.Allocator, elem_id: ElemId, name: []const u8, value: []const u8) void {
        appendStaticCustomTextAttrImpl(Stream, self, allocator, elem_id, name, value);
    }

    /// Appends signal custom text attr using capacity that must already satisfy the caller's transaction contract.
    pub fn appendSignalCustomTextAttr(self: *Stream, allocator: std.mem.Allocator, _: anytype, _: *abi.RocHost, metrics: anytype, elem_id: ElemId, name: []const u8, signal: HostSignalBinding, read: HostTextRead) void {
        if (name.len == 0) @panic("custom text attr descriptor used an empty name");
        if (customAttrDescriptorExistsForAppend(Stream, self, allocator, elem_id.raw(), name)) @panic("element has duplicate custom text attr descriptors");

        const name_copy = allocator.dupe(u8, name) catch @panic("out of memory");
        self.signal_custom_text_attrs.ensureUnusedCapacity(allocator, 1) catch {
            allocator.free(name_copy);
            @panic("out of memory");
        };
        reserveCustomAttrIndexEntry(Stream, self, allocator, elem_id.raw()) catch {
            allocator.free(name_copy);
            @panic("out of memory");
        };
        self.rememberSignalRecordTree(allocator, signal.record);
        const retained_read = retainHostTextRead(read, metrics);
        const index = self.signal_custom_text_attrs.items.len;
        self.signal_custom_text_attrs.appendAssumeCapacity(.{
            .elem_id = elem_id,
            .name = name_copy,
            .signal = signal,
            .read = retained_read,
        });
        recordCustomAttrKeyAssumeCapacity(Stream, self, elem_id.raw(), name_copy, .signal_text, index);
    }

    /// Appends signal optional custom text attr using capacity that must already satisfy the caller's transaction contract.
    pub fn appendSignalOptionalCustomTextAttr(self: *Stream, allocator: std.mem.Allocator, _: anytype, _: *abi.RocHost, metrics: anytype, elem_id: ElemId, name: []const u8, signal: HostSignalBinding, present: HostBoolRead, read: HostTextRead) void {
        if (name.len == 0) @panic("custom text attr descriptor used an empty name");
        if (customAttrDescriptorExistsForAppend(Stream, self, allocator, elem_id.raw(), name)) @panic("element has duplicate custom text attr descriptors");

        const name_copy = allocator.dupe(u8, name) catch @panic("out of memory");
        self.signal_optional_custom_text_attrs.ensureUnusedCapacity(allocator, 1) catch {
            allocator.free(name_copy);
            @panic("out of memory");
        };
        reserveCustomAttrIndexEntry(Stream, self, allocator, elem_id.raw()) catch {
            allocator.free(name_copy);
            @panic("out of memory");
        };
        self.rememberSignalRecordTree(allocator, signal.record);
        const retained_present = retainHostBoolRead(present, metrics);
        const retained_read = retainHostTextRead(read, metrics);
        const index = self.signal_optional_custom_text_attrs.items.len;
        self.signal_optional_custom_text_attrs.appendAssumeCapacity(.{
            .elem_id = elem_id,
            .name = name_copy,
            .signal = signal,
            .present = retained_present,
            .read = retained_read,
        });
        recordCustomAttrKeyAssumeCapacity(Stream, self, elem_id.raw(), name_copy, .signal_text_optional, index);
    }

    /// Appends static custom bool attr using capacity that must already satisfy the caller's transaction contract.
    pub fn appendStaticCustomBoolAttr(self: *Stream, allocator: std.mem.Allocator, elem_id: ElemId, name: []const u8, value: bool) void {
        appendStaticCustomBoolAttrImpl(Stream, self, allocator, elem_id, name, value);
    }

    /// Appends signal custom bool attr using capacity that must already satisfy the caller's transaction contract.
    pub fn appendSignalCustomBoolAttr(self: *Stream, allocator: std.mem.Allocator, _: anytype, _: *abi.RocHost, metrics: anytype, elem_id: ElemId, name: []const u8, signal: HostSignalBinding, read: HostBoolRead) void {
        if (name.len == 0) @panic("custom bool attr descriptor used an empty name");
        if (customAttrDescriptorExistsForAppend(Stream, self, allocator, elem_id.raw(), name)) @panic("element has duplicate custom attr descriptors");

        const name_copy = allocator.dupe(u8, name) catch @panic("out of memory");
        self.signal_custom_bool_attrs.ensureUnusedCapacity(allocator, 1) catch {
            allocator.free(name_copy);
            @panic("out of memory");
        };
        reserveCustomAttrIndexEntry(Stream, self, allocator, elem_id.raw()) catch {
            allocator.free(name_copy);
            @panic("out of memory");
        };
        self.rememberSignalRecordTree(allocator, signal.record);
        const retained_read = retainHostBoolRead(read, metrics);
        const index = self.signal_custom_bool_attrs.items.len;
        self.signal_custom_bool_attrs.appendAssumeCapacity(.{
            .elem_id = elem_id,
            .name = name_copy,
            .signal = signal,
            .read = retained_read,
        });
        recordCustomAttrKeyAssumeCapacity(Stream, self, elem_id.raw(), name_copy, .signal_bool, index);
    }

    /// Appends static bool attr using capacity that must already satisfy the caller's transaction contract.
    pub fn appendStaticBoolAttr(self: *Stream, allocator: std.mem.Allocator, elem_id: ElemId, field: BoolField, value: bool) void {
        appendStaticBoolAttrImpl(Stream, self, allocator, elem_id, field, value);
    }

    /// Appends signal bool attr using capacity that must already satisfy the caller's transaction contract.
    pub fn appendSignalBoolAttr(self: *Stream, allocator: std.mem.Allocator, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype, elem_id: ElemId, field: BoolField, signal: HostSignalBinding, read: HostBoolRead) void {
        self.rememberSignalRecordTree(allocator, signal.record);
        const retained_read = retainHostBoolRead(read, metrics);
        const attr_index = self.signal_bool_attrs.items.len;
        self.signal_bool_attrs.append(allocator, .{
            .elem_id = elem_id,
            .field = field,
            .signal = signal,
            .read = retained_read,
        }) catch {
            rollbackSignalBoolAppend(signal, retained_read, allocator, ctx, roc_host, metrics);
            @panic("out of memory");
        };
        self.recordSignalBoolAttrIndex(allocator, elem_id.raw(), field, attr_index);
    }

    /// Reserves lifecycle ownership entries for a scope without changing its logical index on failure.
    pub fn reserveLifecycleScope(self: *Stream, allocator: std.mem.Allocator, scope_id: ScopeId, additional: usize) ReserveError!void {
        if (additional == 0) return;
        const scope_index = scope_id.index();
        if (scope_index < self.lifecycle_indices_by_scope_id.items.len) {
            try self.lifecycle_indices_by_scope_id.items[scope_index].ensureUnusedCapacity(allocator, additional);
            return;
        }
        const required = std.math.add(usize, scope_index, 1) catch return error.ResourceLimit;
        var prepared: std.ArrayListUnmanaged(LifecycleDescriptorIndex) = .empty;
        errdefer prepared.deinit(allocator);
        try prepared.ensureUnusedCapacity(allocator, additional);
        try self.lifecycle_indices_by_scope_id.ensureTotalCapacity(allocator, required);
        while (self.lifecycle_indices_by_scope_id.items.len < scope_index) self.lifecycle_indices_by_scope_id.appendAssumeCapacity(.empty);
        self.lifecycle_indices_by_scope_id.appendAssumeCapacity(prepared);
    }

    /// Reserves lifecycle descriptor arrays and signal-record publication before preparation begins.
    pub fn reservePreparedLifecycle(self: *Stream, allocator: std.mem.Allocator, additional: usize) std.mem.Allocator.Error!void {
        try self.on_changes.ensureUnusedCapacity(allocator, additional);
        try self.mounts.ensureUnusedCapacity(allocator, additional);
        try self.cleanups.ensureUnusedCapacity(allocator, additional);
        try self.reservePreparedSignalRecordPublication(allocator, additional);
    }

    /// Retains provisional on-change ownership without mutating the stream.
    pub fn prepareOnChange(_: *Stream, signal: HostSignalBinding, to_cmd: roles.CommandBuilder, scope_id: ScopeId, run_initial: bool, run_initial_pending: bool, metrics: anytype) PreparedLifecycleDescriptor {
        abi.increfErasedCallable(to_cmd.toAbi(), 1);
        metrics.bump(.closure_retains, 1);
        return .{ .on_change = .{ .scope_id = scope_id, .run_initial = run_initial, .run_initial_pending = run_initial_pending, .signal = signal, .to_cmd = to_cmd } };
    }

    /// Retains provisional mount ownership without mutating the stream.
    pub fn prepareMount(_: *Stream, to_cmd: roles.CommandBuilder, scope_id: ScopeId, run_on_mount: bool, metrics: anytype) PreparedLifecycleDescriptor {
        abi.increfErasedCallable(to_cmd.toAbi(), 1);
        metrics.bump(.closure_retains, 1);
        return .{ .mount = .{ .scope_id = scope_id, .to_cmd = to_cmd, .run_on_mount = run_on_mount } };
    }

    /// Copies a provisional cleanup name without mutating the stream.
    pub fn prepareCleanup(_: *Stream, allocator: std.mem.Allocator, scope_id: ScopeId, name: []const u8) std.mem.Allocator.Error!PreparedLifecycleDescriptor {
        return .{ .cleanup = .{ .scope_id = scope_id, .name = try allocator.dupe(u8, name) } };
    }

    /// Publishes a prepared lifecycle descriptor using only reserved capacity.
    /// Signal-record publication for an on-change descriptor must already have
    /// been committed by the collection plan.
    pub fn appendPreparedLifecycle(self: *Stream, prepared: PreparedLifecycleDescriptor) void {
        switch (prepared) {
            .on_change => |desc| {
                const index = self.on_changes.items.len;
                self.on_changes.appendAssumeCapacity(desc);
                self.recordLifecycleAssumeCapacity(desc.scope_id, .{ .kind = .on_change, .index = index });
            },
            .mount => |desc| {
                const index = self.mounts.items.len;
                self.mounts.appendAssumeCapacity(desc);
                self.recordLifecycleAssumeCapacity(desc.scope_id, .{ .kind = .mount, .index = index });
            },
            .cleanup => |desc| {
                const index = self.cleanups.items.len;
                self.cleanups.appendAssumeCapacity(desc);
                self.recordLifecycleAssumeCapacity(desc.scope_id, .{ .kind = .cleanup, .index = index });
            },
        }
    }

    fn recordLifecycleAssumeCapacity(self: *Stream, scope_id: ScopeId, value: LifecycleDescriptorIndex) void {
        self.lifecycle_indices_by_scope_id.items[scope_id.index()].appendAssumeCapacity(value);
    }

    /// Returns exact lifecycle descriptors owned by one scope.
    pub fn lifecycleIndices(self: *const Stream, scope_id: ScopeId) []const LifecycleDescriptorIndex {
        if (scope_id.index() >= self.lifecycle_indices_by_scope_id.items.len) return &.{};
        return self.lifecycle_indices_by_scope_id.items[scope_id.index()].items;
    }

    /// Preflights scope-local descriptor identity publication without changing
    /// either list's logical contents. Empty outer slots are harmless index
    /// storage and may remain after an aborted transaction.
    pub fn reserveScopeDescriptorOwnership(self: *Stream, allocator: std.mem.Allocator, scope_id: ScopeId, additional_elems: usize, additional_nodes: usize) ReserveError!void {
        if (additional_elems == 0 and additional_nodes == 0) return;
        const required = std.math.add(usize, scope_id.index(), 1) catch return error.ResourceLimit;
        try self.scope_descriptor_ownership.ensureTotalCapacity(allocator, required);
        while (self.scope_descriptor_ownership.items.len < required) self.scope_descriptor_ownership.appendAssumeCapacity(.{});
        const ownership = &self.scope_descriptor_ownership.items[scope_id.index()];
        try ownership.elem_ids.ensureUnusedCapacity(allocator, additional_elems);
        try ownership.node_ids.ensureUnusedCapacity(allocator, additional_nodes);
    }

    /// Publishes one element identity into its already-reserved scope index.
    pub fn recordScopeElemAssumeCapacity(self: *Stream, scope_id: ScopeId, elem_id: ElemId) void {
        const ownership = &self.scope_descriptor_ownership.items[scope_id.index()];
        ownership.elem_ids.appendAssumeCapacity(elem_id);
    }

    /// Publishes one construction-node identity into its already-reserved scope index.
    pub fn recordScopeNodeAssumeCapacity(self: *Stream, scope_id: ScopeId, node_id: NodeId) void {
        const ownership = &self.scope_descriptor_ownership.items[scope_id.index()];
        ownership.node_ids.appendAssumeCapacity(node_id);
    }

    /// Returns exact element identities owned directly by one scope.
    pub fn scopeOwnedElemIds(self: *const Stream, scope_id: ScopeId) []const ElemId {
        if (scope_id.index() >= self.scope_descriptor_ownership.items.len) return &.{};
        return self.scope_descriptor_ownership.items[scope_id.index()].elem_ids.items;
    }

    /// Returns exact construction-node identities owned directly by one scope.
    pub fn scopeOwnedNodeIds(self: *const Stream, scope_id: ScopeId) []const NodeId {
        if (scope_id.index() >= self.scope_descriptor_ownership.items.len) return &.{};
        return self.scope_descriptor_ownership.items[scope_id.index()].node_ids.items;
    }

    /// Clears one retiring or re-collected scope after its descriptor-removal
    /// journal has captured these stable ids. Capacity is retained for reuse.
    pub fn clearScopeDescriptorOwnership(self: *Stream, scope_id: ScopeId) void {
        if (scope_id.index() >= self.scope_descriptor_ownership.items.len) return;
        const ownership = &self.scope_descriptor_ownership.items[scope_id.index()];
        ownership.elem_ids.clearRetainingCapacity();
        ownership.node_ids.clearRetainingCapacity();
    }

    fn forgetScopeElem(self: *Stream, scope_id: ScopeId, elem_id: ElemId) void {
        if (scope_id.index() >= self.scope_descriptor_ownership.items.len) return;
        const owned_ids = &self.scope_descriptor_ownership.items[scope_id.index()].elem_ids;
        for (owned_ids.items, 0..) |candidate, index| if (candidate == elem_id) {
            _ = owned_ids.swapRemove(index);
            return;
        };
    }

    fn forgetScopeNode(self: *Stream, scope_id: ScopeId, node_id: NodeId) void {
        if (scope_id.index() >= self.scope_descriptor_ownership.items.len) return;
        const owned_ids = &self.scope_descriptor_ownership.items[scope_id.index()].node_ids;
        for (owned_ids.items, 0..) |candidate, index| if (candidate == node_id) {
            _ = owned_ids.swapRemove(index);
            return;
        };
    }

    /// Removes one lifecycle ownership entry and validates its dense descriptor index.
    pub fn removeLifecycleIndex(self: *Stream, scope_id: u64, expected: LifecycleDescriptorIndex) void {
        if (scope_id >= self.lifecycle_indices_by_scope_id.items.len) @panic("lifecycle removal missed its scope index");
        const indexes = &self.lifecycle_indices_by_scope_id.items[@intCast(scope_id)];
        for (indexes.items, 0..) |candidate, offset| if (candidate.kind == expected.kind and candidate.index == expected.index) {
            _ = indexes.swapRemove(offset);
            return;
        };
        @panic("lifecycle removal missed its descriptor index");
    }

    /// Repairs the ownership entry for a descriptor moved by dense swap removal.
    pub fn updateLifecycleIndex(self: *Stream, scope_id: u64, kind: LifecycleDescriptorKind, old_index: usize, new_index: usize) void {
        if (scope_id >= self.lifecycle_indices_by_scope_id.items.len) @panic("moved lifecycle descriptor missed its scope index");
        for (self.lifecycle_indices_by_scope_id.items[@intCast(scope_id)].items) |*candidate| if (candidate.kind == kind and candidate.index == old_index) {
            candidate.index = new_index;
            return;
        };
        @panic("moved lifecycle descriptor index was stale");
    }

    /// Appends on change using capacity that must already satisfy the caller's transaction contract.
    pub fn appendOnChange(self: *Stream, allocator: std.mem.Allocator, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype, scope_id: ScopeId, signal: HostSignalBinding, to_cmd: roles.CommandBuilder, run_initial: bool, run_initial_pending: bool) void {
        self.on_changes.ensureUnusedCapacity(allocator, 1) catch @panic("out of memory");
        self.reserveLifecycleScope(allocator, scope_id, 1) catch |err| switch (err) {
            error.OutOfMemory => @panic("out of memory"),
            error.ResourceLimit => @panic("lifecycle scope index exceeded its bound"),
        };
        self.rememberSignalRecordTree(allocator, signal.record);
        abi.increfErasedCallable(to_cmd.toAbi(), 1);
        metrics.bump(.closure_retains, 1);
        const index = self.on_changes.items.len;
        self.on_changes.appendAssumeCapacity(.{
            .scope_id = scope_id,
            .run_initial = run_initial,
            .run_initial_pending = run_initial_pending,
            .signal = signal,
            .to_cmd = to_cmd,
        });
        self.recordLifecycleAssumeCapacity(scope_id, .{ .kind = .on_change, .index = index });
        _ = ctx;
        _ = roc_host;
    }

    /// Appends mount using capacity that must already satisfy the caller's transaction contract.
    pub fn appendMount(self: *Stream, allocator: std.mem.Allocator, roc_host: *abi.RocHost, metrics: anytype, scope_id: ScopeId, to_cmd: roles.CommandBuilder, run_on_mount: bool) void {
        self.mounts.ensureUnusedCapacity(allocator, 1) catch @panic("out of memory");
        self.reserveLifecycleScope(allocator, scope_id, 1) catch |err| switch (err) {
            error.OutOfMemory => @panic("out of memory"),
            error.ResourceLimit => @panic("lifecycle scope index exceeded its bound"),
        };
        abi.increfErasedCallable(to_cmd.toAbi(), 1);
        metrics.bump(.closure_retains, 1);
        const index = self.mounts.items.len;
        self.mounts.appendAssumeCapacity(.{
            .scope_id = scope_id,
            .to_cmd = to_cmd,
            .run_on_mount = run_on_mount,
        });
        self.recordLifecycleAssumeCapacity(scope_id, .{ .kind = .mount, .index = index });
        _ = roc_host;
    }

    /// Appends cleanup using capacity that must already satisfy the caller's transaction contract.
    pub fn appendCleanup(self: *Stream, allocator: std.mem.Allocator, scope_id: ScopeId, name: []const u8) void {
        const name_copy = allocator.dupe(u8, name) catch @panic("out of memory");
        self.cleanups.ensureUnusedCapacity(allocator, 1) catch {
            allocator.free(name_copy);
            @panic("out of memory");
        };
        self.reserveLifecycleScope(allocator, scope_id, 1) catch {
            allocator.free(name_copy);
            @panic("out of memory");
        };
        const index = self.cleanups.items.len;
        self.cleanups.appendAssumeCapacity(.{ .scope_id = scope_id, .name = name_copy });
        self.recordLifecycleAssumeCapacity(scope_id, .{ .kind = .cleanup, .index = index });
    }

    /// Appends event using capacity that must already satisfy the caller's transaction contract.
    pub fn appendEvent(self: *Stream, allocator: std.mem.Allocator, roc_host: *abi.RocHost, metrics: anytype, elem_id: ElemId, kind: EventKind, delivery_request: EventDeliveryRequest, binder_token: BinderToken, target_node_id: NodeId, read_binder_token: BinderToken, read_node_id: NodeId, payload_descriptor: BoundaryPayloadDescriptor, payload_reducer: HostEventReducer) void {
        const retained_reducer = retainHostEventReducer(payload_reducer, metrics);
        const event_index = self.events.items.len;
        self.events.append(allocator, .{
            .elem_id = elem_id,
            .binding = .{ .fixed = kind },
            .delivery_request = delivery_request,
            .binder_token = binder_token,
            .target_node_id = target_node_id,
            .read_binder_token = read_binder_token,
            .read_node_id = read_node_id,
            .payload_descriptor = payload_descriptor,
            .payload_reducer = retained_reducer,
        }) catch {
            const desc = EventDesc{
                .elem_id = elem_id,
                .binding = .{ .fixed = kind },
                .delivery_request = delivery_request,
                .binder_token = binder_token,
                .target_node_id = target_node_id,
                .read_binder_token = read_binder_token,
                .read_node_id = read_node_id,
                .payload_descriptor = payload_descriptor,
                .payload_reducer = retained_reducer,
            };
            desc.deinit(allocator, roc_host, metrics);
            @panic("out of memory");
        };
        self.recordEventIndex(allocator, elem_id, kind, event_index);
    }

    /// Maintains named event descriptor exists within the indexed descriptor stream used by both hosts.
    pub fn namedEventDescriptorExists(self: *const Stream, elem_id: ElemId, name: []const u8) bool {
        for (self.namedEventIndices(elem_id)) |index| {
            if (index >= self.events.items.len) @panic("named event index exceeded descriptor table");
            const desc = self.events.items[index];
            const binding = desc.named() orelse @panic("named event index pointed at a fixed event descriptor");
            if (desc.elem_id == elem_id and std.mem.eql(u8, binding.name, name)) return true;
        }
        return false;
    }

    /// Appends named event using capacity that must already satisfy the caller's transaction contract.
    pub fn appendNamedEvent(self: *Stream, allocator: std.mem.Allocator, roc_host: *abi.RocHost, metrics: anytype, elem_id: ElemId, name: []const u8, policy: EventPolicy, delivery_request: EventDeliveryRequest, binder_token: BinderToken, target_node_id: NodeId, read_binder_token: BinderToken, read_node_id: NodeId, payload_descriptor: BoundaryPayloadDescriptor, payload_reducer: HostEventReducer) void {
        if (name.len == 0) @panic("named event descriptor used an empty event name");
        if (self.namedEventDescriptorExists(elem_id, name)) @panic("element has duplicate named event descriptors");

        const retained_reducer = retainHostEventReducer(payload_reducer, metrics);
        const name_copy = allocator.dupe(u8, name) catch {
            releaseHostEventReducer(retained_reducer, roc_host, metrics);
            @panic("out of memory");
        };
        const event_index = self.events.items.len;
        self.events.append(allocator, .{
            .elem_id = elem_id,
            .binding = .{ .named = .{
                .name = name_copy,
                .policy = policy,
                .delivery_request = delivery_request,
            } },
            .delivery_request = delivery_request,
            .binder_token = binder_token,
            .target_node_id = target_node_id,
            .read_binder_token = read_binder_token,
            .read_node_id = read_node_id,
            .payload_descriptor = payload_descriptor,
            .payload_reducer = retained_reducer,
        }) catch {
            const desc = EventDesc{
                .elem_id = elem_id,
                .binding = .{ .named = .{
                    .name = name_copy,
                    .policy = policy,
                    .delivery_request = delivery_request,
                } },
                .delivery_request = delivery_request,
                .binder_token = binder_token,
                .target_node_id = target_node_id,
                .read_binder_token = read_binder_token,
                .read_node_id = read_node_id,
                .payload_descriptor = payload_descriptor,
                .payload_reducer = retained_reducer,
            };
            desc.deinit(allocator, roc_host, metrics);
            @panic("out of memory");
        };
        self.recordNamedEventIndex(allocator, elem_id, event_index);
    }

    /// Appends scope site using capacity that must already satisfy the caller's transaction contract.
    pub fn appendScopeSite(self: *Stream, allocator: std.mem.Allocator, node_id: NodeId, scope_id: ScopeId, ordinal: SiteOrdinal, parent_elem_id: ElemId, kind: ScopeSiteKind, binder_bindings: []const BinderBinding) void {
        self.reserveScopeDescriptorOwnership(allocator, scope_id, 0, 1) catch @panic("out of memory");
        appendScopeSiteImpl(Stream, self, allocator, node_id, scope_id, ordinal, parent_elem_id, kind, binder_bindings);
        self.recordScopeNodeAssumeCapacity(scope_id, node_id);
    }

    /// Appends scope site at using capacity that must already satisfy the caller's transaction contract.
    pub fn appendScopeSiteAt(self: *Stream, allocator: std.mem.Allocator, node_id: NodeId, scope_id: ScopeId, ordinal: SiteOrdinal, parent_elem_id: ElemId, render_insert_index: usize, kind: ScopeSiteKind, binder_bindings: []const BinderBinding) void {
        self.reserveScopeDescriptorOwnership(allocator, scope_id, 0, 1) catch @panic("out of memory");
        appendScopeSiteAtImpl(Stream, self, allocator, node_id, scope_id, ordinal, parent_elem_id, render_insert_index, kind, binder_bindings);
        self.recordScopeNodeAssumeCapacity(scope_id, node_id);
    }

    /// Appends state using capacity that must already satisfy the caller's transaction contract.
    pub fn appendState(self: *Stream, allocator: std.mem.Allocator, roc_host: *abi.RocHost, metrics: anytype, node_id: NodeId, initial: roles.Initializer, cap: HostValueCapability) void {
        _ = retainHostValueCapability(cap, metrics);
        abi.increfErasedCallable(initial.toAbi(), 1);
        metrics.bump(.closure_retains, 1);
        const state_index = self.states.items.len;
        self.states.append(allocator, .{
            .node_id = node_id,
            .initial = initial,
            .cap = cap,
        }) catch {
            const desc = StateDesc{
                .node_id = node_id,
                .initial = initial,
                .cap = cap,
            };
            desc.deinit(roc_host, metrics);
            @panic("out of memory");
        };
        self.recordStateIndex(allocator, node_id.raw(), state_index);
    }

    /// Appends when using capacity that must already satisfy the caller's transaction contract.
    pub fn appendWhen(self: *Stream, allocator: std.mem.Allocator, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype, node_id: NodeId, condition: HostSignalBinding, ops: retained.HostWhenOps) void {
        self.rememberSignalRecordTree(allocator, condition.record);
        const retained_ops = retained.retainHostWhenOps(ops, metrics);
        const when_index = self.whens.items.len;
        self.whens.append(allocator, .{
            .node_id = node_id,
            .condition = condition,
            .ops = retained_ops,
        }) catch {
            var desc = WhenDesc{
                .node_id = node_id,
                .condition = condition,
                .ops = retained_ops,
            };
            desc.deinit(allocator, ctx, roc_host, metrics);
            @panic("out of memory");
        };
        self.recordWhenIndex(allocator, node_id.raw(), when_index);
    }

    /// Appends each using capacity that must already satisfy the caller's transaction contract.
    pub fn appendEach(self: *Stream, allocator: std.mem.Allocator, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype, node_id: NodeId, items: HostSignalBinding, ops: HostEachOps) void {
        self.rememberSignalRecordTree(allocator, items.record);
        const retained_ops = retainHostEachOps(ops, metrics);
        const each_index = self.eaches.items.len;
        self.eaches.append(allocator, .{
            .node_id = node_id,
            .items = items,
            .ops = retained_ops,
        }) catch {
            var desc = EachDesc{
                .node_id = node_id,
                .items = items,
                .ops = retained_ops,
            };
            desc.deinit(allocator, ctx, roc_host, metrics);
            @panic("out of memory");
        };
        self.recordEachIndex(allocator, node_id.raw(), each_index);
    }
};

pub const DescriptorIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    /// Creates an initialized value with the ownership and capacity invariants required by this module.
    pub fn init(index: usize) DescriptorIndex {
        if (index >= @intFromEnum(DescriptorIndex.none)) @panic("descriptor index exceeded u32 storage");
        return @enumFromInt(@as(u32, @intCast(index)));
    }

    /// Returns the stored value without changing its identity or ownership policy.
    pub fn get(self: DescriptorIndex) ?usize {
        return if (self == .none) null else @intFromEnum(self);
    }
};

pub const TextFieldDescriptorIndexes = struct {
    text: DescriptorIndex = .none,
    role: DescriptorIndex = .none,
    label: DescriptorIndex = .none,
    test_id: DescriptorIndex = .none,
    value: DescriptorIndex = .none,
    class: DescriptorIndex = .none,

    /// Returns the stored value without changing its identity or ownership policy.
    pub fn get(self: TextFieldDescriptorIndexes, field: TextField) ?usize {
        return switch (field) {
            .text => self.text.get(),
            .role => self.role.get(),
            .label => self.label.get(),
            .test_id => self.test_id.get(),
            .value => self.value.get(),
            .class => self.class.get(),
        };
    }

    /// Maintains slot within the indexed descriptor stream used by both hosts.
    pub fn slot(self: *TextFieldDescriptorIndexes, field: TextField) *DescriptorIndex {
        return switch (field) {
            .text => &self.text,
            .role => &self.role,
            .label => &self.label,
            .test_id => &self.test_id,
            .value => &self.value,
            .class => &self.class,
        };
    }
};

pub const BoolFieldDescriptorIndexes = struct {
    checked: DescriptorIndex = .none,
    disabled: DescriptorIndex = .none,

    /// Returns the stored value without changing its identity or ownership policy.
    pub fn get(self: BoolFieldDescriptorIndexes, field: BoolField) ?usize {
        return switch (field) {
            .checked => self.checked.get(),
            .disabled => self.disabled.get(),
        };
    }

    /// Maintains slot within the indexed descriptor stream used by both hosts.
    pub fn slot(self: *BoolFieldDescriptorIndexes, field: BoolField) *DescriptorIndex {
        return switch (field) {
            .checked => &self.checked,
            .disabled => &self.disabled,
        };
    }
};

pub const EventDescriptorIndexes = struct {
    click: DescriptorIndex = .none,
    input: DescriptorIndex = .none,
    check: DescriptorIndex = .none,
    pointer_down: DescriptorIndex = .none,
    pointer_up: DescriptorIndex = .none,
    pointer_enter: DescriptorIndex = .none,
    pointer_leave: DescriptorIndex = .none,

    /// Returns the stored value without changing its identity or ownership policy.
    pub fn get(self: EventDescriptorIndexes, kind: EventKind) ?usize {
        return switch (kind) {
            .click => self.click.get(),
            .input => self.input.get(),
            .check => self.check.get(),
            .pointer_down => self.pointer_down.get(),
            .pointer_up => self.pointer_up.get(),
            .pointer_enter => self.pointer_enter.get(),
            .pointer_leave => self.pointer_leave.get(),
        };
    }

    /// Maintains slot within the indexed descriptor stream used by both hosts.
    pub fn slot(self: *EventDescriptorIndexes, kind: EventKind) *DescriptorIndex {
        return switch (kind) {
            .click => &self.click,
            .input => &self.input,
            .check => &self.check,
            .pointer_down => &self.pointer_down,
            .pointer_up => &self.pointer_up,
            .pointer_enter => &self.pointer_enter,
            .pointer_leave => &self.pointer_leave,
        };
    }
};

pub const RenderElemIndex = struct {
    render_node: ?usize = null,
    first_child: ?ElemId = null,
    last_child: ?ElemId = null,
    previous_sibling: ?ElemId = null,
    next_sibling: ?ElemId = null,

    /// Returns an initialized empty value with no retained resources.
    pub fn empty(self: RenderElemIndex) bool {
        return self.render_node == null and self.first_child == null and self.last_child == null and self.previous_sibling == null and self.next_sibling == null;
    }
};

/// Exact pointer-write work performed by one sparse render-sibling move.
pub const RenderSiblingMoveWork = struct {
    links_touched: u8 = 0,
};

pub const ElemDescriptorIndex = struct {
    element: DescriptorIndex = .none,
    text_node: DescriptorIndex = .none,
    signal_text_node: DescriptorIndex = .none,
    static_text_attrs: TextFieldDescriptorIndexes = .{},
    signal_text_attrs: TextFieldDescriptorIndexes = .{},
    static_bool_attrs: BoolFieldDescriptorIndexes = .{},
    signal_bool_attrs: BoolFieldDescriptorIndexes = .{},
    events: EventDescriptorIndexes = .{},
};

pub const ScopeSiteDescriptorIndexes = struct {
    component: DescriptorIndex = .none,
    state: DescriptorIndex = .none,
    when: DescriptorIndex = .none,
    each: DescriptorIndex = .none,

    /// Returns the stored value without changing its identity or ownership policy.
    pub fn get(self: ScopeSiteDescriptorIndexes, kind: ScopeSiteKind) ?usize {
        return switch (kind) {
            .component => self.component.get(),
            .state => self.state.get(),
            .when => self.when.get(),
            .each => self.each.get(),
        };
    }

    /// Maintains slot within the indexed descriptor stream used by both hosts.
    pub fn slot(self: *ScopeSiteDescriptorIndexes, kind: ScopeSiteKind) *DescriptorIndex {
        return switch (kind) {
            .component => &self.component,
            .state => &self.state,
            .when => &self.when,
            .each => &self.each,
        };
    }
};

pub const NodeDescriptorIndex = struct {
    scope_sites: ScopeSiteDescriptorIndexes = .{},
    state: DescriptorIndex = .none,
    when: DescriptorIndex = .none,
    each: DescriptorIndex = .none,
};

/// Sets fresh index at the narrow host or engine boundary that owns the mutation.
pub fn setFreshIndex(slot: *DescriptorIndex, value: usize) void {
    if (slot.* != .none) {
        @panic("descriptor stream recorded duplicate descriptor index");
    }
    slot.* = DescriptorIndex.init(value);
}

/// Updates the dense  descriptor index after a local structural splice.
pub fn updateIndex(slot: *DescriptorIndex, value: usize) void {
    if (slot.* == .none) @panic("descriptor stream updated a missing descriptor index");
    slot.* = DescriptorIndex.init(value);
}

/// Clears index while retaining bounded storage where the type promises reuse.
pub fn clearIndex(slot: *DescriptorIndex, expected: usize) void {
    const existing = slot.get() orelse @panic("descriptor stream cleared a missing descriptor index");
    if (existing != expected) @panic("descriptor stream cleared the wrong descriptor index");
    slot.* = .none;
}

/// Ensures elem descriptor index capacity or state before publication can begin.
pub fn ensureElemDescriptorIndex(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator, elem_id: ElemId) *ElemDescriptorIndex {
    const index = elem_id.index();
    while (stream.descriptor_indexes_by_elem_id.items.len <= index) {
        stream.descriptor_indexes_by_elem_id.append(allocator, .{}) catch @panic("out of memory");
    }
    return &stream.descriptor_indexes_by_elem_id.items[index];
}

/// Maintains elem descriptor index within the indexed descriptor stream used by both hosts.
pub fn elemDescriptorIndex(comptime StreamType: type, stream: *const StreamType, elem_id: ElemId) ?ElemDescriptorIndex {
    if (elem_id.index() >= stream.descriptor_indexes_by_elem_id.items.len) return null;
    return stream.descriptor_indexes_by_elem_id.items[elem_id.index()];
}

/// Ensures node descriptor index capacity or state before publication can begin.
pub fn ensureNodeDescriptorIndex(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator, node_id: NodeId) *NodeDescriptorIndex {
    const index = node_id.index();
    while (stream.descriptor_indexes_by_node_id.items.len <= index) {
        stream.descriptor_indexes_by_node_id.append(allocator, .{}) catch @panic("out of memory");
    }
    return &stream.descriptor_indexes_by_node_id.items[index];
}

/// Maintains node descriptor index within the indexed descriptor stream used by both hosts.
pub fn nodeDescriptorIndex(comptime StreamType: type, stream: *const StreamType, node_id: NodeId) ?NodeDescriptorIndex {
    if (node_id.index() >= stream.descriptor_indexes_by_node_id.items.len) return null;
    return stream.descriptor_indexes_by_node_id.items[node_id.index()];
}

/// Records the dense element descriptor index used for O(1) runtime lookup.
pub fn recordElementIndex(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator, elem_id: ElemId, index: usize) void {
    setFreshIndex(&ensureElemDescriptorIndex(StreamType, stream, allocator, asElemId(elem_id)).element, index);
}

/// Updates the dense element descriptor index after a local structural splice.
pub fn updateElementIndex(comptime StreamType: type, stream: *StreamType, elem_id: u64, index: usize) void {
    updateIndex(&stream.descriptor_indexes_by_elem_id.items[@intCast(elem_id)].element, index);
}

/// Clears element index while retaining bounded storage where the type promises reuse.
pub fn clearElementIndex(comptime StreamType: type, stream: *StreamType, elem_id: u64, expected: usize) void {
    clearIndex(&stream.descriptor_indexes_by_elem_id.items[@intCast(elem_id)].element, expected);
}

/// Records the dense text node descriptor index used for O(1) runtime lookup.
pub fn recordTextNodeIndex(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator, elem_id: ElemId, index: usize) void {
    setFreshIndex(&ensureElemDescriptorIndex(StreamType, stream, allocator, asElemId(elem_id)).text_node, index);
}

/// Updates the dense text node descriptor index after a local structural splice.
pub fn updateTextNodeIndex(comptime StreamType: type, stream: *StreamType, elem_id: u64, index: usize) void {
    updateIndex(&stream.descriptor_indexes_by_elem_id.items[@intCast(elem_id)].text_node, index);
}

/// Clears text node index while retaining bounded storage where the type promises reuse.
pub fn clearTextNodeIndex(comptime StreamType: type, stream: *StreamType, elem_id: u64, expected: usize) void {
    clearIndex(&stream.descriptor_indexes_by_elem_id.items[@intCast(elem_id)].text_node, expected);
}

/// Records the dense signal text node descriptor index used for O(1) runtime lookup.
pub fn recordSignalTextNodeIndex(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator, elem_id: u64, index: usize) void {
    setFreshIndex(&ensureElemDescriptorIndex(StreamType, stream, allocator, asElemId(elem_id)).signal_text_node, index);
}

/// Updates the dense signal text node descriptor index after a local structural splice.
pub fn updateSignalTextNodeIndex(comptime StreamType: type, stream: *StreamType, elem_id: u64, index: usize) void {
    updateIndex(&stream.descriptor_indexes_by_elem_id.items[@intCast(elem_id)].signal_text_node, index);
}

/// Clears signal text node index while retaining bounded storage where the type promises reuse.
pub fn clearSignalTextNodeIndex(comptime StreamType: type, stream: *StreamType, elem_id: u64, expected: usize) void {
    clearIndex(&stream.descriptor_indexes_by_elem_id.items[@intCast(elem_id)].signal_text_node, expected);
}

/// Records the dense static text attr descriptor index used for O(1) runtime lookup.
pub fn recordStaticTextAttrIndex(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator, elem_id: u64, field: TextField, index: usize) void {
    setFreshIndex(ensureElemDescriptorIndex(StreamType, stream, allocator, asElemId(elem_id)).static_text_attrs.slot(field), index);
}

/// Updates the dense static text attr descriptor index after a local structural splice.
pub fn updateStaticTextAttrIndex(comptime StreamType: type, stream: *StreamType, elem_id: u64, field: TextField, index: usize) void {
    updateIndex(stream.descriptor_indexes_by_elem_id.items[@intCast(elem_id)].static_text_attrs.slot(field), index);
}

/// Clears static text attr index while retaining bounded storage where the type promises reuse.
pub fn clearStaticTextAttrIndex(comptime StreamType: type, stream: *StreamType, elem_id: u64, field: TextField, expected: usize) void {
    clearIndex(stream.descriptor_indexes_by_elem_id.items[@intCast(elem_id)].static_text_attrs.slot(field), expected);
}

/// Records the dense signal text attr descriptor index used for O(1) runtime lookup.
pub fn recordSignalTextAttrIndex(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator, elem_id: u64, field: TextField, index: usize) void {
    setFreshIndex(ensureElemDescriptorIndex(StreamType, stream, allocator, asElemId(elem_id)).signal_text_attrs.slot(field), index);
}

/// Updates the dense signal text attr descriptor index after a local structural splice.
pub fn updateSignalTextAttrIndex(comptime StreamType: type, stream: *StreamType, elem_id: u64, field: TextField, index: usize) void {
    updateIndex(stream.descriptor_indexes_by_elem_id.items[@intCast(elem_id)].signal_text_attrs.slot(field), index);
}

/// Clears signal text attr index while retaining bounded storage where the type promises reuse.
pub fn clearSignalTextAttrIndex(comptime StreamType: type, stream: *StreamType, elem_id: u64, field: TextField, expected: usize) void {
    clearIndex(stream.descriptor_indexes_by_elem_id.items[@intCast(elem_id)].signal_text_attrs.slot(field), expected);
}

/// Records the dense static bool attr descriptor index used for O(1) runtime lookup.
pub fn recordStaticBoolAttrIndex(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator, elem_id: u64, field: BoolField, index: usize) void {
    setFreshIndex(ensureElemDescriptorIndex(StreamType, stream, allocator, asElemId(elem_id)).static_bool_attrs.slot(field), index);
}

/// Updates the dense static bool attr descriptor index after a local structural splice.
pub fn updateStaticBoolAttrIndex(comptime StreamType: type, stream: *StreamType, elem_id: u64, field: BoolField, index: usize) void {
    updateIndex(stream.descriptor_indexes_by_elem_id.items[@intCast(elem_id)].static_bool_attrs.slot(field), index);
}

/// Clears static bool attr index while retaining bounded storage where the type promises reuse.
pub fn clearStaticBoolAttrIndex(comptime StreamType: type, stream: *StreamType, elem_id: u64, field: BoolField, expected: usize) void {
    clearIndex(stream.descriptor_indexes_by_elem_id.items[@intCast(elem_id)].static_bool_attrs.slot(field), expected);
}

/// Records the dense signal bool attr descriptor index used for O(1) runtime lookup.
pub fn recordSignalBoolAttrIndex(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator, elem_id: u64, field: BoolField, index: usize) void {
    setFreshIndex(ensureElemDescriptorIndex(StreamType, stream, allocator, asElemId(elem_id)).signal_bool_attrs.slot(field), index);
}

/// Updates the dense signal bool attr descriptor index after a local structural splice.
pub fn updateSignalBoolAttrIndex(comptime StreamType: type, stream: *StreamType, elem_id: u64, field: BoolField, index: usize) void {
    updateIndex(stream.descriptor_indexes_by_elem_id.items[@intCast(elem_id)].signal_bool_attrs.slot(field), index);
}

/// Clears signal bool attr index while retaining bounded storage where the type promises reuse.
pub fn clearSignalBoolAttrIndex(comptime StreamType: type, stream: *StreamType, elem_id: u64, field: BoolField, expected: usize) void {
    clearIndex(stream.descriptor_indexes_by_elem_id.items[@intCast(elem_id)].signal_bool_attrs.slot(field), expected);
}

/// Records the dense event descriptor index used for O(1) runtime lookup.
pub fn recordEventIndex(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator, elem_id: ElemId, kind: EventKind, index: usize) void {
    setFreshIndex(ensureElemDescriptorIndex(StreamType, stream, allocator, asElemId(elem_id)).events.slot(kind), index);
}

/// Updates the dense event descriptor index after a local structural splice.
pub fn updateEventIndex(comptime StreamType: type, stream: *StreamType, elem_id: u64, kind: EventKind, index: usize) void {
    updateIndex(stream.descriptor_indexes_by_elem_id.items[@intCast(elem_id)].events.slot(kind), index);
}

/// Clears event index while retaining bounded storage where the type promises reuse.
pub fn clearEventIndex(comptime StreamType: type, stream: *StreamType, elem_id: u64, kind: EventKind, expected: usize) void {
    clearIndex(stream.descriptor_indexes_by_elem_id.items[@intCast(elem_id)].events.slot(kind), expected);
}

/// Ensures named event index list capacity or state before publication can begin.
pub fn ensureNamedEventIndexList(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator, elem_id: ElemId) *std.ArrayListUnmanaged(usize) {
    const index = elem_id.index();
    while (stream.named_event_indices_by_elem_id.items.len <= index) {
        stream.named_event_indices_by_elem_id.append(allocator, .empty) catch @panic("out of memory");
    }
    return &stream.named_event_indices_by_elem_id.items[index];
}

/// Maintains named event indices within the indexed descriptor stream used by both hosts.
pub fn namedEventIndices(comptime StreamType: type, stream: *const StreamType, elem_id: ElemId) []const usize {
    if (elem_id.index() >= stream.named_event_indices_by_elem_id.items.len) return &.{};
    return stream.named_event_indices_by_elem_id.items[elem_id.index()].items;
}

/// Records the dense named event descriptor index used for O(1) runtime lookup.
pub fn recordNamedEventIndex(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator, elem_id: ElemId, index: usize) void {
    ensureNamedEventIndexList(StreamType, stream, allocator, elem_id).append(allocator, index) catch @panic("out of memory");
}

/// Updates the dense named event descriptor index after a local structural splice.
pub fn updateNamedEventIndex(comptime StreamType: type, stream: *StreamType, elem_id: u64, old_index: usize, new_index: usize) void {
    if (elem_id >= stream.named_event_indices_by_elem_id.items.len) @panic("descriptor stream updated a missing named event index");
    const indices = &stream.named_event_indices_by_elem_id.items[@intCast(elem_id)];
    for (indices.items) |*index| {
        if (index.* == old_index) {
            index.* = new_index;
            return;
        }
    }
    @panic("descriptor stream updated a missing named event index");
}

/// Clears named event index while retaining bounded storage where the type promises reuse.
pub fn clearNamedEventIndex(comptime StreamType: type, stream: *StreamType, elem_id: u64, expected: usize) void {
    if (elem_id >= stream.named_event_indices_by_elem_id.items.len) @panic("descriptor stream cleared a missing named event index");
    const indices = &stream.named_event_indices_by_elem_id.items[@intCast(elem_id)];
    for (indices.items, 0..) |index, offset| {
        if (index == expected) {
            _ = indices.swapRemove(offset);
            return;
        }
    }
    @panic("descriptor stream cleared a missing named event index");
}

/// Maintains deinit named event index lists within the indexed descriptor stream used by both hosts.
pub fn deinitNamedEventIndexLists(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator) void {
    for (stream.named_event_indices_by_elem_id.items) |*indices| {
        indices.deinit(allocator);
    }
    stream.named_event_indices_by_elem_id.deinit(allocator);
}

/// Records the dense scope site descriptor index used for O(1) runtime lookup.
pub fn recordScopeSiteIndex(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator, node_id: u64, kind: ScopeSiteKind, index: usize) void {
    setFreshIndex(ensureNodeDescriptorIndex(StreamType, stream, allocator, NodeId.fromRaw(identityRaw(node_id))).scope_sites.slot(kind), index);
}

/// Updates the dense scope site descriptor index after a local structural splice.
pub fn updateScopeSiteIndex(comptime StreamType: type, stream: *StreamType, node_id: u64, kind: ScopeSiteKind, index: usize) void {
    updateIndex(stream.descriptor_indexes_by_node_id.items[@intCast(node_id)].scope_sites.slot(kind), index);
}

/// Clears scope site index while retaining bounded storage where the type promises reuse.
pub fn clearScopeSiteIndex(comptime StreamType: type, stream: *StreamType, node_id: u64, kind: ScopeSiteKind, expected: usize) void {
    clearIndex(stream.descriptor_indexes_by_node_id.items[@intCast(node_id)].scope_sites.slot(kind), expected);
}

/// Records the dense state descriptor index used for O(1) runtime lookup.
pub fn recordStateIndex(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator, node_id: u64, index: usize) void {
    const slot = &ensureNodeDescriptorIndex(StreamType, stream, allocator, NodeId.fromRaw(identityRaw(node_id))).state;
    setFreshIndex(slot, index);
}

/// Updates the dense state descriptor index after a local structural splice.
pub fn updateStateIndex(comptime StreamType: type, stream: *StreamType, node_id: u64, index: usize) void {
    updateIndex(&stream.descriptor_indexes_by_node_id.items[@intCast(node_id)].state, index);
}

/// Clears state index while retaining bounded storage where the type promises reuse.
pub fn clearStateIndex(comptime StreamType: type, stream: *StreamType, node_id: u64, expected: usize) void {
    clearIndex(&stream.descriptor_indexes_by_node_id.items[@intCast(node_id)].state, expected);
}

/// Records the dense when descriptor index used for O(1) runtime lookup.
pub fn recordWhenIndex(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator, node_id: u64, index: usize) void {
    const slot = &ensureNodeDescriptorIndex(StreamType, stream, allocator, NodeId.fromRaw(identityRaw(node_id))).when;
    setFreshIndex(slot, index);
}

/// Updates the dense when descriptor index after a local structural splice.
pub fn updateWhenIndex(comptime StreamType: type, stream: *StreamType, node_id: u64, index: usize) void {
    updateIndex(&stream.descriptor_indexes_by_node_id.items[@intCast(node_id)].when, index);
}

/// Clears when index while retaining bounded storage where the type promises reuse.
pub fn clearWhenIndex(comptime StreamType: type, stream: *StreamType, node_id: u64, expected: usize) void {
    clearIndex(&stream.descriptor_indexes_by_node_id.items[@intCast(node_id)].when, expected);
}

/// Records the dense each descriptor index used for O(1) runtime lookup.
pub fn recordEachIndex(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator, node_id: u64, index: usize) void {
    const slot = &ensureNodeDescriptorIndex(StreamType, stream, allocator, NodeId.fromRaw(identityRaw(node_id))).each;
    setFreshIndex(slot, index);
}

/// Updates the dense each descriptor index after a local structural splice.
pub fn updateEachIndex(comptime StreamType: type, stream: *StreamType, node_id: u64, index: usize) void {
    updateIndex(&stream.descriptor_indexes_by_node_id.items[@intCast(node_id)].each, index);
}

/// Clears each index while retaining bounded storage where the type promises reuse.
pub fn clearEachIndex(comptime StreamType: type, stream: *StreamType, node_id: u64, expected: usize) void {
    clearIndex(&stream.descriptor_indexes_by_node_id.items[@intCast(node_id)].each, expected);
}

/// Ensures render metadata capacity or state before publication can begin.
pub fn ensureRenderMetadata(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator, elem_id: ElemId) *RenderElemIndex {
    const entry = stream.render_metadata_by_elem_id.getOrPut(allocator, elem_id.raw()) catch @panic("out of memory");
    if (!entry.found_existing) entry.value_ptr.* = .{};
    return entry.value_ptr;
}

/// Removes metadata if empty while preserving indexes for unaffected render nodes.
pub fn removeRenderMetadataIfEmpty(comptime StreamType: type, stream: *StreamType, elem_id: ElemId) void {
    const metadata = stream.render_metadata_by_elem_id.get(elem_id.raw()) orelse return;
    if (metadata.empty()) {
        _ = stream.render_metadata_by_elem_id.fetchRemove(elem_id.raw()) orelse @panic("render metadata disappeared during removal");
    }
}

/// Returns index for an already indexed render node.
pub fn renderNodeIndex(comptime StreamType: type, stream: *const StreamType, elem_id: ElemId) ?usize {
    const metadata = stream.render_metadata_by_elem_id.get(elem_id.raw()) orelse return null;
    return metadata.render_node;
}

/// Records the dense render node descriptor index used for O(1) runtime lookup.
pub fn recordRenderNodeIndex(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator, elem_id: ElemId, index: usize) void {
    const metadata = ensureRenderMetadata(StreamType, stream, allocator, elem_id);
    if (metadata.render_node != null) @panic("descriptor stream recorded duplicate render index");
    metadata.render_node = index;
}

/// Updates the dense render node descriptor index after a local structural splice.
pub fn updateRenderNodeIndex(comptime StreamType: type, stream: *StreamType, elem_id: ElemId, index: usize) void {
    const metadata = stream.render_metadata_by_elem_id.getPtr(elem_id.raw()) orelse @panic("descriptor stream updated a missing render index");
    if (metadata.render_node == null) @panic("descriptor stream updated a missing render index");
    metadata.render_node = index;
}

/// Clears render node index while retaining bounded storage where the type promises reuse.
pub fn clearRenderNodeIndex(comptime StreamType: type, stream: *StreamType, elem_id: ElemId, expected: usize) void {
    const metadata = stream.render_metadata_by_elem_id.getPtr(elem_id.raw()) orelse @panic("descriptor stream cleared a missing render index");
    const existing = metadata.render_node orelse @panic("descriptor stream cleared a missing render index");
    if (existing != expected) @panic("descriptor stream cleared the wrong render index");
    metadata.render_node = null;
    removeRenderMetadataIfEmpty(StreamType, stream, elem_id);
}

fn commitSparseRenderNodes(comptime StreamType: type, stream: *StreamType, replacement: *StreamType, retired: *StreamType, removed_elem_ids: []const u64) void {
    for (removed_elem_ids) |raw_elem_id| {
        const elem_id = ElemId.fromRaw(raw_elem_id);
        const index = renderNodeIndex(StreamType, stream, elem_id) orelse @panic("sparse render retirement target was not indexed");
        const removed = stream.render_nodes.swapRemove(index);
        if (removed.elem_id != elem_id) @panic("sparse render retirement index named another node");
        clearRenderNodeIndex(StreamType, stream, elem_id, index);
        retired.render_nodes.appendAssumeCapacity(removed);
        if (index < stream.render_nodes.items.len) updateRenderNodeIndex(StreamType, stream, stream.render_nodes.items[index].elem_id, index);
    }

    for (replacement.render_nodes.items) |node| {
        const replacement_metadata = replacement.render_metadata_by_elem_id.get(node.elem_id.raw()) orelse @panic("sparse render replacement lacked metadata");
        const parent_elem_id = renderNodeParentElemId(StreamType, replacement, node);
        const top_level = renderNodeIndex(StreamType, replacement, parent_elem_id) == null;
        const active_entry = stream.render_metadata_by_elem_id.getOrPutAssumeCapacity(node.elem_id.raw());
        const retained_previous = if (active_entry.found_existing) active_entry.value_ptr.previous_sibling else null;
        const retained_next = if (active_entry.found_existing) active_entry.value_ptr.next_sibling else null;
        active_entry.value_ptr.* = replacement_metadata;
        active_entry.value_ptr.render_node = stream.render_nodes.items.len;
        if (top_level) {
            active_entry.value_ptr.previous_sibling = retained_previous;
            active_entry.value_ptr.next_sibling = retained_next;
        }
        stream.render_nodes.appendAssumeCapacity(node);
    }
    replacement.render_nodes.items.len = 0;
}

fn finishSparseRenderNodeRetirementImpl(comptime StreamType: type, stream: *StreamType, removed_elem_ids: []const u64) void {
    for (removed_elem_ids) |raw_elem_id| {
        const metadata = stream.render_metadata_by_elem_id.get(raw_elem_id) orelse continue;
        if (metadata.render_node != null) continue;
        _ = stream.render_metadata_by_elem_id.fetchRemove(raw_elem_id) orelse unreachable;
    }
}

/// Ensures first render child slot capacity or state before publication can begin.
pub fn ensureFirstRenderChildSlot(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator, parent_elem_id: ElemId) *?ElemId {
    return &ensureRenderMetadata(StreamType, stream, allocator, parent_elem_id).first_child;
}

/// Ensures last render child slot capacity or state before publication can begin.
pub fn ensureLastRenderChildSlot(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator, parent_elem_id: ElemId) *?ElemId {
    return &ensureRenderMetadata(StreamType, stream, allocator, parent_elem_id).last_child;
}

/// Ensures next render sibling slot capacity or state before publication can begin.
pub fn ensureNextRenderSiblingSlot(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator, elem_id: ElemId) *?ElemId {
    return &ensureRenderMetadata(StreamType, stream, allocator, elem_id).next_sibling;
}

/// Ensures the reverse sibling-link slot used by sparse structural splices.
pub fn ensurePreviousRenderSiblingSlot(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator, elem_id: ElemId) *?ElemId {
    return &ensureRenderMetadata(StreamType, stream, allocator, elem_id).previous_sibling;
}

/// Maintains first render child within the indexed descriptor stream used by both hosts.
pub fn firstRenderChild(comptime StreamType: type, stream: *const StreamType, parent_elem_id: ElemId) ?ElemId {
    const metadata = stream.render_metadata_by_elem_id.get(parent_elem_id.raw()) orelse return null;
    return metadata.first_child;
}

/// Returns last render child retained for observability or local structural traversal.
pub fn lastRenderChild(comptime StreamType: type, stream: *const StreamType, parent_elem_id: ElemId) ?ElemId {
    const metadata = stream.render_metadata_by_elem_id.get(parent_elem_id.raw()) orelse return null;
    return metadata.last_child;
}

/// Returns next render sibling from maintained local structure without a full-tree scan.
pub fn nextRenderSibling(comptime StreamType: type, stream: *const StreamType, elem_id: ElemId) ?ElemId {
    const metadata = stream.render_metadata_by_elem_id.get(elem_id.raw()) orelse return null;
    return metadata.next_sibling;
}

/// Returns the previous sibling without scanning the parent's child list.
pub fn previousRenderSibling(comptime StreamType: type, stream: *const StreamType, elem_id: ElemId) ?ElemId {
    const metadata = stream.render_metadata_by_elem_id.get(elem_id.raw()) orelse return null;
    return metadata.previous_sibling;
}

/// Appends render child using capacity that must already satisfy the caller's transaction contract.
pub fn appendRenderChild(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator, parent_elem_id: ElemId, elem_id: ElemId) void {
    _ = ensureRenderMetadata(StreamType, stream, allocator, parent_elem_id);
    _ = ensureRenderMetadata(StreamType, stream, allocator, elem_id);

    const parent_metadata = stream.render_metadata_by_elem_id.getPtr(parent_elem_id.raw()) orelse @panic("render child index was missing its parent links");
    const elem_metadata = stream.render_metadata_by_elem_id.getPtr(elem_id.raw()) orelse @panic("render child index was missing its child links");
    const last = parent_metadata.last_child;
    elem_metadata.previous_sibling = last;
    elem_metadata.next_sibling = null;
    if (last) |last_child| {
        const last_metadata = stream.render_metadata_by_elem_id.getPtr(last_child.raw()) orelse @panic("render child index was missing its last child links");
        last_metadata.next_sibling = elem_id;
    } else {
        parent_metadata.first_child = elem_id;
    }
    parent_metadata.last_child = elem_id;
}

/// Clears render children while retaining bounded storage where the type promises reuse.
pub fn clearRenderChildren(comptime StreamType: type, stream: *StreamType, parent_elem_id: ElemId) void {
    var child = firstRenderChild(StreamType, stream, parent_elem_id);
    while (child) |child_id| {
        const next = nextRenderSibling(StreamType, stream, child_id);
        const child_metadata = stream.render_metadata_by_elem_id.getPtr(child_id) orelse @panic("render child index referenced a child without links");
        child_metadata.previous_sibling = null;
        child_metadata.next_sibling = null;
        removeRenderMetadataIfEmpty(StreamType, stream, child_id);
        child = next;
    }
    if (stream.render_metadata_by_elem_id.getPtr(parent_elem_id)) |parent_metadata| {
        parent_metadata.first_child = null;
        parent_metadata.last_child = null;
    }
    removeRenderMetadataIfEmpty(StreamType, stream, parent_elem_id);
}

/// Removes child while preserving indexes for unaffected render nodes.
pub fn removeRenderChild(comptime StreamType: type, stream: *StreamType, parent_elem_id: ElemId, elem_id: ElemId) void {
    const parent_metadata = stream.render_metadata_by_elem_id.getPtr(parent_elem_id.raw()) orelse @panic("render child index was missing its parent list");
    const elem_metadata = stream.render_metadata_by_elem_id.getPtr(elem_id.raw()) orelse @panic("render child index removed a child without links");
    const previous = elem_metadata.previous_sibling;
    const next = elem_metadata.next_sibling;
    if (previous) |previous_id| {
        const previous_metadata = stream.render_metadata_by_elem_id.getPtr(previous_id.raw()) orelse @panic("render child index referenced a previous child without links");
        previous_metadata.next_sibling = next;
    } else if (parent_metadata.first_child == elem_id) {
        parent_metadata.first_child = next;
    } else @panic("render child index was missing a child");
    if (next) |next_id| {
        const next_metadata = stream.render_metadata_by_elem_id.getPtr(next_id.raw()) orelse @panic("render child index referenced a next child without links");
        next_metadata.previous_sibling = previous;
    } else if (parent_metadata.last_child == elem_id) {
        parent_metadata.last_child = previous;
    } else @panic("render child index was missing a child");
    elem_metadata.previous_sibling = null;
    elem_metadata.next_sibling = null;
    removeRenderMetadataIfEmpty(StreamType, stream, elem_id);
    removeRenderMetadataIfEmpty(StreamType, stream, parent_elem_id);
}

/// Moves one already-linked contiguous sibling range before an anchor.
///
/// Range membership and anchor exclusion are validated by the Rows transition
/// and its render-order overlay before this allocation-free publication step.
pub fn moveRenderSiblingRangeBefore(comptime StreamType: type, stream: *StreamType, parent_elem_id: ElemId, first_elem_id: ElemId, last_elem_id: ElemId, before_elem_id: ?ElemId) RenderSiblingMoveWork {
    if (before_elem_id == first_elem_id) return .{};
    const parent = stream.render_metadata_by_elem_id.getPtr(parent_elem_id.raw()) orelse @panic("render sibling move was missing its parent");
    const first = stream.render_metadata_by_elem_id.getPtr(first_elem_id.raw()) orelse @panic("render sibling move was missing its first child");
    const last = stream.render_metadata_by_elem_id.getPtr(last_elem_id.raw()) orelse @panic("render sibling move was missing its last child");
    const old_previous = first.previous_sibling;
    const old_next = last.next_sibling;
    if (old_next == before_elem_id) return .{};

    if (old_previous) |previous_id| {
        stream.render_metadata_by_elem_id.getPtr(previous_id.raw()).?.next_sibling = old_next;
    } else {
        parent.first_child = old_next;
    }
    if (old_next) |next_id| {
        stream.render_metadata_by_elem_id.getPtr(next_id.raw()).?.previous_sibling = old_previous;
    } else {
        parent.last_child = old_previous;
    }

    const insertion_previous = if (before_elem_id) |before_id|
        (stream.render_metadata_by_elem_id.getPtr(before_id.raw()) orelse @panic("render sibling move was missing its anchor")).previous_sibling
    else
        parent.last_child;
    first.previous_sibling = insertion_previous;
    last.next_sibling = before_elem_id;
    if (insertion_previous) |previous_id| {
        stream.render_metadata_by_elem_id.getPtr(previous_id.raw()).?.next_sibling = first_elem_id;
    } else {
        parent.first_child = first_elem_id;
    }
    if (before_elem_id) |before_id| {
        stream.render_metadata_by_elem_id.getPtr(before_id.raw()).?.previous_sibling = last_elem_id;
    } else {
        parent.last_child = last_elem_id;
    }
    return .{ .links_touched = 6 };
}

/// Inserts children into prepared render metadata for the affected subtree.
pub fn insertRenderChildren(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator, parent_elem_id: ElemId, index: usize, elem_ids: []const ElemId) void {
    if (elem_ids.len == 0) return;

    _ = ensureRenderMetadata(StreamType, stream, allocator, parent_elem_id);
    for (elem_ids) |elem_id| {
        _ = ensureRenderMetadata(StreamType, stream, allocator, elem_id);
    }

    const parent_metadata = stream.render_metadata_by_elem_id.getPtr(parent_elem_id.raw()) orelse @panic("render child insertion was missing parent links");

    var previous: ?ElemId = null;
    var next = parent_metadata.first_child;
    var cursor: usize = 0;
    while (cursor < index) : (cursor += 1) {
        const child_id = next orelse @panic("render child insertion index exceeded parent child list");
        previous = child_id;
        next = nextRenderSibling(StreamType, stream, child_id);
    }

    for (elem_ids, 0..) |elem_id, elem_index| {
        const previous_insert = if (elem_index == 0) previous else elem_ids[elem_index - 1];
        const next_insert = if (elem_index + 1 < elem_ids.len) elem_ids[elem_index + 1] else next;
        ensurePreviousRenderSiblingSlot(StreamType, stream, allocator, elem_id).* = previous_insert;
        ensureNextRenderSiblingSlot(StreamType, stream, allocator, elem_id).* = next_insert;
    }

    if (previous) |previous_id| {
        const previous_metadata = stream.render_metadata_by_elem_id.getPtr(previous_id.raw()) orelse @panic("render child insertion referenced a previous child without links");
        previous_metadata.next_sibling = elem_ids[0];
    } else {
        parent_metadata.first_child = elem_ids[0];
    }
    if (next == null) {
        parent_metadata.last_child = elem_ids[elem_ids.len - 1];
    } else {
        ensurePreviousRenderSiblingSlot(StreamType, stream, allocator, next.?).* = elem_ids[elem_ids.len - 1];
    }
}

/// Replaces children index for the affected parent without rebuilding unrelated tree state.
pub fn replaceRenderChildrenIndex(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator, parent_elem_id: ElemId, elem_ids: []const ElemId) void {
    clearRenderChildren(StreamType, stream, parent_elem_id);
    insertRenderChildren(StreamType, stream, allocator, parent_elem_id, 0, elem_ids);
}

/// Maintains child insertion index for render index within the indexed descriptor stream used by both hosts.
pub fn childInsertionIndexForRenderIndex(comptime StreamType: type, stream: *const StreamType, parent_elem_id: ElemId, render_insert_index: usize) usize {
    var index: usize = 0;
    var child = firstRenderChild(StreamType, stream, parent_elem_id);
    while (child) |child_id| : (index += 1) {
        const child_render_index = renderNodeIndex(StreamType, stream, child_id) orelse @panic("render child index referenced a child without a render index");
        if (child_render_index >= render_insert_index) return index;
        child = nextRenderSibling(StreamType, stream, child_id);
    }
    return index;
}

/// Refreshes indexes from only across the range affected by a structural splice.
pub fn refreshRenderIndexesFrom(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator, start_index: usize, metrics: anytype) void {
    if (start_index > stream.render_nodes.items.len) @panic("render index refresh started past render node table");
    metrics.bump(.render_indexes_refreshed, @intCast(stream.render_nodes.items.len - start_index));
    for (stream.render_nodes.items[start_index..], start_index..) |node, index| {
        ensureRenderMetadata(StreamType, stream, allocator, asElemId(node.elem_id)).render_node = index;
    }
}

/// Refreshes indexes in range only across the range affected by a structural splice.
pub fn refreshRenderIndexesInRange(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator, start_index: usize, count: usize, metrics: anytype) void {
    if (start_index > stream.render_nodes.items.len) @panic("render index range refresh started past render node table");
    if (count > stream.render_nodes.items.len - start_index) @panic("render index range refresh exceeded render node table");
    metrics.bump(.render_indexes_refreshed, @intCast(count));
    for (stream.render_nodes.items[start_index..][0..count], start_index..) |node, index| {
        ensureRenderMetadata(StreamType, stream, allocator, asElemId(node.elem_id)).render_node = index;
    }
}

/// Appends element using capacity that must already satisfy the caller's transaction contract.
pub fn appendElement(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator, elem_id: ElemId, parent_elem_id: ElemId, scope_id: ScopeId, tag: []const u8) ElemId {
    stream.next_elem_id += 1;

    const tag_copy = allocator.dupe(u8, tag) catch @panic("out of memory");
    const element_index = stream.elements.items.len;
    const render_index = stream.render_nodes.items.len;
    stream.render_nodes.append(allocator, .{ .elem_id = elem_id, .kind = .element }) catch {
        allocator.free(tag_copy);
        @panic("out of memory");
    };
    stream.elements.append(allocator, .{
        .elem_id = elem_id,
        .parent_elem_id = parent_elem_id,
        .scope_id = scope_id,
        .tag = tag_copy,
    }) catch {
        allocator.free(tag_copy);
        @panic("out of memory");
    };
    recordElementIndex(StreamType, stream, allocator, elem_id, element_index);
    recordRenderNodeIndex(StreamType, stream, allocator, elem_id, render_index);
    appendRenderChild(StreamType, stream, allocator, parent_elem_id, elem_id);
    return elem_id;
}

/// Appends text node using capacity that must already satisfy the caller's transaction contract.
pub fn appendTextNode(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator, elem_id: ElemId, parent_elem_id: ElemId, scope_id: ScopeId, value: []const u8) void {
    stream.next_elem_id += 1;

    const value_copy = allocator.dupe(u8, value) catch @panic("out of memory");
    const text_node_index = stream.text_nodes.items.len;
    const render_index = stream.render_nodes.items.len;
    stream.render_nodes.append(allocator, .{ .elem_id = elem_id, .kind = .text }) catch {
        allocator.free(value_copy);
        @panic("out of memory");
    };
    stream.text_nodes.append(allocator, .{
        .elem_id = elem_id,
        .parent_elem_id = parent_elem_id,
        .scope_id = scope_id,
        .value = value_copy,
    }) catch {
        allocator.free(value_copy);
        @panic("out of memory");
    };
    recordTextNodeIndex(StreamType, stream, allocator, elem_id, text_node_index);
    recordRenderNodeIndex(StreamType, stream, allocator, elem_id, render_index);
    appendRenderChild(StreamType, stream, allocator, parent_elem_id, elem_id);
}

/// Appends static text attr using capacity that must already satisfy the caller's transaction contract.
pub fn appendStaticTextAttr(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator, elem_id: ElemId, field: TextField, value: []const u8) void {
    const value_copy = allocator.dupe(u8, value) catch @panic("out of memory");
    const attr_index = stream.static_text_attrs.items.len;
    stream.static_text_attrs.append(allocator, .{
        .elem_id = elem_id,
        .field = field,
        .value = value_copy,
    }) catch {
        allocator.free(value_copy);
        @panic("out of memory");
    };
    recordStaticTextAttrIndex(StreamType, stream, allocator, elem_id.raw(), field, attr_index);
}

/// Maintains custom text attr descriptor exists within the indexed descriptor stream used by both hosts.
pub fn customTextAttrDescriptorExists(comptime StreamType: type, stream: *const StreamType, elem_id: ElemId, name: []const u8) bool {
    return customAttrDescriptorExists(StreamType, stream, elem_id, name);
}

/// Maintains custom attr descriptor exists within the indexed descriptor stream used by both hosts.
pub fn customAttrDescriptorExists(comptime StreamType: type, stream: *const StreamType, elem_id: ElemId, name: []const u8) bool {
    if (@hasField(StreamType, "custom_attr_keys")) {
        if (stream.custom_attr_index_active) {
            return stream.custom_attr_keys.contains(.{ .elem_id = elem_id, .name = name });
        }
    }

    var attrs = customAttrRefs(StreamType, stream);
    while (attrs.next()) |attr| {
        if (attr.matches(elem_id.raw(), name)) return true;
    }
    return false;
}

fn customAttrDescriptorExistsForAppend(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator, elem_id: u64, name: []const u8) bool {
    if (@hasField(StreamType, "custom_attr_keys")) {
        tryActivateCustomAttrIndex(StreamType, stream, allocator) catch |err| switch (err) {
            error.OutOfMemory => @panic("out of memory"),
            error.ResourceLimit => @panic("custom attr index exceeded its bound"),
        };
    }
    return customAttrDescriptorExists(StreamType, stream, ElemId.fromRaw(elem_id), name);
}

fn tryActivateCustomAttrIndex(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator) ReserveError!void {
    if (!@hasField(StreamType, "custom_attr_keys") or stream.custom_attr_index_active) return;
    const attr_count = stream.static_custom_text_attrs.items.len +
        stream.signal_custom_text_attrs.items.len +
        stream.signal_optional_custom_text_attrs.items.len +
        stream.static_custom_bool_attrs.items.len +
        stream.signal_custom_bool_attrs.items.len;
    var keys: CustomAttrKeySet = .empty;
    errdefer keys.deinit(allocator);
    const key_capacity = std.math.add(usize, attr_count, 1) catch return error.ResourceLimit;
    try keys.ensureTotalCapacity(allocator, std.math.cast(u32, key_capacity) orelse return error.ResourceLimit);
    var by_elem: std.ArrayListUnmanaged(std.ArrayListUnmanaged(CustomAttrDescriptorIndex)) = .empty;
    errdefer {
        for (by_elem.items) |*indexes| indexes.deinit(allocator);
        by_elem.deinit(allocator);
    }
    var attrs = customAttrRefs(StreamType, stream);
    while (attrs.next()) |attr| {
        const elem_index = attr.elem_id.index();
        const required = std.math.add(usize, elem_index, 1) catch return error.ResourceLimit;
        try by_elem.ensureTotalCapacity(allocator, required);
        while (by_elem.items.len < required) by_elem.appendAssumeCapacity(.empty);
        const descriptor_index = CustomAttrDescriptorIndex{ .kind = attr.kind, .index = attr.index };
        try by_elem.items[elem_index].append(allocator, descriptor_index);
        const key = CustomAttrKey{ .elem_id = attr.elem_id, .name = attr.name };
        if (keys.contains(key)) @panic("element has duplicate custom attribute descriptors");
        keys.putAssumeCapacity(key, descriptor_index);
    }
    stream.custom_attr_keys.deinit(allocator);
    for (stream.custom_attr_indices_by_elem_id.items) |*indexes| indexes.deinit(allocator);
    stream.custom_attr_indices_by_elem_id.deinit(allocator);
    stream.custom_attr_keys = keys;
    stream.custom_attr_indices_by_elem_id = by_elem;
    stream.custom_attr_index_active = true;
}

fn reserveCustomAttrIndexEntry(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator, elem_id: u64) ReserveError!void {
    if (!@hasField(StreamType, "custom_attr_keys")) return;
    if (!stream.custom_attr_index_active) return;
    try stream.custom_attr_keys.ensureUnusedCapacity(allocator, 1);
    const elem_index = std.math.cast(usize, elem_id) orelse return error.ResourceLimit;
    const required = std.math.add(usize, elem_index, 1) catch return error.ResourceLimit;
    try stream.custom_attr_indices_by_elem_id.ensureTotalCapacity(allocator, required);
    while (stream.custom_attr_indices_by_elem_id.items.len < required) stream.custom_attr_indices_by_elem_id.appendAssumeCapacity(.empty);
    try stream.custom_attr_indices_by_elem_id.items[elem_index].ensureUnusedCapacity(allocator, 1);
}

fn recordCustomAttrKeyAssumeCapacity(comptime StreamType: type, stream: *StreamType, elem_id: u64, name: []const u8, kind: CustomAttrKind, index: usize) void {
    if (!@hasField(StreamType, "custom_attr_keys")) return;
    if (!stream.custom_attr_index_active) return;
    const descriptor_index = CustomAttrDescriptorIndex{ .kind = kind, .index = index };
    stream.custom_attr_keys.putAssumeCapacity(.{ .elem_id = ElemId.fromRaw(elem_id), .name = name }, descriptor_index);
    stream.custom_attr_indices_by_elem_id.items[@intCast(elem_id)].appendAssumeCapacity(descriptor_index);
}

/// Appends static custom text attr using capacity that must already satisfy the caller's transaction contract.
pub fn appendStaticCustomTextAttr(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator, elem_id: ElemId, name: []const u8, value: []const u8) void {
    if (name.len == 0) @panic("custom text attr descriptor used an empty name");
    if (customAttrDescriptorExistsForAppend(StreamType, stream, allocator, elem_id.raw(), name)) @panic("element has duplicate custom text attr descriptors");

    const name_copy = allocator.dupe(u8, name) catch @panic("out of memory");
    const value_copy = allocator.dupe(u8, value) catch {
        allocator.free(name_copy);
        @panic("out of memory");
    };
    stream.static_custom_text_attrs.ensureUnusedCapacity(allocator, 1) catch {
        allocator.free(name_copy);
        allocator.free(value_copy);
        @panic("out of memory");
    };
    reserveCustomAttrIndexEntry(StreamType, stream, allocator, elem_id.raw()) catch {
        allocator.free(name_copy);
        allocator.free(value_copy);
        @panic("out of memory");
    };
    const index = stream.static_custom_text_attrs.items.len;
    stream.static_custom_text_attrs.appendAssumeCapacity(.{
        .elem_id = elem_id,
        .name = name_copy,
        .value = value_copy,
    });
    recordCustomAttrKeyAssumeCapacity(StreamType, stream, elem_id.raw(), name_copy, .static_text, index);
}

/// Appends static custom bool attr using capacity that must already satisfy the caller's transaction contract.
pub fn appendStaticCustomBoolAttr(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator, elem_id: ElemId, name: []const u8, value: bool) void {
    if (name.len == 0) @panic("custom bool attr descriptor used an empty name");
    if (customAttrDescriptorExistsForAppend(StreamType, stream, allocator, elem_id.raw(), name)) @panic("element has duplicate custom attr descriptors");

    const name_copy = allocator.dupe(u8, name) catch @panic("out of memory");
    stream.static_custom_bool_attrs.ensureUnusedCapacity(allocator, 1) catch {
        allocator.free(name_copy);
        @panic("out of memory");
    };
    reserveCustomAttrIndexEntry(StreamType, stream, allocator, elem_id.raw()) catch {
        allocator.free(name_copy);
        @panic("out of memory");
    };
    const index = stream.static_custom_bool_attrs.items.len;
    stream.static_custom_bool_attrs.appendAssumeCapacity(.{
        .elem_id = elem_id,
        .name = name_copy,
        .value = value,
    });
    recordCustomAttrKeyAssumeCapacity(StreamType, stream, elem_id.raw(), name_copy, .static_bool, index);
}

/// Appends static bool attr using capacity that must already satisfy the caller's transaction contract.
pub fn appendStaticBoolAttr(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator, elem_id: ElemId, field: BoolField, value: bool) void {
    const attr_index = stream.static_bool_attrs.items.len;
    stream.static_bool_attrs.append(allocator, .{
        .elem_id = elem_id,
        .field = field,
        .value = value,
    }) catch @panic("out of memory");
    recordStaticBoolAttrIndex(StreamType, stream, allocator, elem_id.raw(), field, attr_index);
}

/// Appends cleanup using capacity that must already satisfy the caller's transaction contract.
pub fn appendCleanup(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator, scope_id: ScopeId, name: []const u8) void {
    const name_copy = allocator.dupe(u8, name) catch @panic("out of memory");
    stream.cleanups.append(allocator, .{
        .scope_id = scope_id,
        .name = name_copy,
    }) catch {
        allocator.free(name_copy);
        @panic("out of memory");
    };
}

/// Appends scope site using capacity that must already satisfy the caller's transaction contract.
pub fn appendScopeSite(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator, node_id: NodeId, scope_id: ScopeId, ordinal: SiteOrdinal, parent_elem_id: ElemId, kind: ScopeSiteKind, binder_bindings: []const BinderBinding) void {
    appendScopeSiteAt(StreamType, stream, allocator, node_id, scope_id, ordinal, parent_elem_id, stream.render_nodes.items.len, kind, binder_bindings);
}

/// Appends scope site at using capacity that must already satisfy the caller's transaction contract.
pub fn appendScopeSiteAt(comptime StreamType: type, stream: *StreamType, allocator: std.mem.Allocator, node_id: NodeId, scope_id: ScopeId, ordinal: SiteOrdinal, parent_elem_id: ElemId, render_insert_index: usize, kind: ScopeSiteKind, binder_bindings: []const BinderBinding) void {
    const binder_copy = allocator.dupe(BinderBinding, binder_bindings) catch @panic("out of memory");
    const scope_site_index = stream.scope_sites.items.len;
    stream.scope_sites.append(allocator, .{
        .node_id = node_id,
        .scope_id = scope_id,
        .ordinal = ordinal,
        .parent_elem_id = parent_elem_id,
        .render_insert_index = render_insert_index,
        .kind = kind,
        .binder_bindings = binder_copy,
    }) catch {
        allocator.free(binder_copy);
        @panic("out of memory");
    };
    recordScopeSiteIndex(StreamType, stream, allocator, node_id.raw(), kind, scope_site_index);
}

/// Resolves element desc from maintained indexes without scanning the full descriptor stream.
pub fn findElementDesc(comptime StreamType: type, stream: *const StreamType, elem_id: ElemId) ?StreamType.ElementDesc {
    const descriptor_index = stream.elemDescriptorIndex(elem_id) orelse return null;
    const index = descriptor_index.element.get() orelse return null;
    if (index >= stream.elements.items.len) @panic("element descriptor index exceeded descriptor table");
    const desc = stream.elements.items[index];
    if (identityRaw(desc.elem_id) != elem_id.raw()) @panic("element descriptor index pointed at the wrong elem id");
    return desc;
}

/// Resolves text node desc from maintained indexes without scanning the full descriptor stream.
pub fn findTextNodeDesc(comptime StreamType: type, stream: *const StreamType, elem_id: ElemId) ?StreamType.TextNodeDesc {
    const descriptor_index = stream.elemDescriptorIndex(elem_id) orelse return null;
    const index = descriptor_index.text_node.get() orelse return null;
    if (index >= stream.text_nodes.items.len) @panic("text node descriptor index exceeded descriptor table");
    const desc = stream.text_nodes.items[index];
    if (identityRaw(desc.elem_id) != elem_id.raw()) @panic("text node descriptor index pointed at the wrong elem id");
    return desc;
}

/// Resolves signal text node desc from maintained indexes without scanning the full descriptor stream.
pub fn findSignalTextNodeDesc(comptime StreamType: type, stream: *const StreamType, elem_id: ElemId) ?StreamType.SignalTextNodeDesc {
    const descriptor_index = stream.elemDescriptorIndex(elem_id) orelse return null;
    const index = descriptor_index.signal_text_node.get() orelse return null;
    if (index >= stream.signal_text_nodes.items.len) @panic("signal text node descriptor index exceeded descriptor table");
    const desc = stream.signal_text_nodes.items[index];
    if (identityRaw(desc.elem_id) != elem_id.raw()) @panic("signal text node descriptor index pointed at the wrong elem id");
    return desc;
}

/// Resolves signal text node desc mutable from maintained indexes without scanning the full descriptor stream.
pub fn findSignalTextNodeDescMutable(comptime StreamType: type, stream: *StreamType, elem_id: ElemId) ?*StreamType.SignalTextNodeDesc {
    const descriptor_index = stream.elemDescriptorIndex(elem_id) orelse return null;
    const index = descriptor_index.signal_text_node.get() orelse return null;
    if (index >= stream.signal_text_nodes.items.len) @panic("signal text node descriptor index exceeded descriptor table");
    const desc = &stream.signal_text_nodes.items[index];
    if (identityRaw(desc.elem_id) != elem_id.raw()) @panic("signal text node descriptor index pointed at the wrong elem id");
    return desc;
}

/// Reports whether the selected element has text field in the active descriptor stream.
pub fn streamHasTextField(comptime StreamType: type, stream: *const StreamType, elem_id: ElemId, field: TextField) bool {
    const descriptor_index = stream.elemDescriptorIndex(elem_id) orelse return false;
    if (field == .text and descriptor_index.text_node != .none) return true;
    if (field == .text and descriptor_index.signal_text_node != .none) return true;

    if (descriptor_index.static_text_attrs.get(field)) |attr_index| {
        if (attr_index >= stream.static_text_attrs.items.len) @panic("static text attr descriptor index exceeded descriptor table");
        const desc = stream.static_text_attrs.items[attr_index];
        if (identityRaw(desc.elem_id) != elem_id.raw() or desc.field != field) @panic("static text attr descriptor index pointed at the wrong field");
        return true;
    }
    if (descriptor_index.signal_text_attrs.get(field)) |attr_index| {
        if (attr_index >= stream.signal_text_attrs.items.len) @panic("signal text attr descriptor index exceeded descriptor table");
        const desc = stream.signal_text_attrs.items[attr_index];
        if (identityRaw(desc.elem_id) != elem_id.raw() or desc.field != field) @panic("signal text attr descriptor index pointed at the wrong field");
        return true;
    }
    return false;
}

/// Reports whether the selected element has custom text attr in the active descriptor stream.
pub fn streamHasCustomTextAttr(comptime StreamType: type, stream: *const StreamType, elem_id: ElemId, name: []const u8) bool {
    var attrs = customAttrRefs(StreamType, stream);
    while (attrs.next()) |attr| {
        if (attr.kind.valueKind() == .text and attr.matches(elem_id.raw(), name)) return true;
    }
    return false;
}

/// Reports whether the selected element has bool field in the active descriptor stream.
pub fn streamHasBoolField(comptime StreamType: type, stream: *const StreamType, elem_id: ElemId, field: BoolField) bool {
    const descriptor_index = stream.elemDescriptorIndex(elem_id) orelse return false;
    if (descriptor_index.static_bool_attrs.get(field)) |attr_index| {
        if (attr_index >= stream.static_bool_attrs.items.len) @panic("static bool attr descriptor index exceeded descriptor table");
        const desc = stream.static_bool_attrs.items[attr_index];
        if (identityRaw(desc.elem_id) != elem_id.raw() or desc.field != field) @panic("static bool attr descriptor index pointed at the wrong field");
        return true;
    }
    if (descriptor_index.signal_bool_attrs.get(field)) |attr_index| {
        if (attr_index >= stream.signal_bool_attrs.items.len) @panic("signal bool attr descriptor index exceeded descriptor table");
        const desc = stream.signal_bool_attrs.items[attr_index];
        if (identityRaw(desc.elem_id) != elem_id.raw() or desc.field != field) @panic("signal bool attr descriptor index pointed at the wrong field");
        return true;
    }
    return false;
}

/// Maintains max render elem id within the indexed descriptor stream used by both hosts.
pub fn maxRenderElemId(comptime StreamType: type, stream: *const StreamType) u64 {
    var max_elem_id: u64 = 0;
    for (stream.render_nodes.items) |node| {
        max_elem_id = @max(max_elem_id, identityRaw(node.elem_id));
    }
    return max_elem_id;
}

/// Returns tag for an already indexed render node.
pub fn renderNodeTag(comptime StreamType: type, stream: *const StreamType, node: StreamType.RenderNode) []const u8 {
    return switch (node.kind) {
        .element => (findElementDesc(StreamType, stream, asElemId(node.elem_id)) orelse @panic("renderNodeTag: render node has no matching descriptor")).tag,
        .text, .signal_text => "text",
    };
}

/// Reads elem tag from the active descriptor stream using engine-owned identity.
pub fn streamElemTag(comptime StreamType: type, stream: *const StreamType, elem_id: ElemId) []const u8 {
    const descriptor_index = stream.elemDescriptorIndex(elem_id) orelse @panic("elem id had no descriptor index");
    if (descriptor_index.element.get()) |index| {
        if (index >= stream.elements.items.len) @panic("element descriptor index exceeded descriptor table");
        const desc = stream.elements.items[index];
        if (identityRaw(desc.elem_id) != elem_id.raw()) @panic("element descriptor index pointed at the wrong elem id");
        return desc.tag;
    }
    if (descriptor_index.text_node != .none or descriptor_index.signal_text_node != .none) return "text";
    @panic("elem id had no render descriptor");
}

/// Returns parent elem id for an already indexed render node.
pub fn renderNodeParentElemId(comptime StreamType: type, stream: *const StreamType, node: StreamType.RenderNode) ElemId {
    return switch (node.kind) {
        .element => asElemId((findElementDesc(StreamType, stream, asElemId(node.elem_id)) orelse @panic("renderNodeParentElemId: render node has no matching descriptor")).parent_elem_id),
        .text => asElemId((findTextNodeDesc(StreamType, stream, asElemId(node.elem_id)) orelse @panic("renderNodeParentElemId: render node has no matching descriptor")).parent_elem_id),
        .signal_text => asElemId((findSignalTextNodeDesc(StreamType, stream, asElemId(node.elem_id)) orelse @panic("renderNodeParentElemId: render node has no matching descriptor")).parent_elem_id),
    };
}

/// Reads elem parent elem id from the active descriptor stream using engine-owned identity.
pub fn streamElemParentElemId(comptime StreamType: type, stream: *const StreamType, elem_id: ElemId) ElemId {
    const descriptor_index = stream.elemDescriptorIndex(elem_id) orelse @panic("elem id had no descriptor index");
    if (descriptor_index.element.get()) |index| {
        if (index >= stream.elements.items.len) @panic("element descriptor index exceeded descriptor table");
        const desc = stream.elements.items[index];
        if (identityRaw(desc.elem_id) != elem_id.raw()) @panic("element descriptor index pointed at the wrong elem id");
        return asElemId(desc.parent_elem_id);
    }
    if (descriptor_index.text_node.get()) |index| {
        if (index >= stream.text_nodes.items.len) @panic("text node descriptor index exceeded descriptor table");
        const desc = stream.text_nodes.items[index];
        if (identityRaw(desc.elem_id) != elem_id.raw()) @panic("text node descriptor index pointed at the wrong elem id");
        return asElemId(desc.parent_elem_id);
    }
    if (descriptor_index.signal_text_node.get()) |index| {
        if (index >= stream.signal_text_nodes.items.len) @panic("signal text node descriptor index exceeded descriptor table");
        const desc = stream.signal_text_nodes.items[index];
        if (identityRaw(desc.elem_id) != elem_id.raw()) @panic("signal text node descriptor index pointed at the wrong elem id");
        return asElemId(desc.parent_elem_id);
    }
    @panic("elem id had no render descriptor");
}

/// Appends stream direct children using capacity that must already satisfy the caller's transaction contract.
pub fn appendStreamDirectChildren(comptime StreamType: type, allocator: std.mem.Allocator, stream: *const StreamType, parent_elem_id: ElemId, children: *std.ArrayListUnmanaged(ElemId)) void {
    var child = stream.firstRenderChild(parent_elem_id);
    while (child) |child_id| {
        children.append(allocator, child_id) catch @panic("out of memory");
        child = stream.nextRenderSibling(child_id);
    }
}

/// Reads direct children into from the active descriptor stream using engine-owned identity.
pub fn streamDirectChildrenInto(comptime StreamType: type, allocator: std.mem.Allocator, stream: *const StreamType, parent_elem_id: ElemId, children: *std.ArrayListUnmanaged(ElemId)) []const ElemId {
    children.clearRetainingCapacity();
    appendStreamDirectChildren(StreamType, allocator, stream, parent_elem_id, children);
    return children.items;
}

/// Reads direct children from the active descriptor stream using engine-owned identity.
pub fn streamDirectChildren(comptime StreamType: type, allocator: std.mem.Allocator, stream: *const StreamType, parent_elem_id: ElemId) []ElemId {
    var children: std.ArrayListUnmanaged(ElemId) = .empty;
    errdefer children.deinit(allocator);

    appendStreamDirectChildren(StreamType, allocator, stream, parent_elem_id, &children);
    return children.toOwnedSlice(allocator) catch @panic("out of memory");
}

/// Returns scope id for an already indexed render node.
pub fn renderNodeScopeId(comptime StreamType: type, stream: *const StreamType, node: StreamType.RenderNode) ScopeId {
    return switch (node.kind) {
        .element => ScopeId.fromRaw(identityRaw((findElementDesc(StreamType, stream, asElemId(node.elem_id)) orelse @panic("renderNodeScopeId: render node has no matching descriptor")).scope_id)),
        .text => ScopeId.fromRaw(identityRaw((findTextNodeDesc(StreamType, stream, asElemId(node.elem_id)) orelse @panic("renderNodeScopeId: render node has no matching descriptor")).scope_id)),
        .signal_text => ScopeId.fromRaw(identityRaw((findSignalTextNodeDesc(StreamType, stream, asElemId(node.elem_id)) orelse @panic("renderNodeScopeId: render node has no matching descriptor")).scope_id)),
    };
}

/// Maintains elem scope id within the indexed descriptor stream used by both hosts.
pub fn elemScopeId(comptime StreamType: type, stream: *const StreamType, elem_id: ElemId) ?ScopeId {
    const descriptor_index = stream.elemDescriptorIndex(elem_id) orelse return null;
    if (descriptor_index.element.get()) |index| {
        if (index >= stream.elements.items.len) @panic("element descriptor index exceeded descriptor table");
        const desc = stream.elements.items[index];
        if (identityRaw(desc.elem_id) != elem_id.raw()) @panic("element descriptor index pointed at the wrong elem id");
        return ScopeId.fromRaw(identityRaw(desc.scope_id));
    }
    if (descriptor_index.text_node.get()) |index| {
        if (index >= stream.text_nodes.items.len) @panic("text node descriptor index exceeded descriptor table");
        const desc = stream.text_nodes.items[index];
        if (identityRaw(desc.elem_id) != elem_id.raw()) @panic("text node descriptor index pointed at the wrong elem id");
        return ScopeId.fromRaw(identityRaw(desc.scope_id));
    }
    if (descriptor_index.signal_text_node.get()) |index| {
        if (index >= stream.signal_text_nodes.items.len) @panic("signal text node descriptor index exceeded descriptor table");
        const desc = stream.signal_text_nodes.items[index];
        if (identityRaw(desc.elem_id) != elem_id.raw()) @panic("signal text node descriptor index pointed at the wrong elem id");
        return ScopeId.fromRaw(identityRaw(desc.scope_id));
    }
    return null;
}

/// Maintains adjusted render insert index within the indexed descriptor stream used by both hosts.
pub fn adjustedRenderInsertIndex(old_index: usize, replace_index: usize, removed_count: usize, replacement_count: usize) usize {
    if (removed_count == 0) {
        if (old_index < replace_index) return old_index;
        return old_index + replacement_count;
    }
    if (old_index <= replace_index) return old_index;
    if (old_index < replace_index + removed_count) @panic("scope site inside replaced scope was not removed");
    return old_index - removed_count + replacement_count;
}

const TestElementDesc = struct {
    elem_id: u64,
    parent_elem_id: u64,
    scope_id: u64,
    tag: []const u8,
};

const TestTextNodeDesc = struct {
    elem_id: u64,
    parent_elem_id: u64,
    scope_id: u64,
};

const TestStaticTextAttrDesc = struct {
    elem_id: u64,
    field: TextField,
};

const TestCustomTextAttrDesc = struct {
    elem_id: u64,
    name: []const u8,
};

const TestStaticBoolAttrDesc = struct {
    elem_id: u64,
    field: BoolField,
};

const TestRenderNode = RenderNode;

const TestStream = struct {
    pub const RenderNode = TestRenderNode;
    pub const ElementDesc = TestElementDesc;
    pub const TextNodeDesc = TestTextNodeDesc;
    pub const SignalTextNodeDesc = TestTextNodeDesc;

    render_nodes: std.ArrayListUnmanaged(TestRenderNode) = .empty,
    elements: std.ArrayListUnmanaged(TestElementDesc) = .empty,
    text_nodes: std.ArrayListUnmanaged(TestTextNodeDesc) = .empty,
    signal_text_nodes: std.ArrayListUnmanaged(TestTextNodeDesc) = .empty,
    static_text_attrs: std.ArrayListUnmanaged(TestStaticTextAttrDesc) = .empty,
    signal_text_attrs: std.ArrayListUnmanaged(TestStaticTextAttrDesc) = .empty,
    static_custom_text_attrs: std.ArrayListUnmanaged(TestCustomTextAttrDesc) = .empty,
    signal_custom_text_attrs: std.ArrayListUnmanaged(TestCustomTextAttrDesc) = .empty,
    signal_optional_custom_text_attrs: std.ArrayListUnmanaged(TestCustomTextAttrDesc) = .empty,
    static_custom_bool_attrs: std.ArrayListUnmanaged(TestCustomTextAttrDesc) = .empty,
    signal_custom_bool_attrs: std.ArrayListUnmanaged(TestCustomTextAttrDesc) = .empty,
    static_bool_attrs: std.ArrayListUnmanaged(TestStaticBoolAttrDesc) = .empty,
    signal_bool_attrs: std.ArrayListUnmanaged(TestStaticBoolAttrDesc) = .empty,
    descriptor_indexes_by_elem_id: std.ArrayListUnmanaged(ElemDescriptorIndex) = .empty,
    render_metadata_by_elem_id: std.AutoHashMapUnmanaged(u64, RenderElemIndex) = .empty,

    fn deinit(self: *TestStream, allocator: std.mem.Allocator) void {
        self.render_nodes.deinit(allocator);
        self.elements.deinit(allocator);
        self.text_nodes.deinit(allocator);
        self.signal_text_nodes.deinit(allocator);
        self.static_text_attrs.deinit(allocator);
        self.signal_text_attrs.deinit(allocator);
        self.static_custom_text_attrs.deinit(allocator);
        self.signal_custom_text_attrs.deinit(allocator);
        self.signal_optional_custom_text_attrs.deinit(allocator);
        self.static_custom_bool_attrs.deinit(allocator);
        self.signal_custom_bool_attrs.deinit(allocator);
        self.static_bool_attrs.deinit(allocator);
        self.signal_bool_attrs.deinit(allocator);
        self.descriptor_indexes_by_elem_id.deinit(allocator);
        self.render_metadata_by_elem_id.deinit(allocator);
        self.* = .{};
    }

    fn elemDescriptorIndex(self: *const TestStream, elem_id: ElemId) ?ElemDescriptorIndex {
        if (elem_id.index() >= self.descriptor_indexes_by_elem_id.items.len) return null;
        return self.descriptor_indexes_by_elem_id.items[elem_id.index()];
    }

    fn firstRenderChild(self: *const TestStream, parent_elem_id: ElemId) ?ElemId {
        const metadata = self.render_metadata_by_elem_id.get(parent_elem_id.raw()) orelse return null;
        return metadata.first_child;
    }

    fn nextRenderSibling(self: *const TestStream, elem_id: ElemId) ?ElemId {
        const metadata = self.render_metadata_by_elem_id.get(elem_id.raw()) orelse return null;
        return metadata.next_sibling;
    }
};

fn ensureTestElemDescriptorIndex(stream: *TestStream, allocator: std.mem.Allocator, elem_id: u64) *ElemDescriptorIndex {
    const index: usize = @intCast(elem_id);
    while (stream.descriptor_indexes_by_elem_id.items.len <= index) {
        stream.descriptor_indexes_by_elem_id.append(allocator, .{}) catch @panic("out of memory");
    }
    return &stream.descriptor_indexes_by_elem_id.items[index];
}

const TestMetrics = struct {
    render_indexes_refreshed: u64 = 0,

    /// Increments  for exact structural-work accounting.
    pub fn bump(self: *TestMetrics, comptime field: anytype, count: u64) void {
        switch (field) {
            .render_indexes_refreshed => self.render_indexes_refreshed += count,
            else => {},
        }
    }
};

fn deinitStaticPreparedTestStream(stream: *Stream, allocator: std.mem.Allocator) void {
    for (stream.elements.items) |desc| allocator.free(desc.tag);
    for (stream.text_nodes.items) |desc| allocator.free(desc.value);
    stream.render_nodes.deinit(allocator);
    stream.elements.deinit(allocator);
    stream.text_nodes.deinit(allocator);
    stream.signal_text_attrs.deinit(allocator);
    stream.signal_bool_attrs.deinit(allocator);
    stream.signal_custom_text_attrs.deinit(allocator);
    stream.signal_optional_custom_text_attrs.deinit(allocator);
    stream.signal_custom_bool_attrs.deinit(allocator);
    stream.descriptor_indexes_by_elem_id.deinit(allocator);
    stream.render_metadata_by_elem_id.deinit(allocator);
    for (stream.scope_descriptor_ownership.items) |*ownership| ownership.deinit(allocator);
    stream.scope_descriptor_ownership.deinit(allocator);
}

test "prepared static append sweeps allocation failures without logical mutation and retries" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var counter = FaultAllocator.init(std.testing.allocator);
    var counted_stream: Stream = .{};
    try counted_stream.reserveScopeDescriptorOwnership(std.testing.allocator, ScopeId.fromRaw(0), 1, 0);
    const counted = try counted_stream.prepareElement(counter.allocator(), ElemId.fromRaw(1), ElemId.fromRaw(0), ScopeId.fromRaw(0), "section");
    counted.abort(counter.allocator());
    deinitStaticPreparedTestStream(&counted_stream, std.testing.allocator);
    const attempts = counter.attempts;
    try std.testing.expect(attempts >= 5);

    for (1..attempts + 1) |failure_number| {
        var fault = FaultAllocator.init(std.testing.allocator);
        var stream: Stream = .{};
        defer deinitStaticPreparedTestStream(&stream, std.testing.allocator);
        try stream.reserveScopeDescriptorOwnership(std.testing.allocator, ScopeId.fromRaw(0), 1, 0);
        fault.configure(failure_number);
        try std.testing.expectError(error.OutOfMemory, stream.prepareElement(fault.allocator(), ElemId.fromRaw(1), ElemId.fromRaw(0), ScopeId.fromRaw(0), "section"));
        try std.testing.expectEqual(@as(u64, 1), stream.next_elem_id);
        try std.testing.expectEqual(@as(usize, 0), stream.render_nodes.items.len);
        try std.testing.expectEqual(@as(usize, 0), stream.elements.items.len);
        try std.testing.expectEqual(@as(usize, 0), stream.descriptor_indexes_by_elem_id.items.len);
        try std.testing.expectEqual(@as(usize, 0), stream.render_metadata_by_elem_id.count());

        fault.configure(null);
        const retry = try stream.prepareElement(fault.allocator(), ElemId.fromRaw(1), ElemId.fromRaw(0), ScopeId.fromRaw(0), "section");
        stream.appendPreparedStaticNode(retry);
        try std.testing.expectEqual(@as(u64, 2), stream.next_elem_id);
        try std.testing.expectEqual(@as(usize, 1), stream.render_nodes.items.len);
        try std.testing.expectEqual(@as(usize, 1), stream.elements.items.len);
        try std.testing.expectEqualStrings("section", stream.elements.items[0].tag);
        try std.testing.expectEqual(ElemId.fromRaw(1), stream.firstRenderChild(ElemId.fromRaw(0)).?);
        try std.testing.expectEqualSlices(ElemId, &.{ElemId.fromRaw(1)}, stream.scopeOwnedElemIds(ScopeId.fromRaw(0)));
    }
}

test "prepared static batch reserves cumulative allocation-free publication capacity" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var fault = FaultAllocator.init(std.testing.allocator);
    var stream: Stream = .{};
    defer deinitStaticPreparedTestStream(&stream, std.testing.allocator);

    try stream.reservePreparedStaticNodes(fault.allocator(), 2, 2);
    try stream.reserveScopeDescriptorOwnership(std.testing.allocator, ScopeId.fromRaw(0), 2, 0);
    const element = try stream.prepareElement(fault.allocator(), ElemId.fromRaw(1), ElemId.fromRaw(0), ScopeId.fromRaw(0), "div");
    const text = try stream.prepareTextNode(fault.allocator(), ElemId.fromRaw(2), ElemId.fromRaw(1), ScopeId.fromRaw(0), "hello");

    fault.configure(1);
    stream.appendPreparedStaticNode(element);
    stream.appendPreparedStaticNode(text);
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqual(@as(usize, 2), stream.render_nodes.items.len);
    try std.testing.expectEqual(@as(usize, 1), stream.elements.items.len);
    try std.testing.expectEqual(@as(usize, 1), stream.text_nodes.items.len);
    try std.testing.expectEqualStrings("hello", stream.text_nodes.items[0].value);
}

test "prepared signal attr reservation leaves logical stream empty" {
    var stream: Stream = .{};
    defer deinitStaticPreparedTestStream(&stream, std.testing.allocator);
    try stream.reservePreparedSignalAttrs(std.testing.allocator, 3, 7);
    try std.testing.expect(stream.signal_text_attrs.capacity >= 3);
    try std.testing.expect(stream.signal_bool_attrs.capacity >= 3);
    try std.testing.expect(stream.descriptor_indexes_by_elem_id.capacity >= 8);
    try std.testing.expectEqual(@as(usize, 0), stream.signal_text_attrs.items.len);
    try std.testing.expectEqual(@as(usize, 0), stream.signal_bool_attrs.items.len);
    try std.testing.expectEqual(@as(usize, 0), stream.descriptor_indexes_by_elem_id.items.len);
    try std.testing.expect(stream.elemDescriptorIndex(ElemId.fromRaw(7)) == null);
}

test "prepared custom attribute reservation activates the maintained per-element index" {
    const allocator = std.testing.allocator;
    var stream: Stream = .{};

    try stream.static_custom_text_attrs.ensureUnusedCapacity(allocator, 1);
    try stream.custom_attr_keys.ensureUnusedCapacity(allocator, 1);
    try stream.reservePreparedCustomAttrElem(allocator, 35, 1);
    const name = try allocator.dupe(u8, "data-state");
    const value = try allocator.dupe(u8, "ready");
    stream.static_custom_text_attrs.appendAssumeCapacity(.{ .elem_id = ElemId.fromRaw(35), .name = name, .value = value });
    stream.recordPreparedCustomAttrIndex(ElemId.fromRaw(35), name, .{ .kind = .static_text, .index = 0 });
    defer {
        allocator.free(name);
        allocator.free(value);
        stream.static_custom_text_attrs.deinit(allocator);
        stream.custom_attr_keys.deinit(allocator);
        for (stream.custom_attr_indices_by_elem_id.items) |*indexes| indexes.deinit(allocator);
        stream.custom_attr_indices_by_elem_id.deinit(allocator);
    }

    try std.testing.expect(stream.custom_attr_index_active);
    try std.testing.expectEqual(@as(usize, 1), stream.customAttrIndices(ElemId.fromRaw(35)).len);
    try std.testing.expectEqual(CustomAttrKind.static_text, stream.customAttrIndices(ElemId.fromRaw(35))[0].kind);
}

test "element-local custom attribute reservation scales with attribute count" {
    const allocator = std.testing.allocator;
    var stream: Stream = .{};
    defer {
        for (stream.custom_attr_indices_by_elem_id.items) |*indexes| indexes.deinit(allocator);
        stream.custom_attr_indices_by_elem_id.deinit(allocator);
    }

    const element_count = 1024;
    for (0..element_count) |index| try stream.reservePreparedCustomAttrEntry(allocator, index);

    var reserved_entries: usize = 0;
    for (stream.custom_attr_indices_by_elem_id.items) |indexes| reserved_entries += indexes.capacity;
    try std.testing.expect(reserved_entries <= element_count * 16);
}

test "failed prepared custom attribute reservation does not activate an incomplete index" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var fault = FaultAllocator.init(std.testing.allocator);
    var stream: Stream = .{};
    defer {
        for (stream.custom_attr_indices_by_elem_id.items) |*indexes| indexes.deinit(fault.allocator());
        stream.custom_attr_indices_by_elem_id.deinit(fault.allocator());
    }

    fault.configure(1);
    try std.testing.expectError(error.OutOfMemory, stream.reservePreparedCustomAttrElem(fault.allocator(), 35, 1));
    try std.testing.expect(!stream.custom_attr_index_active);
    try std.testing.expectEqual(@as(usize, 0), stream.customAttrIndices(ElemId.fromRaw(35)).len);
}

test "prepared signal attr publication is allocation free" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    const TestCtx = struct {
        /// Opens a checked capability frame for an app-compiled erased call.
        pub fn pushHostValueCapabilities(_: *@This(), _: []const retained.HostValueCapability) void {}
        /// Closes the current capability frame after an app-compiled erased call.
        pub fn popHostValueCapabilities(_: *@This()) void {}
    };

    var fault = FaultAllocator.init(std.testing.allocator);
    const allocator = fault.allocator();
    var stream: Stream = .{};
    var ctx: TestCtx = .{};
    var env = abi.RocEnv{ .allocator = allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&env);
    var metrics = TestMetrics{};
    defer stream.deinit(allocator, &ctx, &roc_host, &metrics);

    try stream.reservePreparedSignalAttrs(allocator, 2, 2);
    const text_record = try SignalRecord.tryInit(allocator, .{ .ref = 1 });
    const bool_record = try SignalRecord.tryInit(allocator, .{ .ref = 2 });
    const text_sources = try allocator.dupe(u64, &.{1});
    const bool_sources = try allocator.dupe(u64, &.{2});
    const text = Stream.PreparedSignalDescriptor{ .text_attr = .{
        .elem_id = ElemId.fromRaw(1),
        .field = .label,
        .signal = .{ .record = text_record, .source_node_ids = text_sources },
        .read = std.mem.zeroes(HostTextRead),
    } };
    const boolean = Stream.PreparedSignalDescriptor{ .bool_attr = .{
        .elem_id = ElemId.fromRaw(2),
        .field = .disabled,
        .signal = .{ .record = bool_record, .source_node_ids = bool_sources },
        .read = std.mem.zeroes(HostBoolRead),
    } };

    fault.configure(1);
    stream.appendPreparedSignalDescriptor(text);
    stream.appendPreparedSignalDescriptor(boolean);
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqual(@as(?usize, 0), stream.elemDescriptorIndex(ElemId.fromRaw(1)).?.signal_text_attrs.get(.label));
    try std.testing.expectEqual(@as(?usize, 0), stream.elemDescriptorIndex(ElemId.fromRaw(2)).?.signal_bool_attrs.get(.disabled));
    try std.testing.expectEqual(ElemId.fromRaw(1), stream.signal_text_attrs.items[0].elem_id);
    try std.testing.expectEqual(ElemId.fromRaw(2), stream.signal_bool_attrs.items[0].elem_id);
}

test "prepared persistent signal record tree publishes balanced token ownership without allocation" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    const TestCtx = struct {
        /// Opens a checked capability frame for an app-compiled erased call.
        pub fn pushHostValueCapabilities(_: *@This(), _: []const retained.HostValueCapability) void {}
        /// Closes the current capability frame after an app-compiled erased call.
        pub fn popHostValueCapabilities(_: *@This()) void {}
    };

    var fault = FaultAllocator.init(std.testing.allocator);
    const allocator = fault.allocator();
    var stream: Stream = .{};
    var ctx: TestCtx = .{};
    var env = abi.RocEnv{ .allocator = allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&env);
    var metrics = TestMetrics{};
    defer stream.deinit(allocator, &ctx, &roc_host, &metrics);

    const empty_capability = retained.HostValueCapability{ .clone = null, .drop = null, .eq = null };
    const child_token: HostSignalToken = @ptrFromInt(0x1000);
    const root_token: HostSignalToken = @ptrFromInt(0x2000);
    var child = SignalRecord{ .ref_count = 1, .payload = .{ .const_value = .{
        .init = .fromAbi(child_token),
        .cap = empty_capability,
    } } };
    var root = SignalRecord{ .ref_count = 1, .payload = .{ .map = .{
        .input = &child,
        .transform = .fromAbi(root_token),
        .cap = empty_capability,
    } } };

    try stream.reservePreparedSignalRecordPublication(allocator, 2);
    fault.configure(1);
    stream.rememberPreparedSignalRecordTreeAssumeCapacity(&root);

    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqual(@as(usize, 2), stream.signal_records_by_token.count());
    try std.testing.expect(stream.signalRecordByToken(child_token) == &child);
    try std.testing.expect(stream.signalRecordByToken(root_token) == &root);
    try std.testing.expectEqual(@as(?usize, 1), stream.signal_record_descriptor_uses_by_token.get(child_token));
    try std.testing.expectEqual(@as(?usize, 1), stream.signal_record_descriptor_uses_by_token.get(root_token));

    stream.forgetSignalRecordTree(&root);
    try std.testing.expectEqual(@as(usize, 0), stream.signal_records_by_token.count());
    try std.testing.expectEqual(@as(usize, 0), stream.signal_record_descriptor_uses_by_token.count());
}

test "fixed event descriptors preserve Roc supplied payload descriptors" {
    const allocator = std.testing.allocator;
    var stream: Stream = .{};
    defer {
        stream.events.deinit(allocator);
        stream.descriptor_indexes_by_elem_id.deinit(allocator);
    }

    var env = abi.RocEnv{ .allocator = allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&env);
    var metrics = TestMetrics{};
    const binder: BinderToken = @ptrFromInt(0x1000);
    const payload_descriptor = BoundaryPayloadDescriptor.init(.str, .target_value);
    const reducer = HostEventReducer{
        .capability = .{ .clone = null, .drop = null, .eq = null },
        .read_capability = .{ .clone = null, .drop = null, .eq = null },
        .transform = null,
    };

    stream.appendEvent(
        allocator,
        &roc_host,
        &metrics,
        ElemId.fromRaw(7),
        .pointer_down,
        .auto,
        binder,
        NodeId.fromRaw(42),
        binder,
        NodeId.fromRaw(42),
        payload_descriptor,
        reducer,
    );

    try std.testing.expectEqual(@as(usize, 1), stream.events.items.len);
    try std.testing.expectEqual(EventKind.pointer_down, stream.events.items[0].fixedKind().?);
    try std.testing.expect(stream.events.items[0].payload_descriptor.eql(payload_descriptor));
    try std.testing.expectEqual(@as(?usize, 0), stream.elemDescriptorIndex(ElemId.fromRaw(7)).?.events.get(.pointer_down));
}

test "prepared named event indexes publish allocation free for existing and new elements" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    const TestCtx = struct {
        /// Opens a checked capability frame for an app-compiled erased call.
        pub fn pushHostValueCapabilities(_: *@This(), _: []const retained.HostValueCapability) void {}
        /// Closes the current capability frame after an app-compiled erased call.
        pub fn popHostValueCapabilities(_: *@This()) void {}
    };

    var fault = FaultAllocator.init(std.testing.allocator);
    const allocator = fault.allocator();
    var stream: Stream = .{};
    var ctx: TestCtx = .{};
    var env = abi.RocEnv{ .allocator = allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&env);
    var metrics = TestMetrics{};
    defer stream.deinit(allocator, &ctx, &roc_host, &metrics);

    try stream.named_event_indices_by_elem_id.append(allocator, .empty);
    try stream.named_event_indices_by_elem_id.append(allocator, .empty);
    try stream.named_event_indices_by_elem_id.items[1].append(allocator, 17);
    try stream.reservePreparedEvents(allocator, 2, 3);
    try stream.reserveExistingNamedEventIndexes(allocator, 1, 1);

    var groups = [_]Stream.PreparedNamedEventIndexGroup{
        .{ .elem_id = ElemId.fromRaw(1), .existed = true },
        .{ .elem_id = ElemId.fromRaw(3), .existed = false },
    };
    defer for (&groups) |*group| group.abort(allocator);
    try groups[0].event_ordinals.append(allocator, 0);
    try groups[1].event_ordinals.append(allocator, 1);

    const reducer = std.mem.zeroes(HostEventReducer);
    const first_name = try allocator.dupe(u8, "existing");
    const second_name = try allocator.dupe(u8, "new");
    const first = Stream.PreparedEventDescriptor{ .desc = .{
        .elem_id = ElemId.fromRaw(1),
        .binding = .{ .named = .{ .name = first_name, .policy = .none } },
        .binder_token = @ptrFromInt(0x1000),
        .target_node_id = NodeId.fromRaw(1),
        .read_binder_token = @ptrFromInt(0x1000),
        .read_node_id = NodeId.fromRaw(1),
        .payload_descriptor = BoundaryPayloadDescriptor.init(.str, .target_value),
        .payload_reducer = reducer,
        .owns_payload_reducer = false,
    } };
    const second = Stream.PreparedEventDescriptor{ .desc = .{
        .elem_id = ElemId.fromRaw(3),
        .binding = .{ .named = .{ .name = second_name, .policy = .none } },
        .binder_token = @ptrFromInt(0x1000),
        .target_node_id = NodeId.fromRaw(3),
        .read_binder_token = @ptrFromInt(0x1000),
        .read_node_id = NodeId.fromRaw(3),
        .payload_descriptor = BoundaryPayloadDescriptor.init(.str, .target_value),
        .payload_reducer = reducer,
        .owns_payload_reducer = false,
    } };

    fault.configure(1);
    stream.appendPreparedEvent(first);
    stream.appendPreparedEvent(second);
    stream.publishPreparedNamedEventIndexes(&groups, 0);
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqualSlices(usize, &.{ 17, 0 }, stream.namedEventIndices(ElemId.fromRaw(1)));
    try std.testing.expectEqualSlices(usize, &.{1}, stream.namedEventIndices(ElemId.fromRaw(3)));
    try std.testing.expectEqualStrings("existing", stream.events.items[0].named().?.name);
    try std.testing.expectEqualStrings("new", stream.events.items[1].named().?.name);
}

test "prepared state site publication is allocation free" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    const TestCtx = struct {
        /// Opens a checked capability frame for an app-compiled erased call.
        pub fn pushHostValueCapabilities(_: *@This(), _: []const retained.HostValueCapability) void {}
        /// Closes the current capability frame after an app-compiled erased call.
        pub fn popHostValueCapabilities(_: *@This()) void {}
    };
    const Callable = struct {
        fn call(_: *abi.RocHost, _: ?[*]u8, _: ?[*]const u8, _: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {}
    };

    var fault = FaultAllocator.init(std.testing.allocator);
    const allocator = fault.allocator();
    var stream: Stream = .{};
    var ctx: TestCtx = .{};
    var env = abi.RocEnv{ .allocator = allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&env);
    var metrics = TestMetrics{};
    defer stream.deinit(allocator, &ctx, &roc_host, &metrics);
    const initial = abi.rocErasedCallableAllocate(&roc_host, Callable.call, null, 0).?;
    defer abi.decrefErasedCallable(initial, &roc_host);

    try stream.reservePreparedStateSites(allocator, 1, 4);
    try stream.reserveScopeDescriptorOwnership(allocator, ScopeId.fromRaw(0), 0, 1);
    const binder: BinderToken = @ptrFromInt(0x9000);
    const site = try stream.prepareScopeSite(allocator, NodeId.fromRaw(4), ScopeId.fromRaw(0), SiteOrdinal.fromRaw(0), ElemId.fromRaw(1), .state, &.{.{ .token = binder, .node_id = NodeId.fromRaw(2) }});
    const state = stream.prepareState(NodeId.fromRaw(4), .fromAbi(initial), std.mem.zeroes(HostValueCapability), &metrics);

    fault.configure(1);
    stream.appendPreparedStateSite(site, state);
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqual(@as(usize, 1), stream.scope_sites.items.len);
    try std.testing.expectEqual(@as(usize, 1), stream.states.items.len);
    try std.testing.expectEqual(@as(?usize, 0), stream.nodeDescriptorIndex(NodeId.fromRaw(4)).?.scope_sites.get(.state));
    try std.testing.expectEqual(@as(?usize, 0), stream.nodeDescriptorIndex(NodeId.fromRaw(4)).?.state.get());
    try std.testing.expectEqual(binder, stream.scope_sites.items[0].binder_bindings[0].token);
}

test "prepared state site replacement transfers ownership without allocation" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    const TestCtx = struct {
        /// Opens a checked capability frame for an app-compiled erased call.
        pub fn pushHostValueCapabilities(_: *@This(), _: []const retained.HostValueCapability) void {}
        /// Closes the current capability frame after an app-compiled erased call.
        pub fn popHostValueCapabilities(_: *@This()) void {}
    };
    const Callable = struct {
        fn call(_: *abi.RocHost, _: ?[*]u8, _: ?[*]const u8, _: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {}
    };
    var fault = FaultAllocator.init(std.testing.allocator);
    const allocator = fault.allocator();
    var ctx: TestCtx = .{};
    var env = abi.RocEnv{ .allocator = allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&env);
    var metrics = TestMetrics{};
    var active: Stream = .{};
    var replacement: Stream = .{};
    var retired: Stream = .{};
    defer active.deinit(allocator, &ctx, &roc_host, &metrics);
    defer replacement.deinit(allocator, &ctx, &roc_host, &metrics);
    defer retired.deinit(allocator, &ctx, &roc_host, &metrics);
    const initial = abi.rocErasedCallableAllocate(&roc_host, Callable.call, null, 0).?;
    defer abi.decrefErasedCallable(initial, &roc_host);
    const token: BinderToken = @ptrFromInt(0x9200);

    try active.reservePreparedStateSites(allocator, 1, 4);
    try active.reserveScopeDescriptorOwnership(allocator, ScopeId.fromRaw(1), 0, 1);
    active.appendPreparedStateSite(try active.prepareScopeSite(allocator, NodeId.fromRaw(4), ScopeId.fromRaw(1), SiteOrdinal.fromRaw(0), ElemId.fromRaw(1), .state, &.{.{ .token = token, .node_id = NodeId.fromRaw(4) }}), active.prepareState(NodeId.fromRaw(4), .fromAbi(initial), std.mem.zeroes(HostValueCapability), &metrics));
    try replacement.reservePreparedStateSites(allocator, 1, 5);
    try replacement.reserveScopeDescriptorOwnership(allocator, ScopeId.fromRaw(2), 0, 1);
    replacement.appendPreparedStateSite(try replacement.prepareScopeSite(allocator, NodeId.fromRaw(5), ScopeId.fromRaw(2), SiteOrdinal.fromRaw(0), ElemId.fromRaw(2), .state, &.{.{ .token = token, .node_id = NodeId.fromRaw(5) }}), replacement.prepareState(NodeId.fromRaw(5), .fromAbi(initial), std.mem.zeroes(HostValueCapability), &metrics));
    try active.reserveMovedStreamPublication(allocator, &replacement);
    try retired.reserveRetiredStaticPublication(allocator, 0, 0, 0, 0, 0, 0, 0, 0, 0, &.{}, &active, &.{0}, 1, 0, 0);

    fault.configure(1);
    active.commitStaticDescriptorReplacementAssumeCapacity(&replacement, &retired, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{0}, &.{0}, &.{}, &.{});
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqual(NodeId.fromRaw(5), active.scope_sites.items[0].node_id);
    try std.testing.expectEqual(@as(?usize, 0), active.nodeDescriptorIndex(NodeId.fromRaw(5)).?.state.get());
    try std.testing.expectEqual(NodeId.fromRaw(4), retired.states.items[0].node_id);
    try std.testing.expectEqual(token, retired.scope_sites.items[0].binder_bindings[0].token);
    try std.testing.expectEqual(@as(usize, 0), active.scopeOwnedNodeIds(ScopeId.fromRaw(1)).len);
    try std.testing.expectEqualSlices(NodeId, &.{NodeId.fromRaw(5)}, active.scopeOwnedNodeIds(ScopeId.fromRaw(2)));
}

test "when descriptor replacement transfers ownership without allocation" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    const TestCtx = struct {
        /// Opens a checked capability frame for an app-compiled erased call.
        pub fn pushHostValueCapabilities(_: *@This(), _: []const retained.HostValueCapability) void {}
        /// Closes the current capability frame after an app-compiled erased call.
        pub fn popHostValueCapabilities(_: *@This()) void {}
    };
    var fault = FaultAllocator.init(std.testing.allocator);
    const allocator = fault.allocator();
    var ctx: TestCtx = .{};
    var env = abi.RocEnv{ .allocator = allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&env);
    var metrics = TestMetrics{};
    var active: Stream = .{};
    var replacement: Stream = .{};
    var retired: Stream = .{};
    defer active.deinit(allocator, &ctx, &roc_host, &metrics);
    defer replacement.deinit(allocator, &ctx, &roc_host, &metrics);
    defer retired.deinit(allocator, &ctx, &roc_host, &metrics);

    const active_record = try SignalRecord.tryInit(allocator, .{ .ref = 1 });
    const replacement_record = try SignalRecord.tryInit(allocator, .{ .ref = 2 });
    try active.reservePreparedWhens(allocator, 1, 4);
    try active.reservePreparedSignalRecordPublication(allocator, 1);
    active.appendPreparedWhen(active.prepareWhen(NodeId.fromRaw(4), .{ .record = active_record, .source_node_ids = try allocator.dupe(u64, &.{1}) }, std.mem.zeroes(retained.HostWhenOps), &metrics));
    active.rememberSignalRecordTreeAssumeCapacity(active_record);
    try active.scope_sites.append(allocator, .{ .node_id = NodeId.fromRaw(4), .scope_id = ScopeId.fromRaw(1), .ordinal = SiteOrdinal.fromRaw(0), .parent_elem_id = ids.root_elem, .render_insert_index = 0, .kind = .when, .binder_bindings = try allocator.alloc(BinderBinding, 0) });
    setFreshIndex(active.descriptor_indexes_by_node_id.items[4].scope_sites.slot(.when), 0);

    try replacement.reservePreparedWhens(allocator, 1, 5);
    try replacement.reservePreparedSignalRecordPublication(allocator, 1);
    replacement.appendPreparedWhen(replacement.prepareWhen(NodeId.fromRaw(5), .{ .record = replacement_record, .source_node_ids = try allocator.dupe(u64, &.{2}) }, std.mem.zeroes(retained.HostWhenOps), &metrics));
    replacement.rememberSignalRecordTreeAssumeCapacity(replacement_record);
    try replacement.scope_sites.append(allocator, .{ .node_id = NodeId.fromRaw(5), .scope_id = ScopeId.fromRaw(2), .ordinal = SiteOrdinal.fromRaw(0), .parent_elem_id = ids.root_elem, .render_insert_index = 0, .kind = .when, .binder_bindings = try allocator.alloc(BinderBinding, 0) });
    setFreshIndex(replacement.descriptor_indexes_by_node_id.items[5].scope_sites.slot(.when), 0);
    try active.reserveMovedStreamPublication(allocator, &replacement);
    try retired.reserveRetiredStaticPublication(allocator, 0, 0, 0, 0, 0, 0, 0, 1, 0, &.{}, &active, &.{0}, 0, 1, 0);

    fault.configure(1);
    active.commitStaticDescriptorReplacementAssumeCapacity(&replacement, &retired, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{0}, &.{}, &.{0}, &.{});
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqual(NodeId.fromRaw(5), active.whens.items[0].node_id);
    try std.testing.expectEqual(@as(?usize, 0), active.nodeDescriptorIndex(NodeId.fromRaw(5)).?.when.get());
    try std.testing.expectEqual(NodeId.fromRaw(4), retired.whens.items[0].node_id);
    try std.testing.expectEqual(@as(?usize, 0), retired.nodeDescriptorIndex(NodeId.fromRaw(4)).?.when.get());
}

test "each descriptor replacement transfers ownership without allocation" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    const TestCtx = struct {
        /// Opens a checked capability frame for an app-compiled erased call.
        pub fn pushHostValueCapabilities(_: *@This(), _: []const retained.HostValueCapability) void {}
        /// Closes the current capability frame after an app-compiled erased call.
        pub fn popHostValueCapabilities(_: *@This()) void {}
    };
    var fault = FaultAllocator.init(std.testing.allocator);
    const allocator = fault.allocator();
    var ctx: TestCtx = .{};
    var env = abi.RocEnv{ .allocator = allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&env);
    var metrics = TestMetrics{};
    var active: Stream = .{};
    var replacement: Stream = .{};
    var retired: Stream = .{};
    defer active.deinit(allocator, &ctx, &roc_host, &metrics);
    defer replacement.deinit(allocator, &ctx, &roc_host, &metrics);
    defer retired.deinit(allocator, &ctx, &roc_host, &metrics);

    const active_record = try SignalRecord.tryInit(allocator, .{ .ref = 1 });
    const replacement_record = try SignalRecord.tryInit(allocator, .{ .ref = 2 });
    try active.eaches.ensureUnusedCapacity(allocator, 1);
    try active.descriptor_indexes_by_node_id.ensureTotalCapacity(allocator, 5);
    while (active.descriptor_indexes_by_node_id.items.len < 5) active.descriptor_indexes_by_node_id.appendAssumeCapacity(.{});
    try active.reservePreparedSignalRecordPublication(allocator, 1);
    active.eaches.appendAssumeCapacity(.{ .node_id = NodeId.fromRaw(4), .items = .{ .record = active_record, .source_node_ids = try allocator.dupe(u64, &.{1}) }, .ops = std.mem.zeroes(HostEachOps) });
    setFreshIndex(&active.descriptor_indexes_by_node_id.items[4].each, 0);
    active.rememberSignalRecordTreeAssumeCapacity(active_record);
    try active.scope_sites.append(allocator, .{ .node_id = NodeId.fromRaw(4), .scope_id = ScopeId.fromRaw(1), .ordinal = SiteOrdinal.fromRaw(0), .parent_elem_id = ids.root_elem, .render_insert_index = 0, .kind = .each, .binder_bindings = try allocator.alloc(BinderBinding, 0) });
    setFreshIndex(active.descriptor_indexes_by_node_id.items[4].scope_sites.slot(.each), 0);

    try replacement.eaches.ensureUnusedCapacity(allocator, 1);
    try replacement.descriptor_indexes_by_node_id.ensureTotalCapacity(allocator, 6);
    while (replacement.descriptor_indexes_by_node_id.items.len < 6) replacement.descriptor_indexes_by_node_id.appendAssumeCapacity(.{});
    try replacement.reservePreparedSignalRecordPublication(allocator, 1);
    replacement.eaches.appendAssumeCapacity(.{ .node_id = NodeId.fromRaw(5), .items = .{ .record = replacement_record, .source_node_ids = try allocator.dupe(u64, &.{2}) }, .ops = std.mem.zeroes(HostEachOps) });
    setFreshIndex(&replacement.descriptor_indexes_by_node_id.items[5].each, 0);
    replacement.rememberSignalRecordTreeAssumeCapacity(replacement_record);
    try replacement.scope_sites.append(allocator, .{ .node_id = NodeId.fromRaw(5), .scope_id = ScopeId.fromRaw(2), .ordinal = SiteOrdinal.fromRaw(0), .parent_elem_id = ids.root_elem, .render_insert_index = 0, .kind = .each, .binder_bindings = try allocator.alloc(BinderBinding, 0) });
    setFreshIndex(replacement.descriptor_indexes_by_node_id.items[5].scope_sites.slot(.each), 0);
    try active.reserveMovedStreamPublication(allocator, &replacement);
    try retired.reserveRetiredStaticPublication(allocator, 0, 0, 0, 0, 0, 0, 0, 1, 0, &.{}, &active, &.{0}, 0, 0, 1);

    fault.configure(1);
    active.commitStaticDescriptorReplacementAssumeCapacity(&replacement, &retired, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{0}, &.{}, &.{}, &.{0});
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqual(NodeId.fromRaw(5), active.eaches.items[0].node_id);
    try std.testing.expectEqual(@as(?usize, 0), active.nodeDescriptorIndex(NodeId.fromRaw(5)).?.each.get());
    try std.testing.expectEqual(NodeId.fromRaw(4), retired.eaches.items[0].node_id);
    try std.testing.expectEqual(@as(?usize, 0), retired.nodeDescriptorIndex(NodeId.fromRaw(4)).?.each.get());
}

test "prepared when publication is allocation free" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    const TestCtx = struct {
        /// Opens a checked capability frame for an app-compiled erased call.
        pub fn pushHostValueCapabilities(_: *@This(), _: []const retained.HostValueCapability) void {}
        /// Closes the current capability frame after an app-compiled erased call.
        pub fn popHostValueCapabilities(_: *@This()) void {}
    };
    var fault = FaultAllocator.init(std.testing.allocator);
    const allocator = fault.allocator();
    var stream: Stream = .{};
    var ctx: TestCtx = .{};
    var env = abi.RocEnv{ .allocator = allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&env);
    var metrics = TestMetrics{};
    defer stream.deinit(allocator, &ctx, &roc_host, &metrics);

    try stream.reservePreparedWhens(allocator, 1, 6);
    const record = try SignalRecord.tryInit(allocator, .{ .ref = 1 });
    const sources = try allocator.dupe(u64, &.{1});
    const condition = HostSignalBinding{ .record = record, .source_node_ids = sources };
    const prepared = stream.prepareWhen(NodeId.fromRaw(6), condition, std.mem.zeroes(retained.HostWhenOps), &metrics);

    fault.configure(1);
    stream.appendPreparedWhen(prepared);
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqual(@as(usize, 1), stream.whens.items.len);
    try std.testing.expectEqual(@as(?usize, 0), stream.nodeDescriptorIndex(NodeId.fromRaw(6)).?.when.get());
    try std.testing.expect(stream.whens.items[0].condition.record == record);
}

test "prepared fixed and named event replacement is allocation free" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    const TestCtx = struct {
        /// Opens a checked capability frame for an app-compiled erased call.
        pub fn pushHostValueCapabilities(_: *@This(), _: []const retained.HostValueCapability) void {}
        /// Closes the current capability frame after an app-compiled erased call.
        pub fn popHostValueCapabilities(_: *@This()) void {}
    };
    var fault = FaultAllocator.init(std.testing.allocator);
    const allocator = fault.allocator();
    var ctx: TestCtx = .{};
    var env = abi.RocEnv{ .allocator = allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&env);
    var metrics = TestMetrics{};
    var active: Stream = .{};
    var replacement: Stream = .{};
    var retired: Stream = .{};
    defer active.deinit(allocator, &ctx, &roc_host, &metrics);
    defer replacement.deinit(allocator, &ctx, &roc_host, &metrics);
    defer retired.deinit(allocator, &ctx, &roc_host, &metrics);

    const token: BinderToken = @ptrFromInt(0x9100);
    const payload = BoundaryPayloadDescriptor.init(.unit, .none);
    const reducer = std.mem.zeroes(HostEventReducer);
    _ = active.appendElement(allocator, ElemId.fromRaw(1), ElemId.fromRaw(0), ScopeId.fromRaw(0), "old");
    _ = replacement.appendElement(allocator, ElemId.fromRaw(2), ElemId.fromRaw(0), ScopeId.fromRaw(0), "new");
    active.appendEvent(allocator, &roc_host, &metrics, ElemId.fromRaw(1), .click, .auto, token, NodeId.fromRaw(7), token, NodeId.fromRaw(7), payload, reducer);
    active.appendNamedEvent(allocator, &roc_host, &metrics, ElemId.fromRaw(1), "old", .{}, .auto, token, NodeId.fromRaw(7), token, NodeId.fromRaw(7), payload, reducer);
    replacement.appendEvent(allocator, &roc_host, &metrics, ElemId.fromRaw(2), .click, .auto, token, NodeId.fromRaw(8), token, NodeId.fromRaw(8), payload, reducer);
    replacement.appendNamedEvent(allocator, &roc_host, &metrics, ElemId.fromRaw(2), "new", .{}, .auto, token, NodeId.fromRaw(8), token, NodeId.fromRaw(8), payload, reducer);

    try active.reserveMovedStreamPublication(allocator, &replacement);
    try retired.reserveRetiredStaticPublication(allocator, 0, 0, 0, 0, 0, 0, 0, 0, 2, &.{1}, &active, &.{}, 0, 0, 0);
    fault.configure(1);
    active.commitStaticDescriptorReplacementAssumeCapacity(&replacement, &retired, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{ 1, 0 }, &.{}, &.{}, &.{}, &.{});
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqual(@as(usize, 2), active.events.items.len);
    try std.testing.expectEqualStrings("new", active.events.items[1].named().?.name);
    try std.testing.expectEqualSlices(usize, &.{1}, active.namedEventIndices(ElemId.fromRaw(2)));
    try std.testing.expectEqual(@as(?usize, 0), active.elemDescriptorIndex(ElemId.fromRaw(2)).?.events.get(.click));
    try std.testing.expectEqualStrings("old", retired.events.items[0].named().?.name);
    try std.testing.expectEqualSlices(usize, &.{0}, retired.namedEventIndices(ElemId.fromRaw(1)));
}

test "field descriptor indexes round-trip by enum field" {
    var text: TextFieldDescriptorIndexes = .{};
    text.slot(.label).* = DescriptorIndex.init(12);
    text.slot(.class).* = DescriptorIndex.init(18);
    try std.testing.expectEqual(@as(?usize, 12), text.get(.label));
    try std.testing.expectEqual(@as(?usize, 18), text.get(.class));
    try std.testing.expectEqual(@as(?usize, null), text.get(.role));

    var bools: BoolFieldDescriptorIndexes = .{};
    bools.slot(.checked).* = DescriptorIndex.init(3);
    try std.testing.expectEqual(@as(?usize, 3), bools.get(.checked));
    try std.testing.expectEqual(@as(?usize, null), bools.get(.disabled));

    var events: EventDescriptorIndexes = .{};
    events.slot(.pointer_enter).* = DescriptorIndex.init(7);
    try std.testing.expectEqual(@as(?usize, 7), events.get(.pointer_enter));
    try std.testing.expectEqual(@as(?usize, null), events.get(.click));
}

test "scope site descriptor indexes round-trip by kind" {
    var indexes: ScopeSiteDescriptorIndexes = .{};
    indexes.slot(.component).* = DescriptorIndex.init(1);
    indexes.slot(.when).* = DescriptorIndex.init(5);

    try std.testing.expectEqual(@as(?usize, 1), indexes.get(.component));
    try std.testing.expectEqual(@as(?usize, 5), indexes.get(.when));
    try std.testing.expectEqual(@as(?usize, null), indexes.get(.each));
}

test "descriptor index mutation helpers preserve explicit slots" {
    var slot: DescriptorIndex = .none;

    setFreshIndex(&slot, 4);
    try std.testing.expectEqual(@as(?usize, 4), slot.get());

    updateIndex(&slot, 9);
    try std.testing.expectEqual(@as(?usize, 9), slot.get());

    clearIndex(&slot, 9);
    try std.testing.expectEqual(@as(?usize, null), slot.get());
}

test "descriptor indexes retain a cache-dense layout" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(DescriptorIndex));
    try std.testing.expectEqual(@as(usize, 104), @sizeOf(ElemDescriptorIndex));
    try std.testing.expectEqual(@as(usize, 28), @sizeOf(NodeDescriptorIndex));
}

test "custom attribute index tracks family and swap-moved dense index" {
    const allocator = std.testing.allocator;
    const TestCtx = struct {
        /// Opens a no-op capability frame for descriptor teardown.
        pub fn pushHostValueCapabilities(_: *@This(), _: []const retained.HostValueCapability) void {}
        /// Closes the no-op capability frame.
        pub fn popHostValueCapabilities(_: *@This()) void {}
    };
    var ctx: TestCtx = .{};
    var env = abi.RocEnv{ .allocator = allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&env);
    var metrics = TestMetrics{};
    var stream: Stream = .{};
    defer stream.deinit(allocator, &ctx, &roc_host, &metrics);
    stream.appendStaticCustomTextAttr(allocator, ElemId.fromRaw(1), "data-first", "one");
    stream.appendStaticCustomTextAttr(allocator, ElemId.fromRaw(2), "data-second", "two");
    try std.testing.expectEqualDeep(CustomAttrDescriptorIndex{ .kind = .static_text, .index = 0 }, stream.customAttrDescriptorIndex(ElemId.fromRaw(1), "data-first").?);
    try std.testing.expectEqualDeep(CustomAttrDescriptorIndex{ .kind = .static_text, .index = 1 }, stream.customAttrDescriptorIndex(ElemId.fromRaw(2), "data-second").?);
    try std.testing.expectEqualDeep(&[_]CustomAttrDescriptorIndex{.{ .kind = .static_text, .index = 0 }}, stream.customAttrIndices(ElemId.fromRaw(1)));
    try std.testing.expectEqualDeep(&[_]CustomAttrDescriptorIndex{.{ .kind = .static_text, .index = 1 }}, stream.customAttrIndices(ElemId.fromRaw(2)));

    const removed = stream.static_custom_text_attrs.swapRemove(0);
    stream.removeCustomAttrIndex(removed.elem_id.raw(), removed.name, .{ .kind = .static_text, .index = 0 });
    const moved = stream.static_custom_text_attrs.items[0];
    stream.updateCustomAttrIndex(moved.elem_id.raw(), moved.name, .static_text, 1, 0);
    allocator.free(removed.name);
    allocator.free(removed.value);
    try std.testing.expect(stream.customAttrDescriptorIndex(ElemId.fromRaw(1), "data-first") == null);
    try std.testing.expectEqualDeep(CustomAttrDescriptorIndex{ .kind = .static_text, .index = 0 }, stream.customAttrDescriptorIndex(ElemId.fromRaw(2), "data-second").?);
    try std.testing.expectEqual(@as(usize, 0), stream.customAttrIndices(ElemId.fromRaw(1)).len);
    try std.testing.expectEqualDeep(&[_]CustomAttrDescriptorIndex{.{ .kind = .static_text, .index = 0 }}, stream.customAttrIndices(ElemId.fromRaw(2)));
}

test "custom attribute index preflight sweeps allocation failures" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var counter = FaultAllocator.init(std.testing.allocator);
    var baseline: Stream = .{};
    try baseline.reservePreparedCustomAttrIndex(counter.allocator(), 4);
    try baseline.reservePreparedCustomAttrElem(counter.allocator(), 7, 4);
    const attempts = counter.attempts;
    baseline.custom_attr_keys.deinit(counter.allocator());
    for (baseline.custom_attr_indices_by_elem_id.items) |*indexes| indexes.deinit(counter.allocator());
    baseline.custom_attr_indices_by_elem_id.deinit(counter.allocator());
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| {
        var fault = FaultAllocator.init(std.testing.allocator);
        fault.configure(failure_number);
        var stream: Stream = .{};
        var failed = false;
        stream.reservePreparedCustomAttrIndex(fault.allocator(), 4) catch {
            failed = true;
        };
        if (!failed) stream.reservePreparedCustomAttrElem(fault.allocator(), 7, 4) catch {
            failed = true;
        };
        try std.testing.expect(failed);
        try std.testing.expectEqual(@as(usize, 0), stream.custom_attr_keys.count());
        try std.testing.expectEqual(@as(usize, 0), stream.custom_attr_indices_by_elem_id.items.len);
        fault.configure(null);
        try stream.reservePreparedCustomAttrIndex(fault.allocator(), 4);
        try stream.reservePreparedCustomAttrElem(fault.allocator(), 7, 4);
        stream.custom_attr_keys.deinit(fault.allocator());
        for (stream.custom_attr_indices_by_elem_id.items) |*indexes| indexes.deinit(fault.allocator());
        stream.custom_attr_indices_by_elem_id.deinit(fault.allocator());
    }
}

test "prepared custom attribute publication is allocation free" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    const TestCtx = struct {
        /// Opens a no-op capability frame for descriptor teardown.
        pub fn pushHostValueCapabilities(_: *@This(), _: []const retained.HostValueCapability) void {}
        /// Closes the no-op capability frame.
        pub fn popHostValueCapabilities(_: *@This()) void {}
    };
    var fault = FaultAllocator.init(std.testing.allocator);
    const allocator = fault.allocator();
    var ctx: TestCtx = .{};
    var env = abi.RocEnv{ .allocator = allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&env);
    var metrics = TestMetrics{};
    var stream: Stream = .{};
    defer stream.deinit(allocator, &ctx, &roc_host, &metrics);

    try stream.reservePreparedStaticAttrs(allocator, 1);
    try stream.reservePreparedCustomAttrIndex(allocator, 1);
    try stream.reservePreparedCustomAttrElem(allocator, 7, 1);
    const prepared = try stream.prepareStaticCustomTextAttr(allocator, ElemId.fromRaw(7), "data-state", "ready");

    fault.configure(1);
    stream.appendPreparedStaticAttr(prepared);
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqualDeep(CustomAttrDescriptorIndex{ .kind = .static_text, .index = 0 }, stream.customAttrDescriptorIndex(ElemId.fromRaw(7), "data-state").?);
    try std.testing.expectEqualDeep(&[_]CustomAttrDescriptorIndex{.{ .kind = .static_text, .index = 0 }}, stream.customAttrIndices(ElemId.fromRaw(7)));
    fault.configure(null);
}

test "custom descriptor retirement and replacement repairs both indexes without allocation" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    const TestCtx = struct {
        /// Opens a no-op capability frame for descriptor teardown.
        pub fn pushHostValueCapabilities(_: *@This(), _: []const retained.HostValueCapability) void {}
        /// Closes the no-op capability frame.
        pub fn popHostValueCapabilities(_: *@This()) void {}
    };
    var fault = FaultAllocator.init(std.testing.allocator);
    const allocator = fault.allocator();
    var ctx: TestCtx = .{};
    var env = abi.RocEnv{ .allocator = allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&env);
    var metrics = TestMetrics{};
    var active: Stream = .{};
    var replacement: Stream = .{};
    var retired: Stream = .{};
    defer active.deinit(allocator, &ctx, &roc_host, &metrics);
    defer replacement.deinit(allocator, &ctx, &roc_host, &metrics);
    defer retired.deinit(allocator, &ctx, &roc_host, &metrics);

    active.appendStaticCustomTextAttr(allocator, ElemId.fromRaw(1), "data-old", "old");
    active.appendStaticCustomTextAttr(allocator, ElemId.fromRaw(2), "data-keep", "keep");
    active.appendStaticCustomBoolAttr(allocator, ElemId.fromRaw(1), "hidden", true);
    replacement.appendStaticCustomTextAttr(allocator, ElemId.fromRaw(3), "data-new", "new");
    replacement.appendStaticCustomBoolAttr(allocator, ElemId.fromRaw(3), "open", true);
    try active.reserveMovedStreamPublication(allocator, &replacement);
    try retired.reserveRetiredCustomPublication(allocator, &active, &.{1}, 1, 0, 0, 1, 0);

    fault.configure(1);
    active.commitCustomDescriptorReplacementAssumeCapacity(&replacement, &retired, &.{0}, &.{}, &.{}, &.{0}, &.{});
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expect(active.customAttrDescriptorIndex(ElemId.fromRaw(1), "data-old") == null);
    try std.testing.expectEqualDeep(CustomAttrDescriptorIndex{ .kind = .static_text, .index = 0 }, active.customAttrDescriptorIndex(ElemId.fromRaw(2), "data-keep").?);
    try std.testing.expectEqualDeep(CustomAttrDescriptorIndex{ .kind = .static_text, .index = 1 }, active.customAttrDescriptorIndex(ElemId.fromRaw(3), "data-new").?);
    try std.testing.expectEqualDeep(CustomAttrDescriptorIndex{ .kind = .static_bool, .index = 0 }, active.customAttrDescriptorIndex(ElemId.fromRaw(3), "open").?);
    try std.testing.expectEqual(@as(usize, 0), active.customAttrIndices(ElemId.fromRaw(1)).len);
    try std.testing.expectEqual(@as(usize, 2), active.customAttrIndices(ElemId.fromRaw(3)).len);
    try std.testing.expectEqualStrings("old", retired.static_custom_text_attrs.items[0].value);
    try std.testing.expect(retired.static_custom_bool_attrs.items[0].value);
    fault.configure(null);
}

test "lifecycle ownership index preflight sweeps failures and repairs moved descriptors" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var counter = FaultAllocator.init(std.testing.allocator);
    var counted: Stream = .{};
    try counted.reserveLifecycleScope(counter.allocator(), ScopeId.fromRaw(8), 3);
    const attempts = counter.attempts;
    for (counted.lifecycle_indices_by_scope_id.items) |*indexes| indexes.deinit(counter.allocator());
    counted.lifecycle_indices_by_scope_id.deinit(counter.allocator());
    try std.testing.expect(attempts != 0);

    for (1..attempts + 1) |failure_number| {
        var fault = FaultAllocator.init(std.testing.allocator);
        fault.configure(failure_number);
        var failed_stream: Stream = .{};
        try std.testing.expectError(error.OutOfMemory, failed_stream.reserveLifecycleScope(fault.allocator(), ScopeId.fromRaw(8), 3));
        try std.testing.expectEqual(@as(usize, 0), failed_stream.lifecycle_indices_by_scope_id.items.len);
        fault.configure(null);
        try failed_stream.reserveLifecycleScope(fault.allocator(), ScopeId.fromRaw(8), 3);
        for (failed_stream.lifecycle_indices_by_scope_id.items) |*indexes| indexes.deinit(fault.allocator());
        failed_stream.lifecycle_indices_by_scope_id.deinit(fault.allocator());
    }

    const TestCtx = struct {
        /// Opens a no-op capability frame for descriptor teardown.
        pub fn pushHostValueCapabilities(_: *@This(), _: []const retained.HostValueCapability) void {}
        /// Closes the no-op capability frame.
        pub fn popHostValueCapabilities(_: *@This()) void {}
    };
    var fault = FaultAllocator.init(std.testing.allocator);
    const allocator = fault.allocator();
    var ctx: TestCtx = .{};
    var env = abi.RocEnv{ .allocator = allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&env);
    var metrics = TestMetrics{};
    var stream: Stream = .{};
    defer stream.deinit(allocator, &ctx, &roc_host, &metrics);
    stream.appendCleanup(allocator, ScopeId.fromRaw(1), "old");
    stream.appendCleanup(allocator, ScopeId.fromRaw(2), "moved");
    try std.testing.expectEqualDeep(&[_]LifecycleDescriptorIndex{.{ .kind = .cleanup, .index = 0 }}, stream.lifecycleIndices(ScopeId.fromRaw(1)));
    const removed = stream.cleanups.swapRemove(0);
    stream.removeLifecycleIndex(removed.scope_id.raw(), .{ .kind = .cleanup, .index = 0 });
    const moved = stream.cleanups.items[0];
    stream.updateLifecycleIndex(moved.scope_id.raw(), .cleanup, 1, 0);
    allocator.free(removed.name);
    try std.testing.expectEqual(@as(usize, 0), stream.lifecycleIndices(ScopeId.fromRaw(1)).len);
    try std.testing.expectEqualDeep(&[_]LifecycleDescriptorIndex{.{ .kind = .cleanup, .index = 0 }}, stream.lifecycleIndices(ScopeId.fromRaw(2)));

    try stream.cleanups.ensureUnusedCapacity(allocator, 1);
    try stream.reserveLifecycleScope(allocator, ScopeId.fromRaw(3), 1);
    const name = try allocator.dupe(u8, "new");
    fault.configure(1);
    const index = stream.cleanups.items.len;
    stream.cleanups.appendAssumeCapacity(.{ .scope_id = ScopeId.fromRaw(3), .name = name });
    stream.recordLifecycleAssumeCapacity(ScopeId.fromRaw(3), .{ .kind = .cleanup, .index = index });
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqualDeep(&[_]LifecycleDescriptorIndex{.{ .kind = .cleanup, .index = 1 }}, stream.lifecycleIndices(ScopeId.fromRaw(3)));
    fault.configure(null);
}

test "prepared lifecycle descriptors publish allocation free and tear down ownership" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    const TestCtx = struct {
        /// Opens a no-op capability frame for descriptor teardown.
        pub fn pushHostValueCapabilities(_: *@This(), _: []const retained.HostValueCapability) void {}
        /// Closes the no-op capability frame.
        pub fn popHostValueCapabilities(_: *@This()) void {}
    };
    const Callable = struct {
        fn call(_: *abi.RocHost, _: ?[*]u8, _: ?[*]const u8, _: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {}
    };
    var fault = FaultAllocator.init(std.testing.allocator);
    const allocator = fault.allocator();
    var ctx: TestCtx = .{};
    var env = abi.RocEnv{ .allocator = allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&env);
    var metrics = TestMetrics{};
    var stream: Stream = .{};
    defer stream.deinit(allocator, &ctx, &roc_host, &metrics);
    const callable = abi.rocErasedCallableAllocate(&roc_host, Callable.call, null, 0).?;
    defer abi.decrefErasedCallable(callable, &roc_host);
    abi.increfErasedCallable(callable, 1);
    metrics.bump(.closure_retains, 1);
    const record = try SignalRecord.tryInitOwned(allocator, &ctx, &roc_host, &metrics, .{ .const_value = .{
        .init = .fromAbi(callable),
        .cap = .{ .clone = null, .drop = null, .eq = null },
    } });
    const sources = try allocator.dupe(u64, &.{11});
    const signal = HostSignalBinding{ .record = record, .source_node_ids = sources };

    try stream.reservePreparedLifecycle(allocator, 3);
    try stream.reserveLifecycleScope(allocator, ScopeId.fromRaw(4), 3);
    const on_change = stream.prepareOnChange(signal, .fromAbi(callable), ScopeId.fromRaw(4), true, true, &metrics);
    const mount = stream.prepareMount(.fromAbi(callable), ScopeId.fromRaw(4), true, &metrics);
    const cleanup = try stream.prepareCleanup(allocator, ScopeId.fromRaw(4), "dispose");
    fault.configure(1);
    stream.rememberSignalRecordTreeAssumeCapacity(record);
    stream.appendPreparedLifecycle(on_change);
    stream.appendPreparedLifecycle(mount);
    stream.appendPreparedLifecycle(cleanup);
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqualDeep(&[_]LifecycleDescriptorIndex{
        .{ .kind = .on_change, .index = 0 },
        .{ .kind = .mount, .index = 0 },
        .{ .kind = .cleanup, .index = 0 },
    }, stream.lifecycleIndices(ScopeId.fromRaw(4)));
    const token = retained.hostSignalTokenFromCallable(callable);
    try std.testing.expectEqual(@as(?usize, 1), stream.signal_record_descriptor_uses_by_token.get(token));
    fault.configure(null);
}

test "prepared cleanup sweeps allocation failure and retries" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var counter = FaultAllocator.init(std.testing.allocator);
    var stream: Stream = .{};
    var prepared = try stream.prepareCleanup(counter.allocator(), ScopeId.fromRaw(2), "cleanup-name");
    const attempts = counter.attempts;
    switch (prepared) {
        .cleanup => |desc| counter.allocator().free(desc.name),
        else => unreachable,
    }
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| {
        var fault = FaultAllocator.init(std.testing.allocator);
        fault.configure(failure_number);
        try std.testing.expectError(error.OutOfMemory, stream.prepareCleanup(fault.allocator(), ScopeId.fromRaw(2), "cleanup-name"));
        fault.configure(null);
        prepared = try stream.prepareCleanup(fault.allocator(), ScopeId.fromRaw(2), "cleanup-name");
        switch (prepared) {
            .cleanup => |desc| fault.allocator().free(desc.name),
            else => unreachable,
        }
    }
}

test "render elem index reports empty only when no render metadata remains" {
    var index: RenderElemIndex = .{};
    try std.testing.expect(index.empty());

    index.render_node = 1;
    try std.testing.expect(!index.empty());

    index.render_node = null;
    index.first_child = ElemId.fromRaw(3);
    try std.testing.expect(!index.empty());

    index.first_child = null;
    try std.testing.expect(index.empty());
}

test "stream reader helpers validate descriptor indexes" {
    const allocator = std.testing.allocator;
    var stream = TestStream{};
    defer stream.deinit(allocator);

    stream.elements.append(allocator, .{
        .elem_id = 1,
        .parent_elem_id = 0,
        .scope_id = 10,
        .tag = "div",
    }) catch @panic("out of memory");
    ensureTestElemDescriptorIndex(&stream, allocator, 1).element = DescriptorIndex.init(0);

    stream.text_nodes.append(allocator, .{
        .elem_id = 2,
        .parent_elem_id = 1,
        .scope_id = 10,
    }) catch @panic("out of memory");
    ensureTestElemDescriptorIndex(&stream, allocator, 2).text_node = DescriptorIndex.init(0);

    stream.signal_text_nodes.append(allocator, .{
        .elem_id = 3,
        .parent_elem_id = 1,
        .scope_id = 11,
    }) catch @panic("out of memory");
    ensureTestElemDescriptorIndex(&stream, allocator, 3).signal_text_node = DescriptorIndex.init(0);

    stream.static_text_attrs.append(allocator, .{
        .elem_id = 1,
        .field = .label,
    }) catch @panic("out of memory");
    ensureTestElemDescriptorIndex(&stream, allocator, 1).static_text_attrs.slot(.label).* = DescriptorIndex.init(0);

    stream.static_custom_text_attrs.append(allocator, .{
        .elem_id = 1,
        .name = "data-id",
    }) catch @panic("out of memory");

    stream.static_bool_attrs.append(allocator, .{
        .elem_id = 1,
        .field = .checked,
    }) catch @panic("out of memory");
    ensureTestElemDescriptorIndex(&stream, allocator, 1).static_bool_attrs.slot(.checked).* = DescriptorIndex.init(0);

    stream.render_nodes.appendSlice(allocator, &.{
        .{ .elem_id = ElemId.fromRaw(1), .kind = .element },
        .{ .elem_id = ElemId.fromRaw(2), .kind = .text },
        .{ .elem_id = ElemId.fromRaw(3), .kind = .signal_text },
    }) catch @panic("out of memory");
    appendRenderChild(TestStream, &stream, allocator, ElemId.fromRaw(1), ElemId.fromRaw(2));
    appendRenderChild(TestStream, &stream, allocator, ElemId.fromRaw(1), ElemId.fromRaw(3));

    const element = findElementDesc(TestStream, &stream, ElemId.fromRaw(1)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("div", element.tag);
    try std.testing.expectEqual(ElemId.fromRaw(1), renderNodeParentElemId(TestStream, &stream, .{ .elem_id = ElemId.fromRaw(2), .kind = .text }));
    try std.testing.expectEqual(ScopeId.fromRaw(11), renderNodeScopeId(TestStream, &stream, .{ .elem_id = ElemId.fromRaw(3), .kind = .signal_text }));
    try std.testing.expectEqualStrings("text", streamElemTag(TestStream, &stream, ElemId.fromRaw(2)));
    try std.testing.expect(streamHasTextField(TestStream, &stream, ElemId.fromRaw(1), .label));
    try std.testing.expect(streamHasCustomTextAttr(TestStream, &stream, ElemId.fromRaw(1), "data-id"));
    try std.testing.expect(streamHasBoolField(TestStream, &stream, ElemId.fromRaw(1), .checked));
    try std.testing.expectEqual(@as(u64, 3), maxRenderElemId(TestStream, &stream));
    try std.testing.expectEqual(ScopeId.fromRaw(10), elemScopeId(TestStream, &stream, ElemId.fromRaw(1)).?);

    const children = streamDirectChildren(TestStream, allocator, &stream, ElemId.fromRaw(1));
    defer allocator.free(children);
    try std.testing.expectEqualSlices(ElemId, &.{ ElemId.fromRaw(2), ElemId.fromRaw(3) }, children);
}

test "custom attr refs iterate all custom descriptor variants" {
    const allocator = std.testing.allocator;
    var stream = TestStream{};
    defer stream.deinit(allocator);

    stream.static_custom_text_attrs.append(allocator, .{ .elem_id = 1, .name = "data-id" }) catch @panic("out of memory");
    stream.signal_custom_text_attrs.append(allocator, .{ .elem_id = 2, .name = "aria-label" }) catch @panic("out of memory");
    stream.signal_optional_custom_text_attrs.append(allocator, .{ .elem_id = 3, .name = "aria-activedescendant" }) catch @panic("out of memory");
    stream.static_custom_bool_attrs.append(allocator, .{ .elem_id = 4, .name = "disabled" }) catch @panic("out of memory");
    stream.signal_custom_bool_attrs.append(allocator, .{ .elem_id = 5, .name = "aria-expanded" }) catch @panic("out of memory");

    var attrs = customAttrRefs(TestStream, &stream);
    const expected = [_]CustomAttrRef{
        .{ .kind = .static_text, .index = 0, .elem_id = ElemId.fromRaw(1), .name = "data-id" },
        .{ .kind = .signal_text, .index = 0, .elem_id = ElemId.fromRaw(2), .name = "aria-label" },
        .{ .kind = .signal_text_optional, .index = 0, .elem_id = ElemId.fromRaw(3), .name = "aria-activedescendant" },
        .{ .kind = .static_bool, .index = 0, .elem_id = ElemId.fromRaw(4), .name = "disabled" },
        .{ .kind = .signal_bool, .index = 0, .elem_id = ElemId.fromRaw(5), .name = "aria-expanded" },
    };

    for (expected) |item| {
        const attr = attrs.next() orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(item.kind, attr.kind);
        try std.testing.expectEqual(item.kind.valueKind(), attr.kind.valueKind());
        try std.testing.expectEqual(item.elem_id, attr.elem_id);
        try std.testing.expectEqualStrings(item.name, attr.name);
    }
    try std.testing.expect(attrs.next() == null);
}

test "custom attr duplicate detection spans text and bool descriptors" {
    const allocator = std.testing.allocator;
    var stream = TestStream{};
    defer stream.deinit(allocator);

    stream.static_custom_text_attrs.append(allocator, .{ .elem_id = 1, .name = "data-id" }) catch @panic("out of memory");
    stream.signal_custom_bool_attrs.append(allocator, .{ .elem_id = 1, .name = "aria-expanded" }) catch @panic("out of memory");
    stream.signal_optional_custom_text_attrs.append(allocator, .{ .elem_id = 1, .name = "aria-activedescendant" }) catch @panic("out of memory");
    stream.static_custom_bool_attrs.append(allocator, .{ .elem_id = 2, .name = "data-id" }) catch @panic("out of memory");

    try std.testing.expect(customAttrDescriptorExists(TestStream, &stream, ElemId.fromRaw(1), "data-id"));
    try std.testing.expect(customAttrDescriptorExists(TestStream, &stream, ElemId.fromRaw(1), "aria-expanded"));
    try std.testing.expect(customAttrDescriptorExists(TestStream, &stream, ElemId.fromRaw(1), "aria-activedescendant"));
    try std.testing.expect(!customAttrDescriptorExists(TestStream, &stream, ElemId.fromRaw(1), "missing"));
    try std.testing.expect(!customAttrDescriptorExists(TestStream, &stream, ElemId.fromRaw(3), "data-id"));
}

test "stream custom text lookup excludes bool descriptors" {
    const allocator = std.testing.allocator;
    var stream = TestStream{};
    defer stream.deinit(allocator);

    stream.signal_custom_text_attrs.append(allocator, .{ .elem_id = 1, .name = "aria-label" }) catch @panic("out of memory");
    stream.signal_optional_custom_text_attrs.append(allocator, .{ .elem_id = 1, .name = "aria-activedescendant" }) catch @panic("out of memory");
    stream.static_custom_bool_attrs.append(allocator, .{ .elem_id = 1, .name = "aria-expanded" }) catch @panic("out of memory");

    try std.testing.expect(streamHasCustomTextAttr(TestStream, &stream, ElemId.fromRaw(1), "aria-label"));
    try std.testing.expect(streamHasCustomTextAttr(TestStream, &stream, ElemId.fromRaw(1), "aria-activedescendant"));
    try std.testing.expect(!streamHasCustomTextAttr(TestStream, &stream, ElemId.fromRaw(1), "aria-expanded"));
}

test "render metadata helpers maintain child order and indexes" {
    const allocator = std.testing.allocator;
    var stream = TestStream{};
    defer stream.deinit(allocator);

    stream.render_nodes.appendSlice(allocator, &.{
        .{ .elem_id = ElemId.fromRaw(1), .kind = .element },
        .{ .elem_id = ElemId.fromRaw(2), .kind = .element },
        .{ .elem_id = ElemId.fromRaw(3), .kind = .element },
    }) catch @panic("out of memory");

    recordRenderNodeIndex(TestStream, &stream, allocator, ElemId.fromRaw(1), 0);
    recordRenderNodeIndex(TestStream, &stream, allocator, ElemId.fromRaw(2), 1);
    recordRenderNodeIndex(TestStream, &stream, allocator, ElemId.fromRaw(3), 2);
    appendRenderChild(TestStream, &stream, allocator, ElemId.fromRaw(0), ElemId.fromRaw(1));
    appendRenderChild(TestStream, &stream, allocator, ElemId.fromRaw(0), ElemId.fromRaw(3));
    insertRenderChildren(TestStream, &stream, allocator, ElemId.fromRaw(0), 1, &.{ElemId.fromRaw(2)});

    var children = streamDirectChildren(TestStream, allocator, &stream, ElemId.fromRaw(0));
    defer allocator.free(children);
    try std.testing.expectEqualSlices(ElemId, &.{ ElemId.fromRaw(1), ElemId.fromRaw(2), ElemId.fromRaw(3) }, children);
    try std.testing.expectEqual(@as(?ElemId, null), previousRenderSibling(TestStream, &stream, ElemId.fromRaw(1)));
    try std.testing.expectEqual(@as(?ElemId, ElemId.fromRaw(1)), previousRenderSibling(TestStream, &stream, ElemId.fromRaw(2)));
    try std.testing.expectEqual(@as(?ElemId, ElemId.fromRaw(2)), previousRenderSibling(TestStream, &stream, ElemId.fromRaw(3)));
    try std.testing.expectEqual(@as(usize, 1), childInsertionIndexForRenderIndex(TestStream, &stream, ElemId.fromRaw(0), 1));

    removeRenderChild(TestStream, &stream, ElemId.fromRaw(0), ElemId.fromRaw(2));
    allocator.free(children);
    children = streamDirectChildren(TestStream, allocator, &stream, ElemId.fromRaw(0));
    try std.testing.expectEqualSlices(ElemId, &.{ ElemId.fromRaw(1), ElemId.fromRaw(3) }, children);
    try std.testing.expectEqual(@as(?ElemId, ElemId.fromRaw(1)), previousRenderSibling(TestStream, &stream, ElemId.fromRaw(3)));

    clearRenderNodeIndex(TestStream, &stream, ElemId.fromRaw(2), 1);
    try std.testing.expectEqual(@as(?usize, null), renderNodeIndex(TestStream, &stream, ElemId.fromRaw(2)));

    stream.render_nodes.items[1] = .{ .elem_id = ElemId.fromRaw(3), .kind = .element };
    stream.render_nodes.items[2] = .{ .elem_id = ElemId.fromRaw(2), .kind = .element };
    var metrics = TestMetrics{};
    refreshRenderIndexesInRange(TestStream, &stream, allocator, 1, 1, &metrics);

    try std.testing.expectEqual(@as(?usize, 1), renderNodeIndex(TestStream, &stream, ElemId.fromRaw(3)));
    try std.testing.expectEqual(@as(?usize, null), renderNodeIndex(TestStream, &stream, ElemId.fromRaw(2)));
    try std.testing.expectEqual(@as(u64, 1), metrics.render_indexes_refreshed);

    refreshRenderIndexesFrom(TestStream, &stream, allocator, 2, &metrics);
    try std.testing.expectEqual(@as(?usize, 2), renderNodeIndex(TestStream, &stream, ElemId.fromRaw(2)));
    try std.testing.expectEqual(@as(u64, 2), metrics.render_indexes_refreshed);
}

test "sparse render sibling range move touches constant links at 10k" {
    const allocator = std.testing.allocator;
    var stream = TestStream{};
    defer stream.deinit(allocator);

    const parent = ElemId.fromRaw(0);
    for (1..10_001) |raw| {
        appendRenderChild(TestStream, &stream, allocator, parent, ElemId.fromRaw(@intCast(raw)));
    }

    const work = moveRenderSiblingRangeBefore(
        TestStream,
        &stream,
        parent,
        ElemId.fromRaw(5_000),
        ElemId.fromRaw(5_001),
        ElemId.fromRaw(2),
    );
    try std.testing.expectEqual(@as(u8, 6), work.links_touched);
    try std.testing.expectEqual(@as(?ElemId, ElemId.fromRaw(1)), previousRenderSibling(TestStream, &stream, ElemId.fromRaw(5_000)));
    try std.testing.expectEqual(@as(?ElemId, ElemId.fromRaw(5_001)), previousRenderSibling(TestStream, &stream, ElemId.fromRaw(2)));
    try std.testing.expectEqual(@as(?ElemId, ElemId.fromRaw(4_999)), previousRenderSibling(TestStream, &stream, ElemId.fromRaw(5_002)));
    try std.testing.expectEqual(@as(?ElemId, ElemId.fromRaw(2)), nextRenderSibling(TestStream, &stream, ElemId.fromRaw(5_001)));

    const no_op = moveRenderSiblingRangeBefore(
        TestStream,
        &stream,
        parent,
        ElemId.fromRaw(5_000),
        ElemId.fromRaw(5_001),
        ElemId.fromRaw(2),
    );
    try std.testing.expectEqual(@as(u8, 0), no_op.links_touched);
}

test "sparse render membership retires and appends only exact ids" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var fault = FaultAllocator.init(std.testing.allocator);
    const allocator = fault.allocator();
    var active = TestStream{};
    defer active.deinit(allocator);
    var replacement = TestStream{};
    defer replacement.deinit(allocator);
    var retired = TestStream{};
    defer retired.deinit(allocator);

    active.render_nodes.ensureTotalCapacity(allocator, 5) catch @panic("out of memory");
    active.render_metadata_by_elem_id.ensureUnusedCapacity(allocator, 6) catch @panic("out of memory");
    retired.render_nodes.ensureTotalCapacity(allocator, 1) catch @panic("out of memory");
    active.render_nodes.appendSliceAssumeCapacity(&.{
        .{ .elem_id = ElemId.fromRaw(1), .kind = .element },
        .{ .elem_id = ElemId.fromRaw(2), .kind = .element },
        .{ .elem_id = ElemId.fromRaw(3), .kind = .element },
    });
    for (active.render_nodes.items, 0..) |node, index| {
        active.elements.append(allocator, .{ .elem_id = node.elem_id.raw(), .parent_elem_id = 0, .scope_id = node.elem_id.raw(), .tag = "div" }) catch @panic("out of memory");
        ensureTestElemDescriptorIndex(&active, allocator, node.elem_id.raw()).element = DescriptorIndex.init(index);
        recordRenderNodeIndex(TestStream, &active, allocator, node.elem_id, index);
        appendRenderChild(TestStream, &active, allocator, ElemId.fromRaw(0), node.elem_id);
    }

    replacement.render_nodes.appendSlice(allocator, &.{
        .{ .elem_id = ElemId.fromRaw(4), .kind = .element },
        .{ .elem_id = ElemId.fromRaw(5), .kind = .element },
    }) catch @panic("out of memory");
    replacement.elements.appendSlice(allocator, &.{
        .{ .elem_id = 4, .parent_elem_id = 0, .scope_id = 4, .tag = "section" },
        .{ .elem_id = 5, .parent_elem_id = 4, .scope_id = 4, .tag = "span" },
    }) catch @panic("out of memory");
    for (replacement.render_nodes.items, 0..) |node, index| {
        ensureTestElemDescriptorIndex(&replacement, allocator, node.elem_id.raw()).element = DescriptorIndex.init(index);
        recordRenderNodeIndex(TestStream, &replacement, allocator, node.elem_id, index);
    }
    appendRenderChild(TestStream, &replacement, allocator, ElemId.fromRaw(0), ElemId.fromRaw(4));
    appendRenderChild(TestStream, &replacement, allocator, ElemId.fromRaw(4), ElemId.fromRaw(5));

    fault.configure(1);
    commitSparseRenderNodes(TestStream, &active, &replacement, &retired, &.{2});
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    fault.configure(null);
    try std.testing.expectEqual(@as(usize, 4), active.render_nodes.items.len);
    try std.testing.expectEqual(@as(?usize, null), renderNodeIndex(TestStream, &active, ElemId.fromRaw(2)));
    try std.testing.expectEqual(@as(?usize, 1), renderNodeIndex(TestStream, &active, ElemId.fromRaw(3)));
    try std.testing.expectEqual(@as(?usize, 2), renderNodeIndex(TestStream, &active, ElemId.fromRaw(4)));
    try std.testing.expectEqual(@as(?usize, 3), renderNodeIndex(TestStream, &active, ElemId.fromRaw(5)));
    try std.testing.expectEqual(ElemId.fromRaw(2), retired.render_nodes.items[0].elem_id);
    try std.testing.expectEqual(@as(?ElemId, null), previousRenderSibling(TestStream, &active, ElemId.fromRaw(4)));
    try std.testing.expectEqual(@as(?ElemId, ElemId.fromRaw(5)), firstRenderChild(TestStream, &active, ElemId.fromRaw(4)));

    removeRenderChild(TestStream, &active, ElemId.fromRaw(0), ElemId.fromRaw(2));
    insertRenderChildren(TestStream, &active, allocator, ElemId.fromRaw(0), 1, &.{ElemId.fromRaw(4)});
    finishSparseRenderNodeRetirementImpl(TestStream, &active, &.{2});
    const children = streamDirectChildren(TestStream, allocator, &active, ElemId.fromRaw(0));
    defer allocator.free(children);
    try std.testing.expectEqualSlices(ElemId, &.{ ElemId.fromRaw(1), ElemId.fromRaw(4), ElemId.fromRaw(3) }, children);
    try std.testing.expect(!active.render_metadata_by_elem_id.contains(2));
}
