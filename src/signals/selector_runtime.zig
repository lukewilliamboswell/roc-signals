//! Host-owned index for keyed `Signal.select` members.

const std = @import("std");

/// Maps one selected-input record and string key to every live member record.
/// Keys are copied into registry ownership so removing one member never leaves
/// the hash table borrowing bytes from that member's descriptor payload.
pub fn Registry(comptime Record: type) type {
    return struct {
        const Self = @This();
        const Members = std.ArrayListUnmanaged(*Record);
        const Group = struct {
            members_by_key: std.StringHashMapUnmanaged(Members) = .empty,

            fn deinit(self: *Group, allocator: std.mem.Allocator) void {
                var iterator = self.members_by_key.iterator();
                while (iterator.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                self.members_by_key.deinit(allocator);
                self.* = .{};
            }
        };

        groups: std.AutoHashMapUnmanaged(*Record, Group) = .empty,

        /// Registers one independently owned selector membership.
        pub fn register(self: *Self, allocator: std.mem.Allocator, input: *Record, key: []const u8, member: *Record) std.mem.Allocator.Error!void {
            const group_entry = try self.groups.getOrPut(allocator, input);
            if (!group_entry.found_existing) group_entry.value_ptr.* = .{};
            errdefer if (!group_entry.found_existing and group_entry.value_ptr.members_by_key.count() == 0) {
                _ = self.groups.remove(input);
            };

            const existing = group_entry.value_ptr.members_by_key.getPtr(key);
            if (existing) |members| {
                for (members.items) |known| if (known == member) return;
                try members.append(allocator, member);
                return;
            }

            const owned_key = try allocator.dupe(u8, key);
            errdefer allocator.free(owned_key);
            var members: Members = .empty;
            errdefer members.deinit(allocator);
            try members.append(allocator, member);
            try group_entry.value_ptr.members_by_key.put(allocator, owned_key, members);
        }

        /// Removes one membership and releases empty key buckets and groups.
        pub fn unregister(self: *Self, allocator: std.mem.Allocator, input: *Record, key: []const u8, member: *Record) void {
            const group = self.groups.getPtr(input) orelse @panic("selector member was absent from its input group");
            const members = group.members_by_key.getPtr(key) orelse @panic("selector member key was absent from its input group");
            var found: ?usize = null;
            for (members.items, 0..) |known, index| if (known == member) {
                found = index;
                break;
            };
            const index = found orelse @panic("selector member was absent from its key bucket");
            _ = members.swapRemove(index);
            if (members.items.len != 0) return;

            members.deinit(allocator);
            const removed = group.members_by_key.fetchRemove(key) orelse unreachable;
            allocator.free(removed.key);
            if (group.members_by_key.count() != 0) return;

            group.members_by_key.deinit(allocator);
            _ = self.groups.remove(input);
        }

        /// Returns the live members for one exact string key without allocation.
        pub fn membersForKey(self: *const Self, input: *Record, key: []const u8) []const *Record {
            const group = self.groups.get(input) orelse return &.{};
            const bucket = group.members_by_key.get(key) orelse return &.{};
            return bucket.items;
        }

        /// Returns one member whose input-read capability can expose the selected string.
        pub fn anyMember(self: *const Self, input: *Record) ?*Record {
            const group = self.groups.get(input) orelse return null;
            var iterator = group.members_by_key.valueIterator();
            const bucket = iterator.next() orelse return null;
            return if (bucket.items.len == 0) null else bucket.items[0];
        }

        /// Releases all registry-owned keys, buckets, and groups.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            var iterator = self.groups.valueIterator();
            while (iterator.next()) |group| group.deinit(allocator);
            self.groups.deinit(allocator);
            self.* = .{};
        }
    };
}

const TestRecord = struct { id: u64 };

test "selector registry looks up exact keys and supports shared-key members" {
    var registry: Registry(TestRecord) = .{};
    defer registry.deinit(std.testing.allocator);
    var input = TestRecord{ .id = 1 };
    var first = TestRecord{ .id = 2 };
    var second = TestRecord{ .id = 3 };
    var third = TestRecord{ .id = 4 };

    try registry.register(std.testing.allocator, &input, "one", &first);
    try registry.register(std.testing.allocator, &input, "one", &second);
    try registry.register(std.testing.allocator, &input, "two", &third);

    try std.testing.expectEqualSlices(*TestRecord, &.{ &first, &second }, registry.membersForKey(&input, "one"));
    try std.testing.expectEqualSlices(*TestRecord, &.{&third}, registry.membersForKey(&input, "two"));
    try std.testing.expectEqual(@as(usize, 0), registry.membersForKey(&input, "missing").len);

    registry.unregister(std.testing.allocator, &input, "one", &first);
    try std.testing.expectEqualSlices(*TestRecord, &.{&second}, registry.membersForKey(&input, "one"));
    registry.unregister(std.testing.allocator, &input, "one", &second);
    registry.unregister(std.testing.allocator, &input, "two", &third);
    try std.testing.expectEqual(@as(usize, 0), registry.groups.count());
}

test "selector registry owns key bytes independently of member storage" {
    var registry: Registry(TestRecord) = .{};
    defer registry.deinit(std.testing.allocator);
    var input = TestRecord{ .id = 1 };
    var member = TestRecord{ .id = 2 };
    const key = try std.testing.allocator.dupe(u8, "temporary");
    try registry.register(std.testing.allocator, &input, key, &member);
    std.testing.allocator.free(key);
    try std.testing.expectEqualSlices(*TestRecord, &.{&member}, registry.membersForKey(&input, "temporary"));
}

test "selector registration is atomic across every allocation failure" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var input = TestRecord{ .id = 1 };
    var member = TestRecord{ .id = 2 };

    var counter = FaultAllocator.init(std.testing.allocator);
    var baseline: Registry(TestRecord) = .{};
    try baseline.register(counter.allocator(), &input, "key", &member);
    const attempts = counter.attempts;
    counter.configure(null);
    baseline.deinit(counter.allocator());

    for (1..attempts + 1) |failure_number| {
        var fault = FaultAllocator.init(std.testing.allocator);
        fault.configure(failure_number);
        var registry: Registry(TestRecord) = .{};
        try std.testing.expectError(error.OutOfMemory, registry.register(fault.allocator(), &input, "key", &member));
        try std.testing.expectEqual(@as(usize, 0), registry.groups.count());
        fault.configure(null);
        registry.deinit(fault.allocator());
    }
}
