//! One-based registry for opaque Roc HostValue handles and their capabilities.

const std = @import("std");
const abi = @import("roc_platform_abi.zig");
const erased_calls = @import("erased_calls.zig");
const CapabilitySplit = @import("callable_roles.zig").CapabilitySplit;

pub const HostValue = @import("host_values.zig").HostValue;

pub const Error = error{
    OutOfMemory,
    InvalidHandle,
    ReleasedHandle,
    UnconsumedHandle,
    MissingCapability,
    CapabilityMismatch,
    InactiveCapability,
    ConflictingCapability,
    CloneCapabilityMismatch,
    CloneReturnedSource,
};

/// Defines opaque host-value storage whose cells remain paired with app-compiled ownership capabilities.
pub fn Registry(comptime Capability: type) type {
    const Cell = struct {
        box: abi.RocBox,
        capability: ?Capability,
        last_taken_epoch: u64,
        generation: u32,
    };

    const Vacant = struct {
        last_taken_epoch: u64,
        generation: u32,
        next: ?usize,
    };

    const Slot = union(enum) {
        vacant: Vacant,
        occupied: Cell,
    };

    return struct {
        const Self = @This();

        slots: std.ArrayListUnmanaged(Slot) = .empty,
        first_vacant: ?usize = null,
        take_epoch: u64 = 0,

        const index_bits = 32;
        const index_mask: u64 = (@as(u64, 1) << index_bits) - 1;

        fn encodeHandle(index: usize, generation: u32) HostValue {
            std.debug.assert(index < index_mask);
            return HostValue.fromRaw((@as(u64, generation) << index_bits) | @as(u64, @intCast(index + 1)));
        }

        fn handleIndex(value: HostValue) Error!usize {
            const one_based = value.toRaw() & index_mask;
            if (one_based == 0) return Error.InvalidHandle;
            return @intCast(one_based - 1);
        }

        fn handleGeneration(value: HostValue) u32 {
            return @intCast(value.toRaw() >> index_bits);
        }

        /// Releases every resource owned by this value and leaves no retained host or Roc ownership behind.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.slots.deinit(allocator);
        }

        /// Reports whether live values is present in maintained state.
        pub fn hasLiveValues(self: *const Self) bool {
            for (self.slots.items) |entry| {
                switch (entry) {
                    .vacant => {},
                    .occupied => return true,
                }
            }
            return false;
        }

        /// Returns the number of registry cells that still own opaque Roc values.
        pub fn liveCount(self: *const Self) usize {
            var count: usize = 0;
            for (self.slots.items) |entry| {
                switch (entry) {
                    .vacant => {},
                    .occupied => count += 1,
                }
            }
            return count;
        }

        fn cell(box: abi.RocBox, owned_capability: ?Capability, last_taken_epoch: u64, generation: u32) Cell {
            return .{ .box = box, .capability = owned_capability, .last_taken_epoch = last_taken_epoch, .generation = generation };
        }

        fn slot(self: *Self, value: HostValue) Error!*Slot {
            const index = try handleIndex(value);
            if (index >= self.slots.items.len) return Error.InvalidHandle;
            const entry = &self.slots.items[index];
            const generation = switch (entry.*) {
                .vacant => |vacant| vacant.generation,
                .occupied => |occupied| occupied.generation,
            };
            if (generation != handleGeneration(value)) return Error.ReleasedHandle;
            return entry;
        }

        fn occupiedCell(self: *Self, value: HostValue) Error!Cell {
            return switch ((try self.slot(value)).*) {
                .vacant => Error.ReleasedHandle,
                .occupied => |occupied| occupied,
            };
        }

        /// Returns the app-compiled capability that owns values crossing this edge.
        pub fn capability(self: *Self, value: HostValue) Error!?Capability {
            const occupied = try self.occupiedCell(value);
            return occupied.capability;
        }

        /// Stores an owned value with explicit capability ownership, consuming the caller's reference on success.
        pub fn storeOwnedCapability(self: *Self, allocator: std.mem.Allocator, box: abi.RocBox, owned_capability: ?Capability, ops: anytype) Error!HostValue {
            if (self.first_vacant) |index| {
                const vacant = switch (self.slots.items[index]) {
                    .vacant => |value| value,
                    .occupied => unreachable,
                };
                self.first_vacant = vacant.next;
                const generation = vacant.generation + 1;
                self.slots.items[index] = .{ .occupied = cell(box, owned_capability, vacant.last_taken_epoch, generation) };
                return encodeHandle(index, generation);
            }

            if (self.slots.items.len >= index_mask) {
                if (owned_capability) |capability_value| ops.releaseCapability(capability_value);
                return Error.OutOfMemory;
            }
            self.slots.append(allocator, .{ .occupied = cell(box, owned_capability, 0, 0) }) catch {
                if (owned_capability) |capability_value| ops.releaseCapability(capability_value);
                return Error.OutOfMemory;
            };
            return encodeHandle(self.slots.items.len - 1, 0);
        }

        /// Stores an owned value with explicit capability ownership, consuming the caller's reference on success.
        pub fn storeRetainedCapability(self: *Self, allocator: std.mem.Allocator, box: abi.RocBox, borrowed_capability: ?Capability, ops: anytype) Error!HostValue {
            if (borrowed_capability) |capability_value| {
                ops.retainCapability(capability_value);
                errdefer ops.releaseCapability(capability_value);
            }
            return try self.storeOwnedCapability(allocator, box, borrowed_capability, ops);
        }

        /// Stores an owned value with explicit capability ownership, consuming the caller's reference on success.
        pub fn storeRetainedExistingCapability(self: *Self, allocator: std.mem.Allocator, box: abi.RocBox, source_value: HostValue, ops: anytype) Error!HostValue {
            const capability_value = try self.storedCapability(source_value);
            return try self.storeRetainedCapability(allocator, box, capability_value, ops);
        }

        fn ensureStoreCapacity(self: *Self, allocator: std.mem.Allocator) Error!void {
            if (self.first_vacant != null) return;
            self.slots.ensureUnusedCapacity(allocator, 1) catch return Error.OutOfMemory;
        }

        fn storedCapability(self: *Self, value: HostValue) Error!Capability {
            return (try self.capability(value)) orelse Error.MissingCapability;
        }

        /// Rejects a value/capability mismatch before any app-compiled callable can inspect the payload.
        pub fn assertCapability(self: *Self, value: HostValue, expected_capability: Capability, ops: anytype) Error!void {
            const actual_capability = try self.storedCapability(value);
            if (!ops.capabilitiesMatch(actual_capability, expected_capability)) return Error.CapabilityMismatch;
        }

        /// Rejects a value/capability mismatch before any app-compiled callable can inspect the payload.
        pub fn assertCapabilityActive(self: *Self, value: HostValue, ops: anytype) Error!void {
            const actual_capability = try self.storedCapability(value);
            if (!ops.capabilityIsActive(actual_capability)) return Error.InactiveCapability;
        }

        /// Produces an independently owned value while leaving independent ownership in the registry cell.
        pub fn getWithCapability(self: *Self, allocator: std.mem.Allocator, value: HostValue, expected_capability: Capability, ops: anytype) Error!abi.RocBox {
            try self.assertCapability(value, expected_capability, ops);
            return try self.getWithStoredCapability(allocator, value, ops);
        }

        /// Returns the stored value without changing its identity or ownership policy.
        pub fn get(self: *Self, allocator: std.mem.Allocator, value: HostValue, ops: anytype) Error!abi.RocBox {
            return try self.getWithStoredCapability(allocator, value, ops);
        }

        /// Produces an independently owned value while leaving independent ownership in the registry cell.
        pub fn getWithSplit(self: *Self, value: HostValue, split: CapabilitySplit, ops: anytype) Error!abi.RocBox {
            try self.assertCapabilityActive(value, ops);
            return try self.getWithSplitUnchecked(value, split, ops);
        }

        fn getWithStoredCapability(self: *Self, allocator: std.mem.Allocator, value: HostValue, ops: anytype) Error!abi.RocBox {
            const cloned = try self.clone(allocator, value, ops);
            return try self.take(cloned, ops);
        }

        fn getWithSplitUnchecked(self: *Self, value: HostValue, split_callable: CapabilitySplit, ops: anytype) Error!abi.RocBox {
            const entry = try self.slot(value);
            return switch (entry.*) {
                .vacant => Error.ReleasedHandle,
                .occupied => |*occupied| blk: {
                    const split = ops.splitBoxWithSplit(occupied.box, split_callable);
                    occupied.box = split.keep;
                    break :blk split.out;
                },
            };
        }

        /// Transfers registry ownership to the caller and marks the cell unavailable for reuse.
        pub fn take(self: *Self, value: HostValue, ops: anytype) Error!abi.RocBox {
            const entry = try self.slot(value);
            return switch (entry.*) {
                .vacant => Error.ReleasedHandle,
                .occupied => |occupied| blk: {
                    self.take_epoch +%= 1;
                    const index = try handleIndex(value);
                    const reusable = occupied.generation != std.math.maxInt(u32);
                    entry.* = .{ .vacant = .{ .last_taken_epoch = self.take_epoch, .generation = occupied.generation, .next = if (reusable) self.first_vacant else null } };
                    if (reusable) self.first_vacant = index;
                    if (occupied.capability) |capability_value| ops.releaseCapability(capability_value);
                    break :blk occupied.box;
                },
            };
        }

        /// Transfers registry ownership to the caller and marks the cell unavailable for reuse.
        pub fn takeWithCapability(self: *Self, value: HostValue, expected_capability: Capability, ops: anytype) Error!abi.RocBox {
            try self.assertCapability(value, expected_capability, ops);
            return try self.take(value, ops);
        }

        /// Transfers registry ownership to the caller and marks the cell unavailable for reuse.
        pub fn takeWithSplit(self: *Self, value: HostValue, _: CapabilitySplit, ops: anytype) Error!abi.RocBox {
            try self.assertCapabilityActive(value, ops);
            return try self.take(value, ops);
        }

        /// Asserts that the registry handle no longer owns a live value.
        pub fn assertReleased(self: *Self, value: HostValue) Error!void {
            const entry = try self.slot(value);
            return switch (entry.*) {
                .vacant => {},
                .occupied => Error.UnconsumedHandle,
            };
        }

        /// Transfers registry ownership to the caller and marks the cell unavailable for reuse.
        pub fn takeEpoch(self: *const Self) u64 {
            return self.take_epoch;
        }

        /// Asserts that a consuming read transferred the cell after the recorded epoch.
        pub fn assertTakenAfter(self: *Self, value: HostValue, epoch: u64) Error!void {
            // This postcondition deliberately follows the physical slot even if
            // the callback immediately reused it. The recorded take epoch, not
            // current handle validity, proves that the incoming ownership was
            // consumed during the call.
            const index = try handleIndex(value);
            if (index >= self.slots.items.len) return Error.InvalidHandle;
            const entry = &self.slots.items[index];
            const last_taken_epoch = switch (entry.*) {
                .vacant => |vacant| vacant.last_taken_epoch,
                .occupied => |occupied| occupied.last_taken_epoch,
            };
            if (last_taken_epoch <= epoch) return Error.UnconsumedHandle;
        }

        /// Creates a new registry cell containing a capability-owned clone of the source value.
        pub fn clone(self: *Self, allocator: std.mem.Allocator, value: HostValue, ops: anytype) Error!HostValue {
            try self.ensureStoreCapacity(allocator);
            const capability_value = try self.storedCapability(value);
            const cloned = ops.cloneValueWithCapability(value, capability_value);
            if (cloned == value) return Error.CloneReturnedSource;
            const cloned_capability = try self.storedCapability(cloned);
            if (!ops.capabilitiesMatch(cloned_capability, capability_value)) return Error.CloneCapabilityMismatch;
            return cloned;
        }

        /// Sets capability at the narrow host or engine boundary that owns the mutation.
        pub fn setCapability(self: *Self, value: HostValue, borrowed_capability: Capability, ops: anytype) Error!void {
            const entry = try self.slot(value);
            switch (entry.*) {
                .vacant => return Error.ReleasedHandle,
                .occupied => |*occupied| {
                    if (occupied.capability) |actual_capability| {
                        if (!ops.capabilitiesMatch(actual_capability, borrowed_capability)) return Error.ConflictingCapability;
                        return;
                    }
                    ops.retainCapability(borrowed_capability);
                    occupied.capability = borrowed_capability;
                },
            }
        }
    };
}

const TestCapability = extern struct {
    clone: usize,
    eq: usize,
    drop: usize,
};

const TestRegistry = Registry(TestCapability);

const TestOps = struct {
    registry: *TestRegistry,
    retained_capabilities: *u64,
    released_capabilities: *u64,
    split_boxes: *u64,
    clone_returns_source: bool = false,
    clone_uses_wrong_capability: bool = false,
    active_capability: ?TestCapability = null,

    /// Retains every callable needed to clone, compare, and drop values on this edge.
    pub fn retainCapability(self: TestOps, _: TestCapability) void {
        self.retained_capabilities.* += 1;
    }

    /// Releases the callable bundle owned by a retained edge.
    pub fn releaseCapability(self: TestOps, _: TestCapability) void {
        self.released_capabilities.* += 1;
    }

    /// Checks capability identity so erased values cannot cross into the wrong typed edge.
    pub fn capabilitiesMatch(_: TestOps, actual: TestCapability, expected: TestCapability) bool {
        return actual.clone == expected.clone and actual.eq == expected.eq and actual.drop == expected.drop;
    }

    /// Checks that the owning capability is present in the current app-call frame.
    pub fn capabilityIsActive(self: TestOps, actual: TestCapability) bool {
        const active = self.active_capability orelse return false;
        return self.capabilitiesMatch(actual, active);
    }

    /// Clones an opaque value only after validating its owning capability.
    pub fn cloneValueWithCapability(self: TestOps, value: HostValue, capability: TestCapability) HostValue {
        self.split_boxes.* += 1;
        if (self.clone_returns_source) return value;
        const stored_capability = if (self.clone_uses_wrong_capability)
            TestCapability{ .clone = capability.clone + 1, .eq = capability.eq, .drop = capability.drop }
        else
            capability;
        return self.registry.storeRetainedCapability(
            std.testing.allocator,
            @ptrFromInt(0x4000 + value.toRaw()),
            stored_capability,
            self,
        ) catch unreachable;
    }

    /// Uses the app-compiled split callable to create independent keep and output ownership.
    pub fn splitBoxWithSplit(self: TestOps, box: abi.RocBox, _: CapabilitySplit) erased_calls.RocBoxPair {
        self.split_boxes.* += 1;
        const addr = @intFromPtr(box orelse unreachable);
        return .{
            .keep = @ptrFromInt(addr + 0x1000),
            .out = @ptrFromInt(addr + 0x2000),
        };
    }
};

fn testOps(registry: *TestRegistry, retained: *u64, released: *u64, splits: *u64) TestOps {
    return .{
        .registry = registry,
        .retained_capabilities = retained,
        .released_capabilities = released,
        .split_boxes = splits,
    };
}

test "host value registry generation-tags reused slots and rejects stale handles" {
    var registry: Registry(TestCapability) = .{};
    defer registry.deinit(std.testing.allocator);

    var retained: u64 = 0;
    var released: u64 = 0;
    var splits: u64 = 0;
    const ops = testOps(&registry, &retained, &released, &splits);
    const cap = TestCapability{ .clone = 0x101, .eq = 0x102, .drop = 0x103 };

    const first = try registry.storeOwnedCapability(std.testing.allocator, @ptrFromInt(0x10), cap, ops);
    const second = try registry.storeOwnedCapability(std.testing.allocator, @ptrFromInt(0x20), null, ops);
    try std.testing.expectEqual(HostValue.fromRaw(1), first);
    try std.testing.expectEqual(HostValue.fromRaw(2), second);

    try std.testing.expectEqual(@as(usize, 2), registry.slots.items.len);
    try std.testing.expectEqual(@as(abi.RocBox, @ptrFromInt(0x10)), try registry.take(first, ops));
    try std.testing.expectEqual(@as(u64, 1), released);

    const reused = try registry.storeOwnedCapability(std.testing.allocator, @ptrFromInt(0x30), null, ops);
    try std.testing.expect(first != reused);
    try std.testing.expectEqual(@as(u64, (@as(u64, 1) << 32) | 1), reused.toRaw());
    try std.testing.expectError(Error.ReleasedHandle, registry.capability(first));
    try std.testing.expectEqual(@as(abi.RocBox, @ptrFromInt(0x30)), try registry.take(reused, ops));
    try std.testing.expectEqual(@as(usize, 2), registry.slots.items.len);
}

test "host value registry permanently retires generation-saturated slots" {
    var registry: Registry(TestCapability) = .{};
    defer registry.deinit(std.testing.allocator);

    var retained: u64 = 0;
    var released: u64 = 0;
    var splits: u64 = 0;
    const ops = testOps(&registry, &retained, &released, &splits);

    _ = try registry.storeOwnedCapability(std.testing.allocator, @ptrFromInt(0x10), null, ops);
    registry.slots.items[0].occupied.generation = std.math.maxInt(u32);
    const saturated = TestRegistry.encodeHandle(0, std.math.maxInt(u32));
    _ = try registry.take(saturated, ops);
    try std.testing.expectEqual(@as(?usize, null), registry.first_vacant);

    const next = try registry.storeOwnedCapability(std.testing.allocator, @ptrFromInt(0x20), null, ops);
    try std.testing.expectEqual(HostValue.fromRaw(2), next);
    try std.testing.expectEqual(@as(usize, 2), registry.slots.items.len);
    try std.testing.expectError(Error.ReleasedHandle, registry.take(saturated, ops));
}

test "host value registry reports live count and reaches zero when drained" {
    var registry: Registry(TestCapability) = .{};
    defer registry.deinit(std.testing.allocator);

    var retained: u64 = 0;
    var released: u64 = 0;
    var splits: u64 = 0;
    const ops = testOps(&registry, &retained, &released, &splits);
    const cap = TestCapability{ .clone = 0x201, .eq = 0x202, .drop = 0x203 };

    try std.testing.expectEqual(@as(usize, 0), registry.liveCount());
    try std.testing.expect(!registry.hasLiveValues());

    const first = try registry.storeOwnedCapability(std.testing.allocator, @ptrFromInt(0x10), cap, ops);
    const second = try registry.storeOwnedCapability(std.testing.allocator, @ptrFromInt(0x20), cap, ops);
    try std.testing.expectEqual(@as(usize, 2), registry.liveCount());

    _ = try registry.take(first, ops);
    try std.testing.expectEqual(@as(usize, 1), registry.liveCount());
    try std.testing.expect(registry.hasLiveValues());

    _ = try registry.take(second, ops);
    try std.testing.expectEqual(@as(usize, 0), registry.liveCount());
    try std.testing.expect(!registry.hasLiveValues());
    try std.testing.expectEqual(@as(u64, 2), released);
}

test "host value registry asserts consuming callbacks released their handle" {
    var registry: Registry(TestCapability) = .{};
    defer registry.deinit(std.testing.allocator);

    var retained: u64 = 0;
    var released: u64 = 0;
    var splits: u64 = 0;
    const ops = testOps(&registry, &retained, &released, &splits);
    const value = try registry.storeOwnedCapability(std.testing.allocator, @ptrFromInt(0x70), null, ops);
    try std.testing.expectError(Error.UnconsumedHandle, registry.assertReleased(value));

    _ = try registry.take(value, ops);
    try registry.assertReleased(value);
    try std.testing.expectError(Error.ReleasedHandle, registry.take(value, ops));
}

test "host value registry clones through capability clone operation" {
    var registry: Registry(TestCapability) = .{};
    defer registry.deinit(std.testing.allocator);

    var retained: u64 = 0;
    var released: u64 = 0;
    var splits: u64 = 0;
    const ops = testOps(&registry, &retained, &released, &splits);
    const cap = TestCapability{ .clone = 0x301, .eq = 0x302, .drop = 0x303 };
    const original = try registry.storeOwnedCapability(std.testing.allocator, @ptrFromInt(0x40), cap, ops);
    const cloned = try registry.clone(std.testing.allocator, original, ops);

    try std.testing.expect(cloned != original);
    try std.testing.expectEqual(@as(u64, 1), splits);
    try std.testing.expectEqual(@as(u64, 1), retained);
    try std.testing.expectEqual(@as(abi.RocBox, @ptrFromInt(0x4000 + cloned.toRaw())), try registry.getWithCapability(std.testing.allocator, cloned, cap, ops));
    try std.testing.expectEqual(@as(u64, 2), splits);
}

test "host value registry enforces full capability identity" {
    var registry: Registry(TestCapability) = .{};
    defer registry.deinit(std.testing.allocator);

    var retained: u64 = 0;
    var released: u64 = 0;
    var splits: u64 = 0;
    const ops = testOps(&registry, &retained, &released, &splits);
    const cap_a = TestCapability{ .clone = 0x401, .eq = 0x402, .drop = 0x403 };
    const cap_b = TestCapability{ .clone = 0x401, .eq = 0x412, .drop = 0x403 };
    const value = try registry.storeOwnedCapability(std.testing.allocator, @ptrFromInt(0x80), cap_a, ops);

    try registry.assertCapability(value, cap_a, ops);
    try std.testing.expectError(Error.CapabilityMismatch, registry.assertCapability(value, cap_b, ops));
    try std.testing.expectError(Error.ConflictingCapability, registry.setCapability(value, cap_b, ops));
    try std.testing.expectError(Error.CapabilityMismatch, registry.getWithCapability(std.testing.allocator, value, cap_b, ops));
    try std.testing.expectEqual(@as(abi.RocBox, @ptrFromInt(0x4000 + value.toRaw())), try registry.getWithCapability(std.testing.allocator, value, cap_a, ops));
}

test "host value registry permits active-capability split access for capability thunks" {
    var registry: Registry(TestCapability) = .{};
    defer registry.deinit(std.testing.allocator);

    var retained: u64 = 0;
    var released: u64 = 0;
    var splits: u64 = 0;
    var ops = testOps(&registry, &retained, &released, &splits);
    const cap = TestCapability{ .clone = 0x501, .eq = 0x502, .drop = 0x503 };
    const value = try registry.storeOwnedCapability(std.testing.allocator, @ptrFromInt(0x90), cap, ops);

    try std.testing.expectError(Error.InactiveCapability, registry.getWithSplit(value, CapabilitySplit.fromAbi(@ptrFromInt(0x510)), ops));
    ops.active_capability = cap;
    try std.testing.expectEqual(@as(abi.RocBox, @ptrFromInt(0x2090)), try registry.getWithSplit(value, CapabilitySplit.fromAbi(@ptrFromInt(0x510)), ops));
}

test "host value registry rejects malformed capability clone results" {
    var registry: Registry(TestCapability) = .{};
    defer registry.deinit(std.testing.allocator);

    var retained: u64 = 0;
    var released: u64 = 0;
    var splits: u64 = 0;
    const cap = TestCapability{ .clone = 0x581, .eq = 0x582, .drop = 0x583 };

    var source_ops = testOps(&registry, &retained, &released, &splits);
    source_ops.clone_returns_source = true;
    const source_value = try registry.storeOwnedCapability(std.testing.allocator, @ptrFromInt(0x98), cap, source_ops);
    try std.testing.expectError(Error.CloneReturnedSource, registry.clone(std.testing.allocator, source_value, source_ops));

    var wrong_cap_ops = testOps(&registry, &retained, &released, &splits);
    wrong_cap_ops.clone_uses_wrong_capability = true;
    const wrong_cap_value = try registry.storeOwnedCapability(std.testing.allocator, @ptrFromInt(0xa8), cap, wrong_cap_ops);
    try std.testing.expectError(Error.CloneCapabilityMismatch, registry.clone(std.testing.allocator, wrong_cap_value, wrong_cap_ops));
}

test "host value registry consuming operations release capabilities exactly once" {
    var registry: Registry(TestCapability) = .{};
    defer registry.deinit(std.testing.allocator);

    var retained: u64 = 0;
    var released: u64 = 0;
    var splits: u64 = 0;
    const ops = testOps(&registry, &retained, &released, &splits);
    const cap = TestCapability{ .clone = 0x601, .eq = 0x602, .drop = 0x603 };
    const value = try registry.storeRetainedCapability(std.testing.allocator, @ptrFromInt(0xa0), cap, ops);
    try std.testing.expectEqual(@as(u64, 1), retained);

    const take_epoch = registry.takeEpoch();
    try std.testing.expectEqual(@as(abi.RocBox, @ptrFromInt(0xa0)), try registry.takeWithCapability(value, cap, ops));
    try registry.assertTakenAfter(value, take_epoch);
    try std.testing.expectEqual(@as(u64, 1), released);
    try std.testing.expectError(Error.ReleasedHandle, registry.takeWithCapability(value, cap, ops));
    try std.testing.expectEqual(@as(u64, 1), released);
}

test "host value registry rejects reads before a capability is assigned" {
    var registry: Registry(TestCapability) = .{};
    defer registry.deinit(std.testing.allocator);

    var retained: u64 = 0;
    var released: u64 = 0;
    var splits: u64 = 0;
    const ops = testOps(&registry, &retained, &released, &splits);
    const cap = TestCapability{ .clone = 0x701, .eq = 0x702, .drop = 0x703 };
    const value = try registry.storeOwnedCapability(std.testing.allocator, @ptrFromInt(0xb0), null, ops);

    try std.testing.expectError(Error.MissingCapability, registry.getWithCapability(std.testing.allocator, value, cap, ops));
    try registry.setCapability(value, cap, ops);
    try std.testing.expectEqual(@as(u64, 1), retained);
    try std.testing.expectEqual(@as(abi.RocBox, @ptrFromInt(0x4000 + value.toRaw())), try registry.getWithCapability(std.testing.allocator, value, cap, ops));
}
