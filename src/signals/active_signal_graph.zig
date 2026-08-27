//! Active signal graph records, routes, and dirty propagation helpers.

const std = @import("std");
const scope_tree = @import("scope_tree.zig");
const signal_records = @import("signal_records.zig");
const signal_graph = @import("signal_graph.zig");
const boundary = @import("boundary.zig");

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
    event_id: u64,
    signal_ids: []u64,
};

pub const EventDescriptor = struct {
    event_id: u64,
    payload_descriptor: boundary.BoundaryPayloadDescriptor,
};

pub const Descriptor = struct {
    signal_id: u64,
    kind: SignalKind,
    source_state_ids: []u64,
    source_event_ids: []u64,
    input_signal_ids: []u64,
    rank: u64,
};

pub const StateRoute = struct {
    state_id: u64,
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

pub const DirtyStructuralSignal = struct {
    kind: StructuralKind,
    node_id: u64,
    scope_id: u64,
    ordinal: u64,
    record: *signal_records.Record,
    branch: ?scope_tree.Branch = null,
};

/// Returns dense source ids for the validated event route without rediscovering dependencies.
pub fn sourceSignalIdsForEvent(routes: []const EventRoute, event_id: u64) EventLookupError![]const u64 {
    if (event_id == 0) return EventLookupError.EventIdZero;

    const route_index = event_id - 1;
    if (route_index >= routes.len) return EventLookupError.MissingSignalEventRoute;

    const route = routes[@intCast(route_index)];
    if (route.event_id != event_id) return EventLookupError.SignalEventRouteIndexMismatch;
    return route.signal_ids;
}

/// Returns the validated payload schema attached to an active event route.
pub fn eventPayloadDescriptor(descriptors: []const EventDescriptor, event_id: u64) EventLookupError!boundary.BoundaryPayloadDescriptor {
    if (event_id == 0) return EventLookupError.EventIdZero;

    const event_index = event_id - 1;
    if (event_index >= descriptors.len) return EventLookupError.MissingEventDescriptor;

    const descriptor = descriptors[@intCast(event_index)];
    if (descriptor.event_id != event_id) return EventLookupError.EventDescriptorIndexMismatch;
    return descriptor.payload_descriptor;
}

/// Returns dense signal ids associated with for state from maintained indexes.
pub fn signalIdsForState(routes: []const StateRoute, state_id: u64) SignalLookupError![]const u64 {
    if (state_id >= routes.len) return SignalLookupError.MissingSignalRoute;

    const route = routes[@intCast(state_id)];
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
    var route_signal_ids = [_]u64{ 3, 5 };
    var state_signal_ids = [_]u64{7};
    var dependent_signal_ids = [_]u64{ 11, 13 };
    var empty_signal_ids = [_]u64{};

    const event_routes = [_]EventRoute{
        .{ .event_id = 1, .signal_ids = &route_signal_ids },
    };
    const mismatched_event_routes = [_]EventRoute{
        .{ .event_id = 2, .signal_ids = &route_signal_ids },
    };
    const event_descriptors = [_]EventDescriptor{
        .{ .event_id = 1, .payload_descriptor = event_payload },
    };
    const mismatched_event_descriptors = [_]EventDescriptor{
        .{ .event_id = 2, .payload_descriptor = event_payload },
    };
    const state_routes = [_]StateRoute{
        .{ .state_id = 0, .signal_ids = &state_signal_ids },
    };
    const mismatched_state_routes = [_]StateRoute{
        .{ .state_id = 1, .signal_ids = &state_signal_ids },
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
            .source_state_ids = &state_signal_ids,
            .source_event_ids = &route_signal_ids,
            .input_signal_ids = &dependent_signal_ids,
            .rank = 9,
        },
    };
    const mismatched_descriptors = [_]Descriptor{
        .{
            .signal_id = 1,
            .kind = .source,
            .source_state_ids = &empty_signal_ids,
            .source_event_ids = &empty_signal_ids,
            .input_signal_ids = &empty_signal_ids,
            .rank = 0,
        },
    };

    try std.testing.expectEqualSlices(u64, &route_signal_ids, try sourceSignalIdsForEvent(&event_routes, 1));
    try std.testing.expectEqual(event_payload, try eventPayloadDescriptor(&event_descriptors, 1));
    try std.testing.expectEqualSlices(u64, &state_signal_ids, try signalIdsForState(&state_routes, 0));
    try std.testing.expectEqualSlices(u64, &dependent_signal_ids, try dependentSignalIdsForSignal(&dependent_routes, 0));
    try std.testing.expectEqual(@as(u64, 9), try signalRank(&descriptors, 0));

    try std.testing.expectError(EventLookupError.EventIdZero, sourceSignalIdsForEvent(&event_routes, 0));
    try std.testing.expectError(EventLookupError.MissingSignalEventRoute, sourceSignalIdsForEvent(&event_routes, 2));
    try std.testing.expectError(EventLookupError.SignalEventRouteIndexMismatch, sourceSignalIdsForEvent(&mismatched_event_routes, 1));

    try std.testing.expectError(EventLookupError.EventIdZero, eventPayloadDescriptor(&event_descriptors, 0));
    try std.testing.expectError(EventLookupError.MissingEventDescriptor, eventPayloadDescriptor(&event_descriptors, 2));
    try std.testing.expectError(EventLookupError.EventDescriptorIndexMismatch, eventPayloadDescriptor(&mismatched_event_descriptors, 1));

    try std.testing.expectError(SignalLookupError.MissingSignalRoute, signalIdsForState(&state_routes, 1));
    try std.testing.expectError(SignalLookupError.SignalRouteIndexMismatch, signalIdsForState(&mismatched_state_routes, 0));

    try std.testing.expectError(SignalLookupError.MissingSignalDependentRoute, dependentSignalIdsForSignal(&dependent_routes, 1));
    try std.testing.expectError(SignalLookupError.SignalDependentRouteIndexMismatch, dependentSignalIdsForSignal(&mismatched_dependent_routes, 0));

    try std.testing.expectError(SignalLookupError.MissingSignalDescriptor, signalRank(&descriptors, 1));
    try std.testing.expectError(SignalLookupError.SignalDescriptorIndexMismatch, signalRank(&mismatched_descriptors, 0));
}

pub const DirtyRecordQueue = struct {
    generation: u64 = 0,
    seen_generations: std.ArrayListUnmanaged(u64) = .empty,
    pending_record_ids: std.ArrayListUnmanaged(u64) = .empty,
    ordered_record_ids: std.ArrayListUnmanaged(u64) = .empty,
    rank_counts: std.ArrayListUnmanaged(usize) = .empty,
    rank_offsets: std.ArrayListUnmanaged(usize) = .empty,

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
        .ref, .const_value, .task_source, .interval_source, .location_source, .online_source, .visibility_source, .storage_source => {},
        .map => |payload| appendUniqueInputRecord(Record, allocator, records, payload.input),
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
        .ref, .const_value, .task_source, .interval_source, .location_source, .online_source, .visibility_source, .storage_source => {},
        .map => |payload| {
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
        .const_value, .task_source, .location_source, .online_source, .visibility_source, .storage_source => {},
        .interval_source => |payload| hooks.ensureInterval(record.token().?, payload.period_ms),
        .map => |payload| appendDependentId(Record, allocator, nodes.items, requireRecordId(Record, nodes.items, payload.input), record_id),
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

/// Owns a read-only simulation of recursive active-record release and dense remaps.
pub fn PreparedReleaseClosure(comptime Record: type) type {
    return struct {
        records: []*Record,
        steps: []PreparedReleaseStep,

        /// Releases preparation storage without changing graph state.
        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.records);
            allocator.free(self.steps);
            self.* = undefined;
        }
    };
}

/// Simulates descriptor-root releases, recursive zero-use inputs, and dense
/// swap-remaps without mutating graph records or route state.
pub fn prepareReleaseClosure(comptime Record: type, allocator: std.mem.Allocator, nodes: []const Node(Record), roots: []const *Record) (std.mem.Allocator.Error || error{InvalidRelease})!PreparedReleaseClosure(Record) {
    const counts = try allocator.alloc(usize, nodes.len);
    defer allocator.free(counts);
    const scheduled = try allocator.alloc(bool, nodes.len);
    defer allocator.free(scheduled);
    @memset(scheduled, false);
    for (nodes, 0..) |node, index| {
        if (node.record.active_graph_id != @as(u64, @intCast(index))) return error.InvalidRelease;
        counts[index] = node.record.active_use_count;
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
                .ref, .const_value, .task_source, .interval_source, .location_source, .online_source, .visibility_source, .storage_source => {},
            }
        }
    };
    for (roots) |root| try Simulator.decrement(root, nodes, counts, scheduled, &records);

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
    return .{ .records = try records.toOwnedSlice(allocator), .steps = steps };
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
        .const_value, .task_source, .location_source, .online_source, .visibility_source, .storage_source => {},
        .interval_source => hooks.removeInterval(record.token().?),
        .map, .map2, .combine => {},
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
        .const_value, .task_source, .interval_source, .location_source, .online_source, .visibility_source, .storage_source => {},
        .map => |payload| replaceDependentId(Record, nodes, requireRecordId(Record, nodes, payload.input), old_record_id, new_record_id),
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
        combine: CombinePayload,
        task_source,
        interval_source: IntervalPayload,
        location_source,
        online_source,
        visibility_source,
        storage_source,
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
            .const_value, .map, .map2, .combine, .task_source, .interval_source, .location_source, .online_source, .visibility_source, .storage_source => self.id,
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

    /// Removes interval and releases the ownership attached to that live entry.
    pub fn removeInterval(self: *@This(), token: u64) void {
        if (token == 0) @panic("test interval token must be explicit");
        self.interval_removes += 1;
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

test "prepared release closure preserves shared diamond and computes dense remaps" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var source = LifecycleTestRecord{ .id = 1, .payload = .const_value };
    var left = LifecycleTestRecord{ .id = 2, .payload = .{ .map = .{ .input = &source } } };
    var right = LifecycleTestRecord{ .id = 3, .payload = .{ .map = .{ .input = &source } } };
    var root = LifecycleTestRecord{ .id = 4, .payload = .{ .map2 = .{ .left = &left, .right = &right } } };
    var nodes: std.ArrayListUnmanaged(Node(LifecycleTestRecord)) = .empty;
    var source_routes: RouteTable(u64) = .empty;
    var hooks: LifecycleTestHooks = .{};
    defer {
        clearSourceRoutes(std.testing.allocator, &source_routes);
        source_routes.deinit(std.testing.allocator);
        clear(LifecycleTestRecord, std.testing.allocator, &nodes, &hooks);
        nodes.deinit(std.testing.allocator);
    }
    _ = retainRecord(LifecycleTestRecord, std.testing.allocator, &nodes, &source_routes, 1, &root, &hooks);
    try std.testing.expectEqual(@as(usize, 2), source.active_use_count);

    var counter = FaultAllocator.init(std.testing.allocator);
    var baseline = try prepareReleaseClosure(LifecycleTestRecord, counter.allocator(), nodes.items, &.{&root});
    const attempts = counter.attempts;
    try std.testing.expectEqualSlices(*LifecycleTestRecord, &.{ &root, &left, &right, &source }, baseline.records);
    try std.testing.expectEqualDeep(PreparedReleaseStep{ .record_id = 3, .removal_index = 3, .moved_record_id = null }, baseline.steps[0]);
    try std.testing.expectEqualDeep(PreparedReleaseStep{ .record_id = 1, .removal_index = 1, .moved_record_id = 2 }, baseline.steps[1]);
    try std.testing.expectEqualDeep(PreparedReleaseStep{ .record_id = 2, .removal_index = 1, .moved_record_id = null }, baseline.steps[2]);
    try std.testing.expectEqualDeep(PreparedReleaseStep{ .record_id = 0, .removal_index = 0, .moved_record_id = null }, baseline.steps[3]);
    baseline.deinit(counter.allocator());
    try std.testing.expect(attempts != 0);

    for (1..attempts + 1) |failure_number| {
        var fault = FaultAllocator.init(std.testing.allocator);
        fault.configure(failure_number);
        try std.testing.expectError(error.OutOfMemory, prepareReleaseClosure(LifecycleTestRecord, fault.allocator(), nodes.items, &.{&root}));
        try std.testing.expectEqual(@as(usize, 1), root.active_use_count);
        try std.testing.expectEqual(@as(usize, 1), left.active_use_count);
        try std.testing.expectEqual(@as(usize, 1), right.active_use_count);
        try std.testing.expectEqual(@as(usize, 2), source.active_use_count);
        for (nodes.items, 0..) |node, index| try std.testing.expectEqual(@as(?u64, @intCast(index)), node.record.active_graph_id);
    }
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
