//! Active signal graph records, routes, and dirty propagation helpers.

const std = @import("std");
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
    return std.ArrayListUnmanaged(std.ArrayListUnmanaged(Route));
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
            items: []Route,
            retired: std.ArrayListUnmanaged(Route) = .empty,
        };

        /// Releases provisional and retired route storage.
        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            for (self.replacements) |*replacement| {
                allocator.free(replacement.items);
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
                routes.items[index] = .{ .items = replacement.items, .capacity = replacement.items.len };
                replacement.items = &.{};
            }
        }
    };
}

/// Builds grouped route-table replacements without mutating active routes.
pub fn prepareRouteAppends(comptime Route: type, allocator: std.mem.Allocator, routes: *const RouteTable(Route), final_count: usize, appends: []const RouteAppend(Route)) (std.mem.Allocator.Error || error{InvalidAppend})!PreparedRouteAppends(Route) {
    const sorted = try allocator.dupe(RouteAppend(Route), appends);
    defer allocator.free(sorted);
    std.mem.sort(RouteAppend(Route), sorted, {}, struct {
        fn lessThan(_: void, left: RouteAppend(Route), right: RouteAppend(Route)) bool {
            return left.route_index < right.route_index;
        }
    }.lessThan);
    var group_count: usize = 0;
    for (sorted, 0..) |entry, index| {
        if (entry.route_index >= final_count) return error.InvalidAppend;
        if (index == 0 or entry.route_index != sorted[index - 1].route_index) group_count += 1;
    }
    const replacements = try allocator.alloc(PreparedRouteAppends(Route).Replacement, group_count);
    errdefer allocator.free(replacements);
    var written: usize = 0;
    errdefer for (replacements[0..written]) |replacement| allocator.free(replacement.items);
    var start: usize = 0;
    while (start < sorted.len) {
        var end = start + 1;
        while (end < sorted.len and sorted[end].route_index == sorted[start].route_index) end += 1;
        const route_index: usize = @intCast(sorted[start].route_index);
        const existing = if (route_index < routes.items.len) routes.items[route_index].items else &.{};
        const merged_len = std.math.add(usize, existing.len, end - start) catch return error.InvalidAppend;
        const merged = try allocator.alloc(Route, merged_len);
        @memcpy(merged[0..existing.len], existing);
        for (sorted[start..end], existing.len..) |entry, index| merged[index] = entry.value;
        replacements[written] = .{ .route_index = @intCast(route_index), .items = merged };
        written += 1;
        start = end;
    }
    return .{ .replacements = replacements };
}

/// Builds sink route replacements against the dense record layout that will
/// exist after a prepared release. Slots without a surviving old record start
/// empty instead of inheriting routes from the old occupant of that dense ID.
pub fn prepareRouteAppendsAfterRelease(comptime Route: type, allocator: std.mem.Allocator, routes: *const RouteTable(Route), original_record_ids: []const usize, final_count: usize, appends: []const RouteAppend(Route)) (std.mem.Allocator.Error || error{InvalidAppend})!PreparedRouteAppends(Route) {
    return prepareRouteAppendsAfterReleaseWithWork(Route, allocator, routes, original_record_ids, final_count, appends, null);
}

fn prepareRouteAppendsAfterReleaseWithWork(comptime Route: type, allocator: std.mem.Allocator, routes: *const RouteTable(Route), original_record_ids: []const usize, final_count: usize, appends: []const RouteAppend(Route), lookup_work: ?*usize) (std.mem.Allocator.Error || error{InvalidAppend})!PreparedRouteAppends(Route) {
    if (original_record_ids.len > final_count) return error.InvalidAppend;
    const sorted = try allocator.dupe(RouteAppend(Route), appends);
    defer allocator.free(sorted);
    std.mem.sort(RouteAppend(Route), sorted, {}, struct {
        fn lessThan(_: void, left: RouteAppend(Route), right: RouteAppend(Route)) bool {
            return left.route_index < right.route_index;
        }
    }.lessThan);
    var group_count: usize = 0;
    for (sorted, 0..) |entry, index| {
        if (entry.route_index >= final_count) return error.InvalidAppend;
        if (index == 0 or entry.route_index != sorted[index - 1].route_index) group_count += 1;
    }
    const replacements = try allocator.alloc(PreparedRouteAppends(Route).Replacement, group_count);
    errdefer allocator.free(replacements);
    var written: usize = 0;
    errdefer for (replacements[0..written]) |replacement| allocator.free(replacement.items);
    var start: usize = 0;
    while (start < sorted.len) {
        var end = start + 1;
        while (end < sorted.len and sorted[end].route_index == sorted[start].route_index) end += 1;
        const route_index: usize = @intCast(sorted[start].route_index);
        if (lookup_work) |counter| counter.* += 1;
        const existing = if (route_index < original_record_ids.len) blk: {
            const old_index = original_record_ids[route_index];
            break :blk if (old_index < routes.items.len) routes.items[old_index].items else &.{};
        } else &.{};
        const merged_len = std.math.add(usize, existing.len, end - start) catch return error.InvalidAppend;
        const merged = try allocator.alloc(Route, merged_len);
        @memcpy(merged[0..existing.len], existing);
        for (sorted[start..end], existing.len..) |entry, index| merged[index] = entry.value;
        replacements[written] = .{ .route_index = @intCast(route_index), .items = merged };
        written += 1;
        start = end;
    }
    return .{ .replacements = replacements };
}

/// Merges new source routes against the post-retirement dense record mapping.
pub fn prepareSourceRouteAppendsAfterRelease(allocator: std.mem.Allocator, routes: *const RouteTable(u64), final_record_ids: []const ?u64, final_source_count: usize, appends: []const RouteAppend(u64)) (std.mem.Allocator.Error || error{InvalidAppend})!PreparedRouteAppends(u64) {
    const sorted = try allocator.dupe(RouteAppend(u64), appends);
    defer allocator.free(sorted);
    std.mem.sort(RouteAppend(u64), sorted, {}, struct {
        fn lessThan(_: void, left: RouteAppend(u64), right: RouteAppend(u64)) bool {
            return left.route_index < right.route_index;
        }
    }.lessThan);
    var group_count: usize = 0;
    for (sorted, 0..) |entry, index| {
        if (entry.route_index >= final_source_count) return error.InvalidAppend;
        if (index == 0 or entry.route_index != sorted[index - 1].route_index) group_count += 1;
    }
    const replacements = try allocator.alloc(PreparedRouteAppends(u64).Replacement, group_count);
    errdefer allocator.free(replacements);
    var written: usize = 0;
    errdefer for (replacements[0..written]) |replacement| allocator.free(replacement.items);
    var start: usize = 0;
    while (start < sorted.len) {
        var end = start + 1;
        while (end < sorted.len and sorted[end].route_index == sorted[start].route_index) end += 1;
        const route_index: usize = @intCast(sorted[start].route_index);
        const existing = if (route_index < routes.items.len) routes.items[route_index].items else &.{};
        var survivor_count: usize = 0;
        for (existing) |old_id| {
            const old_index: usize = @intCast(old_id);
            if (old_index >= final_record_ids.len) return error.InvalidAppend;
            if (final_record_ids[old_index] != null) survivor_count += 1;
        }
        const merged_len = std.math.add(usize, survivor_count, end - start) catch return error.InvalidAppend;
        const merged = try allocator.alloc(u64, merged_len);
        var write: usize = 0;
        for (existing) |old_id| if (final_record_ids[@intCast(old_id)]) |new_id| {
            merged[write] = new_id;
            write += 1;
        };
        for (sorted[start..end]) |entry| {
            merged[write] = entry.value;
            write += 1;
        }
        replacements[written] = .{ .route_index = @intCast(route_index), .items = merged };
        written += 1;
        start = end;
    }
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
    for (routes.items[@intCast(edit.record_id)].items) |sink| {
        if (sink.kind != edit.kind) continue;
        if (editedSinkIndex(TextSinkEdit, edit.record_id, edit.kind, sink.index, prior) == edit.old_index) return true;
    }
    return false;
}

fn containsBoolSinkAfter(routes: *const RouteTable(BoolSink), prior: []const BoolSinkEdit, edit: BoolSinkEdit) bool {
    if (edit.record_id >= routes.items.len) return false;
    for (routes.items[@intCast(edit.record_id)].items) |sink| {
        if (sink.kind != edit.kind) continue;
        if (editedSinkIndex(BoolSinkEdit, edit.record_id, edit.kind, sink.index, prior) == edit.old_index) return true;
    }
    return false;
}

fn containsChangeSinkAfter(routes: *const RouteTable(ChangeSink), prior: []const ChangeSinkEdit, edit: ChangeSinkEdit) bool {
    if (edit.record_id >= routes.items.len) return false;
    for (routes.items[@intCast(edit.record_id)].items) |sink| {
        if (editedSinkIndex(ChangeSinkEdit, edit.record_id, {}, sink.index, prior) == edit.old_index) return true;
    }
    return false;
}

fn containsStructuralSinkAfter(routes: *const RouteTable(StructuralSink), prior: []const StructuralSinkEdit, edit: StructuralSinkEdit) bool {
    if (edit.record_id >= routes.items.len) return false;
    for (routes.items[@intCast(edit.record_id)].items) |sink| {
        if (sink.kind != edit.kind) continue;
        if (editedSinkIndex(StructuralSinkEdit, edit.record_id, edit.kind, sink.index, prior) == edit.old_index) return true;
    }
    return false;
}

fn containsTextSink(routes: *const RouteTable(TextSink), edit: TextSinkEdit) bool {
    if (edit.record_id >= routes.items.len) return false;
    for (routes.items[@intCast(edit.record_id)].items) |sink| if (sink.kind == edit.kind and sink.index == edit.old_index) return true;
    return false;
}
fn containsBoolSink(routes: *const RouteTable(BoolSink), edit: BoolSinkEdit) bool {
    if (edit.record_id >= routes.items.len) return false;
    for (routes.items[@intCast(edit.record_id)].items) |sink| if (sink.kind == edit.kind and sink.index == edit.old_index) return true;
    return false;
}
fn containsChangeSink(routes: *const RouteTable(ChangeSink), edit: ChangeSinkEdit) bool {
    if (edit.record_id >= routes.items.len) return false;
    for (routes.items[@intCast(edit.record_id)].items) |sink| if (sink.index == edit.old_index) return true;
    return false;
}
fn containsStructuralSink(routes: *const RouteTable(StructuralSink), edit: StructuralSinkEdit) bool {
    if (edit.record_id >= routes.items.len) return false;
    for (routes.items[@intCast(edit.record_id)].items) |sink| if (sink.kind == edit.kind and sink.index == edit.old_index) return true;
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
        try std.testing.expectEqualSlices(TextSink, &.{ .{ .kind = .text_node, .index = 0 }, .{ .kind = .text_attr, .index = 9 } }, text_routes.items[0].items);
        try std.testing.expectEqualSlices(BoolSink, &.{ .{ .kind = .bool_attr, .index = 0 }, .{ .kind = .custom_bool_attr, .index = 9 } }, bool_routes.items[0].items);
    }
    counter.configure(1);
    baseline.apply(&text_routes, &bool_routes, &change_routes, &structural_routes);
    try std.testing.expectEqual(@as(usize, 0), counter.attempts);
    try std.testing.expectEqualSlices(TextSink, &.{.{ .kind = .text_attr, .index = 1 }}, text_routes.items[0].items);
    try std.testing.expectEqualSlices(BoolSink, &.{.{ .kind = .custom_bool_attr, .index = 1 }}, bool_routes.items[0].items);
    try std.testing.expectEqualSlices(ChangeSink, &.{.{ .index = 1 }}, change_routes.items[0].items);
    try std.testing.expectEqualSlices(StructuralSink, &.{.{ .kind = .each, .index = 1 }}, structural_routes.items[0].items);
    counter.configure(null);
    baseline.deinit(counter.allocator());
}

pub const DirtyRecordQueue = struct {
    generation: u64 = 0,
    seen_generations: std.ArrayListUnmanaged(u64) = .empty,
    pending_record_ids: std.ArrayListUnmanaged(u64) = .empty,
    ordered_record_ids: std.ArrayListUnmanaged(u64) = .empty,
    rank_counts: std.ArrayListUnmanaged(usize) = .empty,
    rank_offsets: std.ArrayListUnmanaged(usize) = .empty,

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
        source_routes: []const std.ArrayListUnmanaged(u64),
        dirty_source_node_ids: []const u64,
    ) []const u64 {
        var max_rank: u64 = 0;
        self.begin(allocator, nodes.len);

        for (dirty_source_node_ids) |source_node_id| {
            const route_index: usize = @intCast(source_node_id);
            if (route_index >= source_routes.len) continue;

            for (source_routes[route_index].items) |record_id| {
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
                        .select => continue,
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
pub fn appendNode(comptime Record: type, allocator: std.mem.Allocator, nodes: *std.ArrayListUnmanaged(Node(Record)), record: *Record, node_rank: u64) u64 {
    const record_id: u64 = @intCast(nodes.items.len);
    nodes.append(allocator, .{
        .record = record.retain(),
        .rank = node_rank,
    }) catch @panic("out of memory");
    record.active_graph_id = record_id;
    return record_id;
}

/// Appends dependent id using capacity that must already satisfy the caller's transaction contract.
pub fn appendDependentId(comptime Record: type, allocator: std.mem.Allocator, nodes: []Node(Record), input_record_id: u64, dependent_record_id: u64) void {
    signal_graph.appendDependent(Record, allocator, nodes, input_record_id, dependent_record_id) catch |err| switch (err) {
        error.OutOfMemory => @panic("out of memory"),
        error.UnknownNode => @panic("active signal dependent referenced an unknown input record"),
        else => @panic("active signal dependent insertion missed its edge"),
    };
}

/// Removes dependent id and releases the ownership attached to that live entry.
pub fn removeDependentId(comptime Record: type, allocator: std.mem.Allocator, nodes: []Node(Record), input_record_id: u64, dependent_record_id: u64) void {
    signal_graph.removeDependent(Record, allocator, nodes, input_record_id, dependent_record_id) catch |err| switch (err) {
        error.OutOfMemory => @panic("out of memory"),
        error.UnknownNode => @panic("active signal dependent removal referenced an unknown input record"),
        else => @panic("active signal dependent removal missed its edge"),
    };
}

/// Replaces dependent id while releasing displaced ownership exactly once.
pub fn replaceDependentId(comptime Record: type, nodes: []Node(Record), input_record_id: u64, old_dependent_id: u64, new_dependent_id: u64) void {
    signal_graph.replaceDependent(Record, nodes, input_record_id, old_dependent_id, new_dependent_id) catch |err| switch (err) {
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
pub fn ensureSourceRoute(allocator: std.mem.Allocator, source_routes: *RouteTable(u64), source_node_count: usize, source_node_id: u64) *std.ArrayListUnmanaged(u64) {
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
    if (!containsU64(route.items, record_id)) {
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
    for (route.items, 0..) |existing_id, index| {
        if (existing_id != record_id) continue;
        _ = route.swapRemove(index);
        return;
    }
    @panic("active source signal route removal missed its record");
}

/// Replaces source route id while releasing displaced ownership exactly once.
pub fn replaceSourceRouteId(source_routes: *RouteTable(u64), source_node_id: u64, old_record_id: u64, new_record_id: u64) void {
    if (source_node_id >= source_routes.items.len) @panic("active source signal route rewrite referenced an unknown source node");
    const route = source_routes.items[@intCast(source_node_id)].items;
    for (route) |*existing_id| {
        if (existing_id.* != old_record_id) continue;
        existing_id.* = new_record_id;
        return;
    }
    @panic("active source signal route rewrite missed its record");
}

/// Ensures text route capacity or state before publication can begin.
pub fn ensureTextRoute(allocator: std.mem.Allocator, text_routes: *RouteTable(TextSink), graph_len: usize, record_id: u64) *std.ArrayListUnmanaged(TextSink) {
    return ensureSinkRoute(TextSink, allocator, text_routes, graph_len, record_id, "active text signal route referenced an unknown signal record");
}

/// Ensures bool route capacity or state before publication can begin.
pub fn ensureBoolRoute(allocator: std.mem.Allocator, bool_routes: *RouteTable(BoolSink), graph_len: usize, record_id: u64) *std.ArrayListUnmanaged(BoolSink) {
    return ensureSinkRoute(BoolSink, allocator, bool_routes, graph_len, record_id, "active bool signal route referenced an unknown signal record");
}

/// Ensures change route capacity or state before publication can begin.
pub fn ensureChangeRoute(allocator: std.mem.Allocator, change_routes: *RouteTable(ChangeSink), graph_len: usize, record_id: u64) *std.ArrayListUnmanaged(ChangeSink) {
    return ensureSinkRoute(ChangeSink, allocator, change_routes, graph_len, record_id, "active change signal route referenced an unknown signal record");
}

/// Ensures structural route capacity or state before publication can begin.
pub fn ensureStructuralRoute(allocator: std.mem.Allocator, structural_routes: *RouteTable(StructuralSink), graph_len: usize, record_id: u64) *std.ArrayListUnmanaged(StructuralSink) {
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
    for (route.items, 0..) |sink, sink_index| {
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
    for (text_routes.items[route_index].items) |*sink| {
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
    for (route.items, 0..) |sink, sink_index| {
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
    for (bool_routes.items[route_index].items) |*sink| {
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
    for (route.items, 0..) |sink, sink_index| {
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
    for (change_routes.items[route_index].items) |*sink| {
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
    for (route.items, 0..) |sink, sink_index| {
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
    for (structural_routes.items[route_index].items) |*sink| {
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

/// Appends input records using capacity that must already satisfy the caller's transaction contract.
pub fn appendInputRecords(comptime Record: type, allocator: std.mem.Allocator, records: *std.ArrayListUnmanaged(*Record), record: *Record) void {
    switch (record.payload) {
        .ref, .const_value, .task_source, .interval_source, .entropy_seed_source, .location_source, .online_source, .visibility_source, .storage_source, .row_source => {},
        .map => |payload| appendUniqueInputRecord(Record, allocator, records, payload.input),
        .select => |payload| appendUniqueInputRecord(Record, allocator, records, payload.input),
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
    nodes: *std.ArrayListUnmanaged(Node(Record)),
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
        .ref, .const_value, .task_source, .interval_source, .entropy_seed_source, .location_source, .online_source, .visibility_source, .storage_source, .row_source => {},
        .map => |payload| {
            records_rebuilt += retainRecord(Record, allocator, nodes, source_routes, source_node_count, payload.input, hooks);
            const input_id = requireRecordId(Record, nodes.items, payload.input);
            node_rank = nodes.items[@intCast(input_id)].rank + 1;
        },
        .select => |payload| {
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
        .const_value, .task_source, .entropy_seed_source, .location_source, .online_source, .visibility_source, .storage_source => {},
        .row_source => hooks.ensureRowSource(record),
        .interval_source => |payload| hooks.ensureInterval(record.token().?, payload.period_ms),
        .map => |payload| appendDependentId(Record, allocator, nodes.items, requireRecordId(Record, nodes.items, payload.input), record_id),
        .select => |payload| {
            appendDependentId(Record, allocator, nodes.items, requireRecordId(Record, nodes.items, payload.input), record_id);
            hooks.ensureSelector(payload.input, payload.key, record);
        },
        .map2 => |payload| {
            appendDependentId(Record, allocator, nodes.items, requireRecordId(Record, nodes.items, payload.left), record_id);
            if (payload.right != payload.left) {
                appendDependentId(Record, allocator, nodes.items, requireRecordId(Record, nodes.items, payload.right), record_id);
            }
        },
        .combine => |payload| {
            for (payload.children, 0..) |child, index| {
                if (recordSliceContains(Record, payload.children[0..index], child)) continue;
                appendDependentId(Record, allocator, nodes.items, requireRecordId(Record, nodes.items, child), record_id);
            }
        },
    }

    return records_rebuilt;
}

pub const PreparedReleaseStep = struct {
    record_id: u64,
    removal_index: u64,
    moved_record_id: ?u64,
};

pub const PreparedAdjacencyReplacement = struct {
    record_id: u64,
    dependents: []u64,
};

/// Owns a read-only simulation of recursive active-record release and dense remaps.
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
        final_record_ids: []?u64,
        /// Direct inverse for every surviving dense id: final id to the
        /// committed record index that occupied it before this release.
        original_record_ids: []usize,
        /// Use-count decrements owed to survivors whose count drops but never
        /// reaches zero once the same transaction's retains are netted in.
        survivor_use_decrements: []ExistingUseIncrement,
        adjacency: []PreparedAdjacencyReplacement,
        retired_adjacency: [][]u64,
        retired_nodes: []Node(Record),
        retired_text_routes: []std.ArrayListUnmanaged(TextSink),
        retired_bool_routes: []std.ArrayListUnmanaged(BoolSink),
        retired_change_routes: []std.ArrayListUnmanaged(ChangeSink),
        retired_structural_routes: []std.ArrayListUnmanaged(StructuralSink),
        phase: Phase = .prepared,

        /// Releases preparation storage without changing graph state.
        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.records);
            allocator.free(self.steps);
            allocator.free(self.final_record_ids);
            allocator.free(self.original_record_ids);
            allocator.free(self.survivor_use_decrements);
            switch (self.phase) {
                .prepared => for (self.adjacency) |replacement| allocator.free(replacement.dependents),
                .adjacency_committed, .dense_committed, .retired_released => for (self.retired_adjacency) |items| allocator.free(items),
            }
            allocator.free(self.adjacency);
            allocator.free(self.retired_adjacency);
            if (self.phase == .dense_committed) @panic("committed graph retirement was not finalized");
            allocator.free(self.retired_nodes);
            allocator.free(self.retired_text_routes);
            allocator.free(self.retired_bool_routes);
            allocator.free(self.retired_change_routes);
            allocator.free(self.retired_structural_routes);
            self.* = undefined;
        }

        /// Swaps every prepared survivor/remap adjacency slice without allocation.
        pub fn applyAdjacency(self: *@This(), nodes: []Node(Record)) void {
            if (self.phase != .prepared) @panic("release closure adjacency was already committed");
            for (self.adjacency, self.retired_adjacency) |*replacement, *retired| {
                const index: usize = @intCast(replacement.record_id);
                if (index >= nodes.len) @panic("prepared adjacency referenced an unknown record");
                retired.* = nodes[index].dependents;
                nodes[index].dependents = replacement.dependents;
                replacement.dependents = &.{};
            }
            self.phase = .adjacency_committed;
        }

        /// Removes prepared dense nodes and parallel route slots without allocation.
        /// Descriptor sink routes must already have been removed from retiring records.
        pub fn applyDense(self: *@This(), nodes: *std.ArrayListUnmanaged(Node(Record)), source_routes: *RouteTable(u64), text_routes: *RouteTable(TextSink), bool_routes: *RouteTable(BoolSink), change_routes: *RouteTable(ChangeSink), structural_routes: *RouteTable(StructuralSink)) void {
            if (self.phase != .adjacency_committed) @panic("dense graph retirement commit order was invalid");
            for (self.survivor_use_decrements) |decrement| {
                const record = nodes.items[@intCast(decrement.record_id)].record;
                // A survivor kept alive only by this transaction's retains
                // may touch zero here; the graph append publishing in the
                // same commit restores its count before anything observes it.
                if (record.active_use_count < decrement.count) @panic("prepared survivor use decrement underflowed a live record");
                record.active_use_count -= decrement.count;
            }
            for (source_routes.items) |*route| {
                var write: usize = 0;
                for (route.items) |old_id| {
                    const next_id = self.final_record_ids[@intCast(old_id)] orelse continue;
                    route.items[write] = next_id;
                    write += 1;
                }
                route.items.len = write;
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

        fn retireRouteSlot(comptime Route: type, routes: *RouteTable(Route), retired: []std.ArrayListUnmanaged(Route), removal_index: usize, last_index: usize, step_index: usize) void {
            if (removal_index >= routes.items.len) return;
            if (routes.items[removal_index].items.len != 0) @panic("prepared graph removed a record with live sink routes");
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
        /// `hooks`, and hands the record itself to `hooks.releaseRecord`.
        pub fn releaseRetired(self: *@This(), allocator: std.mem.Allocator, hooks: anytype) void {
            if (self.phase != .dense_committed) @panic("retired graph ownership release order was invalid");
            for (self.retired_nodes) |node| {
                allocator.free(node.dependents);
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

pub const SurvivorAdjacencyAppend = struct {
    record_id: u64,
    dependents: []u64,
};

/// Owns read-only topology and use-count decisions for replacement records.
pub fn PreparedGraphAppend(comptime Record: type) type {
    return struct {
        const Phase = enum { prepared, committed };

        records: []*Record,
        record_ids: []u64,
        ranks: []u64,
        use_counts: []usize,
        existing_use_increments: []ExistingUseIncrement,
        survivor_adjacency: []SurvivorAdjacencyAppend,
        new_nodes: []Node(Record),
        retired_adjacency: [][]u64,
        final_existing_record_ids: []?u64,
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
                    .select => |payload| hooks.registerSelector(payload.input, payload.key, node.record),
                    .row_source => hooks.registerRowSource(node.record),
                    else => {},
                }
            }
        }

        /// Reserves the dense node destination before any graph mutation.
        pub fn reservePublication(self: *const @This(), allocator: std.mem.Allocator, nodes: *std.ArrayListUnmanaged(Node(Record))) (std.mem.Allocator.Error || error{InvalidAppend})!void {
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
        pub fn plannedRecordId(self: *const @This(), original_nodes: []const Node(Record), record: *const Record) ?u64 {
            if (record.active_graph_id) |original_id| {
                const index: usize = @intCast(original_id);
                if (index >= original_nodes.len or original_nodes[index].record != record) return null;
                return self.final_existing_record_ids[index];
            }
            for (self.records, self.record_ids) |planned, id| if (planned == record) return id;
            return null;
        }

        /// Returns the exact dense graph length after retirement and append.
        pub fn finalGraphCount(self: *const @This()) usize {
            return self.survivor_count + self.new_nodes.len;
        }

        /// Publishes prepared nodes, edges, ids, and use counts without allocating.
        pub fn commitNodes(self: *@This(), nodes: *std.ArrayListUnmanaged(Node(Record))) void {
            if (self.phase != .prepared or nodes.items.len != self.survivor_count) @panic("replacement graph publication violated its prepared snapshot");
            for (self.existing_use_increments) |increment| {
                const record = nodes.items[@intCast(increment.record_id)].record;
                record.active_use_count += increment.count;
            }
            for (self.survivor_adjacency, self.retired_adjacency) |*replacement, *retired| {
                const index: usize = @intCast(replacement.record_id);
                retired.* = nodes.items[index].dependents;
                nodes.items[index].dependents = replacement.dependents;
                replacement.dependents = &.{};
            }
            for (self.new_nodes, self.record_ids, self.use_counts) |*node, id, uses| {
                _ = node.record.retain();
                node.record.active_graph_id = id;
                node.record.active_use_count = uses;
                nodes.appendAssumeCapacity(node.*);
                node.dependents = &.{};
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
            for (self.survivor_adjacency) |replacement| allocator.free(replacement.dependents);
            allocator.free(self.survivor_adjacency);
            for (self.new_nodes) |node| allocator.free(node.dependents);
            allocator.free(self.new_nodes);
            for (self.retired_adjacency) |retired| allocator.free(retired);
            allocator.free(self.retired_adjacency);
            allocator.free(self.final_existing_record_ids);
            self.* = undefined;
        }
    };
}

/// Resolves survivor records and topologically enumerates only missing records.
pub fn prepareGraphAppend(comptime Record: type, allocator: std.mem.Allocator, nodes: []const Node(Record), final_record_ids: []const ?u64, roots: []const *Record) (std.mem.Allocator.Error || error{InvalidAppend})!PreparedGraphAppend(Record) {
    return prepareGraphAppendWithWork(Record, allocator, nodes, final_record_ids, roots, null);
}

fn prepareGraphAppendWithWork(comptime Record: type, allocator: std.mem.Allocator, nodes: []const Node(Record), final_record_ids: []const ?u64, roots: []const *Record, lookup_work: ?*usize) (std.mem.Allocator.Error || error{InvalidAppend})!PreparedGraphAppend(Record) {
    if (lookup_work) |work| work.* = 0;
    if (final_record_ids.len != nodes.len) return error.InvalidAppend;
    var survivor_count: usize = 0;
    for (final_record_ids) |final_id| {
        if (final_id) |id| {
            const next = std.math.add(usize, @intCast(id), 1) catch return error.InvalidAppend;
            survivor_count = @max(survivor_count, next);
        }
    }
    const existing_counts = try allocator.alloc(usize, nodes.len);
    defer allocator.free(existing_counts);
    @memset(existing_counts, 0);
    var records: std.ArrayListUnmanaged(*Record) = .empty;
    errdefer records.deinit(allocator);
    var ranks: std.ArrayListUnmanaged(u64) = .empty;
    errdefer ranks.deinit(allocator);
    var uses: std.ArrayListUnmanaged(usize) = .empty;
    errdefer uses.deinit(allocator);
    var new_record_indexes: std.AutoHashMapUnmanaged(*Record, usize) = .empty;
    defer new_record_indexes.deinit(allocator);

    const Builder = struct {
        fn retain(record: *Record, prepare_allocator: std.mem.Allocator, graph_nodes: []const Node(Record), mapping: []const ?u64, survivor_len: usize, existing: []usize, new_records: *std.ArrayListUnmanaged(*Record), new_ranks: *std.ArrayListUnmanaged(u64), new_uses: *std.ArrayListUnmanaged(usize), indexes: *std.AutoHashMapUnmanaged(*Record, usize), work: ?*usize) (std.mem.Allocator.Error || error{InvalidAppend})!struct { id: u64, rank: u64 } {
            if (record.active_graph_id) |original_id| {
                const index: usize = @intCast(original_id);
                if (index >= graph_nodes.len or graph_nodes[index].record != record) return error.InvalidAppend;
                const final_id = mapping[index] orelse return error.InvalidAppend;
                existing[index] = std.math.add(usize, existing[index], 1) catch return error.InvalidAppend;
                return .{ .id = final_id, .rank = graph_nodes[index].rank };
            }
            if (work) |count| count.* += 1;
            if (indexes.get(record)) |index| {
                new_uses.items[index] = std.math.add(usize, new_uses.items[index], 1) catch return error.InvalidAppend;
                return .{ .id = @intCast(survivor_len + index), .rank = new_ranks.items[index] };
            }
            var new_rank: u64 = 0;
            switch (record.payload) {
                .map => |payload| new_rank = std.math.add(u64, (try retain(payload.input, prepare_allocator, graph_nodes, mapping, survivor_len, existing, new_records, new_ranks, new_uses, indexes, work)).rank, 1) catch return error.InvalidAppend,
                .select => |payload| new_rank = std.math.add(u64, (try retain(payload.input, prepare_allocator, graph_nodes, mapping, survivor_len, existing, new_records, new_ranks, new_uses, indexes, work)).rank, 1) catch return error.InvalidAppend,
                .map2 => |payload| {
                    const left = try retain(payload.left, prepare_allocator, graph_nodes, mapping, survivor_len, existing, new_records, new_ranks, new_uses, indexes, work);
                    const right = if (payload.right == payload.left) left else try retain(payload.right, prepare_allocator, graph_nodes, mapping, survivor_len, existing, new_records, new_ranks, new_uses, indexes, work);
                    new_rank = std.math.add(u64, @max(left.rank, right.rank), 1) catch return error.InvalidAppend;
                },
                .combine => |payload| for (payload.children, 0..) |child, child_index| {
                    if (recordSliceContains(Record, payload.children[0..child_index], child)) continue;
                    const child_rank = std.math.add(u64, (try retain(child, prepare_allocator, graph_nodes, mapping, survivor_len, existing, new_records, new_ranks, new_uses, indexes, work)).rank, 1) catch return error.InvalidAppend;
                    new_rank = @max(new_rank, child_rank);
                },
                .ref, .const_value, .task_source, .interval_source, .entropy_seed_source, .location_source, .online_source, .visibility_source, .storage_source, .row_source => {},
            }
            const id: u64 = @intCast(std.math.add(usize, survivor_len, new_records.items.len) catch return error.InvalidAppend);
            try new_records.append(prepare_allocator, record);
            try new_ranks.append(prepare_allocator, new_rank);
            try new_uses.append(prepare_allocator, 1);
            try indexes.put(prepare_allocator, record, new_records.items.len - 1);
            return .{ .id = id, .rank = new_rank };
        }
    };
    for (roots) |root| _ = try Builder.retain(root, allocator, nodes, final_record_ids, survivor_count, existing_counts, &records, &ranks, &uses, &new_record_indexes, lookup_work);

    var increments: std.ArrayListUnmanaged(ExistingUseIncrement) = .empty;
    errdefer increments.deinit(allocator);
    try increments.ensureTotalCapacity(allocator, nodes.len);
    for (existing_counts, final_record_ids, nodes) |count, final_id, node| if (count != 0) {
        _ = std.math.add(usize, node.record.active_use_count, count) catch return error.InvalidAppend;
        increments.appendAssumeCapacity(.{ .record_id = final_id orelse return error.InvalidAppend, .count = count });
    };
    const owned_records = try records.toOwnedSlice(allocator);
    errdefer allocator.free(owned_records);
    const record_ids = try allocator.alloc(u64, owned_records.len);
    errdefer allocator.free(record_ids);
    for (record_ids, 0..) |*id, index| id.* = @intCast(std.math.add(usize, survivor_count, index) catch return error.InvalidAppend);
    const owned_ranks = try ranks.toOwnedSlice(allocator);
    errdefer allocator.free(owned_ranks);
    const owned_uses = try uses.toOwnedSlice(allocator);
    errdefer allocator.free(owned_uses);
    const owned_increments = try increments.toOwnedSlice(allocator);
    errdefer allocator.free(owned_increments);
    const total_count = std.math.add(usize, survivor_count, owned_records.len) catch return error.InvalidAppend;
    const adjacency_lists = try allocator.alloc(std.ArrayListUnmanaged(u64), total_count);
    defer allocator.free(adjacency_lists);
    @memset(adjacency_lists, .empty);
    const adjacency_touched = try allocator.alloc(bool, survivor_count);
    defer allocator.free(adjacency_touched);
    @memset(adjacency_touched, false);
    const final_to_original = try allocator.alloc(usize, survivor_count);
    defer allocator.free(final_to_original);
    @memset(final_to_original, std.math.maxInt(usize));
    for (final_record_ids, 0..) |final_id, original_index| if (final_id) |id| {
        const final_index: usize = @intCast(id);
        if (final_index >= final_to_original.len or final_to_original[final_index] != std.math.maxInt(usize)) return error.InvalidAppend;
        final_to_original[final_index] = original_index;
    };
    errdefer for (adjacency_lists) |*list| list.deinit(allocator);
    const EdgeBuilder = struct {
        fn resolvedRecordId(target: *Record, original_nodes: []const Node(Record), mapping: []const ?u64, survivor_len: usize, appended: *const std.AutoHashMapUnmanaged(*Record, usize), work: ?*usize) error{InvalidAppend}!u64 {
            if (target.active_graph_id) |original_id| {
                const index: usize = @intCast(original_id);
                if (index >= original_nodes.len or original_nodes[index].record != target) return error.InvalidAppend;
                return mapping[index] orelse return error.InvalidAppend;
            }
            if (work) |count| count.* += 1;
            const index = appended.get(target) orelse return error.InvalidAppend;
            return @intCast(std.math.add(usize, survivor_len, index) catch return error.InvalidAppend);
        }

        fn append(input: *Record, dependent_id: u64, prepare_allocator: std.mem.Allocator, original_nodes: []const Node(Record), mapping: []const ?u64, survivor_len: usize, appended: *const std.AutoHashMapUnmanaged(*Record, usize), inverse: []const usize, lists: []std.ArrayListUnmanaged(u64), touched: []bool, work: ?*usize) (std.mem.Allocator.Error || error{InvalidAppend})!void {
            const input_id = try resolvedRecordId(input, original_nodes, mapping, survivor_len, appended, work);
            const input_index: usize = @intCast(input_id);
            if (input_index >= lists.len) return error.InvalidAppend;
            if (input_index < survivor_len and !touched[input_index]) {
                const original_index = inverse[input_index];
                if (original_index == std.math.maxInt(usize) or original_index >= original_nodes.len) return error.InvalidAppend;
                const source = original_nodes[original_index].dependents;
                const capacity = std.math.add(usize, source.len, 1) catch return error.InvalidAppend;
                try lists[input_index].ensureTotalCapacity(prepare_allocator, capacity);
                for (source) |original_dependent| {
                    const original_dependent_index: usize = @intCast(original_dependent);
                    if (original_dependent_index >= mapping.len) return error.InvalidAppend;
                    if (mapping[original_dependent_index]) |final_dependent| lists[input_index].appendAssumeCapacity(final_dependent);
                }
                touched[input_index] = true;
            }
            if (!containsU64(lists[input_index].items, dependent_id)) try lists[input_index].append(prepare_allocator, dependent_id);
        }
    };
    for (owned_records, record_ids) |record, dependent_id| switch (record.payload) {
        .map => |payload| try EdgeBuilder.append(payload.input, dependent_id, allocator, nodes, final_record_ids, survivor_count, &new_record_indexes, final_to_original, adjacency_lists, adjacency_touched, lookup_work),
        .select => |payload| try EdgeBuilder.append(payload.input, dependent_id, allocator, nodes, final_record_ids, survivor_count, &new_record_indexes, final_to_original, adjacency_lists, adjacency_touched, lookup_work),
        .map2 => |payload| {
            try EdgeBuilder.append(payload.left, dependent_id, allocator, nodes, final_record_ids, survivor_count, &new_record_indexes, final_to_original, adjacency_lists, adjacency_touched, lookup_work);
            if (payload.right != payload.left) try EdgeBuilder.append(payload.right, dependent_id, allocator, nodes, final_record_ids, survivor_count, &new_record_indexes, final_to_original, adjacency_lists, adjacency_touched, lookup_work);
        },
        .combine => |payload| for (payload.children, 0..) |child, child_index| {
            if (!recordSliceContains(Record, payload.children[0..child_index], child)) try EdgeBuilder.append(child, dependent_id, allocator, nodes, final_record_ids, survivor_count, &new_record_indexes, final_to_original, adjacency_lists, adjacency_touched, lookup_work);
        },
        .ref, .const_value, .task_source, .interval_source, .entropy_seed_source, .location_source, .online_source, .visibility_source, .storage_source, .row_source => {},
    };
    var survivor_replacement_count: usize = 0;
    for (adjacency_touched) |touched| if (touched) {
        survivor_replacement_count += 1;
    };
    var survivor_replacements = try allocator.alloc(SurvivorAdjacencyAppend, survivor_replacement_count);
    errdefer allocator.free(survivor_replacements);
    var survivor_write: usize = 0;
    for (adjacency_touched, 0..) |touched, id| if (touched) {
        survivor_replacements[survivor_write] = .{ .record_id = @intCast(id), .dependents = try adjacency_lists[id].toOwnedSlice(allocator) };
        survivor_write += 1;
    };
    errdefer for (survivor_replacements[0..survivor_write]) |replacement| allocator.free(replacement.dependents);
    const new_nodes = try allocator.alloc(Node(Record), owned_records.len);
    errdefer allocator.free(new_nodes);
    var new_node_write: usize = 0;
    errdefer for (new_nodes[0..new_node_write]) |node| allocator.free(node.dependents);
    for (new_nodes, owned_records, owned_ranks, 0..) |*node, record, prepared_rank, index| {
        node.* = .{ .record = record, .rank = prepared_rank, .dependents = try adjacency_lists[survivor_count + index].toOwnedSlice(allocator) };
        new_node_write += 1;
    }
    const retired_adjacency = try allocator.alloc([]u64, survivor_replacements.len);
    errdefer allocator.free(retired_adjacency);
    @memset(retired_adjacency, &.{});
    const owned_final_existing_ids = try allocator.dupe(?u64, final_record_ids);
    errdefer allocator.free(owned_final_existing_ids);
    return .{
        .records = owned_records,
        .record_ids = record_ids,
        .ranks = owned_ranks,
        .use_counts = owned_uses,
        .existing_use_increments = owned_increments,
        .survivor_adjacency = survivor_replacements,
        .new_nodes = new_nodes,
        .retired_adjacency = retired_adjacency,
        .final_existing_record_ids = owned_final_existing_ids,
        .survivor_count = survivor_count,
    };
}

/// Counts, per committed graph record, how many times the given roots retain
/// it: an existing record contributes one use per referencing edge and is not
/// entered, while a record outside the graph is walked once through its inputs.
/// This is the same walk `prepareGraphAppend` performs, so a release closure
/// prepared with the replacement roots nets the retains the append will add.
fn countExistingRetainsWithWork(comptime Record: type, allocator: std.mem.Allocator, nodes: []const Node(Record), roots: []const *Record, existing: []usize, lookup_work: ?*usize) (std.mem.Allocator.Error || error{InvalidRelease})!void {
    var visited: std.AutoHashMapUnmanaged(*Record, void) = .empty;
    defer visited.deinit(allocator);
    const root_capacity = std.math.cast(u32, roots.len) orelse return error.InvalidRelease;
    try visited.ensureUnusedCapacity(allocator, root_capacity);
    const Walker = struct {
        fn walk(record: *Record, walk_allocator: std.mem.Allocator, graph_nodes: []const Node(Record), counts: []usize, seen: *std.AutoHashMapUnmanaged(*Record, void), work: ?*usize) (std.mem.Allocator.Error || error{InvalidRelease})!void {
            if (record.active_graph_id) |original_id| {
                const index: usize = @intCast(original_id);
                if (index >= graph_nodes.len or graph_nodes[index].record != record) return error.InvalidRelease;
                counts[index] = std.math.add(usize, counts[index], 1) catch return error.InvalidRelease;
                return;
            }
            if (work) |counter| counter.* += 1;
            const entry = try seen.getOrPut(walk_allocator, record);
            if (entry.found_existing) return;
            switch (record.payload) {
                .map => |payload| try walk(payload.input, walk_allocator, graph_nodes, counts, seen, work),
                .select => |payload| try walk(payload.input, walk_allocator, graph_nodes, counts, seen, work),
                .map2 => |payload| {
                    try walk(payload.left, walk_allocator, graph_nodes, counts, seen, work);
                    if (payload.right != payload.left) try walk(payload.right, walk_allocator, graph_nodes, counts, seen, work);
                },
                .combine => |payload| for (payload.children, 0..) |child, child_index| {
                    if (recordSliceContains(Record, payload.children[0..child_index], child)) continue;
                    try walk(child, walk_allocator, graph_nodes, counts, seen, work);
                },
                .ref, .const_value, .task_source, .interval_source, .entropy_seed_source, .location_source, .online_source, .visibility_source, .storage_source, .row_source => {},
            }
        }
    };
    for (roots) |root| try Walker.walk(root, allocator, nodes, existing, &visited, lookup_work);
}

fn countExistingRetains(comptime Record: type, allocator: std.mem.Allocator, nodes: []const Node(Record), roots: []const *Record, existing: []usize) (std.mem.Allocator.Error || error{InvalidRelease})!void {
    return countExistingRetainsWithWork(Record, allocator, nodes, roots, existing, null);
}

/// Simulates descriptor-root releases, recursive zero-use inputs, and dense
/// swap-remaps without mutating graph records or route state.
///
/// `retained_roots` are the records the same transaction will retain through
/// `prepareGraphAppend`. Their retains are netted against the releases first,
/// so a committed record that one descriptor drops while another picks it up
/// survives with its dense id instead of being retired and re-appended. Every
/// survivor whose count still falls is recorded and decremented at `applyDense`.
pub fn prepareReleaseClosure(comptime Record: type, allocator: std.mem.Allocator, nodes: []const Node(Record), roots: []const *Record, retained_roots: []const *Record) (std.mem.Allocator.Error || error{InvalidRelease})!PreparedReleaseClosure(Record) {
    const counts = try allocator.alloc(usize, nodes.len);
    defer allocator.free(counts);
    const scheduled = try allocator.alloc(bool, nodes.len);
    defer allocator.free(scheduled);
    @memset(scheduled, false);
    const retained = try allocator.alloc(usize, nodes.len);
    defer allocator.free(retained);
    @memset(retained, 0);
    try countExistingRetains(Record, allocator, nodes, retained_roots, retained);
    for (nodes, retained, 0..) |node, retains, index| {
        if (node.record.active_graph_id != @as(u64, @intCast(index))) return error.InvalidRelease;
        counts[index] = std.math.add(usize, node.record.active_use_count, retains) catch return error.InvalidRelease;
    }

    var records: std.ArrayListUnmanaged(*Record) = .empty;
    errdefer records.deinit(allocator);
    try records.ensureTotalCapacity(allocator, nodes.len);
    const Simulator = struct {
        fn decrement(record: *Record, graph_nodes: []const Node(Record), simulated_counts: []usize, is_scheduled: []bool, output: *std.ArrayListUnmanaged(*Record)) error{InvalidRelease}!void {
            const record_id = record.active_graph_id orelse return error.InvalidRelease;
            const index: usize = @intCast(record_id);
            if (index >= graph_nodes.len or graph_nodes[index].record != record or simulated_counts[index] == 0) return error.InvalidRelease;
            simulated_counts[index] -= 1;
            if (simulated_counts[index] != 0) return;
            if (is_scheduled[index]) return error.InvalidRelease;
            is_scheduled[index] = true;
            output.appendAssumeCapacity(record);
            switch (record.payload) {
                .map => |payload| try decrement(payload.input, graph_nodes, simulated_counts, is_scheduled, output),
                .select => |payload| try decrement(payload.input, graph_nodes, simulated_counts, is_scheduled, output),
                .map2 => |payload| {
                    try decrement(payload.left, graph_nodes, simulated_counts, is_scheduled, output);
                    if (payload.right != payload.left) try decrement(payload.right, graph_nodes, simulated_counts, is_scheduled, output);
                },
                .combine => |payload| {
                    for (payload.children, 0..) |child, child_index| {
                        if (recordSliceContains(Record, payload.children[0..child_index], child)) continue;
                        try decrement(child, graph_nodes, simulated_counts, is_scheduled, output);
                    }
                },
                .ref, .const_value, .task_source, .interval_source, .entropy_seed_source, .location_source, .online_source, .visibility_source, .storage_source, .row_source => {},
            }
        }
    };
    for (roots) |root| try Simulator.decrement(root, nodes, counts, scheduled, &records);

    var decrement_count: usize = 0;
    for (nodes, retained, counts) |node, retains, remaining| {
        if (remaining != 0 and node.record.active_use_count + retains != remaining) decrement_count += 1;
    }
    const survivor_use_decrements = try allocator.alloc(ExistingUseIncrement, decrement_count);
    errdefer allocator.free(survivor_use_decrements);
    var decrement_write: usize = 0;
    for (nodes, retained, counts, 0..) |node, retains, remaining, index| {
        if (remaining == 0 or node.record.active_use_count + retains == remaining) continue;
        survivor_use_decrements[decrement_write] = .{ .record_id = @intCast(index), .count = node.record.active_use_count + retains - remaining };
        decrement_write += 1;
    }

    const slots = try allocator.alloc(u64, nodes.len);
    defer allocator.free(slots);
    const positions = try allocator.alloc(usize, nodes.len);
    defer allocator.free(positions);
    for (slots, positions, 0..) |*slot, *position, index| {
        slot.* = @intCast(index);
        position.* = index;
    }
    const steps = try allocator.alloc(PreparedReleaseStep, records.items.len);
    errdefer allocator.free(steps);
    var live_len = nodes.len;
    for (records.items, steps) |record, *step| {
        const original_id = record.active_graph_id.?;
        const removal_index = positions[@intCast(original_id)];
        const last_index = live_len - 1;
        const moved_original_id = slots[last_index];
        step.* = .{
            .record_id = original_id,
            .removal_index = @intCast(removal_index),
            .moved_record_id = if (removal_index == last_index) null else moved_original_id,
        };
        if (removal_index != last_index) {
            slots[removal_index] = moved_original_id;
            positions[@intCast(moved_original_id)] = removal_index;
        }
        live_len = last_index;
    }
    const final_record_ids = try allocator.alloc(?u64, nodes.len);
    errdefer allocator.free(final_record_ids);
    @memset(final_record_ids, null);
    for (slots[0..live_len], 0..) |original_id, final_id| final_record_ids[@intCast(original_id)] = @intCast(final_id);
    const original_record_ids = try allocator.alloc(usize, live_len);
    errdefer allocator.free(original_record_ids);
    for (original_record_ids, slots[0..live_len]) |*original, slot| original.* = @intCast(slot);
    var adjacency_count: usize = 0;
    for (nodes, 0..) |node, original_id| {
        var next_len: usize = 0;
        var changed = false;
        for (node.dependents) |dependent_id| {
            const final_id = final_record_ids[@intCast(dependent_id)] orelse {
                changed = true;
                continue;
            };
            if (final_id != dependent_id) changed = true;
            next_len += 1;
        }
        if (changed or next_len != node.dependents.len or final_record_ids[original_id] == null and node.dependents.len != 0) adjacency_count += 1;
    }
    const adjacency = try allocator.alloc(PreparedAdjacencyReplacement, adjacency_count);
    errdefer allocator.free(adjacency);
    const retired_adjacency = try allocator.alloc([]u64, adjacency_count);
    errdefer allocator.free(retired_adjacency);
    @memset(retired_adjacency, &.{});
    const retired_nodes = try allocator.alloc(Node(Record), records.items.len);
    errdefer allocator.free(retired_nodes);
    const retired_text_routes = try allocator.alloc(std.ArrayListUnmanaged(TextSink), records.items.len);
    errdefer allocator.free(retired_text_routes);
    @memset(retired_text_routes, .empty);
    const retired_bool_routes = try allocator.alloc(std.ArrayListUnmanaged(BoolSink), records.items.len);
    errdefer allocator.free(retired_bool_routes);
    @memset(retired_bool_routes, .empty);
    const retired_change_routes = try allocator.alloc(std.ArrayListUnmanaged(ChangeSink), records.items.len);
    errdefer allocator.free(retired_change_routes);
    @memset(retired_change_routes, .empty);
    const retired_structural_routes = try allocator.alloc(std.ArrayListUnmanaged(StructuralSink), records.items.len);
    errdefer allocator.free(retired_structural_routes);
    @memset(retired_structural_routes, .empty);
    var adjacency_write: usize = 0;
    errdefer for (adjacency[0..adjacency_write]) |replacement| allocator.free(replacement.dependents);
    for (nodes, 0..) |node, original_id| {
        var next_len: usize = 0;
        var changed = false;
        for (node.dependents) |dependent_id| {
            const final_id = final_record_ids[@intCast(dependent_id)] orelse {
                changed = true;
                continue;
            };
            if (final_id != dependent_id) changed = true;
            next_len += 1;
        }
        if (!changed and next_len == node.dependents.len and !(final_record_ids[original_id] == null and node.dependents.len != 0)) continue;
        const replacement = try allocator.alloc(u64, next_len);
        var write: usize = 0;
        for (node.dependents) |dependent_id| {
            const final_id = final_record_ids[@intCast(dependent_id)] orelse continue;
            replacement[write] = final_id;
            write += 1;
        }
        adjacency[adjacency_write] = .{ .record_id = @intCast(original_id), .dependents = replacement };
        adjacency_write += 1;
    }
    return .{
        .records = try records.toOwnedSlice(allocator),
        .steps = steps,
        .final_record_ids = final_record_ids,
        .original_record_ids = original_record_ids,
        .survivor_use_decrements = survivor_use_decrements,
        .adjacency = adjacency,
        .retired_adjacency = retired_adjacency,
        .retired_nodes = retired_nodes,
        .retired_text_routes = retired_text_routes,
        .retired_bool_routes = retired_bool_routes,
        .retired_change_routes = retired_change_routes,
        .retired_structural_routes = retired_structural_routes,
    };
}

/// Releases the test or plan's owned signal record exactly once.
pub fn releaseRecord(
    comptime Record: type,
    allocator: std.mem.Allocator,
    nodes: *std.ArrayListUnmanaged(Node(Record)),
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
    var input_records: std.ArrayListUnmanaged(*Record) = .empty;
    defer input_records.deinit(allocator);
    appendInputRecords(Record, allocator, &input_records, record);

    switch (record.payload) {
        .ref => |source_node_id| removeSourceRoute(source_routes, source_node_id, record_id),
        .const_value, .task_source, .entropy_seed_source, .location_source, .online_source, .visibility_source, .storage_source, .row_source => {},
        .interval_source => hooks.removeInterval(record.token().?),
        .map, .map2, .select, .combine => {},
    }

    for (input_records.items) |input_record| {
        removeDependentId(Record, allocator, nodes.items, requireRecordId(Record, nodes.items, input_record), record_id);
    }

    removeNode(Record, allocator, nodes, source_routes, text_routes, bool_routes, change_routes, structural_routes, record_id, record, hooks);

    for (input_records.items) |input_record| {
        releaseRecord(Record, allocator, nodes, source_routes, text_routes, bool_routes, change_routes, structural_routes, input_record, hooks);
    }
}

/// Clears  while retaining bounded storage where the type promises reuse.
pub fn clear(comptime Record: type, allocator: std.mem.Allocator, nodes: *std.ArrayListUnmanaged(Node(Record)), hooks: anytype) void {
    for (nodes.items, 0..) |node, index| {
        allocator.free(node.dependents);
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
    nodes: *std.ArrayListUnmanaged(Node(Record)),
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

fn appendUniqueInputRecord(comptime Record: type, allocator: std.mem.Allocator, records: *std.ArrayListUnmanaged(*Record), record: *Record) void {
    if (!recordSliceContains(Record, records.items, record)) {
        records.append(allocator, record) catch @panic("out of memory");
    }
}

fn updateMovedRecordEdges(comptime Record: type, nodes: []Node(Record), source_routes: *RouteTable(u64), moved_record: *Record, old_record_id: u64, new_record_id: u64) void {
    switch (moved_record.payload) {
        .ref => |source_node_id| replaceSourceRouteId(source_routes, source_node_id, old_record_id, new_record_id),
        .const_value, .task_source, .interval_source, .entropy_seed_source, .location_source, .online_source, .visibility_source, .storage_source, .row_source => {},
        .map => |payload| replaceDependentId(Record, nodes, requireRecordId(Record, nodes, payload.input), old_record_id, new_record_id),
        .select => |payload| replaceDependentId(Record, nodes, requireRecordId(Record, nodes, payload.input), old_record_id, new_record_id),
        .map2 => |payload| {
            replaceDependentId(Record, nodes, requireRecordId(Record, nodes, payload.left), old_record_id, new_record_id);
            if (payload.right != payload.left) {
                replaceDependentId(Record, nodes, requireRecordId(Record, nodes, payload.right), old_record_id, new_record_id);
            }
        },
        .combine => |payload| {
            for (payload.children, 0..) |child, index| {
                if (recordSliceContains(Record, payload.children[0..index], child)) continue;
                replaceDependentId(Record, nodes, requireRecordId(Record, nodes, child), old_record_id, new_record_id);
            }
        },
    }
}

fn removeNode(
    comptime Record: type,
    allocator: std.mem.Allocator,
    nodes: *std.ArrayListUnmanaged(Node(Record)),
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
    if (nodes.items[record_index].dependents.len != 0) @panic("active signal graph removed a record with live dependents");

    allocator.free(nodes.items[record_index].dependents);
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

fn ensureSinkRoute(comptime Route: type, allocator: std.mem.Allocator, routes: *RouteTable(Route), graph_len: usize, record_id: u64, comptime unknown_record_message: []const u8) *std.ArrayListUnmanaged(Route) {
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

    if (routes.items[record_index].items.len != 0) @panic(live_route_message);
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
        combine: CombinePayload,
        task_source,
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
            .const_value, .map, .map2, .select, .combine, .task_source, .interval_source, .entropy_seed_source, .location_source, .online_source, .visibility_source, .storage_source, .row_source => self.id,
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

const LifecycleStream = struct {
    signal_text_nodes: std.ArrayListUnmanaged(LifecycleSignalDesc) = .empty,
    signal_text_attrs: std.ArrayListUnmanaged(LifecycleSignalDesc) = .empty,
    signal_custom_text_attrs: std.ArrayListUnmanaged(LifecycleSignalDesc) = .empty,
    signal_optional_custom_text_attrs: std.ArrayListUnmanaged(LifecycleSignalDesc) = .empty,
    signal_bool_attrs: std.ArrayListUnmanaged(LifecycleSignalDesc) = .empty,
    signal_custom_bool_attrs: std.ArrayListUnmanaged(LifecycleSignalDesc) = .empty,
    on_changes: std.ArrayListUnmanaged(LifecycleSignalDesc) = .empty,
    whens: std.ArrayListUnmanaged(LifecycleWhenDesc) = .empty,
    eaches: std.ArrayListUnmanaged(LifecycleEachDesc) = .empty,

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
        try std.testing.expectEqualDeep(TextSink{ .kind = .text_node, .index = 4 }, routes.items[0].items[0]);
    }
    try baseline.reserveOuter(counter.allocator(), &routes, 3);
    counter.configure(1);
    baseline.apply(&routes, 3);
    try std.testing.expectEqual(@as(usize, 0), counter.attempts);
    try std.testing.expectEqual(@as(usize, 3), routes.items.len);
    try std.testing.expectEqualSlices(TextSink, &.{ .{ .kind = .text_node, .index = 4 }, .{ .kind = .text_attr, .index = 7 } }, routes.items[0].items);
    try std.testing.expectEqualSlices(TextSink, &.{.{ .kind = .custom_text_attr, .index = 9 }}, routes.items[2].items);
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
    const original_record_ids = [_]usize{ 3, 0 };
    const appends = [_]RouteAppend(TextSink){
        .{ .route_index = 0, .value = .{ .kind = .text_attr, .index = 10 } },
        .{ .route_index = 1, .value = .{ .kind = .text_attr, .index = 11 } },
        .{ .route_index = 3, .value = .{ .kind = .text_attr, .index = 13 } },
    };

    var work: usize = 0;
    var counter = FaultAllocator.init(std.testing.allocator);
    var baseline = try prepareRouteAppendsAfterReleaseWithWork(TextSink, counter.allocator(), &routes, &original_record_ids, 4, &appends, &work);
    defer baseline.deinit(counter.allocator());
    try std.testing.expectEqual(@as(usize, appends.len), work);
    const attempts = counter.attempts;
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| {
        var fault = FaultAllocator.init(std.testing.allocator);
        fault.configure(failure_number);
        try std.testing.expectError(error.OutOfMemory, prepareRouteAppendsAfterRelease(TextSink, fault.allocator(), &routes, &original_record_ids, 4, &appends));
        for (routes.items, 0..) |route, index| try std.testing.expectEqualDeep(TextSink{ .kind = .text_node, .index = index }, route.items[0]);
    }
    try std.testing.expectError(error.InvalidAppend, prepareRouteAppendsAfterRelease(TextSink, std.testing.allocator, &routes, &.{ 0, 1, 2 }, 2, &appends));

    try baseline.reserveOuter(counter.allocator(), &routes, 4);
    counter.configure(1);
    baseline.apply(&routes, 4);
    try std.testing.expectEqual(@as(usize, 0), counter.attempts);
    try std.testing.expectEqualSlices(TextSink, &.{ .{ .kind = .text_node, .index = 3 }, .{ .kind = .text_attr, .index = 10 } }, routes.items[0].items);
    try std.testing.expectEqualSlices(TextSink, &.{ .{ .kind = .text_node, .index = 0 }, .{ .kind = .text_attr, .index = 11 } }, routes.items[1].items);
    try std.testing.expectEqualSlices(TextSink, &.{.{ .kind = .text_attr, .index = 13 }}, routes.items[3].items);
}

test "post-release route inversion lookup work scales with appended groups" {
    const measure = struct {
        fn run(count: usize) !usize {
            const inverse = try std.testing.allocator.alloc(usize, count);
            defer std.testing.allocator.free(inverse);
            const appends = try std.testing.allocator.alloc(RouteAppend(TextSink), count);
            defer std.testing.allocator.free(appends);
            for (inverse, appends, 0..) |*original, *append, index| {
                original.* = count - index - 1;
                append.* = .{ .route_index = @intCast(index), .value = .{ .kind = .text_node, .index = index } };
            }
            var routes: RouteTable(TextSink) = .empty;
            defer routes.deinit(std.testing.allocator);
            var work: usize = 0;
            var prepared = try prepareRouteAppendsAfterReleaseWithWork(TextSink, std.testing.allocator, &routes, inverse, count, appends, &work);
            defer prepared.deinit(std.testing.allocator);
            return work;
        }
    }.run;
    try std.testing.expectEqual(@as(usize, 64), try measure(64));
    try std.testing.expectEqual(@as(usize, 512), try measure(512));
}

test "prepared graph append enumerates missing topology without mutating survivors" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var survivor = LifecycleTestRecord{ .id = 1, .payload = .{ .ref = 0 } };
    var mapped = LifecycleTestRecord{ .id = 2, .payload = .{ .map = .{ .input = &survivor } } };
    var fresh = LifecycleTestRecord{ .id = 3, .payload = .const_value };
    var root = LifecycleTestRecord{ .id = 4, .payload = .{ .map2 = .{ .left = &mapped, .right = &fresh } } };
    var nodes: std.ArrayListUnmanaged(Node(LifecycleTestRecord)) = .empty;
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
    try std.testing.expectEqualSlices(u64, &.{0}, source_routes.items[0].items);
    const mapping = [_]?u64{0};
    const roots = [_]*LifecycleTestRecord{ &mapped, &root };

    var counter = FaultAllocator.init(std.testing.allocator);
    var baseline = try prepareGraphAppend(LifecycleTestRecord, counter.allocator(), nodes.items, &mapping, &roots);
    defer baseline.deinit(counter.allocator());
    const attempts = counter.attempts;
    try std.testing.expect(attempts != 0);
    try std.testing.expectEqualSlices(*LifecycleTestRecord, &.{ &mapped, &fresh, &root }, baseline.records);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 3 }, baseline.record_ids);
    try std.testing.expectEqual(@as(?u64, 0), baseline.plannedRecordId(nodes.items, &survivor));
    try std.testing.expectEqual(@as(?u64, 1), baseline.plannedRecordId(nodes.items, &mapped));
    try std.testing.expectEqual(@as(?u64, 2), baseline.plannedRecordId(nodes.items, &fresh));
    try std.testing.expectEqual(@as(?u64, 3), baseline.plannedRecordId(nodes.items, &root));
    try std.testing.expectEqualSlices(u64, &.{ 1, 0, 2 }, baseline.ranks);
    try std.testing.expectEqualSlices(usize, &.{ 2, 1, 1 }, baseline.use_counts);
    try std.testing.expectEqual(@as(usize, 1), mapped.ref_count);
    try std.testing.expectEqual(@as(usize, 1), fresh.ref_count);
    try std.testing.expectEqual(@as(usize, 1), root.ref_count);
    try std.testing.expectEqualSlices(ExistingUseIncrement, &.{.{ .record_id = 0, .count = 1 }}, baseline.existing_use_increments);
    try std.testing.expectEqual(@as(usize, 1), baseline.survivor_adjacency.len);
    try std.testing.expectEqual(@as(u64, 0), baseline.survivor_adjacency[0].record_id);
    try std.testing.expectEqualSlices(u64, &.{1}, baseline.survivor_adjacency[0].dependents);
    try std.testing.expectEqualSlices(u64, &.{3}, baseline.new_nodes[0].dependents);
    try std.testing.expectEqualSlices(u64, &.{3}, baseline.new_nodes[1].dependents);
    try std.testing.expectEqualSlices(u64, &.{}, baseline.new_nodes[2].dependents);

    for (1..attempts + 1) |failure_number| {
        var fault = FaultAllocator.init(std.testing.allocator);
        fault.configure(failure_number);
        try std.testing.expectError(error.OutOfMemory, prepareGraphAppend(LifecycleTestRecord, fault.allocator(), nodes.items, &mapping, &roots));
        try std.testing.expectEqual(@as(usize, 1), nodes.items.len);
        try std.testing.expectEqual(@as(?u64, 0), survivor.active_graph_id);
        try std.testing.expectEqual(@as(usize, 1), survivor.active_use_count);
        try std.testing.expectEqualSlices(u64, &.{}, nodes.items[0].dependents);
        try std.testing.expectEqualSlices(u64, &.{0}, source_routes.items[0].items);
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
    try std.testing.expectEqualSlices(u64, &.{1}, nodes.items[0].dependents);
    try std.testing.expectEqualSlices(u64, &.{3}, nodes.items[1].dependents);
    try std.testing.expectEqualSlices(u64, &.{3}, nodes.items[2].dependents);
    try std.testing.expectEqualSlices(u64, &.{}, nodes.items[3].dependents);
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

            var lookup_work: usize = 0;
            var prepared = try prepareGraphAppendWithWork(LifecycleTestRecord, std.testing.allocator, &.{}, &.{}, roots, &lookup_work);
            defer prepared.deinit(std.testing.allocator);
            try std.testing.expectEqual(count + 1, prepared.records.len);
            try std.testing.expectEqual(count, prepared.use_counts[0]);
            try std.testing.expectEqual(@as(u64, 0), prepared.ranks[0]);
            for (prepared.ranks[1..]) |prepared_rank| try std.testing.expectEqual(@as(u64, 1), prepared_rank);
            return lookup_work;
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
            var work: usize = 0;
            try countExistingRetainsWithWork(LifecycleTestRecord, std.testing.allocator, &.{}, roots, &.{}, &work);
            return work;
        }
    }.run;

    const small: usize = 64;
    const large: usize = 512;
    try std.testing.expectEqual(2 * small, try measureShared(small));
    try std.testing.expectEqual(2 * large, try measureShared(large));

    var left = LifecycleTestRecord{ .id = 1, .payload = .const_value };
    var right = LifecycleTestRecord{ .id = 2, .payload = .{ .map = .{ .input = &left } } };
    left.payload = .{ .map = .{ .input = &right } };
    var cycle_work: usize = 0;
    try countExistingRetainsWithWork(LifecycleTestRecord, std.testing.allocator, &.{}, &.{&left}, &.{}, &cycle_work);
    try std.testing.expectEqual(@as(usize, 3), cycle_work);
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
    var nodes: std.ArrayListUnmanaged(Node(LifecycleTestRecord)) = .empty;
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
    try std.testing.expectEqualSlices(?u64, &.{ 0, 1, null, 2 }, release.final_record_ids);
    try std.testing.expectEqualSlices(ExistingUseIncrement, &.{ .{ .record_id = 0, .count = 1 }, .{ .record_id = 1, .count = 1 } }, release.survivor_use_decrements);
    for (1..release_attempts + 1) |failure_number| {
        var fault = FaultAllocator.init(std.testing.allocator);
        fault.configure(failure_number);
        try std.testing.expectError(error.OutOfMemory, prepareReleaseClosure(LifecycleTestRecord, fault.allocator(), nodes.items, &retired_roots, &replacement_roots));
        try std.testing.expectEqual(@as(usize, 1), source.active_use_count);
        try std.testing.expectEqual(@as(usize, 2), shared.active_use_count);
        for (nodes.items, 0..) |node, index| try std.testing.expectEqual(@as(?u64, @intCast(index)), node.record.active_graph_id);
    }

    var append = try prepareGraphAppend(LifecycleTestRecord, counter.allocator(), nodes.items, release.final_record_ids, &replacement_roots);
    defer append.deinit(counter.allocator());
    try std.testing.expectEqualSlices(*LifecycleTestRecord, &.{&new_root}, append.records);
    try std.testing.expectEqualSlices(u64, &.{3}, append.record_ids);
    try std.testing.expectEqualSlices(ExistingUseIncrement, &.{.{ .record_id = 0, .count = 1 }}, append.existing_use_increments);
    try std.testing.expectEqual(@as(?u64, 0), append.plannedRecordId(nodes.items, &source));

    try append.reservePublication(counter.allocator(), &nodes);
    try append.reserveParallelRoutes(counter.allocator(), &text_routes, &bool_routes, &change_routes, &structural_routes);
    counter.configure(1);
    release.applyAdjacency(nodes.items);
    release.applyDense(&nodes, &source_routes, &text_routes, &bool_routes, &change_routes, &structural_routes);
    append.commitNodes(&nodes);
    append.commitParallelRoutes(&text_routes, &bool_routes, &change_routes, &structural_routes);
    release.releaseRetired(counter.allocator(), &hooks);
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
    try std.testing.expectEqualSlices(u64, &.{3}, nodes.items[0].dependents);
    try std.testing.expectEqualSlices(u64, &.{2}, nodes.items[1].dependents);
    try std.testing.expectEqualSlices(u64, &.{0}, source_routes.items[0].items);
    try std.testing.expectEqualSlices(u64, &.{1}, source_routes.items[1].items);
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
    var nodes: std.ArrayListUnmanaged(Node(LifecycleTestRecord)) = .empty;
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
    try std.testing.expectEqualSlices(u64, &.{0}, source_routes.items[0].items);

    var counter = FaultAllocator.init(std.testing.allocator);
    var baseline = try prepareReleaseClosure(LifecycleTestRecord, counter.allocator(), nodes.items, &.{&root}, &.{});
    const attempts = counter.attempts;
    try std.testing.expectEqualSlices(*LifecycleTestRecord, &.{ &root, &left, &right, &source }, baseline.records);
    try std.testing.expectEqualDeep(PreparedReleaseStep{ .record_id = 3, .removal_index = 3, .moved_record_id = null }, baseline.steps[0]);
    try std.testing.expectEqualDeep(PreparedReleaseStep{ .record_id = 1, .removal_index = 1, .moved_record_id = 2 }, baseline.steps[1]);
    try std.testing.expectEqualDeep(PreparedReleaseStep{ .record_id = 2, .removal_index = 1, .moved_record_id = null }, baseline.steps[2]);
    try std.testing.expectEqualDeep(PreparedReleaseStep{ .record_id = 0, .removal_index = 0, .moved_record_id = null }, baseline.steps[3]);
    try std.testing.expectEqualSlices(?u64, &.{ null, null, null, null }, baseline.final_record_ids);
    try std.testing.expectEqual(@as(usize, 3), baseline.adjacency.len);
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
        try std.testing.expectEqualSlices(u64, &.{ 1, 2 }, nodes.items[0].dependents);
        try std.testing.expectEqualSlices(u64, &.{3}, nodes.items[1].dependents);
        try std.testing.expectEqualSlices(u64, &.{3}, nodes.items[2].dependents);
    }
    counter.configure(1);
    baseline.applyAdjacency(nodes.items);
    try std.testing.expectEqual(@as(usize, 0), counter.attempts);
    try std.testing.expectEqualSlices(u64, &.{}, nodes.items[0].dependents);
    try std.testing.expectEqualSlices(u64, &.{}, nodes.items[1].dependents);
    try std.testing.expectEqualSlices(u64, &.{}, nodes.items[2].dependents);
    baseline.applyDense(&nodes, &source_routes, &text_routes, &bool_routes, &change_routes, &structural_routes);
    try std.testing.expectEqual(@as(usize, 0), nodes.items.len);
    try std.testing.expectEqual(@as(usize, 0), text_routes.items.len);
    try std.testing.expectEqual(@as(usize, 0), bool_routes.items.len);
    try std.testing.expectEqual(@as(usize, 0), change_routes.items.len);
    try std.testing.expectEqual(@as(usize, 0), structural_routes.items.len);
    try std.testing.expectEqualSlices(u64, &.{}, source_routes.items[0].items);
    try std.testing.expectEqual(@as(usize, 0), counter.attempts);
    baseline.releaseRetired(counter.allocator(), &hooks);
    counter.configure(null);
    baseline.deinit(counter.allocator());
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
            std.testing.allocator.free(node.dependents);
        }
    }

    try signal_graph.appendDependent(TestRecord, std.testing.allocator, &nodes, 0, 1);
    try signal_graph.appendDependent(TestRecord, std.testing.allocator, &nodes, 0, 2);
    try signal_graph.appendDependent(TestRecord, std.testing.allocator, &nodes, 2, 3);
    try signal_graph.appendDependent(TestRecord, std.testing.allocator, &nodes, 3, 1);

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
    defer for (&nodes) |*node| std.testing.allocator.free(node.dependents);
    try signal_graph.appendDependent(TestRecord, std.testing.allocator, &nodes, 0, 1);
    try signal_graph.appendDependent(TestRecord, std.testing.allocator, &nodes, 1, 2);

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
            std.testing.allocator.free(node.dependents);
        }
    }
    try signal_graph.appendDependent(TestRecord, std.testing.allocator, &nodes, 1, 2);
    try signal_graph.appendDependent(TestRecord, std.testing.allocator, &nodes, 2, 0);

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
            std.testing.allocator.free(node.dependents);
        }
    }
    try signal_graph.appendDependent(TestRecord, std.testing.allocator, &nodes, 0, 1);
    try signal_graph.appendDependent(TestRecord, std.testing.allocator, &nodes, 0, 2);
    try signal_graph.appendDependent(TestRecord, std.testing.allocator, &nodes, 1, 3);
    try signal_graph.appendDependent(TestRecord, std.testing.allocator, &nodes, 2, 3);

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
    try std.testing.expectEqualSlices(u64, &.{7}, source_routes.items[2].items);

    replaceSourceRouteId(&source_routes, 2, 7, 3);
    try std.testing.expectEqualSlices(u64, &.{3}, source_routes.items[2].items);

    removeSourceRoute(&source_routes, 2, 3);
    try std.testing.expectEqual(@as(usize, 0), source_routes.items[2].items.len);
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
    try std.testing.expectEqualSlices(TextSink, &.{.{ .kind = .text_attr, .index = 8 }}, text_routes.items[1].items);

    appendBoolRoute(std.testing.allocator, &bool_routes, 2, 1, .{ .kind = .bool_attr, .index = 4 });
    appendBoolRoute(std.testing.allocator, &bool_routes, 2, 1, .{ .kind = .custom_bool_attr, .index = 4 });
    updateBoolRouteIndex(&bool_routes, 1, .custom_bool_attr, 4, 9);
    removeBoolRoute(&bool_routes, 1, .bool_attr, 4);
    try std.testing.expectEqualSlices(BoolSink, &.{.{ .kind = .custom_bool_attr, .index = 9 }}, bool_routes.items[1].items);
    removeBoolRoute(&bool_routes, 1, .custom_bool_attr, 9);
    try std.testing.expectEqual(@as(usize, 0), bool_routes.items[1].items.len);

    appendChangeRoute(std.testing.allocator, &change_routes, 2, 1, .{ .index = 5 });
    updateChangeRouteIndex(&change_routes, 1, 5, 10);
    removeChangeRoute(&change_routes, 1, 10);
    try std.testing.expectEqual(@as(usize, 0), change_routes.items[1].items.len);

    appendStructuralRoute(std.testing.allocator, &structural_routes, 2, 1, .{ .kind = .when, .index = 6 });
    appendStructuralRoute(std.testing.allocator, &structural_routes, 2, 1, .{ .kind = .each, .index = 6 });
    updateStructuralRouteIndex(&structural_routes, 1, .each, 6, 11);
    removeStructuralRoute(&structural_routes, 1, .when, 6);
    try std.testing.expectEqualSlices(StructuralSink, &.{.{ .kind = .each, .index = 11 }}, structural_routes.items[1].items);
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
    try std.testing.expectEqualSlices(TextSink, &.{.{ .kind = .text_node, .index = 9 }}, text_routes.items[0].items);
    try std.testing.expectEqualSlices(TextSink, &.{.{ .kind = .text_attr, .index = 4 }}, text_routes.items[1].items);
}

test "active graph retain and release update moved record ids and routes" {
    var source_a = LifecycleTestRecord{ .id = 0, .payload = .{ .ref = 1 } };
    var source_b = LifecycleTestRecord{ .id = 1, .payload = .{ .ref = 2 } };
    var mapped = LifecycleTestRecord{ .id = 2, .payload = .{ .map = .{ .input = &source_b } } };

    var nodes: std.ArrayListUnmanaged(Node(LifecycleTestRecord)) = .empty;
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
    try std.testing.expectEqualSlices(u64, &.{2}, nodes.items[1].dependents);
    try std.testing.expectEqualSlices(u64, &.{0}, source_routes.items[1].items);
    try std.testing.expectEqualSlices(u64, &.{1}, source_routes.items[2].items);

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
    try std.testing.expectEqualSlices(u64, &.{0}, nodes.items[1].dependents);
    try std.testing.expectEqualSlices(u64, &.{}, source_routes.items[1].items);
    try std.testing.expectEqualSlices(u64, &.{1}, source_routes.items[2].items);

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

    var nodes: std.ArrayListUnmanaged(Node(LifecycleTestRecord)) = .empty;
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
    try std.testing.expectEqualSlices(u64, &.{mapped.active_graph_id.?}, nodes.items[@intCast(row_source.active_graph_id.?)].dependents);
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

    var nodes: std.ArrayListUnmanaged(Node(LifecycleTestRecord)) = .empty;
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

    var nodes: std.ArrayListUnmanaged(Node(LifecycleTestRecord)) = .empty;
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

    try std.testing.expectEqualSlices(TextSink, &.{ .{ .kind = .custom_text_attr, .index = 0 }, .{ .kind = .custom_text_optional_attr, .index = 0 } }, text_routes.items[0].items);
    try std.testing.expectEqualSlices(TextSink, &.{ .{ .kind = .text_node, .index = 0 }, .{ .kind = .text_attr, .index = 0 } }, text_routes.items[1].items);
    try std.testing.expectEqualSlices(BoolSink, &.{.{ .kind = .bool_attr, .index = 0 }}, bool_routes.items[0].items);
    try std.testing.expectEqualSlices(BoolSink, &.{.{ .kind = .custom_bool_attr, .index = 0 }}, bool_routes.items[1].items);
    try std.testing.expectEqualSlices(ChangeSink, &.{.{ .index = 0 }}, change_routes.items[1].items);
    try std.testing.expectEqualSlices(StructuralSink, &.{.{ .kind = .when, .index = 0 }}, structural_routes.items[0].items);
    try std.testing.expectEqualSlices(StructuralSink, &.{.{ .kind = .each, .index = 0 }}, structural_routes.items[1].items);

    clear(LifecycleTestRecord, std.testing.allocator, &nodes, &hooks);
    try std.testing.expectEqual(@as(?u64, null), source.active_graph_id);
    try std.testing.expectEqual(@as(?u64, null), mapped.active_graph_id);
}
