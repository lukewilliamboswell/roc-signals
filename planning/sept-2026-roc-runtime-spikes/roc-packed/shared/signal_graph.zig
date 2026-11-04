//! Generic dependency graph helpers for ranking and collecting dirty signals.
//!
//! Forward adjacency is an unordered set per input: propagation orders work by
//! rank, never by the position of an edge inside its input's list, so an edge
//! can be dropped by swapping the last entry into its slot. Every node also
//! remembers, per distinct input, the slot its own id occupies in that input's
//! list (`InputSlots`), which is what makes a single edge drop or renumber
//! O(1) instead of a scan of a hot input's whole fan-out.

const std = @import("std");

pub const Error = error{
    UnknownNode,
    MissingDependent,
};

/// Owns forward adjacency while keeping the overwhelmingly common empty and
/// singleton cases inside the graph node itself. Spilled storage is an
/// ordinary allocator-owned slice of `capacity` ids with `count` live entries
/// in its prefix, so prepared graph transactions can transfer it without
/// copying and edge drops can swap-remove without reallocating.
pub const OwnedAdjacency = struct {
    storage: u64 = 0,
    count: u32 = 0,
    /// Zero while the value is inline (at most one id lives in `storage`);
    /// otherwise the length of the spilled slice `storage` points at.
    capacity: u32 = 0,

    pub const empty: @This() = .{};

    /// Smallest spilled capacity that `shouldCompact` is willing to shrink;
    /// below it the retained slack is a few words and not worth a copy.
    pub const compaction_min_capacity: u32 = 8;

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
            else => .{ .storage = @intFromPtr(owned.ptr), .count = @intCast(owned.len), .capacity = @intCast(owned.len) },
        };
    }

    fn spilled(self: *const @This()) bool {
        return self.capacity != 0;
    }

    fn spilledSlice(self: *const @This()) []u64 {
        const ptr: [*]u64 = @ptrFromInt(@as(usize, @intCast(self.storage)));
        return ptr[0..self.capacity];
    }

    /// Borrows the live ids. Their order is not a contract: drops swap the
    /// last entry into the vacated slot.
    pub fn slice(self: *const @This()) []const u64 {
        if (self.spilled()) return self.spilledSlice()[0..self.count];
        if (self.count == 0) return &.{};
        return @as(*const [1]u64, @ptrCast(&self.storage))[0..];
    }

    /// Mutably borrows the live ids for in-place renumbering.
    pub fn mutableSlice(self: *@This()) []u64 {
        if (self.spilled()) return self.spilledSlice()[0..self.count];
        if (self.count == 0) return &.{};
        return @as(*[1]u64, @ptrCast(&self.storage))[0..];
    }

    /// Returns the number of live dependent ids.
    pub fn len(self: *const @This()) usize {
        return self.count;
    }

    /// Number of ids that can be appended before storage must grow.
    fn effectiveCapacity(self: *const @This()) usize {
        return if (self.spilled()) self.capacity else 1;
    }

    /// Grows storage so `extra` more ids can be appended without allocating.
    /// Growth is geometric so repeated single appends stay amortized O(1),
    /// and the contents are preserved, so a caller may reserve on a live list
    /// during preparation and still refuse the transaction afterwards.
    pub fn ensureUnusedCapacity(self: *@This(), allocator: std.mem.Allocator, extra: usize) std.mem.Allocator.Error!void {
        const needed = std.math.add(usize, self.count, extra) catch return error.OutOfMemory;
        if (needed <= self.effectiveCapacity()) return;
        if (needed > std.math.maxInt(u32)) return error.OutOfMemory;
        const doubled = std.math.mul(usize, self.effectiveCapacity(), 2) catch needed;
        const new_capacity: u32 = @intCast(@min(@max(needed, doubled, 2), std.math.maxInt(u32)));
        if (self.spilled()) {
            const grown = try allocator.realloc(self.spilledSlice(), new_capacity);
            self.storage = @intFromPtr(grown.ptr);
            self.capacity = new_capacity;
            return;
        }
        const fresh = try allocator.alloc(u64, new_capacity);
        if (self.count == 1) fresh[0] = self.storage;
        self.* = .{ .storage = @intFromPtr(fresh.ptr), .count = self.count, .capacity = new_capacity };
    }

    /// Number of ids that can still be appended without growing storage.
    pub fn unusedCapacity(self: *const @This()) usize {
        return self.effectiveCapacity() - self.count;
    }

    /// Copies the live ids into fresh storage with room for `extra` more,
    /// growing geometrically, and leaves this value untouched. A prepared
    /// transaction uses this when a live list lacks room, so the committed
    /// list is replaced atomically at commit instead of grown in place during
    /// preparation. Slots stay valid because the live prefix is preserved.
    pub fn cloneWithCapacity(self: *const @This(), allocator: std.mem.Allocator, extra: usize) std.mem.Allocator.Error!@This() {
        const needed = std.math.add(usize, self.count, extra) catch return error.OutOfMemory;
        if (needed > std.math.maxInt(u32)) return error.OutOfMemory;
        const doubled = std.math.mul(usize, self.effectiveCapacity(), 2) catch needed;
        const new_capacity: u32 = @intCast(@min(@max(needed, doubled, 2), std.math.maxInt(u32)));
        const fresh = try allocator.alloc(u64, new_capacity);
        @memcpy(fresh[0..self.count], self.slice());
        return .{ .storage = @intFromPtr(fresh.ptr), .count = self.count, .capacity = new_capacity };
    }

    /// Appends one id into reserved capacity and returns the slot it occupies.
    /// The caller guarantees the id is not already present; edges are unique
    /// because every call site dedups the inputs of one dependent.
    pub fn appendAssumeCapacity(self: *@This(), value: u64) u32 {
        if (self.count >= self.effectiveCapacity()) @panic("adjacency append exceeded its reserved capacity");
        const slot = self.count;
        if (self.spilled()) self.spilledSlice()[slot] = value else self.storage = value;
        self.count += 1;
        return slot;
    }

    /// Appends one unique id, growing storage when needed, and returns its slot.
    pub fn append(self: *@This(), allocator: std.mem.Allocator, value: u64) std.mem.Allocator.Error!u32 {
        try self.ensureUnusedCapacity(allocator, 1);
        return self.appendAssumeCapacity(value);
    }

    /// Removes the id at `slot` by moving the last live id into it. Returns
    /// the id that now occupies `slot`, or null when the removed id was last.
    /// Never allocates or frees; see `trim` for releasing storage.
    pub fn swapRemove(self: *@This(), slot: u32) ?u64 {
        if (slot >= self.count) @panic("adjacency swap-remove addressed a slot beyond the live entries");
        const last = self.count - 1;
        self.count = last;
        if (!self.spilled()) return null;
        const items = self.spilledSlice();
        if (slot == last) return null;
        items[slot] = items[last];
        return items[slot];
    }

    /// True when spilled storage would retain more than four times
    /// `live_after` entries (and is large enough to matter), so a transaction
    /// that drops edges should rebuild the list at its live size. Because a
    /// compaction costs O(live) and only follows at least three-quarters of
    /// the capacity worth of drops, every drop stays amortized O(1).
    pub fn shouldCompact(self: *const @This(), live_after: usize) bool {
        if (!self.spilled() or self.capacity < compaction_min_capacity) return false;
        return live_after * 4 <= self.capacity;
    }

    /// Frees spilled storage once at most one id remains, restoring the inline
    /// representation. Freeing cannot fail, so this is safe during an
    /// allocation-free commit.
    pub fn trim(self: *@This(), allocator: std.mem.Allocator) void {
        if (!self.spilled() or self.count > 1) return;
        const items = self.spilledSlice();
        const value = if (self.count == 1) items[0] else 0;
        const count = self.count;
        allocator.free(items);
        self.* = .{ .storage = value, .count = count };
    }

    /// Releases spilled storage and restores the inline empty state.
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.spilled()) allocator.free(self.spilledSlice());
        self.* = .{};
    }
};

/// The slot a node's id occupies in each of its distinct inputs' adjacency
/// lists, indexed by input position (the order in which the node's payload
/// enumerates its distinct inputs). Up to two positions live inline, which
/// covers `map`, `select` and `map2` without an allocation; wider `combine`
/// nodes spill to an allocator-owned slice sized once at node creation.
pub const InputSlots = struct {
    storage: u64 = 0,
    count: u32 = 0,

    pub const empty: @This() = .{};

    const inline_capacity = 2;

    /// Allocates slot storage for a node with `arity` distinct inputs.
    pub fn init(allocator: std.mem.Allocator, arity: usize) std.mem.Allocator.Error!@This() {
        if (arity > std.math.maxInt(u32)) return error.OutOfMemory;
        if (arity <= inline_capacity) return .{ .count = @intCast(arity) };
        const owned = try allocator.alloc(u32, arity);
        @memset(owned, 0);
        return .{ .storage = @intFromPtr(owned.ptr), .count = @intCast(arity) };
    }

    fn spilled(self: *const @This()) bool {
        return self.count > inline_capacity;
    }

    fn spilledSlice(self: *const @This()) []u32 {
        const ptr: [*]u32 = @ptrFromInt(@as(usize, @intCast(self.storage)));
        return ptr[0..self.count];
    }

    /// Number of distinct input positions this node has.
    pub fn len(self: *const @This()) usize {
        return self.count;
    }

    /// Returns the adjacency slot recorded for input `position`.
    pub fn get(self: *const @This(), position: u32) u32 {
        if (position >= self.count) @panic("input slot position exceeded the node's arity");
        if (self.spilled()) return self.spilledSlice()[position];
        return @truncate(self.storage >> @intCast(32 * position));
    }

    /// Records the adjacency slot for input `position`.
    pub fn set(self: *@This(), position: u32, slot: u32) void {
        if (position >= self.count) @panic("input slot position exceeded the node's arity");
        if (self.spilled()) {
            self.spilledSlice()[position] = slot;
            return;
        }
        const shift: u6 = @intCast(32 * position);
        self.storage = (self.storage & ~(@as(u64, std.math.maxInt(u32)) << shift)) | (@as(u64, slot) << shift);
    }

    /// Releases spilled storage.
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.spilled()) allocator.free(self.spilledSlice());
        self.* = .{};
    }
};

/// Defines one dependency-graph node with its stored rank, forward adjacency,
/// and the slots its own id occupies in each input's adjacency.
pub fn Node(comptime Record: type) type {
    return struct {
        record: *Record,
        rank: u64 = 0,
        dependents: OwnedAdjacency = .empty,
        input_slots: InputSlots = .empty,
    };
}

/// Appends the edge `input_id -> dependent_id` and records the slot it landed
/// in at the dependent's `input_position`. The edge must not already exist:
/// call sites enumerate each dependent's distinct inputs exactly once.
pub fn appendDependent(comptime Record: type, allocator: std.mem.Allocator, nodes: []Node(Record), input_id: u64, dependent_id: u64, input_position: u32) (Error || std.mem.Allocator.Error)!void {
    if (input_id >= nodes.len or dependent_id >= nodes.len) return Error.UnknownNode;
    const slot = try nodes[@intCast(input_id)].dependents.append(allocator, dependent_id);
    nodes[@intCast(dependent_id)].input_slots.set(input_position, slot);
}

/// Appends an edge into capacity the caller already reserved on the input's
/// adjacency, recording the slot at the dependent's `input_position`.
pub fn appendDependentAssumeCapacity(comptime Record: type, nodes: []Node(Record), input_id: u64, dependent_id: u64, input_position: u32) Error!void {
    if (input_id >= nodes.len or dependent_id >= nodes.len) return Error.UnknownNode;
    const slot = nodes[@intCast(input_id)].dependents.appendAssumeCapacity(dependent_id);
    nodes[@intCast(dependent_id)].input_slots.set(input_position, slot);
}

/// Drops the edge `input_id -> dependent_id` through the dependent's recorded
/// slot, then repairs the slot of whichever id was swapped into the hole. The
/// `resolver` answers `inputPosition(nodes, moved_id, input_id)` for that
/// moved dependent, so the cost is O(1) plus the moved node's arity. Never
/// allocates or frees; the input keeps its capacity until `trim`.
pub fn unlinkDependent(comptime Record: type, nodes: []Node(Record), input_id: u64, dependent_id: u64, input_position: u32, resolver: anytype) Error!void {
    if (input_id >= nodes.len or dependent_id >= nodes.len) return Error.UnknownNode;
    const dependents = &nodes[@intCast(input_id)].dependents;
    const slot = nodes[@intCast(dependent_id)].input_slots.get(input_position);
    if (slot >= dependents.len() or dependents.slice()[slot] != dependent_id) return Error.MissingDependent;
    if (dependents.swapRemove(slot)) |moved_id| {
        if (moved_id >= nodes.len) return Error.UnknownNode;
        const moved_position = resolver.inputPosition(nodes, moved_id, input_id);
        nodes[@intCast(moved_id)].input_slots.set(moved_position, slot);
    }
}

/// Drops one edge and releases the input's spilled storage if the drop left
/// it inline-sized. Allocation-free.
pub fn removeDependent(comptime Record: type, allocator: std.mem.Allocator, nodes: []Node(Record), input_id: u64, dependent_id: u64, input_position: u32, resolver: anytype) Error!void {
    try unlinkDependent(Record, nodes, input_id, dependent_id, input_position, resolver);
    nodes[@intCast(input_id)].dependents.trim(allocator);
}

/// Renumbers the edge `input_id -> old_dependent_id` to `new_dependent_id`
/// through the slot recorded on the dependent's node, which lives at
/// `dependent_node_id` (its original slot before a dense move, or its new
/// slot after one). O(1).
pub fn replaceDependent(comptime Record: type, nodes: []Node(Record), input_id: u64, dependent_node_id: u64, input_position: u32, old_dependent_id: u64, new_dependent_id: u64) Error!void {
    if (input_id >= nodes.len or dependent_node_id >= nodes.len) return Error.UnknownNode;
    const slot = nodes[@intCast(dependent_node_id)].input_slots.get(input_position);
    const dependents = nodes[@intCast(input_id)].dependents.mutableSlice();
    if (slot >= dependents.len or dependents[slot] != old_dependent_id) return Error.MissingDependent;
    dependents[slot] = new_dependent_id;
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

const TestRecord = struct {
    id: u64,
    /// Distinct inputs in position order; the test resolver reads it.
    inputs: []const u64 = &.{},
};

const TestResolver = struct {
    /// Finds `input_id` in the dependent test record's explicit input list.
    pub fn inputPosition(_: @This(), nodes: []const Node(TestRecord), dependent_id: u64, input_id: u64) u32 {
        for (nodes[@intCast(dependent_id)].record.inputs, 0..) |input, position| if (input == input_id) return @intCast(position);
        @panic("test dependent did not list the input");
    }
};

fn initTestNodes(comptime count: usize, records: *[count]TestRecord) ![count]Node(TestRecord) {
    var nodes: [count]Node(TestRecord) = undefined;
    for (&nodes, records, 0..) |*node, *record, index| {
        node.* = .{ .record = record, .rank = @intCast(index), .input_slots = try InputSlots.init(std.testing.allocator, record.inputs.len) };
    }
    return nodes;
}

fn deinitTestNodes(nodes: []Node(TestRecord)) void {
    for (nodes) |*node| {
        node.dependents.deinit(std.testing.allocator);
        node.input_slots.deinit(std.testing.allocator);
    }
}

fn expectSlotsCoherent(nodes: []const Node(TestRecord)) !void {
    for (nodes, 0..) |node, index| {
        for (node.record.inputs, 0..) |input, position| {
            const slot = node.input_slots.get(@intCast(position));
            const dependents = nodes[@intCast(input)].dependents.slice();
            try std.testing.expect(slot < dependents.len);
            try std.testing.expectEqual(@as(u64, @intCast(index)), dependents[slot]);
        }
    }
}

test "owned adjacency keeps the common singleton edge allocation free" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var fault = FaultAllocator.init(std.testing.allocator);
    var adjacency: OwnedAdjacency = .empty;
    defer adjacency.deinit(fault.allocator());

    try std.testing.expectEqual(@sizeOf([]u64), @sizeOf(OwnedAdjacency));

    fault.configure(1);
    try std.testing.expectEqual(@as(u32, 0), try adjacency.append(fault.allocator(), 7));
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqualSlices(u64, &.{7}, adjacency.slice());

    try std.testing.expectError(error.OutOfMemory, adjacency.append(fault.allocator(), 9));
    try std.testing.expectEqualSlices(u64, &.{7}, adjacency.slice());

    fault.configure(null);
    try std.testing.expectEqual(@as(u32, 1), try adjacency.append(fault.allocator(), 9));
    try std.testing.expectEqualSlices(u64, &.{ 7, 9 }, adjacency.slice());
}

test "owned adjacency grows geometrically, swap-removes in place, and trims to inline" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var fault = FaultAllocator.init(std.testing.allocator);
    var adjacency: OwnedAdjacency = .empty;
    defer adjacency.deinit(fault.allocator());

    for (0..64) |value| _ = try adjacency.append(fault.allocator(), @intCast(value));
    // 1 (inline) -> 2 -> 4 -> 8 -> 16 -> 32 -> 64: six growth steps (each
    // realloc may try remap then alloc), not one reallocation per append.
    try std.testing.expect(fault.attempts <= 11);
    try std.testing.expectEqual(@as(usize, 64), adjacency.len());
    try std.testing.expect(!adjacency.shouldCompact(64));

    // Dropping a middle slot moves the last id into it without touching the allocator.
    fault.configure(1);
    try std.testing.expectEqual(@as(?u64, 63), adjacency.swapRemove(5));
    try std.testing.expectEqual(@as(u64, 63), adjacency.slice()[5]);
    try std.testing.expectEqual(@as(?u64, null), adjacency.swapRemove(62));
    try std.testing.expectEqual(@as(usize, 62), adjacency.len());
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);

    // Compaction becomes due once live entries fall to a quarter of capacity.
    try std.testing.expect(!adjacency.shouldCompact(17));
    try std.testing.expect(adjacency.shouldCompact(16));
    while (adjacency.len() > 16) _ = adjacency.swapRemove(0);
    while (adjacency.len() > 1) _ = adjacency.swapRemove(0);
    const survivor = adjacency.slice()[0];
    adjacency.trim(fault.allocator());
    try std.testing.expectEqual(@as(u32, 0), adjacency.capacity);
    try std.testing.expectEqualSlices(u64, &.{survivor}, adjacency.slice());
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    fault.configure(null);
}

test "input slots pack two positions inline and spill wider arities" {
    var two = try InputSlots.init(std.testing.allocator, 2);
    defer two.deinit(std.testing.allocator);
    two.set(0, 0xAAAA_0001);
    two.set(1, 0x5555_0002);
    try std.testing.expectEqual(@as(u32, 0xAAAA_0001), two.get(0));
    try std.testing.expectEqual(@as(u32, 0x5555_0002), two.get(1));
    two.set(0, 3);
    try std.testing.expectEqual(@as(u32, 3), two.get(0));
    try std.testing.expectEqual(@as(u32, 0x5555_0002), two.get(1));

    var five = try InputSlots.init(std.testing.allocator, 5);
    defer five.deinit(std.testing.allocator);
    for (0..5) |position| five.set(@intCast(position), @intCast(position * 10));
    for (0..5) |position| try std.testing.expectEqual(@as(u32, @intCast(position * 10)), five.get(@intCast(position)));
}

test "signal graph edges drop and renumber through per-edge slots" {
    var records = [_]TestRecord{
        .{ .id = 0 },
        .{ .id = 1, .inputs = &.{0} },
        .{ .id = 2, .inputs = &.{0} },
        .{ .id = 3, .inputs = &.{ 0, 2 } },
        .{ .id = 4, .inputs = &.{0} },
    };
    var nodes = try initTestNodes(5, &records);
    defer deinitTestNodes(&nodes);

    try appendDependent(TestRecord, std.testing.allocator, &nodes, 0, 1, 0);
    try appendDependent(TestRecord, std.testing.allocator, &nodes, 0, 2, 0);
    try appendDependent(TestRecord, std.testing.allocator, &nodes, 0, 3, 0);
    try appendDependent(TestRecord, std.testing.allocator, &nodes, 2, 3, 1);
    try appendDependent(TestRecord, std.testing.allocator, &nodes, 0, 4, 0);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 3, 4 }, nodes[0].dependents.slice());
    try expectSlotsCoherent(&nodes);

    // Dropping 2 swaps 4 into slot 1 and repairs 4's recorded slot.
    try removeDependent(TestRecord, std.testing.allocator, &nodes, 0, 2, 0, TestResolver{});
    records[2].inputs = &.{};
    try std.testing.expectEqualSlices(u64, &.{ 1, 4, 3 }, nodes[0].dependents.slice());
    try std.testing.expectEqual(@as(u32, 1), nodes[4].input_slots.get(0));
    try std.testing.expectError(Error.MissingDependent, removeDependent(TestRecord, std.testing.allocator, &nodes, 0, 2, 0, TestResolver{}));

    // Renumbering 3 -> 9 touches only its slot.
    try replaceDependent(TestRecord, &nodes, 0, 3, 0, 3, 9);
    try std.testing.expectEqualSlices(u64, &.{ 1, 4, 9 }, nodes[0].dependents.slice());
    try std.testing.expectError(Error.MissingDependent, replaceDependent(TestRecord, &nodes, 0, 3, 0, 3, 9));
    try replaceDependent(TestRecord, &nodes, 0, 3, 0, 9, 3);
    try expectSlotsCoherent(&nodes);

    // Draining to one survivor releases the spilled storage without allocating.
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var fault = FaultAllocator.init(std.testing.allocator);
    fault.configure(1);
    try removeDependent(TestRecord, fault.allocator(), &nodes, 0, 1, 0, TestResolver{});
    try removeDependent(TestRecord, fault.allocator(), &nodes, 0, 4, 0, TestResolver{});
    records[1].inputs = &.{};
    records[4].inputs = &.{};
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqual(@as(u32, 0), nodes[0].dependents.capacity);
    try std.testing.expectEqualSlices(u64, &.{3}, nodes[0].dependents.slice());
    try expectSlotsCoherent(&nodes);
}
