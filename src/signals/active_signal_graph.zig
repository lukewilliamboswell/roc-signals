//! Active signal graph records, routes, and dirty propagation helpers.

const std = @import("std");
const shared_buffer = @import("shared_buffer.zig");
const scope_tree = @import("scope_tree.zig");
const signal_records = @import("signal_records.zig");
const signal_graph = @import("signal_graph.zig");
const boundary = @import("boundary.zig");
const ids = @import("ids.zig");

/// Defines the dense active-graph node view used by dependency-ordered propagation.
pub fn Node(comptime Record: type) type {
    return signal_graph.Node(Record);
}

/// Defines dense event and sink routes derived from the active descriptor stream.
pub fn RouteTable(comptime Route: type) type {
    return shared_buffer.List(SmallRouteList(Route));
}

/// Stores the common zero-or-one route case inline while retaining ordinary
/// independently owned storage for records with multiple routes.
pub fn SmallRouteList(comptime Route: type) type {
    return union(enum) {
        empty,
        one: Route,
        many: shared_buffer.List(Route),

        const Self = @This();

        /// Borrows all routes in insertion order without transferring their storage.
        pub fn slice(self: *const Self) []const Route {
            return switch (self.*) {
                .empty => &.{},
                .one => |*value| @as(*const [1]Route, @ptrCast(value))[0..],
                .many => |list| list.items,
            };
        }

        /// Mutably borrows all routes in insertion order for in-place remapping.
        pub fn mutableSlice(self: *Self) []Route {
            return switch (self.*) {
                .empty => &.{},
                .one => |*value| @as(*[1]Route, @ptrCast(value))[0..],
                .many => |*list| list.items,
            };
        }

        /// Returns the number of routes represented by the inline or spilled form.
        pub fn len(self: *const Self) usize {
            return self.slice().len;
        }

        /// Reserves room for additional routes, preserving the current representation on failure.
        pub fn ensureUnusedCapacity(self: *Self, allocator: std.mem.Allocator, additional: usize) std.mem.Allocator.Error!void {
            const required = std.math.add(usize, self.len(), additional) catch return error.OutOfMemory;
            if (required <= 1) return;
            switch (self.*) {
                .empty => {
                    var list: shared_buffer.List(Route) = .empty;
                    try list.ensureTotalCapacity(allocator, required);
                    self.* = .{ .many = list };
                },
                .one => |value| {
                    var list: shared_buffer.List(Route) = .empty;
                    try list.ensureTotalCapacity(allocator, required);
                    list.appendAssumeCapacity(value);
                    self.* = .{ .many = list };
                },
                .many => |*list| try list.ensureUnusedCapacity(allocator, additional),
            }
        }

        /// Appends one owned route, allocating only when the list must spill past its inline slot.
        pub fn append(self: *Self, allocator: std.mem.Allocator, value: Route) std.mem.Allocator.Error!void {
            try self.ensureUnusedCapacity(allocator, 1);
            self.appendAssumeCapacity(value);
        }

        /// Appends after capacity has been prepared; a missing spill reservation is a caller defect.
        pub fn appendAssumeCapacity(self: *Self, value: Route) void {
            switch (self.*) {
                .empty => self.* = .{ .one = value },
                .one => @panic("small route list lacked prepared spill capacity"),
                .many => |*list| list.appendAssumeCapacity(value),
            }
        }

        /// Removes and returns a route without preserving order, retaining any spilled allocation.
        pub fn swapRemove(self: *Self, index: usize) Route {
            return switch (self.*) {
                .empty => @panic("removed from empty route list"),
                .one => |value| blk: {
                    if (index != 0) @panic("route index out of bounds");
                    self.* = .empty;
                    break :blk value;
                },
                .many => |*list| list.swapRemove(index),
            };
        }

        /// Releases spilled storage and restores the list to its empty inline state.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .many => |*list| list.deinit(allocator),
                .empty, .one => {},
            }
            self.* = .empty;
        }
    };
}

test "small route list keeps singleton inline and owns spilled storage" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var fault = FaultAllocator.init(std.testing.allocator);
    var routes: SmallRouteList(u64) = .empty;
    defer routes.deinit(fault.allocator());

    fault.configure(1);
    try routes.append(fault.allocator(), 11);
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqualSlices(u64, &.{11}, routes.slice());

    try std.testing.expectError(error.OutOfMemory, routes.append(fault.allocator(), 22));
    try std.testing.expectEqualSlices(u64, &.{11}, routes.slice());

    fault.configure(null);
    try routes.append(fault.allocator(), 22);
    try routes.append(fault.allocator(), 33);
    routes.mutableSlice()[1] = 44;
    try std.testing.expectEqualSlices(u64, &.{ 11, 44, 33 }, routes.slice());
    try std.testing.expectEqual(@as(u64, 44), routes.swapRemove(1));
    try std.testing.expectEqualSlices(u64, &.{ 11, 33 }, routes.slice());

    routes.deinit(fault.allocator());
    try std.testing.expectEqual(@as(usize, 0), routes.len());
    try routes.append(fault.allocator(), 55);
    try std.testing.expectEqual(@as(u64, 55), routes.swapRemove(0));
    try std.testing.expectEqual(@as(usize, 0), routes.len());
}

pub const SignalKind = enum(u64) {
    source = 1,
    map = 2,
    map2 = 3,
};

pub const EventRoute = struct {
    event_id: ids.EventId,
    signal_ids: []ids.NodeId,
};

pub const EventDescriptor = struct {
    event_id: ids.EventId,
    payload_descriptor: boundary.BoundaryPayloadDescriptor,
};

pub const Descriptor = struct {
    signal_id: u64,
    kind: SignalKind,
    source_state_ids: []ids.NodeId,
    source_event_ids: []ids.EventId,
    input_signal_ids: []u64,
    rank: u64,
};

pub const StateRoute = struct {
    state_id: ids.NodeId,
    signal_ids: []u64,
};

pub const DependentsRoute = struct {
    signal_id: u64,
    signal_ids: []u64,
};

pub const EventLookupError = error{
    EventIdZero,
    MissingSignalEventRoute,
    SignalEventRouteIndexMismatch,
    MissingEventDescriptor,
    EventDescriptorIndexMismatch,
};

pub const SignalLookupError = error{
    MissingSignalRoute,
    SignalRouteIndexMismatch,
    MissingSignalDependentRoute,
    SignalDependentRouteIndexMismatch,
    MissingSignalDescriptor,
    SignalDescriptorIndexMismatch,
};

pub const TextSinkKind = enum {
    text_node,
    text_attr,
    custom_text_attr,
    custom_text_optional_attr,
};

pub const TextSink = struct {
    kind: TextSinkKind,
    index: usize,
};

pub const BoolSinkKind = enum {
    bool_attr,
    custom_bool_attr,
};

pub const BoolSink = struct {
    kind: BoolSinkKind,
    index: usize,
};

pub const ChangeSink = struct {
    index: usize,
};

pub const StructuralKind = enum {
    when,
    each,
};

pub const StructuralSink = struct {
    kind: StructuralKind,
    index: usize,
};

pub const TextSinkEdit = struct { record_id: u64, kind: TextSinkKind, old_index: usize, new_index: ?usize = null };
pub const BoolSinkEdit = struct { record_id: u64, kind: BoolSinkKind, old_index: usize, new_index: ?usize = null };
pub const ChangeSinkEdit = struct { record_id: u64, old_index: usize, new_index: ?usize = null };
pub const StructuralSinkEdit = struct { record_id: u64, kind: StructuralKind, old_index: usize, new_index: ?usize = null };

/// Describes one route entry to append to a prepared route table.
pub fn RouteAppend(comptime Route: type) type {
    return struct { route_index: u64, value: Route };
}

/// Owns allocation-free replacements for selected route-table entries.
pub fn PreparedRouteAppends(comptime Route: type) type {
    return struct {
        replacements: []Replacement,

        const Replacement = struct {
            route_index: u64,
            next: SmallRouteList(Route) = .empty,
            retired: SmallRouteList(Route) = .empty,
        };

        /// Releases provisional and retired route storage.
        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            for (self.replacements) |*replacement| {
                replacement.next.deinit(allocator);
                replacement.retired.deinit(allocator);
            }
            allocator.free(self.replacements);
            self.* = undefined;
        }

        /// Reserves the destination outer route table before publication.
        pub fn reserveOuter(self: *const @This(), allocator: std.mem.Allocator, routes: *RouteTable(Route), final_count: usize) std.mem.Allocator.Error!void {
            _ = self;
            try routes.ensureTotalCapacity(allocator, final_count);
        }

        /// Publishes every prepared inner route list without allocation.
        pub fn apply(self: *@This(), routes: *RouteTable(Route), final_count: usize) void {
            while (routes.items.len < final_count) routes.appendAssumeCapacity(.empty);
            for (self.replacements) |*replacement| {
                const index: usize = @intCast(replacement.route_index);
                if (index >= routes.items.len) @panic("prepared route append exceeded its destination table");
                replacement.retired = routes.items[index];
                routes.items[index] = replacement.next;
                replacement.next = .empty;
            }
        }
    };
}

/// Builds grouped route-table replacements without mutating active routes.
pub fn prepareRouteAppends(comptime Route: type, allocator: std.mem.Allocator, routes: *const RouteTable(Route), final_count: usize, appends: []const RouteAppend(Route)) (std.mem.Allocator.Error || error{InvalidAppend})!PreparedRouteAppends(Route) {
    return prepareDenseRouteAppends(Route, allocator, routes, null, final_count, appends, null);
}

/// Builds sink route replacements against the dense record layout that will
/// exist after a prepared release. Slots without a surviving old record start
/// empty instead of inheriting routes from the old occupant of that dense ID.
pub fn prepareRouteAppendsAfterRelease(comptime Route: type, allocator: std.mem.Allocator, routes: *const RouteTable(Route), remap: *const DenseRemap, final_count: usize, appends: []const RouteAppend(Route)) (std.mem.Allocator.Error || error{InvalidAppend})!PreparedRouteAppends(Route) {
    return prepareRouteAppendsAfterReleaseWithWork(Route, allocator, routes, remap, final_count, appends, null);
}

fn prepareRouteAppendsAfterReleaseWithWork(comptime Route: type, allocator: std.mem.Allocator, routes: *const RouteTable(Route), remap: *const DenseRemap, final_count: usize, appends: []const RouteAppend(Route), lookup_work: ?*usize) (std.mem.Allocator.Error || error{InvalidAppend})!PreparedRouteAppends(Route) {
    if (remap.survivor_count > final_count) return error.InvalidAppend;
    return prepareDenseRouteAppends(Route, allocator, routes, remap, final_count, appends, lookup_work);
}

/// Runtime metadata describing how to read each append's destination record
/// ID out of a typed `RouteAppend(Route)` slice without dispatching per entry.
/// The stride and field offset come from the typed factory, so the shared
/// planner walks any append layout with plain pointer arithmetic.
const RouteIndexStream = struct {
    base: [*]const u8,
    stride: usize,
    offset: usize,
    len: usize,

    fn of(comptime Route: type, appends: []const RouteAppend(Route)) RouteIndexStream {
        return .{
            .base = @ptrCast(appends.ptr),
            .stride = @sizeOf(RouteAppend(Route)),
            .offset = @offsetOf(RouteAppend(Route), "route_index"),
            .len = appends.len,
        };
    }

    fn at(self: RouteIndexStream, index: usize) u64 {
        const address = self.base + index * self.stride + self.offset;
        return @as(*const u64, @ptrCast(@alignCast(address))).*;
    }
};

/// Per-destination bookkeeping owned by the shared planner, one entry per
/// targeted final record in first-appearance order. `append_count` is the
/// number of inputs targeting that record; the entry's position doubles as
/// the index of its typed replacement.
const DenseRouteGroup = struct { route_index: u64, append_count: usize = 0 };

/// Sparse index from a targeted final record id to its `DenseRouteGroup`
/// position, so planning reserves storage for the targeted records only and
/// never for the whole final graph.
const DenseRouteGroupIndex = std.AutoHashMapUnmanaged(u64, usize);

/// Closed operation table through which the shared planner drives typed route
/// storage. Every operation is a batch over one replacement group or over the
/// whole input, never one route at a time. The table is built once per route
/// type by `DenseRouteAdapter(Route)` and handed out only paired with the
/// adapter instance that owns the typed storage, so a caller cannot combine
/// one type's operations with another type's owner.
const DenseRoutePlanOps = struct {
    /// Number of routes currently stored for the old dense record `old_index`.
    existing_len: *const fn (owner: *anyopaque, old_index: usize) usize,
    /// Allocates `group_count` uninitialized typed replacements.
    alloc_replacements: *const fn (owner: *anyopaque, allocator: std.mem.Allocator, group_count: usize) std.mem.Allocator.Error!void,
    /// Initializes replacement `written`, reserves `merged_len` routes, and
    /// copies the old record's routes when `old_index` names a survivor. On
    /// failure the replacement holds no storage and is not counted as written.
    prepare_replacement: *const fn (owner: *anyopaque, allocator: std.mem.Allocator, written: usize, route_index: u64, old_index: ?usize, merged_len: usize) std.mem.Allocator.Error!void,
    /// Appends every input route, in input order, into the replacement chosen
    /// by `groups.get(route_index)`; capacity is already reserved.
    append_inputs: *const fn (owner: *anyopaque, groups: *const DenseRouteGroupIndex) void,
    /// Releases the initialized prefix `[0..written)` and the replacement
    /// slice after a failed plan, leaving the committed table untouched.
    release_prefix: *const fn (owner: *anyopaque, allocator: std.mem.Allocator, written: usize) void,
};

/// An erased owner paired with the operation table that created it. Only
/// `DenseRouteAdapter(Route).bind` constructs this pair.
const DenseRoutePlan = struct {
    owner: *anyopaque,
    ops: *const DenseRoutePlanOps,
};

/// Typed adapter that lends one route type's table and append inputs to the
/// shared planner and receives the prepared replacements back. The adapter is
/// a stack value whose lifetime spans one call to `planDenseRouteAppends`.
fn DenseRouteAdapter(comptime Route: type) type {
    return struct {
        routes: *const RouteTable(Route),
        appends: []const RouteAppend(Route),
        replacements: []Replacement = &.{},

        const Self = @This();
        const Replacement = PreparedRouteAppends(Route).Replacement;

        const ops: DenseRoutePlanOps = .{
            .existing_len = existingLen,
            .alloc_replacements = allocReplacements,
            .prepare_replacement = prepareReplacement,
            .append_inputs = appendInputs,
            .release_prefix = releasePrefix,
        };

        fn bind(self: *Self) DenseRoutePlan {
            return .{ .owner = self, .ops = &ops };
        }

        fn recover(owner: *anyopaque) *Self {
            return @ptrCast(@alignCast(owner));
        }

        fn existingLen(owner: *anyopaque, old_index: usize) usize {
            return recover(owner).routes.items[old_index].len();
        }

        fn allocReplacements(owner: *anyopaque, allocator: std.mem.Allocator, group_count: usize) std.mem.Allocator.Error!void {
            recover(owner).replacements = try allocator.alloc(Replacement, group_count);
        }

        fn prepareReplacement(owner: *anyopaque, allocator: std.mem.Allocator, written: usize, route_index: u64, old_index: ?usize, merged_len: usize) std.mem.Allocator.Error!void {
            const self = recover(owner);
            const replacement = &self.replacements[written];
            replacement.* = .{ .route_index = route_index };
            try replacement.next.ensureUnusedCapacity(allocator, merged_len);
            if (old_index) |index| for (self.routes.items[index].slice()) |value| replacement.next.appendAssumeCapacity(value);
        }

        fn appendInputs(owner: *anyopaque, groups: *const DenseRouteGroupIndex) void {
            const self = recover(owner);
            for (self.appends) |entry| self.replacements[groups.get(entry.route_index).?].next.appendAssumeCapacity(entry.value);
        }

        fn releasePrefix(owner: *anyopaque, allocator: std.mem.Allocator, written: usize) void {
            const self = recover(owner);
            for (self.replacements[0..written]) |*replacement| replacement.next.deinit(allocator);
            allocator.free(self.replacements);
            self.replacements = &.{};
        }
    };
}

/// Shared, non-generic planning body for dense sink-route appends. Counts the
/// inputs per final record, allocates one typed replacement per targeted
/// record, reserves each replacement's merged capacity, copies the survivor's
/// existing routes, and finally appends the inputs in their original order.
/// `remap`, when present, resolves each final dense ID to the old record that
/// survives there; a final slot without a survivor starts empty and never
/// inherits the routes of the old occupant of that dense ID.
///
/// The committed table is only read. On any failure the adapter's initialized
/// prefix is released and the caller observes no change. Every typed operation
/// is dispatched once per replacement group or once per plan, never per route.
/// Storage and work are proportional to the appended routes and the targeted
/// records; the final graph length only bounds the accepted ids.
fn planDenseRouteAppends(allocator: std.mem.Allocator, plan: DenseRoutePlan, route_ids: RouteIndexStream, routes_len: usize, remap: ?*const DenseRemap, final_count: usize, lookup_work: ?*usize) (std.mem.Allocator.Error || error{InvalidAppend})!void {
    var groups: shared_buffer.List(DenseRouteGroup) = .empty;
    defer groups.deinit(allocator);
    var group_index: DenseRouteGroupIndex = .empty;
    defer group_index.deinit(allocator);
    // Reject invalid destinations before reserving anything, then reserve
    // once, bounded by the appended routes: a plan's allocation count does
    // not depend on how many routes it carries.
    for (0..route_ids.len) |position| if (route_ids.at(position) >= final_count) return error.InvalidAppend;
    try groups.ensureTotalCapacity(allocator, route_ids.len);
    try group_index.ensureTotalCapacity(allocator, std.math.cast(u32, route_ids.len) orelse return error.InvalidAppend);
    for (0..route_ids.len) |position| {
        const route_index = route_ids.at(position);
        const entry = group_index.getOrPutAssumeCapacity(route_index);
        if (!entry.found_existing) {
            entry.value_ptr.* = groups.items.len;
            groups.appendAssumeCapacity(.{ .route_index = route_index });
        }
        const slot = &groups.items[entry.value_ptr.*];
        slot.append_count = std.math.add(usize, slot.append_count, 1) catch return error.InvalidAppend;
    }
    try plan.ops.alloc_replacements(plan.owner, allocator, groups.items.len);
    var written: usize = 0;
    errdefer plan.ops.release_prefix(plan.owner, allocator, written);
    for (groups.items) |slot| {
        if (lookup_work) |counter| counter.* += 1;
        const old_index: ?usize = if (remap) |mapping| blk: {
            const candidate: usize = @intCast(mapping.originalId(slot.route_index) orelse break :blk null);
            break :blk if (candidate < routes_len) candidate else null;
        } else if (slot.route_index < routes_len) @as(usize, @intCast(slot.route_index)) else null;
        const existing_len = if (old_index) |index| plan.ops.existing_len(plan.owner, index) else 0;
        const merged_len = std.math.add(usize, existing_len, slot.append_count) catch return error.InvalidAppend;
        try plan.ops.prepare_replacement(plan.owner, allocator, written, slot.route_index, old_index, merged_len);
        written += 1;
    }
    plan.ops.append_inputs(plan.owner, &group_index);
}

/// Typed entry to the shared planner: binds this route type's adapter, runs
/// the erased body, and hands the prepared replacements to the caller. On
/// failure nothing is owned by the returned value and the committed table is
/// unchanged.
fn prepareDenseRouteAppends(comptime Route: type, allocator: std.mem.Allocator, routes: *const RouteTable(Route), remap: ?*const DenseRemap, final_count: usize, appends: []const RouteAppend(Route), lookup_work: ?*usize) (std.mem.Allocator.Error || error{InvalidAppend})!PreparedRouteAppends(Route) {
    var adapter = DenseRouteAdapter(Route){ .routes = routes, .appends = appends };
    try planDenseRouteAppends(allocator, adapter.bind(), RouteIndexStream.of(Route, appends), routes.items.len, remap, final_count, lookup_work);
    return .{ .replacements = adapter.replacements };
}

/// Merges new source routes against the post-retirement dense record mapping.
/// Only the source routes the appends target are read or copied; the retired
/// and displaced record ids inside them resolve through the sparse `remap`.
pub fn prepareSourceRouteAppendsAfterRelease(allocator: std.mem.Allocator, routes: *const RouteTable(u64), remap: *const DenseRemap, final_source_count: usize, appends: []const RouteAppend(u64)) (std.mem.Allocator.Error || error{InvalidAppend})!PreparedRouteAppends(u64) {
    var groups: shared_buffer.List(DenseRouteGroup) = .empty;
    defer groups.deinit(allocator);
    var group_index: DenseRouteGroupIndex = .empty;
    defer group_index.deinit(allocator);
    for (appends) |entry| if (entry.route_index >= final_source_count) return error.InvalidAppend;
    try groups.ensureTotalCapacity(allocator, appends.len);
    try group_index.ensureTotalCapacity(allocator, std.math.cast(u32, appends.len) orelse return error.InvalidAppend);
    for (appends) |entry| {
        const slot = group_index.getOrPutAssumeCapacity(entry.route_index);
        if (!slot.found_existing) {
            slot.value_ptr.* = groups.items.len;
            groups.appendAssumeCapacity(.{ .route_index = entry.route_index });
        }
        const group = &groups.items[slot.value_ptr.*];
        group.append_count = std.math.add(usize, group.append_count, 1) catch return error.InvalidAppend;
    }
    const replacements = try allocator.alloc(PreparedRouteAppends(u64).Replacement, groups.items.len);
    errdefer allocator.free(replacements);
    var written: usize = 0;
    errdefer for (replacements[0..written]) |*replacement| replacement.next.deinit(allocator);
    for (groups.items) |group| {
        const route_index: usize = @intCast(group.route_index);
        const existing = if (route_index < routes.items.len) routes.items[route_index].slice() else &.{};
        var survivor_count: usize = 0;
        for (existing) |old_id| {
            if (old_id >= remap.original_count) return error.InvalidAppend;
            if (remap.finalId(old_id) != null) survivor_count += 1;
        }
        const merged_len = std.math.add(usize, survivor_count, group.append_count) catch return error.InvalidAppend;
        replacements[written] = .{ .route_index = group.route_index };
        written += 1;
        try replacements[written - 1].next.ensureUnusedCapacity(allocator, merged_len);
        for (existing) |old_id| if (remap.finalId(old_id)) |new_id| {
            replacements[written - 1].next.appendAssumeCapacity(new_id);
        };
    }
    for (appends) |entry| replacements[group_index.get(entry.route_index).?].next.appendAssumeCapacity(entry.value);
    return .{ .replacements = replacements };
}

/// Owns validated sink-route removals and moved-descriptor index patches.
pub const PreparedSinkRouteEdits = struct {
    text: []TextSinkEdit,
    bools: []BoolSinkEdit,
    changes: []ChangeSinkEdit,
    structural: []StructuralSinkEdit,

    /// Releases preparation storage without changing live routes.
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.bools);
        allocator.free(self.changes);
        allocator.free(self.structural);
        self.* = undefined;
    }

    /// Applies exact route removals and index patches without allocation.
    pub fn apply(self: *const @This(), text_routes: *RouteTable(TextSink), bool_routes: *RouteTable(BoolSink), change_routes: *RouteTable(ChangeSink), structural_routes: *RouteTable(StructuralSink)) void {
        for (self.text) |edit| if (edit.new_index) |new_index|
            updateTextRouteIndex(text_routes, edit.record_id, edit.kind, edit.old_index, new_index)
        else
            removeTextRoute(text_routes, edit.record_id, edit.kind, edit.old_index);
        for (self.bools) |edit| if (edit.new_index) |new_index|
            updateBoolRouteIndex(bool_routes, edit.record_id, edit.kind, edit.old_index, new_index)
        else
            removeBoolRoute(bool_routes, edit.record_id, edit.kind, edit.old_index);
        for (self.changes) |edit| if (edit.new_index) |new_index|
            updateChangeRouteIndex(change_routes, edit.record_id, edit.old_index, new_index)
        else
            removeChangeRoute(change_routes, edit.record_id, edit.old_index);
        for (self.structural) |edit| if (edit.new_index) |new_index|
            updateStructuralRouteIndex(structural_routes, edit.record_id, edit.kind, edit.old_index, new_index)
        else
            removeStructuralRoute(structural_routes, edit.record_id, edit.kind, edit.old_index);
    }
};

/// Copies and validates sink edits before route mutation begins.
pub fn prepareSinkRouteEdits(allocator: std.mem.Allocator, text_routes: *const RouteTable(TextSink), bool_routes: *const RouteTable(BoolSink), change_routes: *const RouteTable(ChangeSink), structural_routes: *const RouteTable(StructuralSink), text: []const TextSinkEdit, bools: []const BoolSinkEdit, changes: []const ChangeSinkEdit, structural: []const StructuralSinkEdit) std.mem.Allocator.Error!PreparedSinkRouteEdits {
    for (text, 0..) |edit, index| if (!containsTextSinkAfter(text_routes, text[0..index], edit)) return error.OutOfMemory;
    for (bools, 0..) |edit, index| if (!containsBoolSinkAfter(bool_routes, bools[0..index], edit)) return error.OutOfMemory;
    for (changes, 0..) |edit, index| if (!containsChangeSinkAfter(change_routes, changes[0..index], edit)) return error.OutOfMemory;
    for (structural, 0..) |edit, index| if (!containsStructuralSinkAfter(structural_routes, structural[0..index], edit)) return error.OutOfMemory;
    const owned_text = try allocator.dupe(TextSinkEdit, text);
    errdefer allocator.free(owned_text);
    const owned_bools = try allocator.dupe(BoolSinkEdit, bools);
    errdefer allocator.free(owned_bools);
    const owned_changes = try allocator.dupe(ChangeSinkEdit, changes);
    errdefer allocator.free(owned_changes);
    return .{
        .text = owned_text,
        .bools = owned_bools,
        .changes = owned_changes,
        .structural = try allocator.dupe(StructuralSinkEdit, structural),
    };
}

fn editedSinkIndex(comptime Edit: type, record_id: u64, kind: anytype, initial: usize, prior: []const Edit) ?usize {
    var current = initial;
    for (prior) |edit| {
        if (edit.record_id != record_id) continue;
        if (@hasField(Edit, "kind") and edit.kind != kind) continue;
        if (edit.old_index != current) continue;
        current = edit.new_index orelse return null;
    }
    return current;
}

fn containsTextSinkAfter(routes: *const RouteTable(TextSink), prior: []const TextSinkEdit, edit: TextSinkEdit) bool {
    if (edit.record_id >= routes.items.len) return false;
    for (routes.items[@intCast(edit.record_id)].slice()) |sink| {
        if (sink.kind != edit.kind) continue;
        if (editedSinkIndex(TextSinkEdit, edit.record_id, edit.kind, sink.index, prior) == edit.old_index) return true;
    }
    return false;
}

fn containsBoolSinkAfter(routes: *const RouteTable(BoolSink), prior: []const BoolSinkEdit, edit: BoolSinkEdit) bool {
    if (edit.record_id >= routes.items.len) return false;
    for (routes.items[@intCast(edit.record_id)].slice()) |sink| {
        if (sink.kind != edit.kind) continue;
        if (editedSinkIndex(BoolSinkEdit, edit.record_id, edit.kind, sink.index, prior) == edit.old_index) return true;
    }
    return false;
}

fn containsChangeSinkAfter(routes: *const RouteTable(ChangeSink), prior: []const ChangeSinkEdit, edit: ChangeSinkEdit) bool {
    if (edit.record_id >= routes.items.len) return false;
    for (routes.items[@intCast(edit.record_id)].slice()) |sink| {
        if (editedSinkIndex(ChangeSinkEdit, edit.record_id, {}, sink.index, prior) == edit.old_index) return true;
    }
    return false;
}

fn containsStructuralSinkAfter(routes: *const RouteTable(StructuralSink), prior: []const StructuralSinkEdit, edit: StructuralSinkEdit) bool {
    if (edit.record_id >= routes.items.len) return false;
    for (routes.items[@intCast(edit.record_id)].slice()) |sink| {
        if (sink.kind != edit.kind) continue;
        if (editedSinkIndex(StructuralSinkEdit, edit.record_id, edit.kind, sink.index, prior) == edit.old_index) return true;
    }
    return false;
}

fn containsTextSink(routes: *const RouteTable(TextSink), edit: TextSinkEdit) bool {
    if (edit.record_id >= routes.items.len) return false;
    for (routes.items[@intCast(edit.record_id)].slice()) |sink| if (sink.kind == edit.kind and sink.index == edit.old_index) return true;
    return false;
}
fn containsBoolSink(routes: *const RouteTable(BoolSink), edit: BoolSinkEdit) bool {
    if (edit.record_id >= routes.items.len) return false;
    for (routes.items[@intCast(edit.record_id)].slice()) |sink| if (sink.kind == edit.kind and sink.index == edit.old_index) return true;
    return false;
}
fn containsChangeSink(routes: *const RouteTable(ChangeSink), edit: ChangeSinkEdit) bool {
    if (edit.record_id >= routes.items.len) return false;
    for (routes.items[@intCast(edit.record_id)].slice()) |sink| if (sink.index == edit.old_index) return true;
    return false;
}
fn containsStructuralSink(routes: *const RouteTable(StructuralSink), edit: StructuralSinkEdit) bool {
    if (edit.record_id >= routes.items.len) return false;
    for (routes.items[@intCast(edit.record_id)].slice()) |sink| if (sink.kind == edit.kind and sink.index == edit.old_index) return true;
    return false;
}

pub const DirtyStructuralSignal = struct {
    kind: StructuralKind,
    node_id: ids.NodeId,
    scope_id: ids.ScopeId,
    ordinal: ids.SiteOrdinal,
    record: *signal_records.Record,
    branch: ?scope_tree.Branch = null,
};

/// Returns dense source ids for the validated event route without rediscovering dependencies.
pub fn sourceSignalIdsForEvent(routes: []const EventRoute, event_id: ids.EventId) EventLookupError![]const ids.NodeId {
    if (event_id.raw() == 0) return EventLookupError.EventIdZero;

    const route_index = event_id.raw() - 1;
    if (route_index >= routes.len) return EventLookupError.MissingSignalEventRoute;

    const route = routes[@intCast(route_index)];
    if (route.event_id != event_id) return EventLookupError.SignalEventRouteIndexMismatch;
    return route.signal_ids;
}

/// Returns the validated payload schema attached to an active event route.
pub fn eventPayloadDescriptor(descriptors: []const EventDescriptor, event_id: ids.EventId) EventLookupError!boundary.BoundaryPayloadDescriptor {
    if (event_id.raw() == 0) return EventLookupError.EventIdZero;

    const event_index = event_id.raw() - 1;
    if (event_index >= descriptors.len) return EventLookupError.MissingEventDescriptor;

    const descriptor = descriptors[@intCast(event_index)];
    if (descriptor.event_id != event_id) return EventLookupError.EventDescriptorIndexMismatch;
    return descriptor.payload_descriptor;
}

/// Returns dense signal ids associated with for state from maintained indexes.
pub fn signalIdsForState(routes: []const StateRoute, state_id: ids.NodeId) SignalLookupError![]const u64 {
    if (state_id.raw() >= routes.len) return SignalLookupError.MissingSignalRoute;

    const route = routes[@intCast(state_id.raw())];
    if (route.state_id != state_id) return SignalLookupError.SignalRouteIndexMismatch;
    return route.signal_ids;
}

/// Returns stored forward adjacency for one signal without scanning the graph.
pub fn dependentSignalIdsForSignal(routes: []const DependentsRoute, signal_id: u64) SignalLookupError![]const u64 {
    if (signal_id >= routes.len) return SignalLookupError.MissingSignalDependentRoute;

    const route = routes[@intCast(signal_id)];
    if (route.signal_id != signal_id) return SignalLookupError.SignalDependentRouteIndexMismatch;
    return route.signal_ids;
}

/// Returns a signal's topological rank without traversing the dependency graph.
pub fn signalRank(descriptors: []const Descriptor, signal_id: u64) SignalLookupError!u64 {
    if (signal_id >= descriptors.len) return SignalLookupError.MissingSignalDescriptor;

    const descriptor = descriptors[@intCast(signal_id)];
    if (descriptor.signal_id != signal_id) return SignalLookupError.SignalDescriptorIndexMismatch;
    return descriptor.rank;
}

/// Returns the stored topological rank used for dependency-ordered scheduling.
pub fn rank(comptime Record: type, nodes: []const Node(Record), record_id: u64) u64 {
    return signal_graph.rank(Record, nodes, record_id) catch @panic("active signal record id has no graph node");
}

/// Returns stored forward adjacency for one signal without scanning the graph.
pub fn dependentIds(comptime Record: type, nodes: []const Node(Record), record_id: u64) []const u64 {
    return signal_graph.dependentIds(Record, nodes, record_id) catch @panic("active signal record id has no dependent table");
}

test "active graph route lookup helpers validate indexed ids" {
    const event_payload = boundary.BoundaryPayloadDescriptor.init(.str, .target_value);
    var route_signal_ids = [_]ids.NodeId{ ids.NodeId.fromRaw(3), ids.NodeId.fromRaw(5) };
    var source_event_ids = [_]ids.EventId{ ids.EventId.fromRaw(3), ids.EventId.fromRaw(5) };
    var state_signal_ids = [_]u64{7};
    var source_state_ids = [_]ids.NodeId{ids.NodeId.fromRaw(7)};
    var dependent_signal_ids = [_]u64{ 11, 13 };
    var empty_node_ids = [_]ids.NodeId{};
    var empty_event_ids = [_]ids.EventId{};

    const event_routes = [_]EventRoute{
        .{ .event_id = ids.EventId.fromRaw(1), .signal_ids = &route_signal_ids },
    };
    const mismatched_event_routes = [_]EventRoute{
        .{ .event_id = ids.EventId.fromRaw(2), .signal_ids = &route_signal_ids },
    };
    const event_descriptors = [_]EventDescriptor{
        .{ .event_id = ids.EventId.fromRaw(1), .payload_descriptor = event_payload },
    };
    const mismatched_event_descriptors = [_]EventDescriptor{
        .{ .event_id = ids.EventId.fromRaw(2), .payload_descriptor = event_payload },
    };
    const state_routes = [_]StateRoute{
        .{ .state_id = ids.NodeId.fromRaw(0), .signal_ids = &state_signal_ids },
    };
    const mismatched_state_routes = [_]StateRoute{
        .{ .state_id = ids.NodeId.fromRaw(1), .signal_ids = &state_signal_ids },
    };
    const dependent_routes = [_]DependentsRoute{
        .{ .signal_id = 0, .signal_ids = &dependent_signal_ids },
    };
    const mismatched_dependent_routes = [_]DependentsRoute{
        .{ .signal_id = 1, .signal_ids = &dependent_signal_ids },
    };
    const descriptors = [_]Descriptor{
        .{
            .signal_id = 0,
            .kind = .map,
            .source_state_ids = &source_state_ids,
            .source_event_ids = &source_event_ids,
            .input_signal_ids = &dependent_signal_ids,
            .rank = 9,
        },
    };
    const mismatched_descriptors = [_]Descriptor{
        .{
            .signal_id = 1,
            .kind = .source,
            .source_state_ids = &empty_node_ids,
            .source_event_ids = &empty_event_ids,
            .input_signal_ids = &.{},
            .rank = 0,
        },
    };

    try std.testing.expectEqualSlices(ids.NodeId, &route_signal_ids, try sourceSignalIdsForEvent(&event_routes, ids.EventId.fromRaw(1)));
    try std.testing.expectEqual(event_payload, try eventPayloadDescriptor(&event_descriptors, ids.EventId.fromRaw(1)));
    try std.testing.expectEqualSlices(u64, &state_signal_ids, try signalIdsForState(&state_routes, ids.NodeId.fromRaw(0)));
    try std.testing.expectEqualSlices(u64, &dependent_signal_ids, try dependentSignalIdsForSignal(&dependent_routes, 0));
    try std.testing.expectEqual(@as(u64, 9), try signalRank(&descriptors, 0));

    try std.testing.expectError(EventLookupError.EventIdZero, sourceSignalIdsForEvent(&event_routes, ids.EventId.fromRaw(0)));
    try std.testing.expectError(EventLookupError.MissingSignalEventRoute, sourceSignalIdsForEvent(&event_routes, ids.EventId.fromRaw(2)));
    try std.testing.expectError(EventLookupError.SignalEventRouteIndexMismatch, sourceSignalIdsForEvent(&mismatched_event_routes, ids.EventId.fromRaw(1)));

    try std.testing.expectError(EventLookupError.EventIdZero, eventPayloadDescriptor(&event_descriptors, ids.EventId.fromRaw(0)));
    try std.testing.expectError(EventLookupError.MissingEventDescriptor, eventPayloadDescriptor(&event_descriptors, ids.EventId.fromRaw(2)));
    try std.testing.expectError(EventLookupError.EventDescriptorIndexMismatch, eventPayloadDescriptor(&mismatched_event_descriptors, ids.EventId.fromRaw(1)));

    try std.testing.expectError(SignalLookupError.MissingSignalRoute, signalIdsForState(&state_routes, ids.NodeId.fromRaw(1)));
    try std.testing.expectError(SignalLookupError.SignalRouteIndexMismatch, signalIdsForState(&mismatched_state_routes, ids.NodeId.fromRaw(0)));

    try std.testing.expectError(SignalLookupError.MissingSignalDependentRoute, dependentSignalIdsForSignal(&dependent_routes, 1));
    try std.testing.expectError(SignalLookupError.SignalDependentRouteIndexMismatch, dependentSignalIdsForSignal(&mismatched_dependent_routes, 0));

    try std.testing.expectError(SignalLookupError.MissingSignalDescriptor, signalRank(&descriptors, 1));
    try std.testing.expectError(SignalLookupError.SignalDescriptorIndexMismatch, signalRank(&mismatched_descriptors, 0));
}

test "prepared sink route edits sweep failures and commit without allocation" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var text_routes: RouteTable(TextSink) = .empty;
    var bool_routes: RouteTable(BoolSink) = .empty;
    var change_routes: RouteTable(ChangeSink) = .empty;
    var structural_routes: RouteTable(StructuralSink) = .empty;
    defer {
        clearSinkRoutes(std.testing.allocator, &text_routes, &bool_routes, &change_routes, &structural_routes);
        text_routes.deinit(std.testing.allocator);
        bool_routes.deinit(std.testing.allocator);
        change_routes.deinit(std.testing.allocator);
        structural_routes.deinit(std.testing.allocator);
    }
    appendTextRoute(std.testing.allocator, &text_routes, 1, 0, .{ .kind = .text_node, .index = 0 });
    appendTextRoute(std.testing.allocator, &text_routes, 1, 0, .{ .kind = .text_attr, .index = 9 });
    appendBoolRoute(std.testing.allocator, &bool_routes, 1, 0, .{ .kind = .bool_attr, .index = 0 });
    appendBoolRoute(std.testing.allocator, &bool_routes, 1, 0, .{ .kind = .custom_bool_attr, .index = 9 });
    appendChangeRoute(std.testing.allocator, &change_routes, 1, 0, .{ .index = 0 });
    appendChangeRoute(std.testing.allocator, &change_routes, 1, 0, .{ .index = 9 });
    appendStructuralRoute(std.testing.allocator, &structural_routes, 1, 0, .{ .kind = .when, .index = 0 });
    appendStructuralRoute(std.testing.allocator, &structural_routes, 1, 0, .{ .kind = .each, .index = 9 });
    const text_edits = [_]TextSinkEdit{ .{ .record_id = 0, .kind = .text_node, .old_index = 0 }, .{ .record_id = 0, .kind = .text_attr, .old_index = 9, .new_index = 1 } };
    const bool_edits = [_]BoolSinkEdit{ .{ .record_id = 0, .kind = .bool_attr, .old_index = 0 }, .{ .record_id = 0, .kind = .custom_bool_attr, .old_index = 9, .new_index = 1 } };
    const change_edits = [_]ChangeSinkEdit{ .{ .record_id = 0, .old_index = 0 }, .{ .record_id = 0, .old_index = 9, .new_index = 1 } };
    const structural_edits = [_]StructuralSinkEdit{ .{ .record_id = 0, .kind = .when, .old_index = 0 }, .{ .record_id = 0, .kind = .each, .old_index = 9, .new_index = 1 } };

    var counter = FaultAllocator.init(std.testing.allocator);
    var baseline = try prepareSinkRouteEdits(counter.allocator(), &text_routes, &bool_routes, &change_routes, &structural_routes, &text_edits, &bool_edits, &change_edits, &structural_edits);
    const attempts = counter.attempts;
    for (1..attempts + 1) |failure_number| {
        var fault = FaultAllocator.init(std.testing.allocator);
        fault.configure(failure_number);
        try std.testing.expectError(error.OutOfMemory, prepareSinkRouteEdits(fault.allocator(), &text_routes, &bool_routes, &change_routes, &structural_routes, &text_edits, &bool_edits, &change_edits, &structural_edits));
        try std.testing.expectEqualSlices(TextSink, &.{ .{ .kind = .text_node, .index = 0 }, .{ .kind = .text_attr, .index = 9 } }, text_routes.items[0].slice());
        try std.testing.expectEqualSlices(BoolSink, &.{ .{ .kind = .bool_attr, .index = 0 }, .{ .kind = .custom_bool_attr, .index = 9 } }, bool_routes.items[0].slice());
    }
    counter.configure(1);
    baseline.apply(&text_routes, &bool_routes, &change_routes, &structural_routes);
    try std.testing.expectEqual(@as(usize, 0), counter.attempts);
    try std.testing.expectEqualSlices(TextSink, &.{.{ .kind = .text_attr, .index = 1 }}, text_routes.items[0].slice());
    try std.testing.expectEqualSlices(BoolSink, &.{.{ .kind = .custom_bool_attr, .index = 1 }}, bool_routes.items[0].slice());
    try std.testing.expectEqualSlices(ChangeSink, &.{.{ .index = 1 }}, change_routes.items[0].slice());
    try std.testing.expectEqualSlices(StructuralSink, &.{.{ .kind = .each, .index = 1 }}, structural_routes.items[0].slice());
    counter.configure(null);
    baseline.deinit(counter.allocator());
}

pub const DirtyRecordQueue = struct {
    generation: u64 = 0,
    seen_generations: shared_buffer.List(u64) = .empty,
    pending_record_ids: shared_buffer.List(u64) = .empty,
    ordered_record_ids: shared_buffer.List(u64) = .empty,
    rank_counts: shared_buffer.List(usize) = .empty,
    rank_offsets: shared_buffer.List(usize) = .empty,

    /// Reserves every buffer needed to collect any dirty closure in `nodes`.
    /// Once this succeeds, `collectForRoots` and `collectForSources` perform no
    /// allocator calls until the graph grows or gains a larger rank.
    pub fn reserveForGraph(self: *DirtyRecordQueue, comptime Record: type, allocator: std.mem.Allocator, nodes: []const Node(Record)) (std.mem.Allocator.Error || error{ResourceLimit})!void {
        var max_rank: u64 = 0;
        for (nodes) |node| max_rank = @max(max_rank, node.rank);
        const rank_len = std.math.add(usize, std.math.cast(usize, max_rank) orelse return error.ResourceLimit, 1) catch return error.ResourceLimit;
        try self.seen_generations.ensureTotalCapacity(allocator, nodes.len);
        try self.pending_record_ids.ensureTotalCapacity(allocator, nodes.len);
        try self.ordered_record_ids.ensureTotalCapacity(allocator, nodes.len);
        try self.rank_counts.ensureTotalCapacity(allocator, rank_len);
        try self.rank_offsets.ensureTotalCapacity(allocator, rank_len);
    }

    /// Releases every resource owned by this value and leaves no retained host or Roc ownership behind.
    pub fn deinit(self: *DirtyRecordQueue, allocator: std.mem.Allocator) void {
        self.seen_generations.deinit(allocator);
        self.pending_record_ids.deinit(allocator);
        self.ordered_record_ids.deinit(allocator);
        self.rank_counts.deinit(allocator);
        self.rank_offsets.deinit(allocator);
        self.* = .{};
    }

    /// Collects for sources from the explicitly affected graph or scope set.
    pub fn collectForSources(
        self: *DirtyRecordQueue,
        comptime Record: type,
        allocator: std.mem.Allocator,
        nodes: []const Node(Record),
        source_routes: []const SmallRouteList(u64),
        dirty_source_node_ids: []const u64,
    ) []const u64 {
        var max_rank: u64 = 0;
        self.begin(allocator, nodes.len);

        for (dirty_source_node_ids) |source_node_id| {
            const route_index: usize = @intCast(source_node_id);
            if (route_index >= source_routes.len) continue;

            for (source_routes[route_index].slice()) |record_id| {
                self.enqueueRecord(Record, allocator, nodes, record_id, &max_rank);
            }
        }

        return self.finish(Record, allocator, nodes, max_rank);
    }

    /// Collects for roots from the explicitly affected graph or scope set.
    pub fn collectForRoots(
        self: *DirtyRecordQueue,
        comptime Record: type,
        allocator: std.mem.Allocator,
        nodes: []const Node(Record),
        root_record_ids: []const u64,
    ) []const u64 {
        var max_rank: u64 = 0;
        self.begin(allocator, nodes.len);

        for (root_record_ids) |record_id| {
            self.enqueueRecord(Record, allocator, nodes, record_id, &max_rank);
        }

        return self.finish(Record, allocator, nodes, max_rank);
    }

    fn begin(self: *DirtyRecordQueue, allocator: std.mem.Allocator, node_count: usize) void {
        if (self.generation == std.math.maxInt(u64)) {
            @memset(self.seen_generations.items, 0);
            self.generation = 0;
        }
        self.generation += 1;

        const previous_len = self.seen_generations.items.len;
        if (previous_len < node_count) {
            self.seen_generations.resize(allocator, node_count) catch @panic("out of memory");
            @memset(self.seen_generations.items[previous_len..], 0);
        }

        self.pending_record_ids.clearRetainingCapacity();
        self.ordered_record_ids.clearRetainingCapacity();
    }

    fn finish(self: *DirtyRecordQueue, comptime Record: type, allocator: std.mem.Allocator, nodes: []const Node(Record), initial_max_rank: u64) []const u64 {
        var max_rank = initial_max_rank;
        var pending_index: usize = 0;
        while (pending_index < self.pending_record_ids.items.len) : (pending_index += 1) {
            const record_id = self.pending_record_ids.items[pending_index];
            for (dependentIds(Record, nodes, record_id)) |dependent_record_id| {
                if (comptime Record == signal_records.Record) {
                    switch (nodes[@intCast(dependent_record_id)].record.payload) {
                        .select, .keyed_select => continue,
                        else => {},
                    }
                }
                self.enqueueRecord(Record, allocator, nodes, dependent_record_id, &max_rank);
            }
        }

        self.writeRanked(Record, allocator, nodes, max_rank);
        return self.ordered_record_ids.items;
    }

    fn enqueueRecord(self: *DirtyRecordQueue, comptime Record: type, allocator: std.mem.Allocator, nodes: []const Node(Record), record_id: u64, max_rank: *u64) void {
        if (record_id >= nodes.len) @panic("dirty active signal root referenced an unknown record");
        const record_index: usize = @intCast(record_id);
        if (self.seen_generations.items[record_index] == self.generation) return;

        self.seen_generations.items[record_index] = self.generation;
        self.pending_record_ids.append(allocator, record_id) catch @panic("out of memory");
        if (nodes[record_index].rank > max_rank.*) {
            max_rank.* = nodes[record_index].rank;
        }
    }

    fn writeRanked(self: *DirtyRecordQueue, comptime Record: type, allocator: std.mem.Allocator, nodes: []const Node(Record), max_rank: u64) void {
        if (self.pending_record_ids.items.len == 0) return;

        const rank_count = (std.math.cast(usize, max_rank) orelse @panic("dirty active signal rank exceeded addressable memory")) + 1;
        self.rank_counts.resize(allocator, rank_count) catch @panic("out of memory");
        self.rank_offsets.resize(allocator, rank_count) catch @panic("out of memory");
        @memset(self.rank_counts.items, 0);

        for (self.pending_record_ids.items) |record_id| {
            const record_index: usize = @intCast(record_id);
            const rank_index: usize = @intCast(nodes[record_index].rank);
            self.rank_counts.items[rank_index] += 1;
        }

        var offset: usize = 0;
        for (self.rank_counts.items, 0..) |count, index| {
            self.rank_offsets.items[index] = offset;
            offset += count;
        }

        self.ordered_record_ids.resize(allocator, self.pending_record_ids.items.len) catch @panic("out of memory");
        for (self.pending_record_ids.items) |record_id| {
            const record_index: usize = @intCast(record_id);
            const rank_index: usize = @intCast(nodes[record_index].rank);
            const output_index = self.rank_offsets.items[rank_index];
            self.rank_offsets.items[rank_index] = output_index + 1;
            self.ordered_record_ids.items[output_index] = record_id;
        }
    }
};

/// Records id in the metrics or lifecycle state owned by this operation.
pub fn recordId(comptime Record: type, nodes: []const Node(Record), record: *const Record) ?u64 {
    const record_id = record.active_graph_id orelse return null;
    if (record_id >= nodes.len) @panic("active signal record dense id exceeded the graph table");
    if (nodes[@intCast(record_id)].record != record) {
        @panic("active signal record dense id pointed at a different record");
    }
    return record_id;
}

/// Resolves a retained signal record to its dense id or rejects incoherent graph wiring.
pub fn requireRecordId(comptime Record: type, nodes: []const Node(Record), record: *const Record) u64 {
    return recordId(Record, nodes, record) orelse @panic("active signal graph referenced a record that was not registered");
}

/// Emits the already-decided command that attaches a newly created render node.
pub fn appendNode(comptime Record: type, allocator: std.mem.Allocator, nodes: *shared_buffer.List(Node(Record)), record: *Record, node_rank: u64) u64 {
    const record_id: u64 = @intCast(nodes.items.len);
    const input_slots = signal_graph.InputSlots.init(allocator, distinctInputCount(Record, record)) catch @panic("out of memory");
    nodes.append(allocator, .{
        .record = record.retain(),
        .rank = node_rank,
        .input_slots = input_slots,
    }) catch @panic("out of memory");
    record.active_graph_id = record_id;
    return record_id;
}

/// Appends the edge from every distinct input of `dependent_record_id` to it,
/// recording each edge's slot at the matching input position. The inputs must
/// already hold dense ids; ingestion appends the node first and then wires it.
pub fn appendInputEdges(comptime Record: type, allocator: std.mem.Allocator, nodes: []Node(Record), dependent_record_id: u64) void {
    var inputs = DistinctInputIterator(Record).init(nodes[@intCast(dependent_record_id)].record);
    while (inputs.next()) |input| {
        signal_graph.appendDependent(Record, allocator, nodes, requireRecordId(Record, nodes, input.record), dependent_record_id, input.position) catch |err| switch (err) {
            error.OutOfMemory => @panic("out of memory"),
            error.UnknownNode => @panic("active signal dependent referenced an unknown input record"),
            else => @panic("active signal dependent insertion missed its edge"),
        };
    }
}

/// Drops the edge `input_record_id -> dependent_record_id` through the
/// dependent's recorded slot at `input_position`, freeing the input's spilled
/// adjacency once it is inline-sized. Allocation-free.
pub fn removeDependentId(comptime Record: type, allocator: std.mem.Allocator, nodes: []Node(Record), input_record_id: u64, dependent_record_id: u64, input_position: u32) void {
    signal_graph.removeDependent(Record, allocator, nodes, input_record_id, dependent_record_id, input_position, InputPositionResolver(Record){}) catch |err| switch (err) {
        error.UnknownNode => @panic("active signal dependent removal referenced an unknown input record"),
        else => @panic("active signal dependent removal missed its edge"),
    };
}

/// Renumbers one edge in place through the slot stored on the dependent's
/// node at `dependent_node_id`.
pub fn replaceDependentId(comptime Record: type, nodes: []Node(Record), input_record_id: u64, dependent_node_id: u64, input_position: u32, old_dependent_id: u64, new_dependent_id: u64) void {
    signal_graph.replaceDependent(Record, nodes, input_record_id, dependent_node_id, input_position, old_dependent_id, new_dependent_id) catch |err| switch (err) {
        error.UnknownNode => @panic("active signal dependent rewrite referenced an unknown input record"),
        else => @panic("active signal dependent rewrite missed its edge"),
    };
}

/// Clears source routes while retaining bounded storage where the type promises reuse.
pub fn clearSourceRoutes(allocator: std.mem.Allocator, source_routes: *RouteTable(u64)) void {
    clearRouteTable(u64, allocator, source_routes);
}

/// Clears sink routes while retaining bounded storage where the type promises reuse.
pub fn clearSinkRoutes(
    allocator: std.mem.Allocator,
    text_routes: *RouteTable(TextSink),
    bool_routes: *RouteTable(BoolSink),
    change_routes: *RouteTable(ChangeSink),
    structural_routes: *RouteTable(StructuralSink),
) void {
    clearRouteTable(TextSink, allocator, text_routes);
    clearRouteTable(BoolSink, allocator, bool_routes);
    clearRouteTable(ChangeSink, allocator, change_routes);
    clearRouteTable(StructuralSink, allocator, structural_routes);
}

/// Clears routes while retaining bounded storage where the type promises reuse.
pub fn clearRoutes(
    allocator: std.mem.Allocator,
    source_routes: *RouteTable(u64),
    text_routes: *RouteTable(TextSink),
    bool_routes: *RouteTable(BoolSink),
    change_routes: *RouteTable(ChangeSink),
    structural_routes: *RouteTable(StructuralSink),
) void {
    clearSourceRoutes(allocator, source_routes);
    clearSinkRoutes(allocator, text_routes, bool_routes, change_routes, structural_routes);
}

/// Ensures source route capacity or state before publication can begin.
pub fn ensureSourceRoute(allocator: std.mem.Allocator, source_routes: *RouteTable(u64), source_node_count: usize, source_node_id: u64) *SmallRouteList(u64) {
    if (source_node_id >= source_node_count) @panic("active source signal route referenced an unknown source node");
    const route_index: usize = @intCast(source_node_id);
    while (source_routes.items.len <= route_index) {
        source_routes.append(allocator, .empty) catch @panic("out of memory");
    }
    return &source_routes.items[route_index];
}

/// Appends source route using capacity that must already satisfy the caller's transaction contract.
pub fn appendSourceRoute(allocator: std.mem.Allocator, source_routes: *RouteTable(u64), source_node_count: usize, source_node_id: u64, record_id: u64) void {
    const route = ensureSourceRoute(allocator, source_routes, source_node_count, source_node_id);
    if (!containsU64(route.slice(), record_id)) {
        route.append(allocator, record_id) catch @panic("out of memory");
    }
}

/// Appends fresh source route using capacity that must already satisfy the caller's transaction contract.
pub fn appendFreshSourceRoute(allocator: std.mem.Allocator, source_routes: *RouteTable(u64), source_node_count: usize, source_node_id: u64, record_id: u64) void {
    const route = ensureSourceRoute(allocator, source_routes, source_node_count, source_node_id);
    route.append(allocator, record_id) catch @panic("out of memory");
}

/// Removes source route and releases the ownership attached to that live entry.
pub fn removeSourceRoute(source_routes: *RouteTable(u64), source_node_id: u64, record_id: u64) void {
    if (source_node_id >= source_routes.items.len) @panic("active source signal route removal referenced an unknown source node");
    var route = &source_routes.items[@intCast(source_node_id)];
    for (route.slice(), 0..) |existing_id, index| {
        if (existing_id != record_id) continue;
        _ = route.swapRemove(index);
        return;
    }
    @panic("active source signal route removal missed its record");
}

/// Replaces source route id while releasing displaced ownership exactly once.
pub fn replaceSourceRouteId(source_routes: *RouteTable(u64), source_node_id: u64, old_record_id: u64, new_record_id: u64) void {
    if (source_node_id >= source_routes.items.len) @panic("active source signal route rewrite referenced an unknown source node");
    const route = source_routes.items[@intCast(source_node_id)].mutableSlice();
    for (route) |*existing_id| {
        if (existing_id.* != old_record_id) continue;
        existing_id.* = new_record_id;
        return;
    }
    @panic("active source signal route rewrite missed its record");
}

/// Ensures text route capacity or state before publication can begin.
pub fn ensureTextRoute(allocator: std.mem.Allocator, text_routes: *RouteTable(TextSink), graph_len: usize, record_id: u64) *SmallRouteList(TextSink) {
    return ensureSinkRoute(TextSink, allocator, text_routes, graph_len, record_id, "active text signal route referenced an unknown signal record");
}

/// Ensures bool route capacity or state before publication can begin.
pub fn ensureBoolRoute(allocator: std.mem.Allocator, bool_routes: *RouteTable(BoolSink), graph_len: usize, record_id: u64) *SmallRouteList(BoolSink) {
    return ensureSinkRoute(BoolSink, allocator, bool_routes, graph_len, record_id, "active bool signal route referenced an unknown signal record");
}

/// Ensures change route capacity or state before publication can begin.
pub fn ensureChangeRoute(allocator: std.mem.Allocator, change_routes: *RouteTable(ChangeSink), graph_len: usize, record_id: u64) *SmallRouteList(ChangeSink) {
    return ensureSinkRoute(ChangeSink, allocator, change_routes, graph_len, record_id, "active change signal route referenced an unknown signal record");
}

/// Ensures structural route capacity or state before publication can begin.
pub fn ensureStructuralRoute(allocator: std.mem.Allocator, structural_routes: *RouteTable(StructuralSink), graph_len: usize, record_id: u64) *SmallRouteList(StructuralSink) {
    return ensureSinkRoute(StructuralSink, allocator, structural_routes, graph_len, record_id, "active structural signal route referenced an unknown signal record");
}

/// Removes sink routes for record id and releases the ownership attached to that live entry.
pub fn removeSinkRoutesForRecordId(
    allocator: std.mem.Allocator,
    text_routes: *RouteTable(TextSink),
    bool_routes: *RouteTable(BoolSink),
    change_routes: *RouteTable(ChangeSink),
    structural_routes: *RouteTable(StructuralSink),
    record_index: usize,
    last_index: usize,
) void {
    removeRouteTableRecordId(TextSink, allocator, text_routes, record_index, last_index, "active signal graph removed a record with live text sinks");
    removeRouteTableRecordId(BoolSink, allocator, bool_routes, record_index, last_index, "active signal graph removed a record with live bool sinks");
    removeRouteTableRecordId(ChangeSink, allocator, change_routes, record_index, last_index, "active signal graph removed a record with live change sinks");
    removeRouteTableRecordId(StructuralSink, allocator, structural_routes, record_index, last_index, "active signal graph removed a record with live structural sinks");
}

/// Appends text route using capacity that must already satisfy the caller's transaction contract.
pub fn appendTextRoute(allocator: std.mem.Allocator, text_routes: *RouteTable(TextSink), graph_len: usize, record_id: u64, route: TextSink) void {
    ensureTextRoute(allocator, text_routes, graph_len, record_id).append(allocator, route) catch @panic("out of memory");
}

/// Removes text route and releases the ownership attached to that live entry.
pub fn removeTextRoute(text_routes: *RouteTable(TextSink), record_id: u64, kind: TextSinkKind, index: usize) void {
    const route_index: usize = @intCast(record_id);
    if (route_index >= text_routes.items.len) @panic("active text signal route removal referenced an unknown signal record");
    var route = &text_routes.items[route_index];
    for (route.slice(), 0..) |sink, sink_index| {
        if (sink.kind == kind and sink.index == index) {
            _ = route.swapRemove(sink_index);
            return;
        }
    }
    @panic("active text signal route removal missed its sink");
}

/// Updates the dense text route descriptor index after a local structural splice.
pub fn updateTextRouteIndex(text_routes: *RouteTable(TextSink), record_id: u64, kind: TextSinkKind, old_index: usize, new_index: usize) void {
    if (old_index == new_index) return;
    const route_index: usize = @intCast(record_id);
    if (route_index >= text_routes.items.len) @panic("active text signal route update referenced an unknown signal record");
    for (text_routes.items[route_index].mutableSlice()) |*sink| {
        if (sink.kind == kind and sink.index == old_index) {
            sink.index = new_index;
            return;
        }
    }
    @panic("active text signal route update missed its sink");
}

/// Appends bool route using capacity that must already satisfy the caller's transaction contract.
pub fn appendBoolRoute(allocator: std.mem.Allocator, bool_routes: *RouteTable(BoolSink), graph_len: usize, record_id: u64, route: BoolSink) void {
    ensureBoolRoute(allocator, bool_routes, graph_len, record_id).append(allocator, route) catch @panic("out of memory");
}

/// Removes bool route and releases the ownership attached to that live entry.
pub fn removeBoolRoute(bool_routes: *RouteTable(BoolSink), record_id: u64, kind: BoolSinkKind, index: usize) void {
    const route_index: usize = @intCast(record_id);
    if (route_index >= bool_routes.items.len) @panic("active bool signal route removal referenced an unknown signal record");
    var route = &bool_routes.items[route_index];
    for (route.slice(), 0..) |sink, sink_index| {
        if (sink.kind == kind and sink.index == index) {
            _ = route.swapRemove(sink_index);
            return;
        }
    }
    @panic("active bool signal route removal missed its sink");
}

/// Updates the dense bool route descriptor index after a local structural splice.
pub fn updateBoolRouteIndex(bool_routes: *RouteTable(BoolSink), record_id: u64, kind: BoolSinkKind, old_index: usize, new_index: usize) void {
    if (old_index == new_index) return;
    const route_index: usize = @intCast(record_id);
    if (route_index >= bool_routes.items.len) @panic("active bool signal route update referenced an unknown signal record");
    for (bool_routes.items[route_index].mutableSlice()) |*sink| {
        if (sink.kind == kind and sink.index == old_index) {
            sink.index = new_index;
            return;
        }
    }
    @panic("active bool signal route update missed its sink");
}

/// Appends change route using capacity that must already satisfy the caller's transaction contract.
pub fn appendChangeRoute(allocator: std.mem.Allocator, change_routes: *RouteTable(ChangeSink), graph_len: usize, record_id: u64, route: ChangeSink) void {
    ensureChangeRoute(allocator, change_routes, graph_len, record_id).append(allocator, route) catch @panic("out of memory");
}

/// Removes change route and releases the ownership attached to that live entry.
pub fn removeChangeRoute(change_routes: *RouteTable(ChangeSink), record_id: u64, index: usize) void {
    const route_index: usize = @intCast(record_id);
    if (route_index >= change_routes.items.len) @panic("active change signal route removal referenced an unknown signal record");
    var route = &change_routes.items[route_index];
    for (route.slice(), 0..) |sink, sink_index| {
        if (sink.index == index) {
            _ = route.swapRemove(sink_index);
            return;
        }
    }
    @panic("active change signal route removal missed its sink");
}

/// Updates the dense change route descriptor index after a local structural splice.
pub fn updateChangeRouteIndex(change_routes: *RouteTable(ChangeSink), record_id: u64, old_index: usize, new_index: usize) void {
    if (old_index == new_index) return;
    const route_index: usize = @intCast(record_id);
    if (route_index >= change_routes.items.len) @panic("active change signal route update referenced an unknown signal record");
    for (change_routes.items[route_index].mutableSlice()) |*sink| {
        if (sink.index == old_index) {
            sink.index = new_index;
            return;
        }
    }
    @panic("active change signal route update missed its sink");
}

/// Appends structural route using capacity that must already satisfy the caller's transaction contract.
pub fn appendStructuralRoute(allocator: std.mem.Allocator, structural_routes: *RouteTable(StructuralSink), graph_len: usize, record_id: u64, route: StructuralSink) void {
    ensureStructuralRoute(allocator, structural_routes, graph_len, record_id).append(allocator, route) catch @panic("out of memory");
}

/// Removes structural route and releases the ownership attached to that live entry.
pub fn removeStructuralRoute(structural_routes: *RouteTable(StructuralSink), record_id: u64, kind: StructuralKind, index: usize) void {
    const route_index: usize = @intCast(record_id);
    if (route_index >= structural_routes.items.len) @panic("active structural signal route removal referenced an unknown signal record");
    var route = &structural_routes.items[route_index];
    for (route.slice(), 0..) |sink, sink_index| {
        if (sink.kind == kind and sink.index == index) {
            _ = route.swapRemove(sink_index);
            return;
        }
    }
    @panic("active structural signal route removal missed its sink");
}

/// Updates the dense structural route descriptor index after a local structural splice.
pub fn updateStructuralRouteIndex(structural_routes: *RouteTable(StructuralSink), record_id: u64, kind: StructuralKind, old_index: usize, new_index: usize) void {
    if (old_index == new_index) return;
    const route_index: usize = @intCast(record_id);
    if (route_index >= structural_routes.items.len) @panic("active structural signal route update referenced an unknown signal record");
    for (structural_routes.items[route_index].mutableSlice()) |*sink| {
        if (sink.kind == kind and sink.index == old_index) {
            sink.index = new_index;
            return;
        }
    }
    @panic("active structural signal route update missed its sink");
}

/// Records slice contains in the metrics or lifecycle state owned by this operation.
pub fn recordSliceContains(comptime Record: type, records: []const *Record, record: *Record) bool {
    for (records) |existing| {
        if (existing == record) return true;
    }
    return false;
}

/// One distinct input of a record together with its input position: the
/// index under which the record's node stores its adjacency slot for that
/// input (`Node.input_slots`).
pub fn DistinctInput(comptime Record: type) type {
    return struct { record: *Record, position: u32 };
}

/// Enumerates a record's distinct inputs in canonical position order: `map`
/// and selectors expose their single input, `map2` its left then right input
/// (once when they coincide), and `combine` each child at its first
/// occurrence. Every adjacency maintenance path derives input positions from
/// this iterator so slots recorded at ingestion resolve identically at
/// release, renumbering and audit time.
pub fn DistinctInputIterator(comptime Record: type) type {
    return struct {
        record: *Record,
        index: usize = 0,
        position: u32 = 0,

        /// Starts enumerating `record`'s distinct inputs from position zero.
        pub fn init(record: *Record) @This() {
            return .{ .record = record };
        }

        /// Returns the next distinct input, or null once every input was seen.
        pub fn next(self: *@This()) ?DistinctInput(Record) {
            const input: *Record = switch (self.record.payload) {
                .ref, .const_value, .interval_source, .entropy_seed_source, .location_source, .online_source, .visibility_source, .storage_source, .row_source => return null,
                .map => |payload| blk: {
                    if (self.index != 0) return null;
                    break :blk payload.input;
                },
                .select, .keyed_select => |payload| blk: {
                    if (self.index != 0) return null;
                    break :blk payload.input;
                },
                .map2 => |payload| blk: {
                    if (self.index == 0) break :blk payload.left;
                    if (self.index == 1 and payload.right != payload.left) break :blk payload.right;
                    return null;
                },
                .combine => |payload| blk: {
                    while (self.index < payload.children.len) : (self.index += 1) {
                        const child = payload.children[self.index];
                        if (!recordSliceContains(Record, payload.children[0..self.index], child)) break :blk child;
                    }
                    return null;
                },
            };
            self.index += 1;
            const position = self.position;
            self.position += 1;
            return .{ .record = input, .position = position };
        }
    };
}

/// Counts a record's distinct inputs: the arity of its `InputSlots`.
pub fn distinctInputCount(comptime Record: type, record: *Record) usize {
    var count: usize = 0;
    var inputs = DistinctInputIterator(Record).init(record);
    while (inputs.next()) |_| count += 1;
    return count;
}

/// Resolves the input position under which `record` reads `input`. Cost is
/// the record's own arity; a record that does not read `input` is a wiring
/// defect.
pub fn recordInputPosition(comptime Record: type, record: *Record, input: *const Record) u32 {
    var inputs = DistinctInputIterator(Record).init(record);
    while (inputs.next()) |entry| if (entry.record == input) return entry.position;
    @panic("active signal graph record does not read the given input");
}

/// Adapts `inputPosition` to the dense-id interface `signal_graph` uses when a
/// swap-removed edge moves another dependent's id into the vacated slot.
pub fn InputPositionResolver(comptime Record: type) type {
    return struct {
        /// Resolves the position under which the dependent at `dependent_id`
        /// reads the input at `input_id`; both are dense ids into `nodes`.
        pub fn inputPosition(_: @This(), nodes: []const Node(Record), dependent_id: u64, input_id: u64) u32 {
            return recordInputPosition(Record, nodes[@intCast(dependent_id)].record, nodes[@intCast(input_id)].record);
        }
    };
}

/// Appends input records using capacity that must already satisfy the caller's transaction contract.
pub fn appendInputRecords(comptime Record: type, allocator: std.mem.Allocator, records: *shared_buffer.List(*Record), record: *Record) void {
    switch (record.payload) {
        .ref, .const_value, .interval_source, .entropy_seed_source, .location_source, .online_source, .visibility_source, .storage_source, .row_source => {},
        .map => |payload| appendUniqueInputRecord(Record, allocator, records, payload.input),
        .select, .keyed_select => |payload| appendUniqueInputRecord(Record, allocator, records, payload.input),
        .map2 => |payload| {
            appendUniqueInputRecord(Record, allocator, records, payload.left);
            appendUniqueInputRecord(Record, allocator, records, payload.right);
        },
        .combine => |payload| {
            for (payload.children) |child| {
                appendUniqueInputRecord(Record, allocator, records, child);
            }
        },
    }
}

/// Adds active-graph ownership of a signal record and its retained payload.
pub fn retainRecord(
    comptime Record: type,
    allocator: std.mem.Allocator,
    nodes: *shared_buffer.List(Node(Record)),
    source_routes: *RouteTable(u64),
    source_node_count: usize,
    record: *Record,
    hooks: anytype,
) u64 {
    if (record.active_use_count != 0) {
        record.active_use_count += 1;
        return 0;
    }

    record.active_use_count = 1;
    var node_rank: u64 = 0;
    var records_rebuilt: u64 = 0;

    switch (record.payload) {
        .ref, .const_value, .interval_source, .entropy_seed_source, .location_source, .online_source, .visibility_source, .storage_source, .row_source => {},
        .map => |payload| {
            records_rebuilt += retainRecord(Record, allocator, nodes, source_routes, source_node_count, payload.input, hooks);
            const input_id = requireRecordId(Record, nodes.items, payload.input);
            node_rank = nodes.items[@intCast(input_id)].rank + 1;
        },
        .select, .keyed_select => |payload| {
            records_rebuilt += retainRecord(Record, allocator, nodes, source_routes, source_node_count, payload.input, hooks);
            const input_id = requireRecordId(Record, nodes.items, payload.input);
            node_rank = nodes.items[@intCast(input_id)].rank + 1;
        },
        .map2 => |payload| {
            records_rebuilt += retainRecord(Record, allocator, nodes, source_routes, source_node_count, payload.left, hooks);
            if (payload.right != payload.left) {
                records_rebuilt += retainRecord(Record, allocator, nodes, source_routes, source_node_count, payload.right, hooks);
            }
            const left_id = requireRecordId(Record, nodes.items, payload.left);
            const right_id = requireRecordId(Record, nodes.items, payload.right);
            node_rank = @max(
                nodes.items[@intCast(left_id)].rank,
                nodes.items[@intCast(right_id)].rank,
            ) + 1;
        },
        .combine => |payload| {
            for (payload.children, 0..) |child, index| {
                if (recordSliceContains(Record, payload.children[0..index], child)) continue;
                records_rebuilt += retainRecord(Record, allocator, nodes, source_routes, source_node_count, child, hooks);
                const child_id = requireRecordId(Record, nodes.items, child);
                node_rank = @max(node_rank, nodes.items[@intCast(child_id)].rank + 1);
            }
        },
    }

    const record_id = appendNode(Record, allocator, nodes, record, node_rank);
    records_rebuilt += 1;

    switch (record.payload) {
        // appendNode assigned a fresh active-graph id, so this route cannot
        // already contain it. Avoid a growing linear duplicate scan here.
        .ref => |source_node_id| appendFreshSourceRoute(allocator, source_routes, source_node_count, source_node_id, record_id),
        .const_value, .entropy_seed_source, .location_source, .online_source, .visibility_source, .storage_source => {},
        .row_source => hooks.ensureRowSource(record),
        .interval_source => |payload| hooks.ensureInterval(record.token().?, payload.period_ms),
        .select, .keyed_select => |payload| hooks.ensureSelector(payload.input, payload.key, record),
        .map, .map2, .combine => {},
    }
    appendInputEdges(Record, allocator, nodes.items, record_id);

    return records_rebuilt;
}

pub const PreparedReleaseStep = struct {
    record_id: u64,
    removal_index: u64,
    moved_record_id: ?u64,
};

/// A survivor input whose adjacency list a prepared transaction replaces at
/// commit. `record_id` is the input's original dense id. A compaction
/// (`rewrite_slots`) holds the survivors with final ids at live size and
/// must rewrite their recorded slots; a capacity clone made for an append
/// preserves the live prefix, so slots and the planned in-place edits still
/// apply to it. After `applyAdjacency`, `dependents` holds the displaced list
/// until `deinit` frees it.
pub const PreparedAdjacencyReplacement = struct {
    record_id: u64,
    dependents: signal_graph.OwnedAdjacency,
    rewrite_slots: bool,
};

/// One edge a prepared release drops in place: a retired dependent's edge
/// into a survivor input, addressed through the dependent's recorded slot.
pub const PreparedEdgeDrop = struct {
    input_id: u64,
    dependent_id: u64,
    position: u32,
};

/// One edge whose dependent id changes in place because that dependent
/// survives in a new dense slot after the retired records are removed.
pub const PreparedEdgeRenumber = struct {
    input_id: u64,
    dependent_id: u64,
    final_id: u64,
    position: u32,
};

/// Counters a preparation step reports to focused tests: `records` is every
/// committed graph record inspected, `edges` every adjacency entry read, and
/// `lookups` every record outside the committed graph resolved. Production
/// callers pass no counter; the counts exist so a test can prove that
/// preparation touched only the affected records rather than the whole graph.
pub const PreparationWork = struct {
    records: usize = 0,
    edges: usize = 0,
    lookups: usize = 0,
};

/// Sparse description of how a prepared release renumbers dense graph ids.
///
/// Only retired records and the survivors a swap-removal displaced have
/// entries; every other id keeps its slot. A survivor whose original id is
/// below `survivor_count` never moves (it is never the last live slot), so an
/// id without an entry maps to itself in both directions. Storage and lookups
/// are therefore proportional to the retired set, not to the graph.
pub const DenseRemap = struct {
    /// Original dense id to its final id, or null when the record retires.
    moved: std.AutoHashMapUnmanaged(u64, ?u64) = .empty,
    /// Final dense id to the original id of the displaced survivor now there.
    inverse: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    /// Committed graph length the remap was prepared against.
    original_count: usize,
    /// Graph length once the retired records are removed.
    survivor_count: usize,

    /// A remap for a graph of `count` records in which nothing retires or moves.
    pub fn identity(count: usize) DenseRemap {
        return .{ .original_count = count, .survivor_count = count };
    }

    /// Releases the sparse tables.
    pub fn deinit(self: *DenseRemap, allocator: std.mem.Allocator) void {
        self.moved.deinit(allocator);
        self.inverse.deinit(allocator);
        self.* = undefined;
    }

    /// Resolves a committed record's final dense id, or null once it retires.
    /// An id outside the committed graph is a caller defect.
    pub fn finalId(self: *const DenseRemap, original_id: u64) ?u64 {
        if (original_id >= self.original_count) @panic("dense remap queried an id outside the committed graph");
        if (self.moved.get(original_id)) |final| return final;
        return original_id;
    }

    /// Resolves the committed record that will occupy `final_id`, or null when
    /// that slot is beyond the survivors (a slot a later append will fill).
    pub fn originalId(self: *const DenseRemap, final_id: u64) ?u64 {
        if (final_id >= self.survivor_count) return null;
        return self.inverse.get(final_id) orelse final_id;
    }
};

/// Owns a read-only simulation of recursive active-record release and dense remaps.
///
/// Adjacency edits are planned per edge: each retired record's edge into a
/// survivor input is dropped through the dependent's recorded slot, and each
/// displaced survivor's edges are renumbered through the same slots, so the
/// prepared work and the commit are O(affected edges), never O(fan-out) of a
/// hot shared input. A survivor input whose spilled storage would keep more
/// than four times its live entries is instead rebuilt at its live size (a
/// compaction in `replacements`), which keeps retained capacity bounded while
/// staying amortized O(1) per dropped edge.
pub fn PreparedReleaseClosure(comptime Record: type) type {
    return struct {
        const Phase = enum {
            prepared,
            adjacency_committed,
            dense_committed,
            retired_released,
        };

        records: []*Record,
        steps: []PreparedReleaseStep,
        /// Sparse id renumbering the append and route planners resolve against.
        remap: DenseRemap,
        /// Use-count decrements owed to survivors whose count drops but never
        /// reaches zero once the same transaction's retains are netted in.
        survivor_use_decrements: []ExistingUseIncrement,
        /// Edges dropped in place at `applyAdjacency`, one per retired record
        /// and survivor input; compacted inputs are excluded.
        edge_drops: []PreparedEdgeDrop,
        /// Edges renumbered in place for displaced survivors; compacted inputs
        /// are excluded because their rebuilt lists already carry final ids.
        edge_renumbers: []PreparedEdgeRenumber,
        /// Survivor inputs whose lists are replaced at commit: release
        /// compactions, plus capacity clones the same transaction's append
        /// requested through `reserveAdjacencyForAppend`.
        replacements: shared_buffer.List(PreparedAdjacencyReplacement),
        /// Original input id to its index in `replacements`.
        replacement_index: std.AutoHashMapUnmanaged(u64, usize),
        /// Survivor inputs edited in place; their spilled storage is released
        /// after publication if the drops (net of the same transaction's
        /// appends) left it inline-sized.
        trimmed_inputs: []*Record,
        retired_nodes: []Node(Record),
        retired_text_routes: []SmallRouteList(TextSink),
        retired_bool_routes: []SmallRouteList(BoolSink),
        retired_change_routes: []SmallRouteList(ChangeSink),
        retired_structural_routes: []SmallRouteList(StructuralSink),
        phase: Phase = .prepared,

        /// A release that retires nothing from a graph of `count` records, for
        /// appends that follow no removal. Owns no storage, so `deinit` is a
        /// formality and every commit step is a no-op.
        pub fn none(count: usize) @This() {
            return .{
                .records = &.{},
                .steps = &.{},
                .remap = DenseRemap.identity(count),
                .survivor_use_decrements = &.{},
                .edge_drops = &.{},
                .edge_renumbers = &.{},
                .replacements = .empty,
                .replacement_index = .empty,
                .trimmed_inputs = &.{},
                .retired_nodes = &.{},
                .retired_text_routes = &.{},
                .retired_bool_routes = &.{},
                .retired_change_routes = &.{},
                .retired_structural_routes = &.{},
            };
        }

        /// Releases preparation storage without changing graph state.
        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.records);
            allocator.free(self.steps);
            self.remap.deinit(allocator);
            allocator.free(self.survivor_use_decrements);
            allocator.free(self.edge_drops);
            allocator.free(self.edge_renumbers);
            // Before commit each entry owns the prepared list; afterwards it
            // owns the list the commit displaced. Both are freed here.
            for (self.replacements.items) |*replacement| replacement.dependents.deinit(allocator);
            self.replacements.deinit(allocator);
            self.replacement_index.deinit(allocator);
            allocator.free(self.trimmed_inputs);
            if (self.phase == .dense_committed) @panic("committed graph retirement was not finalized");
            allocator.free(self.retired_nodes);
            allocator.free(self.retired_text_routes);
            allocator.free(self.retired_bool_routes);
            allocator.free(self.retired_change_routes);
            allocator.free(self.retired_structural_routes);
            self.* = undefined;
        }

        /// Guarantees that survivor `final_input_id` can take `extra` more
        /// dependents at commit without allocating. A list this release
        /// already replaces is grown in place (it is transaction-owned); a
        /// live list with room needs nothing; a full live list is cloned with
        /// geometric headroom and installed at `applyAdjacency`, so committed
        /// state is untouched until commit and a refusal leaks nothing. The
        /// clone costs O(live) but follows at least that many appends, so an
        /// added edge stays amortized O(1); `work` counts the entries copied.
        pub fn reserveAdjacencyForAppend(self: *@This(), allocator: std.mem.Allocator, nodes: []const Node(Record), final_input_id: u64, extra: usize, work: ?*PreparationWork) (std.mem.Allocator.Error || error{InvalidAppend})!void {
            if (self.phase != .prepared) @panic("release adjacency was reserved after commit");
            const original_id = self.remap.originalId(final_input_id) orelse return error.InvalidAppend;
            if (self.replacement_index.get(original_id)) |index| {
                return self.replacements.items[index].dependents.ensureUnusedCapacity(allocator, extra);
            }
            const live = &nodes[@intCast(original_id)].dependents;
            if (live.unusedCapacity() >= extra) return;
            if (work) |counter| counter.edges += live.len();
            try self.replacements.ensureUnusedCapacity(allocator, 1);
            try self.replacement_index.ensureUnusedCapacity(allocator, 1);
            var clone = try live.cloneWithCapacity(allocator, extra);
            errdefer clone.deinit(allocator);
            self.replacement_index.putAssumeCapacity(original_id, self.replacements.items.len);
            self.replacements.appendAssumeCapacity(.{ .record_id = original_id, .dependents = clone, .rewrite_slots = false });
        }

        /// Applies every prepared adjacency edit without allocation: installs
        /// compacted lists and rewrites their survivors' slots, drops retired
        /// edges by swap-remove, then renumbers displaced survivors' edges.
        /// Runs against original dense ids, before `applyDense`.
        pub fn applyAdjacency(self: *@This(), nodes: []Node(Record)) void {
            if (self.phase != .prepared) @panic("release closure adjacency was already committed");
            for (self.replacements.items) |*replacement| {
                const index: usize = @intCast(replacement.record_id);
                if (index >= nodes.len) @panic("prepared adjacency referenced an unknown record");
                const displaced = nodes[index].dependents;
                nodes[index].dependents = replacement.dependents;
                replacement.dependents = displaced;
                if (!replacement.rewrite_slots) continue;
                const input_record = nodes[index].record;
                for (nodes[index].dependents.slice(), 0..) |final_dependent, slot| {
                    const original_dependent = self.remap.originalId(final_dependent) orelse @panic("compacted adjacency listed a dependent outside the survivors");
                    const dependent = &nodes[@intCast(original_dependent)];
                    dependent.input_slots.set(recordInputPosition(Record, dependent.record, input_record), @intCast(slot));
                }
            }
            for (self.edge_drops) |drop| {
                signal_graph.unlinkDependent(Record, nodes, drop.input_id, drop.dependent_id, drop.position, InputPositionResolver(Record){}) catch @panic("prepared edge drop no longer matched the graph");
            }
            for (self.edge_renumbers) |edit| {
                signal_graph.replaceDependent(Record, nodes, edit.input_id, edit.dependent_id, edit.position, edit.dependent_id, edit.final_id) catch @panic("prepared edge renumber no longer matched the graph");
            }
            self.phase = .adjacency_committed;
        }

        /// Removes prepared dense nodes and parallel route slots without allocation.
        /// Descriptor sink routes must already have been removed from retiring records.
        pub fn applyDense(self: *@This(), nodes: *shared_buffer.List(Node(Record)), source_routes: *RouteTable(u64), text_routes: *RouteTable(TextSink), bool_routes: *RouteTable(BoolSink), change_routes: *RouteTable(ChangeSink), structural_routes: *RouteTable(StructuralSink)) void {
            if (self.phase != .adjacency_committed) @panic("dense graph retirement commit order was invalid");
            for (self.survivor_use_decrements) |decrement| {
                const record = nodes.items[@intCast(decrement.record_id)].record;
                // A survivor kept alive only by this transaction's retains
                // may touch zero here; the graph append publishing in the
                // same commit restores its count before anything observes it.
                if (record.active_use_count < decrement.count) @panic("prepared survivor use decrement underflowed a live record");
                record.active_use_count -= decrement.count;
            }
            // Source routes are keyed by source node, and only `ref` records
            // occupy them, so the retired and displaced refs name exactly the
            // route entries that change.
            for (self.records) |record| switch (record.payload) {
                .ref => |source_node_id| removeSourceRoute(source_routes, source_node_id, record.active_graph_id.?),
                else => {},
            };
            var displaced = self.remap.inverse.iterator();
            while (displaced.next()) |entry| {
                const original_id = entry.value_ptr.*;
                const final_id = entry.key_ptr.*;
                switch (nodes.items[@intCast(original_id)].record.payload) {
                    .ref => |source_node_id| replaceSourceRouteId(source_routes, source_node_id, original_id, final_id),
                    else => {},
                }
            }
            var live_len = nodes.items.len;
            for (self.steps, 0..) |step, step_index| {
                const removal_index: usize = @intCast(step.removal_index);
                const last_index = live_len - 1;
                if (nodes.items[removal_index].record != self.records[step_index]) @panic("prepared dense removal no longer matched graph record");
                self.retired_nodes[step_index] = nodes.swapRemove(removal_index);
                self.records[step_index].active_graph_id = null;
                self.records[step_index].active_use_count = 0;
                if (removal_index != last_index) nodes.items[removal_index].record.active_graph_id = @intCast(removal_index);
                retireRouteSlot(TextSink, text_routes, self.retired_text_routes, removal_index, last_index, step_index);
                retireRouteSlot(BoolSink, bool_routes, self.retired_bool_routes, removal_index, last_index, step_index);
                retireRouteSlot(ChangeSink, change_routes, self.retired_change_routes, removal_index, last_index, step_index);
                retireRouteSlot(StructuralSink, structural_routes, self.retired_structural_routes, removal_index, last_index, step_index);
                live_len = last_index;
            }
            text_routes.items.len = @min(text_routes.items.len, live_len);
            bool_routes.items.len = @min(bool_routes.items.len, live_len);
            change_routes.items.len = @min(change_routes.items.len, live_len);
            structural_routes.items.len = @min(structural_routes.items.len, live_len);
            self.phase = .dense_committed;
        }

        fn retireRouteSlot(comptime Route: type, routes: *RouteTable(Route), retired: []SmallRouteList(Route), removal_index: usize, last_index: usize, step_index: usize) void {
            if (removal_index >= routes.items.len) return;
            if (routes.items[removal_index].len() != 0) @panic("prepared graph removed a record with live sink routes");
            retired[step_index] = routes.items[removal_index];
            if (removal_index != last_index and last_index < routes.items.len) {
                routes.items[removal_index] = routes.items[last_index];
                routes.items[last_index] = .empty;
            } else routes.items[removal_index] = .empty;
        }

        /// Releases displaced graph buffers and record lifecycle ownership after publication.
        /// Counts the retired records that declare an interval source, so the
        /// owning transaction can reserve the host commands their cancellation
        /// emits at publication.
        pub fn retiredIntervalSourceCount(self: *const @This()) usize {
            var count: usize = 0;
            for (self.records) |record| {
                switch (record.payload) {
                    .interval_source => count += 1,
                    else => {},
                }
            }
            return count;
        }

        /// Releases every retired record after the dense graph committed:
        /// frees its adjacency, removes its interval registration through
        /// `hooks`, and hands the record itself to `hooks.releaseRecord`. Also
        /// trims the survivor inputs edited in place; this runs after the
        /// same transaction's append published, so a list it grew is never
        /// trimmed underneath it. `nodes` is the published graph.
        pub fn releaseRetired(self: *@This(), allocator: std.mem.Allocator, nodes: []Node(Record), hooks: anytype) void {
            if (self.phase != .dense_committed) @panic("retired graph ownership release order was invalid");
            for (self.trimmed_inputs) |input| {
                const input_id = input.active_graph_id orelse @panic("trimmed adjacency input lost its dense id");
                nodes[@intCast(input_id)].dependents.trim(allocator);
            }
            for (self.retired_nodes) |node| {
                var dependents = node.dependents;
                dependents.deinit(allocator);
                var input_slots = node.input_slots;
                input_slots.deinit(allocator);
                switch (node.record.payload) {
                    .interval_source => hooks.removeInterval(node.record.token().?),
                    else => {},
                }
                hooks.releaseRecord(node.record);
            }
            for (self.retired_text_routes) |*route| route.deinit(allocator);
            for (self.retired_bool_routes) |*route| route.deinit(allocator);
            for (self.retired_change_routes) |*route| route.deinit(allocator);
            for (self.retired_structural_routes) |*route| route.deinit(allocator);
            self.phase = .retired_released;
        }
    };
}

pub const ExistingUseIncrement = struct { record_id: u64, count: usize };

/// One edge a prepared append adds from a survivor input (final dense id) to
/// a new record, appended into capacity reserved during preparation.
pub const SurvivorEdgeAppend = struct {
    input_id: u64,
    dependent_id: u64,
    position: u32,
};

/// Owns read-only topology and use-count decisions for replacement records.
///
/// Edges between new records are built in the new nodes during preparation.
/// Edges from survivor inputs are recorded one per edge and appended at
/// `commitNodes` into capacity reserved on the input's list (through the
/// release closure's `reserveAdjacencyForAppend`), so adding a row that reads
/// a hot shared signal costs O(1) amortized on that signal, not a copy of its
/// fan-out on every append.
pub fn PreparedGraphAppend(comptime Record: type) type {
    return struct {
        const Phase = enum { prepared, committed };

        records: []*Record,
        record_ids: []u64,
        ranks: []u64,
        use_counts: []usize,
        existing_use_increments: []ExistingUseIncrement,
        survivor_edges: []SurvivorEdgeAppend,
        new_nodes: []Node(Record),
        survivor_count: usize,
        phase: Phase = .prepared,

        /// Counts the appended records that declare an interval source, so the
        /// owning transaction can reserve interval-registry capacity before
        /// publication.
        pub fn appendedIntervalSourceCount(self: *const @This()) usize {
            var count: usize = 0;
            for (self.new_nodes) |node| {
                switch (node.record.payload) {
                    .interval_source => count += 1,
                    else => {},
                }
            }
            return count;
        }

        /// Counts newly appended keyed-row source records so the engine can
        /// reserve its stable row-handle index before graph publication.
        pub fn appendedRowSourceCount(self: *const @This()) usize {
            var count: usize = 0;
            for (self.new_nodes) |node| switch (node.record.payload) {
                .row_source => count += 1,
                else => {},
            };
            return count;
        }

        /// Registers the effect sources the committed append introduced. This
        /// is the publication-side counterpart of `PreparedReleaseClosure.releaseRetired`
        /// removing retired sources: every interval record that enters the
        /// active graph through a prepared transaction must enter the interval
        /// registry here, or its later retirement has nothing to remove.
        /// Must run after `commitNodes`; the hooks must not allocate.
        pub fn registerAppendedEffects(self: *const @This(), hooks: anytype) void {
            if (self.phase != .committed) @panic("appended effect registration ran before graph publication");
            for (self.new_nodes) |node| {
                switch (node.record.payload) {
                    .interval_source => |payload| hooks.registerInterval(node.record.token().?, payload.period_ms),
                    .select, .keyed_select => |payload| hooks.registerSelector(payload.input, payload.key, node.record),
                    .row_source => hooks.registerRowSource(node.record),
                    else => {},
                }
            }
        }

        /// Reserves the dense node destination before any graph mutation.
        pub fn reservePublication(self: *const @This(), allocator: std.mem.Allocator, nodes: *shared_buffer.List(Node(Record))) (std.mem.Allocator.Error || error{InvalidAppend})!void {
            const final_count = std.math.add(usize, self.survivor_count, self.new_nodes.len) catch return error.InvalidAppend;
            try nodes.ensureTotalCapacity(allocator, final_count);
        }

        /// Reserves the parallel route-table slots for every final dense node.
        pub fn reserveParallelRoutes(
            self: *const @This(),
            allocator: std.mem.Allocator,
            text_routes: *RouteTable(TextSink),
            bool_routes: *RouteTable(BoolSink),
            change_routes: *RouteTable(ChangeSink),
            structural_routes: *RouteTable(StructuralSink),
        ) (std.mem.Allocator.Error || error{InvalidAppend})!void {
            const final_count = std.math.add(usize, self.survivor_count, self.new_nodes.len) catch return error.InvalidAppend;
            try text_routes.ensureTotalCapacity(allocator, final_count);
            try bool_routes.ensureTotalCapacity(allocator, final_count);
            try change_routes.ensureTotalCapacity(allocator, final_count);
            try structural_routes.ensureTotalCapacity(allocator, final_count);
        }

        /// Extends parallel route tables to the final graph length without allocating.
        pub fn commitParallelRoutes(
            self: *const @This(),
            text_routes: *RouteTable(TextSink),
            bool_routes: *RouteTable(BoolSink),
            change_routes: *RouteTable(ChangeSink),
            structural_routes: *RouteTable(StructuralSink),
        ) void {
            const final_count = self.survivor_count + self.new_nodes.len;
            if (text_routes.items.len > final_count or bool_routes.items.len > final_count or change_routes.items.len > final_count or structural_routes.items.len > final_count) @panic("replacement graph route tables exceeded their prepared length");
            while (text_routes.items.len < final_count) text_routes.appendAssumeCapacity(.empty);
            while (bool_routes.items.len < final_count) bool_routes.appendAssumeCapacity(.empty);
            while (change_routes.items.len < final_count) change_routes.appendAssumeCapacity(.empty);
            while (structural_routes.items.len < final_count) structural_routes.appendAssumeCapacity(.empty);
        }

        /// Resolves a record to the dense id it will have after publication.
        /// `remap` is the release remap this append was prepared against.
        pub fn plannedRecordId(self: *const @This(), remap: *const DenseRemap, original_nodes: []const Node(Record), record: *const Record) ?u64 {
            if (record.active_graph_id) |original_id| {
                const index: usize = @intCast(original_id);
                if (index >= original_nodes.len or original_nodes[index].record != record) return null;
                return remap.finalId(original_id);
            }
            for (self.records, self.record_ids) |planned, id| if (planned == record) return id;
            return null;
        }

        /// Returns the exact dense graph length after retirement and append.
        pub fn finalGraphCount(self: *const @This()) usize {
            return self.survivor_count + self.new_nodes.len;
        }

        /// Publishes prepared nodes, edges, ids, and use counts without allocating.
        /// Must follow the release closure's `applyDense`, so survivor lists
        /// (including compacted ones) are the lists whose capacity was reserved.
        pub fn commitNodes(self: *@This(), nodes: *shared_buffer.List(Node(Record))) void {
            if (self.phase != .prepared or nodes.items.len != self.survivor_count) @panic("replacement graph publication violated its prepared snapshot");
            for (self.existing_use_increments) |increment| {
                const record = nodes.items[@intCast(increment.record_id)].record;
                record.active_use_count += increment.count;
            }
            for (self.new_nodes, self.record_ids, self.use_counts) |*node, id, uses| {
                _ = node.record.retain();
                node.record.active_graph_id = id;
                node.record.active_use_count = uses;
                nodes.appendAssumeCapacity(node.*);
                node.dependents = .empty;
                node.input_slots = .empty;
            }
            for (self.survivor_edges) |edge| {
                signal_graph.appendDependentAssumeCapacity(Record, nodes.items, edge.input_id, edge.dependent_id, edge.position) catch @panic("prepared survivor edge referenced an unknown record");
            }
            self.phase = .committed;
        }

        /// Releases preparation storage without changing the active graph.
        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.records);
            allocator.free(self.record_ids);
            allocator.free(self.ranks);
            allocator.free(self.use_counts);
            allocator.free(self.existing_use_increments);
            allocator.free(self.survivor_edges);
            for (self.new_nodes) |*node| {
                node.dependents.deinit(allocator);
                node.input_slots.deinit(allocator);
            }
            allocator.free(self.new_nodes);
            self.* = undefined;
        }
    };
}

/// Resolves survivor records and topologically enumerates only missing records.
///
/// `release` is the release closure prepared for the same transaction (or
/// `PreparedReleaseClosure.none` when nothing retires): the append resolves ids
/// through its remap and asks it to reserve adjacency capacity for the edges
/// the append adds, so the commit sequence stays allocation-free and a refused
/// transaction leaves the committed graph untouched.
pub fn prepareGraphAppend(comptime Record: type, allocator: std.mem.Allocator, nodes: []const Node(Record), release: *PreparedReleaseClosure(Record), roots: []const *Record) (std.mem.Allocator.Error || error{InvalidAppend})!PreparedGraphAppend(Record) {
    return prepareGraphAppendWithWork(Record, allocator, nodes, release, roots, null);
}

/// Sparse per-original-record counter used while planning: the map holds only
/// records the plan touched and `order` remembers first-touch order so the
/// published increment list is deterministic.
const TouchedCounts = struct {
    counts: std.AutoHashMapUnmanaged(u64, usize) = .empty,
    order: shared_buffer.List(u64) = .empty,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.counts.deinit(allocator);
        self.order.deinit(allocator);
    }

    fn add(self: *@This(), allocator: std.mem.Allocator, key: u64, amount: usize) std.mem.Allocator.Error!bool {
        try self.order.ensureUnusedCapacity(allocator, 1);
        const entry = try self.counts.getOrPut(allocator, key);
        if (!entry.found_existing) {
            entry.value_ptr.* = 0;
            self.order.appendAssumeCapacity(key);
        }
        const next = std.math.add(usize, entry.value_ptr.*, amount) catch return false;
        entry.value_ptr.* = next;
        return true;
    }

    fn get(self: *const @This(), key: u64) usize {
        return self.counts.get(key) orelse 0;
    }
};

fn prepareGraphAppendWithWork(comptime Record: type, allocator: std.mem.Allocator, nodes: []const Node(Record), release: *PreparedReleaseClosure(Record), roots: []const *Record, work: ?*PreparationWork) (std.mem.Allocator.Error || error{InvalidAppend})!PreparedGraphAppend(Record) {
    if (work) |counter| counter.* = .{};
    const remap = &release.remap;
    if (remap.original_count != nodes.len) return error.InvalidAppend;
    const survivor_count = remap.survivor_count;
    var existing_counts: TouchedCounts = .{};
    defer existing_counts.deinit(allocator);
    var records: shared_buffer.List(*Record) = .empty;
    errdefer records.deinit(allocator);
    var ranks: shared_buffer.List(u64) = .empty;
    errdefer ranks.deinit(allocator);
    var uses: shared_buffer.List(usize) = .empty;
    errdefer uses.deinit(allocator);
    var new_record_indexes: std.AutoHashMapUnmanaged(*Record, usize) = .empty;
    defer new_record_indexes.deinit(allocator);

    const Builder = struct {
        fn retain(record: *Record, prepare_allocator: std.mem.Allocator, graph_nodes: []const Node(Record), mapping: *const DenseRemap, existing: *TouchedCounts, new_records: *shared_buffer.List(*Record), new_ranks: *shared_buffer.List(u64), new_uses: *shared_buffer.List(usize), indexes: *std.AutoHashMapUnmanaged(*Record, usize), counter: ?*PreparationWork) (std.mem.Allocator.Error || error{InvalidAppend})!struct { id: u64, rank: u64 } {
            if (record.active_graph_id) |original_id| {
                const index: usize = @intCast(original_id);
                if (index >= graph_nodes.len or graph_nodes[index].record != record) return error.InvalidAppend;
                if (counter) |c| c.records += 1;
                const final_id = mapping.finalId(original_id) orelse return error.InvalidAppend;
                if (!try existing.add(prepare_allocator, original_id, 1)) return error.InvalidAppend;
                return .{ .id = final_id, .rank = graph_nodes[index].rank };
            }
            if (counter) |c| c.lookups += 1;
            if (indexes.get(record)) |index| {
                new_uses.items[index] = std.math.add(usize, new_uses.items[index], 1) catch return error.InvalidAppend;
                return .{ .id = @intCast(mapping.survivor_count + index), .rank = new_ranks.items[index] };
            }
            var new_rank: u64 = 0;
            switch (record.payload) {
                .map => |payload| new_rank = std.math.add(u64, (try retain(payload.input, prepare_allocator, graph_nodes, mapping, existing, new_records, new_ranks, new_uses, indexes, counter)).rank, 1) catch return error.InvalidAppend,
                .select, .keyed_select => |payload| new_rank = std.math.add(u64, (try retain(payload.input, prepare_allocator, graph_nodes, mapping, existing, new_records, new_ranks, new_uses, indexes, counter)).rank, 1) catch return error.InvalidAppend,
                .map2 => |payload| {
                    const left = try retain(payload.left, prepare_allocator, graph_nodes, mapping, existing, new_records, new_ranks, new_uses, indexes, counter);
                    const right = if (payload.right == payload.left) left else try retain(payload.right, prepare_allocator, graph_nodes, mapping, existing, new_records, new_ranks, new_uses, indexes, counter);
                    new_rank = std.math.add(u64, @max(left.rank, right.rank), 1) catch return error.InvalidAppend;
                },
                .combine => |payload| for (payload.children, 0..) |child, child_index| {
                    if (recordSliceContains(Record, payload.children[0..child_index], child)) continue;
                    const child_rank = std.math.add(u64, (try retain(child, prepare_allocator, graph_nodes, mapping, existing, new_records, new_ranks, new_uses, indexes, counter)).rank, 1) catch return error.InvalidAppend;
                    new_rank = @max(new_rank, child_rank);
                },
                .ref, .const_value, .interval_source, .entropy_seed_source, .location_source, .online_source, .visibility_source, .storage_source, .row_source => {},
            }
            const id: u64 = @intCast(std.math.add(usize, mapping.survivor_count, new_records.items.len) catch return error.InvalidAppend);
            try new_records.append(prepare_allocator, record);
            try new_ranks.append(prepare_allocator, new_rank);
            try new_uses.append(prepare_allocator, 1);
            try indexes.put(prepare_allocator, record, new_records.items.len - 1);
            return .{ .id = id, .rank = new_rank };
        }
    };
    for (roots) |root| _ = try Builder.retain(root, allocator, nodes, remap, &existing_counts, &records, &ranks, &uses, &new_record_indexes, work);

    const owned_increments = try allocator.alloc(ExistingUseIncrement, existing_counts.order.items.len);
    errdefer allocator.free(owned_increments);
    for (owned_increments, existing_counts.order.items) |*increment, original_id| {
        const count = existing_counts.get(original_id);
        _ = std.math.add(usize, nodes[@intCast(original_id)].record.active_use_count, count) catch return error.InvalidAppend;
        increment.* = .{ .record_id = remap.finalId(original_id) orelse return error.InvalidAppend, .count = count };
    }
    const owned_records = try records.toOwnedSlice(allocator);
    errdefer allocator.free(owned_records);
    const record_ids = try allocator.alloc(u64, owned_records.len);
    errdefer allocator.free(record_ids);
    for (record_ids, 0..) |*id, index| id.* = @intCast(std.math.add(usize, survivor_count, index) catch return error.InvalidAppend);
    const owned_ranks = try ranks.toOwnedSlice(allocator);
    errdefer allocator.free(owned_ranks);
    const owned_uses = try uses.toOwnedSlice(allocator);
    errdefer allocator.free(owned_uses);
    const new_lists = try allocator.alloc(signal_graph.OwnedAdjacency, owned_records.len);
    defer allocator.free(new_lists);
    @memset(new_lists, .empty);
    errdefer for (new_lists) |*list| list.deinit(allocator);
    const new_slots = try allocator.alloc(signal_graph.InputSlots, owned_records.len);
    defer allocator.free(new_slots);
    @memset(new_slots, .empty);
    errdefer for (new_slots) |*slots| slots.deinit(allocator);
    for (new_slots, owned_records) |*slots, record| slots.* = try signal_graph.InputSlots.init(allocator, distinctInputCount(Record, record));
    // Survivor inputs gain edges in place: one planned edge each, plus one
    // capacity reservation per survivor input touched.
    var survivor_edges: shared_buffer.List(SurvivorEdgeAppend) = .empty;
    errdefer survivor_edges.deinit(allocator);
    var survivor_extra: TouchedCounts = .{};
    defer survivor_extra.deinit(allocator);
    for (owned_records, record_ids, 0..) |record, dependent_id, dependent_index| {
        var inputs = DistinctInputIterator(Record).init(record);
        while (inputs.next()) |input| {
            // A record outside the committed graph is one this append introduces.
            const original_id = input.record.active_graph_id orelse {
                if (work) |c| c.lookups += 1;
                const index = new_record_indexes.get(input.record) orelse return error.InvalidAppend;
                const slot = try new_lists[index].append(allocator, dependent_id);
                new_slots[dependent_index].set(input.position, slot);
                continue;
            };
            const original_index: usize = @intCast(original_id);
            if (original_index >= nodes.len or nodes[original_index].record != input.record) return error.InvalidAppend;
            const final_id = remap.finalId(original_id) orelse return error.InvalidAppend;
            if (work) |c| {
                c.records += 1;
                c.edges += 1;
            }
            if (!try survivor_extra.add(allocator, final_id, 1)) return error.InvalidAppend;
            try survivor_edges.append(allocator, .{ .input_id = final_id, .dependent_id = dependent_id, .position = input.position });
        }
    }
    for (survivor_extra.order.items) |final_id| {
        try release.reserveAdjacencyForAppend(allocator, nodes, final_id, survivor_extra.get(final_id), work);
    }
    const owned_survivor_edges = try survivor_edges.toOwnedSlice(allocator);
    errdefer allocator.free(owned_survivor_edges);
    const new_nodes = try allocator.alloc(Node(Record), owned_records.len);
    errdefer allocator.free(new_nodes);
    for (new_nodes, owned_records, owned_ranks, new_lists, new_slots) |*node, record, prepared_rank, *list, *slots| {
        node.* = .{ .record = record, .rank = prepared_rank, .dependents = list.*, .input_slots = slots.* };
        list.* = .empty;
        slots.* = .empty;
    }
    return .{
        .records = owned_records,
        .record_ids = record_ids,
        .ranks = owned_ranks,
        .use_counts = owned_uses,
        .existing_use_increments = owned_increments,
        .survivor_edges = owned_survivor_edges,
        .new_nodes = new_nodes,
        .survivor_count = survivor_count,
    };
}

/// Counts, per committed graph record, how many times the given roots retain
/// it: an existing record contributes one use per referencing edge and is not
/// entered, while a record outside the graph is walked once through its inputs.
/// This is the same walk `prepareGraphAppend` performs, so a release closure
/// prepared with the replacement roots nets the retains the append will add.
/// Only records the walk reaches gain an entry in `existing`.
fn countExistingRetainsWithWork(comptime Record: type, allocator: std.mem.Allocator, nodes: []const Node(Record), roots: []const *Record, existing: *TouchedCounts, work: ?*PreparationWork) (std.mem.Allocator.Error || error{InvalidRelease})!void {
    var visited: std.AutoHashMapUnmanaged(*Record, void) = .empty;
    defer visited.deinit(allocator);
    const root_capacity = std.math.cast(u32, roots.len) orelse return error.InvalidRelease;
    try visited.ensureUnusedCapacity(allocator, root_capacity);
    const Walker = struct {
        fn walk(record: *Record, walk_allocator: std.mem.Allocator, graph_nodes: []const Node(Record), counts: *TouchedCounts, seen: *std.AutoHashMapUnmanaged(*Record, void), counter: ?*PreparationWork) (std.mem.Allocator.Error || error{InvalidRelease})!void {
            if (record.active_graph_id) |original_id| {
                const index: usize = @intCast(original_id);
                if (index >= graph_nodes.len or graph_nodes[index].record != record) return error.InvalidRelease;
                if (counter) |c| c.records += 1;
                if (!try counts.add(walk_allocator, original_id, 1)) return error.InvalidRelease;
                return;
            }
            if (counter) |c| c.lookups += 1;
            const entry = try seen.getOrPut(walk_allocator, record);
            if (entry.found_existing) return;
            switch (record.payload) {
                .map => |payload| try walk(payload.input, walk_allocator, graph_nodes, counts, seen, counter),
                .select, .keyed_select => |payload| try walk(payload.input, walk_allocator, graph_nodes, counts, seen, counter),
                .map2 => |payload| {
                    try walk(payload.left, walk_allocator, graph_nodes, counts, seen, counter);
                    if (payload.right != payload.left) try walk(payload.right, walk_allocator, graph_nodes, counts, seen, counter);
                },
                .combine => |payload| for (payload.children, 0..) |child, child_index| {
                    if (recordSliceContains(Record, payload.children[0..child_index], child)) continue;
                    try walk(child, walk_allocator, graph_nodes, counts, seen, counter);
                },
                .ref, .const_value, .interval_source, .entropy_seed_source, .location_source, .online_source, .visibility_source, .storage_source, .row_source => {},
            }
        }
    };
    for (roots) |root| try Walker.walk(root, allocator, nodes, existing, &visited, work);
}

/// Simulates descriptor-root releases, recursive zero-use inputs, and dense
/// swap-remaps without mutating graph records or route state.
///
/// `retained_roots` are the records the same transaction will retain through
/// `prepareGraphAppend`. Their retains are netted against the releases first,
/// so a committed record that one descriptor drops while another picks it up
/// survives with its dense id instead of being retired and re-appended. Every
/// survivor whose count still falls is recorded and decremented at `applyDense`.
///
/// Work and reserved storage are proportional to the records the release
/// reaches (retired records, the survivors whose use counts change, the
/// displaced last-slot survivors) and to their edges, each addressed through
/// the dependent's recorded slot rather than by scanning an input's fan-out;
/// the rest of the graph is neither visited nor mirrored. `auditDenseIds` is
/// the whole-graph consistency check for tests and diagnostics.
pub fn prepareReleaseClosure(comptime Record: type, allocator: std.mem.Allocator, nodes: []const Node(Record), roots: []const *Record, retained_roots: []const *Record) (std.mem.Allocator.Error || error{InvalidRelease})!PreparedReleaseClosure(Record) {
    return prepareReleaseClosureWithWork(Record, allocator, nodes, roots, retained_roots, null);
}

fn prepareReleaseClosureWithWork(comptime Record: type, allocator: std.mem.Allocator, nodes: []const Node(Record), roots: []const *Record, retained_roots: []const *Record, work: ?*PreparationWork) (std.mem.Allocator.Error || error{InvalidRelease})!PreparedReleaseClosure(Record) {
    if (work) |counter| counter.* = .{};
    // Simulation scratch that never reaches the returned closure comes from
    // one arena, so a refusal releases it in one step instead of replaying
    // every table's teardown at each error exit.
    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();
    var retained: TouchedCounts = .{};
    try countExistingRetainsWithWork(Record, scratch, nodes, retained_roots, &retained, work);

    // Remaining use count per touched record, netted against the retains.
    var counts: TouchedCounts = .{};
    var records: shared_buffer.List(*Record) = .empty;
    errdefer records.deinit(allocator);
    const Simulator = struct {
        fn decrement(record: *Record, sim_allocator: std.mem.Allocator, out_allocator: std.mem.Allocator, graph_nodes: []const Node(Record), remaining: *TouchedCounts, retains: *const TouchedCounts, output: *shared_buffer.List(*Record), counter: ?*PreparationWork) (std.mem.Allocator.Error || error{InvalidRelease})!void {
            const record_id = record.active_graph_id orelse return error.InvalidRelease;
            const index: usize = @intCast(record_id);
            if (index >= graph_nodes.len or graph_nodes[index].record != record) return error.InvalidRelease;
            if (counter) |c| c.records += 1;
            try remaining.order.ensureUnusedCapacity(sim_allocator, 1);
            const entry = try remaining.counts.getOrPut(sim_allocator, record_id);
            if (!entry.found_existing) {
                entry.value_ptr.* = std.math.add(usize, record.active_use_count, retains.get(record_id)) catch return error.InvalidRelease;
                remaining.order.appendAssumeCapacity(record_id);
            }
            if (entry.value_ptr.* == 0) return error.InvalidRelease;
            entry.value_ptr.* -= 1;
            if (entry.value_ptr.* != 0) return;
            try output.append(out_allocator, record);
            switch (record.payload) {
                .map => |payload| try decrement(payload.input, sim_allocator, out_allocator, graph_nodes, remaining, retains, output, counter),
                .select, .keyed_select => |payload| try decrement(payload.input, sim_allocator, out_allocator, graph_nodes, remaining, retains, output, counter),
                .map2 => |payload| {
                    try decrement(payload.left, sim_allocator, out_allocator, graph_nodes, remaining, retains, output, counter);
                    if (payload.right != payload.left) try decrement(payload.right, sim_allocator, out_allocator, graph_nodes, remaining, retains, output, counter);
                },
                .combine => |payload| {
                    for (payload.children, 0..) |child, child_index| {
                        if (recordSliceContains(Record, payload.children[0..child_index], child)) continue;
                        try decrement(child, sim_allocator, out_allocator, graph_nodes, remaining, retains, output, counter);
                    }
                },
                .ref, .const_value, .interval_source, .entropy_seed_source, .location_source, .online_source, .visibility_source, .storage_source, .row_source => {},
            }
        }
    };
    for (roots) |root| try Simulator.decrement(root, scratch, allocator, nodes, &counts, &retained, &records, work);

    var decrement_count: usize = 0;
    for (counts.order.items) |record_id| {
        const remaining = counts.get(record_id);
        if (remaining != 0 and nodes[@intCast(record_id)].record.active_use_count + retained.get(record_id) != remaining) decrement_count += 1;
    }
    const survivor_use_decrements = try allocator.alloc(ExistingUseIncrement, decrement_count);
    errdefer allocator.free(survivor_use_decrements);
    var decrement_write: usize = 0;
    for (counts.order.items) |record_id| {
        const remaining = counts.get(record_id);
        const before = nodes[@intCast(record_id)].record.active_use_count + retained.get(record_id);
        if (remaining == 0 or before == remaining) continue;
        survivor_use_decrements[decrement_write] = .{ .record_id = record_id, .count = before - remaining };
        decrement_write += 1;
    }

    // Simulate the swap-removals. Only slots that diverge from the identity
    // layout are recorded: `position_of` maps a displaced original id to its
    // current slot and `slot_at` maps a slot to the original id now in it.
    var position_of: std.AutoHashMapUnmanaged(u64, usize) = .empty;
    var slot_at: std.AutoHashMapUnmanaged(usize, u64) = .empty;
    const step_capacity = std.math.cast(u32, records.items.len) orelse return error.InvalidRelease;
    try position_of.ensureTotalCapacity(scratch, step_capacity);
    try slot_at.ensureTotalCapacity(scratch, step_capacity);
    const steps = try allocator.alloc(PreparedReleaseStep, records.items.len);
    errdefer allocator.free(steps);
    var live_len = nodes.len;
    for (records.items, steps) |record, *step| {
        const original_id = record.active_graph_id.?;
        const removal_index = position_of.get(original_id) orelse @as(usize, @intCast(original_id));
        const last_index = live_len - 1;
        const moved_original_id = slot_at.get(last_index) orelse @as(u64, @intCast(last_index));
        step.* = .{
            .record_id = original_id,
            .removal_index = @intCast(removal_index),
            .moved_record_id = if (removal_index == last_index) null else moved_original_id,
        };
        if (removal_index != last_index) {
            slot_at.putAssumeCapacity(removal_index, moved_original_id);
            position_of.putAssumeCapacity(moved_original_id, removal_index);
        }
        live_len = last_index;
    }
    var remap: DenseRemap = .{ .original_count = nodes.len, .survivor_count = live_len };
    errdefer remap.deinit(allocator);
    try remap.moved.ensureTotalCapacity(allocator, step_capacity * 2);
    try remap.inverse.ensureTotalCapacity(allocator, step_capacity);
    for (records.items) |record| remap.moved.putAssumeCapacity(record.active_graph_id.?, null);
    var displaced = position_of.iterator();
    while (displaced.next()) |entry| {
        const original_id = entry.key_ptr.*;
        if (remap.moved.contains(original_id)) continue;
        const final_id: u64 = @intCast(entry.value_ptr.*);
        if (final_id == original_id) continue;
        remap.moved.putAssumeCapacity(original_id, final_id);
        remap.inverse.putAssumeCapacity(final_id, original_id);
    }

    // Adjacency edits are planned per edge. Retired records drop their edges
    // into survivor inputs; displaced survivors renumber theirs. Each edge is
    // addressed through the dependent's recorded slot, so the work here and
    // at commit is one entry per affected edge, never a copy of an input's
    // fan-out. A retired input's list is freed wholesale, so edges into it
    // are validated but not dropped.
    var drop_counts: TouchedCounts = .{};
    var edge_drops: shared_buffer.List(PreparedEdgeDrop) = .empty;
    errdefer edge_drops.deinit(allocator);
    for (records.items) |record| {
        const dependent_id = record.active_graph_id.?;
        var inputs = DistinctInputIterator(Record).init(record);
        while (inputs.next()) |input| {
            const input_id = try validatedEdge(Record, nodes, input.record, dependent_id, input.position, work);
            if (remap.finalId(input_id) == null) continue;
            if (!try drop_counts.add(scratch, input_id, 1)) return error.InvalidRelease;
            try edge_drops.append(allocator, .{ .input_id = input_id, .dependent_id = dependent_id, .position = input.position });
        }
    }
    var edge_renumbers: shared_buffer.List(PreparedEdgeRenumber) = .empty;
    errdefer edge_renumbers.deinit(allocator);
    // A survivor can be displaced by more than one step (it lands in a hole
    // that later becomes the last live slot); its edges renumber once, to
    // its final id.
    var renumbered: std.AutoHashMapUnmanaged(u64, void) = .empty;
    try renumbered.ensureTotalCapacity(scratch, step_capacity);
    for (steps) |step| {
        const moved_id = step.moved_record_id orelse continue;
        const final_id = remap.finalId(moved_id) orelse continue;
        if (final_id == moved_id) continue;
        if (renumbered.getOrPutAssumeCapacity(moved_id).found_existing) continue;
        const moved_record = nodes[@intCast(moved_id)].record;
        var inputs = DistinctInputIterator(Record).init(moved_record);
        while (inputs.next()) |input| {
            const input_id = try validatedEdge(Record, nodes, input.record, moved_id, input.position, work);
            if (remap.finalId(input_id) == null) return error.InvalidRelease;
            try edge_renumbers.append(allocator, .{ .input_id = input_id, .dependent_id = moved_id, .final_id = final_id, .position = input.position });
        }
    }
    // Bounded retained capacity: a survivor input whose spilled list would
    // keep more than four times its live entries is rebuilt at its live size
    // (in its existing order, with final ids). The copy costs O(live) and
    // follows at least three-quarters of the capacity worth of drops, so a
    // dropped edge stays amortized O(1). Drops and renumbers into a compacted
    // input are subsumed by its rebuilt list.
    var replacements: shared_buffer.List(PreparedAdjacencyReplacement) = .empty;
    errdefer {
        for (replacements.items) |*replacement| replacement.dependents.deinit(allocator);
        replacements.deinit(allocator);
    }
    var replacement_index: std.AutoHashMapUnmanaged(u64, usize) = .empty;
    errdefer replacement_index.deinit(allocator);
    var trimmed: shared_buffer.List(*Record) = .empty;
    errdefer trimmed.deinit(allocator);
    for (drop_counts.order.items) |input_id| {
        const current = &nodes[@intCast(input_id)].dependents;
        const live_after = current.len() - drop_counts.get(input_id);
        if (live_after <= 1 or !current.shouldCompact(live_after)) {
            try trimmed.append(allocator, nodes[@intCast(input_id)].record);
            continue;
        }
        if (work) |counter| counter.edges += current.len();
        const replacement = try allocator.alloc(u64, live_after);
        errdefer allocator.free(replacement);
        var write: usize = 0;
        for (current.slice()) |dependent_id| {
            const final_id = remap.finalId(dependent_id) orelse continue;
            if (write == live_after) return error.InvalidRelease;
            replacement[write] = final_id;
            write += 1;
        }
        if (write != live_after) return error.InvalidRelease;
        try replacement_index.put(allocator, input_id, replacements.items.len);
        try replacements.append(allocator, .{ .record_id = input_id, .dependents = signal_graph.OwnedAdjacency.adopt(allocator, replacement), .rewrite_slots = true });
    }
    if (replacement_index.count() != 0) {
        var kept: usize = 0;
        for (edge_drops.items) |drop| {
            if (replacement_index.contains(drop.input_id)) continue;
            edge_drops.items[kept] = drop;
            kept += 1;
        }
        edge_drops.items.len = kept;
        kept = 0;
        for (edge_renumbers.items) |edit| {
            if (replacement_index.contains(edit.input_id)) continue;
            edge_renumbers.items[kept] = edit;
            kept += 1;
        }
        edge_renumbers.items.len = kept;
    }
    const retired_nodes = try allocator.alloc(Node(Record), records.items.len);
    errdefer allocator.free(retired_nodes);
    const retired_text_routes = try allocator.alloc(SmallRouteList(TextSink), records.items.len);
    errdefer allocator.free(retired_text_routes);
    @memset(retired_text_routes, .empty);
    const retired_bool_routes = try allocator.alloc(SmallRouteList(BoolSink), records.items.len);
    errdefer allocator.free(retired_bool_routes);
    @memset(retired_bool_routes, .empty);
    const retired_change_routes = try allocator.alloc(SmallRouteList(ChangeSink), records.items.len);
    errdefer allocator.free(retired_change_routes);
    @memset(retired_change_routes, .empty);
    const retired_structural_routes = try allocator.alloc(SmallRouteList(StructuralSink), records.items.len);
    errdefer allocator.free(retired_structural_routes);
    @memset(retired_structural_routes, .empty);
    const owned_drops = try edge_drops.toOwnedSlice(allocator);
    errdefer allocator.free(owned_drops);
    const owned_renumbers = try edge_renumbers.toOwnedSlice(allocator);
    errdefer allocator.free(owned_renumbers);
    const owned_trimmed = try trimmed.toOwnedSlice(allocator);
    errdefer allocator.free(owned_trimmed);
    const owned_records = try records.toOwnedSlice(allocator);
    return .{
        .records = owned_records,
        .steps = steps,
        .remap = remap,
        .survivor_use_decrements = survivor_use_decrements,
        .edge_drops = owned_drops,
        .edge_renumbers = owned_renumbers,
        .replacements = replacements,
        .replacement_index = replacement_index,
        .trimmed_inputs = owned_trimmed,
        .retired_nodes = retired_nodes,
        .retired_text_routes = retired_text_routes,
        .retired_bool_routes = retired_bool_routes,
        .retired_change_routes = retired_change_routes,
        .retired_structural_routes = retired_structural_routes,
    };
}

/// Checks that the committed edge `input -> dependent_id` exists exactly where
/// the dependent's slot at `position` says, returning the input's dense id.
/// One adjacency entry is read, which `work` counts.
fn validatedEdge(comptime Record: type, nodes: []const Node(Record), input: *Record, dependent_id: u64, position: u32, work: ?*PreparationWork) error{InvalidRelease}!u64 {
    const input_id = input.active_graph_id orelse return error.InvalidRelease;
    if (input_id >= nodes.len or nodes[@intCast(input_id)].record != input) return error.InvalidRelease;
    const dependent = nodes[@intCast(dependent_id)];
    if (position >= dependent.input_slots.len()) return error.InvalidRelease;
    const slot = dependent.input_slots.get(position);
    const dependents = nodes[@intCast(input_id)].dependents.slice();
    if (work) |counter| counter.edges += 1;
    if (slot >= dependents.len or dependents[slot] != dependent_id) return error.InvalidRelease;
    return input_id;
}

/// Whole-graph audit that every dense slot holds a record carrying that slot
/// as its id. This is O(graph) by construction and belongs in tests and debug
/// diagnostics; production release preparation validates only the records it
/// touches.
pub fn auditDenseIds(comptime Record: type, nodes: []const Node(Record)) error{InvalidRelease}!void {
    var total_edges: usize = 0;
    var total_inputs: usize = 0;
    for (nodes, 0..) |node, index| {
        if (node.record.active_graph_id != @as(u64, @intCast(index))) return error.InvalidRelease;
        for (node.dependents.slice()) |dependent_id| if (dependent_id >= nodes.len) return error.InvalidRelease;
        total_edges += node.dependents.len();
        // Every input's recorded slot must point back at this record, and the
        // edge totals must match so no stale entry survives anywhere.
        var arity: usize = 0;
        var inputs = DistinctInputIterator(Record).init(node.record);
        while (inputs.next()) |input| {
            _ = try validatedEdge(Record, nodes, input.record, @intCast(index), input.position, null);
            arity += 1;
        }
        if (arity != node.input_slots.len()) return error.InvalidRelease;
        total_inputs += arity;
    }
    if (total_edges != total_inputs) return error.InvalidRelease;
}

/// Releases the test or plan's owned signal record exactly once.
pub fn releaseRecord(
    comptime Record: type,
    allocator: std.mem.Allocator,
    nodes: *shared_buffer.List(Node(Record)),
    source_routes: *RouteTable(u64),
    text_routes: *RouteTable(TextSink),
    bool_routes: *RouteTable(BoolSink),
    change_routes: *RouteTable(ChangeSink),
    structural_routes: *RouteTable(StructuralSink),
    record: *Record,
    hooks: anytype,
) void {
    if (record.active_use_count == 0) @panic("active signal graph record use count underflow");
    record.active_use_count -= 1;
    if (record.active_use_count != 0) return;

    const record_id = requireRecordId(Record, nodes.items, record);
    var input_records: shared_buffer.List(*Record) = .empty;
    defer input_records.deinit(allocator);
    appendInputRecords(Record, allocator, &input_records, record);

    switch (record.payload) {
        .ref => |source_node_id| removeSourceRoute(source_routes, source_node_id, record_id),
        .const_value, .entropy_seed_source, .location_source, .online_source, .visibility_source, .storage_source, .row_source => {},
        .interval_source => hooks.removeInterval(record.token().?),
        .map, .map2, .select, .keyed_select, .combine => {},
    }

    for (input_records.items, 0..) |input_record, position| {
        removeDependentId(Record, allocator, nodes.items, requireRecordId(Record, nodes.items, input_record), record_id, @intCast(position));
    }

    removeNode(Record, allocator, nodes, source_routes, text_routes, bool_routes, change_routes, structural_routes, record_id, record, hooks);

    for (input_records.items) |input_record| {
        releaseRecord(Record, allocator, nodes, source_routes, text_routes, bool_routes, change_routes, structural_routes, input_record, hooks);
    }
}

/// Clears  while retaining bounded storage where the type promises reuse.
pub fn clear(comptime Record: type, allocator: std.mem.Allocator, nodes: *shared_buffer.List(Node(Record)), hooks: anytype) void {
    for (nodes.items, 0..) |node, index| {
        var dependents = node.dependents;
        dependents.deinit(allocator);
        var input_slots = node.input_slots;
        input_slots.deinit(allocator);
        const active_graph_id = node.record.active_graph_id orelse @panic("active signal graph record was missing its dense id");
        if (active_graph_id != @as(u64, @intCast(index))) @panic("active signal graph record dense id did not match its slot");
        node.record.active_graph_id = null;
        node.record.active_use_count = 0;
        hooks.releaseRecord(node.record);
    }
    nodes.items.len = 0;
}

/// Retains exactly the records referenced by the incoming descriptor stream.
pub fn retainStreamRecords(
    comptime Record: type,
    allocator: std.mem.Allocator,
    nodes: *shared_buffer.List(Node(Record)),
    source_routes: *RouteTable(u64),
    source_node_count: usize,
    stream: anytype,
    hooks: anytype,
) u64 {
    var records_rebuilt: u64 = 0;

    for (stream.signal_text_nodes.items) |*desc| {
        records_rebuilt += retainRecord(Record, allocator, nodes, source_routes, source_node_count, desc.signal.record, hooks);
    }
    for (stream.signal_text_attrs.items) |*desc| {
        records_rebuilt += retainRecord(Record, allocator, nodes, source_routes, source_node_count, desc.signal.record, hooks);
    }
    for (stream.signal_custom_text_attrs.items) |*desc| {
        records_rebuilt += retainRecord(Record, allocator, nodes, source_routes, source_node_count, desc.signal.record, hooks);
    }
    for (stream.signal_optional_custom_text_attrs.items) |*desc| {
        records_rebuilt += retainRecord(Record, allocator, nodes, source_routes, source_node_count, desc.signal.record, hooks);
    }
    for (stream.signal_bool_attrs.items) |*desc| {
        records_rebuilt += retainRecord(Record, allocator, nodes, source_routes, source_node_count, desc.signal.record, hooks);
    }
    for (stream.signal_custom_bool_attrs.items) |*desc| {
        records_rebuilt += retainRecord(Record, allocator, nodes, source_routes, source_node_count, desc.signal.record, hooks);
    }
    for (stream.on_changes.items) |*desc| {
        records_rebuilt += retainRecord(Record, allocator, nodes, source_routes, source_node_count, desc.signal.record, hooks);
    }
    for (stream.events.items) |desc| if (desc.handler.signalRoot()) |root| {
        records_rebuilt += retainRecord(Record, allocator, nodes, source_routes, source_node_count, root, hooks);
    };
    for (stream.whens.items) |*desc| {
        records_rebuilt += retainRecord(Record, allocator, nodes, source_routes, source_node_count, desc.condition.record, hooks);
    }
    for (stream.eaches.items) |*desc| {
        records_rebuilt += retainRecord(Record, allocator, nodes, source_routes, source_node_count, desc.items.record, hooks);
    }

    return records_rebuilt;
}

/// Rebuilds sink routes for initial ingestion from explicit descriptor edges.
pub fn rebuildSinkRoutesFromStream(
    comptime Record: type,
    allocator: std.mem.Allocator,
    nodes: []const Node(Record),
    text_routes: *RouteTable(TextSink),
    bool_routes: *RouteTable(BoolSink),
    change_routes: *RouteTable(ChangeSink),
    structural_routes: *RouteTable(StructuralSink),
    stream: anytype,
) void {
    clearSinkRoutes(allocator, text_routes, bool_routes, change_routes, structural_routes);

    for (stream.signal_text_nodes.items, 0..) |desc, index| {
        const id = requireRecordId(Record, nodes, desc.signal.record);
        appendTextRoute(allocator, text_routes, nodes.len, id, .{
            .kind = .text_node,
            .index = index,
        });
    }
    for (stream.signal_text_attrs.items, 0..) |desc, index| {
        const id = requireRecordId(Record, nodes, desc.signal.record);
        appendTextRoute(allocator, text_routes, nodes.len, id, .{
            .kind = .text_attr,
            .index = index,
        });
    }
    for (stream.signal_custom_text_attrs.items, 0..) |desc, index| {
        const id = requireRecordId(Record, nodes, desc.signal.record);
        appendTextRoute(allocator, text_routes, nodes.len, id, .{
            .kind = .custom_text_attr,
            .index = index,
        });
    }
    for (stream.signal_optional_custom_text_attrs.items, 0..) |desc, index| {
        const id = requireRecordId(Record, nodes, desc.signal.record);
        appendTextRoute(allocator, text_routes, nodes.len, id, .{
            .kind = .custom_text_optional_attr,
            .index = index,
        });
    }
    for (stream.signal_bool_attrs.items, 0..) |desc, index| {
        const id = requireRecordId(Record, nodes, desc.signal.record);
        appendBoolRoute(allocator, bool_routes, nodes.len, id, .{
            .kind = .bool_attr,
            .index = index,
        });
    }
    for (stream.signal_custom_bool_attrs.items, 0..) |desc, index| {
        const id = requireRecordId(Record, nodes, desc.signal.record);
        appendBoolRoute(allocator, bool_routes, nodes.len, id, .{
            .kind = .custom_bool_attr,
            .index = index,
        });
    }
    for (stream.on_changes.items, 0..) |desc, index| {
        const id = requireRecordId(Record, nodes, desc.signal.record);
        appendChangeRoute(allocator, change_routes, nodes.len, id, .{
            .index = index,
        });
    }
    for (stream.whens.items, 0..) |desc, index| {
        const id = requireRecordId(Record, nodes, desc.condition.record);
        appendStructuralRoute(allocator, structural_routes, nodes.len, id, .{
            .kind = .when,
            .index = index,
        });
    }
    for (stream.eaches.items, 0..) |desc, index| {
        const id = requireRecordId(Record, nodes, desc.items.record);
        appendStructuralRoute(allocator, structural_routes, nodes.len, id, .{
            .kind = .each,
            .index = index,
        });
    }
}

fn appendUniqueInputRecord(comptime Record: type, allocator: std.mem.Allocator, records: *shared_buffer.List(*Record), record: *Record) void {
    if (!recordSliceContains(Record, records.items, record)) {
        records.append(allocator, record) catch @panic("out of memory");
    }
}

/// Renumbers the edges and source route of a record that a dense swap-remove
/// just moved from `old_record_id` into `new_record_id`. Each edge is found
/// through the moved record's own slots, so the cost is its arity, not the
/// fan-out of its inputs.
fn updateMovedRecordEdges(comptime Record: type, nodes: []Node(Record), source_routes: *RouteTable(u64), moved_record: *Record, old_record_id: u64, new_record_id: u64) void {
    switch (moved_record.payload) {
        .ref => |source_node_id| replaceSourceRouteId(source_routes, source_node_id, old_record_id, new_record_id),
        else => {},
    }
    var inputs = DistinctInputIterator(Record).init(moved_record);
    while (inputs.next()) |input| {
        replaceDependentId(Record, nodes, requireRecordId(Record, nodes, input.record), new_record_id, input.position, old_record_id, new_record_id);
    }
}

fn removeNode(
    comptime Record: type,
    allocator: std.mem.Allocator,
    nodes: *shared_buffer.List(Node(Record)),
    source_routes: *RouteTable(u64),
    text_routes: *RouteTable(TextSink),
    bool_routes: *RouteTable(BoolSink),
    change_routes: *RouteTable(ChangeSink),
    structural_routes: *RouteTable(StructuralSink),
    record_id: u64,
    record: *Record,
    hooks: anytype,
) void {
    const record_index: usize = @intCast(record_id);
    if (record_index >= nodes.items.len) @panic("active signal graph removal referenced an unknown record");
    if (nodes.items[record_index].record != record) @panic("active signal graph removal referenced the wrong record");
    if (nodes.items[record_index].dependents.len() != 0) @panic("active signal graph removed a record with live dependents");

    nodes.items[record_index].dependents.deinit(allocator);
    nodes.items[record_index].input_slots.deinit(allocator);
    const last_index = nodes.items.len - 1;
    removeSinkRoutesForRecordId(allocator, text_routes, bool_routes, change_routes, structural_routes, record_index, last_index);
    _ = nodes.swapRemove(record_index);
    record.active_graph_id = null;
    hooks.releaseRecord(record);

    if (record_index != last_index) {
        const moved_id: u64 = @intCast(record_index);
        const old_moved_id: u64 = @intCast(last_index);
        const moved_record = nodes.items[record_index].record;
        moved_record.active_graph_id = moved_id;
        updateMovedRecordEdges(Record, nodes.items, source_routes, moved_record, old_moved_id, moved_id);
    }
}

fn ensureSinkRoute(comptime Route: type, allocator: std.mem.Allocator, routes: *RouteTable(Route), graph_len: usize, record_id: u64, comptime unknown_record_message: []const u8) *SmallRouteList(Route) {
    if (record_id >= graph_len) @panic(unknown_record_message);
    const route_index: usize = @intCast(record_id);
    while (routes.items.len <= route_index) {
        routes.append(allocator, .empty) catch @panic("out of memory");
    }
    return &routes.items[route_index];
}

fn clearRouteTable(comptime Route: type, allocator: std.mem.Allocator, routes: *RouteTable(Route)) void {
    for (routes.items) |*route| {
        route.deinit(allocator);
    }
    routes.items.len = 0;
}

fn removeRouteTableRecordId(
    comptime Route: type,
    allocator: std.mem.Allocator,
    routes: *RouteTable(Route),
    record_index: usize,
    last_index: usize,
    comptime live_route_message: []const u8,
) void {
    if (routes.items.len > last_index + 1) @panic("active sink route table exceeded active signal graph length");
    if (record_index >= routes.items.len) return;

    if (routes.items[record_index].len() != 0) @panic(live_route_message);
    routes.items[record_index].deinit(allocator);

    if (record_index != last_index and last_index < routes.items.len) {
        routes.items[record_index] = routes.items[last_index];
        routes.items[last_index] = .empty;
    } else {
        routes.items[record_index] = .empty;
    }

    if (routes.items.len == last_index + 1) {
        routes.items.len = last_index;
    }
}

fn containsU64(items: []const u64, target: u64) bool {
    for (items) |item| {
        if (item == target) return true;
    }
    return false;
}

const TestRecord = struct {
    id: u64,
};

/// Wires `input_id -> dependent_id` for the payload-free dirty-queue test
/// records: the dependent's next free position (counted from the edges it
/// already has) receives the slot, and two positions fit inline.
fn appendTestEdge(nodes: []Node(TestRecord), input_id: u64, dependent_id: u64) !void {
    var position: u32 = 0;
    for (nodes) |node| for (node.dependents.slice()) |existing| if (existing == dependent_id) {
        position += 1;
    };
    if (nodes[@intCast(dependent_id)].input_slots.len() == 0) nodes[@intCast(dependent_id)].input_slots = try signal_graph.InputSlots.init(std.testing.allocator, 2);
    try signal_graph.appendDependent(TestRecord, std.testing.allocator, nodes, input_id, dependent_id, position);
}

const LifecycleTestRecord = struct {
    id: u64,
    ref_count: usize = 1,
    payload: Payload,
    active_graph_id: ?u64 = null,
    active_use_count: usize = 0,

    const MapPayload = struct {
        input: *LifecycleTestRecord,
    };

    const Map2Payload = struct {
        left: *LifecycleTestRecord,
        right: *LifecycleTestRecord,
    };

    const SelectPayload = struct {
        input: *LifecycleTestRecord,
        key: []const u8,
    };

    const CombinePayload = struct {
        children: []*LifecycleTestRecord,
    };

    const IntervalPayload = struct {
        period_ms: u64,
    };

    const Payload = union(enum) {
        ref: u64,
        const_value,
        map: MapPayload,
        map2: Map2Payload,
        select: SelectPayload,
        keyed_select: SelectPayload,
        combine: CombinePayload,
        interval_source: IntervalPayload,
        entropy_seed_source,
        location_source,
        online_source,
        visibility_source,
        storage_source,
        row_source,
    };

    /// Acquires an independent retained reference that the caller must eventually release.
    pub fn retain(self: *LifecycleTestRecord) *LifecycleTestRecord {
        self.ref_count += 1;
        return self;
    }

    /// Returns the opaque identity token carried by this borrowed descriptor.
    pub fn token(self: *const LifecycleTestRecord) ?u64 {
        return switch (self.payload) {
            .ref => null,
            .const_value, .map, .map2, .select, .keyed_select, .combine, .interval_source, .entropy_seed_source, .location_source, .online_source, .visibility_source, .storage_source, .row_source => self.id,
        };
    }
};

const LifecycleTestHooks = struct {
    interval_ensures: u64 = 0,
    interval_removes: u64 = 0,
    record_releases: u64 = 0,

    /// Ensures interval capacity or state before publication can begin.
    pub fn ensureInterval(self: *@This(), token: u64, period_ms: u64) void {
        if (token == 0) @panic("test interval token must be explicit");
        if (period_ms == 0) @panic("test interval period must be explicit");
        self.interval_ensures += 1;
    }

    /// Registers an appended interval during publication without allocating.
    pub fn registerInterval(self: *@This(), token: u64, period_ms: u64) void {
        self.ensureInterval(token, period_ms);
    }

    /// Removes interval and releases the ownership attached to that live entry.
    pub fn removeInterval(self: *@This(), token: u64) void {
        if (token == 0) @panic("test interval token must be explicit");
        self.interval_removes += 1;
    }

    /// Records selector registration in lifecycle tests without owning a runtime index.
    pub fn ensureSelector(_: *@This(), _: *LifecycleTestRecord, _: []const u8, _: *LifecycleTestRecord) void {}

    /// Records prepared selector registration in lifecycle tests.
    pub fn registerSelector(self: *@This(), input: *LifecycleTestRecord, key: []const u8, member: *LifecycleTestRecord) void {
        self.ensureSelector(input, key, member);
    }

    /// Records keyed-row source registration in lifecycle tests.
    pub fn ensureRowSource(_: *@This(), _: *LifecycleTestRecord) void {}

    /// Records prepared keyed-row source registration in lifecycle tests.
    pub fn registerRowSource(self: *@This(), record: *LifecycleTestRecord) void {
        self.ensureRowSource(record);
    }

    /// Releases the test or plan's owned signal record exactly once.
    pub fn releaseRecord(self: *@This(), record: *LifecycleTestRecord) void {
        if (record.ref_count == 0) @panic("test record release underflow");
        record.ref_count -= 1;
        self.record_releases += 1;
    }
};

/// Builds a sparse remap from an explicit per-original final id table so a
/// test can state a layout directly; null retires that original record.
fn testRemapFromFinalIds(allocator: std.mem.Allocator, final_ids: []const ?u64) !DenseRemap {
    var survivors: usize = 0;
    for (final_ids) |final| if (final != null) {
        survivors += 1;
    };
    var remap: DenseRemap = .{ .original_count = final_ids.len, .survivor_count = survivors };
    errdefer remap.deinit(allocator);
    for (final_ids, 0..) |final, original| {
        const original_id: u64 = @intCast(original);
        if (final == original_id) continue;
        try remap.moved.put(allocator, original_id, final);
        if (final) |final_id| try remap.inverse.put(allocator, final_id, original_id);
    }
    return remap;
}

const LifecycleSignalBinding = struct {
    record: *LifecycleTestRecord,
};

const LifecycleSignalDesc = struct {
    signal: LifecycleSignalBinding,
};

const LifecycleWhenDesc = struct {
    condition: LifecycleSignalBinding,
};

const LifecycleEachDesc = struct {
    items: LifecycleSignalBinding,
};

const LifecycleEventDesc = struct {
    handler: struct {
        record: ?*LifecycleTestRecord,

        /// Exposes only the fixture's declared action-read root.
        pub fn signalRoot(self: @This()) ?*LifecycleTestRecord {
            return self.record;
        }
    },
};

const LifecycleStream = struct {
    signal_text_nodes: shared_buffer.List(LifecycleSignalDesc) = .empty,
    signal_text_attrs: shared_buffer.List(LifecycleSignalDesc) = .empty,
    signal_custom_text_attrs: shared_buffer.List(LifecycleSignalDesc) = .empty,
    signal_optional_custom_text_attrs: shared_buffer.List(LifecycleSignalDesc) = .empty,
    signal_bool_attrs: shared_buffer.List(LifecycleSignalDesc) = .empty,
    signal_custom_bool_attrs: shared_buffer.List(LifecycleSignalDesc) = .empty,
    on_changes: shared_buffer.List(LifecycleSignalDesc) = .empty,
    whens: shared_buffer.List(LifecycleWhenDesc) = .empty,
    eaches: shared_buffer.List(LifecycleEachDesc) = .empty,
    events: shared_buffer.List(LifecycleEventDesc) = .empty,

    fn deinit(self: *LifecycleStream, allocator: std.mem.Allocator) void {
        self.signal_text_nodes.deinit(allocator);
        self.signal_text_attrs.deinit(allocator);
        self.signal_custom_text_attrs.deinit(allocator);
        self.signal_optional_custom_text_attrs.deinit(allocator);
        self.signal_bool_attrs.deinit(allocator);
        self.signal_custom_bool_attrs.deinit(allocator);
        self.on_changes.deinit(allocator);
        self.whens.deinit(allocator);
        self.eaches.deinit(allocator);
        self.events.deinit(allocator);
    }
};

test "prepared route appends sweep failures and publish without allocation" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var routes: RouteTable(TextSink) = .empty;
    defer {
        clearRouteTable(TextSink, std.testing.allocator, &routes);
        routes.deinit(std.testing.allocator);
    }
    try routes.append(std.testing.allocator, .empty);
    try routes.items[0].append(std.testing.allocator, .{ .kind = .text_node, .index = 4 });
    const appends = [_]RouteAppend(TextSink){
        .{ .route_index = 0, .value = .{ .kind = .text_attr, .index = 7 } },
        .{ .route_index = 2, .value = .{ .kind = .custom_text_attr, .index = 9 } },
    };
    var counter = FaultAllocator.init(std.testing.allocator);
    var baseline = try prepareRouteAppends(TextSink, counter.allocator(), &routes, 3, &appends);
    defer baseline.deinit(counter.allocator());
    const attempts = counter.attempts;
    for (1..attempts + 1) |failure_number| {
        var fault = FaultAllocator.init(std.testing.allocator);
        fault.configure(failure_number);
        try std.testing.expectError(error.OutOfMemory, prepareRouteAppends(TextSink, fault.allocator(), &routes, 3, &appends));
        try std.testing.expectEqual(@as(usize, 1), routes.items.len);
        try std.testing.expectEqualDeep(TextSink{ .kind = .text_node, .index = 4 }, routes.items[0].slice()[0]);
    }
    try baseline.reserveOuter(counter.allocator(), &routes, 3);
    counter.configure(1);
    baseline.apply(&routes, 3);
    try std.testing.expectEqual(@as(usize, 0), counter.attempts);
    try std.testing.expectEqual(@as(usize, 3), routes.items.len);
    try std.testing.expectEqualSlices(TextSink, &.{ .{ .kind = .text_node, .index = 4 }, .{ .kind = .text_attr, .index = 7 } }, routes.items[0].slice());
    try std.testing.expectEqualSlices(TextSink, &.{.{ .kind = .custom_text_attr, .index = 9 }}, routes.items[2].slice());
}

test "post-release route appends use direct sparse survivor inversion with linear work" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var routes: RouteTable(TextSink) = .empty;
    defer {
        clearRouteTable(TextSink, std.testing.allocator, &routes);
        routes.deinit(std.testing.allocator);
    }
    for (0..4) |index| {
        try routes.append(std.testing.allocator, .empty);
        try routes.items[index].append(std.testing.allocator, .{ .kind = .text_node, .index = index });
    }
    // Old records 3 and 0 survive as final records 0 and 1. Final records 2
    // and 3 are fresh, so they intentionally have no inverse entry.
    var remap = try testRemapFromFinalIds(std.testing.allocator, &.{ 1, null, null, 0 });
    defer remap.deinit(std.testing.allocator);
    const appends = [_]RouteAppend(TextSink){
        .{ .route_index = 0, .value = .{ .kind = .text_attr, .index = 10 } },
        .{ .route_index = 1, .value = .{ .kind = .text_attr, .index = 11 } },
        .{ .route_index = 3, .value = .{ .kind = .text_attr, .index = 13 } },
    };

    var work: usize = 0;
    var counter = FaultAllocator.init(std.testing.allocator);
    var baseline = try prepareRouteAppendsAfterReleaseWithWork(TextSink, counter.allocator(), &routes, &remap, 4, &appends, &work);
    defer baseline.deinit(counter.allocator());
    try std.testing.expectEqual(@as(usize, appends.len), work);
    const attempts = counter.attempts;
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| {
        var fault = FaultAllocator.init(std.testing.allocator);
        fault.configure(failure_number);
        try std.testing.expectError(error.OutOfMemory, prepareRouteAppendsAfterRelease(TextSink, fault.allocator(), &routes, &remap, 4, &appends));
        for (routes.items, 0..) |route, index| try std.testing.expectEqualDeep(TextSink{ .kind = .text_node, .index = index }, route.slice()[0]);
    }
    const oversized = DenseRemap.identity(3);
    try std.testing.expectError(error.InvalidAppend, prepareRouteAppendsAfterRelease(TextSink, std.testing.allocator, &routes, &oversized, 2, &appends));

    try baseline.reserveOuter(counter.allocator(), &routes, 4);
    counter.configure(1);
    baseline.apply(&routes, 4);
    try std.testing.expectEqual(@as(usize, 0), counter.attempts);
    try std.testing.expectEqualSlices(TextSink, &.{ .{ .kind = .text_node, .index = 3 }, .{ .kind = .text_attr, .index = 10 } }, routes.items[0].slice());
    try std.testing.expectEqualSlices(TextSink, &.{ .{ .kind = .text_node, .index = 0 }, .{ .kind = .text_attr, .index = 11 } }, routes.items[1].slice());
    try std.testing.expectEqualSlices(TextSink, &.{.{ .kind = .text_attr, .index = 13 }}, routes.items[3].slice());
}

test "post-release route inversion lookup work scales with appended groups" {
    const measure = struct {
        fn run(count: usize) !usize {
            const final_ids = try std.testing.allocator.alloc(?u64, count);
            defer std.testing.allocator.free(final_ids);
            const appends = try std.testing.allocator.alloc(RouteAppend(TextSink), count);
            defer std.testing.allocator.free(appends);
            for (final_ids, appends, 0..) |*final, *append, index| {
                final.* = @intCast(count - index - 1);
                append.* = .{ .route_index = @intCast(index), .value = .{ .kind = .text_node, .index = index } };
            }
            var remap = try testRemapFromFinalIds(std.testing.allocator, final_ids);
            defer remap.deinit(std.testing.allocator);
            var routes: RouteTable(TextSink) = .empty;
            defer routes.deinit(std.testing.allocator);
            var work: usize = 0;
            var prepared = try prepareRouteAppendsAfterReleaseWithWork(TextSink, std.testing.allocator, &routes, &remap, count, appends, &work);
            defer prepared.deinit(std.testing.allocator);
            return work;
        }
    }.run;
    try std.testing.expectEqual(@as(usize, 64), try measure(64));
    try std.testing.expectEqual(@as(usize, 512), try measure(512));
}

test "dense route preparation preserves interleaved order and allocates no singleton payloads" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    const measure = struct {
        fn run(count: usize) !usize {
            const appends = try std.testing.allocator.alloc(RouteAppend(TextSink), count);
            defer std.testing.allocator.free(appends);
            for (appends, 0..) |*append, index| append.* = .{ .route_index = @intCast(index), .value = .{ .kind = .text_node, .index = index } };
            var routes: RouteTable(TextSink) = .empty;
            var counter = FaultAllocator.init(std.testing.allocator);
            var prepared = try prepareRouteAppends(TextSink, counter.allocator(), &routes, count, appends);
            defer prepared.deinit(counter.allocator());
            return counter.attempts;
        }
    }.run;
    try std.testing.expectEqual(try measure(64), try measure(512));

    var routes: RouteTable(TextSink) = .empty;
    defer {
        clearRouteTable(TextSink, std.testing.allocator, &routes);
        routes.deinit(std.testing.allocator);
    }
    try routes.append(std.testing.allocator, .empty);
    try routes.items[0].append(std.testing.allocator, .{ .kind = .text_node, .index = 1 });
    const appends = [_]RouteAppend(TextSink){
        .{ .route_index = 2, .value = .{ .kind = .text_attr, .index = 20 } },
        .{ .route_index = 0, .value = .{ .kind = .text_attr, .index = 2 } },
        .{ .route_index = 2, .value = .{ .kind = .text_attr, .index = 21 } },
        .{ .route_index = 0, .value = .{ .kind = .text_attr, .index = 3 } },
    };
    var prepared = try prepareRouteAppends(TextSink, std.testing.allocator, &routes, 3, &appends);
    defer prepared.deinit(std.testing.allocator);
    try prepared.reserveOuter(std.testing.allocator, &routes, 3);
    prepared.apply(&routes, 3);
    try std.testing.expectEqualSlices(TextSink, &.{ .{ .kind = .text_node, .index = 1 }, .{ .kind = .text_attr, .index = 2 }, .{ .kind = .text_attr, .index = 3 } }, routes.items[0].slice());
    try std.testing.expectEqualSlices(TextSink, &.{ .{ .kind = .text_attr, .index = 20 }, .{ .kind = .text_attr, .index = 21 } }, routes.items[2].slice());
}

fn sampleRoute(comptime Route: type, index: usize) Route {
    return switch (Route) {
        TextSink => .{ .kind = .text_attr, .index = index },
        BoolSink => .{ .kind = .custom_bool_attr, .index = index },
        ChangeSink => .{ .index = index },
        StructuralSink => .{ .kind = .each, .index = index },
        else => @compileError("unsupported route type"),
    };
}

fn expectSampleRoutes(comptime Route: type, expected_indexes: []const usize, actual: []const Route) !void {
    try std.testing.expectEqual(expected_indexes.len, actual.len);
    for (expected_indexes, actual) |index, route| try std.testing.expectEqualDeep(sampleRoute(Route, index), route);
}

test "shared dense route planner serves every sink kind through retirement, faults, and allocation-free commit" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    inline for (.{ TextSink, BoolSink, ChangeSink, StructuralSink }) |Route| {
        var routes: RouteTable(Route) = .empty;
        defer {
            clearRouteTable(Route, std.testing.allocator, &routes);
            routes.deinit(std.testing.allocator);
        }
        // Old record 0 is empty, 1 and 3 hold one inline route, and 2 has
        // spilled to independently owned storage.
        for (0..4) |_| try routes.append(std.testing.allocator, .empty);
        try routes.items[1].append(std.testing.allocator, sampleRoute(Route, 100));
        try routes.items[3].append(std.testing.allocator, sampleRoute(Route, 300));
        for (200..203) |index| try routes.items[2].append(std.testing.allocator, sampleRoute(Route, index));
        const snapshot = [_][]const usize{ &.{}, &.{100}, &.{ 200, 201, 202 }, &.{300} };
        const expectUnchanged = struct {
            fn run(table: *const RouteTable(Route), expected: []const []const usize) !void {
                try std.testing.expectEqual(expected.len, table.items.len);
                for (expected, table.items) |indexes, *list| try expectSampleRoutes(Route, indexes, list.slice());
            }
        }.run;

        // Old records 2 and 3 survive as final records 0 and 1. Final records
        // 2, 3, and 4 are fresh; final 2 reuses the dense ID of a spilled old
        // record and must not inherit its routes.
        var remap = try testRemapFromFinalIds(std.testing.allocator, &.{ null, null, 0, 1 });
        defer remap.deinit(std.testing.allocator);
        const appends = [_]RouteAppend(Route){
            .{ .route_index = 3, .value = sampleRoute(Route, 30) },
            .{ .route_index = 0, .value = sampleRoute(Route, 10) },
            .{ .route_index = 2, .value = sampleRoute(Route, 20) },
            .{ .route_index = 3, .value = sampleRoute(Route, 31) },
            .{ .route_index = 1, .value = sampleRoute(Route, 11) },
            .{ .route_index = 0, .value = sampleRoute(Route, 12) },
            .{ .route_index = 3, .value = sampleRoute(Route, 32) },
        };

        var counter = FaultAllocator.init(std.testing.allocator);
        var baseline = try prepareRouteAppendsAfterRelease(Route, counter.allocator(), &routes, &remap, 5, &appends);
        defer baseline.deinit(counter.allocator());
        try std.testing.expectEqual(@as(usize, 4), baseline.replacements.len);
        // Counters, replacements, and one spill per multi-route replacement.
        const attempts = counter.attempts;
        try std.testing.expect(attempts >= 4);

        // Failing the first attempt aborts before any replacement exists;
        // failing the last aborts after earlier replacements already own
        // spilled storage. Both must release everything and leave the
        // committed table untouched.
        for (1..attempts + 1) |failure_number| {
            var fault = FaultAllocator.init(std.testing.allocator);
            fault.configure(failure_number);
            try std.testing.expectError(error.OutOfMemory, prepareRouteAppendsAfterRelease(Route, fault.allocator(), &routes, &remap, 5, &appends));
            try std.testing.expectEqual(@as(usize, 1), fault.induced_failures);
            try expectUnchanged(&routes, &snapshot);
        }

        // Invalid destinations are rejected before any replacement is built.
        const invalid = [_]RouteAppend(Route){.{ .route_index = 5, .value = sampleRoute(Route, 50) }};
        var rejected = FaultAllocator.init(std.testing.allocator);
        try std.testing.expectError(error.InvalidAppend, prepareRouteAppendsAfterRelease(Route, rejected.allocator(), &routes, &remap, 5, &invalid));
        try std.testing.expectEqual(@as(usize, 0), rejected.attempts);
        try std.testing.expectError(error.InvalidAppend, prepareRouteAppends(Route, rejected.allocator(), &routes, 5, &invalid));
        const oversized = DenseRemap.identity(3);
        try std.testing.expectError(error.InvalidAppend, prepareRouteAppendsAfterRelease(Route, rejected.allocator(), &routes, &oversized, 2, &appends));
        try expectUnchanged(&routes, &snapshot);

        // No appends prepare no replacements and publish only padding.
        var nothing = try prepareRouteAppendsAfterRelease(Route, counter.allocator(), &routes, &remap, 5, &.{});
        defer nothing.deinit(counter.allocator());
        try std.testing.expectEqual(@as(usize, 0), nothing.replacements.len);

        try baseline.reserveOuter(counter.allocator(), &routes, 5);
        counter.configure(1);
        baseline.apply(&routes, 5);
        try std.testing.expectEqual(@as(usize, 0), counter.attempts);
        try std.testing.expectEqual(@as(usize, 5), routes.items.len);
        try expectSampleRoutes(Route, &.{ 200, 201, 202, 10, 12 }, routes.items[0].slice());
        try expectSampleRoutes(Route, &.{ 300, 11 }, routes.items[1].slice());
        try expectSampleRoutes(Route, &.{20}, routes.items[2].slice());
        try expectSampleRoutes(Route, &.{ 30, 31, 32 }, routes.items[3].slice());
        try expectSampleRoutes(Route, &.{}, routes.items[4].slice());
        // Displaced storage now belongs to the plan and is released by its
        // deinit; the table keeps only the published replacements.
        try std.testing.expectEqual(@as(usize, 3), baseline.replacements[2].retired.len());
        try std.testing.expectEqual(@as(usize, 1), baseline.replacements[3].retired.len());
        try std.testing.expect(baseline.replacements[0].next == .empty);
    }
}

test "dense source route preparation remaps survivors before ordered appends" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var routes: RouteTable(u64) = .empty;
    defer {
        clearRouteTable(u64, std.testing.allocator, &routes);
        routes.deinit(std.testing.allocator);
    }
    try routes.append(std.testing.allocator, .empty);
    try routes.items[0].append(std.testing.allocator, 3);
    try routes.items[0].append(std.testing.allocator, 1);
    try routes.items[0].append(std.testing.allocator, 2);
    var remap = try testRemapFromFinalIds(std.testing.allocator, &.{ 4, null, 7, 9 });
    defer remap.deinit(std.testing.allocator);
    const appends = [_]RouteAppend(u64){
        .{ .route_index = 2, .value = 12 },
        .{ .route_index = 0, .value = 10 },
        .{ .route_index = 2, .value = 13 },
        .{ .route_index = 0, .value = 11 },
    };
    var counter = FaultAllocator.init(std.testing.allocator);
    var prepared = try prepareSourceRouteAppendsAfterRelease(counter.allocator(), &routes, &remap, 3, &appends);
    defer prepared.deinit(counter.allocator());
    const attempts = counter.attempts;
    for (1..attempts + 1) |failure_number| {
        var fault = FaultAllocator.init(std.testing.allocator);
        fault.configure(failure_number);
        try std.testing.expectError(error.OutOfMemory, prepareSourceRouteAppendsAfterRelease(fault.allocator(), &routes, &remap, 3, &appends));
        try std.testing.expectEqualSlices(u64, &.{ 3, 1, 2 }, routes.items[0].slice());
    }
    try prepared.reserveOuter(counter.allocator(), &routes, 3);
    counter.configure(1);
    prepared.apply(&routes, 3);
    try std.testing.expectEqual(@as(usize, 0), counter.attempts);
    try std.testing.expectEqualSlices(u64, &.{ 9, 7, 10, 11 }, routes.items[0].slice());
    try std.testing.expectEqualSlices(u64, &.{ 12, 13 }, routes.items[2].slice());
}

test "prepared graph append enumerates missing topology without mutating survivors" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var survivor = LifecycleTestRecord{ .id = 1, .payload = .{ .ref = 0 } };
    var mapped = LifecycleTestRecord{ .id = 2, .payload = .{ .map = .{ .input = &survivor } } };
    var fresh = LifecycleTestRecord{ .id = 3, .payload = .const_value };
    var root = LifecycleTestRecord{ .id = 4, .payload = .{ .map2 = .{ .left = &mapped, .right = &fresh } } };
    var nodes: shared_buffer.List(Node(LifecycleTestRecord)) = .empty;
    var source_routes: RouteTable(u64) = .empty;
    var text_routes: RouteTable(TextSink) = .empty;
    var bool_routes: RouteTable(BoolSink) = .empty;
    var change_routes: RouteTable(ChangeSink) = .empty;
    var structural_routes: RouteTable(StructuralSink) = .empty;
    var hooks: LifecycleTestHooks = .{};
    defer {
        clearSourceRoutes(std.testing.allocator, &source_routes);
        source_routes.deinit(std.testing.allocator);
        clearSinkRoutes(std.testing.allocator, &text_routes, &bool_routes, &change_routes, &structural_routes);
        text_routes.deinit(std.testing.allocator);
        bool_routes.deinit(std.testing.allocator);
        change_routes.deinit(std.testing.allocator);
        structural_routes.deinit(std.testing.allocator);
        clear(LifecycleTestRecord, std.testing.allocator, &nodes, &hooks);
        nodes.deinit(std.testing.allocator);
    }
    _ = retainRecord(LifecycleTestRecord, std.testing.allocator, &nodes, &source_routes, 4, &survivor, &hooks);
    try std.testing.expectEqual(@as(usize, 1), survivor.active_use_count);
    try std.testing.expectEqualSlices(u64, &.{0}, source_routes.items[0].slice());
    var none = PreparedReleaseClosure(LifecycleTestRecord).none(1);
    defer none.deinit(std.testing.allocator);
    const mapping = &none.remap;
    const roots = [_]*LifecycleTestRecord{ &mapped, &root };

    var counter = FaultAllocator.init(std.testing.allocator);
    var baseline = try prepareGraphAppend(LifecycleTestRecord, counter.allocator(), nodes.items, &none, &roots);
    defer baseline.deinit(counter.allocator());
    const attempts = counter.attempts;
    try std.testing.expect(attempts != 0);
    try std.testing.expectEqualSlices(*LifecycleTestRecord, &.{ &mapped, &fresh, &root }, baseline.records);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 3 }, baseline.record_ids);
    try std.testing.expectEqual(@as(?u64, 0), baseline.plannedRecordId(mapping, nodes.items, &survivor));
    try std.testing.expectEqual(@as(?u64, 1), baseline.plannedRecordId(mapping, nodes.items, &mapped));
    try std.testing.expectEqual(@as(?u64, 2), baseline.plannedRecordId(mapping, nodes.items, &fresh));
    try std.testing.expectEqual(@as(?u64, 3), baseline.plannedRecordId(mapping, nodes.items, &root));
    try std.testing.expectEqualSlices(u64, &.{ 1, 0, 2 }, baseline.ranks);
    try std.testing.expectEqualSlices(usize, &.{ 2, 1, 1 }, baseline.use_counts);
    try std.testing.expectEqual(@as(usize, 1), mapped.ref_count);
    try std.testing.expectEqual(@as(usize, 1), fresh.ref_count);
    try std.testing.expectEqual(@as(usize, 1), root.ref_count);
    try std.testing.expectEqualSlices(ExistingUseIncrement, &.{.{ .record_id = 0, .count = 1 }}, baseline.existing_use_increments);
    // The survivor's edge is appended in place at commit (its inline slot is
    // free), so the release owns no replacement list for it.
    try std.testing.expectEqualSlices(SurvivorEdgeAppend, &.{.{ .input_id = 0, .dependent_id = 1, .position = 0 }}, baseline.survivor_edges);
    try std.testing.expectEqual(@as(usize, 0), none.replacements.items.len);
    try std.testing.expectEqualSlices(u64, &.{3}, baseline.new_nodes[0].dependents.slice());
    try std.testing.expectEqualSlices(u64, &.{3}, baseline.new_nodes[1].dependents.slice());
    try std.testing.expectEqualSlices(u64, &.{}, baseline.new_nodes[2].dependents.slice());

    for (1..attempts + 1) |failure_number| {
        var fault = FaultAllocator.init(std.testing.allocator);
        fault.configure(failure_number);
        try std.testing.expectError(error.OutOfMemory, prepareGraphAppend(LifecycleTestRecord, fault.allocator(), nodes.items, &none, &roots));
        try std.testing.expectEqual(@as(usize, 1), nodes.items.len);
        try std.testing.expectEqual(@as(?u64, 0), survivor.active_graph_id);
        try std.testing.expectEqual(@as(usize, 1), survivor.active_use_count);
        try std.testing.expectEqualSlices(u64, &.{}, nodes.items[0].dependents.slice());
        try std.testing.expectEqualSlices(u64, &.{0}, source_routes.items[0].slice());
        for ([_]*LifecycleTestRecord{ &mapped, &fresh, &root }) |record| {
            try std.testing.expectEqual(@as(?u64, null), record.active_graph_id);
            try std.testing.expectEqual(@as(usize, 0), record.active_use_count);
            try std.testing.expectEqual(@as(usize, 1), record.ref_count);
        }
    }
    try baseline.reservePublication(counter.allocator(), &nodes);
    try baseline.reserveParallelRoutes(counter.allocator(), &text_routes, &bool_routes, &change_routes, &structural_routes);
    counter.configure(1);
    baseline.commitNodes(&nodes);
    baseline.commitParallelRoutes(&text_routes, &bool_routes, &change_routes, &structural_routes);
    try std.testing.expectEqual(@as(usize, 0), counter.attempts);
    try std.testing.expectEqual(@as(usize, 4), nodes.items.len);
    try std.testing.expectEqual(@as(usize, 4), text_routes.items.len);
    try std.testing.expectEqual(@as(usize, 4), bool_routes.items.len);
    try std.testing.expectEqual(@as(usize, 4), change_routes.items.len);
    try std.testing.expectEqual(@as(usize, 4), structural_routes.items.len);
    try std.testing.expectEqualSlices(u64, &.{1}, nodes.items[0].dependents.slice());
    try std.testing.expectEqualSlices(u64, &.{3}, nodes.items[1].dependents.slice());
    try std.testing.expectEqualSlices(u64, &.{3}, nodes.items[2].dependents.slice());
    try std.testing.expectEqualSlices(u64, &.{}, nodes.items[3].dependents.slice());
    try std.testing.expectEqual(@as(usize, 2), survivor.active_use_count);
    try std.testing.expectEqual(@as(?u64, 1), mapped.active_graph_id);
    try std.testing.expectEqual(@as(usize, 2), mapped.active_use_count);
    try std.testing.expectEqual(@as(?u64, 2), fresh.active_graph_id);
    try std.testing.expectEqual(@as(?u64, 3), root.active_graph_id);
    try std.testing.expectEqual(@as(usize, 2), mapped.ref_count);
    try std.testing.expectEqual(@as(usize, 2), fresh.ref_count);
    try std.testing.expectEqual(@as(usize, 2), root.ref_count);
}

test "prepared graph append indexes new records with linear lookup work" {
    const measure = struct {
        fn run(count: usize) !usize {
            var shared = LifecycleTestRecord{ .id = 1, .payload = .const_value };
            const maps = try std.testing.allocator.alloc(LifecycleTestRecord, count);
            defer std.testing.allocator.free(maps);
            const roots = try std.testing.allocator.alloc(*LifecycleTestRecord, count);
            defer std.testing.allocator.free(roots);
            for (maps, roots, 0..) |*map, *root, index| {
                map.* = .{ .id = @intCast(index + 2), .payload = .{ .map = .{ .input = &shared } } };
                root.* = map;
            }

            var work: PreparationWork = .{};
            var empty = PreparedReleaseClosure(LifecycleTestRecord).none(0);
            defer empty.deinit(std.testing.allocator);
            var prepared = try prepareGraphAppendWithWork(LifecycleTestRecord, std.testing.allocator, &.{}, &empty, roots, &work);
            defer prepared.deinit(std.testing.allocator);
            try std.testing.expectEqual(count + 1, prepared.records.len);
            try std.testing.expectEqual(count, prepared.use_counts[0]);
            try std.testing.expectEqual(@as(u64, 0), prepared.ranks[0]);
            for (prepared.ranks[1..]) |prepared_rank| try std.testing.expectEqual(@as(u64, 1), prepared_rank);
            try std.testing.expectEqual(@as(usize, 0), work.records);
            try std.testing.expectEqual(@as(usize, 0), work.edges);
            return work.lookups;
        }
    }.run;

    const small: usize = 64;
    const large: usize = 512;
    try std.testing.expectEqual(3 * small, try measure(small));
    try std.testing.expectEqual(3 * large, try measure(large));
}

test "replacement retain indexing has linear work and terminates shared cycles" {
    const measureShared = struct {
        fn run(count: usize) !usize {
            var shared = LifecycleTestRecord{ .id = 1, .payload = .const_value };
            const maps = try std.testing.allocator.alloc(LifecycleTestRecord, count);
            defer std.testing.allocator.free(maps);
            const roots = try std.testing.allocator.alloc(*LifecycleTestRecord, count);
            defer std.testing.allocator.free(roots);
            for (maps, roots, 0..) |*map, *root, index| {
                map.* = .{ .id = @intCast(index + 2), .payload = .{ .map = .{ .input = &shared } } };
                root.* = map;
            }
            var work: PreparationWork = .{};
            var existing: TouchedCounts = .{};
            defer existing.deinit(std.testing.allocator);
            try countExistingRetainsWithWork(LifecycleTestRecord, std.testing.allocator, &.{}, roots, &existing, &work);
            return work.lookups;
        }
    }.run;

    const small: usize = 64;
    const large: usize = 512;
    try std.testing.expectEqual(2 * small, try measureShared(small));
    try std.testing.expectEqual(2 * large, try measureShared(large));

    var left = LifecycleTestRecord{ .id = 1, .payload = .const_value };
    var right = LifecycleTestRecord{ .id = 2, .payload = .{ .map = .{ .input = &left } } };
    left.payload = .{ .map = .{ .input = &right } };
    var cycle_work: PreparationWork = .{};
    var cycle_existing: TouchedCounts = .{};
    defer cycle_existing.deinit(std.testing.allocator);
    try countExistingRetainsWithWork(LifecycleTestRecord, std.testing.allocator, &.{}, &.{&left}, &cycle_existing, &cycle_work);
    try std.testing.expectEqual(@as(usize, 3), cycle_work.lookups);
}

test "prepared release closure nets replacement retains so a handed-over record survives" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    // `source` is used only by the retiring `old_root`; `shared` is used by the
    // retiring root and by a surviving `keeper`. The replacement `new_root`
    // picks `source` up again in the same transaction.
    var source = LifecycleTestRecord{ .id = 1, .payload = .{ .ref = 0 } };
    var shared = LifecycleTestRecord{ .id = 2, .payload = .{ .ref = 1 } };
    var old_root = LifecycleTestRecord{ .id = 3, .payload = .{ .map2 = .{ .left = &source, .right = &shared } } };
    var keeper = LifecycleTestRecord{ .id = 4, .payload = .{ .map = .{ .input = &shared } } };
    var new_root = LifecycleTestRecord{ .id = 5, .payload = .{ .map = .{ .input = &source } } };
    var nodes: shared_buffer.List(Node(LifecycleTestRecord)) = .empty;
    var source_routes: RouteTable(u64) = .empty;
    var text_routes: RouteTable(TextSink) = .empty;
    var bool_routes: RouteTable(BoolSink) = .empty;
    var change_routes: RouteTable(ChangeSink) = .empty;
    var structural_routes: RouteTable(StructuralSink) = .empty;
    var hooks: LifecycleTestHooks = .{};
    defer {
        clearSourceRoutes(std.testing.allocator, &source_routes);
        source_routes.deinit(std.testing.allocator);
        clearSinkRoutes(std.testing.allocator, &text_routes, &bool_routes, &change_routes, &structural_routes);
        text_routes.deinit(std.testing.allocator);
        bool_routes.deinit(std.testing.allocator);
        change_routes.deinit(std.testing.allocator);
        structural_routes.deinit(std.testing.allocator);
        clear(LifecycleTestRecord, std.testing.allocator, &nodes, &hooks);
        nodes.deinit(std.testing.allocator);
    }
    _ = retainRecord(LifecycleTestRecord, std.testing.allocator, &nodes, &source_routes, 2, &old_root, &hooks);
    _ = retainRecord(LifecycleTestRecord, std.testing.allocator, &nodes, &source_routes, 2, &keeper, &hooks);
    for (0..nodes.items.len) |_| {
        try text_routes.append(std.testing.allocator, .empty);
        try bool_routes.append(std.testing.allocator, .empty);
        try change_routes.append(std.testing.allocator, .empty);
        try structural_routes.append(std.testing.allocator, .empty);
    }
    try std.testing.expectEqual(@as(usize, 4), nodes.items.len);
    try std.testing.expectEqual(@as(?u64, 0), source.active_graph_id);
    try std.testing.expectEqual(@as(usize, 1), source.active_use_count);
    try std.testing.expectEqual(@as(usize, 2), shared.active_use_count);
    const retired_roots = [_]*LifecycleTestRecord{&old_root};
    const replacement_roots = [_]*LifecycleTestRecord{&new_root};

    var counter = FaultAllocator.init(std.testing.allocator);
    var release = try prepareReleaseClosure(LifecycleTestRecord, counter.allocator(), nodes.items, &retired_roots, &replacement_roots);
    defer release.deinit(counter.allocator());
    const release_attempts = counter.attempts;
    try std.testing.expect(release_attempts != 0);
    try std.testing.expectEqualSlices(*LifecycleTestRecord, &.{&old_root}, release.records);
    try std.testing.expectEqual(@as(?u64, 0), release.remap.finalId(0));
    try std.testing.expectEqual(@as(?u64, 1), release.remap.finalId(1));
    try std.testing.expectEqual(@as(?u64, null), release.remap.finalId(2));
    try std.testing.expectEqual(@as(?u64, 2), release.remap.finalId(3));
    try std.testing.expectEqual(@as(?u64, 3), release.remap.originalId(2));
    try std.testing.expectEqual(@as(usize, 3), release.remap.survivor_count);
    try std.testing.expectEqualSlices(ExistingUseIncrement, &.{ .{ .record_id = 0, .count = 1 }, .{ .record_id = 1, .count = 1 } }, release.survivor_use_decrements);
    for (1..release_attempts + 1) |failure_number| {
        var fault = FaultAllocator.init(std.testing.allocator);
        fault.configure(failure_number);
        try std.testing.expectError(error.OutOfMemory, prepareReleaseClosure(LifecycleTestRecord, fault.allocator(), nodes.items, &retired_roots, &replacement_roots));
        try std.testing.expectEqual(@as(usize, 1), source.active_use_count);
        try std.testing.expectEqual(@as(usize, 2), shared.active_use_count);
        for (nodes.items, 0..) |node, index| try std.testing.expectEqual(@as(?u64, @intCast(index)), node.record.active_graph_id);
    }

    var append = try prepareGraphAppend(LifecycleTestRecord, counter.allocator(), nodes.items, &release, &replacement_roots);
    defer append.deinit(counter.allocator());
    try std.testing.expectEqualSlices(*LifecycleTestRecord, &.{&new_root}, append.records);
    try std.testing.expectEqualSlices(u64, &.{3}, append.record_ids);
    try std.testing.expectEqualSlices(ExistingUseIncrement, &.{.{ .record_id = 0, .count = 1 }}, append.existing_use_increments);
    try std.testing.expectEqual(@as(?u64, 0), append.plannedRecordId(&release.remap, nodes.items, &source));

    try append.reservePublication(counter.allocator(), &nodes);
    try append.reserveParallelRoutes(counter.allocator(), &text_routes, &bool_routes, &change_routes, &structural_routes);
    counter.configure(1);
    release.applyAdjacency(nodes.items);
    release.applyDense(&nodes, &source_routes, &text_routes, &bool_routes, &change_routes, &structural_routes);
    append.commitNodes(&nodes);
    append.commitParallelRoutes(&text_routes, &bool_routes, &change_routes, &structural_routes);
    release.releaseRetired(counter.allocator(), nodes.items, &hooks);
    try std.testing.expectEqual(@as(usize, 0), counter.attempts);
    try std.testing.expectEqual(@as(usize, 4), nodes.items.len);
    try std.testing.expectEqual(@as(?u64, 0), source.active_graph_id);
    try std.testing.expectEqual(@as(usize, 1), source.active_use_count);
    try std.testing.expectEqual(@as(?u64, 1), shared.active_graph_id);
    try std.testing.expectEqual(@as(usize, 1), shared.active_use_count);
    try std.testing.expectEqual(@as(?u64, null), old_root.active_graph_id);
    try std.testing.expectEqual(@as(usize, 0), old_root.active_use_count);
    try std.testing.expectEqual(@as(?u64, 2), keeper.active_graph_id);
    try std.testing.expectEqual(@as(?u64, 3), new_root.active_graph_id);
    try std.testing.expectEqual(@as(usize, 1), new_root.active_use_count);
    try std.testing.expectEqualSlices(u64, &.{3}, nodes.items[0].dependents.slice());
    try std.testing.expectEqualSlices(u64, &.{2}, nodes.items[1].dependents.slice());
    try std.testing.expectEqualSlices(u64, &.{0}, source_routes.items[0].slice());
    try std.testing.expectEqualSlices(u64, &.{1}, source_routes.items[1].slice());
    try std.testing.expectEqual(@as(u64, 1), hooks.record_releases);
    try std.testing.expectEqual(@as(usize, 1), old_root.ref_count);
    try std.testing.expectEqual(@as(usize, 2), new_root.ref_count);
}

test "prepared release closure preserves shared diamond and computes dense remaps" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var source = LifecycleTestRecord{ .id = 1, .payload = .{ .ref = 0 } };
    var left = LifecycleTestRecord{ .id = 2, .payload = .{ .map = .{ .input = &source } } };
    var right = LifecycleTestRecord{ .id = 3, .payload = .{ .map = .{ .input = &source } } };
    var root = LifecycleTestRecord{ .id = 4, .payload = .{ .map2 = .{ .left = &left, .right = &right } } };
    var nodes: shared_buffer.List(Node(LifecycleTestRecord)) = .empty;
    var source_routes: RouteTable(u64) = .empty;
    var text_routes: RouteTable(TextSink) = .empty;
    var bool_routes: RouteTable(BoolSink) = .empty;
    var change_routes: RouteTable(ChangeSink) = .empty;
    var structural_routes: RouteTable(StructuralSink) = .empty;
    var hooks: LifecycleTestHooks = .{};
    defer {
        clearSourceRoutes(std.testing.allocator, &source_routes);
        source_routes.deinit(std.testing.allocator);
        text_routes.deinit(std.testing.allocator);
        bool_routes.deinit(std.testing.allocator);
        change_routes.deinit(std.testing.allocator);
        structural_routes.deinit(std.testing.allocator);
        clear(LifecycleTestRecord, std.testing.allocator, &nodes, &hooks);
        nodes.deinit(std.testing.allocator);
    }
    _ = retainRecord(LifecycleTestRecord, std.testing.allocator, &nodes, &source_routes, 1, &root, &hooks);
    for (0..nodes.items.len) |_| {
        try text_routes.append(std.testing.allocator, .empty);
        try bool_routes.append(std.testing.allocator, .empty);
        try change_routes.append(std.testing.allocator, .empty);
        try structural_routes.append(std.testing.allocator, .empty);
    }
    try std.testing.expectEqual(@as(usize, 2), source.active_use_count);
    try std.testing.expectEqualSlices(u64, &.{0}, source_routes.items[0].slice());

    var counter = FaultAllocator.init(std.testing.allocator);
    var baseline = try prepareReleaseClosure(LifecycleTestRecord, counter.allocator(), nodes.items, &.{&root}, &.{});
    const attempts = counter.attempts;
    try std.testing.expectEqualSlices(*LifecycleTestRecord, &.{ &root, &left, &right, &source }, baseline.records);
    try std.testing.expectEqualDeep(PreparedReleaseStep{ .record_id = 3, .removal_index = 3, .moved_record_id = null }, baseline.steps[0]);
    try std.testing.expectEqualDeep(PreparedReleaseStep{ .record_id = 1, .removal_index = 1, .moved_record_id = 2 }, baseline.steps[1]);
    try std.testing.expectEqualDeep(PreparedReleaseStep{ .record_id = 2, .removal_index = 1, .moved_record_id = null }, baseline.steps[2]);
    try std.testing.expectEqualDeep(PreparedReleaseStep{ .record_id = 0, .removal_index = 0, .moved_record_id = null }, baseline.steps[3]);
    for (0..4) |original| try std.testing.expectEqual(@as(?u64, null), baseline.remap.finalId(@intCast(original)));
    try std.testing.expectEqual(@as(usize, 0), baseline.remap.survivor_count);
    // Every input retires with its dependents, so no list is edited in place.
    try std.testing.expectEqual(@as(usize, 0), baseline.edge_drops.len);
    try std.testing.expectEqual(@as(usize, 0), baseline.replacements.items.len);
    try std.testing.expect(attempts != 0);

    for (1..attempts + 1) |failure_number| {
        var fault = FaultAllocator.init(std.testing.allocator);
        fault.configure(failure_number);
        try std.testing.expectError(error.OutOfMemory, prepareReleaseClosure(LifecycleTestRecord, fault.allocator(), nodes.items, &.{&root}, &.{}));
        try std.testing.expectEqual(@as(usize, 1), root.active_use_count);
        try std.testing.expectEqual(@as(usize, 1), left.active_use_count);
        try std.testing.expectEqual(@as(usize, 1), right.active_use_count);
        try std.testing.expectEqual(@as(usize, 2), source.active_use_count);
        for (nodes.items, 0..) |node, index| try std.testing.expectEqual(@as(?u64, @intCast(index)), node.record.active_graph_id);
        try std.testing.expectEqualSlices(u64, &.{ 1, 2 }, nodes.items[0].dependents.slice());
        try std.testing.expectEqualSlices(u64, &.{3}, nodes.items[1].dependents.slice());
        try std.testing.expectEqualSlices(u64, &.{3}, nodes.items[2].dependents.slice());
    }
    counter.configure(1);
    baseline.applyAdjacency(nodes.items);
    try std.testing.expectEqual(@as(usize, 0), counter.attempts);
    // Retired inputs keep their lists until `releaseRetired` frees them
    // wholesale; nothing is edited edge by edge.
    try std.testing.expectEqualSlices(u64, &.{ 1, 2 }, nodes.items[0].dependents.slice());
    try std.testing.expectEqualSlices(u64, &.{3}, nodes.items[1].dependents.slice());
    try std.testing.expectEqualSlices(u64, &.{3}, nodes.items[2].dependents.slice());
    baseline.applyDense(&nodes, &source_routes, &text_routes, &bool_routes, &change_routes, &structural_routes);
    try std.testing.expectEqual(@as(usize, 0), nodes.items.len);
    try std.testing.expectEqual(@as(usize, 0), text_routes.items.len);
    try std.testing.expectEqual(@as(usize, 0), bool_routes.items.len);
    try std.testing.expectEqual(@as(usize, 0), change_routes.items.len);
    try std.testing.expectEqual(@as(usize, 0), structural_routes.items.len);
    try std.testing.expectEqualSlices(u64, &.{}, source_routes.items[0].slice());
    try std.testing.expectEqual(@as(usize, 0), counter.attempts);
    baseline.releaseRetired(counter.allocator(), nodes.items, &hooks);
    counter.configure(null);
    baseline.deinit(counter.allocator());
}

/// Locality fixture: `count` independent rows, each `ref` source -> `map`
/// label -> `map2(label, source)` root, plus an unrelated live diamond that
/// must survive every transaction untouched. Rows may additionally share one
/// `shared` ref when `shared_input` is set, which models a row binding that
/// reads a selection signal every other row also reads.
const LocalityRows = struct {
    const Row = struct {
        source: LifecycleTestRecord,
        label: LifecycleTestRecord,
        root: LifecycleTestRecord,
    };

    allocator: std.mem.Allocator,
    rows: []Row,
    shared: LifecycleTestRecord,
    diamond_source: LifecycleTestRecord,
    diamond_left: LifecycleTestRecord,
    diamond_right: LifecycleTestRecord,
    diamond_root: LifecycleTestRecord,
    nodes: shared_buffer.List(Node(LifecycleTestRecord)) = .empty,
    source_routes: RouteTable(u64) = .empty,
    text_routes: RouteTable(TextSink) = .empty,
    bool_routes: RouteTable(BoolSink) = .empty,
    change_routes: RouteTable(ChangeSink) = .empty,
    structural_routes: RouteTable(StructuralSink) = .empty,
    hooks: LifecycleTestHooks = .{},

    fn sourceNodeCount(self: *const LocalityRows) usize {
        return self.rows.len + 2;
    }

    /// Builds `count` committed rows. Records live behind stable heap
    /// addresses because the graph keys them by pointer.
    fn init(allocator: std.mem.Allocator, count: usize, shared_input: bool) !*LocalityRows {
        const self = try allocator.create(LocalityRows);
        errdefer allocator.destroy(self);
        const rows = try allocator.alloc(Row, count);
        errdefer allocator.free(rows);
        self.* = .{
            .allocator = allocator,
            .rows = rows,
            .shared = .{ .id = 1, .payload = .{ .ref = @intCast(count) } },
            .diamond_source = .{ .id = 2, .payload = .{ .ref = @intCast(count + 1) } },
            .diamond_left = .{ .id = 3, .payload = .const_value },
            .diamond_right = .{ .id = 4, .payload = .const_value },
            .diamond_root = .{ .id = 5, .payload = .const_value },
        };
        self.diamond_left.payload = .{ .map = .{ .input = &self.diamond_source } };
        self.diamond_right.payload = .{ .map = .{ .input = &self.diamond_source } };
        self.diamond_root.payload = .{ .map2 = .{ .left = &self.diamond_left, .right = &self.diamond_right } };
        for (self.rows, 0..) |*row, index| self.initRow(row, index, shared_input);
        for (self.rows) |*row| try self.commitRoot(&row.root);
        try self.commitRoot(&self.diamond_root);
        return self;
    }

    fn initRow(self: *LocalityRows, row: *Row, index: usize, shared_input: bool) void {
        const base: u64 = @intCast(10 + index * 3);
        row.source = .{ .id = base, .payload = .{ .ref = @intCast(index) } };
        row.label = .{ .id = base + 1, .payload = .{ .map = .{ .input = &row.source } } };
        row.root = .{ .id = base + 2, .payload = .{ .map2 = .{ .left = &row.label, .right = if (shared_input) &self.shared else &row.source } } };
    }

    /// Retains a root the way initial ingestion does and gives its record a
    /// text sink so dense moves can be checked against the parallel tables.
    fn commitRoot(self: *LocalityRows, root: *LifecycleTestRecord) !void {
        _ = retainRecord(LifecycleTestRecord, self.allocator, &self.nodes, &self.source_routes, self.sourceNodeCount(), root, &self.hooks);
        while (self.text_routes.items.len < self.nodes.items.len) {
            try self.text_routes.append(self.allocator, .empty);
            try self.bool_routes.append(self.allocator, .empty);
            try self.change_routes.append(self.allocator, .empty);
            try self.structural_routes.append(self.allocator, .empty);
        }
        self.text_routes.items[@intCast(root.active_graph_id.?)] = .{ .one = .{ .kind = .text_node, .index = @intCast(root.id) } };
    }

    fn deinit(self: *LocalityRows) void {
        const allocator = self.allocator;
        clearSourceRoutes(allocator, &self.source_routes);
        self.source_routes.deinit(allocator);
        clearSinkRoutes(allocator, &self.text_routes, &self.bool_routes, &self.change_routes, &self.structural_routes);
        self.text_routes.deinit(allocator);
        self.bool_routes.deinit(allocator);
        self.change_routes.deinit(allocator);
        self.structural_routes.deinit(allocator);
        clear(LifecycleTestRecord, allocator, &self.nodes, &self.hooks);
        self.nodes.deinit(allocator);
        allocator.free(self.rows);
        allocator.destroy(self);
    }

    /// Whole-graph audit (test only): dense ids match slots, every edge points
    /// at a live slot, every input lists its dependent exactly once, every
    /// live `ref` sits in its source route exactly once, retired records carry
    /// no id, and each root's text sink travelled with its record.
    fn audit(self: *LocalityRows) !void {
        try auditDenseIds(LifecycleTestRecord, self.nodes.items);
        try std.testing.expectEqual(self.nodes.items.len, self.text_routes.items.len);
        var inputs: shared_buffer.List(*LifecycleTestRecord) = .empty;
        defer inputs.deinit(self.allocator);
        for (self.nodes.items, 0..) |node, index| {
            const id: u64 = @intCast(index);
            try std.testing.expect(node.record.active_use_count != 0);
            inputs.clearRetainingCapacity();
            appendInputRecords(LifecycleTestRecord, self.allocator, &inputs, node.record);
            for (inputs.items) |input| {
                const input_id: usize = @intCast(input.active_graph_id orelse return error.TestUnexpectedResult);
                var seen: usize = 0;
                for (self.nodes.items[input_id].dependents.slice()) |dependent| if (dependent == id) {
                    seen += 1;
                };
                try std.testing.expectEqual(@as(usize, 1), seen);
                try std.testing.expect(self.nodes.items[input_id].rank < node.rank);
            }
            switch (node.record.payload) {
                .ref => |source_node_id| {
                    var seen: usize = 0;
                    for (self.source_routes.items[@intCast(source_node_id)].slice()) |route_id| if (route_id == id) {
                        seen += 1;
                    };
                    try std.testing.expectEqual(@as(usize, 1), seen);
                },
                else => {},
            }
        }
        var total_routed: usize = 0;
        for (self.source_routes.items) |route| total_routed += route.len();
        var live_refs: usize = 0;
        for (self.nodes.items) |node| switch (node.record.payload) {
            .ref => live_refs += 1,
            else => {},
        };
        try std.testing.expectEqual(live_refs, total_routed);
        for (self.rows) |*row| try self.auditRoot(&row.root);
        try self.auditRoot(&self.diamond_root);
    }

    fn auditRoot(self: *LocalityRows, root: *const LifecycleTestRecord) !void {
        if (root.active_graph_id) |id| {
            const routes = self.text_routes.items[@intCast(id)].slice();
            try std.testing.expectEqual(@as(usize, 1), routes.len);
            try std.testing.expectEqual(@as(usize, @intCast(root.id)), routes[0].index);
            try std.testing.expectEqual(@as(usize, 2), root.ref_count);
        } else {
            try std.testing.expectEqual(@as(usize, 0), root.active_use_count);
            try std.testing.expectEqual(@as(usize, 1), root.ref_count);
        }
    }
};

/// One prepared structural transaction over a `LocalityRows` fixture, built
/// in the same order the engine builds it: release, append, then every
/// route planner (including the no-op planners for sink kinds with no
/// appends). Measures the work counters and the allocator traffic.
const LocalityTransaction = struct {
    release: PreparedReleaseClosure(LifecycleTestRecord),
    append: PreparedGraphAppend(LifecycleTestRecord),
    source_appends: PreparedRouteAppends(u64),
    text_appends: PreparedRouteAppends(TextSink),
    bool_appends: PreparedRouteAppends(BoolSink),
    change_appends: PreparedRouteAppends(ChangeSink),
    structural_appends: PreparedRouteAppends(StructuralSink),
    release_work: PreparationWork = .{},
    append_work: PreparationWork = .{},
    source_route_count: usize,

    fn prepare(allocator: std.mem.Allocator, fixture: *LocalityRows, retired_roots: []const *LifecycleTestRecord, replacement_rows: []LocalityRows.Row) !LocalityTransaction {
        var replacement_roots: shared_buffer.List(*LifecycleTestRecord) = .empty;
        defer replacement_roots.deinit(std.testing.allocator);
        for (replacement_rows) |*row| try replacement_roots.append(std.testing.allocator, &row.root);
        var self: LocalityTransaction = undefined;
        self.release_work = .{};
        self.append_work = .{};
        self.release = try prepareReleaseClosureWithWork(LifecycleTestRecord, allocator, fixture.nodes.items, retired_roots, replacement_roots.items, &self.release_work);
        errdefer self.release.deinit(allocator);
        self.append = try prepareGraphAppendWithWork(LifecycleTestRecord, allocator, fixture.nodes.items, &self.release, replacement_roots.items, &self.append_work);
        errdefer self.append.deinit(allocator);
        const graph_count = self.append.finalGraphCount();
        var source_inputs: shared_buffer.List(RouteAppend(u64)) = .empty;
        defer source_inputs.deinit(std.testing.allocator);
        var text_inputs: shared_buffer.List(RouteAppend(TextSink)) = .empty;
        defer text_inputs.deinit(std.testing.allocator);
        for (replacement_rows) |*row| {
            const root_id = self.append.plannedRecordId(&self.release.remap, fixture.nodes.items, &row.root) orelse return error.TestUnexpectedResult;
            try text_inputs.append(std.testing.allocator, .{ .route_index = root_id, .value = .{ .kind = .text_node, .index = @intCast(row.root.id) } });
            const source_id = self.append.plannedRecordId(&self.release.remap, fixture.nodes.items, &row.source) orelse return error.TestUnexpectedResult;
            try source_inputs.append(std.testing.allocator, .{ .route_index = row.source.payload.ref, .value = source_id });
        }
        self.source_route_count = fixture.source_routes.items.len;
        for (source_inputs.items) |entry| self.source_route_count = @max(self.source_route_count, @as(usize, @intCast(entry.route_index)) + 1);
        self.source_appends = try prepareSourceRouteAppendsAfterRelease(allocator, &fixture.source_routes, &self.release.remap, self.source_route_count, source_inputs.items);
        errdefer self.source_appends.deinit(allocator);
        self.text_appends = try prepareRouteAppendsAfterRelease(TextSink, allocator, &fixture.text_routes, &self.release.remap, graph_count, text_inputs.items);
        errdefer self.text_appends.deinit(allocator);
        self.bool_appends = try prepareRouteAppendsAfterRelease(BoolSink, allocator, &fixture.bool_routes, &self.release.remap, graph_count, &.{});
        errdefer self.bool_appends.deinit(allocator);
        self.change_appends = try prepareRouteAppendsAfterRelease(ChangeSink, allocator, &fixture.change_routes, &self.release.remap, graph_count, &.{});
        errdefer self.change_appends.deinit(allocator);
        self.structural_appends = try prepareRouteAppendsAfterRelease(StructuralSink, allocator, &fixture.structural_routes, &self.release.remap, graph_count, &.{});
        errdefer self.structural_appends.deinit(allocator);
        try self.append.reservePublication(allocator, &fixture.nodes);
        try self.append.reserveParallelRoutes(allocator, &fixture.text_routes, &fixture.bool_routes, &fixture.change_routes, &fixture.structural_routes);
        try self.source_appends.reserveOuter(allocator, &fixture.source_routes, self.source_route_count);
        return self;
    }

    /// Publishes in engine order. Retiring roots drop their text sink first,
    /// as the engine's sink edits do before dense retirement.
    fn commit(self: *LocalityTransaction, allocator: std.mem.Allocator, fixture: *LocalityRows) void {
        for (self.release.records) |record| fixture.text_routes.items[@intCast(record.active_graph_id.?)] = .empty;
        self.release.applyAdjacency(fixture.nodes.items);
        self.release.applyDense(&fixture.nodes, &fixture.source_routes, &fixture.text_routes, &fixture.bool_routes, &fixture.change_routes, &fixture.structural_routes);
        self.append.commitNodes(&fixture.nodes);
        self.append.commitParallelRoutes(&fixture.text_routes, &fixture.bool_routes, &fixture.change_routes, &fixture.structural_routes);
        self.source_appends.apply(&fixture.source_routes, self.source_route_count);
        const graph_count = self.append.finalGraphCount();
        self.text_appends.apply(&fixture.text_routes, graph_count);
        self.bool_appends.apply(&fixture.bool_routes, graph_count);
        self.change_appends.apply(&fixture.change_routes, graph_count);
        self.structural_appends.apply(&fixture.structural_routes, graph_count);
        self.append.registerAppendedEffects(&fixture.hooks);
        self.release.releaseRetired(allocator, fixture.nodes.items, &fixture.hooks);
    }

    fn deinit(self: *LocalityTransaction, allocator: std.mem.Allocator) void {
        self.structural_appends.deinit(allocator);
        self.change_appends.deinit(allocator);
        self.bool_appends.deinit(allocator);
        self.text_appends.deinit(allocator);
        self.source_appends.deinit(allocator);
        self.append.deinit(allocator);
        self.release.deinit(allocator);
    }
};

/// Work and allocator traffic one prepared transaction cost.
const LocalityCost = struct {
    records: usize,
    edges: usize,
    attempts: usize,
    bytes: usize,
    graph_len: usize,

    fn expectIndependentOfGraphSize(small: LocalityCost, large: LocalityCost) !void {
        try std.testing.expect(large.graph_len > 9 * small.graph_len);
        try std.testing.expectEqual(small.records, large.records);
        try std.testing.expectEqual(small.edges, large.edges);
        try std.testing.expectEqual(small.attempts, large.attempts);
        try std.testing.expectEqual(small.bytes, large.bytes);
    }
};

fn measureLocality(fixture: *LocalityRows, retired_roots: []const *LifecycleTestRecord, replacement_rows: []LocalityRows.Row, commit: bool) !LocalityCost {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var counter = FaultAllocator.init(std.testing.allocator);
    const graph_len = fixture.nodes.items.len;
    var transaction = try LocalityTransaction.prepare(counter.allocator(), fixture, retired_roots, replacement_rows);
    const cost: LocalityCost = .{
        .records = transaction.release_work.records + transaction.append_work.records,
        .edges = transaction.release_work.edges + transaction.append_work.edges,
        .attempts = counter.attempts,
        .bytes = counter.bytes.requested,
        .graph_len = graph_len,
    };
    if (commit) {
        counter.configure(1);
        transaction.commit(counter.allocator(), fixture);
        try std.testing.expectEqual(@as(usize, 0), counter.attempts);
        counter.configure(null);
    }
    transaction.deinit(counter.allocator());
    return cost;
}

fn initReplacementRows(count: usize, first_source_node: u64) ![]LocalityRows.Row {
    const rows = try std.testing.allocator.alloc(LocalityRows.Row, count);
    for (rows, 0..) |*row, index| {
        const base: u64 = 100_000 + @as(u64, @intCast(index)) * 3;
        row.source = .{ .id = base, .payload = .{ .ref = first_source_node + @as(u64, @intCast(index)) } };
        row.label = .{ .id = base + 1, .payload = .{ .map = .{ .input = &row.source } } };
        row.root = .{ .id = base + 2, .payload = .{ .map2 = .{ .left = &row.label, .right = &row.source } } };
    }
    return rows;
}

test "release and append preparation for one row is independent of graph size" {
    const sizes = [_]usize{ 1_000, 10_000 };
    var removal: [2]LocalityCost = undefined;
    var pure_append: [2]LocalityCost = undefined;
    var mixed: [2]LocalityCost = undefined;
    var full_clear: [2]LocalityCost = undefined;
    for (sizes, 0..) |count, sample| {
        var fixture = try LocalityRows.init(std.testing.allocator, count, false);
        defer fixture.deinit();
        try std.testing.expectEqual(3 * count + 4, fixture.nodes.items.len);

        // Remove one row from the middle after the graph is fully live.
        const middle = &fixture.rows[count / 2];
        removal[sample] = try measureLocality(fixture, &.{&middle.root}, &.{}, true);
        try std.testing.expectEqual(3 * count + 1, fixture.nodes.items.len);
        try std.testing.expectEqual(@as(?u64, null), middle.root.active_graph_id);
        try std.testing.expectEqual(@as(u64, 3), fixture.hooks.record_releases);
        try fixture.audit();

        // Pure append of a few rows; the release side must do no graph work.
        const appended = try initReplacementRows(4, @intCast(count + 2));
        defer std.testing.allocator.free(appended);
        pure_append[sample] = try measureLocality(fixture, &.{}, appended, true);
        try std.testing.expectEqual(3 * count + 13, fixture.nodes.items.len);
        try fixture.audit();

        // Mixed: retire one committed row while another row arrives.
        const replaced = try initReplacementRows(1, @intCast(count + 6));
        defer std.testing.allocator.free(replaced);
        mixed[sample] = try measureLocality(fixture, &.{&fixture.rows[1].root}, replaced, true);
        try std.testing.expectEqual(3 * count + 13, fixture.nodes.items.len);
        try fixture.audit();

        // Full clear retires everything and is measured against its own size.
        var everything: shared_buffer.List(*LifecycleTestRecord) = .empty;
        defer everything.deinit(std.testing.allocator);
        for (fixture.rows) |*row| if (row.root.active_graph_id != null) try everything.append(std.testing.allocator, &row.root);
        for (appended) |*row| try everything.append(std.testing.allocator, &row.root);
        for (replaced) |*row| try everything.append(std.testing.allocator, &row.root);
        try everything.append(std.testing.allocator, &fixture.diamond_root);
        const live_before = fixture.nodes.items.len;
        full_clear[sample] = try measureLocality(fixture, everything.items, &.{}, true);
        try std.testing.expectEqual(@as(usize, 0), fixture.nodes.items.len);
        try std.testing.expectEqual(@as(usize, 0), fixture.text_routes.items.len);
        try std.testing.expectEqual(live_before, fixture.hooks.record_releases - 6);
        // Clearing visits each row four times (root, label, source twice
        // through the map2) and the diamond five times: work proportional to
        // the retired set, not more.
        try std.testing.expectEqual(4 * (everything.items.len - 1) + 5, full_clear[sample].records);
        for (fixture.source_routes.items) |route| try std.testing.expectEqual(@as(usize, 0), route.len());
    }
    try LocalityCost.expectIndependentOfGraphSize(removal[0], removal[1]);
    try LocalityCost.expectIndependentOfGraphSize(pure_append[0], pure_append[1]);
    try LocalityCost.expectIndependentOfGraphSize(mixed[0], mixed[1]);
    // One row: root, label, and the source reached through both map2 inputs.
    try std.testing.expectEqual(@as(usize, 4), removal[0].records);
    try std.testing.expect(removal[0].edges <= 8);
    try std.testing.expectEqual(@as(usize, 0), pure_append[0].records);
    try std.testing.expectEqual(@as(usize, 0), pure_append[0].edges);
    try std.testing.expect(full_clear[1].records > 9 * full_clear[0].records);
}

test "sparse release keeps shared inputs, duplicate edges, and removal order coherent" {
    // Shared input retained by survivors: every row's root also reads `shared`.
    {
        var fixture = try LocalityRows.init(std.testing.allocator, 6, true);
        defer fixture.deinit();
        try std.testing.expectEqual(@as(usize, 6), fixture.shared.active_use_count);
        const shared_id: usize = @intCast(fixture.shared.active_graph_id.?);
        const before = try std.testing.allocator.dupe(u64, fixture.nodes.items[shared_id].dependents.slice());
        defer std.testing.allocator.free(before);
        const retired_root_id = fixture.rows[2].root.active_graph_id.?;

        var preview = try prepareReleaseClosure(LifecycleTestRecord, std.testing.allocator, fixture.nodes.items, &.{&fixture.rows[2].root}, &.{});
        try std.testing.expectEqualSlices(*LifecycleTestRecord, &.{ &fixture.rows[2].root, &fixture.rows[2].label, &fixture.rows[2].source }, preview.records);
        try std.testing.expectEqualSlices(ExistingUseIncrement, &.{.{ .record_id = @intCast(shared_id), .count = 1 }}, preview.survivor_use_decrements);
        // Expected survivor edges: the retired root's edge dropped, the
        // others renumbered through the remap. Order within the list is not
        // a contract (the drop swaps the last edge into the hole), so compare
        // as sets.
        var expected: shared_buffer.List(u64) = .empty;
        defer expected.deinit(std.testing.allocator);
        for (before) |old| if (preview.remap.finalId(old)) |final| try expected.append(std.testing.allocator, final);
        try std.testing.expectEqual(before.len - 1, expected.items.len);
        std.mem.sort(u64, expected.items, {}, std.sort.asc(u64));
        // The root's edge into its own label is not dropped edge by edge: the
        // label retires too and its list is freed wholesale. Only the edge
        // into the surviving `shared` input is planned.
        try std.testing.expectEqualSlices(PreparedEdgeDrop, &.{.{ .input_id = @intCast(shared_id), .dependent_id = retired_root_id, .position = 1 }}, preview.edge_drops);
        preview.deinit(std.testing.allocator);

        _ = try measureLocality(fixture, &.{&fixture.rows[2].root}, &.{}, true);
        try fixture.audit();
        try std.testing.expectEqual(@as(usize, 5), fixture.shared.active_use_count);
        try std.testing.expectEqual(@as(?u64, @intCast(shared_id)), fixture.shared.active_graph_id);
        const actual = try std.testing.allocator.dupe(u64, fixture.nodes.items[shared_id].dependents.slice());
        defer std.testing.allocator.free(actual);
        std.mem.sort(u64, actual, {}, std.sort.asc(u64));
        try std.testing.expectEqualSlices(u64, expected.items, actual);
        for (fixture.rows) |*row| if (row.root.active_graph_id) |id| {
            try std.testing.expect(containsU64(fixture.nodes.items[shared_id].dependents.slice(), id));
        };
        try std.testing.expect(!containsU64(fixture.nodes.items[shared_id].dependents.slice(), retired_root_id) or retired_root_id < fixture.nodes.items.len);
        try std.testing.expectEqualSlices(u64, &.{@intCast(shared_id)}, fixture.source_routes.items[6].slice());
    }

    // Duplicate inputs: `map2(x, x)` and `combine([x, x])` decrement `x` once.
    {
        var x = LifecycleTestRecord{ .id = 1, .payload = .{ .ref = 0 } };
        var twice = LifecycleTestRecord{ .id = 2, .payload = .{ .map2 = .{ .left = &x, .right = &x } } };
        var children = [_]*LifecycleTestRecord{ &x, &x };
        var combined = LifecycleTestRecord{ .id = 3, .payload = .{ .combine = .{ .children = &children } } };
        var nodes: shared_buffer.List(Node(LifecycleTestRecord)) = .empty;
        var source_routes: RouteTable(u64) = .empty;
        var text_routes: RouteTable(TextSink) = .empty;
        var bool_routes: RouteTable(BoolSink) = .empty;
        var change_routes: RouteTable(ChangeSink) = .empty;
        var structural_routes: RouteTable(StructuralSink) = .empty;
        var hooks: LifecycleTestHooks = .{};
        defer {
            clearSourceRoutes(std.testing.allocator, &source_routes);
            source_routes.deinit(std.testing.allocator);
            clear(LifecycleTestRecord, std.testing.allocator, &nodes, &hooks);
            nodes.deinit(std.testing.allocator);
        }
        _ = retainRecord(LifecycleTestRecord, std.testing.allocator, &nodes, &source_routes, 1, &twice, &hooks);
        _ = retainRecord(LifecycleTestRecord, std.testing.allocator, &nodes, &source_routes, 1, &combined, &hooks);
        try std.testing.expectEqual(@as(usize, 2), x.active_use_count);
        try std.testing.expectEqualSlices(u64, &.{ 1, 2 }, nodes.items[0].dependents.slice());

        var release = try prepareReleaseClosure(LifecycleTestRecord, std.testing.allocator, nodes.items, &.{&twice}, &.{});
        defer release.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(*LifecycleTestRecord, &.{&twice}, release.records);
        try std.testing.expectEqualSlices(ExistingUseIncrement, &.{.{ .record_id = 0, .count = 1 }}, release.survivor_use_decrements);
        // `twice` drops its single edge into x (both inputs coincide, so one
        // position) and `combined` moves from slot 2 into slot 1.
        try std.testing.expectEqualSlices(PreparedEdgeDrop, &.{.{ .input_id = 0, .dependent_id = 1, .position = 0 }}, release.edge_drops);
        try std.testing.expectEqualSlices(PreparedEdgeRenumber, &.{.{ .input_id = 0, .dependent_id = 2, .final_id = 1, .position = 0 }}, release.edge_renumbers);
        release.applyAdjacency(nodes.items);
        try std.testing.expectEqualSlices(u64, &.{1}, nodes.items[0].dependents.slice());
        release.applyDense(&nodes, &source_routes, &text_routes, &bool_routes, &change_routes, &structural_routes);
        release.releaseRetired(std.testing.allocator, nodes.items, &hooks);
        try std.testing.expectEqual(@as(usize, 1), x.active_use_count);
        try std.testing.expectEqual(@as(?u64, 1), combined.active_graph_id);
        try std.testing.expectEqualSlices(u64, &.{0}, source_routes.items[0].slice());
        try auditDenseIds(LifecycleTestRecord, nodes.items);

        var last = try prepareReleaseClosure(LifecycleTestRecord, std.testing.allocator, nodes.items, &.{&combined}, &.{});
        defer last.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(*LifecycleTestRecord, &.{ &combined, &x }, last.records);
        last.applyAdjacency(nodes.items);
        last.applyDense(&nodes, &source_routes, &text_routes, &bool_routes, &change_routes, &structural_routes);
        last.releaseRetired(std.testing.allocator, nodes.items, &hooks);
        try std.testing.expectEqual(@as(usize, 0), nodes.items.len);
        try std.testing.expectEqual(@as(usize, 0), source_routes.items[0].len());
    }

    // Removal order: retiring the first and last rows together makes the
    // last row's records move into the first row's holes and then retire
    // from their new slots; the reverse order retires them in place first.
    for ([_][2]usize{ .{ 0, 7 }, .{ 7, 0 }, .{ 3, 4 }, .{ 7, 6 } }) |order| {
        var fixture = try LocalityRows.init(std.testing.allocator, 8, false);
        defer fixture.deinit();
        const roots = [_]*LifecycleTestRecord{ &fixture.rows[order[0]].root, &fixture.rows[order[1]].root };
        var release = try prepareReleaseClosure(LifecycleTestRecord, std.testing.allocator, fixture.nodes.items, &roots, &.{});
        try std.testing.expectEqual(@as(usize, 6), release.records.len);
        try std.testing.expectEqual(@as(usize, 3 * 8 + 4 - 6), release.remap.survivor_count);
        for (release.records) |record| try std.testing.expectEqual(@as(?u64, null), release.remap.finalId(record.active_graph_id.?));
        // Every displaced survivor came from beyond the survivor prefix.
        var displaced = release.remap.inverse.iterator();
        while (displaced.next()) |entry| {
            try std.testing.expect(entry.value_ptr.* >= release.remap.survivor_count);
            try std.testing.expect(entry.key_ptr.* < release.remap.survivor_count);
            try std.testing.expectEqual(@as(?u64, entry.key_ptr.*), release.remap.finalId(entry.value_ptr.*));
        }
        release.deinit(std.testing.allocator);
        _ = try measureLocality(fixture, &roots, &.{}, true);
        try std.testing.expectEqual(@as(usize, 3 * 8 + 4 - 6), fixture.nodes.items.len);
        try fixture.audit();
        try std.testing.expectEqual(@as(u64, 6), fixture.hooks.record_releases);
    }
}

test "dropping or adding one edge on a shared input is independent of its fan-out" {
    const sizes = [_]usize{ 1_000, 10_000 };
    var removal: [2]LocalityCost = undefined;
    var shared_append: [2]LocalityCost = undefined;
    var mixed: [2]LocalityCost = undefined;
    for (sizes, 0..) |count, sample| {
        // Replacement rows outlive the fixture: once published they belong to
        // its graph and are released by its teardown.
        const appended = try initReplacementRows(1, @intCast(count + 2));
        defer std.testing.allocator.free(appended);
        const replaced = try initReplacementRows(1, @intCast(count + 3));
        defer std.testing.allocator.free(replaced);
        var fixture = try LocalityRows.init(std.testing.allocator, count, true);
        defer fixture.deinit();
        const shared_id: usize = @intCast(fixture.shared.active_graph_id.?);
        try std.testing.expectEqual(count, fixture.nodes.items[shared_id].dependents.len());

        // Retire one of the `count` rows that all read `shared`.
        removal[sample] = try measureLocality(fixture, &.{&fixture.rows[count / 2].root}, &.{}, true);
        try std.testing.expectEqual(count - 1, fixture.nodes.items[shared_id].dependents.len());
        try std.testing.expectEqual(count - 1, fixture.shared.active_use_count);
        try fixture.audit();

        // Add one more row that reads `shared`.
        for (appended) |*row| row.root.payload = .{ .map2 = .{ .left = &row.label, .right = &fixture.shared } };
        shared_append[sample] = try measureLocality(fixture, &.{}, appended, true);
        try std.testing.expectEqual(count, fixture.nodes.items[shared_id].dependents.len());
        try fixture.audit();

        // Replace one `shared` reader with another in a single transaction.
        for (replaced) |*row| row.root.payload = .{ .map2 = .{ .left = &row.label, .right = &fixture.shared } };
        mixed[sample] = try measureLocality(fixture, &.{&fixture.rows[1].root}, replaced, true);
        try std.testing.expectEqual(count, fixture.nodes.items[shared_id].dependents.len());
        try std.testing.expectEqual(count, fixture.shared.active_use_count);
        try fixture.audit();
    }
    try LocalityCost.expectIndependentOfGraphSize(removal[0], removal[1]);
    try LocalityCost.expectIndependentOfGraphSize(shared_append[0], shared_append[1]);
    try LocalityCost.expectIndependentOfGraphSize(mixed[0], mixed[1]);
    // One retired row is root, label and source; the root's two edges and the
    // label's one are validated through their slots. Nothing reads the rest
    // of `shared`'s fan-out (which would add `count` edges here).
    try std.testing.expectEqual(@as(usize, 4), removal[0].records);
    try std.testing.expect(removal[0].edges <= 8);
    try std.testing.expect(shared_append[0].edges <= 2);
    try std.testing.expect(mixed[0].edges <= 10);
}

test "shared input adjacency compacts after bulk retirement, clones when full, and trims to inline" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    // Rows appended later outlive the fixture, which releases them at teardown.
    const three = try initReplacementRows(3, 70);
    defer std.testing.allocator.free(three);
    const two = try initReplacementRows(2, 74);
    defer std.testing.allocator.free(two);
    var fixture = try LocalityRows.init(std.testing.allocator, 64, true);
    defer fixture.deinit();
    const shared_id: usize = @intCast(fixture.shared.active_graph_id.?);
    for (three) |*row| row.root.payload = .{ .map2 = .{ .left = &row.label, .right = &fixture.shared } };
    for (two) |*row| row.root.payload = .{ .map2 = .{ .left = &row.label, .right = &fixture.shared } };
    // Ingestion grew the list geometrically: 64 readers fill 64 slots.
    try std.testing.expectEqual(@as(usize, 64), fixture.nodes.items[shared_id].dependents.len());
    try std.testing.expectEqual(@as(u32, 64), fixture.nodes.items[shared_id].dependents.capacity);

    const Step = struct {
        fn run(rows: *LocalityRows, retired: []const *LifecycleTestRecord, appended: []LocalityRows.Row, expected_replacements: usize, expected_rewrite: bool) !LocalityTransaction {
            var counter = FaultAllocator.init(std.testing.allocator);
            var transaction = try LocalityTransaction.prepare(counter.allocator(), rows, retired, appended);
            try std.testing.expectEqual(expected_replacements, transaction.release.replacements.items.len);
            for (transaction.release.replacements.items) |replacement| try std.testing.expectEqual(expected_rewrite, replacement.rewrite_slots);
            counter.configure(1);
            transaction.commit(counter.allocator(), rows);
            try std.testing.expectEqual(@as(usize, 0), counter.attempts);
            counter.configure(null);
            return transaction;
        }
    };

    // Retiring half leaves 32 live entries in 64 slots: above a quarter, so
    // the edges are dropped in place and the storage is kept.
    var half: [32]*LifecycleTestRecord = undefined;
    for (&half, 0..) |*root, index| root.* = &fixture.rows[index].root;
    var first = try Step.run(fixture, &half, &.{}, 0, false);
    try std.testing.expectEqual(half.len, first.release.edge_drops.len);
    first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 32), fixture.nodes.items[shared_id].dependents.len());
    try std.testing.expectEqual(@as(u32, 64), fixture.nodes.items[shared_id].dependents.capacity);
    try fixture.audit();

    // Sixteen more leave 16 live in 64 slots: the list is rebuilt at its live
    // size with every survivor's slot rewritten. Each retired row validates
    // its own three edges, and the copy reads the 32 entries still live, two
    // per drop in this step; the copy is bounded by the drops that led to it,
    // so a dropped edge stays amortized O(1).
    var quarter: [16]*LifecycleTestRecord = undefined;
    for (&quarter, 0..) |*root, index| root.* = &fixture.rows[32 + index].root;
    var second = try Step.run(fixture, &quarter, &.{}, 1, true);
    try std.testing.expectEqual(@as(usize, 0), second.release.edge_drops.len);
    try std.testing.expectEqual(3 * quarter.len + 32, second.release_work.edges);
    second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 16), fixture.nodes.items[shared_id].dependents.len());
    try std.testing.expectEqual(@as(u32, 16), fixture.nodes.items[shared_id].dependents.capacity);
    try fixture.audit();

    // A full list that loses one reader and gains three in one transaction:
    // the append clones it with geometric headroom (committed storage is not
    // grown during preparation) and the drop lands on the installed clone.
    var third = try Step.run(fixture, &.{&fixture.rows[48].root}, three, 1, false);
    try std.testing.expectEqual(@as(usize, 1), third.release.edge_drops.len);
    third.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 18), fixture.nodes.items[shared_id].dependents.len());
    try std.testing.expectEqual(@as(u32, 32), fixture.nodes.items[shared_id].dependents.capacity);
    try std.testing.expectEqual(@as(?u64, null), fixture.rows[48].root.active_graph_id);
    try fixture.audit();

    // With headroom left, two more readers append in place.
    var fourth = try Step.run(fixture, &.{}, two, 0, false);
    fourth.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 20), fixture.nodes.items[shared_id].dependents.len());
    try std.testing.expectEqual(@as(u32, 32), fixture.nodes.items[shared_id].dependents.capacity);
    try fixture.audit();

    // Retiring every reader but one returns the list to its inline form.
    var rest: shared_buffer.List(*LifecycleTestRecord) = .empty;
    defer rest.deinit(std.testing.allocator);
    for (fixture.rows[49..]) |*row| try rest.append(std.testing.allocator, &row.root);
    for (three) |*row| try rest.append(std.testing.allocator, &row.root);
    try rest.append(std.testing.allocator, &two[0].root);
    var fifth = try Step.run(fixture, rest.items, &.{}, 0, false);
    fifth.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u64, &.{two[1].root.active_graph_id.?}, fixture.nodes.items[shared_id].dependents.slice());
    try std.testing.expectEqual(@as(u32, 0), fixture.nodes.items[shared_id].dependents.capacity);
    try std.testing.expectEqual(@as(usize, 1), fixture.shared.active_use_count);
    try fixture.audit();
}

test "structural preparation refusal publishes nothing and leaks nothing" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    // Replacement rows outlive the fixture: once published they belong to
    // its graph and are released by its teardown.
    const replaced = try initReplacementRows(2, 14);
    defer std.testing.allocator.free(replaced);
    var fixture = try LocalityRows.init(std.testing.allocator, 12, true);
    defer fixture.deinit();
    // The replacement rows also read `shared`, so the transaction nets a
    // release against a retain on the same survivor.
    for (replaced) |*row| row.root.payload = .{ .map2 = .{ .left = &row.label, .right = &fixture.shared } };
    const retired = [_]*LifecycleTestRecord{ &fixture.rows[5].root, &fixture.rows[11].root };

    var counter = FaultAllocator.init(std.testing.allocator);
    var baseline = try LocalityTransaction.prepare(counter.allocator(), fixture, &retired, replaced);
    const attempts = counter.attempts;
    try std.testing.expect(attempts != 0);
    // The two retired roots drop `shared` twice and the two replacement roots
    // pick it up again: it survives in place with a netted decrement the
    // append's increments restore in the same publication.
    try std.testing.expectEqualSlices(ExistingUseIncrement, &.{.{ .record_id = fixture.shared.active_graph_id.?, .count = 2 }}, baseline.release.survivor_use_decrements);
    try std.testing.expectEqualSlices(ExistingUseIncrement, &.{.{ .record_id = fixture.shared.active_graph_id.?, .count = 2 }}, baseline.append.existing_use_increments);
    baseline.deinit(counter.allocator());

    const live_len = fixture.nodes.items.len;
    for (1..attempts + 1) |failure_number| {
        var fault = FaultAllocator.init(std.testing.allocator);
        fault.configure(failure_number);
        try std.testing.expectError(error.OutOfMemory, LocalityTransaction.prepare(fault.allocator(), fixture, &retired, replaced));
        try std.testing.expectEqual(live_len, fixture.nodes.items.len);
        try std.testing.expectEqual(@as(usize, 12), fixture.shared.active_use_count);
        try std.testing.expectEqual(@as(usize, 1), fixture.rows[5].root.active_use_count);
        try std.testing.expectEqual(@as(usize, 1), fixture.rows[11].source.active_use_count);
        try std.testing.expectEqual(@as(u64, 0), fixture.hooks.record_releases);
        for (replaced) |*row| {
            try std.testing.expectEqual(@as(?u64, null), row.root.active_graph_id);
            try std.testing.expectEqual(@as(usize, 1), row.root.ref_count);
        }
        try fixture.audit();
    }

    _ = try measureLocality(fixture, &retired, replaced, true);
    try fixture.audit();
    try std.testing.expectEqual(@as(usize, 12), fixture.shared.active_use_count);
    try std.testing.expectEqual(live_len, fixture.nodes.items.len);
    try std.testing.expectEqual(@as(u64, 6), fixture.hooks.record_releases);
    for (replaced) |*row| try std.testing.expectEqual(@as(usize, 2), row.root.ref_count);
}

test "active graph dirty queue collects roots and dependents by rank" {
    var records = [_]TestRecord{
        .{ .id = 0 },
        .{ .id = 1 },
        .{ .id = 2 },
        .{ .id = 3 },
    };
    var nodes = [_]Node(TestRecord){
        .{ .record = &records[0], .rank = 0 },
        .{ .record = &records[1], .rank = 3 },
        .{ .record = &records[2], .rank = 1 },
        .{ .record = &records[3], .rank = 2 },
    };
    defer {
        for (&nodes) |*node| {
            node.dependents.deinit(std.testing.allocator);
        }
    }

    try appendTestEdge(&nodes, 0, 1);
    try appendTestEdge(&nodes, 0, 2);
    try appendTestEdge(&nodes, 2, 3);
    try appendTestEdge(&nodes, 3, 1);

    var queue = DirtyRecordQueue{};
    defer queue.deinit(std.testing.allocator);

    const dirty_ids = queue.collectForRoots(TestRecord, std.testing.allocator, &nodes, &.{ 0, 2 });
    try std.testing.expectEqualSlices(u64, &.{ 0, 2, 3, 1 }, dirty_ids);
}

test "active graph dirty queue reservation sweeps failures and makes collection allocation free" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var records = [_]TestRecord{ .{ .id = 0 }, .{ .id = 1 }, .{ .id = 2 } };
    var nodes = [_]Node(TestRecord){
        .{ .record = &records[0], .rank = 0 },
        .{ .record = &records[1], .rank = 1 },
        .{ .record = &records[2], .rank = 2 },
    };
    defer for (&nodes) |*node| node.dependents.deinit(std.testing.allocator);
    try appendTestEdge(&nodes, 0, 1);
    try appendTestEdge(&nodes, 1, 2);

    var baseline_fault = FaultAllocator.init(std.testing.allocator);
    var baseline = DirtyRecordQueue{};
    defer baseline.deinit(baseline_fault.allocator());
    try baseline.reserveForGraph(TestRecord, baseline_fault.allocator(), &nodes);
    const attempts = baseline_fault.attempts;
    baseline_fault.configure(1);
    try std.testing.expectEqualSlices(u64, &.{ 0, 1, 2 }, baseline.collectForRoots(TestRecord, baseline_fault.allocator(), &nodes, &.{0}));
    try std.testing.expectEqual(@as(usize, 0), baseline_fault.attempts);

    var induced: usize = 0;
    for (1..attempts + 1) |fail_at| {
        var fault = FaultAllocator.init(std.testing.allocator);
        fault.configure(fail_at);
        var queue = DirtyRecordQueue{};
        defer queue.deinit(fault.allocator());
        try std.testing.expectError(error.OutOfMemory, queue.reserveForGraph(TestRecord, fault.allocator(), &nodes));
        induced += 1;
    }
    try std.testing.expectEqual(attempts, induced);
}

test "active graph dirty queue collects source-route dependents by rank" {
    var records = [_]TestRecord{
        .{ .id = 0 },
        .{ .id = 1 },
        .{ .id = 2 },
    };
    var nodes = [_]Node(TestRecord){
        .{ .record = &records[0], .rank = 2 },
        .{ .record = &records[1], .rank = 0 },
        .{ .record = &records[2], .rank = 1 },
    };
    defer {
        for (&nodes) |*node| {
            node.dependents.deinit(std.testing.allocator);
        }
    }
    try appendTestEdge(&nodes, 1, 2);
    try appendTestEdge(&nodes, 2, 0);

    var source_routes: RouteTable(u64) = .empty;
    defer source_routes.deinit(std.testing.allocator);
    defer clearSourceRoutes(std.testing.allocator, &source_routes);
    appendSourceRoute(std.testing.allocator, &source_routes, 4, 3, 1);
    appendSourceRoute(std.testing.allocator, &source_routes, 4, 3, 1);

    var queue = DirtyRecordQueue{};
    defer queue.deinit(std.testing.allocator);

    const dirty_ids = queue.collectForSources(TestRecord, std.testing.allocator, &nodes, source_routes.items, &.{3});
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 0 }, dirty_ids);
}

test "active graph dirty queue reuses retained buffers and ranks reachable records" {
    var records = [_]TestRecord{
        .{ .id = 0 },
        .{ .id = 1 },
        .{ .id = 2 },
        .{ .id = 3 },
    };
    var nodes = [_]Node(TestRecord){
        .{ .record = &records[0], .rank = 0 },
        .{ .record = &records[1], .rank = 1 },
        .{ .record = &records[2], .rank = 1 },
        .{ .record = &records[3], .rank = 2 },
    };
    defer {
        for (&nodes) |*node| {
            node.dependents.deinit(std.testing.allocator);
        }
    }
    try appendTestEdge(&nodes, 0, 1);
    try appendTestEdge(&nodes, 0, 2);
    try appendTestEdge(&nodes, 1, 3);
    try appendTestEdge(&nodes, 2, 3);

    var source_routes: RouteTable(u64) = .empty;
    defer source_routes.deinit(std.testing.allocator);
    defer clearSourceRoutes(std.testing.allocator, &source_routes);
    appendSourceRoute(std.testing.allocator, &source_routes, 1, 0, 0);
    appendSourceRoute(std.testing.allocator, &source_routes, 1, 0, 0);

    var queue = DirtyRecordQueue{};
    defer queue.deinit(std.testing.allocator);

    const first_ids = queue.collectForSources(TestRecord, std.testing.allocator, &nodes, source_routes.items, &.{0});
    try std.testing.expectEqualSlices(u64, &.{ 0, 1, 2, 3 }, first_ids);

    const pending_capacity = queue.pending_record_ids.capacity;
    const ordered_capacity = queue.ordered_record_ids.capacity;
    const seen_capacity = queue.seen_generations.capacity;
    const rank_capacity = queue.rank_counts.capacity;

    const second_ids = queue.collectForSources(TestRecord, std.testing.allocator, &nodes, source_routes.items, &.{0});
    try std.testing.expectEqualSlices(u64, &.{ 0, 1, 2, 3 }, second_ids);
    try std.testing.expectEqual(pending_capacity, queue.pending_record_ids.capacity);
    try std.testing.expectEqual(ordered_capacity, queue.ordered_record_ids.capacity);
    try std.testing.expectEqual(seen_capacity, queue.seen_generations.capacity);
    try std.testing.expectEqual(rank_capacity, queue.rank_counts.capacity);
}

test "active source routes replace and remove ids" {
    var source_routes: RouteTable(u64) = .empty;
    defer source_routes.deinit(std.testing.allocator);
    defer clearSourceRoutes(std.testing.allocator, &source_routes);

    appendSourceRoute(std.testing.allocator, &source_routes, 4, 2, 7);
    appendSourceRoute(std.testing.allocator, &source_routes, 4, 2, 7);
    try std.testing.expectEqualSlices(u64, &.{7}, source_routes.items[2].slice());

    replaceSourceRouteId(&source_routes, 2, 7, 3);
    try std.testing.expectEqualSlices(u64, &.{3}, source_routes.items[2].slice());

    removeSourceRoute(&source_routes, 2, 3);
    try std.testing.expectEqual(@as(usize, 0), source_routes.items[2].len());
}

test "active sink routes use route-specific keys" {
    var text_routes: RouteTable(TextSink) = .empty;
    var bool_routes: RouteTable(BoolSink) = .empty;
    var change_routes: RouteTable(ChangeSink) = .empty;
    var structural_routes: RouteTable(StructuralSink) = .empty;
    defer text_routes.deinit(std.testing.allocator);
    defer bool_routes.deinit(std.testing.allocator);
    defer change_routes.deinit(std.testing.allocator);
    defer structural_routes.deinit(std.testing.allocator);
    defer clearSinkRoutes(std.testing.allocator, &text_routes, &bool_routes, &change_routes, &structural_routes);

    appendTextRoute(std.testing.allocator, &text_routes, 2, 1, .{ .kind = .text_node, .index = 3 });
    appendTextRoute(std.testing.allocator, &text_routes, 2, 1, .{ .kind = .text_attr, .index = 3 });
    updateTextRouteIndex(&text_routes, 1, .text_attr, 3, 8);
    removeTextRoute(&text_routes, 1, .text_node, 3);
    try std.testing.expectEqualSlices(TextSink, &.{.{ .kind = .text_attr, .index = 8 }}, text_routes.items[1].slice());

    appendBoolRoute(std.testing.allocator, &bool_routes, 2, 1, .{ .kind = .bool_attr, .index = 4 });
    appendBoolRoute(std.testing.allocator, &bool_routes, 2, 1, .{ .kind = .custom_bool_attr, .index = 4 });
    updateBoolRouteIndex(&bool_routes, 1, .custom_bool_attr, 4, 9);
    removeBoolRoute(&bool_routes, 1, .bool_attr, 4);
    try std.testing.expectEqualSlices(BoolSink, &.{.{ .kind = .custom_bool_attr, .index = 9 }}, bool_routes.items[1].slice());
    removeBoolRoute(&bool_routes, 1, .custom_bool_attr, 9);
    try std.testing.expectEqual(@as(usize, 0), bool_routes.items[1].len());

    appendChangeRoute(std.testing.allocator, &change_routes, 2, 1, .{ .index = 5 });
    updateChangeRouteIndex(&change_routes, 1, 5, 10);
    removeChangeRoute(&change_routes, 1, 10);
    try std.testing.expectEqual(@as(usize, 0), change_routes.items[1].len());

    appendStructuralRoute(std.testing.allocator, &structural_routes, 2, 1, .{ .kind = .when, .index = 6 });
    appendStructuralRoute(std.testing.allocator, &structural_routes, 2, 1, .{ .kind = .each, .index = 6 });
    updateStructuralRouteIndex(&structural_routes, 1, .each, 6, 11);
    removeStructuralRoute(&structural_routes, 1, .when, 6);
    try std.testing.expectEqualSlices(StructuralSink, &.{.{ .kind = .each, .index = 11 }}, structural_routes.items[1].slice());
}

test "active sink route record removal moves last route entries" {
    var text_routes: RouteTable(TextSink) = .empty;
    var bool_routes: RouteTable(BoolSink) = .empty;
    var change_routes: RouteTable(ChangeSink) = .empty;
    var structural_routes: RouteTable(StructuralSink) = .empty;
    defer text_routes.deinit(std.testing.allocator);
    defer bool_routes.deinit(std.testing.allocator);
    defer change_routes.deinit(std.testing.allocator);
    defer structural_routes.deinit(std.testing.allocator);
    defer clearSinkRoutes(std.testing.allocator, &text_routes, &bool_routes, &change_routes, &structural_routes);

    _ = ensureTextRoute(std.testing.allocator, &text_routes, 3, 0);
    appendTextRoute(std.testing.allocator, &text_routes, 3, 1, .{ .kind = .text_attr, .index = 4 });
    appendTextRoute(std.testing.allocator, &text_routes, 3, 2, .{ .kind = .text_node, .index = 9 });

    removeSinkRoutesForRecordId(std.testing.allocator, &text_routes, &bool_routes, &change_routes, &structural_routes, 0, 2);

    try std.testing.expectEqual(@as(usize, 2), text_routes.items.len);
    try std.testing.expectEqualSlices(TextSink, &.{.{ .kind = .text_node, .index = 9 }}, text_routes.items[0].slice());
    try std.testing.expectEqualSlices(TextSink, &.{.{ .kind = .text_attr, .index = 4 }}, text_routes.items[1].slice());
}

test "active graph retain and release update moved record ids and routes" {
    var source_a = LifecycleTestRecord{ .id = 0, .payload = .{ .ref = 1 } };
    var source_b = LifecycleTestRecord{ .id = 1, .payload = .{ .ref = 2 } };
    var mapped = LifecycleTestRecord{ .id = 2, .payload = .{ .map = .{ .input = &source_b } } };

    var nodes: shared_buffer.List(Node(LifecycleTestRecord)) = .empty;
    defer nodes.deinit(std.testing.allocator);

    var source_routes: RouteTable(u64) = .empty;
    var text_routes: RouteTable(TextSink) = .empty;
    var bool_routes: RouteTable(BoolSink) = .empty;
    var change_routes: RouteTable(ChangeSink) = .empty;
    var structural_routes: RouteTable(StructuralSink) = .empty;
    defer source_routes.deinit(std.testing.allocator);
    defer text_routes.deinit(std.testing.allocator);
    defer bool_routes.deinit(std.testing.allocator);
    defer change_routes.deinit(std.testing.allocator);
    defer structural_routes.deinit(std.testing.allocator);
    defer clearRoutes(std.testing.allocator, &source_routes, &text_routes, &bool_routes, &change_routes, &structural_routes);

    var hooks = LifecycleTestHooks{};
    try std.testing.expectEqual(@as(u64, 1), retainRecord(LifecycleTestRecord, std.testing.allocator, &nodes, &source_routes, 4, &source_a, &hooks));
    try std.testing.expectEqual(@as(u64, 2), retainRecord(LifecycleTestRecord, std.testing.allocator, &nodes, &source_routes, 4, &mapped, &hooks));
    try std.testing.expectEqual(@as(usize, 3), nodes.items.len);
    try std.testing.expectEqual(@as(?u64, 0), source_a.active_graph_id);
    try std.testing.expectEqual(@as(?u64, 1), source_b.active_graph_id);
    try std.testing.expectEqual(@as(?u64, 2), mapped.active_graph_id);
    try std.testing.expectEqualSlices(u64, &.{2}, nodes.items[1].dependents.slice());
    try std.testing.expectEqualSlices(u64, &.{0}, source_routes.items[1].slice());
    try std.testing.expectEqualSlices(u64, &.{1}, source_routes.items[2].slice());

    releaseRecord(
        LifecycleTestRecord,
        std.testing.allocator,
        &nodes,
        &source_routes,
        &text_routes,
        &bool_routes,
        &change_routes,
        &structural_routes,
        &source_a,
        &hooks,
    );
    try std.testing.expectEqual(@as(usize, 2), nodes.items.len);
    try std.testing.expectEqual(@as(?u64, null), source_a.active_graph_id);
    try std.testing.expectEqual(@as(?u64, 1), source_b.active_graph_id);
    try std.testing.expectEqual(@as(?u64, 0), mapped.active_graph_id);
    try std.testing.expectEqual(&mapped, nodes.items[0].record);
    try std.testing.expectEqual(&source_b, nodes.items[1].record);
    try std.testing.expectEqualSlices(u64, &.{0}, nodes.items[1].dependents.slice());
    try std.testing.expectEqualSlices(u64, &.{}, source_routes.items[1].slice());
    try std.testing.expectEqualSlices(u64, &.{1}, source_routes.items[2].slice());

    releaseRecord(
        LifecycleTestRecord,
        std.testing.allocator,
        &nodes,
        &source_routes,
        &text_routes,
        &bool_routes,
        &change_routes,
        &structural_routes,
        &mapped,
        &hooks,
    );
    try std.testing.expectEqual(@as(usize, 0), nodes.items.len);
    try std.testing.expectEqual(@as(?u64, null), source_b.active_graph_id);
    try std.testing.expectEqual(@as(?u64, null), mapped.active_graph_id);
    try std.testing.expectEqual(@as(usize, 1), source_a.ref_count);
    try std.testing.expectEqual(@as(usize, 1), source_b.ref_count);
    try std.testing.expectEqual(@as(usize, 1), mapped.ref_count);
    try std.testing.expectEqual(@as(u64, 3), hooks.record_releases);
}

test "row source is an ordinary rank zero root with normal dependents" {
    var row_source = LifecycleTestRecord{ .id = 41, .payload = .row_source };
    var mapped = LifecycleTestRecord{ .id = 42, .payload = .{ .map = .{ .input = &row_source } } };

    var nodes: shared_buffer.List(Node(LifecycleTestRecord)) = .empty;
    defer nodes.deinit(std.testing.allocator);
    var source_routes: RouteTable(u64) = .empty;
    var text_routes: RouteTable(TextSink) = .empty;
    var bool_routes: RouteTable(BoolSink) = .empty;
    var change_routes: RouteTable(ChangeSink) = .empty;
    var structural_routes: RouteTable(StructuralSink) = .empty;
    defer source_routes.deinit(std.testing.allocator);
    defer text_routes.deinit(std.testing.allocator);
    defer bool_routes.deinit(std.testing.allocator);
    defer change_routes.deinit(std.testing.allocator);
    defer structural_routes.deinit(std.testing.allocator);
    defer clearRoutes(std.testing.allocator, &source_routes, &text_routes, &bool_routes, &change_routes, &structural_routes);

    var hooks = LifecycleTestHooks{};
    try std.testing.expectEqual(@as(u64, 2), retainRecord(LifecycleTestRecord, std.testing.allocator, &nodes, &source_routes, 0, &mapped, &hooks));
    try std.testing.expectEqual(@as(usize, 2), nodes.items.len);
    try std.testing.expectEqual(@as(u64, 0), nodes.items[@intCast(row_source.active_graph_id.?)].rank);
    try std.testing.expectEqual(@as(u64, 1), nodes.items[@intCast(mapped.active_graph_id.?)].rank);
    try std.testing.expectEqualSlices(u64, &.{mapped.active_graph_id.?}, nodes.items[@intCast(row_source.active_graph_id.?)].dependents.slice());
    try std.testing.expectEqual(@as(usize, 0), source_routes.items.len);

    releaseRecord(
        LifecycleTestRecord,
        std.testing.allocator,
        &nodes,
        &source_routes,
        &text_routes,
        &bool_routes,
        &change_routes,
        &structural_routes,
        &mapped,
        &hooks,
    );
    try std.testing.expectEqual(@as(usize, 0), nodes.items.len);
    try std.testing.expectEqual(@as(u64, 2), hooks.record_releases);
}

test "active graph interval records use explicit lifecycle hooks" {
    var interval = LifecycleTestRecord{ .id = 7, .payload = .{ .interval_source = .{ .period_ms = 250 } } };

    var nodes: shared_buffer.List(Node(LifecycleTestRecord)) = .empty;
    defer nodes.deinit(std.testing.allocator);

    var source_routes: RouteTable(u64) = .empty;
    var text_routes: RouteTable(TextSink) = .empty;
    var bool_routes: RouteTable(BoolSink) = .empty;
    var change_routes: RouteTable(ChangeSink) = .empty;
    var structural_routes: RouteTable(StructuralSink) = .empty;
    defer source_routes.deinit(std.testing.allocator);
    defer text_routes.deinit(std.testing.allocator);
    defer bool_routes.deinit(std.testing.allocator);
    defer change_routes.deinit(std.testing.allocator);
    defer structural_routes.deinit(std.testing.allocator);
    defer clearRoutes(std.testing.allocator, &source_routes, &text_routes, &bool_routes, &change_routes, &structural_routes);

    var hooks = LifecycleTestHooks{};
    try std.testing.expectEqual(@as(u64, 1), retainRecord(LifecycleTestRecord, std.testing.allocator, &nodes, &source_routes, 1, &interval, &hooks));
    try std.testing.expectEqual(@as(u64, 1), hooks.interval_ensures);
    try std.testing.expectEqual(@as(usize, 1), nodes.items.len);

    releaseRecord(
        LifecycleTestRecord,
        std.testing.allocator,
        &nodes,
        &source_routes,
        &text_routes,
        &bool_routes,
        &change_routes,
        &structural_routes,
        &interval,
        &hooks,
    );
    try std.testing.expectEqual(@as(usize, 0), nodes.items.len);
    try std.testing.expectEqual(@as(u64, 1), hooks.interval_removes);
    try std.testing.expectEqual(@as(u64, 1), hooks.record_releases);
}

test "active graph stream rebuild retains records and rebuilds sink routes" {
    var source = LifecycleTestRecord{ .id = 0, .payload = .{ .ref = 1 } };
    var mapped = LifecycleTestRecord{ .id = 1, .payload = .{ .map = .{ .input = &source } } };

    var stream: LifecycleStream = .{};
    defer stream.deinit(std.testing.allocator);
    stream.signal_text_nodes.append(std.testing.allocator, .{ .signal = .{ .record = &mapped } }) catch @panic("out of memory");
    stream.signal_text_attrs.append(std.testing.allocator, .{ .signal = .{ .record = &mapped } }) catch @panic("out of memory");
    stream.signal_custom_text_attrs.append(std.testing.allocator, .{ .signal = .{ .record = &source } }) catch @panic("out of memory");
    stream.signal_optional_custom_text_attrs.append(std.testing.allocator, .{ .signal = .{ .record = &source } }) catch @panic("out of memory");
    stream.signal_bool_attrs.append(std.testing.allocator, .{ .signal = .{ .record = &source } }) catch @panic("out of memory");
    stream.signal_custom_bool_attrs.append(std.testing.allocator, .{ .signal = .{ .record = &mapped } }) catch @panic("out of memory");
    stream.on_changes.append(std.testing.allocator, .{ .signal = .{ .record = &mapped } }) catch @panic("out of memory");
    stream.whens.append(std.testing.allocator, .{ .condition = .{ .record = &source } }) catch @panic("out of memory");
    stream.eaches.append(std.testing.allocator, .{ .items = .{ .record = &mapped } }) catch @panic("out of memory");
    stream.events.append(std.testing.allocator, .{ .handler = .{ .record = &mapped } }) catch @panic("out of memory");

    var nodes: shared_buffer.List(Node(LifecycleTestRecord)) = .empty;
    defer nodes.deinit(std.testing.allocator);

    var source_routes: RouteTable(u64) = .empty;
    var text_routes: RouteTable(TextSink) = .empty;
    var bool_routes: RouteTable(BoolSink) = .empty;
    var change_routes: RouteTable(ChangeSink) = .empty;
    var structural_routes: RouteTable(StructuralSink) = .empty;
    defer source_routes.deinit(std.testing.allocator);
    defer text_routes.deinit(std.testing.allocator);
    defer bool_routes.deinit(std.testing.allocator);
    defer change_routes.deinit(std.testing.allocator);
    defer structural_routes.deinit(std.testing.allocator);
    defer clearRoutes(std.testing.allocator, &source_routes, &text_routes, &bool_routes, &change_routes, &structural_routes);

    var hooks = LifecycleTestHooks{};
    const records_rebuilt = retainStreamRecords(LifecycleTestRecord, std.testing.allocator, &nodes, &source_routes, 2, &stream, &hooks);
    try std.testing.expectEqual(@as(u64, 2), records_rebuilt);
    try std.testing.expectEqual(@as(usize, 2), nodes.items.len);
    try std.testing.expectEqual(@as(?u64, 0), source.active_graph_id);
    try std.testing.expectEqual(@as(?u64, 1), mapped.active_graph_id);

    rebuildSinkRoutesFromStream(
        LifecycleTestRecord,
        std.testing.allocator,
        nodes.items,
        &text_routes,
        &bool_routes,
        &change_routes,
        &structural_routes,
        &stream,
    );

    try std.testing.expectEqualSlices(TextSink, &.{ .{ .kind = .custom_text_attr, .index = 0 }, .{ .kind = .custom_text_optional_attr, .index = 0 } }, text_routes.items[0].slice());
    try std.testing.expectEqualSlices(TextSink, &.{ .{ .kind = .text_node, .index = 0 }, .{ .kind = .text_attr, .index = 0 } }, text_routes.items[1].slice());
    try std.testing.expectEqualSlices(BoolSink, &.{.{ .kind = .bool_attr, .index = 0 }}, bool_routes.items[0].slice());
    try std.testing.expectEqualSlices(BoolSink, &.{.{ .kind = .custom_bool_attr, .index = 0 }}, bool_routes.items[1].slice());
    try std.testing.expectEqualSlices(ChangeSink, &.{.{ .index = 0 }}, change_routes.items[1].slice());
    try std.testing.expectEqualSlices(StructuralSink, &.{.{ .kind = .when, .index = 0 }}, structural_routes.items[0].slice());
    try std.testing.expectEqualSlices(StructuralSink, &.{.{ .kind = .each, .index = 0 }}, structural_routes.items[1].slice());

    clear(LifecycleTestRecord, std.testing.allocator, &nodes, &hooks);
    try std.testing.expectEqual(@as(?u64, null), source.active_graph_id);
    try std.testing.expectEqual(@as(?u64, null), mapped.active_graph_id);
}
