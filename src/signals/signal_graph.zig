//! Generic dependency graph helpers for ranking and collecting dirty signals.

const std = @import("std");

pub const Error = error{
    UnknownNode,
    MissingDependent,
};

/// Owns forward adjacency while keeping the overwhelmingly common empty and
/// singleton cases inside the graph node itself. Spilled storage remains an
/// ordinary allocator-owned slice so prepared graph transactions can transfer
/// it without copying.
pub const OwnedAdjacency = struct {
    storage: u64 = 0,
    count: usize = 0,

    pub const empty: @This() = .{};

    /// Adopts an allocator-owned slice, freeing redundant storage when its
    /// contents fit inline. The caller transfers ownership in every case.
    pub fn adopt(allocator: std.mem.Allocator, owned: []u64) @This() {
        return switch (owned.len) {
            0 => blk: {
                allocator.free(owned);
                break :blk .{};
            },
            1 => blk: {
                const value = owned[0];
                allocator.free(owned);
                break :blk .{ .storage = value, .count = 1 };
            },
            else => .{ .storage = @intFromPtr(owned.ptr), .count = owned.len },
        };
    }

    /// Borrows the stored ids in insertion order.
    pub fn slice(self: *const @This()) []const u64 {
        if (self.count == 0) return &.{};
        if (self.count == 1) return @as(*const [1]u64, @ptrCast(&self.storage))[0..];
        const ptr: [*]const u64 = @ptrFromInt(@as(usize, @intCast(self.storage)));
        return ptr[0..self.count];
    }

    /// Mutably borrows the stored ids for dense-id remapping.
    pub fn mutableSlice(self: *@This()) []u64 {
        if (self.count == 0) return &.{};
        if (self.count == 1) return @as(*[1]u64, @ptrCast(&self.storage))[0..];
        const ptr: [*]u64 = @ptrFromInt(@as(usize, @intCast(self.storage)));
        return ptr[0..self.count];
    }

    /// Returns the number of stored dependent ids.
    pub fn len(self: *const @This()) usize {
        return self.slice().len;
    }

    /// Appends one unique edge while avoiding allocation until a node fans out
    /// to a second dependent.
    pub fn append(self: *@This(), allocator: std.mem.Allocator, value: u64) std.mem.Allocator.Error!void {
        if (self.count == 0) {
            self.* = .{ .storage = value, .count = 1 };
            return;
        }
        if (self.count == 1) {
            const replacement = try allocator.alloc(u64, 2);
            replacement[0] = self.storage;
            replacement[1] = value;
            self.* = .{ .storage = @intFromPtr(replacement.ptr), .count = 2 };
            return;
        }
        const current = self.mutableSlice();
        const replacement = try allocator.realloc(current, self.count + 1);
        replacement[self.count] = value;
        self.* = .{ .storage = @intFromPtr(replacement.ptr), .count = replacement.len };
    }

    /// Releases spilled storage and restores the inline empty state.
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.count > 1) allocator.free(self.mutableSlice());
        self.* = .{};
    }
};

/// Defines one dependency-graph node with its stored rank and forward adjacency.
pub fn Node(comptime Record: type) type {
    return struct {
        record: *Record,
        rank: u64 = 0,
        dependents: OwnedAdjacency = .empty,
    };
}

/// Appends dependent using capacity that must already satisfy the caller's transaction contract.
pub fn appendDependent(comptime Record: type, allocator: std.mem.Allocator, nodes: []Node(Record), input_id: u64, dependent_id: u64) (Error || std.mem.Allocator.Error)!void {
    const input_index: usize = @intCast(input_id);
    if (input_index >= nodes.len) return Error.UnknownNode;

    const dependents = &nodes[input_index].dependents;
    if (containsU64(dependents.slice(), dependent_id)) return;

    try dependents.append(allocator, dependent_id);
}

/// Removes dependent and releases the ownership attached to that live entry.
pub fn removeDependent(comptime Record: type, allocator: std.mem.Allocator, nodes: []Node(Record), input_id: u64, dependent_id: u64) (Error || std.mem.Allocator.Error)!void {
    var prepared = try prepareDependentRemoval(Record, allocator, nodes, input_id, dependent_id);
    defer prepared.deinit(allocator);
    var retired = prepared.apply(Record, nodes);
    retired.deinit(allocator);
}

/// Owns replacement adjacency until an allocation-free edge-removal commit.
pub const PreparedDependentRemoval = struct {
    input_id: u64,
    ownership: union(enum) {
        prepared: OwnedAdjacency,
        committed,
    },

    /// Releases provisional replacement storage on abort.
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        switch (self.ownership) {
            .prepared => |*replacement| replacement.deinit(allocator),
            .committed => {},
        }
        self.* = undefined;
    }

    /// Swaps prepared adjacency into the live node and returns displaced ownership.
    pub fn apply(self: *@This(), comptime Record: type, nodes: []Node(Record)) OwnedAdjacency {
        const replacement = switch (self.ownership) {
            .prepared => |value| value,
            .committed => @panic("dependent removal was already committed"),
        };
        const index: usize = @intCast(self.input_id);
        if (index >= nodes.len) @panic("prepared dependent removal referenced an unknown node");
        const retired = nodes[index].dependents;
        nodes[index].dependents = replacement;
        self.ownership = .committed;
        return retired;
    }
};

/// Copies surviving adjacency before mutation so edge removal can commit atomically.
pub fn prepareDependentRemoval(comptime Record: type, allocator: std.mem.Allocator, nodes: []const Node(Record), input_id: u64, dependent_id: u64) (Error || std.mem.Allocator.Error)!PreparedDependentRemoval {
    const input_index: usize = @intCast(input_id);
    if (input_index >= nodes.len) return Error.UnknownNode;
    const existing = nodes[input_index].dependents.slice();
    var found = false;
    for (existing) |id| if (id == dependent_id) {
        found = true;
        break;
    };
    if (!found) return Error.MissingDependent;
    if (existing.len == 1) return .{ .input_id = input_id, .ownership = .{ .prepared = .empty } };
    if (existing.len == 2) {
        const survivor = if (existing[0] == dependent_id) existing[1] else existing[0];
        return .{ .input_id = input_id, .ownership = .{ .prepared = .{ .storage = survivor, .count = 1 } } };
    }
    const replacement = try allocator.alloc(u64, existing.len - 1);
    var write_index: usize = 0;
    for (existing) |id| {
        if (id == dependent_id) continue;
        replacement[write_index] = id;
        write_index += 1;
    }
    return .{ .input_id = input_id, .ownership = .{ .prepared = OwnedAdjacency.adopt(allocator, replacement) } };
}

/// Replaces dependent while releasing displaced ownership exactly once.
pub fn replaceDependent(comptime Record: type, nodes: []Node(Record), input_id: u64, old_dependent_id: u64, new_dependent_id: u64) Error!void {
    const input_index: usize = @intCast(input_id);
    if (input_index >= nodes.len) return Error.UnknownNode;

    const dependents = nodes[input_index].dependents.mutableSlice();
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
    return nodes[index].dependents.slice();
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

test "owned adjacency keeps the common singleton edge allocation free" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var fault = FaultAllocator.init(std.testing.allocator);
    var adjacency: OwnedAdjacency = .empty;
    defer adjacency.deinit(fault.allocator());

    try std.testing.expectEqual(@sizeOf([]u64), @sizeOf(OwnedAdjacency));

    fault.configure(1);
    try adjacency.append(fault.allocator(), 7);
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqualSlices(u64, &.{7}, adjacency.slice());

    try std.testing.expectError(error.OutOfMemory, adjacency.append(fault.allocator(), 9));
    try std.testing.expectEqualSlices(u64, &.{7}, adjacency.slice());

    fault.configure(null);
    try adjacency.append(fault.allocator(), 9);
    try std.testing.expectEqualSlices(u64, &.{ 7, 9 }, adjacency.slice());
}

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
            node.dependents.deinit(std.testing.allocator);
        }
    }

    try appendDependent(TestRecord, std.testing.allocator, &nodes, 0, 1);
    try appendDependent(TestRecord, std.testing.allocator, &nodes, 0, 1);
    try appendDependent(TestRecord, std.testing.allocator, &nodes, 0, 2);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2 }, nodes[0].dependents.slice());

    try replaceDependent(TestRecord, &nodes, 0, 2, 3);
    try std.testing.expectEqualSlices(u64, &.{ 1, 3 }, nodes[0].dependents.slice());

    try removeDependent(TestRecord, std.testing.allocator, &nodes, 0, 1);
    try std.testing.expectEqualSlices(u64, &.{3}, nodes[0].dependents.slice());
}

test "prepared dependent removal leaves adjacency atomic under allocation faults" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var records = [_]TestRecord{ .{ .id = 0 }, .{ .id = 1 }, .{ .id = 2 } };
    var nodes = [_]Node(TestRecord){
        .{ .record = &records[0], .dependents = OwnedAdjacency.adopt(std.testing.allocator, try std.testing.allocator.dupe(u64, &.{ 1, 2, 3 })) },
        .{ .record = &records[1] },
        .{ .record = &records[2] },
    };
    defer for (&nodes) |*node| node.dependents.deinit(std.testing.allocator);

    var failing = FaultAllocator.init(std.testing.allocator);
    failing.configure(1);
    try std.testing.expectError(error.OutOfMemory, prepareDependentRemoval(TestRecord, failing.allocator(), &nodes, 0, 1));
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 3 }, nodes[0].dependents.slice());

    var fault = FaultAllocator.init(std.testing.allocator);
    var prepared = try prepareDependentRemoval(TestRecord, fault.allocator(), &nodes, 0, 1);
    defer prepared.deinit(fault.allocator());
    fault.configure(1);
    const retired = prepared.apply(TestRecord, &nodes);
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqualSlices(u64, &.{ 2, 3 }, nodes[0].dependents.slice());
    var owned_retired = retired;
    owned_retired.deinit(std.testing.allocator);
}
