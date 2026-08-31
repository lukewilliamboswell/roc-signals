//! Stable, generation-checked identities for keyed rows.
//!
//! A handle encodes a one-based slot index in its low 32 bits and a slot
//! generation in its high 32 bits. Neither field may be zero. Reusing a free
//! slot increments its generation, so a handle from an earlier row lifetime
//! cannot resolve to the new occupant. A slot whose generation reaches the
//! maximum `u32` value is permanently retired instead of wrapping.

const std = @import("std");

const index_bits = 32;
const max_slot_count: usize = std.math.maxInt(u32);

/// Nominal identity of one live keyed row.
pub const RowHandleId = enum(u64) {
    _,

    /// Returns the packed representation used at internal ABI boundaries.
    pub fn raw(self: RowHandleId) u64 {
        return @intFromEnum(self);
    }

    /// Reconstructs a handle from an already validated internal representation.
    pub fn fromRaw(raw_value: u64) RowHandleId {
        return @enumFromInt(raw_value);
    }

    fn init(slot_index: usize, slot_generation: u32) RowHandleId {
        if (slot_generation == 0 or slot_index >= max_slot_count) @panic("invalid row handle fields");
        const one_based_index: u32 = @intCast(slot_index + 1);
        return @enumFromInt((@as(u64, slot_generation) << index_bits) | one_based_index);
    }

    fn generation(self: RowHandleId) u32 {
        return @truncate(self.raw() >> index_bits);
    }

    fn slotIndex(self: RowHandleId) ?usize {
        const one_based_index: u32 = @truncate(self.raw());
        if (one_based_index == 0 or self.generation() == 0) return null;
        return @as(usize, one_based_index - 1);
    }
};

pub const LookupError = error{InvalidRowHandle};
pub const InsertError = std.mem.Allocator.Error || error{ResourceLimit};

/// Defines an O(1) slot registry for row-owned engine metadata.
pub fn Registry(comptime Payload: type) type {
    return struct {
        const Self = @This();

        const State = union(enum) {
            active: Payload,
            free: ?u32,
            retired,
        };

        const Slot = struct {
            generation: u32 = 1,
            state: State,
        };

        slots: std.ArrayListUnmanaged(Slot) = .empty,
        free_head: ?u32 = null,
        slot_limit: usize = max_slot_count,

        /// Creates an empty registry using the full representable slot range.
        pub fn init() Self {
            return .{};
        }

        /// Creates an empty registry with a smaller explicit resource limit.
        pub fn initWithLimit(limit: usize) Self {
            return .{ .slot_limit = @min(limit, max_slot_count) };
        }

        /// Releases registry storage. Payload-owned resources must be released
        /// by their engine owner before calling this function.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.slots.deinit(allocator);
            self.* = undefined;
        }

        /// Inserts one payload and returns its stable, generation-checked handle.
        pub fn insert(self: *Self, allocator: std.mem.Allocator, payload: Payload) InsertError!RowHandleId {
            if (self.free_head) |free_index| {
                const index: usize = free_index;
                if (index >= self.slots.items.len) @panic("row handle free list exceeded slot storage");
                const slot = &self.slots.items[index];
                const next = switch (slot.state) {
                    .free => |value| value,
                    .active, .retired => @panic("row handle free list referenced a non-free slot"),
                };
                if (slot.generation == 0 or slot.generation == std.math.maxInt(u32)) {
                    @panic("row handle free list contained an unusable generation");
                }
                self.free_head = next;
                slot.state = .{ .active = payload };
                return RowHandleId.init(index, slot.generation);
            }

            if (self.slots.items.len >= self.slot_limit or self.slots.items.len >= max_slot_count) {
                return error.ResourceLimit;
            }
            const index = self.slots.items.len;
            try self.slots.append(allocator, .{ .state = .{ .active = payload } });
            return RowHandleId.init(index, 1);
        }

        /// Returns mutable metadata only when both slot and generation match.
        pub fn get(self: *Self, handle: RowHandleId) LookupError!*Payload {
            const index = handle.slotIndex() orelse return error.InvalidRowHandle;
            if (index >= self.slots.items.len) return error.InvalidRowHandle;
            const slot = &self.slots.items[index];
            if (slot.generation != handle.generation()) return error.InvalidRowHandle;
            return switch (slot.state) {
                .active => |*payload| payload,
                .free, .retired => error.InvalidRowHandle,
            };
        }

        /// Returns immutable metadata only when both slot and generation match.
        pub fn getConst(self: *const Self, handle: RowHandleId) LookupError!*const Payload {
            const index = handle.slotIndex() orelse return error.InvalidRowHandle;
            if (index >= self.slots.items.len) return error.InvalidRowHandle;
            const slot = &self.slots.items[index];
            if (slot.generation != handle.generation()) return error.InvalidRowHandle;
            return switch (slot.state) {
                .active => |*payload| payload,
                .free, .retired => error.InvalidRowHandle,
            };
        }

        /// Removes one live payload. Reusable slots advance their generation;
        /// saturated slots retire permanently and never enter the free list.
        pub fn remove(self: *Self, handle: RowHandleId) LookupError!Payload {
            const index = handle.slotIndex() orelse return error.InvalidRowHandle;
            if (index >= self.slots.items.len) return error.InvalidRowHandle;
            const slot = &self.slots.items[index];
            if (slot.generation != handle.generation()) return error.InvalidRowHandle;
            const payload = switch (slot.state) {
                .active => |value| value,
                .free, .retired => return error.InvalidRowHandle,
            };

            if (slot.generation == std.math.maxInt(u32)) {
                slot.state = .retired;
            } else {
                slot.generation += 1;
                slot.state = .{ .free = self.free_head };
                self.free_head = @intCast(index);
            }
            return payload;
        }

        /// Reports whether this exact generation is currently live.
        pub fn contains(self: *const Self, handle: RowHandleId) bool {
            _ = self.getConst(handle) catch return false;
            return true;
        }
    };
}

test "row handles encode nonzero generation and one-based slot" {
    var registry = Registry(u64).init();
    defer registry.deinit(std.testing.allocator);

    const first = try registry.insert(std.testing.allocator, 10);
    const second = try registry.insert(std.testing.allocator, 20);
    try std.testing.expectEqual(@as(u64, 0x0000_0001_0000_0001), first.raw());
    try std.testing.expectEqual(@as(u64, 0x0000_0001_0000_0002), second.raw());
    try std.testing.expectEqual(@as(u64, 10), (try registry.getConst(first)).*);
    (try registry.get(second)).* = 21;
    try std.testing.expectEqual(@as(u64, 21), (try registry.getConst(second)).*);
}

test "removed row handles are stale and slots reuse in constant time" {
    var registry = Registry(u32).init();
    defer registry.deinit(std.testing.allocator);

    const first = try registry.insert(std.testing.allocator, 11);
    const second = try registry.insert(std.testing.allocator, 22);
    try std.testing.expectEqual(@as(u32, 11), try registry.remove(first));
    try std.testing.expectError(error.InvalidRowHandle, registry.get(first));
    try std.testing.expectError(error.InvalidRowHandle, registry.remove(first));

    const reused = try registry.insert(std.testing.allocator, 33);
    try std.testing.expectEqual(@as(u64, 0x0000_0002_0000_0001), reused.raw());
    try std.testing.expect(!registry.contains(first));
    try std.testing.expect(registry.contains(reused));
    try std.testing.expectEqual(@as(u32, 22), (try registry.getConst(second)).*);
    try std.testing.expectEqual(@as(u32, 33), (try registry.getConst(reused)).*);
}

test "zero fields and cross-generation handles are rejected" {
    var registry = Registry(u8).init();
    defer registry.deinit(std.testing.allocator);
    const live = try registry.insert(std.testing.allocator, 7);

    try std.testing.expectError(error.InvalidRowHandle, registry.get(RowHandleId.fromRaw(0)));
    try std.testing.expectError(error.InvalidRowHandle, registry.get(RowHandleId.fromRaw(1)));
    try std.testing.expectError(error.InvalidRowHandle, registry.get(RowHandleId.fromRaw(@as(u64, 1) << 32)));
    try std.testing.expectError(error.InvalidRowHandle, registry.get(RowHandleId.fromRaw((@as(u64, 2) << 32) | 1)));
    try std.testing.expectEqual(@as(u8, 7), (try registry.get(live)).*);
}

test "maximum-generation slot retires permanently" {
    var registry = Registry(u32).init();
    defer registry.deinit(std.testing.allocator);
    _ = try registry.insert(std.testing.allocator, 1);

    registry.slots.items[0].generation = std.math.maxInt(u32);
    const saturated = RowHandleId.init(0, std.math.maxInt(u32));
    try std.testing.expectEqual(@as(u32, 1), try registry.remove(saturated));
    try std.testing.expectError(error.InvalidRowHandle, registry.get(saturated));
    try std.testing.expect(registry.free_head == null);

    const next = try registry.insert(std.testing.allocator, 2);
    try std.testing.expectEqual(@as(u64, 0x0000_0001_0000_0002), next.raw());
    try std.testing.expectEqual(@as(usize, 2), registry.slots.items.len);
}

test "slot resource limit refuses growth after retired capacity is exhausted" {
    var registry = Registry(u32).initWithLimit(1);
    defer registry.deinit(std.testing.allocator);
    _ = try registry.insert(std.testing.allocator, 1);
    registry.slots.items[0].generation = std.math.maxInt(u32);
    const saturated = RowHandleId.init(0, std.math.maxInt(u32));
    _ = try registry.remove(saturated);

    try std.testing.expectError(error.ResourceLimit, registry.insert(std.testing.allocator, 2));
}

test "free list reuses the most recently released live slot" {
    var registry = Registry(u8).init();
    defer registry.deinit(std.testing.allocator);
    const first = try registry.insert(std.testing.allocator, 1);
    const second = try registry.insert(std.testing.allocator, 2);
    const third = try registry.insert(std.testing.allocator, 3);
    _ = try registry.remove(first);
    _ = try registry.remove(third);

    const reuse_third = try registry.insert(std.testing.allocator, 4);
    const reuse_first = try registry.insert(std.testing.allocator, 5);
    try std.testing.expectEqual(@as(u64, 0x0000_0002_0000_0003), reuse_third.raw());
    try std.testing.expectEqual(@as(u64, 0x0000_0002_0000_0001), reuse_first.raw());
    try std.testing.expectEqual(@as(u8, 2), (try registry.getConst(second)).*);
}
