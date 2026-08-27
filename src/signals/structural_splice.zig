//! Structural patch planning for replacing disposed scopes or keyed rows.

const std = @import("std");
const descriptor_stream = @import("descriptor_stream.zig");
const scope_runtime = @import("scope_runtime.zig");

pub const EachSite = scope_runtime.EachSite;

pub const ReplacementTarget = union(enum) {
    scope: u64,
    each_site: EachSite,
};

pub const PatchTargets = struct {
    removed: ReplacementTarget,
    replacement: ReplacementTarget,
};

pub const Splice = struct {
    removed_elem_ids: []u64,
    touched_parent_ids: []u64,
    replacement_elem_ids: []u64,
    moved_event_elem_ids: []u64,
    replacement_on_change_indices: []usize,
    replacement_mount_indices: []usize,

    /// Releases every resource owned by this value and leaves no retained host or Roc ownership behind.
    pub fn deinit(self: Splice, allocator: std.mem.Allocator) void {
        allocator.free(self.removed_elem_ids);
        allocator.free(self.touched_parent_ids);
        allocator.free(self.replacement_elem_ids);
        allocator.free(self.moved_event_elem_ids);
        allocator.free(self.replacement_on_change_indices);
        allocator.free(self.replacement_mount_indices);
    }
};

pub const SpliceAndTargets = struct {
    splice: Splice,
    targets: PatchTargets,
};

pub const RenderRemovalScan = struct {
    removed_elem_ids: []u64,
    touched_parent_ids: []u64,
    removed_render_count: usize,
    target_scan_count: usize,

    /// Releases every resource owned by this value and leaves no retained host or Roc ownership behind.
    pub fn deinit(self: RenderRemovalScan, allocator: std.mem.Allocator) void {
        allocator.free(self.removed_elem_ids);
        allocator.free(self.touched_parent_ids);
    }
};

pub const PreparedRemoval = struct {
    scan: RenderRemovalScan,
    descriptor_indexes: ElemOwnedRemovalScratch,

    /// Releases all provisional removal metadata without touching the source stream.
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.descriptor_indexes.deinit(allocator);
        self.scan.deinit(allocator);
        self.* = undefined;
    }
};

pub const ElemOwnedRemovalScratch = struct {
    element_indexes: std.ArrayListUnmanaged(usize) = .empty,
    text_node_indexes: std.ArrayListUnmanaged(usize) = .empty,
    signal_text_node_indexes: std.ArrayListUnmanaged(usize) = .empty,
    static_text_attr_indexes: std.ArrayListUnmanaged(usize) = .empty,
    signal_text_attr_indexes: std.ArrayListUnmanaged(usize) = .empty,
    static_bool_attr_indexes: std.ArrayListUnmanaged(usize) = .empty,
    signal_bool_attr_indexes: std.ArrayListUnmanaged(usize) = .empty,
    event_indexes: std.ArrayListUnmanaged(usize) = .empty,

    /// Releases every resource owned by this value and leaves no retained host or Roc ownership behind.
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.element_indexes.deinit(allocator);
        self.text_node_indexes.deinit(allocator);
        self.signal_text_node_indexes.deinit(allocator);
        self.static_text_attr_indexes.deinit(allocator);
        self.signal_text_attr_indexes.deinit(allocator);
        self.static_bool_attr_indexes.deinit(allocator);
        self.signal_bool_attr_indexes.deinit(allocator);
        self.event_indexes.deinit(allocator);
        self.* = .{};
    }

    /// Asserts that a splice plan owns no pending actions or provisional resources.
    pub fn assertEmpty(self: *const @This()) void {
        if (self.element_indexes.items.len != 0 or
            self.text_node_indexes.items.len != 0 or
            self.signal_text_node_indexes.items.len != 0 or
            self.static_text_attr_indexes.items.len != 0 or
            self.signal_text_attr_indexes.items.len != 0 or
            self.static_bool_attr_indexes.items.len != 0 or
            self.signal_bool_attr_indexes.items.len != 0 or
            self.event_indexes.items.len != 0)
        {
            @panic("elem-owned removal scratch was already active");
        }
    }

    /// Drops live entries while retaining allocated capacity for bounded reuse.
    pub fn clearRetainingCapacity(self: *@This()) void {
        self.element_indexes.clearRetainingCapacity();
        self.text_node_indexes.clearRetainingCapacity();
        self.signal_text_node_indexes.clearRetainingCapacity();
        self.static_text_attr_indexes.clearRetainingCapacity();
        self.signal_text_attr_indexes.clearRetainingCapacity();
        self.static_bool_attr_indexes.clearRetainingCapacity();
        self.signal_bool_attr_indexes.clearRetainingCapacity();
        self.event_indexes.clearRetainingCapacity();
    }

    /// Reserves the worst-case descriptor-index footprint for `additional`
    /// elements without changing any logical scratch length.
    pub fn prepare(self: *@This(), allocator: std.mem.Allocator, additional: usize) std.mem.Allocator.Error!void {
        const text_fields = std.math.mul(usize, additional, 6) catch return error.OutOfMemory;
        const bool_fields = std.math.mul(usize, additional, 2) catch return error.OutOfMemory;
        const events = std.math.mul(usize, additional, 7) catch return error.OutOfMemory;
        try self.element_indexes.ensureUnusedCapacity(allocator, additional);
        try self.text_node_indexes.ensureUnusedCapacity(allocator, additional);
        try self.signal_text_node_indexes.ensureUnusedCapacity(allocator, additional);
        try self.static_text_attr_indexes.ensureUnusedCapacity(allocator, text_fields);
        try self.signal_text_attr_indexes.ensureUnusedCapacity(allocator, text_fields);
        try self.static_bool_attr_indexes.ensureUnusedCapacity(allocator, bool_fields);
        try self.signal_bool_attr_indexes.ensureUnusedCapacity(allocator, bool_fields);
        try self.event_indexes.ensureUnusedCapacity(allocator, events);
    }

    /// Records descriptor indexes without allocating. `prepare` must have
    /// reserved capacity for every element in the transaction first.
    pub fn appendDescriptorIndexesAssumeCapacity(self: *@This(), descriptor_index: anytype) void {
        appendRemovalIndexAssumeCapacity(&self.element_indexes, descriptorIndexValue(descriptor_index.element));
        appendRemovalIndexAssumeCapacity(&self.text_node_indexes, descriptorIndexValue(descriptor_index.text_node));
        appendRemovalIndexAssumeCapacity(&self.signal_text_node_indexes, descriptorIndexValue(descriptor_index.signal_text_node));
        appendTextFieldRemovalIndexesAssumeCapacity(&self.static_text_attr_indexes, descriptor_index.static_text_attrs);
        appendTextFieldRemovalIndexesAssumeCapacity(&self.signal_text_attr_indexes, descriptor_index.signal_text_attrs);
        appendBoolFieldRemovalIndexesAssumeCapacity(&self.static_bool_attr_indexes, descriptor_index.static_bool_attrs);
        appendBoolFieldRemovalIndexesAssumeCapacity(&self.signal_bool_attr_indexes, descriptor_index.signal_bool_attrs);
        appendEventRemovalIndexesAssumeCapacity(&self.event_indexes, descriptor_index.events);
    }

    /// Appends descriptor indexes using capacity that must already satisfy the caller's transaction contract.
    pub fn appendDescriptorIndexes(self: *@This(), allocator: std.mem.Allocator, descriptor_index: anytype) void {
        appendRemovalIndex(allocator, &self.element_indexes, descriptorIndexValue(descriptor_index.element));
        appendRemovalIndex(allocator, &self.text_node_indexes, descriptorIndexValue(descriptor_index.text_node));
        appendRemovalIndex(allocator, &self.signal_text_node_indexes, descriptorIndexValue(descriptor_index.signal_text_node));
        appendTextFieldRemovalIndexes(allocator, &self.static_text_attr_indexes, descriptor_index.static_text_attrs);
        appendTextFieldRemovalIndexes(allocator, &self.signal_text_attr_indexes, descriptor_index.signal_text_attrs);
        appendBoolFieldRemovalIndexes(allocator, &self.static_bool_attr_indexes, descriptor_index.static_bool_attrs);
        appendBoolFieldRemovalIndexes(allocator, &self.signal_bool_attr_indexes, descriptor_index.signal_bool_attrs);
        appendEventRemovalIndexes(allocator, &self.event_indexes, descriptor_index.events);
    }

    /// Orders removal indexes from highest to lowest so earlier positions remain valid during mutation.
    pub fn sortDescending(self: *@This()) void {
        sortRemovalIndexesDescending(self.element_indexes.items);
        sortRemovalIndexesDescending(self.text_node_indexes.items);
        sortRemovalIndexesDescending(self.signal_text_node_indexes.items);
        sortRemovalIndexesDescending(self.static_text_attr_indexes.items);
        sortRemovalIndexesDescending(self.signal_text_attr_indexes.items);
        sortRemovalIndexesDescending(self.static_bool_attr_indexes.items);
        sortRemovalIndexesDescending(self.signal_bool_attr_indexes.items);
        sortRemovalIndexesDescending(self.event_indexes.items);
    }
};

/// Evaluates scope is in target set using explicit scope ownership rather than DOM position or content.
pub fn scopeIsInTargetSet(target_scopes: []const bool, scope_id: u64) bool {
    if (scope_id >= target_scopes.len) @panic("descriptor referenced scope outside replacement target set");
    return target_scopes[@intCast(scope_id)];
}

fn removalIndexDesc(_: void, lhs: usize, rhs: usize) bool {
    return lhs > rhs;
}

/// Orders removal indexes from highest to lowest so earlier positions remain valid during mutation.
pub fn sortRemovalIndexesDescending(indexes: []usize) void {
    std.mem.sort(usize, indexes, {}, removalIndexDesc);
}

/// Appends removal index using capacity that must already satisfy the caller's transaction contract.
pub fn appendRemovalIndex(allocator: std.mem.Allocator, indexes: *std.ArrayListUnmanaged(usize), index: ?usize) void {
    indexes.append(allocator, index orelse return) catch @panic("out of memory");
}

fn appendRemovalIndexAssumeCapacity(indexes: *std.ArrayListUnmanaged(usize), index: ?usize) void {
    indexes.appendAssumeCapacity(index orelse return);
}

fn appendTextFieldRemovalIndexesAssumeCapacity(indexes: *std.ArrayListUnmanaged(usize), fields: anytype) void {
    appendRemovalIndexAssumeCapacity(indexes, descriptorIndexValue(fields.text));
    appendRemovalIndexAssumeCapacity(indexes, descriptorIndexValue(fields.role));
    appendRemovalIndexAssumeCapacity(indexes, descriptorIndexValue(fields.label));
    appendRemovalIndexAssumeCapacity(indexes, descriptorIndexValue(fields.test_id));
    appendRemovalIndexAssumeCapacity(indexes, descriptorIndexValue(fields.value));
    appendRemovalIndexAssumeCapacity(indexes, descriptorIndexValue(fields.class));
}

fn appendBoolFieldRemovalIndexesAssumeCapacity(indexes: *std.ArrayListUnmanaged(usize), fields: anytype) void {
    appendRemovalIndexAssumeCapacity(indexes, descriptorIndexValue(fields.checked));
    appendRemovalIndexAssumeCapacity(indexes, descriptorIndexValue(fields.disabled));
}

fn appendEventRemovalIndexesAssumeCapacity(indexes: *std.ArrayListUnmanaged(usize), events: anytype) void {
    appendRemovalIndexAssumeCapacity(indexes, descriptorIndexValue(events.click));
    appendRemovalIndexAssumeCapacity(indexes, descriptorIndexValue(events.input));
    appendRemovalIndexAssumeCapacity(indexes, descriptorIndexValue(events.check));
    appendRemovalIndexAssumeCapacity(indexes, descriptorIndexValue(events.pointer_down));
    appendRemovalIndexAssumeCapacity(indexes, descriptorIndexValue(events.pointer_up));
    appendRemovalIndexAssumeCapacity(indexes, descriptorIndexValue(events.pointer_enter));
    appendRemovalIndexAssumeCapacity(indexes, descriptorIndexValue(events.pointer_leave));
}

fn descriptorIndexValue(index: anytype) ?usize {
    if (@TypeOf(index) == descriptor_stream.DescriptorIndex) return index.get();
    return index;
}

/// Appends text field removal indexes using capacity that must already satisfy the caller's transaction contract.
pub fn appendTextFieldRemovalIndexes(allocator: std.mem.Allocator, indexes: *std.ArrayListUnmanaged(usize), fields: anytype) void {
    appendRemovalIndex(allocator, indexes, descriptorIndexValue(fields.text));
    appendRemovalIndex(allocator, indexes, descriptorIndexValue(fields.role));
    appendRemovalIndex(allocator, indexes, descriptorIndexValue(fields.label));
    appendRemovalIndex(allocator, indexes, descriptorIndexValue(fields.test_id));
    appendRemovalIndex(allocator, indexes, descriptorIndexValue(fields.value));
    appendRemovalIndex(allocator, indexes, descriptorIndexValue(fields.class));
}

/// Appends bool field removal indexes using capacity that must already satisfy the caller's transaction contract.
pub fn appendBoolFieldRemovalIndexes(allocator: std.mem.Allocator, indexes: *std.ArrayListUnmanaged(usize), fields: anytype) void {
    appendRemovalIndex(allocator, indexes, descriptorIndexValue(fields.checked));
    appendRemovalIndex(allocator, indexes, descriptorIndexValue(fields.disabled));
}

/// Appends event removal indexes using capacity that must already satisfy the caller's transaction contract.
pub fn appendEventRemovalIndexes(allocator: std.mem.Allocator, indexes: *std.ArrayListUnmanaged(usize), events: anytype) void {
    appendRemovalIndex(allocator, indexes, descriptorIndexValue(events.click));
    appendRemovalIndex(allocator, indexes, descriptorIndexValue(events.input));
    appendRemovalIndex(allocator, indexes, descriptorIndexValue(events.check));
    appendRemovalIndex(allocator, indexes, descriptorIndexValue(events.pointer_down));
    appendRemovalIndex(allocator, indexes, descriptorIndexValue(events.pointer_up));
    appendRemovalIndex(allocator, indexes, descriptorIndexValue(events.pointer_enter));
    appendRemovalIndex(allocator, indexes, descriptorIndexValue(events.pointer_leave));
}

/// Builds target scope set from validated descriptors without introducing host-specific semantics.
pub fn buildTargetScopeSet(comptime Scope: type, allocator: std.mem.Allocator, scratch: *std.ArrayListUnmanaged(bool), scopes: []const Scope, target: ReplacementTarget, lookup: anytype) []const bool {
    if (scratch.items.len != 0) @panic("replacement target scope scratch was already active");
    scratch.resize(allocator, scopes.len) catch @panic("out of memory");
    const target_scopes = scratch.items;
    for (scopes) |scope| {
        if (scope.scope_id >= target_scopes.len) @panic("scope descriptor id exceeded replacement target set");
        target_scopes[@intCast(scope.scope_id)] = lookup.scopeIsInTarget(scope.scope_id, target);
    }
    return target_scopes;
}

/// Prepares a render-removal snapshot without mutating the source stream.
pub fn prepareRenderRemovalScan(comptime Stream: type, allocator: std.mem.Allocator, stream: *const Stream, render_insert_index: usize, target_scopes: []const bool) std.mem.Allocator.Error!RenderRemovalScan {
    if (render_insert_index > stream.render_nodes.items.len) @panic("structural replacement render insertion point is outside the active stream");

    var removed_elem_ids: std.ArrayListUnmanaged(u64) = .empty;
    errdefer removed_elem_ids.deinit(allocator);
    var removed_elem_set: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer removed_elem_set.deinit(allocator);
    var touched_parent_ids: std.ArrayListUnmanaged(u64) = .empty;
    errdefer touched_parent_ids.deinit(allocator);
    var touched_parent_set: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer touched_parent_set.deinit(allocator);

    var removed_render_count: usize = 0;
    var target_scan_count: usize = 0;
    var render_index = render_insert_index;
    while (render_index < stream.render_nodes.items.len) : (render_index += 1) {
        const node = stream.render_nodes.items[render_index];
        const parent_elem_id = descriptor_stream.renderNodeParentElemId(Stream, stream, node);
        target_scan_count += 1;
        const scope_in_target = scopeIsInTargetSet(target_scopes, descriptor_stream.renderNodeScopeId(Stream, stream, node));
        const parent_removed = removed_elem_set.contains(parent_elem_id);
        if (!scope_in_target and !parent_removed) break;
        removed_render_count += 1;
        try removed_elem_ids.append(allocator, node.elem_id);
        try removed_elem_set.put(allocator, node.elem_id, {});
        const touched_entry = try touched_parent_set.getOrPut(allocator, parent_elem_id);
        if (!touched_entry.found_existing) try touched_parent_ids.append(allocator, parent_elem_id);
    }

    var touched_parent_write_index: usize = 0;
    for (touched_parent_ids.items) |parent_elem_id| {
        if (removed_elem_set.contains(parent_elem_id)) continue;
        touched_parent_ids.items[touched_parent_write_index] = parent_elem_id;
        touched_parent_write_index += 1;
    }
    touched_parent_ids.items.len = touched_parent_write_index;

    const owned_removed = try removed_elem_ids.toOwnedSlice(allocator);
    errdefer allocator.free(owned_removed);
    const owned_parents = try touched_parent_ids.toOwnedSlice(allocator);
    return .{
        .removed_elem_ids = owned_removed,
        .touched_parent_ids = owned_parents,
        .removed_render_count = removed_render_count,
        .target_scan_count = target_scan_count,
    };
}

/// Collects render removal scan for legacy immediate callers.
pub fn collectRenderRemovalScan(comptime Stream: type, allocator: std.mem.Allocator, stream: *const Stream, render_insert_index: usize, target_scopes: []const bool) RenderRemovalScan {
    return prepareRenderRemovalScan(Stream, allocator, stream, render_insert_index, target_scopes) catch @panic("out of memory");
}

/// Prepares the render scan and every descriptor-removal index before mutation.
pub fn prepareRemoval(comptime Stream: type, allocator: std.mem.Allocator, stream: *const Stream, render_insert_index: usize, target_scopes: []const bool) std.mem.Allocator.Error!PreparedRemoval {
    var prepared = PreparedRemoval{
        .scan = try prepareRenderRemovalScan(Stream, allocator, stream, render_insert_index, target_scopes),
        .descriptor_indexes = .{},
    };
    errdefer prepared.deinit(allocator);
    try prepared.descriptor_indexes.prepare(allocator, prepared.scan.removed_elem_ids.len);
    for (prepared.scan.removed_elem_ids) |elem_id| {
        const descriptor_index = stream.elemDescriptorIndex(elem_id) orelse continue;
        prepared.descriptor_indexes.appendDescriptorIndexesAssumeCapacity(descriptor_index);
    }
    prepared.descriptor_indexes.sortDescending();
    return prepared;
}

/// Prepares the render element ids selected by a local structural splice.
pub fn prepareRenderElemIds(allocator: std.mem.Allocator, render_nodes: anytype) std.mem.Allocator.Error![]u64 {
    const elem_ids = try allocator.alloc(u64, render_nodes.len);
    for (render_nodes, 0..) |node, index| {
        elem_ids[index] = node.elem_id;
    }
    return elem_ids;
}

/// Returns the render element ids selected by this local structural splice.
pub fn renderElemIds(allocator: std.mem.Allocator, render_nodes: anytype) []u64 {
    return prepareRenderElemIds(allocator, render_nodes) catch @panic("out of memory");
}

/// Prepares a contiguous descriptor range affected by a splice.
pub fn prepareIndexRange(allocator: std.mem.Allocator, start: usize, count: usize) std.mem.Allocator.Error![]usize {
    _ = std.math.add(usize, start, count) catch return error.OutOfMemory;
    const indexes = try allocator.alloc(usize, count);
    for (indexes, 0..) |*index, offset| {
        index.* = start + offset;
    }
    return indexes;
}

/// Returns the contiguous descriptor range affected by this splice.
pub fn indexRange(allocator: std.mem.Allocator, start: usize, count: usize) []usize {
    return prepareIndexRange(allocator, start, count) catch @panic("out of memory");
}

pub const PreparedPublicationDeltas = struct {
    replacement_elem_ids: []u64,
    moved_event_elem_ids: []u64,
    replacement_on_change_indices: []usize,
    replacement_mount_indices: []usize,

    /// Releases provisional publication metadata without mutating active state.
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.replacement_elem_ids);
        allocator.free(self.moved_event_elem_ids);
        allocator.free(self.replacement_on_change_indices);
        allocator.free(self.replacement_mount_indices);
        self.* = undefined;
    }
};

/// Copies all metadata needed after a structural stream replacement so commit
/// can publish it without allocating.
pub fn preparePublicationDeltas(allocator: std.mem.Allocator, replacement_render_nodes: anytype, moved_event_elem_ids: []const u64, on_change_start: usize, on_change_count: usize, mount_start: usize, mount_count: usize) std.mem.Allocator.Error!PreparedPublicationDeltas {
    const replacement_elem_ids = try prepareRenderElemIds(allocator, replacement_render_nodes);
    errdefer allocator.free(replacement_elem_ids);
    const owned_moved_events = try allocator.dupe(u64, moved_event_elem_ids);
    errdefer allocator.free(owned_moved_events);
    const on_change_indices = try prepareIndexRange(allocator, on_change_start, on_change_count);
    errdefer allocator.free(on_change_indices);
    const mount_indices = try prepareIndexRange(allocator, mount_start, mount_count);
    return .{
        .replacement_elem_ids = replacement_elem_ids,
        .moved_event_elem_ids = owned_moved_events,
        .replacement_on_change_indices = on_change_indices,
        .replacement_mount_indices = mount_indices,
    };
}

/// Adjusts only scope-site insertion indexes shifted by the committed local splice.
pub fn adjustScopeSiteRenderInsertIndices(scope_sites: anytype, replace_index: usize, removed_render_count: usize, replacement_render_count: usize) void {
    for (scope_sites) |*desc| {
        desc.render_insert_index = descriptor_stream.adjustedRenderInsertIndex(desc.render_insert_index, replace_index, removed_render_count, replacement_render_count);
    }
}

test "structural splice owns replacement slices" {
    const allocator = std.testing.allocator;
    const splice = Splice{
        .removed_elem_ids = try allocator.dupe(u64, &.{ 1, 2 }),
        .touched_parent_ids = try allocator.dupe(u64, &.{3}),
        .replacement_elem_ids = try allocator.dupe(u64, &.{ 4, 5 }),
        .moved_event_elem_ids = try allocator.dupe(u64, &.{6}),
        .replacement_on_change_indices = try allocator.dupe(usize, &.{6}),
        .replacement_mount_indices = try allocator.dupe(usize, &.{7}),
    };
    splice.deinit(allocator);
}

test "structural splice allocates replacement metadata snapshots" {
    const RenderNode = struct {
        elem_id: u64,
    };
    const ScopeSite = struct {
        render_insert_index: usize,
    };
    const allocator = std.testing.allocator;

    const render_nodes = [_]RenderNode{ .{ .elem_id = 8 }, .{ .elem_id = 13 } };
    const elem_ids = renderElemIds(allocator, render_nodes[0..]);
    defer allocator.free(elem_ids);
    try std.testing.expectEqualSlices(u64, &.{ 8, 13 }, elem_ids);

    const indexes = indexRange(allocator, 4, 3);
    defer allocator.free(indexes);
    try std.testing.expectEqualSlices(usize, &.{ 4, 5, 6 }, indexes);

    var scope_sites = [_]ScopeSite{
        .{ .render_insert_index = 2 },
        .{ .render_insert_index = 9 },
    };
    adjustScopeSiteRenderInsertIndices(scope_sites[0..], 4, 2, 5);
    try std.testing.expectEqual(@as(usize, 2), scope_sites[0].render_insert_index);
    try std.testing.expectEqual(@as(usize, 12), scope_sites[1].render_insert_index);
}

test "publication deltas sweep failures and retry without source mutation" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    const RenderNode = struct { elem_id: u64 };
    const nodes = [_]RenderNode{ .{ .elem_id = 4 }, .{ .elem_id = 9 } };
    const moved = [_]u64{ 3, 8 };

    var counter = FaultAllocator.init(std.testing.allocator);
    var successful = try preparePublicationDeltas(counter.allocator(), &nodes, &moved, 7, 2, 11, 1);
    const attempts = counter.attempts;
    successful.deinit(counter.allocator());
    try std.testing.expect(attempts >= 4);

    for (1..attempts + 1) |failure_number| {
        var fault = FaultAllocator.init(std.testing.allocator);
        fault.configure(failure_number);
        try std.testing.expectError(error.OutOfMemory, preparePublicationDeltas(fault.allocator(), &nodes, &moved, 7, 2, 11, 1));
        try std.testing.expectEqualSlices(u64, &.{ 4, 9 }, &.{ nodes[0].elem_id, nodes[1].elem_id });
        try std.testing.expectEqualSlices(u64, &.{ 3, 8 }, &moved);
        fault.configure(null);
        var retry = try preparePublicationDeltas(fault.allocator(), &nodes, &moved, 7, 2, 11, 1);
        try std.testing.expectEqualSlices(u64, &.{ 4, 9 }, retry.replacement_elem_ids);
        try std.testing.expectEqualSlices(u64, &.{ 3, 8 }, retry.moved_event_elem_ids);
        try std.testing.expectEqualSlices(usize, &.{ 7, 8 }, retry.replacement_on_change_indices);
        try std.testing.expectEqualSlices(usize, &.{11}, retry.replacement_mount_indices);
        retry.deinit(fault.allocator());
    }
}

test "structural splice collects removal indexes" {
    const TextFields = struct {
        text: ?usize = 1,
        role: ?usize = null,
        label: ?usize = 7,
        test_id: ?usize = null,
        value: ?usize = 3,
        class: ?usize = null,
    };

    var indexes: std.ArrayListUnmanaged(usize) = .empty;
    defer indexes.deinit(std.testing.allocator);

    appendTextFieldRemovalIndexes(std.testing.allocator, &indexes, TextFields{});
    sortRemovalIndexesDescending(indexes.items);

    try std.testing.expectEqualSlices(usize, &.{ 7, 3, 1 }, indexes.items);
    try std.testing.expect(scopeIsInTargetSet(&.{ false, true, false }, 1));
}

test "structural splice scratch collects descriptor indexes" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    const DescriptorIndex = struct {
        element: ?usize = 3,
        text_node: ?usize = null,
        signal_text_node: ?usize = 9,
        static_text_attrs: struct {
            text: ?usize = 4,
            role: ?usize = null,
            label: ?usize = 1,
            test_id: ?usize = null,
            value: ?usize = null,
            class: ?usize = null,
        } = .{},
        signal_text_attrs: struct {
            text: ?usize = null,
            role: ?usize = null,
            label: ?usize = null,
            test_id: ?usize = null,
            value: ?usize = null,
            class: ?usize = null,
        } = .{},
        static_bool_attrs: struct {
            checked: ?usize = 2,
            disabled: ?usize = null,
        } = .{},
        signal_bool_attrs: struct {
            checked: ?usize = null,
            disabled: ?usize = null,
        } = .{},
        events: struct {
            click: ?usize = 8,
            input: ?usize = null,
            check: ?usize = null,
            pointer_down: ?usize = null,
            pointer_up: ?usize = null,
            pointer_enter: ?usize = null,
            pointer_leave: ?usize = null,
        } = .{},
    };

    var fault = FaultAllocator.init(std.testing.allocator);
    const allocator = fault.allocator();
    var scratch: ElemOwnedRemovalScratch = .{};
    defer scratch.deinit(allocator);

    scratch.assertEmpty();
    try scratch.prepare(allocator, 1);
    fault.configure(1);
    scratch.appendDescriptorIndexesAssumeCapacity(DescriptorIndex{});
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    fault.configure(null);
    scratch.sortDescending();

    try std.testing.expectEqualSlices(usize, &.{3}, scratch.element_indexes.items);
    try std.testing.expectEqualSlices(usize, &.{9}, scratch.signal_text_node_indexes.items);
    try std.testing.expectEqualSlices(usize, &.{ 4, 1 }, scratch.static_text_attr_indexes.items);
    try std.testing.expectEqualSlices(usize, &.{2}, scratch.static_bool_attr_indexes.items);
    try std.testing.expectEqualSlices(usize, &.{8}, scratch.event_indexes.items);

    scratch.clearRetainingCapacity();
    scratch.assertEmpty();
}

test "structural splice builds target scope set through explicit lookup" {
    const TestScope = struct {
        scope_id: u64,
    };
    const Lookup = struct {
        /// Evaluates scope is in target using explicit scope ownership rather than DOM position or content.
        pub fn scopeIsInTarget(_: @This(), scope_id: u64, target: ReplacementTarget) bool {
            return switch (target) {
                .scope => |root_scope_id| scope_id >= root_scope_id,
                .each_site => false,
            };
        }
    };

    var scratch: std.ArrayListUnmanaged(bool) = .empty;
    defer scratch.deinit(std.testing.allocator);
    const scopes = [_]TestScope{ .{ .scope_id = 0 }, .{ .scope_id = 1 }, .{ .scope_id = 2 } };

    const target_scopes = buildTargetScopeSet(TestScope, std.testing.allocator, &scratch, scopes[0..], .{ .scope = 1 }, Lookup{});
    try std.testing.expectEqualSlices(bool, &.{ false, true, true }, target_scopes);
}

const TestStream = struct {
    pub const RenderNode = descriptor_stream.RenderNode;
    pub const ElementDesc = descriptor_stream.ElementDesc;
    pub const TextNodeDesc = descriptor_stream.TextNodeDesc;
    pub const SignalTextNodeDesc = descriptor_stream.TextNodeDesc;

    render_nodes: std.ArrayListUnmanaged(RenderNode) = .empty,
    elements: std.ArrayListUnmanaged(ElementDesc) = .empty,
    text_nodes: std.ArrayListUnmanaged(TextNodeDesc) = .empty,
    signal_text_nodes: std.ArrayListUnmanaged(SignalTextNodeDesc) = .empty,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.render_nodes.deinit(allocator);
        self.elements.deinit(allocator);
        self.text_nodes.deinit(allocator);
        self.signal_text_nodes.deinit(allocator);
    }

    /// Resolves an element id through the maintained descriptor index.
    pub fn elemDescriptorIndex(self: *const @This(), elem_id: u64) ?descriptor_stream.ElemDescriptorIndex {
        for (self.elements.items, 0..) |desc, index| {
            if (desc.elem_id == elem_id) return .{ .element = descriptor_stream.DescriptorIndex.init(index) };
        }
        for (self.text_nodes.items, 0..) |desc, index| {
            if (desc.elem_id == elem_id) return .{ .text_node = descriptor_stream.DescriptorIndex.init(index) };
        }
        for (self.signal_text_nodes.items, 0..) |desc, index| {
            if (desc.elem_id == elem_id) return .{ .signal_text_node = descriptor_stream.DescriptorIndex.init(index) };
        }
        return null;
    }
};

test "structural splice scans removed render range" {
    const allocator = std.testing.allocator;
    var stream = TestStream{};
    defer stream.deinit(allocator);

    stream.render_nodes.appendSlice(allocator, &.{
        .{ .elem_id = 1, .kind = .element },
        .{ .elem_id = 2, .kind = .text },
        .{ .elem_id = 3, .kind = .text },
        .{ .elem_id = 4, .kind = .element },
    }) catch @panic("out of memory");
    stream.elements.appendSlice(allocator, &.{
        .{ .elem_id = 1, .parent_elem_id = 0, .scope_id = 10, .tag = "div" },
        .{ .elem_id = 4, .parent_elem_id = 0, .scope_id = 20, .tag = "aside" },
    }) catch @panic("out of memory");
    stream.text_nodes.appendSlice(allocator, &.{
        .{ .elem_id = 2, .parent_elem_id = 1, .scope_id = 10, .value = "a" },
        .{ .elem_id = 3, .parent_elem_id = 1, .scope_id = 10, .value = "b" },
    }) catch @panic("out of memory");

    var target_scopes = [_]bool{false} ** 21;
    target_scopes[10] = true;
    const scan = collectRenderRemovalScan(TestStream, allocator, &stream, 0, target_scopes[0..]);
    defer scan.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), scan.removed_render_count);
    try std.testing.expectEqual(@as(usize, 4), scan.target_scan_count);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 3 }, scan.removed_elem_ids);
    try std.testing.expectEqualSlices(u64, &.{0}, scan.touched_parent_ids);
}

test "render removal preparation sweeps allocation failures without source mutation" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var stream = TestStream{};
    defer stream.deinit(std.testing.allocator);
    try stream.render_nodes.appendSlice(std.testing.allocator, &.{
        .{ .elem_id = 1, .kind = .element },
        .{ .elem_id = 2, .kind = .text },
        .{ .elem_id = 3, .kind = .text },
    });
    try stream.elements.append(std.testing.allocator, .{ .elem_id = 1, .parent_elem_id = 0, .scope_id = 1, .tag = "div" });
    try stream.text_nodes.appendSlice(std.testing.allocator, &.{
        .{ .elem_id = 2, .parent_elem_id = 1, .scope_id = 1, .value = "a" },
        .{ .elem_id = 3, .parent_elem_id = 1, .scope_id = 1, .value = "b" },
    });
    const original_nodes = try std.testing.allocator.dupe(TestStream.RenderNode, stream.render_nodes.items);
    defer std.testing.allocator.free(original_nodes);
    const target_scopes = &.{ false, true };

    var counter = FaultAllocator.init(std.testing.allocator);
    var successful = try prepareRemoval(TestStream, counter.allocator(), &stream, 0, target_scopes);
    const attempts = counter.attempts;
    successful.deinit(counter.allocator());
    try std.testing.expect(attempts != 0);

    for (1..attempts + 1) |failure_number| {
        var fault = FaultAllocator.init(std.testing.allocator);
        fault.configure(failure_number);
        try std.testing.expectError(error.OutOfMemory, prepareRemoval(TestStream, fault.allocator(), &stream, 0, target_scopes));
        try std.testing.expectEqualSlices(TestStream.RenderNode, original_nodes, stream.render_nodes.items);
        fault.configure(null);
        var retry = try prepareRemoval(TestStream, fault.allocator(), &stream, 0, target_scopes);
        try std.testing.expectEqualSlices(u64, &.{ 1, 2, 3 }, retry.scan.removed_elem_ids);
        try std.testing.expectEqualSlices(usize, &.{0}, retry.descriptor_indexes.element_indexes.items);
        try std.testing.expectEqualSlices(usize, &.{ 1, 0 }, retry.descriptor_indexes.text_node_indexes.items);
        retry.deinit(fault.allocator());
    }
}

test "structural splice removes rendered descendants of target nodes across scope boundaries" {
    const allocator = std.testing.allocator;
    var stream = TestStream{};
    defer stream.deinit(allocator);

    stream.render_nodes.appendSlice(allocator, &.{
        .{ .elem_id = 1, .kind = .element },
        .{ .elem_id = 2, .kind = .element },
        .{ .elem_id = 3, .kind = .text },
        .{ .elem_id = 4, .kind = .element },
    }) catch @panic("out of memory");
    stream.elements.appendSlice(allocator, &.{
        .{ .elem_id = 1, .parent_elem_id = 0, .scope_id = 10, .tag = "section" },
        .{ .elem_id = 2, .parent_elem_id = 1, .scope_id = 20, .tag = "div" },
        .{ .elem_id = 4, .parent_elem_id = 0, .scope_id = 30, .tag = "aside" },
    }) catch @panic("out of memory");
    stream.text_nodes.appendSlice(allocator, &.{
        .{ .elem_id = 3, .parent_elem_id = 2, .scope_id = 30, .value = "nested" },
    }) catch @panic("out of memory");

    var target_scopes = [_]bool{false} ** 31;
    target_scopes[10] = true;
    const scan = collectRenderRemovalScan(TestStream, allocator, &stream, 0, target_scopes[0..]);
    defer scan.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), scan.removed_render_count);
    try std.testing.expectEqual(@as(usize, 4), scan.target_scan_count);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 3 }, scan.removed_elem_ids);
    try std.testing.expectEqualSlices(u64, &.{0}, scan.touched_parent_ids);
}
