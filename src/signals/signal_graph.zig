//! Generic dependency graph helpers for ranking and collecting dirty signals.

const std = @import("std");

pub const Error = error{
    UnknownNode,
    MissingDependent,
};

/// Provides the `Node` operation.
pub fn Node(comptime Record: type) type {
    return struct {
        record: *Record,
        rank: u64 = 0,
        dependents: []u64 = &.{},
    };
}

/// Provides the `appendDependent` operation.
pub fn appendDependent(comptime Record: type, allocator: std.mem.Allocator, nodes: []Node(Record), input_id: u64, dependent_id: u64) (Error || std.mem.Allocator.Error)!void {
    const input_index: usize = @intCast(input_id);
    if (input_index >= nodes.len) return Error.UnknownNode;

    const dependents = &nodes[input_index].dependents;
    if (containsU64(dependents.*, dependent_id)) return;

    const previous_len = dependents.*.len;
    dependents.* = try allocator.realloc(dependents.*, previous_len + 1);
    dependents.*[previous_len] = dependent_id;
}

/// Provides the `removeDependent` operation.
pub fn removeDependent(comptime Record: type, allocator: std.mem.Allocator, nodes: []Node(Record), input_id: u64, dependent_id: u64) (Error || std.mem.Allocator.Error)!void {
    const input_index: usize = @intCast(input_id);
    if (input_index >= nodes.len) return Error.UnknownNode;

    const dependents = &nodes[input_index].dependents;
    for (dependents.*, 0..) |existing_id, index| {
        if (existing_id != dependent_id) continue;
        std.mem.copyForwards(u64, dependents.*[index..], dependents.*[index + 1 ..]);
        dependents.* = try allocator.realloc(dependents.*, dependents.*.len - 1);
        return;
    }

    return Error.MissingDependent;
}

/// Provides the `replaceDependent` operation.
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

/// Provides the `rank` operation.
pub fn rank(comptime Record: type, nodes: []const Node(Record), record_id: u64) Error!u64 {
    const index: usize = @intCast(record_id);
    if (index >= nodes.len) return Error.UnknownNode;
    return nodes[index].rank;
}

/// Provides the `dependentIds` operation.
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
