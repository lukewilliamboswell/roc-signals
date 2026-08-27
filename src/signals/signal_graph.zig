//! Generic dependency graph helpers for ranking and collecting dirty signals.

const std = @import("std");

pub const Error = error{
    UnknownNode,
    MissingDependent,
};

/// Defines one dependency-graph node with its stored rank and forward adjacency.
pub fn Node(comptime Record: type) type {
    return struct {
        record: *Record,
        rank: u64 = 0,
        dependents: []u64 = &.{},
    };
}

/// Appends dependent using capacity that must already satisfy the caller's transaction contract.
pub fn appendDependent(comptime Record: type, allocator: std.mem.Allocator, nodes: []Node(Record), input_id: u64, dependent_id: u64) (Error || std.mem.Allocator.Error)!void {
    const input_index: usize = @intCast(input_id);
    if (input_index >= nodes.len) return Error.UnknownNode;

    const dependents = &nodes[input_index].dependents;
    if (containsU64(dependents.*, dependent_id)) return;

    const previous_len = dependents.*.len;
    dependents.* = try allocator.realloc(dependents.*, previous_len + 1);
    dependents.*[previous_len] = dependent_id;
}

/// Removes dependent and releases the ownership attached to that live entry.
pub fn removeDependent(comptime Record: type, allocator: std.mem.Allocator, nodes: []Node(Record), input_id: u64, dependent_id: u64) (Error || std.mem.Allocator.Error)!void {
    var prepared = try prepareDependentRemoval(Record, allocator, nodes, input_id, dependent_id);
    defer prepared.deinit(allocator);
    const retired = prepared.apply(Record, nodes);
    allocator.free(retired);
}

/// Owns replacement adjacency until an allocation-free edge-removal commit.
pub const PreparedDependentRemoval = struct {
    input_id: u64,
    replacement: []u64,
    committed: bool = false,

    /// Releases provisional replacement storage on abort.
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.replacement);
        self.* = undefined;
    }

    /// Swaps prepared adjacency into the live node and returns displaced ownership.
    pub fn apply(self: *@This(), comptime Record: type, nodes: []Node(Record)) []u64 {
        if (self.committed) @panic("dependent removal was already committed");
        const index: usize = @intCast(self.input_id);
        if (index >= nodes.len) @panic("prepared dependent removal referenced an unknown node");
        const retired = nodes[index].dependents;
        nodes[index].dependents = self.replacement;
        self.replacement = &.{};
        self.committed = true;
        return retired;
    }
};

/// Copies surviving adjacency before mutation so edge removal can commit atomically.
pub fn prepareDependentRemoval(comptime Record: type, allocator: std.mem.Allocator, nodes: []const Node(Record), input_id: u64, dependent_id: u64) (Error || std.mem.Allocator.Error)!PreparedDependentRemoval {
    const input_index: usize = @intCast(input_id);
    if (input_index >= nodes.len) return Error.UnknownNode;
    const existing = nodes[input_index].dependents;
    var found = false;
    for (existing) |id| if (id == dependent_id) {
        found = true;
        break;
    };
    if (!found) return Error.MissingDependent;
    const replacement = try allocator.alloc(u64, existing.len - 1);
    var write_index: usize = 0;
    for (existing) |id| {
        if (id == dependent_id) continue;
        replacement[write_index] = id;
        write_index += 1;
    }
    return .{ .input_id = input_id, .replacement = replacement };
}

/// Replaces dependent while releasing displaced ownership exactly once.
pub fn replaceDependent(comptime Record: type, nodes: []Node(Record), input_id: u64, old_dependent_id: u64, new_dependent_id: u64) Error!void {
    const input_index: usize = @intCast(input_id);
    if (input_index >= nodes.len) return Error.UnknownNode;

    const dependents = nodes[input_index].dependents;
    for (dependents) |*existing_id| {
        if (existing_id.* != old_dependent_id) continue;
        existing_id.* = new_dependent_id;
        return;
    }

    return Error.MissingDependent;
}

/// Returns the stored topological rank used for dependency-ordered scheduling.
pub fn rank(comptime Record: type, nodes: []const Node(Record), record_id: u64) Error!u64 {
    const index: usize = @intCast(record_id);
    if (index >= nodes.len) return Error.UnknownNode;
    return nodes[index].rank;
}

/// Returns stored forward adjacency for one signal without scanning the graph.
pub fn dependentIds(comptime Record: type, nodes: []const Node(Record), record_id: u64) Error![]const u64 {
    const index: usize = @intCast(record_id);
    if (index >= nodes.len) return Error.UnknownNode;
    return nodes[index].dependents;
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

test "signal graph dependents are unique and mutable" {
    var records = [_]TestRecord{
        .{ .id = 0 },
        .{ .id = 1 },
        .{ .id = 2 },
        .{ .id = 3 },
    };
    var nodes = [_]Node(TestRecord){
        .{ .record = &records[0], .rank = 0 },
        .{ .record = &records[1], .rank = 1 },
        .{ .record = &records[2], .rank = 2 },
        .{ .record = &records[3], .rank = 3 },
    };
    defer {
        for (&nodes) |*node| {
            std.testing.allocator.free(node.dependents);
        }
    }

    try appendDependent(TestRecord, std.testing.allocator, &nodes, 0, 1);
    try appendDependent(TestRecord, std.testing.allocator, &nodes, 0, 1);
    try appendDependent(TestRecord, std.testing.allocator, &nodes, 0, 2);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2 }, nodes[0].dependents);

    try replaceDependent(TestRecord, &nodes, 0, 2, 3);
    try std.testing.expectEqualSlices(u64, &.{ 1, 3 }, nodes[0].dependents);

    try removeDependent(TestRecord, std.testing.allocator, &nodes, 0, 1);
    try std.testing.expectEqualSlices(u64, &.{3}, nodes[0].dependents);
}

test "prepared dependent removal leaves adjacency atomic under allocation faults" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var records = [_]TestRecord{ .{ .id = 0 }, .{ .id = 1 }, .{ .id = 2 } };
    var nodes = [_]Node(TestRecord){
        .{ .record = &records[0], .dependents = try std.testing.allocator.dupe(u64, &.{ 1, 2 }) },
        .{ .record = &records[1] },
        .{ .record = &records[2] },
    };
    defer for (&nodes) |*node| std.testing.allocator.free(node.dependents);

    var failing = FaultAllocator.init(std.testing.allocator);
    failing.configure(1);
    try std.testing.expectError(error.OutOfMemory, prepareDependentRemoval(TestRecord, failing.allocator(), &nodes, 0, 1));
    try std.testing.expectEqualSlices(u64, &.{ 1, 2 }, nodes[0].dependents);

    var fault = FaultAllocator.init(std.testing.allocator);
    var prepared = try prepareDependentRemoval(TestRecord, fault.allocator(), &nodes, 0, 1);
    defer prepared.deinit(fault.allocator());
    fault.configure(1);
    const retired = prepared.apply(TestRecord, &nodes);
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqualSlices(u64, &.{2}, nodes[0].dependents);
    std.testing.allocator.free(retired);
}
