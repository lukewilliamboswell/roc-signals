//! Host-owned index for keyed `Signal.select` members.

const std = @import("std");
const shared_buffer = @import("shared_buffer.zig");

/// Maps one selected-input record and string key to every live member record.
/// Keys are copied into registry ownership so removing one member never leaves
/// the hash table borrowing bytes from that member's descriptor payload.
pub fn Registry(comptime Record: type) type {
    return struct {
        const Self = @This();
        const Members = shared_buffer.List(*Record);
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

        /// Counts every live membership across all groups and keys.
        pub fn memberCount(self: *const Self) usize {
            var total: usize = 0;
            var groups = self.groups.valueIterator();
            while (groups.next()) |group| {
                var buckets = group.members_by_key.valueIterator();
                while (buckets.next()) |bucket| total += bucket.items.len;
            }
            return total;
        }

        /// Releases all registry-owned keys, buckets, and groups.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            var iterator = self.groups.valueIterator();
            while (iterator.next()) |group| group.deinit(allocator);
            self.groups.deinit(allocator);
            self.* = .{};
        }

        /// Memberships one structural transaction appends, held under candidate
        /// ownership until the transaction publishes.
        ///
        /// A structural change touches only the selector records it retires or
        /// creates, so the live registry is patched rather than rebuilt: retired
        /// members leave through `unregister` when their records are released,
        /// and appended members enter through this staging area. `stage` copies
        /// keys and builds buckets in a private registry that only the
        /// transaction owns; `reserveLive` then grows the live tables so
        /// `commitInto` can move that ownership across without allocating.
        /// Rollback at any point before commit is `deinit`, which releases the
        /// staged copies and leaves live memberships exactly as they were; the
        /// spare capacity a reservation left behind is the only trace and is
        /// reused by the next transaction.
        pub const PreparedAppend = struct {
            const Phase = enum { staging, reserved, committed };

            staged: Self = .{},
            phase: Phase = .staging,
            /// Memberships staged so far, and the key bytes copied for them.
            /// Kept here so a host can report the work once at commit rather
            /// than once per preparation attempt when a refused transaction
            /// is retried.
            staged_memberships: u64 = 0,
            staged_key_bytes: u64 = 0,

            /// Records one appended membership. The key is copied into staged
            /// ownership immediately so a member never lends its descriptor
            /// bytes to the index, matching `register`.
            pub fn stage(self: *PreparedAppend, allocator: std.mem.Allocator, input: *Record, key: []const u8, member: *Record) std.mem.Allocator.Error!void {
                if (self.phase != .staging) @panic("selector membership staged after live reservation");
                try self.staged.register(allocator, input, key, member);
                self.staged_memberships += 1;
                self.staged_key_bytes += key.len;
            }

            /// Grows the live tables every staged group, key, and bucket will
            /// enter, so commit performs no allocation. Live memberships are not
            /// modified. Reservations are made for every staged entry rather
            /// than only the ones currently absent from `live`, because members
            /// retired by the same transaction may empty a bucket or group
            /// between this call and commit; removal only ever returns capacity,
            /// so the reservation stays sufficient.
            pub fn reserveLive(self: *PreparedAppend, allocator: std.mem.Allocator, live: *Self) std.mem.Allocator.Error!void {
                if (self.phase != .staging) @panic("selector live reservation repeated");
                try live.groups.ensureUnusedCapacity(allocator, self.staged.groups.count());
                var groups = self.staged.groups.iterator();
                while (groups.next()) |entry| {
                    const live_group = live.groups.getPtr(entry.key_ptr.*) orelse continue;
                    try live_group.members_by_key.ensureUnusedCapacity(allocator, entry.value_ptr.members_by_key.count());
                    var buckets = entry.value_ptr.members_by_key.iterator();
                    while (buckets.next()) |bucket| {
                        const live_bucket = live_group.members_by_key.getPtr(bucket.key_ptr.*) orelse continue;
                        try live_bucket.ensureUnusedCapacity(allocator, bucket.value_ptr.items.len);
                    }
                }
                self.phase = .reserved;
            }

            /// Publishes every staged membership into `live` using only the
            /// capacity `reserveLive` obtained. Whole groups and whole key
            /// buckets that `live` lacks move across with their owned key bytes;
            /// members joining an existing bucket are appended and their staged
            /// duplicate key is released. Staged members are freshly appended
            /// records, so they cannot already be present in `live`. After this
            /// call the staged registry is empty and `deinit` is a no-op.
            pub fn commitInto(self: *PreparedAppend, allocator: std.mem.Allocator, live: *Self) void {
                if (self.phase != .reserved) @panic("selector memberships committed without live reservation");
                var groups = self.staged.groups.iterator();
                while (groups.next()) |entry| {
                    const staged_group = entry.value_ptr;
                    const live_entry = live.groups.getOrPutAssumeCapacity(entry.key_ptr.*);
                    if (!live_entry.found_existing) {
                        live_entry.value_ptr.* = staged_group.*;
                        staged_group.* = .{};
                        continue;
                    }
                    var buckets = staged_group.members_by_key.iterator();
                    while (buckets.next()) |bucket| {
                        const live_bucket = live_entry.value_ptr.members_by_key.getOrPutAssumeCapacity(bucket.key_ptr.*);
                        if (!live_bucket.found_existing) {
                            live_bucket.value_ptr.* = bucket.value_ptr.*;
                            continue;
                        }
                        live_bucket.value_ptr.appendSliceAssumeCapacity(bucket.value_ptr.items);
                        bucket.value_ptr.deinit(allocator);
                        allocator.free(bucket.key_ptr.*);
                    }
                    staged_group.members_by_key.deinit(allocator);
                    staged_group.* = .{};
                }
                self.staged.groups.deinit(allocator);
                self.staged = .{};
                self.phase = .committed;
            }

            /// Releases whatever the transaction still owns: every staged key
            /// and bucket before commit, nothing after it.
            pub fn deinit(self: *PreparedAppend, allocator: std.mem.Allocator) void {
                self.staged.deinit(allocator);
                self.* = .{ .phase = .committed };
            }
        };
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

fn expectMembers(registry: *const Registry(TestRecord), input: *TestRecord, key: []const u8, expected: []const *TestRecord) !void {
    try std.testing.expectEqualSlices(*TestRecord, expected, registry.membersForKey(input, key));
}

test "prepared selector append patches only staged memberships into a live registry" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    const allocator = std.testing.allocator;
    var live: Registry(TestRecord) = .{};
    defer live.deinit(allocator);
    var input = TestRecord{ .id = 1 };
    var other_input = TestRecord{ .id = 2 };
    var survivor = TestRecord{ .id = 3 };
    var shared_key_survivor = TestRecord{ .id = 4 };
    var joins_existing_bucket = TestRecord{ .id = 5 };
    var new_key_member = TestRecord{ .id = 6 };
    var new_group_member = TestRecord{ .id = 7 };
    try live.register(allocator, &input, "one", &survivor);
    try live.register(allocator, &input, "two", &shared_key_survivor);

    var prepared: Registry(TestRecord).PreparedAppend = .{};
    defer prepared.deinit(allocator);
    try prepared.stage(allocator, &input, "two", &joins_existing_bucket);
    try prepared.stage(allocator, &input, "three", &new_key_member);
    try prepared.stage(allocator, &other_input, "one", &new_group_member);
    try prepared.reserveLive(allocator, &live);

    // Nothing is visible until commit.
    try expectMembers(&live, &input, "two", &.{&shared_key_survivor});
    try expectMembers(&live, &input, "three", &.{});
    try expectMembers(&live, &other_input, "one", &.{});
    try std.testing.expectEqual(@as(usize, 2), live.memberCount());

    var counter = FaultAllocator.init(allocator);
    prepared.commitInto(counter.allocator(), &live);
    try std.testing.expectEqual(@as(usize, 0), counter.attempts);

    try expectMembers(&live, &input, "one", &.{&survivor});
    try expectMembers(&live, &input, "two", &.{ &shared_key_survivor, &joins_existing_bucket });
    try expectMembers(&live, &input, "three", &.{&new_key_member});
    try expectMembers(&live, &other_input, "one", &.{&new_group_member});
    try std.testing.expectEqual(@as(usize, 5), live.memberCount());

    // Moved keys are owned by the live registry: unregistering everything releases them.
    live.unregister(allocator, &input, "one", &survivor);
    live.unregister(allocator, &input, "two", &shared_key_survivor);
    live.unregister(allocator, &input, "two", &joins_existing_bucket);
    live.unregister(allocator, &input, "three", &new_key_member);
    live.unregister(allocator, &other_input, "one", &new_group_member);
    try std.testing.expectEqual(@as(usize, 0), live.groups.count());
}

test "prepared selector append commits after same-transaction retirements emptied its targets" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    const allocator = std.testing.allocator;
    var live: Registry(TestRecord) = .{};
    defer live.deinit(allocator);
    var input = TestRecord{ .id = 1 };
    var retiring = TestRecord{ .id = 2 };
    var replacement_same_key = TestRecord{ .id = 3 };
    var replacement_other_key = TestRecord{ .id = 4 };
    try live.register(allocator, &input, "key", &retiring);

    var prepared: Registry(TestRecord).PreparedAppend = .{};
    defer prepared.deinit(allocator);
    try prepared.stage(allocator, &input, "key", &replacement_same_key);
    try prepared.stage(allocator, &input, "other", &replacement_other_key);
    try prepared.reserveLive(allocator, &live);

    // Publication releases retired records before the staged members land,
    // which removes the whole group here; the reservation must still hold.
    live.unregister(allocator, &input, "key", &retiring);
    try std.testing.expectEqual(@as(usize, 0), live.groups.count());

    var counter = FaultAllocator.init(allocator);
    prepared.commitInto(counter.allocator(), &live);
    try std.testing.expectEqual(@as(usize, 0), counter.attempts);
    try expectMembers(&live, &input, "key", &.{&replacement_same_key});
    try expectMembers(&live, &input, "other", &.{&replacement_other_key});
    live.unregister(allocator, &input, "key", &replacement_same_key);
    live.unregister(allocator, &input, "other", &replacement_other_key);
    try std.testing.expectEqual(@as(usize, 0), live.groups.count());
}

test "prepared selector append rollback leaves live memberships untouched across every allocation failure" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    const allocator = std.testing.allocator;
    var input = TestRecord{ .id = 1 };
    var other_input = TestRecord{ .id = 2 };
    var survivor = TestRecord{ .id = 3 };
    var first = TestRecord{ .id = 4 };
    var second = TestRecord{ .id = 5 };
    var third = TestRecord{ .id = 6 };

    const Attempt = struct {
        fn run(fault: *FaultAllocator, live: *Registry(TestRecord), a: *TestRecord, b: *TestRecord, c: *TestRecord, in: *TestRecord, other: *TestRecord) !void {
            var prepared: Registry(TestRecord).PreparedAppend = .{};
            defer prepared.deinit(fault.allocator());
            try prepared.stage(fault.allocator(), in, "one", a);
            try prepared.stage(fault.allocator(), in, "two", b);
            try prepared.stage(fault.allocator(), other, "two", c);
            try prepared.reserveLive(fault.allocator(), live);
            prepared.commitInto(fault.allocator(), live);
        }
    };

    var counter = FaultAllocator.init(allocator);
    var baseline: Registry(TestRecord) = .{};
    try baseline.register(counter.allocator(), &input, "one", &survivor);
    counter.configure(null);
    try Attempt.run(&counter, &baseline, &first, &second, &third, &input, &other_input);
    const attempts = counter.attempts;
    try std.testing.expect(attempts > 0);
    baseline.deinit(counter.allocator());

    for (1..attempts + 1) |failure_number| {
        var fault = FaultAllocator.init(allocator);
        var live: Registry(TestRecord) = .{};
        try live.register(fault.allocator(), &input, "one", &survivor);
        fault.configure(failure_number);
        try std.testing.expectError(error.OutOfMemory, Attempt.run(&fault, &live, &first, &second, &third, &input, &other_input));
        fault.configure(null);
        try expectMembers(&live, &input, "one", &.{&survivor});
        try expectMembers(&live, &input, "two", &.{});
        try expectMembers(&live, &other_input, "two", &.{});
        try std.testing.expectEqual(@as(usize, 1), live.memberCount());
        try std.testing.expectEqual(@as(usize, 1), live.groups.count());
        // The same transaction retried against the same live registry succeeds.
        try Attempt.run(&fault, &live, &first, &second, &third, &input, &other_input);
        try std.testing.expectEqual(@as(usize, 4), live.memberCount());
        live.deinit(fault.allocator());
    }
}

test "prepared selector append keeps live capacity bounded across repeated churn" {
    const allocator = std.testing.allocator;
    var live: Registry(TestRecord) = .{};
    defer live.deinit(allocator);
    var input = TestRecord{ .id = 1 };
    var stable = TestRecord{ .id = 2 };
    try live.register(allocator, &input, "stable", &stable);
    var members: [8]TestRecord = undefined;
    for (&members, 0..) |*member, index| member.* = .{ .id = 100 + index };

    var capacity_after_warmup: usize = 0;
    for (0..64) |round| {
        var prepared: Registry(TestRecord).PreparedAppend = .{};
        errdefer prepared.deinit(allocator);
        var key_buffers: [8][16]u8 = undefined;
        for (&members, 0..) |*member, index| {
            const key = try std.fmt.bufPrint(&key_buffers[index], "k{d}", .{index});
            try prepared.stage(allocator, &input, key, member);
        }
        try prepared.reserveLive(allocator, &live);
        prepared.commitInto(allocator, &live);
        try std.testing.expectEqual(@as(usize, 9), live.memberCount());
        for (&members, 0..) |*member, index| {
            const key = try std.fmt.bufPrint(&key_buffers[index], "k{d}", .{index});
            live.unregister(allocator, &input, key, member);
        }
        try std.testing.expectEqual(@as(usize, 1), live.memberCount());
        const capacity = live.groups.getPtr(&input).?.members_by_key.capacity();
        if (round == 1) capacity_after_warmup = capacity;
        if (round > 1) try std.testing.expectEqual(capacity_after_warmup, capacity);
    }
}
