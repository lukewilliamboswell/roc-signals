//! Pre-reserved transaction indexes with reset work bounded by touched buckets.
const std = @import("std");

/// An auto-hashed index for borrowed transaction data. Capacity is reserved
/// before insertion; removal shifts the local collision chain so misses never
/// cross old tombstones. Reset clears only buckets touched by this transaction.
/// No keys or values require destruction here.
pub fn TransactionMap(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        const State = enum(u8) { empty, occupied, touched_empty };
        const Entry = struct { key: K, value: V };
        states: []State = &.{},
        entries: []Entry = &.{},
        touched: []u32 = &.{},
        touched_len: usize = 0,
        len: u32 = 0,
        /// Cumulative occupancy bytes written by resets, excluding constant
        /// length bookkeeping. Used by locality tests across retained sizes.
        reset_bytes: u64 = 0,

        pub const empty: Self = .{};

        /// Releases backing storage; the index never owns its keys or values.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.states);
            allocator.free(self.entries);
            allocator.free(self.touched);
            self.* = .{};
        }

        /// Returns the number of currently indexed entries.
        pub fn count(self: *const Self) u32 {
            return self.len;
        }

        /// Returns the entry bound supported without another reservation.
        pub fn capacity(self: *const Self) usize {
            return self.states.len / 5 * 4 + self.states.len % 5 * 4 / 5;
        }

        /// Reports requested backing bytes, including the reset journal.
        pub fn retainedBytes(self: *const Self) usize {
            return self.states.len * @sizeOf(State) + self.entries.len * @sizeOf(Entry) + self.touched.len * @sizeOf(u32);
        }

        /// Grows atomically before publication; refusal preserves the old
        /// index. The 80% load limit matches the standard auto hash map; local
        /// deletion keeps that occupancy bound meaningful after churn.
        pub fn ensureTotalCapacity(self: *Self, allocator: std.mem.Allocator, expected: u32) std.mem.Allocator.Error!void {
            if (expected <= self.capacity()) return;
            const scaled = std.math.mul(usize, expected, 5) catch return error.OutOfMemory;
            const needed = std.math.add(usize, scaled, 3) catch return error.OutOfMemory;
            const size = std.math.ceilPowerOfTwo(usize, @max(8, needed / 4)) catch return error.OutOfMemory;
            if (size > std.math.maxInt(u32)) return error.OutOfMemory;
            var next: Self = .{};
            errdefer next.deinit(allocator);
            next.states = try allocator.alloc(State, size);
            @memset(next.states, .empty);
            next.entries = try allocator.alloc(Entry, size);
            next.touched = try allocator.alloc(u32, size);
            for (self.touched[0..self.touched_len]) |index| {
                if (self.states[index] == .occupied) next.putAssumeCapacity(self.entries[index].key, self.entries[index].value);
            }
            next.reset_bytes = self.reset_bytes;
            self.deinit(allocator);
            self.* = next;
        }

        fn start(self: *const Self, key: K) usize {
            return @as(usize, @truncate(std.hash_map.AutoContext(K).hash(.{}, key))) & (self.states.len - 1);
        }

        fn find(self: *const Self, key: K) ?usize {
            if (self.len == 0) return null;
            var index = self.start(key);
            for (0..self.states.len) |_| {
                switch (self.states[index]) {
                    .empty, .touched_empty => return null,
                    .occupied => if (std.meta.eql(self.entries[index].key, key)) return index,
                }
                index = (index + 1) & (self.states.len - 1);
            }
            return null;
        }

        /// Finds a borrowed value without inspecting unrelated entries.
        pub fn get(self: *const Self, key: K) ?V {
            return self.entries[self.find(key) orelse return null].value;
        }

        /// Finds mutable index storage, borrowed until the next index mutation.
        pub fn getPtr(self: *Self, key: K) ?*V {
            return &self.entries[self.find(key) orelse return null].value;
        }

        /// Tests membership using the same exact-key lookup as reads.
        pub fn contains(self: *const Self, key: K) bool {
            return self.find(key) != null;
        }

        /// Inserts or replaces a borrowed entry using preflighted capacity.
        pub fn putAssumeCapacity(self: *Self, key: K, value: V) void {
            if (self.getPtr(key)) |ptr| {
                ptr.* = value;
                return;
            }
            std.debug.assert(self.len < self.capacity());
            var index = self.start(key);
            while (self.states[index] == .occupied) index = (index + 1) & (self.states.len - 1);
            if (self.states[index] == .empty) {
                self.touched[self.touched_len] = @intCast(index);
                self.touched_len += 1;
            }
            self.states[index] = .occupied;
            self.entries[index] = .{ .key = key, .value = value };
            self.len += 1;
        }

        /// Removes one entry and closes its probe-chain hole. Previously
        /// touched empty buckets remain journaled, without acting as tombstones.
        pub fn fetchRemove(self: *Self, key: K) ?Entry {
            const index = self.find(key) orelse return null;
            const removed = self.entries[index];
            var hole = index;
            self.states[hole] = .touched_empty;
            const mask = self.states.len - 1;
            var scan = (hole + 1) & mask;
            while (self.states[scan] == .occupied) : (scan = (scan + 1) & mask) {
                const home = self.start(self.entries[scan].key);
                if (((scan -% home) & mask) >= ((scan -% hole) & mask)) {
                    self.entries[hole] = self.entries[scan];
                    self.states[hole] = .occupied;
                    self.states[scan] = .touched_empty;
                    hole = scan;
                }
            }
            self.len -= 1;
            return removed;
        }

        /// Ends a transaction without allocation or a capacity-wide clear.
        /// Removed buckets are included so churn cannot accumulate across turns.
        pub fn clearRetainingCapacity(self: *Self) void {
            for (self.touched[0..self.touched_len]) |index| {
                self.states[index] = .empty;
                self.reset_bytes +|= @sizeOf(State);
            }
            self.touched_len = 0;
            self.len = 0;
        }
    };
}

test "transaction map closes collision chains across bucket wraparound" {
    for (0..4) |removed_index| {
        var map: TransactionMap(u64, u64) = .empty;
        defer map.deinit(std.testing.allocator);
        try map.ensureTotalCapacity(std.testing.allocator, 8);
        var keys: [4]u64 = undefined;
        var found: usize = 0;
        var candidate: u64 = 0;
        while (found < keys.len) : (candidate += 1) {
            if (map.start(candidate) != map.states.len - 1) continue;
            keys[found] = candidate;
            found += 1;
            map.putAssumeCapacity(candidate, candidate + 1);
        }
        _ = map.fetchRemove(keys[removed_index]);
        for (keys, 0..) |key, index| {
            if (index == removed_index) {
                try std.testing.expect(map.get(key) == null);
            } else try std.testing.expectEqual(key + 1, map.get(key).?);
        }
        map.putAssumeCapacity(keys[removed_index], 42);
        try std.testing.expectEqual(@as(u64, 42), map.get(keys[removed_index]).?);
        try std.testing.expectEqual(@as(usize, 4), map.touched_len);
    }
}

test "transaction map reset bytes follow touched entries after a large transaction" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    for ([_]u32{ 1000, 10000 }) |size| {
        var fault = FaultAllocator.init(std.testing.allocator);
        var map: TransactionMap(u64, u64) = .empty;
        defer map.deinit(fault.allocator());
        try map.ensureTotalCapacity(fault.allocator(), size);
        for (0..size) |key| map.putAssumeCapacity(key, key + 1);
        map.clearRetainingCapacity();
        fault.configure(1);
        for (0..100) |turn| {
            const before = map.reset_bytes;
            map.putAssumeCapacity(turn, turn + 1);
            try std.testing.expectEqual(turn + 1, map.get(turn).?);
            _ = map.fetchRemove(turn);
            map.putAssumeCapacity(turn, turn + 2);
            map.clearRetainingCapacity();
            try std.testing.expectEqual(@as(usize, 1), map.reset_bytes - before);
            try std.testing.expectEqual(@as(u32, 0), map.count());
            try std.testing.expect(map.get(turn) == null);
        }
        try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    }
}

test "transaction map churn and refused growth preserve collision lookup" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var fault = FaultAllocator.init(std.testing.allocator);
    var map: TransactionMap(u64, u64) = .empty;
    defer map.deinit(fault.allocator());
    try map.ensureTotalCapacity(fault.allocator(), 32);
    for (0..1000) |turn| {
        map.putAssumeCapacity(turn, turn);
        if (turn >= 16) try std.testing.expectEqual(turn - 16, map.fetchRemove(turn - 16).?.value);
        for (turn -| 15..turn + 1) |key| try std.testing.expectEqual(key, map.get(key).?);
    }
    for (1..4) |position| {
        fault.configure(position);
        try std.testing.expectError(error.OutOfMemory, map.ensureTotalCapacity(fault.allocator(), 1000));
        for (984..1000) |key| try std.testing.expectEqual(key, map.get(key).?);
    }
    fault.configure(null);
    try map.ensureTotalCapacity(fault.allocator(), 1000);
    for (984..1000) |key| try std.testing.expectEqual(key, map.get(key).?);
    map.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u32, 0), map.count());
}
