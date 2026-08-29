//! Render-state cache that suppresses duplicate host commands for stable DOM nodes.

const std = @import("std");
const builtin = @import("builtin");
const boundary = @import("boundary.zig");
const render = @import("render_commands.zig");
const render_sink = @import("render_sink.zig");
const ids = @import("ids.zig");

pub const TextField = render.TextField;
pub const BoolField = render.BoolField;
pub const EventKind = render.EventKind;
pub const BoundaryPayloadDescriptor = boundary.BoundaryPayloadDescriptor;
pub const EventBindingKey = render_sink.EventBindingKey;
pub const EventBinding = render_sink.EventBinding;

pub const EventBindings = struct {
    click: ?EventBinding = null,
    input: ?EventBinding = null,
    check: ?EventBinding = null,
    pointer_down: ?EventBinding = null,
    pointer_up: ?EventBinding = null,
    pointer_enter: ?EventBinding = null,
    pointer_leave: ?EventBinding = null,
};

/// Maps a fixed event kind to its compact cache slot.
pub fn eventBindingSlot(bindings: *EventBindings, kind: EventKind) *?EventBinding {
    return switch (kind) {
        .click => &bindings.click,
        .input => &bindings.input,
        .check => &bindings.check,
        .pointer_down => &bindings.pointer_down,
        .pointer_up => &bindings.pointer_up,
        .pointer_enter => &bindings.pointer_enter,
        .pointer_leave => &bindings.pointer_leave,
    };
}

pub const CustomTextAttr = struct {
    name: []const u8,
    value: []const u8,

    fn deinit(self: CustomTextAttr, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
    }
};

pub const NamedEvent = struct {
    name: []const u8,
    binding: EventBinding,

    fn deinit(self: NamedEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub const ScalarNode = struct {
    lifecycle: union(enum) {
        vacant,
        active: []const u8,
    } = .vacant,
    parent_id: ?ids.ElemId = null,
    children: std.ArrayListUnmanaged(ids.ElemId) = .empty,
    event_bindings: EventBindings = .{},
    text: ?[]const u8 = null,
    role: ?[]const u8 = null,
    label: ?[]const u8 = null,
    test_id: ?[]const u8 = null,
    value: ?[]const u8 = null,
    class: ?[]const u8 = null,
    custom_text_attrs: std.ArrayListUnmanaged(CustomTextAttr) = .empty,
    named_events: std.ArrayListUnmanaged(NamedEvent) = .empty,
    checked: ?bool = null,
    disabled: ?bool = null,

    fn deinit(self: *ScalarNode, allocator: std.mem.Allocator) void {
        if (self.text) |text| allocator.free(text);
        if (self.role) |role| allocator.free(role);
        if (self.label) |label| allocator.free(label);
        if (self.test_id) |test_id| allocator.free(test_id);
        if (self.value) |value| allocator.free(value);
        if (self.class) |class| allocator.free(class);
        for (self.custom_text_attrs.items) |attr| {
            attr.deinit(allocator);
        }
        self.custom_text_attrs.deinit(allocator);
        for (self.named_events.items) |event| {
            event.deinit(allocator);
        }
        self.named_events.deinit(allocator);
        self.children.deinit(allocator);
        self.* = .{};
    }

    fn initActive(tag: []const u8) ScalarNode {
        return .{ .lifecycle = .{ .active = tag } };
    }

    /// Reports whether this dense cache slot currently owns a render node.
    pub fn isActive(self: *const ScalarNode) bool {
        return self.lifecycle == .active;
    }

    /// Returns the tag carried by an active node, or null for a vacant slot.
    pub fn activeTag(self: *const ScalarNode) ?[]const u8 {
        return switch (self.lifecycle) {
            .vacant => null,
            .active => |tag| tag,
        };
    }

    fn textSlot(self: *ScalarNode, field: TextField) *?[]const u8 {
        return switch (field) {
            .text => &self.text,
            .role => &self.role,
            .label => &self.label,
            .test_id => &self.test_id,
            .value => &self.value,
            .class => &self.class,
        };
    }

    fn boolSlot(self: *ScalarNode, field: BoolField) *?bool {
        return switch (field) {
            .checked => &self.checked,
            .disabled => &self.disabled,
        };
    }

    /// Resolves a custom attribute name to its cache entry for targeted updates.
    pub fn customTextAttrIndex(self: *const ScalarNode, name: []const u8) ?usize {
        for (self.custom_text_attrs.items, 0..) |attr, index| {
            if (std.mem.eql(u8, attr.name, name)) return index;
        }
        return null;
    }

    /// Resolves a named event to its cache entry without scanning unrelated bindings.
    pub fn namedEventIndex(self: *const ScalarNode, name: []const u8) ?usize {
        for (self.named_events.items, 0..) |event, index| {
            if (std.mem.eql(u8, event.name, name)) return index;
        }
        return null;
    }

    fn fixedEventBindingSlot(self: *ScalarNode, kind: EventKind) *?EventBinding {
        return eventBindingSlot(&self.event_bindings, kind);
    }

    fn fixedEventId(self: *const ScalarNode, kind: EventKind) ?u64 {
        const binding = switch (kind) {
            .click => self.event_bindings.click,
            .input => self.event_bindings.input,
            .check => self.event_bindings.check,
            .pointer_down => self.event_bindings.pointer_down,
            .pointer_up => self.event_bindings.pointer_up,
            .pointer_enter => self.event_bindings.pointer_enter,
            .pointer_leave => self.event_bindings.pointer_leave,
        } orelse return null;
        return binding.event_id.raw();
    }
};

fn elemSliceIndex(items: []const ids.ElemId, target: ids.ElemId) ?usize {
    for (items, 0..) |item, index| {
        if (item == target) return index;
    }
    return null;
}

fn stableSubsequenceLength(indexes: []const usize, scratch: []usize) usize {
    var len: usize = 0;
    for (indexes) |index| {
        var low: usize = 0;
        var high = len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (scratch[mid] < index) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        scratch[low] = index;
        if (low == len) len += 1;
    }
    return len;
}

const JournalPhase = enum {
    prepared,
    applied,

    fn isApplied(self: JournalPhase) bool {
        return self == .applied;
    }
};

/// Owns one parent-child replacement until an allocation-free cache commit.
pub const PreparedChildrenReplacement = struct {
    parent_elem_id: ids.ElemId,
    next: []ids.ElemId,
    retired: std.ArrayListUnmanaged(ids.ElemId) = .empty,
    phase: JournalPhase = .prepared,

    /// Copies the next child order without mutating the active cache.
    pub fn prepare(comptime Ctx: type, allocator: std.mem.Allocator, cache: *const Cache(Ctx), parent_elem_id: ids.ElemId, next: []const ids.ElemId) (std.mem.Allocator.Error || error{MissingParent})!PreparedChildrenReplacement {
        const index = parent_elem_id.index();
        if (index >= cache.nodes.items.len or !cache.nodes.items[index].isActive()) return error.MissingParent;
        return .{ .parent_elem_id = parent_elem_id, .next = try allocator.dupe(ids.ElemId, next) };
    }

    /// Swaps the prepared order into the cache without allocating.
    pub fn apply(self: *PreparedChildrenReplacement, comptime Ctx: type, cache: *Cache(Ctx)) void {
        if (self.phase.isApplied()) @panic("prepared child replacement committed twice");
        const node = &cache.nodes.items[self.parent_elem_id.index()];
        self.retired = node.children;
        node.children = .{ .items = self.next, .capacity = self.next.len };
        self.next = &.{};
        self.phase = .applied;
    }

    /// Releases provisional or retired child storage after abort or commit.
    pub fn deinit(self: *PreparedChildrenReplacement, allocator: std.mem.Allocator) void {
        allocator.free(self.next);
        self.retired.deinit(allocator);
        self.* = undefined;
    }
};

/// Defers ownership transfer for one cache-node removal until commit.
pub const PreparedNodeRemoval = struct {
    elem_id: ids.ElemId,
    retired: ScalarNode = .{},
    phase: JournalPhase = .prepared,

    /// Validates an active non-root cache node without mutating it.
    pub fn prepare(comptime Ctx: type, cache: *const Cache(Ctx), elem_id: ids.ElemId) error{MissingNode}!PreparedNodeRemoval {
        const index = elem_id.index();
        if (elem_id == ids.root_elem or index >= cache.nodes.items.len or !cache.nodes.items[index].isActive()) return error.MissingNode;
        return .{ .elem_id = elem_id };
    }

    /// Transfers the active node into retired ownership without allocating.
    pub fn apply(self: *PreparedNodeRemoval, comptime Ctx: type, cache: *Cache(Ctx)) void {
        if (self.phase.isApplied()) @panic("prepared render node removal committed twice");
        const node = &cache.nodes.items[self.elem_id.index()];
        self.retired = node.*;
        node.* = .{};
        self.phase = .applied;
    }

    /// Releases a committed retired node; abort before commit owns nothing.
    pub fn deinit(self: *PreparedNodeRemoval, allocator: std.mem.Allocator) void {
        if (self.phase.isApplied()) self.retired.deinit(allocator);
        self.* = undefined;
    }
};

/// Owns and deduplicates tags missing from the active cache until publication.
pub const PreparedTagOverlay = struct {
    entries: std.StringHashMapUnmanaged([]const u8) = .empty,
    phase: JournalPhase = .prepared,

    /// Reserves provisional and persistent tag tables for the whole batch.
    pub fn init(comptime Ctx: type, allocator: std.mem.Allocator, cache: *Cache(Ctx), expected_new_tags: usize) (std.mem.Allocator.Error || error{ResourceLimit})!PreparedTagOverlay {
        var self: PreparedTagOverlay = .{};
        errdefer self.entries.deinit(allocator);
        const additional = std.math.cast(u32, expected_new_tags) orelse return error.ResourceLimit;
        try self.entries.ensureUnusedCapacity(allocator, additional);
        try cache.interned_tags.ensureUnusedCapacity(allocator, additional);
        return self;
    }

    /// Resolves an active or provisional tag, copying each missing value once.
    pub fn resolve(self: *PreparedTagOverlay, comptime Ctx: type, allocator: std.mem.Allocator, cache: *const Cache(Ctx), tag: []const u8) std.mem.Allocator.Error![]const u8 {
        if (cache.interned_tags.get(tag)) |interned| return interned;
        if (self.entries.get(tag)) |provisional| return provisional;
        const owned = try allocator.dupe(u8, tag);
        self.entries.putAssumeCapacity(owned, owned);
        return owned;
    }

    /// Publishes every missing tag into pre-reserved persistent storage.
    pub fn apply(self: *PreparedTagOverlay, comptime Ctx: type, cache: *Cache(Ctx)) void {
        if (self.phase.isApplied()) @panic("prepared tag overlay committed twice");
        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| cache.interned_tags.putAssumeCapacity(entry.key_ptr.*, entry.value_ptr.*);
        self.phase = .applied;
    }

    /// Releases unpublished tags or only the overlay table after commit.
    pub fn deinit(self: *PreparedTagOverlay, allocator: std.mem.Allocator) void {
        if (!self.phase.isApplied()) {
            var values = self.entries.valueIterator();
            while (values.next()) |value| allocator.free(value.*);
        }
        self.entries.deinit(allocator);
        self.* = undefined;
    }
};

/// Owns a cache node until publication; its tag belongs to a tag overlay.
pub const PreparedNodeCreation = struct {
    elem_id: ids.ElemId,
    tag: []const u8,
    phase: JournalPhase = .prepared,

    /// Resolves a provisional tag without changing cache indexes.
    pub fn prepare(comptime Ctx: type, allocator: std.mem.Allocator, cache: *Cache(Ctx), tags: *PreparedTagOverlay, elem_id: ids.ElemId, tag: []const u8) (std.mem.Allocator.Error || error{ ActiveNode, ResourceLimit })!PreparedNodeCreation {
        return prepareImpl(Ctx, allocator, cache, tags, elem_id, tag, false);
    }

    /// Resolves a provisional tag for a slot retired by the same render plan.
    pub fn prepareReplacing(comptime Ctx: type, allocator: std.mem.Allocator, cache: *Cache(Ctx), tags: *PreparedTagOverlay, elem_id: ids.ElemId, tag: []const u8) (std.mem.Allocator.Error || error{ResourceLimit})!PreparedNodeCreation {
        return prepareImpl(Ctx, allocator, cache, tags, elem_id, tag, true) catch |err| switch (err) {
            error.ActiveNode => unreachable,
            else => |other| other,
        };
    }

    fn prepareImpl(comptime Ctx: type, allocator: std.mem.Allocator, cache: *Cache(Ctx), tags: *PreparedTagOverlay, elem_id: ids.ElemId, tag: []const u8, replaces_active: bool) (std.mem.Allocator.Error || error{ ActiveNode, ResourceLimit })!PreparedNodeCreation {
        const index = elem_id.index();
        if (!replaces_active and index < cache.nodes.items.len and cache.nodes.items[index].isActive()) return error.ActiveNode;
        return .{ .elem_id = elem_id, .tag = try tags.resolve(Ctx, allocator, cache, tag) };
    }

    /// Publishes the node using only pre-reserved storage after tag publication.
    pub fn apply(self: *PreparedNodeCreation, comptime Ctx: type, cache: *Cache(Ctx)) void {
        if (self.phase.isApplied()) @panic("prepared render node creation committed twice");
        const index = self.elem_id.index();
        while (cache.nodes.items.len <= index) cache.nodes.appendAssumeCapacity(.{});
        cache.nodes.items[index] = ScalarNode.initActive(self.tag);
        self.phase = .applied;
    }

    /// Clears the non-owning prepared node state.
    pub fn deinit(self: *PreparedNodeCreation) void {
        self.* = undefined;
    }
};

/// Owns one text-field value until an allocation-free cache update.
pub const PreparedTextFieldUpdate = struct {
    elem_id: ids.ElemId,
    field: TextField,
    next: ?[]u8,
    retired: ?[]const u8 = null,
    phase: JournalPhase = .prepared,

    /// Copies an optional next value without changing the active node.
    pub fn prepare(comptime Ctx: type, allocator: std.mem.Allocator, cache: *const Cache(Ctx), elem_id: ids.ElemId, field: TextField, value: ?[]const u8) (std.mem.Allocator.Error || error{MissingNode})!PreparedTextFieldUpdate {
        const index = elem_id.index();
        if (index >= cache.nodes.items.len or !cache.nodes.items[index].isActive()) return error.MissingNode;
        return prepareKnownNode(allocator, elem_id, field, value);
    }

    fn prepareKnownNode(allocator: std.mem.Allocator, elem_id: ids.ElemId, field: TextField, value: ?[]const u8) std.mem.Allocator.Error!PreparedTextFieldUpdate {
        return .{ .elem_id = elem_id, .field = field, .next = if (value) |bytes| try allocator.dupe(u8, bytes) else null };
    }

    /// Swaps the prepared value into the active cache without allocating.
    pub fn apply(self: *PreparedTextFieldUpdate, comptime Ctx: type, cache: *Cache(Ctx)) void {
        if (self.phase.isApplied()) @panic("prepared text field update committed twice");
        const slot = cache.nodes.items[self.elem_id.index()].textSlot(self.field);
        self.retired = slot.*;
        slot.* = self.next;
        self.next = null;
        self.phase = .applied;
    }

    /// Releases the provisional value on abort or the retired value after commit.
    pub fn deinit(self: *PreparedTextFieldUpdate, allocator: std.mem.Allocator) void {
        if (self.next) |value| allocator.free(value);
        if (self.retired) |value| allocator.free(value);
        self.* = undefined;
    }
};

/// Stores one allocation-free boolean cache update.
pub const PreparedBoolFieldUpdate = struct {
    elem_id: ids.ElemId,
    field: BoolField,
    next: ?bool,
    retired: ?bool = null,
    phase: JournalPhase = .prepared,

    /// Validates the active node without changing it.
    pub fn prepare(comptime Ctx: type, cache: *const Cache(Ctx), elem_id: ids.ElemId, field: BoolField, value: ?bool) error{MissingNode}!PreparedBoolFieldUpdate {
        const index = elem_id.index();
        if (index >= cache.nodes.items.len or !cache.nodes.items[index].isActive()) return error.MissingNode;
        return .{ .elem_id = elem_id, .field = field, .next = value };
    }

    /// Swaps the prepared value into the active cache without allocating.
    pub fn apply(self: *PreparedBoolFieldUpdate, comptime Ctx: type, cache: *Cache(Ctx)) void {
        if (self.phase.isApplied()) @panic("prepared boolean field update committed twice");
        const slot = cache.nodes.items[self.elem_id.index()].boolSlot(self.field);
        self.retired = slot.*;
        slot.* = self.next;
        self.phase = .applied;
    }
};

/// Stores one allocation-free fixed-event binding update.
pub const PreparedFixedEventUpdate = struct {
    elem_id: ids.ElemId,
    kind: EventKind,
    next: ?EventBinding,
    retired: ?EventBinding = null,
    phase: JournalPhase = .prepared,

    /// Canonicalizes delivery metadata and validates the active node.
    pub fn prepare(comptime Ctx: type, cache: *const Cache(Ctx), elem_id: ids.ElemId, kind: EventKind, binding: ?EventBinding) error{MissingNode}!PreparedFixedEventUpdate {
        const index = elem_id.index();
        if (index >= cache.nodes.items.len or !cache.nodes.items[index].isActive()) return error.MissingNode;
        return .{ .elem_id = elem_id, .kind = kind, .next = if (binding) |value| value.withDeliveryFor(.{ .fixed = kind }) else null };
    }

    /// Swaps the prepared binding into the active cache without allocation.
    pub fn apply(self: *PreparedFixedEventUpdate, comptime Ctx: type, cache: *Cache(Ctx)) void {
        if (self.phase.isApplied()) @panic("prepared fixed event update committed twice");
        const slot = cache.nodes.items[self.elem_id.index()].fixedEventBindingSlot(self.kind);
        self.retired = slot.*;
        slot.* = self.next;
        self.phase = .applied;
    }
};

/// Owns the complete custom-text attribute set for one touched node.
pub const PreparedCustomTextAttrsReplacement = struct {
    elem_id: ids.ElemId,
    next: []CustomTextAttr,
    retired: std.ArrayListUnmanaged(CustomTextAttr) = .empty,
    phase: JournalPhase = .prepared,

    /// Copies final names and values without changing the active cache.
    pub fn prepare(comptime Ctx: type, allocator: std.mem.Allocator, cache: *const Cache(Ctx), elem_id: ids.ElemId, attrs: []const CustomTextAttr) (std.mem.Allocator.Error || error{MissingNode})!PreparedCustomTextAttrsReplacement {
        const index = elem_id.index();
        if (index >= cache.nodes.items.len or !cache.nodes.items[index].isActive()) return error.MissingNode;
        return prepareKnownNode(allocator, elem_id, attrs);
    }

    fn prepareKnownNode(allocator: std.mem.Allocator, elem_id: ids.ElemId, attrs: []const CustomTextAttr) std.mem.Allocator.Error!PreparedCustomTextAttrsReplacement {
        const next = try allocator.alloc(CustomTextAttr, attrs.len);
        errdefer allocator.free(next);
        var initialized: usize = 0;
        errdefer for (next[0..initialized]) |attr| attr.deinit(allocator);
        for (attrs, 0..) |attr, offset| {
            const name = try allocator.dupe(u8, attr.name);
            errdefer allocator.free(name);
            const value = try allocator.dupe(u8, attr.value);
            next[offset] = .{ .name = name, .value = value };
            initialized += 1;
        }
        return .{ .elem_id = elem_id, .next = next };
    }

    /// Swaps final attributes into the active cache without allocating.
    pub fn apply(self: *PreparedCustomTextAttrsReplacement, comptime Ctx: type, cache: *Cache(Ctx)) void {
        if (self.phase.isApplied()) @panic("prepared custom attribute replacement committed twice");
        const node = &cache.nodes.items[self.elem_id.index()];
        self.retired = node.custom_text_attrs;
        node.custom_text_attrs = .{ .items = self.next, .capacity = self.next.len };
        self.next = &.{};
        self.phase = .applied;
    }

    /// Releases provisional attributes on abort or retired attributes after commit.
    pub fn deinit(self: *PreparedCustomTextAttrsReplacement, allocator: std.mem.Allocator) void {
        for (self.next) |attr| attr.deinit(allocator);
        allocator.free(self.next);
        for (self.retired.items) |attr| attr.deinit(allocator);
        self.retired.deinit(allocator);
        self.* = undefined;
    }
};

/// Owns the complete named-event set for one touched node.
pub const PreparedNamedEventsReplacement = struct {
    elem_id: ids.ElemId,
    next: []NamedEvent,
    retired: std.ArrayListUnmanaged(NamedEvent) = .empty,
    phase: JournalPhase = .prepared,

    /// Copies final event names and canonicalizes bindings without cache mutation.
    pub fn prepare(comptime Ctx: type, allocator: std.mem.Allocator, cache: *const Cache(Ctx), elem_id: ids.ElemId, events: []const NamedEvent) (std.mem.Allocator.Error || error{MissingNode})!PreparedNamedEventsReplacement {
        const index = elem_id.index();
        if (index >= cache.nodes.items.len or !cache.nodes.items[index].isActive()) return error.MissingNode;
        return prepareKnownNode(allocator, elem_id, events);
    }

    fn prepareKnownNode(allocator: std.mem.Allocator, elem_id: ids.ElemId, events: []const NamedEvent) std.mem.Allocator.Error!PreparedNamedEventsReplacement {
        const next = try allocator.alloc(NamedEvent, events.len);
        errdefer allocator.free(next);
        var initialized: usize = 0;
        errdefer for (next[0..initialized]) |event| event.deinit(allocator);
        for (events, 0..) |event, offset| {
            const name = try allocator.dupe(u8, event.name);
            next[offset] = .{
                .name = name,
                .binding = event.binding.withDeliveryFor(.{ .named = name }),
            };
            initialized += 1;
        }
        return .{ .elem_id = elem_id, .next = next };
    }

    /// Swaps final named events into the active cache without allocating.
    pub fn apply(self: *PreparedNamedEventsReplacement, comptime Ctx: type, cache: *Cache(Ctx)) void {
        if (self.phase.isApplied()) @panic("prepared named event replacement committed twice");
        const node = &cache.nodes.items[self.elem_id.index()];
        self.retired = node.named_events;
        node.named_events = .{ .items = self.next, .capacity = self.next.len };
        self.next = &.{};
        self.phase = .applied;
    }

    /// Releases provisional events on abort or retired events after commit.
    pub fn deinit(self: *PreparedNamedEventsReplacement, allocator: std.mem.Allocator) void {
        for (self.next) |event| event.deinit(allocator);
        allocator.free(self.next);
        for (self.retired.items) |event| event.deinit(allocator);
        self.retired.deinit(allocator);
        self.* = undefined;
    }
};

/// Upper bounds used to reserve one render splice journal before preparation.
pub const PreparedRenderCounts = struct {
    node_capacity: usize = 0,
    new_tags: usize = 0,
    removals: usize = 0,
    creations: usize = 0,
    children: usize = 0,
    text_fields: usize = 0,
    bool_fields: usize = 0,
    fixed_events: usize = 0,
    custom_attrs: usize = 0,
    named_events: usize = 0,
    child_links: usize = 0,
    wire_commands: usize = 0,
    /// Active nodes this splice keeps in place while their subtree is
    /// re-collected under the same id and tag; see `addNodeReuse`.
    reuses: usize = 0,
};

/// Which scalar fields a re-collected descriptor set on a reused node, so
/// `clearUnsetReusedFields` can retire every field the old subtree carried
/// and the new one no longer declares.
const ReusedNodeFields = struct {
    text: u8 = 0,
    bools: u8 = 0,
    events: u8 = 0,

    fn textBit(field: TextField) u8 {
        return @as(u8, 1) << @intCast(@intFromEnum(field));
    }

    fn boolBit(field: BoolField) u8 {
        return @as(u8, 1) << @intCast(@intFromEnum(field));
    }

    fn eventBit(kind: EventKind) u8 {
        return @as(u8, 1) << @intCast(@intFromEnum(kind));
    }
};

/// Number of scalar clears one reused node can need at most: every text
/// field, bool field, and fixed event kind the old subtree may have set.
pub const reused_node_max_clears: usize = std.enums.values(TextField).len + std.enums.values(BoolField).len + std.enums.values(EventKind).len;

/// Owns every cache delta for one render splice until atomic publication.
pub fn PreparedRenderSplice(comptime Ctx: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        tags: PreparedTagOverlay,
        removals: std.ArrayListUnmanaged(PreparedNodeRemoval) = .empty,
        creations: std.ArrayListUnmanaged(PreparedNodeCreation) = .empty,
        children: std.ArrayListUnmanaged(PreparedChildrenReplacement) = .empty,
        text_fields: std.ArrayListUnmanaged(PreparedTextFieldUpdate) = .empty,
        bool_fields: std.ArrayListUnmanaged(PreparedBoolFieldUpdate) = .empty,
        fixed_events: std.ArrayListUnmanaged(PreparedFixedEventUpdate) = .empty,
        custom_attrs: std.ArrayListUnmanaged(PreparedCustomTextAttrsReplacement) = .empty,
        named_events: std.ArrayListUnmanaged(PreparedNamedEventsReplacement) = .empty,
        provisional_nodes: std.AutoHashMapUnmanaged(u64, void) = .empty,
        reused_nodes: std.AutoHashMapUnmanaged(u64, ReusedNodeFields) = .empty,
        parent_intent_indexes: std.AutoHashMapUnmanaged(u64, usize) = .empty,
        parent_intents: std.ArrayListUnmanaged(ParentIntent) = .empty,
        wire: render.PreparedBatch,
        phase: JournalPhase = .prepared,

        const ParentIntent = struct { child_id: ids.ElemId, next: ?ids.ElemId, retired: ?ids.ElemId };

        /// Reserves every plan-local journal and persistent tag slot before collection.
        pub fn init(allocator: std.mem.Allocator, cache: *Cache(Ctx), counts: PreparedRenderCounts) (std.mem.Allocator.Error || error{ResourceLimit})!Self {
            var tags = try PreparedTagOverlay.init(Ctx, allocator, cache, counts.new_tags);
            const wire = render.PreparedBatch.init(allocator, counts.wire_commands) catch |err| {
                tags.deinit(allocator);
                return err;
            };
            var self = Self{
                .allocator = allocator,
                .tags = tags,
                .wire = wire,
            };
            errdefer self.deinit();
            try cache.preflightNodeCapacity(allocator, counts.node_capacity);
            try self.removals.ensureTotalCapacity(allocator, counts.removals);
            try self.creations.ensureTotalCapacity(allocator, counts.creations);
            try self.children.ensureTotalCapacity(allocator, counts.children);
            try self.text_fields.ensureTotalCapacity(allocator, counts.text_fields);
            try self.bool_fields.ensureTotalCapacity(allocator, counts.bool_fields);
            try self.fixed_events.ensureTotalCapacity(allocator, counts.fixed_events);
            try self.custom_attrs.ensureTotalCapacity(allocator, counts.custom_attrs);
            try self.named_events.ensureTotalCapacity(allocator, counts.named_events);
            const creation_count = std.math.cast(u32, counts.creations) orelse return error.ResourceLimit;
            const child_link_count = std.math.cast(u32, counts.child_links) orelse return error.ResourceLimit;
            try self.provisional_nodes.ensureUnusedCapacity(allocator, creation_count);
            const reuse_count = std.math.cast(u32, counts.reuses) orelse return error.ResourceLimit;
            try self.reused_nodes.ensureUnusedCapacity(allocator, reuse_count);
            try self.parent_intent_indexes.ensureUnusedCapacity(allocator, child_link_count);
            try self.parent_intents.ensureTotalCapacity(allocator, counts.child_links);
            return self;
        }

        fn nodeExists(self: *const Self, cache: *const Cache(Ctx), elem_id: ids.ElemId) bool {
            const index = elem_id.index();
            return self.provisional_nodes.contains(elem_id.raw()) or
                (index < cache.nodes.items.len and cache.nodes.items[index].isActive());
        }

        fn activeNode(self: *const Self, cache: *const Cache(Ctx), elem_id: ids.ElemId) ?*const ScalarNode {
            if (self.provisional_nodes.contains(elem_id.raw())) return null;
            const index = elem_id.index();
            if (index >= cache.nodes.items.len or !cache.nodes.items[index].isActive()) return null;
            return &cache.nodes.items[index];
        }

        /// Reserves capacity for `parents` further final child-list
        /// replacements, together with `child_links` parent intents and wire
        /// commands, before any journal mutation.
        ///
        /// One `addChildren` call consumes exactly one child-list slot, so a
        /// caller that registers several parents on one splice must reserve a
        /// slot for each: `addChildren` publishes through `appendAssumeCapacity`
        /// and cannot grow at that point.
        pub fn reserveAdditionalChildren(self: *Self, parents: usize, child_links: usize) (std.mem.Allocator.Error || error{ResourceLimit})!void {
            try self.children.ensureUnusedCapacity(self.allocator, parents);
            const link_count = std.math.cast(u32, child_links) orelse return error.ResourceLimit;
            try self.parent_intent_indexes.ensureUnusedCapacity(self.allocator, link_count);
            try self.parent_intents.ensureUnusedCapacity(self.allocator, child_links);
            try self.wire.reserveAdditional(self.allocator, child_links);
        }

        /// Transfers scalar field and custom-attribute journals with their wire
        /// commands from a separately prepared splice. The donor must contain
        /// no topology or event edits; structural and scalar preparation remain
        /// independent while publishing through one atomic batch.
        ///
        /// The donor was prepared against the committed cache before this
        /// splice decided which nodes it retires, so it may carry updates for
        /// nodes this splice removes (or removes and recreates under the same
        /// id). Those updates have no node to land on: applying them after the
        /// removal would plant owned copies in a vacant slot that the next
        /// creation overwrites, and their wire commands would address a node
        /// the batch already removed. A node reused in place (`addNodeReuse`)
        /// is treated the same way: its re-collected descriptors already
        /// decided every field, and the donor evaluated the retired ones.
        /// Ownership of every donor entry therefore resolves here: entries for
        /// surviving nodes move to this splice, entries for retired or reused
        /// nodes are released, and on failure the donor still owns everything
        /// it prepared.
        pub fn adoptScalarUpdates(self: *Self, donor: *Self) (std.mem.Allocator.Error || error{ResourceLimit})!void {
            if (donor.removals.items.len != 0 or donor.creations.items.len != 0 or donor.children.items.len != 0 or donor.fixed_events.items.len != 0 or donor.named_events.items.len != 0 or donor.provisional_nodes.count() != 0 or donor.parent_intents.items.len != 0) return error.ResourceLimit;
            var retired: std.AutoHashMapUnmanaged(u64, void) = .empty;
            defer retired.deinit(self.allocator);
            const retired_bound = std.math.add(usize, self.removals.items.len, self.reused_nodes.count()) catch return error.ResourceLimit;
            try retired.ensureUnusedCapacity(self.allocator, std.math.cast(u32, retired_bound) orelse return error.ResourceLimit);
            for (self.removals.items) |removal| retired.putAssumeCapacity(removal.elem_id.raw(), {});
            var reused_iterator = self.reused_nodes.keyIterator();
            while (reused_iterator.next()) |elem_id| retired.putAssumeCapacity(elem_id.*, {});
            var kept_text: usize = 0;
            for (donor.text_fields.items) |entry| kept_text += @intFromBool(!retired.contains(entry.elem_id.raw()));
            var kept_bool: usize = 0;
            for (donor.bool_fields.items) |entry| kept_bool += @intFromBool(!retired.contains(entry.elem_id.raw()));
            var kept_custom: usize = 0;
            for (donor.custom_attrs.items) |entry| kept_custom += @intFromBool(!retired.contains(entry.elem_id.raw()));
            try self.text_fields.ensureUnusedCapacity(self.allocator, kept_text);
            try self.bool_fields.ensureUnusedCapacity(self.allocator, kept_bool);
            try self.custom_attrs.ensureUnusedCapacity(self.allocator, kept_custom);
            try self.wire.appendPreparedSurviving(self.allocator, &donor.wire, &retired);
            for (donor.text_fields.items) |*entry| {
                if (retired.contains(entry.elem_id.raw())) entry.deinit(donor.allocator) else self.text_fields.appendAssumeCapacity(entry.*);
            }
            for (donor.bool_fields.items) |entry| {
                if (!retired.contains(entry.elem_id.raw())) self.bool_fields.appendAssumeCapacity(entry);
            }
            for (donor.custom_attrs.items) |*entry| {
                if (retired.contains(entry.elem_id.raw())) entry.deinit(donor.allocator) else self.custom_attrs.appendAssumeCapacity(entry.*);
            }
            donor.text_fields.clearRetainingCapacity();
            donor.bool_fields.clearRetainingCapacity();
            donor.custom_attrs.clearRetainingCapacity();
        }

        /// Adds one active node retirement and its corresponding host removal.
        pub fn addRemoval(self: *Self, cache: *const Cache(Ctx), elem_id: ids.ElemId) error{ MissingNode, ResourceLimit }!void {
            self.removals.appendAssumeCapacity(try PreparedNodeRemoval.prepare(Ctx, cache, elem_id));
            self.setParentIntent(cache, elem_id.raw(), null) catch |err| switch (err) {
                error.ConflictingParent, error.DuplicateChild => unreachable,
                else => |value| return value,
            };
            try self.wire.addSemantic(.{ .remove_node = try render.WireElemId.fromEngine(elem_id) });
        }

        /// Journals one same-id remove/recreate operation against the active cache.
        pub fn addNodeReplacement(self: *Self, cache: *Cache(Ctx), elem_id: ids.ElemId, tag: []const u8) (std.mem.Allocator.Error || error{ DuplicateNode, MissingNode, ResourceLimit })!void {
            try self.addRemoval(cache, elem_id);
            try self.addReplacementCreation(cache, elem_id, tag);
        }

        /// Keeps an active node in place while a re-collected subtree claims
        /// its id under the same tag. The host sees no removal or creation;
        /// every scalar field the new descriptors set is diffed against the
        /// node's committed state like any live update, and
        /// `clearUnsetReusedFields` retires the fields they no longer declare.
        /// The caller replaces the node's child list through `addChildren`.
        pub fn addNodeReuse(self: *Self, cache: *const Cache(Ctx), elem_id: ids.ElemId, tag: []const u8) error{ DuplicateNode, MissingNode, TagMismatch, ResourceLimit }!void {
            const node = self.activeNode(cache, elem_id) orelse return error.MissingNode;
            if (!std.mem.eql(u8, node.activeTag().?, tag)) return error.TagMismatch;
            if (self.reused_nodes.contains(elem_id.raw())) return error.DuplicateNode;
            if (self.reused_nodes.available == 0) return error.ResourceLimit;
            self.reused_nodes.putAssumeCapacity(elem_id.raw(), .{});
        }

        /// Clears, on every reused node, each text field, bool field, and fixed
        /// event kind that no descriptor set since `addNodeReuse`. Call once
        /// after all field journaling for the splice; a field already absent
        /// on the committed node emits nothing.
        pub fn clearUnsetReusedFields(self: *Self, cache: *const Cache(Ctx)) (std.mem.Allocator.Error || error{ MissingNode, ResourceLimit })!void {
            var iterator = self.reused_nodes.iterator();
            while (iterator.next()) |entry| {
                const elem_id = ids.ElemId.fromRaw(entry.key_ptr.*);
                const fields = entry.value_ptr.*;
                inline for (std.enums.values(TextField)) |field| if (fields.text & ReusedNodeFields.textBit(field) == 0) {
                    try self.addTextField(cache, elem_id, field, null);
                };
                inline for (std.enums.values(BoolField)) |field| if (fields.bools & ReusedNodeFields.boolBit(field) == 0) {
                    try self.addBoolField(cache, elem_id, field, null);
                };
                inline for (std.enums.values(EventKind)) |kind| if (fields.events & ReusedNodeFields.eventBit(kind) == 0) {
                    try self.addFixedEvent(cache, elem_id, kind, null);
                };
            }
        }

        /// Adds one provisional node and its prepared tag to the journal.
        pub fn addCreation(self: *Self, cache: *Cache(Ctx), elem_id: ids.ElemId, tag: []const u8) (std.mem.Allocator.Error || error{ ActiveNode, DuplicateNode, ResourceLimit })!void {
            return self.addCreationOptions(cache, elem_id, tag, false);
        }

        /// Adds a provisional node whose active slot is retired by this plan.
        fn addReplacementCreation(self: *Self, cache: *Cache(Ctx), elem_id: ids.ElemId, tag: []const u8) (std.mem.Allocator.Error || error{ DuplicateNode, ResourceLimit })!void {
            self.addCreationOptions(cache, elem_id, tag, true) catch |err| switch (err) {
                error.ActiveNode => unreachable,
                else => |value| return value,
            };
        }

        fn addCreationOptions(self: *Self, cache: *Cache(Ctx), elem_id: ids.ElemId, tag: []const u8, replaces_active: bool) (std.mem.Allocator.Error || error{ ActiveNode, DuplicateNode, ResourceLimit })!void {
            if (self.provisional_nodes.contains(elem_id.raw())) return error.DuplicateNode;
            const prepared = if (replaces_active)
                try PreparedNodeCreation.prepareReplacing(Ctx, self.allocator, cache, &self.tags, elem_id, tag)
            else
                try PreparedNodeCreation.prepare(Ctx, self.allocator, cache, &self.tags, elem_id, tag);
            self.provisional_nodes.putAssumeCapacity(elem_id.raw(), {});
            self.creations.appendAssumeCapacity(prepared);
            const wire_elem_id = try render.WireElemId.fromEngine(elem_id);
            if (std.mem.eql(u8, prepared.tag, "text"))
                try self.wire.addSemantic(.{ .create_text = wire_elem_id })
            else
                try self.wire.addSemantic(.{ .create_element = .{ .elem_id = wire_elem_id, .tag = prepared.tag } });
        }

        /// Adds the engine-only render root for an initial surface. The host
        /// observes a reset command rather than a synthetic DOM creation for
        /// id zero, while cache and native-shadow publication still receive
        /// the same prepared root ownership.
        pub fn addHostRoot(self: *Self, cache: *Cache(Ctx)) (std.mem.Allocator.Error || error{ ActiveNode, DuplicateNode, ResourceLimit })!void {
            if (cache.hasRoot()) return error.ActiveNode;
            if (self.provisional_nodes.contains(0)) return error.DuplicateNode;
            const prepared = try PreparedNodeCreation.prepare(Ctx, self.allocator, cache, &self.tags, ids.ElemId.fromRaw(0), "root");
            self.provisional_nodes.putAssumeCapacity(0, {});
            self.creations.appendAssumeCapacity(prepared);
        }

        fn setParentIntent(self: *Self, cache: *const Cache(Ctx), child_id: u64, next: ?u64) error{ ConflictingParent, DuplicateChild, MissingNode, ResourceLimit }!void {
            if (!self.nodeExists(cache, ids.ElemId.fromRaw(child_id))) return error.MissingNode;
            const semantic_child_id = ids.ElemId.fromRaw(child_id);
            const semantic_next = ids.optionalElemFromRaw(next);
            if (self.parent_intent_indexes.get(child_id)) |intent_index| {
                const intent = &self.parent_intents.items[intent_index];
                if (semantic_next != null and intent.next != null) {
                    if (intent.next.? == semantic_next.?) return error.DuplicateChild;
                    return error.ConflictingParent;
                }
                if (semantic_next != null) intent.next = semantic_next;
                return;
            }
            const index = std.math.cast(usize, child_id) orelse return error.ResourceLimit;
            const retired = if (index < cache.nodes.items.len and cache.nodes.items[index].isActive()) cache.nodes.items[index].parent_id else null;
            const intent_index = self.parent_intents.items.len;
            self.parent_intents.appendAssumeCapacity(.{ .child_id = semantic_child_id, .next = semantic_next, .retired = retired });
            self.parent_intent_indexes.putAssumeCapacity(child_id, intent_index);
        }

        /// Adds one complete parent-child replacement and final parent intents.
        pub fn addChildren(self: *Self, cache: *const Cache(Ctx), parent_elem_id: ids.ElemId, next: []const ids.ElemId) (std.mem.Allocator.Error || error{ ConflictingParent, DuplicateChild, MissingNode, ResourceLimit })!void {
            if (!self.nodeExists(cache, parent_elem_id)) return error.MissingNode;
            const parent_index = parent_elem_id.index();
            const old_children: []const ids.ElemId = if (parent_index < cache.nodes.items.len and cache.nodes.items[parent_index].isActive())
                cache.nodes.items[parent_index].children.items
            else
                &.{};
            if (parent_index < cache.nodes.items.len and cache.nodes.items[parent_index].isActive()) {
                for (old_children) |child_id| try self.setParentIntent(cache, child_id.raw(), null);
            }
            for (next) |child_id| try self.setParentIntent(cache, child_id.raw(), parent_elem_id.raw());
            const copied = try self.allocator.dupe(ids.ElemId, next);
            self.children.appendAssumeCapacity(.{ .parent_elem_id = parent_elem_id, .next = copied });
            const parent_id = try render.WireElemId.fromEngine(parent_elem_id);
            var old_indexes = std.AutoHashMapUnmanaged(u64, usize).empty;
            defer old_indexes.deinit(self.allocator);
            try old_indexes.ensureTotalCapacity(self.allocator, std.math.cast(u32, old_children.len) orelse return error.ResourceLimit);
            for (old_children, 0..) |child_id, index| {
                const entry = old_indexes.getOrPutAssumeCapacity(child_id.raw());
                if (entry.found_existing) return error.DuplicateChild;
                entry.value_ptr.* = index;
            }
            const retained = try self.allocator.alloc(bool, next.len);
            defer self.allocator.free(retained);
            const stable = try self.allocator.alloc(bool, next.len);
            defer self.allocator.free(stable);
            const previous = try self.allocator.alloc(?usize, next.len);
            defer self.allocator.free(previous);
            const tails = try self.allocator.alloc(usize, next.len);
            defer self.allocator.free(tails);
            @memset(retained, false);
            @memset(stable, false);
            var tails_len: usize = 0;
            for (next, 0..) |child_id, index| if (old_indexes.get(child_id.raw())) |old_index| {
                retained[index] = true;
                var low: usize = 0;
                var high = tails_len;
                while (low < high) {
                    const middle = low + (high - low) / 2;
                    const middle_old = old_indexes.get(next[tails[middle]].raw()) orelse unreachable;
                    if (middle_old < old_index) low = middle + 1 else high = middle;
                }
                previous[index] = if (low == 0) null else tails[low - 1];
                tails[low] = index;
                if (low == tails_len) tails_len += 1;
            };
            var stable_index: ?usize = if (tails_len == 0) null else tails[tails_len - 1];
            while (stable_index) |index| {
                stable[index] = true;
                stable_index = previous[index];
            }
            for (next, retained) |child_id, is_retained| if (!is_retained) try self.wire.addSemantic(.{ .append_child = .{
                .parent = parent_id,
                .child = try render.WireElemId.fromEngine(child_id),
            } });
            var index = next.len;
            while (index != 0) {
                index -= 1;
                if (!retained[index] or stable[index]) continue;
                try self.wire.addSemantic(.{ .move_before = .{
                    .parent = parent_id,
                    .child = try render.WireElemId.fromEngine(next[index]),
                    .before = if (index + 1 == next.len) null else try render.WireElemId.fromEngine(next[index + 1]),
                } });
            }
        }

        /// Adds a text field for an active or provisional node.
        pub fn addTextField(self: *Self, cache: *const Cache(Ctx), elem_id: ids.ElemId, field: TextField, value: ?[]const u8) (std.mem.Allocator.Error || error{ MissingNode, ResourceLimit })!void {
            if (!self.nodeExists(cache, elem_id)) return error.MissingNode;
            if (self.reused_nodes.getPtr(elem_id.raw())) |fields| fields.text |= ReusedNodeFields.textBit(field);
            if (self.activeNode(cache, elem_id)) |node| {
                const old = @constCast(node).textSlot(field).*;
                if ((old == null and value == null) or (old != null and value != null and std.mem.eql(u8, old.?, value.?))) return;
            }
            const prepared = try PreparedTextFieldUpdate.prepareKnownNode(self.allocator, elem_id, field, value);
            self.text_fields.appendAssumeCapacity(prepared);
            const wire_elem_id = try render.WireElemId.fromEngine(elem_id);
            if (prepared.next) |bytes| {
                const attr_name: ?[]const u8 = switch (field) {
                    .role => "role",
                    .label => "aria-label",
                    .test_id => "data-testid",
                    .class => "class",
                    .text, .value => null,
                };
                if (attr_name) |name| try self.wire.addSetAttrText(wire_elem_id, name, bytes) else {
                    switch (field) {
                        .text => try self.wire.addSemantic(.{ .set_text = .{ .elem_id = wire_elem_id, .bytes = bytes } }),
                        .value => try self.wire.addSemantic(.{ .set_value = .{ .elem_id = wire_elem_id, .bytes = bytes } }),
                        else => unreachable,
                    }
                }
            } else {
                const attr_name: ?[]const u8 = switch (field) {
                    .role => "role",
                    .label => "aria-label",
                    .test_id => "data-testid",
                    .class => "class",
                    .text, .value => null,
                };
                if (attr_name) |name| try self.wire.addRemoveAttr(wire_elem_id, name) else {
                    switch (field) {
                        .text => try self.wire.addSemantic(.{ .set_text = .{ .elem_id = wire_elem_id, .bytes = "" } }),
                        .value => try self.wire.addSemantic(.{ .set_value = .{ .elem_id = wire_elem_id, .bytes = "" } }),
                        else => unreachable,
                    }
                }
            }
        }

        /// Adds a boolean field for an active or provisional node.
        pub fn addBoolField(self: *Self, cache: *const Cache(Ctx), elem_id: ids.ElemId, field: BoolField, value: ?bool) error{ MissingNode, ResourceLimit }!void {
            if (!self.nodeExists(cache, elem_id)) return error.MissingNode;
            if (self.reused_nodes.getPtr(elem_id.raw())) |fields| fields.bools |= ReusedNodeFields.boolBit(field);
            if (self.activeNode(cache, elem_id)) |node| if (@constCast(node).boolSlot(field).* == value) return;
            self.bool_fields.appendAssumeCapacity(.{ .elem_id = elem_id, .field = field, .next = value });
            const wire_elem_id = try render.WireElemId.fromEngine(elem_id);
            switch (field) {
                .checked => try self.wire.addSemantic(.{ .set_checked = .{ .elem_id = wire_elem_id, .value = value orelse false } }),
                .disabled => try self.wire.addSemantic(.{ .set_disabled = .{ .elem_id = wire_elem_id, .value = value orelse false } }),
            }
        }

        /// Adds a fixed event for an active or provisional node.
        pub fn addFixedEvent(self: *Self, cache: *const Cache(Ctx), elem_id: ids.ElemId, kind: EventKind, binding: ?EventBinding) error{ MissingNode, ResourceLimit }!void {
            if (!self.nodeExists(cache, elem_id)) return error.MissingNode;
            if (self.reused_nodes.getPtr(elem_id.raw())) |fields| fields.events |= ReusedNodeFields.eventBit(kind);
            const next = if (binding) |value| value.withDeliveryFor(.{ .fixed = kind }) else null;
            if (self.activeNode(cache, elem_id)) |node| {
                const old = eventBindingSlot(@constCast(&node.event_bindings), kind).*;
                if ((old == null and next == null) or (old != null and next != null and old.?.eql(next.?))) return;
            }
            self.fixed_events.appendAssumeCapacity(.{ .elem_id = elem_id, .kind = kind, .next = next });
            const wire_elem_id = try render.WireElemId.fromEngine(elem_id);
            if (next) |value| {
                if (value.canUseFixedOpcode(kind)) try self.wire.addSemantic(.{ .bind_fixed = .{ .elem_id = wire_elem_id, .event_id = try render.WireEventId.fromEngine(value.event_id), .kind = kind } }) else try self.wire.addBindEvent(.{
                    .elem_id = wire_elem_id,
                    .event_id = try render.WireEventId.fromEngine(value.event_id),
                    .name = kind.domEventName(),
                    .policy = value.policy,
                    .delivery = value.delivery.toWire(),
                    .payload_descriptor = value.payload_descriptor,
                });
            } else try self.wire.addSemantic(.{ .clear_fixed = .{ .elem_id = wire_elem_id, .kind = kind } });
        }

        /// Adds final custom attributes for an active or provisional node.
        pub fn addCustomAttrs(self: *Self, cache: *const Cache(Ctx), elem_id: ids.ElemId, attrs: []const CustomTextAttr) (std.mem.Allocator.Error || error{ MissingNode, ResourceLimit })!void {
            if (!self.nodeExists(cache, elem_id)) return error.MissingNode;
            const wire_elem_id = try render.WireElemId.fromEngine(elem_id);
            if (self.activeNode(cache, elem_id)) |node| {
                if (node.custom_text_attrs.items.len == attrs.len) {
                    var equal = true;
                    for (node.custom_text_attrs.items, attrs) |old, next| {
                        if (!std.mem.eql(u8, old.name, next.name) or !std.mem.eql(u8, old.value, next.value)) {
                            equal = false;
                            break;
                        }
                    }
                    if (equal) return;
                }
            }
            var prepared = try PreparedCustomTextAttrsReplacement.prepareKnownNode(self.allocator, elem_id, attrs);
            errdefer prepared.deinit(self.allocator);
            const cache_index = elem_id.index();
            if (cache_index < cache.nodes.items.len and cache.nodes.items[cache_index].isActive()) {
                for (cache.nodes.items[cache_index].custom_text_attrs.items) |old| {
                    var found = false;
                    for (prepared.next) |next| if (std.mem.eql(u8, old.name, next.name)) {
                        found = true;
                        break;
                    };
                    if (!found) try self.wire.addRemoveAttr(wire_elem_id, old.name);
                }
            }
            for (prepared.next) |next| {
                var unchanged = false;
                if (cache_index < cache.nodes.items.len and cache.nodes.items[cache_index].isActive()) {
                    if (cache.nodes.items[cache_index].customTextAttrIndex(next.name)) |old_index| {
                        unchanged = std.mem.eql(u8, cache.nodes.items[cache_index].custom_text_attrs.items[old_index].value, next.value);
                    }
                }
                if (!unchanged) try self.wire.addSetAttrText(wire_elem_id, next.name, next.value);
            }
            self.custom_attrs.appendAssumeCapacity(prepared);
        }

        /// Adds final named events for an active or provisional node.
        pub fn addNamedEvents(self: *Self, cache: *const Cache(Ctx), elem_id: ids.ElemId, events: []const NamedEvent) (std.mem.Allocator.Error || error{ MissingNode, ResourceLimit })!void {
            if (!self.nodeExists(cache, elem_id)) return error.MissingNode;
            const wire_elem_id = try render.WireElemId.fromEngine(elem_id);
            if (self.activeNode(cache, elem_id)) |node| {
                if (node.named_events.items.len == events.len) {
                    var equal = true;
                    for (node.named_events.items, events) |old, next| {
                        if (!std.mem.eql(u8, old.name, next.name) or !old.binding.eql(next.binding)) {
                            equal = false;
                            break;
                        }
                    }
                    if (equal) return;
                }
            }
            var prepared = try PreparedNamedEventsReplacement.prepareKnownNode(self.allocator, elem_id, events);
            errdefer prepared.deinit(self.allocator);
            const cache_index = elem_id.index();
            if (cache_index < cache.nodes.items.len and cache.nodes.items[cache_index].isActive()) {
                for (cache.nodes.items[cache_index].named_events.items) |old| {
                    var found = false;
                    for (prepared.next) |next| if (std.mem.eql(u8, old.name, next.name)) {
                        found = true;
                        break;
                    };
                    if (!found) try self.wire.addClearEvent(wire_elem_id, old.name);
                }
            }
            for (prepared.next) |next| {
                var unchanged = false;
                if (cache_index < cache.nodes.items.len and cache.nodes.items[cache_index].isActive()) {
                    if (cache.nodes.items[cache_index].namedEventIndex(next.name)) |old_index| unchanged = cache.nodes.items[cache_index].named_events.items[old_index].binding.eql(next.binding);
                }
                if (!unchanged) try self.wire.addBindEvent(.{
                    .elem_id = wire_elem_id,
                    .event_id = try render.WireEventId.fromEngine(next.binding.event_id),
                    .name = next.name,
                    .policy = next.binding.policy,
                    .delivery = next.binding.delivery.toWire(),
                    .payload_descriptor = next.binding.payload_descriptor,
                });
            }
            self.named_events.appendAssumeCapacity(prepared);
        }

        /// Publishes every prepared cache delta without allocation.
        pub fn apply(self: *Self, cache: *Cache(Ctx)) void {
            if (self.phase.isApplied()) @panic("prepared render splice committed twice");
            self.tags.apply(Ctx, cache);
            for (self.removals.items) |*value| value.apply(Ctx, cache);
            for (self.creations.items) |*value| value.apply(Ctx, cache);
            for (self.children.items) |*value| value.apply(Ctx, cache);
            for (self.parent_intents.items) |intent| cache.nodes.items[intent.child_id.index()].parent_id = intent.next;
            for (self.text_fields.items) |*value| value.apply(Ctx, cache);
            for (self.bool_fields.items) |*value| value.apply(Ctx, cache);
            for (self.fixed_events.items) |*value| value.apply(Ctx, cache);
            for (self.custom_attrs.items) |*value| value.apply(Ctx, cache);
            for (self.named_events.items) |*value| value.apply(Ctx, cache);
            self.phase = .applied;
        }

        /// Releases provisional deltas on abort or retired cache ownership after commit.
        pub fn deinit(self: *Self) void {
            var index = self.named_events.items.len;
            while (index != 0) {
                index -= 1;
                self.named_events.items[index].deinit(self.allocator);
            }
            index = self.custom_attrs.items.len;
            while (index != 0) {
                index -= 1;
                self.custom_attrs.items[index].deinit(self.allocator);
            }
            index = self.text_fields.items.len;
            while (index != 0) {
                index -= 1;
                self.text_fields.items[index].deinit(self.allocator);
            }
            index = self.children.items.len;
            while (index != 0) {
                index -= 1;
                self.children.items[index].deinit(self.allocator);
            }
            index = self.creations.items.len;
            while (index != 0) {
                index -= 1;
                self.creations.items[index].deinit();
            }
            index = self.removals.items.len;
            while (index != 0) {
                index -= 1;
                self.removals.items[index].deinit(self.allocator);
            }
            self.named_events.deinit(self.allocator);
            self.custom_attrs.deinit(self.allocator);
            self.fixed_events.deinit(self.allocator);
            self.bool_fields.deinit(self.allocator);
            self.text_fields.deinit(self.allocator);
            self.children.deinit(self.allocator);
            self.creations.deinit(self.allocator);
            self.removals.deinit(self.allocator);
            self.parent_intents.deinit(self.allocator);
            self.parent_intent_indexes.deinit(self.allocator);
            self.provisional_nodes.deinit(self.allocator);
            self.reused_nodes.deinit(self.allocator);
            self.tags.deinit(self.allocator);
            self.wire.deinit(self.allocator);
            self.* = undefined;
        }
    };
}

/// Defines the engine-owned rendered-state cache used to emit only changed host commands.
pub fn Cache(comptime Ctx: type) type {
    return struct {
        const Self = @This();

        nodes: std.ArrayListUnmanaged(ScalarNode) = .empty,
        interned_tags: std.StringHashMapUnmanaged([]const u8) = .empty,
        move_child_indexes: std.AutoHashMapUnmanaged(u64, usize) = .empty,
        move_old_indexes: std.ArrayListUnmanaged(usize) = .empty,
        move_stable_subsequence: std.ArrayListUnmanaged(usize) = .empty,

        /// Releases every resource owned by this value and leaves no retained host or Roc ownership behind.
        pub fn deinit(self: *Self, ctx: Ctx.Handle) void {
            const allocator = Ctx.allocator(ctx);
            for (self.nodes.items) |*node| {
                node.deinit(allocator);
            }
            self.nodes.deinit(allocator);
            var interned_tags = self.interned_tags.valueIterator();
            while (interned_tags.next()) |tag| allocator.free(tag.*);
            self.interned_tags.deinit(allocator);
            self.move_child_indexes.deinit(allocator);
            self.move_old_indexes.deinit(allocator);
            self.move_stable_subsequence.deinit(allocator);
            self.* = .{};
        }

        /// Reports whether root is present in maintained state.
        pub fn hasRoot(self: *const Self) bool {
            return self.nodes.items.len != 0 and self.nodes.items[0].isActive();
        }

        /// Reserves the node table without changing its logical contents.
        pub fn preflightNodeCapacity(self: *Self, allocator: std.mem.Allocator, capacity: usize) std.mem.Allocator.Error!void {
            try self.nodes.ensureTotalCapacity(allocator, capacity);
        }

        /// Reserves one active parent's final child-list capacity without changing its contents.
        pub fn preflightChildCapacity(self: *Self, allocator: std.mem.Allocator, parent_elem_id: ids.ElemId, capacity: usize) (std.mem.Allocator.Error || error{MissingParent})!void {
            const index = parent_elem_id.index();
            if (index >= self.nodes.items.len or !self.nodes.items[index].isActive()) return error.MissingParent;
            try self.nodes.items[index].children.ensureTotalCapacity(allocator, capacity);
        }

        /// Ensures node capacity or traps at the legacy infallible boundary.
        pub fn ensureNodeCapacity(self: *Self, ctx: Ctx.Handle, capacity: usize) void {
            self.preflightNodeCapacity(Ctx.allocator(ctx), capacity) catch @panic("out of memory");
        }

        /// Reports whether active node is present in maintained state.
        pub fn hasActiveNode(self: *const Self, elem_id: ids.ElemId) bool {
            const index = elem_id.index();
            return index < self.nodes.items.len and self.nodes.items[index].isActive();
        }

        /// Returns active node tag differs from the maintained active-runtime indexes.
        pub fn activeNodeTagDiffers(self: *const Self, elem_id: ids.ElemId, tag: []const u8) bool {
            const index = elem_id.index();
            if (index >= self.nodes.items.len) return false;
            const node = &self.nodes.items[index];
            const active_tag = node.activeTag() orelse return false;
            return !std.mem.eql(u8, active_tag, tag);
        }

        /// Stages a complete render-surface reset in the host command sink.
        pub fn reset(self: *Self, ctx: Ctx.Handle) void {
            const allocator = Ctx.allocator(ctx);
            for (self.nodes.items) |*node| {
                node.deinit(allocator);
            }
            self.nodes.items.len = 0;
            self.nodes.append(allocator, ScalarNode.initActive(self.internTag(allocator, "root"))) catch @panic("out of memory");
            Ctx.sink(ctx).reset();
        }

        fn internTag(self: *Self, allocator: std.mem.Allocator, tag: []const u8) []const u8 {
            if (self.interned_tags.get(tag)) |interned| return interned;
            const owned = allocator.dupe(u8, tag) catch @panic("out of memory");
            self.interned_tags.put(allocator, owned, owned) catch {
                allocator.free(owned);
                @panic("out of memory");
            };
            return owned;
        }

        fn ensureCacheNode(self: *Self, ctx: Ctx.Handle, elem_id: ids.ElemId, tag: []const u8) bool {
            const allocator = Ctx.allocator(ctx);
            const index = elem_id.index();
            while (index > self.nodes.items.len) {
                self.nodes.append(allocator, .{}) catch @panic("out of memory");
            }
            if (index == self.nodes.items.len) {
                self.nodes.append(allocator, ScalarNode.initActive(self.internTag(allocator, tag))) catch @panic("out of memory");
                return true;
            }
            const node = &self.nodes.items[index];
            if (!node.isActive()) {
                node.* = ScalarNode.initActive(self.internTag(allocator, tag));
                return true;
            }
            const active_tag = node.activeTag().?;
            if (!std.mem.eql(u8, active_tag, tag)) {
                var message: [160]u8 = undefined;
                const rendered = std.fmt.bufPrint(
                    &message,
                    "render descriptor changed tag for elem {d}: cache '{s}', stream '{s}'",
                    .{ elem_id, active_tag, tag },
                ) catch "render descriptor changed the tag for an existing render cache identity";
                @panic(rendered);
            }
            return false;
        }

        /// Emits the already-decided command that attaches a newly created render node.
        pub fn appendNode(self: *Self, ctx: Ctx.Handle, elem_id: ids.ElemId, parent_elem_id: ids.ElemId, tag: []const u8) void {
            const created = self.ensureCacheNode(ctx, elem_id, tag);
            if (!created) @panic("initial render append reused an existing render cache identity");
            const parent = self.activeNode(parent_elem_id);
            const child = self.activeNode(elem_id);
            child.parent_id = parent_elem_id;
            parent.children.append(Ctx.allocator(ctx), elem_id) catch @panic("out of memory");
            Ctx.sink(ctx).appendNode(elem_id, parent_elem_id, tag);
        }

        /// Ensures the host render surface contains the engine-selected node and tag.
        pub fn ensureNode(self: *Self, ctx: Ctx.Handle, elem_id: ids.ElemId, tag: []const u8, counts: *render.Counts) void {
            if (!self.ensureCacheNode(ctx, elem_id, tag)) return;
            Ctx.sink(ctx).ensureNode(elem_id, tag);
            counts.addCreateElement();
        }

        /// Emits removal of a node whose owning scope has already been disposed by the engine.
        pub fn removeNode(self: *Self, ctx: Ctx.Handle, elem_id: ids.ElemId, counts: *render.Counts) void {
            const allocator = Ctx.allocator(ctx);
            const index = elem_id.index();
            if (index >= self.nodes.items.len or !self.nodes.items[index].isActive()) {
                @panic("render cache removed a missing element");
            }
            if (elem_id == ids.root_elem) @panic("render cache attempted to remove the host DOM root");

            if (self.nodes.items[index].parent_id) |parent_id| {
                const parent_index = parent_id.index();
                if (parent_index < self.nodes.items.len and self.nodes.items[parent_index].isActive()) {
                    const parent = &self.nodes.items[parent_index];
                    if (elemSliceIndex(parent.children.items, elem_id)) |child_index| {
                        _ = parent.children.orderedRemove(child_index);
                    }
                }
            }
            Ctx.sink(ctx).removeNode(elem_id);
            self.deactivateSubtree(allocator, elem_id);
            counts.addRemoveNode();
        }

        fn deactivateSubtree(self: *Self, allocator: std.mem.Allocator, elem_id: ids.ElemId) void {
            const index = elem_id.index();
            if (index >= self.nodes.items.len or !self.nodes.items[index].isActive()) return;

            const child_ids = allocator.dupe(ids.ElemId, self.nodes.items[index].children.items) catch @panic("out of memory");
            defer allocator.free(child_ids);
            for (child_ids) |child_id| {
                self.deactivateSubtree(allocator, child_id);
            }
            self.nodes.items[index].deinit(allocator);
        }

        /// Returns active node from the maintained active-runtime indexes.
        pub fn activeNode(self: *Self, elem_id: ids.ElemId) *ScalarNode {
            const index = elem_id.index();
            if (index >= self.nodes.items.len or !self.nodes.items[index].isActive()) {
                @panic("render command referenced missing element cache");
            }
            return &self.nodes.items[index];
        }

        /// Returns the owned name for an indexed named-event cache entry.
        pub fn namedEventNameAt(self: *Self, elem_id: ids.ElemId, index: usize) ?[]const u8 {
            const events = self.activeNode(elem_id).named_events.items;
            if (index >= events.len) return null;
            return events[index].name;
        }

        /// Returns the owned name for an indexed custom-attribute cache entry.
        pub fn customTextAttrNameAt(self: *Self, elem_id: ids.ElemId, index: usize) ?[]const u8 {
            const attrs = self.activeNode(elem_id).custom_text_attrs.items;
            if (index >= attrs.len) return null;
            return attrs[index].name;
        }

        /// Publishes the engine-selected child order for one parent.
        pub fn replaceChildren(self: *Self, ctx: Ctx.Handle, parent_elem_id: ids.ElemId, next_child_ids: []const ids.ElemId, counts: *render.Counts) void {
            const allocator = Ctx.allocator(ctx);
            const parent = self.activeNode(parent_elem_id);

            for (next_child_ids, 0..) |child_id, new_index| {
                const child = self.activeNode(child_id);
                const old_parent_id = child.parent_id;
                const semantic_child_id = child_id;
                const semantic_parent_id = parent_elem_id;
                const old_child_index = if (old_parent_id) |id| elemSliceIndex(self.activeNode(id).children.items, semantic_child_id) else null;

                if (old_parent_id == null or old_parent_id.? != semantic_parent_id or old_child_index == null) {
                    counts.addAppendChild();
                } else if (old_child_index.? != new_index) {
                    counts.addMoveBefore();
                }
                child.parent_id = semantic_parent_id;
            }

            parent.children.deinit(allocator);
            parent.children = .empty;
            parent.children.appendSlice(allocator, next_child_ids) catch @panic("out of memory");
            Ctx.sink(ctx).replaceChildren(parent_elem_id, next_child_ids);
        }

        /// Publishes a moves-only child reorder without rebuilding surviving row structure.
        pub fn replaceChildrenForMoves(self: *Self, ctx: Ctx.Handle, parent_elem_id: ids.ElemId, next_child_ids: []const ids.ElemId, counts: *render.Counts) void {
            const allocator = Ctx.allocator(ctx);
            const parent = self.activeNode(parent_elem_id);
            if (parent.children.items.len != next_child_ids.len) @panic("pure structural move changed child count");

            const old_child_indexes = &self.move_child_indexes;
            old_child_indexes.clearRetainingCapacity();
            defer old_child_indexes.clearRetainingCapacity();
            for (parent.children.items, 0..) |child_id, index| {
                const entry = old_child_indexes.getOrPut(allocator, child_id.raw()) catch @panic("out of memory");
                if (entry.found_existing) @panic("parent child list contained duplicate element ids");
                entry.value_ptr.* = index;
            }

            self.move_old_indexes.resize(allocator, next_child_ids.len) catch @panic("out of memory");
            defer self.move_old_indexes.clearRetainingCapacity();
            const old_indexes_in_next_order = self.move_old_indexes.items;
            for (next_child_ids, 0..) |child_id, index| {
                const child = self.activeNode(child_id);
                if (child.parent_id == null or child.parent_id.? != parent_elem_id) @panic("pure structural move crossed parent boundary");
                old_indexes_in_next_order[index] = old_child_indexes.get(child_id.raw()) orelse @panic("pure structural move inserted a child");
            }

            self.move_stable_subsequence.resize(allocator, next_child_ids.len) catch @panic("out of memory");
            defer self.move_stable_subsequence.clearRetainingCapacity();
            const stable_scratch = self.move_stable_subsequence.items;
            const stable_len = stableSubsequenceLength(old_indexes_in_next_order, stable_scratch);
            const displaced_count = next_child_ids.len - stable_len;
            var displaced_index: usize = 0;
            while (displaced_index < displaced_count) : (displaced_index += 1) {
                counts.addMoveBefore();
            }

            for (next_child_ids) |child_id| {
                self.activeNode(child_id).parent_id = parent_elem_id;
            }
            parent.children.deinit(allocator);
            parent.children = .empty;
            parent.children.appendSlice(allocator, next_child_ids) catch @panic("out of memory");
            Ctx.sink(ctx).replaceChildrenForMoves(parent_elem_id, next_child_ids);
        }

        /// Applies event binding after preparation has fixed semantics and reserved fallible growth.
        pub fn applyEventBinding(self: *Self, ctx: Ctx.Handle, elem_id: ids.ElemId, kind: EventKind, binding: ?EventBinding, counts: *render.Counts) void {
            const node = self.activeNode(elem_id);
            const slot = node.fixedEventBindingSlot(kind);
            if (binding) |raw_next| {
                const next = raw_next.withDeliveryFor(.{ .fixed = kind });
                if (!next.policy.isNone()) @panic("fixed event binding carried listener policy");
                if (slot.*) |existing| {
                    if (existing.eql(next)) return;
                }

                slot.* = next;
                Ctx.sink(ctx).bindEvent(elem_id, .{ .fixed = kind }, next);
                counts.addEventBinding();
                return;
            }

            if (slot.* == null) return;
            slot.* = null;
            Ctx.sink(ctx).clearEvent(elem_id, .{ .fixed = kind });
            counts.addEventBinding();
        }

        /// Applies named event binding after preparation has fixed semantics and reserved fallible growth.
        pub fn applyNamedEventBinding(self: *Self, ctx: Ctx.Handle, elem_id: ids.ElemId, name: []const u8, binding: ?EventBinding, counts: *render.Counts) void {
            const allocator = Ctx.allocator(ctx);
            const node = self.activeNode(elem_id);
            const existing_index = node.namedEventIndex(name);

            if (binding) |raw_next| {
                const next = raw_next.withDeliveryFor(.{ .named = name });
                if (existing_index) |index| {
                    const existing = &node.named_events.items[index];
                    if (existing.binding.eql(next)) return;

                    existing.binding = next;
                } else {
                    const name_copy = allocator.dupe(u8, name) catch @panic("out of memory");
                    node.named_events.append(allocator, .{
                        .name = name_copy,
                        .binding = next,
                    }) catch {
                        allocator.free(name_copy);
                        @panic("out of memory");
                    };
                }

                Ctx.sink(ctx).bindEvent(elem_id, .{ .named = name }, next);
                counts.addEventBinding();
                return;
            }

            const index = existing_index orelse return;
            const removed = node.named_events.orderedRemove(index);
            Ctx.sink(ctx).clearEvent(elem_id, .{ .named = removed.name });
            removed.deinit(allocator);
            counts.addEventBinding();
        }

        /// Asserts that committed render-cache state matches the host sink after publication.
        pub fn debugAssertMatchesSink(self: *Self, ctx: Ctx.Handle) void {
            if (comptime builtin.mode != .Debug) return;

            for (self.nodes.items, 0..) |cached, index| {
                Ctx.sink(ctx).debugAssertNode(
                    ids.ElemId.fromIndex(index),
                    cached.isActive(),
                    cached.activeTag(),
                    cached.parent_id,
                    cached.children.items,
                    ids.optionalEventFromRaw(cached.fixedEventId(.click)),
                    ids.optionalEventFromRaw(cached.fixedEventId(.input)),
                    ids.optionalEventFromRaw(cached.fixedEventId(.check)),
                    ids.optionalEventFromRaw(cached.fixedEventId(.pointer_down)),
                    ids.optionalEventFromRaw(cached.fixedEventId(.pointer_up)),
                    ids.optionalEventFromRaw(cached.fixedEventId(.pointer_enter)),
                    ids.optionalEventFromRaw(cached.fixedEventId(.pointer_leave)),
                );
            }
        }

        /// Applies an engine-decided text field value to one render node.
        pub fn applyTextField(self: *Self, ctx: Ctx.Handle, elem_id: ids.ElemId, field: TextField, value: []const u8) bool {
            const allocator = Ctx.allocator(ctx);
            const slot = self.activeNode(elem_id).textSlot(field);
            if (slot.*) |existing| {
                if (std.mem.eql(u8, existing, value)) return false;
            }

            const value_copy = allocator.dupe(u8, value) catch @panic("out of memory");
            if (slot.*) |existing| allocator.free(existing);
            slot.* = value_copy;
            Ctx.sink(ctx).applyTextField(elem_id, field, value);
            return true;
        }

        /// Applies an engine-decided custom text attribute to one render node.
        pub fn applyTextAttr(self: *Self, ctx: Ctx.Handle, elem_id: ids.ElemId, name: []const u8, value: []const u8) bool {
            const allocator = Ctx.allocator(ctx);
            const node = self.activeNode(elem_id);
            if (node.customTextAttrIndex(name)) |index| {
                const attr = &node.custom_text_attrs.items[index];
                if (std.mem.eql(u8, attr.value, value)) return false;

                const value_copy = allocator.dupe(u8, value) catch @panic("out of memory");
                allocator.free(attr.value);
                attr.value = value_copy;
                Ctx.sink(ctx).applyTextAttr(elem_id, name, value);
                return true;
            }

            const name_copy = allocator.dupe(u8, name) catch @panic("out of memory");
            const value_copy = allocator.dupe(u8, value) catch {
                allocator.free(name_copy);
                @panic("out of memory");
            };
            node.custom_text_attrs.append(allocator, .{
                .name = name_copy,
                .value = value_copy,
            }) catch {
                allocator.free(name_copy);
                allocator.free(value_copy);
                @panic("out of memory");
            };
            Ctx.sink(ctx).applyTextAttr(elem_id, name, value);
            return true;
        }

        /// Applies an engine-decided boolean field value to one render node.
        pub fn applyBoolField(self: *Self, ctx: Ctx.Handle, elem_id: ids.ElemId, field: BoolField, value: bool) bool {
            const slot = self.activeNode(elem_id).boolSlot(field);
            if (slot.*) |existing| {
                if (existing == value) return false;
            }

            slot.* = value;
            Ctx.sink(ctx).applyBoolField(elem_id, field, value);
            return true;
        }

        /// Clears an engine-decided text field from one render node.
        pub fn clearTextField(self: *Self, ctx: Ctx.Handle, elem_id: ids.ElemId, field: TextField) bool {
            const allocator = Ctx.allocator(ctx);
            const slot = self.activeNode(elem_id).textSlot(field);
            const existing = slot.* orelse return false;
            allocator.free(existing);
            slot.* = null;
            Ctx.sink(ctx).clearTextField(elem_id, field);
            return true;
        }

        /// Clears an engine-decided custom text attribute from one render node.
        pub fn clearTextAttr(self: *Self, ctx: Ctx.Handle, elem_id: ids.ElemId, name: []const u8) bool {
            const allocator = Ctx.allocator(ctx);
            const node = self.activeNode(elem_id);
            const index = node.customTextAttrIndex(name) orelse return false;
            const removed = node.custom_text_attrs.orderedRemove(index);
            Ctx.sink(ctx).clearTextAttr(elem_id, removed.name);
            removed.deinit(allocator);
            return true;
        }

        /// Clears an engine-decided boolean field from one render node.
        pub fn clearBoolField(self: *Self, ctx: Ctx.Handle, elem_id: ids.ElemId, field: BoolField) bool {
            const slot = self.activeNode(elem_id).boolSlot(field);
            const existing = slot.* orelse return false;
            slot.* = null;
            if (!existing) return false;
            Ctx.sink(ctx).clearBoolField(elem_id, field);
            return true;
        }
    };
}

const TestHost = struct {
    apply_text_field_count: u64 = 0,
    apply_text_attr_count: u64 = 0,
    clear_text_attr_count: u64 = 0,
    bind_event_count: u64 = 0,
    clear_event_count: u64 = 0,
    bind_named_event_count: u64 = 0,
    clear_named_event_count: u64 = 0,
    last_event_binding: ?EventBinding = null,
};

const TestCtx = struct {
    pub const Handle = *TestHost;
    pub const Sink = TestSink;

    /// Returns the allocator owned by this host context for shared-engine work.
    pub fn allocator(_: Handle) std.mem.Allocator {
        return std.testing.allocator;
    }

    /// Returns the thin render-command sink used by the shared engine.
    pub fn sink(host: Handle) Sink {
        return .{ .host = host };
    }
};

const TestSink = struct {
    host: *TestHost,

    /// Stages a complete render-surface reset in the host command sink.
    pub fn reset(_: TestSink) void {}
    /// Emits the already-decided command that attaches a newly created render node.
    pub fn appendNode(_: TestSink, _: ids.ElemId, _: ids.ElemId, _: []const u8) void {}
    /// Ensures the host render surface contains the engine-selected node and tag.
    pub fn ensureNode(_: TestSink, _: ids.ElemId, _: []const u8) void {}
    /// Emits removal of a node whose owning scope has already been disposed by the engine.
    pub fn removeNode(_: TestSink, _: ids.ElemId) void {}
    /// Publishes the engine-selected child order for one parent.
    pub fn replaceChildren(_: TestSink, _: ids.ElemId, _: []const ids.ElemId) void {}
    /// Publishes a moves-only child reorder without rebuilding surviving row structure.
    pub fn replaceChildrenForMoves(_: TestSink, _: ids.ElemId, _: []const ids.ElemId) void {}
    /// Applies an engine-decided text field value to one render node.
    pub fn applyTextField(self: TestSink, _: ids.ElemId, _: TextField, _: []const u8) void {
        self.host.apply_text_field_count += 1;
    }
    /// Applies an engine-decided custom text attribute to one render node.
    pub fn applyTextAttr(self: TestSink, _: ids.ElemId, _: []const u8, _: []const u8) void {
        self.host.apply_text_attr_count += 1;
    }
    /// Applies an engine-decided boolean field value to one render node.
    pub fn applyBoolField(_: TestSink, _: ids.ElemId, _: BoolField, _: bool) void {}
    /// Clears an engine-decided text field from one render node.
    pub fn clearTextField(_: TestSink, _: ids.ElemId, _: TextField) void {}
    /// Clears an engine-decided custom text attribute from one render node.
    pub fn clearTextAttr(self: TestSink, _: ids.ElemId, _: []const u8) void {
        self.host.clear_text_attr_count += 1;
    }
    /// Clears an engine-decided boolean field from one render node.
    pub fn clearBoolField(_: TestSink, _: ids.ElemId, _: BoolField) void {}
    /// Publishes a validated canonical event binding selected by the engine.
    pub fn bindEvent(self: TestSink, _: ids.ElemId, key: EventBindingKey, binding: EventBinding) void {
        self.host.last_event_binding = binding;
        switch (key) {
            .fixed => self.host.bind_event_count += 1,
            .named => self.host.bind_named_event_count += 1,
        }
    }
    /// Removes a host event registration whose engine-owned binding is no longer active.
    pub fn clearEvent(self: TestSink, _: ids.ElemId, key: EventBindingKey) void {
        switch (key) {
            .fixed => self.host.clear_event_count += 1,
            .named => self.host.clear_named_event_count += 1,
        }
    }
    /// Checks that the host render surface matches the engine's committed node metadata.
    pub fn debugAssertNode(_: TestSink, _: ids.ElemId, _: bool, _: ?[]const u8, _: ?ids.ElemId, _: []const ids.ElemId, _: ?ids.EventId, _: ?ids.EventId, _: ?ids.EventId, _: ?ids.EventId, _: ?ids.EventId, _: ?ids.EventId, _: ?ids.EventId) void {}
};

test "applying unchanged text field emits no duplicate command" {
    var host = TestHost{};
    var cache: Cache(TestCtx) = .{};
    defer cache.deinit(&host);

    cache.reset(&host);
    var counts: render.Counts = .{};
    cache.ensureNode(&host, ids.ElemId.fromRaw(1), "div", &counts);

    try std.testing.expect(cache.applyTextField(&host, ids.ElemId.fromRaw(1), .text, "hello"));
    try std.testing.expect(!cache.applyTextField(&host, ids.ElemId.fromRaw(1), .text, "hello"));
    try std.testing.expectEqual(@as(u64, 1), host.apply_text_field_count);
}

test "render cache capacity preflight is recoverable and logically inert" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var fault = FaultAllocator.init(std.testing.allocator);
    const allocator = fault.allocator();
    var cache: Cache(TestCtx) = .{};
    defer {
        cache.nodes.items[0].children.deinit(allocator);
        cache.nodes.deinit(allocator);
    }
    try cache.nodes.append(allocator, ScalarNode.initActive("root"));

    fault.configure(1);
    try std.testing.expectError(error.OutOfMemory, cache.preflightNodeCapacity(allocator, 32));
    try std.testing.expectEqual(@as(usize, 1), cache.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 0), cache.nodes.items[0].children.items.len);

    fault.configure(null);
    try cache.preflightNodeCapacity(allocator, 32);
    fault.configure(1);
    try std.testing.expectError(error.OutOfMemory, cache.preflightChildCapacity(allocator, ids.ElemId.fromRaw(0), 16));
    try std.testing.expectEqual(@as(usize, 1), cache.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 0), cache.nodes.items[0].children.items.len);

    fault.configure(null);
    try cache.preflightChildCapacity(allocator, ids.root_elem, 16);
    fault.configure(1);
    cache.nodes.items[0].children.appendAssumeCapacity(ids.ElemId.fromRaw(7));
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqualSlices(ids.ElemId, &.{ids.ElemId.fromRaw(7)}, cache.nodes.items[0].children.items);
    fault.configure(null);
}

test "prepared child replacement aborts cleanly and commits allocation free" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var fault = FaultAllocator.init(std.testing.allocator);
    const allocator = fault.allocator();
    var cache: Cache(TestCtx) = .{};
    defer {
        cache.nodes.items[0].children.deinit(allocator);
        cache.nodes.deinit(allocator);
    }
    try cache.nodes.append(allocator, ScalarNode.initActive("root"));
    try cache.nodes.items[0].children.appendSlice(allocator, &.{ ids.ElemId.fromRaw(1), ids.ElemId.fromRaw(2) });

    fault.configure(1);
    try std.testing.expectError(error.OutOfMemory, PreparedChildrenReplacement.prepare(TestCtx, allocator, &cache, ids.ElemId.fromRaw(0), &.{ ids.ElemId.fromRaw(2), ids.ElemId.fromRaw(3) }));
    try std.testing.expectEqualSlices(ids.ElemId, &.{ ids.ElemId.fromRaw(1), ids.ElemId.fromRaw(2) }, cache.nodes.items[0].children.items);

    fault.configure(null);
    var aborted = try PreparedChildrenReplacement.prepare(TestCtx, allocator, &cache, ids.root_elem, &.{ ids.ElemId.fromRaw(2), ids.ElemId.fromRaw(3) });
    aborted.deinit(allocator);
    try std.testing.expectEqualSlices(ids.ElemId, &.{ ids.ElemId.fromRaw(1), ids.ElemId.fromRaw(2) }, cache.nodes.items[0].children.items);

    var committed = try PreparedChildrenReplacement.prepare(TestCtx, allocator, &cache, ids.root_elem, &.{ ids.ElemId.fromRaw(2), ids.ElemId.fromRaw(3) });
    fault.configure(1);
    committed.apply(TestCtx, &cache);
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqualSlices(ids.ElemId, &.{ ids.ElemId.fromRaw(2), ids.ElemId.fromRaw(3) }, cache.nodes.items[0].children.items);
    try std.testing.expectEqualSlices(ids.ElemId, &.{ ids.ElemId.fromRaw(1), ids.ElemId.fromRaw(2) }, committed.retired.items);
    fault.configure(null);
    committed.deinit(allocator);
}

test "prepared render node removal defers ownership and applies allocation free" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var fault = FaultAllocator.init(std.testing.allocator);
    const allocator = fault.allocator();
    var cache: Cache(TestCtx) = .{};
    defer {
        for (cache.nodes.items) |*node| node.deinit(allocator);
        cache.nodes.deinit(allocator);
    }
    try cache.nodes.append(allocator, ScalarNode.initActive("root"));
    var child = ScalarNode.initActive("div");
    child.parent_id = ids.ElemId.fromRaw(0);
    child.text = try allocator.dupe(u8, "owned");
    try cache.nodes.append(allocator, child);

    var aborted = try PreparedNodeRemoval.prepare(TestCtx, &cache, ids.ElemId.fromRaw(1));
    aborted.deinit(allocator);
    try std.testing.expect(cache.nodes.items[1].isActive());
    try std.testing.expectEqualStrings("owned", cache.nodes.items[1].text.?);

    var committed = try PreparedNodeRemoval.prepare(TestCtx, &cache, ids.ElemId.fromRaw(1));
    fault.configure(1);
    committed.apply(TestCtx, &cache);
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expect(!cache.nodes.items[1].isActive());
    try std.testing.expectEqualStrings("owned", committed.retired.text.?);
    fault.configure(null);
    committed.deinit(allocator);
}

test "prepared render node creation sweeps allocation failures and retries" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    const Runner = struct {
        fn deinit(cache: *Cache(TestCtx), allocator: std.mem.Allocator) void {
            for (cache.nodes.items) |*node| node.deinit(allocator);
            cache.nodes.deinit(allocator);
            var tags = cache.interned_tags.valueIterator();
            while (tags.next()) |tag| allocator.free(tag.*);
            cache.interned_tags.deinit(allocator);
        }

        fn run(failure_number: ?usize) !usize {
            var fault = FaultAllocator.init(std.testing.allocator);
            const allocator = fault.allocator();
            var cache: Cache(TestCtx) = .{};
            defer deinit(&cache, allocator);
            fault.configure(failure_number);
            var overlay: ?PreparedTagOverlay = null;
            defer if (overlay) |*tags| tags.deinit(allocator);
            const reserved = cache.preflightNodeCapacity(allocator, 5);
            if (reserved) |_| {
                overlay = PreparedTagOverlay.init(TestCtx, allocator, &cache, 2) catch null;
                if (overlay) |*tags| {
                    const first = PreparedNodeCreation.prepare(TestCtx, allocator, &cache, tags, ids.ElemId.fromRaw(2), "section") catch null;
                    const second = if (first != null) PreparedNodeCreation.prepare(TestCtx, allocator, &cache, tags, ids.ElemId.fromRaw(3), "article") catch null else null;
                    const duplicate = if (second != null) PreparedNodeCreation.prepare(TestCtx, allocator, &cache, tags, ids.ElemId.fromRaw(4), "section") catch null else null;
                    if (first != null and second != null and duplicate != null) {
                        if (failure_number != null) return error.TestUnexpectedResult;
                        var nodes = [_]PreparedNodeCreation{ first.?, second.?, duplicate.? };
                        const attempts = fault.attempts;
                        fault.configure(1);
                        tags.apply(TestCtx, &cache);
                        for (&nodes) |*node| node.apply(TestCtx, &cache);
                        try std.testing.expectEqual(@as(usize, 0), fault.attempts);
                        try std.testing.expectEqual(@as(usize, 2), cache.interned_tags.count());
                        try std.testing.expect(cache.nodes.items[2].activeTag().?.ptr == cache.nodes.items[4].activeTag().?.ptr);
                        fault.configure(null);
                        for (&nodes) |*node| node.deinit();
                        return attempts;
                    }
                }
            } else |err| {
                if (err != error.OutOfMemory) return err;
            }
            try std.testing.expectEqual(@as(usize, 0), cache.nodes.items.len);
            try std.testing.expectEqual(@as(usize, 0), cache.interned_tags.count());
            fault.configure(null);
            if (overlay) |*tags| tags.deinit(allocator);
            overlay = try PreparedTagOverlay.init(TestCtx, allocator, &cache, 2);
            try cache.preflightNodeCapacity(allocator, 5);
            var retry = try PreparedNodeCreation.prepare(TestCtx, allocator, &cache, &overlay.?, ids.ElemId.fromRaw(3), "section");
            overlay.?.apply(TestCtx, &cache);
            retry.apply(TestCtx, &cache);
            retry.deinit();
            try std.testing.expect(cache.nodes.items[3].isActive());
            return 0;
        }
    };

    const attempts = try Runner.run(null);
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| _ = try Runner.run(failure_number);
}

test "prepared scalar fields abort cleanly and publish allocation free" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var fault = FaultAllocator.init(std.testing.allocator);
    const allocator = fault.allocator();
    var cache: Cache(TestCtx) = .{};
    defer {
        for (cache.nodes.items) |*node| node.deinit(allocator);
        cache.nodes.deinit(allocator);
    }
    var node = ScalarNode.initActive("input");
    node.value = try allocator.dupe(u8, "old");
    node.checked = false;
    try cache.nodes.append(allocator, node);

    fault.configure(1);
    try std.testing.expectError(error.OutOfMemory, PreparedTextFieldUpdate.prepare(TestCtx, allocator, &cache, ids.ElemId.fromRaw(0), .value, "new"));
    try std.testing.expectEqualStrings("old", cache.nodes.items[0].value.?);
    try std.testing.expectEqual(false, cache.nodes.items[0].checked.?);

    fault.configure(null);
    var aborted = try PreparedTextFieldUpdate.prepare(TestCtx, allocator, &cache, ids.root_elem, .value, "new");
    aborted.deinit(allocator);
    try std.testing.expectEqualStrings("old", cache.nodes.items[0].value.?);

    var text = try PreparedTextFieldUpdate.prepare(TestCtx, allocator, &cache, ids.root_elem, .value, "new");
    var boolean = try PreparedBoolFieldUpdate.prepare(TestCtx, &cache, ids.root_elem, .checked, true);
    const old_binding = EventBinding{ .event_id = ids.EventId.fromRaw(1), .payload_descriptor = BoundaryPayloadDescriptor.init(.unit, .none) };
    cache.nodes.items[0].event_bindings.click = old_binding;
    const next_binding = EventBinding{ .event_id = ids.EventId.fromRaw(2), .payload_descriptor = BoundaryPayloadDescriptor.init(.unit, .none) };
    var event = try PreparedFixedEventUpdate.prepare(TestCtx, &cache, ids.root_elem, .click, next_binding);
    fault.configure(1);
    text.apply(TestCtx, &cache);
    boolean.apply(TestCtx, &cache);
    event.apply(TestCtx, &cache);
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqualStrings("new", cache.nodes.items[0].value.?);
    try std.testing.expect(cache.nodes.items[0].checked.?);
    try std.testing.expectEqual(ids.EventId.fromRaw(2), cache.nodes.items[0].event_bindings.click.?.event_id);
    try std.testing.expectEqual(ids.EventId.fromRaw(1), event.retired.?.event_id);
    try std.testing.expectEqualStrings("old", text.retired.?);
    fault.configure(null);
    text.deinit(allocator);
}

test "prepared custom attributes sweep failures and publish allocation free" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var fault = FaultAllocator.init(std.testing.allocator);
    const allocator = fault.allocator();
    var cache: Cache(TestCtx) = .{};
    defer {
        for (cache.nodes.items) |*node| node.deinit(allocator);
        cache.nodes.deinit(allocator);
    }
    var node = ScalarNode.initActive("div");
    try node.custom_text_attrs.append(allocator, .{
        .name = try allocator.dupe(u8, "data-old"),
        .value = try allocator.dupe(u8, "old"),
    });
    try cache.nodes.append(allocator, node);
    const desired = [_]CustomTextAttr{
        .{ .name = "data-a", .value = "one" },
        .{ .name = "data-b", .value = "two" },
    };

    fault.configure(null);
    var counted = try PreparedCustomTextAttrsReplacement.prepare(TestCtx, allocator, &cache, ids.ElemId.fromRaw(0), &desired);
    const attempts = fault.attempts;
    counted.deinit(allocator);
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| {
        fault.configure(failure_number);
        try std.testing.expectError(error.OutOfMemory, PreparedCustomTextAttrsReplacement.prepare(TestCtx, allocator, &cache, ids.root_elem, &desired));
        try std.testing.expectEqualStrings("data-old", cache.nodes.items[0].custom_text_attrs.items[0].name);
        fault.configure(null);
        var retry = try PreparedCustomTextAttrsReplacement.prepare(TestCtx, allocator, &cache, ids.root_elem, &desired);
        retry.deinit(allocator);
    }

    var committed = try PreparedCustomTextAttrsReplacement.prepare(TestCtx, allocator, &cache, ids.root_elem, &desired);
    fault.configure(1);
    committed.apply(TestCtx, &cache);
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqualStrings("data-a", cache.nodes.items[0].custom_text_attrs.items[0].name);
    try std.testing.expectEqualStrings("data-old", committed.retired.items[0].name);
    fault.configure(null);
    committed.deinit(allocator);
}

test "prepared named events sweep failures and publish allocation free" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var fault = FaultAllocator.init(std.testing.allocator);
    const allocator = fault.allocator();
    var cache: Cache(TestCtx) = .{};
    defer {
        for (cache.nodes.items) |*node| node.deinit(allocator);
        cache.nodes.deinit(allocator);
    }
    var node = ScalarNode.initActive("div");
    try node.named_events.append(allocator, .{
        .name = try allocator.dupe(u8, "old"),
        .binding = .{ .event_id = ids.EventId.fromRaw(1), .payload_descriptor = BoundaryPayloadDescriptor.init(.unit, .none) },
    });
    try cache.nodes.append(allocator, node);
    const desired = [_]NamedEvent{
        .{ .name = "focus", .binding = .{ .event_id = ids.EventId.fromRaw(2), .payload_descriptor = BoundaryPayloadDescriptor.init(.unit, .none) } },
        .{ .name = "blur", .binding = .{ .event_id = ids.EventId.fromRaw(3), .payload_descriptor = BoundaryPayloadDescriptor.init(.unit, .none) } },
    };

    fault.configure(null);
    var counted = try PreparedNamedEventsReplacement.prepare(TestCtx, allocator, &cache, ids.ElemId.fromRaw(0), &desired);
    const attempts = fault.attempts;
    counted.deinit(allocator);
    for (1..attempts + 1) |failure_number| {
        fault.configure(failure_number);
        try std.testing.expectError(error.OutOfMemory, PreparedNamedEventsReplacement.prepare(TestCtx, allocator, &cache, ids.root_elem, &desired));
        try std.testing.expectEqualStrings("old", cache.nodes.items[0].named_events.items[0].name);
        fault.configure(null);
        var retry = try PreparedNamedEventsReplacement.prepare(TestCtx, allocator, &cache, ids.root_elem, &desired);
        retry.deinit(allocator);
    }

    var committed = try PreparedNamedEventsReplacement.prepare(TestCtx, allocator, &cache, ids.root_elem, &desired);
    fault.configure(1);
    committed.apply(TestCtx, &cache);
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqualStrings("focus", cache.nodes.items[0].named_events.items[0].name);
    try std.testing.expectEqualStrings("old", committed.retired.items[0].name);
    fault.configure(null);
    committed.deinit(allocator);
}

test "prepared render splice composes mixed cache deltas allocation free" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var fault = FaultAllocator.init(std.testing.allocator);
    const allocator = fault.allocator();
    var cache: Cache(TestCtx) = .{};
    defer {
        for (cache.nodes.items) |*node| node.deinit(allocator);
        cache.nodes.deinit(allocator);
        var tags = cache.interned_tags.valueIterator();
        while (tags.next()) |tag| allocator.free(tag.*);
        cache.interned_tags.deinit(allocator);
    }
    try cache.nodes.append(allocator, ScalarNode.initActive("root"));
    try cache.nodes.append(allocator, ScalarNode.initActive("left"));
    try cache.nodes.append(allocator, ScalarNode.initActive("right"));
    var child = ScalarNode.initActive("old");
    child.parent_id = ids.ElemId.fromRaw(1);
    try cache.nodes.append(allocator, child);
    try cache.nodes.items[0].children.appendSlice(allocator, &.{ ids.ElemId.fromRaw(1), ids.ElemId.fromRaw(2) });
    try cache.nodes.items[1].children.append(allocator, ids.ElemId.fromRaw(3));

    const counts = PreparedRenderCounts{
        .node_capacity = 8,
        .new_tags = 1,
        .creations = 1,
        .children = 2,
        .child_links = 2,
        .text_fields = 1,
        .bool_fields = 1,
        .fixed_events = 1,
        .custom_attrs = 1,
        .named_events = 1,
        .wire_commands = 8,
    };
    const custom = [_]CustomTextAttr{.{ .name = "data-new", .value = "yes" }};
    const named = [_]NamedEvent{.{ .name = "focus", .binding = .{ .event_id = ids.EventId.fromRaw(10), .payload_descriptor = BoundaryPayloadDescriptor.init(.unit, .none) } }};

    var aborted = try PreparedRenderSplice(TestCtx).init(allocator, &cache, counts);
    try aborted.addCreation(&cache, ids.ElemId.fromRaw(7), "button");
    try aborted.addChildren(&cache, ids.ElemId.fromRaw(1), &.{ids.ElemId.fromRaw(7)});
    try aborted.addChildren(&cache, ids.ElemId.fromRaw(2), &.{ids.ElemId.fromRaw(3)});
    try aborted.addTextField(&cache, ids.ElemId.fromRaw(7), .label, "next");
    try aborted.addBoolField(&cache, ids.ElemId.fromRaw(7), .disabled, true);
    try aborted.addFixedEvent(&cache, ids.ElemId.fromRaw(7), .click, .{ .event_id = ids.EventId.fromRaw(9), .payload_descriptor = BoundaryPayloadDescriptor.init(.unit, .none) });
    try aborted.addCustomAttrs(&cache, ids.ElemId.fromRaw(7), &custom);
    try aborted.addNamedEvents(&cache, ids.ElemId.fromRaw(7), &named);
    aborted.deinit();
    try std.testing.expectEqualSlices(ids.ElemId, &.{ids.ElemId.fromRaw(3)}, cache.nodes.items[1].children.items);
    try std.testing.expectEqual(@as(?ids.ElemId, ids.ElemId.fromRaw(1)), cache.nodes.items[3].parent_id);
    try std.testing.expectEqual(@as(usize, 4), cache.nodes.items.len);

    var plan = try PreparedRenderSplice(TestCtx).init(allocator, &cache, counts);
    defer plan.deinit();
    try plan.addCreation(&cache, ids.ElemId.fromRaw(7), "button");
    try plan.addChildren(&cache, ids.ElemId.fromRaw(1), &.{ids.ElemId.fromRaw(7)});
    try plan.addChildren(&cache, ids.ElemId.fromRaw(2), &.{ids.ElemId.fromRaw(3)});
    try plan.addTextField(&cache, ids.ElemId.fromRaw(7), .label, "next");
    try plan.addBoolField(&cache, ids.ElemId.fromRaw(7), .disabled, true);
    try plan.addFixedEvent(&cache, ids.ElemId.fromRaw(7), .click, .{ .event_id = ids.EventId.fromRaw(9), .payload_descriptor = BoundaryPayloadDescriptor.init(.unit, .none) });
    try plan.addCustomAttrs(&cache, ids.ElemId.fromRaw(7), &custom);
    try plan.addNamedEvents(&cache, ids.ElemId.fromRaw(7), &named);

    var batch: render.TransactionalBatch = .{};
    defer batch.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 8), plan.wire.commands.items.len);
    try plan.wire.preflight(&batch, allocator);
    try std.testing.expectEqual(@as(usize, 0), batch.published.commands.len());
    fault.configure(1);
    try plan.wire.stageAssumeCapacity(&batch, allocator);
    plan.apply(&cache);
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqual(@as(usize, 8), batch.staged.commands.len());
    try std.testing.expectEqual(@as(usize, 0), batch.published.commands.len());
    try std.testing.expectEqualStrings("button", cache.nodes.items[7].activeTag().?);
    try std.testing.expectEqualStrings("next", cache.nodes.items[7].label.?);
    try std.testing.expect(cache.nodes.items[7].disabled.?);
    try std.testing.expectEqual(ids.EventId.fromRaw(9), cache.nodes.items[7].event_bindings.click.?.event_id);
    try std.testing.expectEqualStrings("data-new", cache.nodes.items[7].custom_text_attrs.items[0].name);
    try std.testing.expectEqualStrings("focus", cache.nodes.items[7].named_events.items[0].name);
    try std.testing.expectEqualSlices(ids.ElemId, &.{ids.ElemId.fromRaw(7)}, cache.nodes.items[1].children.items);
    try std.testing.expectEqualSlices(ids.ElemId, &.{ids.ElemId.fromRaw(3)}, cache.nodes.items[2].children.items);
    try std.testing.expectEqual(@as(?ids.ElemId, ids.ElemId.fromRaw(1)), cache.nodes.items[7].parent_id);
    try std.testing.expectEqual(@as(?ids.ElemId, ids.ElemId.fromRaw(2)), cache.nodes.items[3].parent_id);
    batch.commit();
    batch.publish();
    try std.testing.expectEqual(@as(usize, 8), batch.published.commands.len());
    const expected_ops = [_]render.Op{
        .create_element,
        .append_child,
        .append_child,
        .extended,
        .set_disabled,
        .bind_click,
        .extended,
        .extended,
    };
    for (batch.published.commands.records.items, expected_ops) |record, expected| {
        try std.testing.expectEqual(@intFromEnum(expected), record.op);
    }
    fault.configure(null);
}

test "prepared render splice leaves unchanged retained values allocation free" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var fault = FaultAllocator.init(std.testing.allocator);
    var cache: Cache(TestCtx) = .{};
    var host = TestHost{};
    defer cache.deinit(&host);
    try cache.nodes.append(std.testing.allocator, ScalarNode.initActive("root"));
    var plan = try PreparedRenderSplice(TestCtx).init(fault.allocator(), &cache, .{
        .node_capacity = 1,
        .text_fields = 1,
        .bool_fields = 1,
        .fixed_events = 1,
        .custom_attrs = 1,
        .named_events = 1,
        .wire_commands = 1,
    });
    defer plan.deinit();
    fault.configure(1);
    try plan.addTextField(&cache, ids.ElemId.fromRaw(0), .text, null);
    try plan.addBoolField(&cache, ids.root_elem, .checked, null);
    try plan.addFixedEvent(&cache, ids.root_elem, .click, null);
    try plan.addCustomAttrs(&cache, ids.root_elem, &.{});
    try plan.addNamedEvents(&cache, ids.root_elem, &.{});
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqual(@as(usize, 0), plan.text_fields.items.len);
    try std.testing.expectEqual(@as(usize, 0), plan.bool_fields.items.len);
    try std.testing.expectEqual(@as(usize, 0), plan.fixed_events.items.len);
    try std.testing.expectEqual(@as(usize, 0), plan.custom_attrs.items.len);
    try std.testing.expectEqual(@as(usize, 0), plan.named_events.items.len);
    try std.testing.expectEqual(@as(usize, 0), plan.wire.commands.items.len);
    fault.configure(null);
}

test "prepared render wire commands own borrowed preparation inputs" {
    var cache: Cache(TestCtx) = .{};
    var host = TestHost{};
    defer cache.deinit(&host);
    try cache.nodes.append(std.testing.allocator, ScalarNode.initActive("root"));
    var tag = try std.testing.allocator.dupe(u8, "article");
    var label = try std.testing.allocator.dupe(u8, "owned label");
    var plan = try PreparedRenderSplice(TestCtx).init(std.testing.allocator, &cache, .{
        .node_capacity = 2,
        .new_tags = 1,
        .creations = 1,
        .text_fields = 1,
        .wire_commands = 2,
    });
    defer plan.deinit();
    try plan.addCreation(&cache, ids.ElemId.fromRaw(1), tag);
    try plan.addTextField(&cache, ids.ElemId.fromRaw(1), .label, label);
    std.testing.allocator.free(tag);
    std.testing.allocator.free(label);
    tag = undefined;
    label = undefined;

    var batch: render.TransactionalBatch = .{};
    defer batch.deinit(std.testing.allocator);
    try plan.wire.preflight(&batch, std.testing.allocator);
    try plan.wire.stageAssumeCapacity(&batch, std.testing.allocator);
    try std.testing.expectEqualStrings("article", batch.staged.strings.items);
    try std.testing.expect(std.mem.indexOf(u8, batch.staged.dynamic.bytes.items, "owned label") != null);
}

test "prepared render wire derives retirement and keyed replacement diffs" {
    var cache: Cache(TestCtx) = .{};
    var host = TestHost{};
    defer cache.deinit(&host);
    try cache.nodes.append(std.testing.allocator, ScalarNode.initActive("root"));
    var child = ScalarNode.initActive("button");
    child.parent_id = ids.ElemId.fromRaw(0);
    try child.custom_text_attrs.append(std.testing.allocator, .{
        .name = try std.testing.allocator.dupe(u8, "old"),
        .value = try std.testing.allocator.dupe(u8, "value"),
    });
    try child.named_events.append(std.testing.allocator, .{
        .name = try std.testing.allocator.dupe(u8, "blur"),
        .binding = .{ .event_id = ids.EventId.fromRaw(1), .payload_descriptor = BoundaryPayloadDescriptor.init(.unit, .none) },
    });
    try cache.nodes.append(std.testing.allocator, child);
    try cache.nodes.items[0].children.append(std.testing.allocator, ids.ElemId.fromRaw(1));

    const attrs = [_]CustomTextAttr{.{ .name = "new", .value = "next" }};
    const events = [_]NamedEvent{.{ .name = "focus", .binding = .{ .event_id = ids.EventId.fromRaw(2), .payload_descriptor = BoundaryPayloadDescriptor.init(.unit, .none) } }};
    var plan = try PreparedRenderSplice(TestCtx).init(std.testing.allocator, &cache, .{
        .node_capacity = 2,
        .removals = 1,
        .children = 1,
        .child_links = 1,
        .custom_attrs = 1,
        .named_events = 1,
        .wire_commands = 5,
    });
    defer plan.deinit();
    try plan.addCustomAttrs(&cache, ids.ElemId.fromRaw(1), &attrs);
    try plan.addNamedEvents(&cache, ids.ElemId.fromRaw(1), &events);
    try plan.addRemoval(&cache, ids.ElemId.fromRaw(1));
    try plan.addChildren(&cache, ids.root_elem, &.{});
    try std.testing.expectEqual(@as(usize, 5), plan.wire.commands.items.len);
    const counts = plan.wire.counts();
    try std.testing.expectEqual(@as(u64, 5), counts.total);
    try std.testing.expectEqual(@as(u64, 1), counts.remove_node);
    try std.testing.expectEqual(@as(u64, 2), counts.set_metadata);
    try std.testing.expectEqual(@as(u64, 2), counts.bind_event);
}

test "prepared render splice reuses a same-tag slot and clears the fields its new descriptor dropped" {
    const allocator = std.testing.allocator;
    var cache: Cache(TestCtx) = .{};
    var host = TestHost{};
    defer cache.deinit(&host);
    try cache.nodes.append(allocator, ScalarNode.initActive("root"));
    var node = ScalarNode.initActive("input");
    node.parent_id = ids.root_elem;
    node.label = try allocator.dupe(u8, "old label");
    node.value = try allocator.dupe(u8, "same");
    node.checked = true;
    node.event_bindings.click = .{ .event_id = ids.EventId.fromRaw(3), .payload_descriptor = BoundaryPayloadDescriptor.init(.unit, .none) };
    try cache.nodes.append(allocator, node);
    try cache.nodes.items[0].children.append(allocator, ids.ElemId.fromRaw(1));

    var plan = try PreparedRenderSplice(TestCtx).init(allocator, &cache, .{
        .node_capacity = 2,
        .reuses = 1,
        .text_fields = 1 + reused_node_max_clears,
        .bool_fields = reused_node_max_clears,
        .fixed_events = reused_node_max_clears,
        .wire_commands = 1 + reused_node_max_clears,
    });
    defer plan.deinit();
    try std.testing.expectError(error.TagMismatch, plan.addNodeReuse(&cache, ids.ElemId.fromRaw(1), "section"));
    try std.testing.expectError(error.MissingNode, plan.addNodeReuse(&cache, ids.ElemId.fromRaw(2), "input"));
    try plan.addNodeReuse(&cache, ids.ElemId.fromRaw(1), "input");
    try std.testing.expectError(error.DuplicateNode, plan.addNodeReuse(&cache, ids.ElemId.fromRaw(1), "input"));
    // The re-collected descriptor keeps the value, adds text, and no longer
    // declares the label, the checked flag, or the click binding.
    try plan.addTextField(&cache, ids.ElemId.fromRaw(1), .value, "same");
    try plan.addTextField(&cache, ids.ElemId.fromRaw(1), .text, "typed");
    try plan.clearUnsetReusedFields(&cache);

    try std.testing.expectEqual(@as(usize, 0), plan.removals.items.len);
    try std.testing.expectEqual(@as(usize, 0), plan.creations.items.len);
    const counts = plan.wire.counts();
    try std.testing.expectEqual(@as(u64, 4), counts.total);
    try std.testing.expectEqual(@as(u64, 1), counts.set_text);
    try std.testing.expectEqual(@as(u64, 0), counts.set_value);
    try std.testing.expectEqual(@as(u64, 1), counts.set_metadata);
    try std.testing.expectEqual(@as(u64, 1), counts.set_checked);
    try std.testing.expectEqual(@as(u64, 1), counts.bind_event);

    plan.apply(&cache);
    const applied = &cache.nodes.items[1];
    try std.testing.expectEqualStrings("input", applied.activeTag().?);
    try std.testing.expectEqualStrings("typed", applied.text.?);
    try std.testing.expectEqualStrings("same", applied.value.?);
    try std.testing.expectEqual(@as(?[]const u8, null), applied.label);
    try std.testing.expectEqual(@as(?bool, null), applied.checked);
    try std.testing.expect(applied.event_bindings.click == null);
    try std.testing.expectEqualSlices(ids.ElemId, &.{ids.ElemId.fromRaw(1)}, cache.nodes.items[0].children.items);
}

test "prepared render splice recreates one active slot transactionally" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var fault = FaultAllocator.init(std.testing.allocator);
    const allocator = fault.allocator();
    var cache: Cache(TestCtx) = .{};
    var host = TestHost{};
    defer cache.deinit(&host);
    try cache.nodes.append(allocator, ScalarNode.initActive("root"));
    try cache.nodes.append(allocator, ScalarNode.initActive("old"));
    var aborted = try PreparedRenderSplice(TestCtx).init(allocator, &cache, .{
        .node_capacity = 2,
        .new_tags = 1,
        .removals = 1,
        .creations = 1,
        .child_links = 1,
        .wire_commands = 2,
    });
    fault.configure(1);
    try std.testing.expectError(error.OutOfMemory, aborted.addNodeReplacement(&cache, ids.ElemId.fromRaw(1), "new"));
    try std.testing.expectEqualStrings("old", cache.nodes.items[1].activeTag().?);
    try std.testing.expectEqual(@as(?ids.ElemId, null), cache.nodes.items[1].parent_id);
    fault.configure(null);
    aborted.deinit();
    var plan = try PreparedRenderSplice(TestCtx).init(allocator, &cache, .{
        .node_capacity = 2,
        .new_tags = 1,
        .removals = 1,
        .creations = 1,
        .child_links = 1,
        .wire_commands = 2,
    });
    defer plan.deinit();
    try plan.addNodeReplacement(&cache, ids.ElemId.fromRaw(1), "new");
    try std.testing.expectEqualStrings("old", cache.nodes.items[1].activeTag().?);
    fault.configure(1);
    plan.apply(&cache);
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqualStrings("new", cache.nodes.items[1].activeTag().?);
    try std.testing.expectEqual(@as(usize, 2), plan.wire.commands.items.len);
    fault.configure(null);
}

test "prepared render splice adoption releases scalar updates for nodes it retires" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    const Plan = PreparedRenderSplice(TestCtx);
    const Runner = struct {
        const retired_next = [_]CustomTextAttr{.{ .name = "data-slack", .value = "7" }};
        const survivor_next = [_]CustomTextAttr{.{ .name = "data-slack", .value = "3" }};

        fn seed(allocator: std.mem.Allocator, cache: *Cache(TestCtx)) !void {
            try cache.nodes.append(allocator, ScalarNode.initActive("root"));
            for ([_][]const u8{ "li", "li" }, 1..) |tag, index| {
                var node = ScalarNode.initActive(tag);
                node.parent_id = ids.root_elem;
                try cache.nodes.append(allocator, node);
                const slot = &cache.nodes.items[index];
                slot.text = try allocator.dupe(u8, "old");
                try slot.custom_text_attrs.append(allocator, .{ .name = try allocator.dupe(u8, "data-slack"), .value = try allocator.dupe(u8, "0") });
            }
        }

        /// Prepares the scalar splice against the committed cache, then the
        /// structural splice that retires node 1, and adopts the former into
        /// the latter the way `PreparedSourceTransaction.prepareRoots` does.
        fn prepare(allocator: std.mem.Allocator, cache: *Cache(TestCtx), batch: *render.TransactionalBatch) !Plan {
            var scalar = try Plan.init(allocator, cache, .{ .node_capacity = 3, .text_fields = 2, .bool_fields = 1, .custom_attrs = 2, .wire_commands = 5 });
            defer scalar.deinit();
            try scalar.addTextField(cache, ids.ElemId.fromRaw(1), .text, "retired");
            try scalar.addBoolField(cache, ids.ElemId.fromRaw(1), .checked, true);
            try scalar.addCustomAttrs(cache, ids.ElemId.fromRaw(1), &retired_next);
            try scalar.addTextField(cache, ids.ElemId.fromRaw(2), .text, "survivor");
            try scalar.addCustomAttrs(cache, ids.ElemId.fromRaw(2), &survivor_next);
            try std.testing.expectEqual(@as(usize, 5), scalar.wire.commands.items.len);
            var structural = try Plan.init(allocator, cache, .{ .node_capacity = 3, .removals = 1, .child_links = 1, .wire_commands = 1 });
            errdefer structural.deinit();
            try structural.addRemoval(cache, ids.ElemId.fromRaw(1));
            try structural.adoptScalarUpdates(&scalar);
            try structural.wire.preflight(batch, allocator);
            return structural;
        }

        fn expectCommitted(cache: *const Cache(TestCtx), batch: *const render.TransactionalBatch) !void {
            try std.testing.expect(!cache.nodes.items[1].isActive());
            try std.testing.expectEqual(@as(?[]const u8, null), cache.nodes.items[1].text);
            try std.testing.expectEqual(@as(?bool, null), cache.nodes.items[1].checked);
            try std.testing.expectEqual(@as(usize, 0), cache.nodes.items[1].custom_text_attrs.items.len);
            try std.testing.expectEqualStrings("survivor", cache.nodes.items[2].text.?);
            try std.testing.expectEqualStrings("3", cache.nodes.items[2].custom_text_attrs.items[0].value);
            try std.testing.expectEqual(@as(usize, 3), batch.published.commands.len());
        }

        fn run(failure_number: ?usize) !usize {
            var fault = FaultAllocator.init(std.testing.allocator);
            const allocator = fault.allocator();
            var cache: Cache(TestCtx) = .{};
            var host = TestHost{};
            defer cache.deinit(&host);
            var batch: render.TransactionalBatch = .{};
            defer batch.deinit(allocator);
            try seed(allocator, &cache);
            fault.configure(failure_number);
            const prepared = prepare(allocator, &cache, &batch);
            if (failure_number == null) {
                var plan = try prepared;
                const attempts = fault.attempts;
                try std.testing.expectEqual(@as(usize, 1), plan.text_fields.items.len);
                try std.testing.expectEqual(@as(usize, 0), plan.bool_fields.items.len);
                try std.testing.expectEqual(@as(usize, 1), plan.custom_attrs.items.len);
                try std.testing.expectEqual(@as(usize, 3), plan.wire.commands.items.len);
                for (plan.wire.commands.items[1..]) |command| switch (command) {
                    .set_text => |value| try std.testing.expectEqual(@as(u32, 2), value.elem_id.raw()),
                    .set_attr_text => |value| try std.testing.expectEqual(@as(u32, 2), value.elem_id.raw()),
                    else => return error.TestUnexpectedResult,
                };
                fault.configure(1);
                try plan.wire.stageAssumeCapacity(&batch, allocator);
                plan.apply(&cache);
                batch.commit();
                batch.publish();
                try std.testing.expectEqual(@as(usize, 0), fault.attempts);
                fault.configure(null);
                plan.deinit();
                try expectCommitted(&cache, &batch);
                // The retired slot is reused by a later creation; anything the
                // adoption left behind on it would be overwritten and leak.
                var reuse = try Plan.init(allocator, &cache, .{ .node_capacity = 3, .new_tags = 1, .creations = 1, .wire_commands = 1 });
                defer reuse.deinit();
                try reuse.addCreation(&cache, ids.ElemId.fromRaw(1), "p");
                reuse.apply(&cache);
                try std.testing.expectEqualStrings("p", cache.nodes.items[1].activeTag().?);
                return attempts;
            }
            try std.testing.expectError(error.OutOfMemory, prepared);
            try std.testing.expect(cache.nodes.items[1].isActive());
            try std.testing.expectEqualStrings("old", cache.nodes.items[1].text.?);
            try std.testing.expectEqualStrings("0", cache.nodes.items[1].custom_text_attrs.items[0].value);
            try std.testing.expectEqualStrings("0", cache.nodes.items[2].custom_text_attrs.items[0].value);
            try std.testing.expectEqual(@as(usize, 0), batch.staged.commands.len());
            fault.configure(null);
            var retry = try prepare(allocator, &cache, &batch);
            retry.deinit();
            return 0;
        }
    };

    const attempts = try Runner.run(null);
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| _ = try Runner.run(failure_number);
}

test "prepared render splice sweeps every allocation and retries" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    const Plan = PreparedRenderSplice(TestCtx);
    const Runner = struct {
        const counts = PreparedRenderCounts{
            .node_capacity = 8,
            .new_tags = 1,
            .creations = 1,
            .children = 1,
            .child_links = 1,
            .text_fields = 1,
            .bool_fields = 1,
            .fixed_events = 1,
            .custom_attrs = 1,
            .named_events = 1,
            .wire_commands = 7,
        };
        const custom = [_]CustomTextAttr{.{ .name = "data-new", .value = "yes" }};
        const named = [_]NamedEvent{.{ .name = "focus", .binding = .{ .event_id = ids.EventId.fromRaw(10), .payload_descriptor = BoundaryPayloadDescriptor.init(.unit, .none) } }};

        fn prepare(allocator: std.mem.Allocator, cache: *Cache(TestCtx), batch: *render.TransactionalBatch) !Plan {
            var plan = try Plan.init(allocator, cache, counts);
            errdefer plan.deinit();
            try plan.addCreation(cache, ids.ElemId.fromRaw(7), "button");
            try plan.addChildren(cache, ids.root_elem, &.{ids.ElemId.fromRaw(7)});
            try plan.addTextField(cache, ids.ElemId.fromRaw(7), .label, "next");
            try plan.addBoolField(cache, ids.ElemId.fromRaw(7), .disabled, true);
            try plan.addFixedEvent(cache, ids.ElemId.fromRaw(7), .click, .{ .event_id = ids.EventId.fromRaw(9), .payload_descriptor = BoundaryPayloadDescriptor.init(.unit, .none) });
            try plan.addCustomAttrs(cache, ids.ElemId.fromRaw(7), &custom);
            try plan.addNamedEvents(cache, ids.ElemId.fromRaw(7), &named);
            try plan.wire.preflight(batch, allocator);
            return plan;
        }

        fn run(failure_number: ?usize) !usize {
            var fault = FaultAllocator.init(std.testing.allocator);
            var cache: Cache(TestCtx) = .{};
            var host = TestHost{};
            defer cache.deinit(&host);
            var batch: render.TransactionalBatch = .{};
            defer batch.deinit(fault.allocator());
            try cache.nodes.append(std.testing.allocator, ScalarNode.initActive("root"));
            fault.configure(failure_number);
            const prepared = prepare(fault.allocator(), &cache, &batch);
            if (failure_number == null) {
                var plan = try prepared;
                const attempts = fault.attempts;
                fault.configure(1);
                try plan.wire.stageAssumeCapacity(&batch, fault.allocator());
                plan.apply(&cache);
                try std.testing.expectEqual(@as(usize, 0), fault.attempts);
                try std.testing.expectEqual(@as(usize, 0), batch.published.commands.len());
                batch.commit();
                batch.publish();
                try std.testing.expectEqual(@as(usize, 7), batch.published.commands.len());
                fault.configure(null);
                plan.deinit();
                return attempts;
            }
            try std.testing.expectError(error.OutOfMemory, prepared);
            try std.testing.expectEqual(@as(usize, 1), cache.nodes.items.len);
            try std.testing.expectEqual(@as(usize, 0), cache.nodes.items[0].children.items.len);
            try std.testing.expectEqual(@as(usize, 0), cache.interned_tags.count());
            try std.testing.expectEqual(@as(usize, 0), batch.published.commands.len());
            try std.testing.expectEqual(@as(usize, 0), batch.staged.commands.len());
            fault.configure(null);
            var retry = try prepare(fault.allocator(), &cache, &batch);
            retry.deinit();
            try std.testing.expectEqual(@as(usize, 1), cache.nodes.items.len);
            return 0;
        }
    };

    const attempts = try Runner.run(null);
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| _ = try Runner.run(failure_number);

    var cache: Cache(TestCtx) = .{};
    var host = TestHost{};
    defer cache.deinit(&host);
    try cache.nodes.append(std.testing.allocator, ScalarNode.initActive("root"));
    var duplicate = try Plan.init(std.testing.allocator, &cache, .{ .node_capacity = 8, .new_tags = 1, .creations = 1, .children = 1, .child_links = 1, .wire_commands = 1 });
    defer duplicate.deinit();
    try duplicate.addCreation(&cache, ids.ElemId.fromRaw(7), "button");
    try std.testing.expectError(error.DuplicateChild, duplicate.addChildren(&cache, ids.root_elem, &.{ ids.ElemId.fromRaw(7), ids.ElemId.fromRaw(7) }));
    try std.testing.expectEqual(@as(usize, 0), cache.nodes.items[0].children.items.len);
}

test "render cache reset accepts sparse element ids" {
    var host = TestHost{};
    var cache: Cache(TestCtx) = .{};
    defer cache.deinit(&host);

    cache.reset(&host);
    var counts: render.Counts = .{};
    cache.ensureNode(&host, ids.ElemId.fromRaw(3), "div", &counts);

    try std.testing.expectEqual(@as(usize, 4), cache.nodes.items.len);
    try std.testing.expect(!cache.nodes.items[1].isActive());
    try std.testing.expect(!cache.nodes.items[2].isActive());
    try std.testing.expect(cache.nodes.items[3].isActive());
    try std.testing.expectEqual(@as(u64, 1), counts.create_element);
}

test "removed cache slot can be recreated with a different tag" {
    var host = TestHost{};
    var cache: Cache(TestCtx) = .{};
    defer cache.deinit(&host);

    cache.reset(&host);
    var counts: render.Counts = .{};
    cache.ensureNode(&host, ids.ElemId.fromRaw(1), "text", &counts);
    try std.testing.expect(!cache.activeNodeTagDiffers(ids.ElemId.fromRaw(1), "text"));
    try std.testing.expect(cache.activeNodeTagDiffers(ids.ElemId.fromRaw(1), "div"));
    try std.testing.expect(cache.applyTextField(&host, ids.ElemId.fromRaw(1), .text, "stale"));

    cache.removeNode(&host, ids.ElemId.fromRaw(1), &counts);
    try std.testing.expect(!cache.activeNodeTagDiffers(ids.ElemId.fromRaw(1), "div"));

    cache.ensureNode(&host, ids.ElemId.fromRaw(1), "div", &counts);
    const node = cache.activeNode(ids.ElemId.fromRaw(1));
    try std.testing.expectEqualStrings("div", node.activeTag().?);
    try std.testing.expectEqual(@as(?[]const u8, null), node.text);
    try std.testing.expectEqual(@as(u64, 2), counts.create_element);
    try std.testing.expectEqual(@as(u64, 1), counts.remove_node);
    try std.testing.expectEqual(@as(u64, 3), counts.total);
}

test "reordering children counts only displaced moves" {
    var host = TestHost{};
    var cache: Cache(TestCtx) = .{};
    defer cache.deinit(&host);

    cache.reset(&host);
    var counts: render.Counts = .{};
    cache.ensureNode(&host, ids.ElemId.fromRaw(1), "div", &counts);
    cache.ensureNode(&host, ids.ElemId.fromRaw(2), "div", &counts);
    cache.ensureNode(&host, ids.ElemId.fromRaw(3), "div", &counts);
    cache.replaceChildren(&host, ids.root_elem, &.{ ids.ElemId.fromRaw(1), ids.ElemId.fromRaw(2), ids.ElemId.fromRaw(3) }, &counts);

    counts = .{};
    cache.replaceChildrenForMoves(&host, ids.root_elem, &.{ ids.ElemId.fromRaw(2), ids.ElemId.fromRaw(1), ids.ElemId.fromRaw(3) }, &counts);

    try std.testing.expectEqual(@as(u64, 1), counts.move_before);
    try std.testing.expectEqual(@as(u64, 1), counts.total);
}

test "unchanged event binding emits no duplicate command" {
    var host = TestHost{};
    var cache: Cache(TestCtx) = .{};
    defer cache.deinit(&host);

    cache.reset(&host);
    var counts: render.Counts = .{};
    cache.ensureNode(&host, ids.ElemId.fromRaw(1), "button", &counts);

    const binding = EventBinding{ .event_id = ids.EventId.fromRaw(1), .payload_descriptor = BoundaryPayloadDescriptor.init(.unit, .none) };
    cache.applyEventBinding(&host, ids.ElemId.fromRaw(1), .click, binding, &counts);
    cache.applyEventBinding(&host, ids.ElemId.fromRaw(1), .click, binding, &counts);
    try std.testing.expectEqual(@as(u64, 1), counts.bind_event);
    try std.testing.expectEqual(@as(u64, 1), host.bind_event_count);

    cache.applyEventBinding(&host, ids.ElemId.fromRaw(1), .click, null, &counts);
    cache.applyEventBinding(&host, ids.ElemId.fromRaw(1), .click, null, &counts);
    try std.testing.expectEqual(@as(u64, 2), counts.bind_event);
    try std.testing.expectEqual(@as(u64, 1), host.clear_event_count);
}

test "event binding slots are keyed by event kind" {
    var bindings = EventBindings{};
    const click = EventBinding{ .event_id = ids.EventId.fromRaw(1), .payload_descriptor = BoundaryPayloadDescriptor.init(.unit, .none) };
    const input = EventBinding{ .event_id = ids.EventId.fromRaw(2), .payload_descriptor = BoundaryPayloadDescriptor.init(.str, .target_value) };
    const pointer_down = EventBinding{ .event_id = ids.EventId.fromRaw(3), .payload_descriptor = BoundaryPayloadDescriptor.init(.bool, .target_checked) };

    eventBindingSlot(&bindings, .click).* = click;
    eventBindingSlot(&bindings, .input).* = input;
    eventBindingSlot(&bindings, .pointer_down).* = pointer_down;

    try std.testing.expectEqual(click, bindings.click.?);
    try std.testing.expectEqual(input, bindings.input.?);
    try std.testing.expectEqual(pointer_down, bindings.pointer_down.?);
    try std.testing.expectEqual(@as(?EventBinding, null), bindings.check);
    try std.testing.expectEqual(@as(?EventBinding, null), bindings.pointer_up);
    try std.testing.expectEqual(@as(?EventBinding, null), bindings.pointer_enter);
    try std.testing.expectEqual(@as(?EventBinding, null), bindings.pointer_leave);
}

test "event bindings derive delivery before cache storage and sink commands" {
    var host = TestHost{};
    var cache: Cache(TestCtx) = .{};
    defer cache.deinit(&host);

    cache.reset(&host);
    var counts: render.Counts = .{};
    cache.ensureNode(&host, ids.ElemId.fromRaw(1), "button", &counts);
    cache.ensureNode(&host, ids.ElemId.fromRaw(2), "form", &counts);

    const fixed = EventBinding{
        .event_id = ids.EventId.fromRaw(1),
        .payload_descriptor = BoundaryPayloadDescriptor.init(.unit, .none),
    };
    cache.applyEventBinding(&host, ids.ElemId.fromRaw(1), .pointer_down, fixed, &counts);
    const fixed_delivery = cache.activeNode(ids.ElemId.fromRaw(1)).event_bindings.pointer_down.?.delivery;
    try std.testing.expectEqual(render_sink.EventDeliveryRequest.auto, fixed_delivery.requested);
    try std.testing.expectEqual(render_sink.EventDeliveryEffective.native, fixed_delivery.effective);
    try std.testing.expectEqual(render_sink.EventDeliveryReason.pointer_drag, fixed_delivery.reason);
    try std.testing.expectEqual(render_sink.EventDeliveryReason.pointer_drag, host.last_event_binding.?.delivery.reason);

    const named = EventBinding{
        .event_id = ids.EventId.fromRaw(2),
        .policy = render.EventPolicy.fromBits(render.listener_option_capture),
        .payload_descriptor = BoundaryPayloadDescriptor.init(.unit, .none),
    };
    cache.applyNamedEventBinding(&host, ids.ElemId.fromRaw(2), "focus", named, &counts);
    const named_delivery = cache.activeNode(ids.ElemId.fromRaw(2)).named_events.items[0].binding.delivery;
    try std.testing.expectEqual(render_sink.EventDeliveryRequest.auto, named_delivery.requested);
    try std.testing.expectEqual(render_sink.EventDeliveryEffective.native, named_delivery.effective);
    try std.testing.expectEqual(render_sink.EventDeliveryReason.capture_policy, named_delivery.reason);
    try std.testing.expectEqual(render_sink.EventDeliveryReason.capture_policy, host.last_event_binding.?.delivery.reason);
}

test "custom text attr application and clear are idempotent" {
    var host = TestHost{};
    var cache: Cache(TestCtx) = .{};
    defer cache.deinit(&host);

    cache.reset(&host);
    var counts: render.Counts = .{};
    cache.ensureNode(&host, ids.ElemId.fromRaw(1), "div", &counts);

    try std.testing.expect(cache.applyTextAttr(&host, ids.ElemId.fromRaw(1), "data-x", "a"));
    try std.testing.expect(!cache.applyTextAttr(&host, ids.ElemId.fromRaw(1), "data-x", "a"));
    try std.testing.expect(cache.applyTextAttr(&host, ids.ElemId.fromRaw(1), "data-x", "b"));
    try std.testing.expectEqual(@as(u64, 2), host.apply_text_attr_count);

    try std.testing.expect(!cache.clearTextAttr(&host, ids.ElemId.fromRaw(1), "data-missing"));
    try std.testing.expect(cache.clearTextAttr(&host, ids.ElemId.fromRaw(1), "data-x"));
    try std.testing.expect(!cache.clearTextAttr(&host, ids.ElemId.fromRaw(1), "data-x"));
    try std.testing.expectEqual(@as(u64, 1), host.clear_text_attr_count);
}

test "named event replacement and clear are idempotent" {
    var host = TestHost{};
    var cache: Cache(TestCtx) = .{};
    defer cache.deinit(&host);

    cache.reset(&host);
    var counts: render.Counts = .{};
    cache.ensureNode(&host, ids.ElemId.fromRaw(1), "form", &counts);

    const first = EventBinding{
        .event_id = ids.EventId.fromRaw(1),
        .payload_descriptor = BoundaryPayloadDescriptor.init(.unit, .none),
    };
    const second = EventBinding{
        .event_id = ids.EventId.fromRaw(2),
        .policy = render.EventPolicy.fromBits(render.listener_option_prevent_default),
        .payload_descriptor = BoundaryPayloadDescriptor.init(.str, .target_value),
    };

    cache.applyNamedEventBinding(&host, ids.ElemId.fromRaw(1), "submit", first, &counts);
    cache.applyNamedEventBinding(&host, ids.ElemId.fromRaw(1), "submit", first, &counts);
    try std.testing.expectEqualStrings("submit", cache.namedEventNameAt(ids.ElemId.fromRaw(1), 0).?);

    cache.applyNamedEventBinding(&host, ids.ElemId.fromRaw(1), "submit", second, &counts);
    try std.testing.expectEqual(@as(u64, 2), host.bind_named_event_count);
    try std.testing.expectEqual(@as(u64, 2), counts.bind_event);

    cache.applyNamedEventBinding(&host, ids.ElemId.fromRaw(1), "submit", null, &counts);
    cache.applyNamedEventBinding(&host, ids.ElemId.fromRaw(1), "submit", null, &counts);
    try std.testing.expectEqual(@as(u64, 1), host.clear_named_event_count);
    try std.testing.expectEqual(@as(u64, 3), counts.bind_event);
}
