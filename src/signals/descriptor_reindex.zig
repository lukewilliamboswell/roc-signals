//! Sparse index changes caused by descending swap-removal of descriptor lanes.
//! Unmoved entries need no storage or visit, even when the lane is very wide.
const std = @import("std");

pub const Move = struct { original: usize, final: usize };

/// Borrows the descending removal journal and owns only displaced survivors.
/// The journal must remain alive and unchanged until this plan is destroyed.
pub const Plan = struct {
    allocator: std.mem.Allocator,
    removed: []const usize,
    moves: []Move,
    final_indexes: std.AutoHashMapUnmanaged(usize, usize),
    remaining: usize,

    /// Simulates the descriptor lane's exact swap-removal order in O(removed)
    /// expected work. Duplicate, unordered, and out-of-range removals are errors.
    pub fn prepare(allocator: std.mem.Allocator, count: usize, removed: []const usize) error{ OutOfMemory, InvalidDescriptor, ResourceLimit }!Plan {
        var slots: std.AutoHashMapUnmanaged(usize, usize) = .empty;
        errdefer slots.deinit(allocator);
        try slots.ensureTotalCapacity(allocator, std.math.cast(u32, removed.len) orelse return error.ResourceLimit);
        var remaining = count;
        var previous = count;
        for (removed) |index| {
            if (index >= remaining or index >= previous) return error.InvalidDescriptor;
            previous = index;
            remaining -= 1;
            const original = if (slots.fetchRemove(remaining)) |slot| slot.value else remaining;
            if (index != remaining) slots.putAssumeCapacity(index, original);
        }
        const moves = try allocator.alloc(Move, slots.count());
        errdefer allocator.free(moves);
        var iterator = slots.iterator();
        var cursor: usize = 0;
        while (iterator.next()) |slot| {
            moves[cursor] = .{ .original = slot.value_ptr.*, .final = slot.key_ptr.* };
            cursor += 1;
        }
        slots.clearRetainingCapacity();
        for (moves) |move| slots.putAssumeCapacity(move.original, move.final);
        return .{ .allocator = allocator, .removed = removed, .moves = moves, .final_indexes = slots, .remaining = remaining };
    }

    /// Resolves a surviving original index without enumerating unaffected entries.
    /// Removed identities return null, including a removed last lane entry.
    pub fn finalIndex(self: *const Plan, original: usize) ?usize {
        var left: usize = 0;
        var right = self.removed.len;
        while (left < right) {
            const middle = left + (right - left) / 2;
            const value = self.removed[middle];
            if (value == original) return null;
            if (value > original) left = middle + 1 else right = middle;
        }
        return self.final_indexes.get(original) orelse original;
    }

    /// Releases preparation storage; the borrowed removal journal stays owned
    /// by the surrounding structural transaction.
    pub fn deinit(self: *Plan) void {
        self.allocator.free(self.moves);
        self.final_indexes.deinit(self.allocator);
    }
};

test "sparse descriptor reindex matches every removal subset of a dense lane" {
    for (0..256) |mask| {
        var removals: [8]usize = undefined;
        var removed_len: usize = 0;
        var reference = [_]usize{ 0, 1, 2, 3, 4, 5, 6, 7 };
        var remaining: usize = 8;
        for (0..8) |offset| {
            const index = 7 - offset;
            if (mask & (@as(usize, 1) << @intCast(index)) == 0) continue;
            removals[removed_len] = index;
            removed_len += 1;
            remaining -= 1;
            reference[index] = reference[remaining];
        }
        var plan = try Plan.prepare(std.testing.allocator, 8, removals[0..removed_len]);
        defer plan.deinit();
        try std.testing.expectEqual(remaining, plan.remaining);
        for (0..8) |original| {
            const expected = std.mem.indexOfScalar(usize, reference[0..remaining], original);
            try std.testing.expectEqual(expected, plan.finalIndex(original));
        }
    }
}

test "sparse descriptor reindex retains only changed entries in a wide lane" {
    var plan = try Plan.prepare(std.testing.allocator, 1000000, &.{3});
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 1), plan.moves.len);
    try std.testing.expectEqual(@as(usize, 1), plan.final_indexes.count());
    try std.testing.expectEqual(@as(?usize, 3), plan.finalIndex(999999));
    try std.testing.expectEqual(@as(?usize, 999998), plan.finalIndex(999998));
    try std.testing.expectEqual(null, plan.finalIndex(3));
}

test "sparse descriptor reindex rejects invalid removal journals" {
    try std.testing.expectError(error.InvalidDescriptor, Plan.prepare(std.testing.allocator, 5, &.{ 1, 3 }));
    try std.testing.expectError(error.InvalidDescriptor, Plan.prepare(std.testing.allocator, 5, &.{ 3, 3 }));
    try std.testing.expectError(error.InvalidDescriptor, Plan.prepare(std.testing.allocator, 5, &.{5}));
}

fn prepareWithFailure(allocator: std.mem.Allocator) !void {
    var plan = try Plan.prepare(allocator, 10000, &.{ 9, 7, 3 });
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 9997), plan.remaining);
}

test "sparse descriptor reindex releases all allocation refusals" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, prepareWithFailure, .{});
}
