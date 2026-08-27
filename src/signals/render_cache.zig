//! Render-state cache that suppresses duplicate host commands for stable DOM nodes.

const std = @import("std");
const builtin = @import("builtin");
const boundary = @import("boundary.zig");
const render = @import("render_commands.zig");
const render_sink = @import("render_sink.zig");

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
    active: bool = false,
    tag: ?[]const u8 = null,
    parent_id: ?u64 = null,
    children: std.ArrayListUnmanaged(u64) = .empty,
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
        return .{
            .active = true,
            .tag = tag,
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
        return binding.event_id;
    }
};

fn u64SliceIndex(items: []const u64, target: u64) ?usize {
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

/// Owns one parent-child replacement until an allocation-free cache commit.
pub const PreparedChildrenReplacement = struct {
    parent_elem_id: u64,
    next: []u64,
    retired: std.ArrayListUnmanaged(u64) = .empty,
    committed: bool = false,

    /// Copies the next child order without mutating the active cache.
    pub fn prepare(comptime Ctx: type, allocator: std.mem.Allocator, cache: *const Cache(Ctx), parent_elem_id: u64, next: []const u64) (std.mem.Allocator.Error || error{MissingParent})!PreparedChildrenReplacement {
        const index = std.math.cast(usize, parent_elem_id) orelse return error.MissingParent;
        if (index >= cache.nodes.items.len or !cache.nodes.items[index].active) return error.MissingParent;
        return .{ .parent_elem_id = parent_elem_id, .next = try allocator.dupe(u64, next) };
    }

    /// Swaps the prepared order into the cache without allocating.
    pub fn apply(self: *PreparedChildrenReplacement, comptime Ctx: type, cache: *Cache(Ctx)) void {
        if (self.committed) @panic("prepared child replacement committed twice");
        const node = &cache.nodes.items[@intCast(self.parent_elem_id)];
        self.retired = node.children;
        node.children = .{ .items = self.next, .capacity = self.next.len };
        self.next = &.{};
        self.committed = true;
    }

    /// Releases provisional or retired child storage after abort or commit.
    pub fn deinit(self: *PreparedChildrenReplacement, allocator: std.mem.Allocator) void {
        allocator.free(self.next);
        self.retired.deinit(allocator);
        self.* = undefined;
    }
};

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
            return self.nodes.items.len != 0 and self.nodes.items[0].active;
        }

        /// Reserves the node table without changing its logical contents.
        pub fn preflightNodeCapacity(self: *Self, allocator: std.mem.Allocator, capacity: usize) std.mem.Allocator.Error!void {
            try self.nodes.ensureTotalCapacity(allocator, capacity);
        }

        /// Reserves one active parent's final child-list capacity without changing its contents.
        pub fn preflightChildCapacity(self: *Self, allocator: std.mem.Allocator, parent_elem_id: u64, capacity: usize) (std.mem.Allocator.Error || error{MissingParent})!void {
            const index = std.math.cast(usize, parent_elem_id) orelse return error.MissingParent;
            if (index >= self.nodes.items.len or !self.nodes.items[index].active) return error.MissingParent;
            try self.nodes.items[index].children.ensureTotalCapacity(allocator, capacity);
        }

        /// Ensures node capacity or traps at the legacy infallible boundary.
        pub fn ensureNodeCapacity(self: *Self, ctx: Ctx.Handle, capacity: usize) void {
            self.preflightNodeCapacity(Ctx.allocator(ctx), capacity) catch @panic("out of memory");
        }

        /// Reports whether active node is present in maintained state.
        pub fn hasActiveNode(self: *const Self, elem_id: u64) bool {
            const index: usize = @intCast(elem_id);
            return index < self.nodes.items.len and self.nodes.items[index].active;
        }

        /// Returns active node tag differs from the maintained active-runtime indexes.
        pub fn activeNodeTagDiffers(self: *const Self, elem_id: u64, tag: []const u8) bool {
            const index: usize = @intCast(elem_id);
            if (index >= self.nodes.items.len) return false;
            const node = &self.nodes.items[index];
            if (!node.active) return false;
            return node.tag == null or !std.mem.eql(u8, node.tag.?, tag);
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

        fn ensureCacheNode(self: *Self, ctx: Ctx.Handle, elem_id: u64, tag: []const u8) bool {
            const allocator = Ctx.allocator(ctx);
            const index: usize = @intCast(elem_id);
            while (index > self.nodes.items.len) {
                self.nodes.append(allocator, .{}) catch @panic("out of memory");
            }
            if (index == self.nodes.items.len) {
                self.nodes.append(allocator, ScalarNode.initActive(self.internTag(allocator, tag))) catch @panic("out of memory");
                return true;
            }
            const node = &self.nodes.items[index];
            if (!node.active) {
                node.* = ScalarNode.initActive(self.internTag(allocator, tag));
                return true;
            }
            if (node.tag == null or !std.mem.eql(u8, node.tag.?, tag)) {
                var message: [160]u8 = undefined;
                const rendered = std.fmt.bufPrint(
                    &message,
                    "render descriptor changed tag for elem {d}: cache '{s}', stream '{s}'",
                    .{ elem_id, node.tag orelse "<null>", tag },
                ) catch "render descriptor changed the tag for an existing render cache identity";
                @panic(rendered);
            }
            return false;
        }

        /// Emits the already-decided command that attaches a newly created render node.
        pub fn appendNode(self: *Self, ctx: Ctx.Handle, elem_id: u64, parent_elem_id: u64, tag: []const u8) void {
            const created = self.ensureCacheNode(ctx, elem_id, tag);
            if (!created) @panic("initial render append reused an existing render cache identity");
            const parent = self.activeNode(parent_elem_id);
            const child = self.activeNode(elem_id);
            child.parent_id = parent_elem_id;
            parent.children.append(Ctx.allocator(ctx), elem_id) catch @panic("out of memory");
            Ctx.sink(ctx).appendNode(elem_id, parent_elem_id, tag);
        }

        /// Ensures the host render surface contains the engine-selected node and tag.
        pub fn ensureNode(self: *Self, ctx: Ctx.Handle, elem_id: u64, tag: []const u8, counts: *render.Counts) void {
            if (!self.ensureCacheNode(ctx, elem_id, tag)) return;
            Ctx.sink(ctx).ensureNode(elem_id, tag);
            counts.addCreateElement();
        }

        /// Emits removal of a node whose owning scope has already been disposed by the engine.
        pub fn removeNode(self: *Self, ctx: Ctx.Handle, elem_id: u64, counts: *render.Counts) void {
            const allocator = Ctx.allocator(ctx);
            const index: usize = @intCast(elem_id);
            if (index >= self.nodes.items.len or !self.nodes.items[index].active) {
                @panic("render cache removed a missing element");
            }
            if (elem_id == 0) @panic("render cache attempted to remove the host DOM root");

            if (self.nodes.items[index].parent_id) |parent_id| {
                const parent_index: usize = @intCast(parent_id);
                if (parent_index < self.nodes.items.len and self.nodes.items[parent_index].active) {
                    const parent = &self.nodes.items[parent_index];
                    if (u64SliceIndex(parent.children.items, elem_id)) |child_index| {
                        _ = parent.children.orderedRemove(child_index);
                    }
                }
            }
            Ctx.sink(ctx).removeNode(elem_id);
            self.deactivateSubtree(allocator, elem_id);
            counts.addRemoveNode();
        }

        fn deactivateSubtree(self: *Self, allocator: std.mem.Allocator, elem_id: u64) void {
            const index: usize = @intCast(elem_id);
            if (index >= self.nodes.items.len or !self.nodes.items[index].active) return;

            const child_ids = allocator.dupe(u64, self.nodes.items[index].children.items) catch @panic("out of memory");
            defer allocator.free(child_ids);
            for (child_ids) |child_id| {
                self.deactivateSubtree(allocator, child_id);
            }
            self.nodes.items[index].deinit(allocator);
        }

        /// Returns active node from the maintained active-runtime indexes.
        pub fn activeNode(self: *Self, elem_id: u64) *ScalarNode {
            const index: usize = @intCast(elem_id);
            if (index >= self.nodes.items.len or !self.nodes.items[index].active) {
                @panic("render command referenced missing element cache");
            }
            return &self.nodes.items[index];
        }

        /// Returns the owned name for an indexed named-event cache entry.
        pub fn namedEventNameAt(self: *Self, elem_id: u64, index: usize) ?[]const u8 {
            const events = self.activeNode(elem_id).named_events.items;
            if (index >= events.len) return null;
            return events[index].name;
        }

        /// Returns the owned name for an indexed custom-attribute cache entry.
        pub fn customTextAttrNameAt(self: *Self, elem_id: u64, index: usize) ?[]const u8 {
            const attrs = self.activeNode(elem_id).custom_text_attrs.items;
            if (index >= attrs.len) return null;
            return attrs[index].name;
        }

        /// Publishes the engine-selected child order for one parent.
        pub fn replaceChildren(self: *Self, ctx: Ctx.Handle, parent_elem_id: u64, next_child_ids: []const u64, counts: *render.Counts) void {
            const allocator = Ctx.allocator(ctx);
            const parent = self.activeNode(parent_elem_id);

            for (next_child_ids, 0..) |child_id, new_index| {
                const child = self.activeNode(child_id);
                const old_parent_id = child.parent_id;
                const old_child_index = if (old_parent_id) |id| u64SliceIndex(self.activeNode(id).children.items, child_id) else null;

                if (old_parent_id == null or old_parent_id.? != parent_elem_id or old_child_index == null) {
                    counts.addAppendChild();
                } else if (old_child_index.? != new_index) {
                    counts.addMoveBefore();
                }
                child.parent_id = parent_elem_id;
            }

            parent.children.deinit(allocator);
            parent.children = .empty;
            parent.children.appendSlice(allocator, next_child_ids) catch @panic("out of memory");
            Ctx.sink(ctx).replaceChildren(parent_elem_id, next_child_ids);
        }

        /// Publishes a moves-only child reorder without rebuilding surviving row structure.
        pub fn replaceChildrenForMoves(self: *Self, ctx: Ctx.Handle, parent_elem_id: u64, next_child_ids: []const u64, counts: *render.Counts) void {
            const allocator = Ctx.allocator(ctx);
            const parent = self.activeNode(parent_elem_id);
            if (parent.children.items.len != next_child_ids.len) @panic("pure structural move changed child count");

            const old_child_indexes = &self.move_child_indexes;
            old_child_indexes.clearRetainingCapacity();
            defer old_child_indexes.clearRetainingCapacity();
            for (parent.children.items, 0..) |child_id, index| {
                const entry = old_child_indexes.getOrPut(allocator, child_id) catch @panic("out of memory");
                if (entry.found_existing) @panic("parent child list contained duplicate element ids");
                entry.value_ptr.* = index;
            }

            self.move_old_indexes.resize(allocator, next_child_ids.len) catch @panic("out of memory");
            defer self.move_old_indexes.clearRetainingCapacity();
            const old_indexes_in_next_order = self.move_old_indexes.items;
            for (next_child_ids, 0..) |child_id, index| {
                const child = self.activeNode(child_id);
                if (child.parent_id == null or child.parent_id.? != parent_elem_id) @panic("pure structural move crossed parent boundary");
                old_indexes_in_next_order[index] = old_child_indexes.get(child_id) orelse @panic("pure structural move inserted a child");
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
        pub fn applyEventBinding(self: *Self, ctx: Ctx.Handle, elem_id: u64, kind: EventKind, binding: ?EventBinding, counts: *render.Counts) void {
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
        pub fn applyNamedEventBinding(self: *Self, ctx: Ctx.Handle, elem_id: u64, name: []const u8, binding: ?EventBinding, counts: *render.Counts) void {
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
                    @intCast(index),
                    cached.active,
                    cached.tag,
                    cached.parent_id,
                    cached.children.items,
                    cached.fixedEventId(.click),
                    cached.fixedEventId(.input),
                    cached.fixedEventId(.check),
                    cached.fixedEventId(.pointer_down),
                    cached.fixedEventId(.pointer_up),
                    cached.fixedEventId(.pointer_enter),
                    cached.fixedEventId(.pointer_leave),
                );
            }
        }

        /// Applies an engine-decided text field value to one render node.
        pub fn applyTextField(self: *Self, ctx: Ctx.Handle, elem_id: u64, field: TextField, value: []const u8) bool {
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
        pub fn applyTextAttr(self: *Self, ctx: Ctx.Handle, elem_id: u64, name: []const u8, value: []const u8) bool {
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
        pub fn applyBoolField(self: *Self, ctx: Ctx.Handle, elem_id: u64, field: BoolField, value: bool) bool {
            const slot = self.activeNode(elem_id).boolSlot(field);
            if (slot.*) |existing| {
                if (existing == value) return false;
            }

            slot.* = value;
            Ctx.sink(ctx).applyBoolField(elem_id, field, value);
            return true;
        }

        /// Clears an engine-decided text field from one render node.
        pub fn clearTextField(self: *Self, ctx: Ctx.Handle, elem_id: u64, field: TextField) bool {
            const allocator = Ctx.allocator(ctx);
            const slot = self.activeNode(elem_id).textSlot(field);
            const existing = slot.* orelse return false;
            allocator.free(existing);
            slot.* = null;
            Ctx.sink(ctx).clearTextField(elem_id, field);
            return true;
        }

        /// Clears an engine-decided custom text attribute from one render node.
        pub fn clearTextAttr(self: *Self, ctx: Ctx.Handle, elem_id: u64, name: []const u8) bool {
            const allocator = Ctx.allocator(ctx);
            const node = self.activeNode(elem_id);
            const index = node.customTextAttrIndex(name) orelse return false;
            const removed = node.custom_text_attrs.orderedRemove(index);
            Ctx.sink(ctx).clearTextAttr(elem_id, removed.name);
            removed.deinit(allocator);
            return true;
        }

        /// Clears an engine-decided boolean field from one render node.
        pub fn clearBoolField(self: *Self, ctx: Ctx.Handle, elem_id: u64, field: BoolField) bool {
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
    pub fn appendNode(_: TestSink, _: u64, _: u64, _: []const u8) void {}
    /// Ensures the host render surface contains the engine-selected node and tag.
    pub fn ensureNode(_: TestSink, _: u64, _: []const u8) void {}
    /// Emits removal of a node whose owning scope has already been disposed by the engine.
    pub fn removeNode(_: TestSink, _: u64) void {}
    /// Publishes the engine-selected child order for one parent.
    pub fn replaceChildren(_: TestSink, _: u64, _: []const u64) void {}
    /// Publishes a moves-only child reorder without rebuilding surviving row structure.
    pub fn replaceChildrenForMoves(_: TestSink, _: u64, _: []const u64) void {}
    /// Applies an engine-decided text field value to one render node.
    pub fn applyTextField(self: TestSink, _: u64, _: TextField, _: []const u8) void {
        self.host.apply_text_field_count += 1;
    }
    /// Applies an engine-decided custom text attribute to one render node.
    pub fn applyTextAttr(self: TestSink, _: u64, _: []const u8, _: []const u8) void {
        self.host.apply_text_attr_count += 1;
    }
    /// Applies an engine-decided boolean field value to one render node.
    pub fn applyBoolField(_: TestSink, _: u64, _: BoolField, _: bool) void {}
    /// Clears an engine-decided text field from one render node.
    pub fn clearTextField(_: TestSink, _: u64, _: TextField) void {}
    /// Clears an engine-decided custom text attribute from one render node.
    pub fn clearTextAttr(self: TestSink, _: u64, _: []const u8) void {
        self.host.clear_text_attr_count += 1;
    }
    /// Clears an engine-decided boolean field from one render node.
    pub fn clearBoolField(_: TestSink, _: u64, _: BoolField) void {}
    /// Publishes a validated canonical event binding selected by the engine.
    pub fn bindEvent(self: TestSink, _: u64, key: EventBindingKey, binding: EventBinding) void {
        self.host.last_event_binding = binding;
        switch (key) {
            .fixed => self.host.bind_event_count += 1,
            .named => self.host.bind_named_event_count += 1,
        }
    }
    /// Removes a host event registration whose engine-owned binding is no longer active.
    pub fn clearEvent(self: TestSink, _: u64, key: EventBindingKey) void {
        switch (key) {
            .fixed => self.host.clear_event_count += 1,
            .named => self.host.clear_named_event_count += 1,
        }
    }
    /// Checks that the host render surface matches the engine's committed node metadata.
    pub fn debugAssertNode(_: TestSink, _: u64, _: bool, _: ?[]const u8, _: ?u64, _: []const u64, _: ?u64, _: ?u64, _: ?u64, _: ?u64, _: ?u64, _: ?u64, _: ?u64) void {}
};

test "applying unchanged text field emits no duplicate command" {
    var host = TestHost{};
    var cache: Cache(TestCtx) = .{};
    defer cache.deinit(&host);

    cache.reset(&host);
    var counts: render.Counts = .{};
    cache.ensureNode(&host, 1, "div", &counts);

    try std.testing.expect(cache.applyTextField(&host, 1, .text, "hello"));
    try std.testing.expect(!cache.applyTextField(&host, 1, .text, "hello"));
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
    try std.testing.expectError(error.OutOfMemory, cache.preflightChildCapacity(allocator, 0, 16));
    try std.testing.expectEqual(@as(usize, 1), cache.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 0), cache.nodes.items[0].children.items.len);

    fault.configure(null);
    try cache.preflightChildCapacity(allocator, 0, 16);
    fault.configure(1);
    cache.nodes.items[0].children.appendAssumeCapacity(7);
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqualSlices(u64, &.{7}, cache.nodes.items[0].children.items);
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
    try cache.nodes.items[0].children.appendSlice(allocator, &.{ 1, 2 });

    fault.configure(1);
    try std.testing.expectError(error.OutOfMemory, PreparedChildrenReplacement.prepare(TestCtx, allocator, &cache, 0, &.{ 2, 3 }));
    try std.testing.expectEqualSlices(u64, &.{ 1, 2 }, cache.nodes.items[0].children.items);

    fault.configure(null);
    var aborted = try PreparedChildrenReplacement.prepare(TestCtx, allocator, &cache, 0, &.{ 2, 3 });
    aborted.deinit(allocator);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2 }, cache.nodes.items[0].children.items);

    var committed = try PreparedChildrenReplacement.prepare(TestCtx, allocator, &cache, 0, &.{ 2, 3 });
    fault.configure(1);
    committed.apply(TestCtx, &cache);
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqualSlices(u64, &.{ 2, 3 }, cache.nodes.items[0].children.items);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2 }, committed.retired.items);
    fault.configure(null);
    committed.deinit(allocator);
}

test "render cache reset accepts sparse element ids" {
    var host = TestHost{};
    var cache: Cache(TestCtx) = .{};
    defer cache.deinit(&host);

    cache.reset(&host);
    var counts: render.Counts = .{};
    cache.ensureNode(&host, 3, "div", &counts);

    try std.testing.expectEqual(@as(usize, 4), cache.nodes.items.len);
    try std.testing.expect(!cache.nodes.items[1].active);
    try std.testing.expect(!cache.nodes.items[2].active);
    try std.testing.expect(cache.nodes.items[3].active);
    try std.testing.expectEqual(@as(u64, 1), counts.create_element);
}

test "removed cache slot can be recreated with a different tag" {
    var host = TestHost{};
    var cache: Cache(TestCtx) = .{};
    defer cache.deinit(&host);

    cache.reset(&host);
    var counts: render.Counts = .{};
    cache.ensureNode(&host, 1, "text", &counts);
    try std.testing.expect(!cache.activeNodeTagDiffers(1, "text"));
    try std.testing.expect(cache.activeNodeTagDiffers(1, "div"));
    try std.testing.expect(cache.applyTextField(&host, 1, .text, "stale"));

    cache.removeNode(&host, 1, &counts);
    try std.testing.expect(!cache.activeNodeTagDiffers(1, "div"));

    cache.ensureNode(&host, 1, "div", &counts);
    const node = cache.activeNode(1);
    try std.testing.expectEqualStrings("div", node.tag.?);
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
    cache.ensureNode(&host, 1, "div", &counts);
    cache.ensureNode(&host, 2, "div", &counts);
    cache.ensureNode(&host, 3, "div", &counts);
    cache.replaceChildren(&host, 0, &.{ 1, 2, 3 }, &counts);

    counts = .{};
    cache.replaceChildrenForMoves(&host, 0, &.{ 2, 1, 3 }, &counts);

    try std.testing.expectEqual(@as(u64, 1), counts.move_before);
    try std.testing.expectEqual(@as(u64, 1), counts.total);
}

test "unchanged event binding emits no duplicate command" {
    var host = TestHost{};
    var cache: Cache(TestCtx) = .{};
    defer cache.deinit(&host);

    cache.reset(&host);
    var counts: render.Counts = .{};
    cache.ensureNode(&host, 1, "button", &counts);

    const binding = EventBinding{ .event_id = 1, .payload_descriptor = BoundaryPayloadDescriptor.init(.unit, .none) };
    cache.applyEventBinding(&host, 1, .click, binding, &counts);
    cache.applyEventBinding(&host, 1, .click, binding, &counts);
    try std.testing.expectEqual(@as(u64, 1), counts.bind_event);
    try std.testing.expectEqual(@as(u64, 1), host.bind_event_count);

    cache.applyEventBinding(&host, 1, .click, null, &counts);
    cache.applyEventBinding(&host, 1, .click, null, &counts);
    try std.testing.expectEqual(@as(u64, 2), counts.bind_event);
    try std.testing.expectEqual(@as(u64, 1), host.clear_event_count);
}

test "event binding slots are keyed by event kind" {
    var bindings = EventBindings{};
    const click = EventBinding{ .event_id = 1, .payload_descriptor = BoundaryPayloadDescriptor.init(.unit, .none) };
    const input = EventBinding{ .event_id = 2, .payload_descriptor = BoundaryPayloadDescriptor.init(.str, .target_value) };
    const pointer_down = EventBinding{ .event_id = 3, .payload_descriptor = BoundaryPayloadDescriptor.init(.bool, .target_checked) };

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
    cache.ensureNode(&host, 1, "button", &counts);
    cache.ensureNode(&host, 2, "form", &counts);

    const fixed = EventBinding{
        .event_id = 1,
        .payload_descriptor = BoundaryPayloadDescriptor.init(.unit, .none),
    };
    cache.applyEventBinding(&host, 1, .pointer_down, fixed, &counts);
    const fixed_delivery = cache.activeNode(1).event_bindings.pointer_down.?.delivery;
    try std.testing.expectEqual(render_sink.EventDeliveryRequest.auto, fixed_delivery.requested);
    try std.testing.expectEqual(render_sink.EventDeliveryEffective.native, fixed_delivery.effective);
    try std.testing.expectEqual(render_sink.EventDeliveryReason.pointer_drag, fixed_delivery.reason);
    try std.testing.expectEqual(render_sink.EventDeliveryReason.pointer_drag, host.last_event_binding.?.delivery.reason);

    const named = EventBinding{
        .event_id = 2,
        .policy = render.EventPolicy.fromBits(render.listener_option_capture),
        .payload_descriptor = BoundaryPayloadDescriptor.init(.unit, .none),
    };
    cache.applyNamedEventBinding(&host, 2, "focus", named, &counts);
    const named_delivery = cache.activeNode(2).named_events.items[0].binding.delivery;
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
    cache.ensureNode(&host, 1, "div", &counts);

    try std.testing.expect(cache.applyTextAttr(&host, 1, "data-x", "a"));
    try std.testing.expect(!cache.applyTextAttr(&host, 1, "data-x", "a"));
    try std.testing.expect(cache.applyTextAttr(&host, 1, "data-x", "b"));
    try std.testing.expectEqual(@as(u64, 2), host.apply_text_attr_count);

    try std.testing.expect(!cache.clearTextAttr(&host, 1, "data-missing"));
    try std.testing.expect(cache.clearTextAttr(&host, 1, "data-x"));
    try std.testing.expect(!cache.clearTextAttr(&host, 1, "data-x"));
    try std.testing.expectEqual(@as(u64, 1), host.clear_text_attr_count);
}

test "named event replacement and clear are idempotent" {
    var host = TestHost{};
    var cache: Cache(TestCtx) = .{};
    defer cache.deinit(&host);

    cache.reset(&host);
    var counts: render.Counts = .{};
    cache.ensureNode(&host, 1, "form", &counts);

    const first = EventBinding{
        .event_id = 1,
        .payload_descriptor = BoundaryPayloadDescriptor.init(.unit, .none),
    };
    const second = EventBinding{
        .event_id = 2,
        .policy = render.EventPolicy.fromBits(render.listener_option_prevent_default),
        .payload_descriptor = BoundaryPayloadDescriptor.init(.str, .target_value),
    };

    cache.applyNamedEventBinding(&host, 1, "submit", first, &counts);
    cache.applyNamedEventBinding(&host, 1, "submit", first, &counts);
    try std.testing.expectEqualStrings("submit", cache.namedEventNameAt(1, 0).?);

    cache.applyNamedEventBinding(&host, 1, "submit", second, &counts);
    try std.testing.expectEqual(@as(u64, 2), host.bind_named_event_count);
    try std.testing.expectEqual(@as(u64, 2), counts.bind_event);

    cache.applyNamedEventBinding(&host, 1, "submit", null, &counts);
    cache.applyNamedEventBinding(&host, 1, "submit", null, &counts);
    try std.testing.expectEqual(@as(u64, 1), host.clear_named_event_count);
    try std.testing.expectEqual(@as(u64, 3), counts.bind_event);
}
