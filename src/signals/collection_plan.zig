//! Transaction journal used while preparing descriptor collection.
//!
//! Actions own every provisional resource until `commit`. Aborting destroys
//! them in reverse construction order. Commit is allocation-free: all action
//! storage and action-specific capacity must be prepared before it begins.

const std = @import("std");

pub const IdentityKey = u128;

pub const IdentityIntent = struct {
    key: IdentityKey,
    id: u64,
};

pub const IdentityOverlay = struct {
    provisional_by_key: std.AutoHashMapUnmanaged(IdentityKey, u64) = .{},
    reserved_ids: std.AutoHashMapUnmanaged(u64, void) = .{},
    intents: std.ArrayListUnmanaged(IdentityIntent) = .empty,
    prepared_remaining: usize = 0,
    committed: bool = false,

    pub fn deinit(self: *IdentityOverlay, allocator: std.mem.Allocator) void {
        self.provisional_by_key.deinit(allocator);
        self.reserved_ids.deinit(allocator);
        self.intents.deinit(allocator);
        self.* = .{};
    }

    pub fn prepare(self: *IdentityOverlay, allocator: std.mem.Allocator, additional: usize) std.mem.Allocator.Error!void {
        const next_remaining = std.math.add(usize, self.prepared_remaining, additional) catch return error.OutOfMemory;
        try self.provisional_by_key.ensureUnusedCapacity(allocator, @intCast(additional));
        try self.reserved_ids.ensureUnusedCapacity(allocator, @intCast(additional));
        try self.intents.ensureUnusedCapacity(allocator, additional);
        self.prepared_remaining = next_remaining;
    }

    pub fn lookup(self: *const IdentityOverlay, key: IdentityKey, active_id: ?u64) ?u64 {
        return self.provisional_by_key.get(key) orelse active_id;
    }

    /// Stages `key` using the first candidate not already reserved by this
    /// transaction. Candidate enumeration is supplied by the persistent table;
    /// overlay lookup and reservation membership remain O(1).
    pub fn reserve(self: *IdentityOverlay, key: IdentityKey, active_id: ?u64, candidates: []const u64) error{ NoCapacity, NoAvailableIdentity }!u64 {
        if (self.committed) @panic("identity overlay cannot reserve after commit");
        if (self.lookup(key, active_id)) |id| return id;
        if (self.prepared_remaining == 0) return error.NoCapacity;
        for (candidates) |id| {
            if (self.reserved_ids.contains(id)) continue;
            self.provisional_by_key.putAssumeCapacity(key, id);
            self.reserved_ids.putAssumeCapacity(id, {});
            self.intents.appendAssumeCapacity(.{ .key = key, .id = id });
            self.prepared_remaining -= 1;
            return id;
        }
        return error.NoAvailableIdentity;
    }

    pub fn abort(self: *IdentityOverlay) void {
        if (self.committed) @panic("committed identity overlay cannot abort");
        self.provisional_by_key.clearRetainingCapacity();
        self.reserved_ids.clearRetainingCapacity();
        self.intents.clearRetainingCapacity();
        self.prepared_remaining = 0;
    }

    pub fn commit(self: *IdentityOverlay, publisher: anytype) void {
        if (self.committed) @panic("identity overlay committed twice");
        for (self.intents.items) |intent| publisher.publishIdentity(intent.key, intent.id);
        self.committed = true;
    }
};

pub const ScopeKey = struct {
    parent_id: u64,
    ordinal: u64,
    kind: u8,
    branch: u8 = 0,
};

pub const ScopeIntent = struct {
    key: ScopeKey,
    id: u64,
};

pub const ScopeOverlay = struct {
    provisional_by_key: std.AutoHashMapUnmanaged(ScopeKey, u64) = .{},
    reserved_ids: std.AutoHashMapUnmanaged(u64, void) = .{},
    intents: std.ArrayListUnmanaged(ScopeIntent) = .empty,
    prepared_remaining: usize = 0,
    committed: bool = false,

    pub fn deinit(self: *ScopeOverlay, allocator: std.mem.Allocator) void {
        self.provisional_by_key.deinit(allocator);
        self.reserved_ids.deinit(allocator);
        self.intents.deinit(allocator);
        self.* = .{};
    }

    pub fn prepare(self: *ScopeOverlay, allocator: std.mem.Allocator, additional: usize) std.mem.Allocator.Error!void {
        const next_remaining = std.math.add(usize, self.prepared_remaining, additional) catch return error.OutOfMemory;
        try self.provisional_by_key.ensureUnusedCapacity(allocator, @intCast(additional));
        try self.reserved_ids.ensureUnusedCapacity(allocator, @intCast(additional));
        try self.intents.ensureUnusedCapacity(allocator, additional);
        self.prepared_remaining = next_remaining;
    }

    pub fn lookup(self: *const ScopeOverlay, key: ScopeKey, active_id: ?u64) ?u64 {
        return self.provisional_by_key.get(key) orelse active_id;
    }

    pub fn reserve(self: *ScopeOverlay, key: ScopeKey, active_id: ?u64, candidates: []const u64) error{ NoCapacity, NoAvailableScope }!u64 {
        if (self.committed) @panic("scope overlay cannot reserve after commit");
        if (self.lookup(key, active_id)) |id| return id;
        if (self.prepared_remaining == 0) return error.NoCapacity;
        for (candidates) |id| {
            if (self.reserved_ids.contains(id)) continue;
            self.provisional_by_key.putAssumeCapacity(key, id);
            self.reserved_ids.putAssumeCapacity(id, {});
            self.intents.appendAssumeCapacity(.{ .key = key, .id = id });
            self.prepared_remaining -= 1;
            return id;
        }
        return error.NoAvailableScope;
    }

    pub fn abort(self: *ScopeOverlay) void {
        if (self.committed) @panic("committed scope overlay cannot abort");
        self.provisional_by_key.clearRetainingCapacity();
        self.reserved_ids.clearRetainingCapacity();
        self.intents.clearRetainingCapacity();
        self.prepared_remaining = 0;
    }

    pub fn commit(self: *ScopeOverlay, publisher: anytype) void {
        if (self.committed) @panic("scope overlay committed twice");
        for (self.intents.items) |intent| publisher.publishScope(intent.key, intent.id);
        self.committed = true;
    }
};

pub fn OwnedValues(comptime Value: type) type {
    return struct {
        const Self = @This();
        values: std.ArrayListUnmanaged(Value) = .empty,
        committed: bool = false,

        pub fn deinit(self: *Self, allocator: std.mem.Allocator, dropper: anytype) void {
            if (!self.committed) self.abort(dropper);
            self.values.deinit(allocator);
            self.* = .{};
        }

        pub fn prepare(self: *Self, allocator: std.mem.Allocator, additional: usize) std.mem.Allocator.Error!void {
            try self.values.ensureUnusedCapacity(allocator, additional);
        }

        pub fn appendAssumeCapacity(self: *Self, value: Value) void {
            if (self.committed) @panic("owned values cannot append after commit");
            self.values.appendAssumeCapacity(value);
        }

        pub fn abort(self: *Self, dropper: anytype) void {
            if (self.committed) @panic("committed values cannot abort");
            var index = self.values.items.len;
            while (index != 0) {
                index -= 1;
                dropper.dropValue(self.values.items[index]);
            }
            self.values.clearRetainingCapacity();
        }

        pub fn commit(self: *Self, publisher: anytype) void {
            if (self.committed) @panic("owned values committed twice");
            for (self.values.items) |value| publisher.publishValue(value);
            self.committed = true;
        }
    };
}

/// Transaction-local signal records keyed by stable callable token. Newly
/// constructed records remain owned here until allocation-free publication;
/// abort releases them in reverse construction order.
pub fn RecordOverlay(comptime Token: type, comptime Record: type) type {
    return struct {
        const Self = @This();
        provisional_by_token: std.AutoHashMapUnmanaged(Token, *Record) = .{},
        owned: std.ArrayListUnmanaged(*Record) = .empty,
        committed: bool = false,

        pub fn prepare(self: *Self, allocator: std.mem.Allocator, additional: usize) std.mem.Allocator.Error!void {
            try self.provisional_by_token.ensureUnusedCapacity(allocator, @intCast(additional));
            try self.owned.ensureUnusedCapacity(allocator, additional);
        }

        pub fn lookup(self: *const Self, token: Token, persistent: ?*Record) ?*Record {
            return self.provisional_by_token.get(token) orelse persistent;
        }

        pub fn ownAssumeCapacity(self: *Self, token: Token, record: *Record) void {
            if (self.committed) @panic("record overlay cannot own after commit");
            self.provisional_by_token.putAssumeCapacity(token, record);
            self.owned.appendAssumeCapacity(record);
        }

        pub fn abort(self: *Self, releaser: anytype) void {
            if (self.committed) @panic("committed record overlay cannot abort");
            var index = self.owned.items.len;
            while (index != 0) {
                index -= 1;
                releaser.releaseRecord(self.owned.items[index]);
            }
            self.provisional_by_token.clearRetainingCapacity();
            self.owned.clearRetainingCapacity();
        }

        pub fn commit(self: *Self, publisher: anytype) void {
            if (self.committed) @panic("record overlay committed twice");
            for (self.owned.items) |record| publisher.publishRecord(record);
            self.committed = true;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator, releaser: anytype) void {
            if (!self.committed) self.abort(releaser);
            self.provisional_by_token.deinit(allocator);
            self.owned.deinit(allocator);
            self.* = .{};
        }
    };
}

test "record overlay aborts in reverse and commits without allocation" {
    const TestRecord = struct { id: u8 };
    var first = TestRecord{ .id = 1 };
    var second = TestRecord{ .id = 2 };
    var released: [2]u8 = undefined;
    var release_len: usize = 0;
    const Releaser = struct {
        values: *[2]u8,
        len: *usize,
        pub fn releaseRecord(self: @This(), record: *TestRecord) void {
            self.values[self.len.*] = record.id;
            self.len.* += 1;
        }
    };
    var overlay = RecordOverlay(u64, TestRecord){};
    try overlay.prepare(std.testing.allocator, 2);
    overlay.ownAssumeCapacity(10, &first);
    overlay.ownAssumeCapacity(20, &second);
    try std.testing.expect(overlay.lookup(20, null) == &second);
    overlay.abort(Releaser{ .values = &released, .len = &release_len });
    try std.testing.expectEqualSlices(u8, &.{ 2, 1 }, released[0..release_len]);
    overlay.deinit(std.testing.allocator, Releaser{ .values = &released, .len = &release_len });
}

pub fn Plan(comptime Action: type) type {
    return struct {
        const Self = @This();

        actions: std.ArrayListUnmanaged(Action) = .empty,
        committed: bool = false,

        pub fn deinit(self: *Self, allocator: std.mem.Allocator, ctx: anytype) void {
            if (!self.committed) self.abort(ctx);
            self.actions.deinit(allocator);
            self.* = .{};
        }

        pub fn ensureUnusedCapacity(self: *Self, allocator: std.mem.Allocator, count: usize) std.mem.Allocator.Error!void {
            try self.actions.ensureUnusedCapacity(allocator, count);
        }

        pub fn appendAssumeCapacity(self: *Self, action: Action) void {
            if (self.committed) @panic("collection plan cannot append after commit");
            self.actions.appendAssumeCapacity(action);
        }

        /// Applies already-prepared actions in construction order. `apply`
        /// cannot fail or allocate; reaching it is the transaction's mutation
        /// boundary.
        pub fn commit(self: *Self, ctx: anytype) void {
            if (self.committed) @panic("collection plan committed twice");
            for (self.actions.items) |*action| action.apply(ctx);
            self.committed = true;
        }

        pub fn abort(self: *Self, ctx: anytype) void {
            if (self.committed) @panic("committed collection plan cannot abort");
            var index = self.actions.items.len;
            while (index != 0) {
                index -= 1;
                self.actions.items[index].abort(ctx);
            }
            self.actions.clearRetainingCapacity();
        }
    };
}

const TestContext = struct {
    applied: std.ArrayListUnmanaged(u8) = .empty,
    aborted: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *@This()) void {
        self.applied.deinit(std.testing.allocator);
        self.aborted.deinit(std.testing.allocator);
    }
};

const TestAction = struct {
    id: u8,

    fn apply(self: *@This(), ctx: *TestContext) void {
        ctx.applied.append(std.testing.allocator, self.id) catch unreachable;
    }

    fn abort(self: *@This(), ctx: *TestContext) void {
        ctx.aborted.append(std.testing.allocator, self.id) catch unreachable;
    }
};

test "collection plan aborts provisional ownership in reverse order" {
    var ctx: TestContext = .{};
    defer ctx.deinit();
    var plan: Plan(TestAction) = .{};
    defer plan.deinit(std.testing.allocator, &ctx);
    try plan.ensureUnusedCapacity(std.testing.allocator, 3);
    plan.appendAssumeCapacity(.{ .id = 1 });
    plan.appendAssumeCapacity(.{ .id = 2 });
    plan.appendAssumeCapacity(.{ .id = 3 });
    plan.abort(&ctx);
    try std.testing.expectEqualSlices(u8, &.{ 3, 2, 1 }, ctx.aborted.items);
    try std.testing.expectEqual(@as(usize, 0), ctx.applied.items.len);
}

test "collection plan commit applies in order and transfers ownership" {
    var ctx: TestContext = .{};
    defer ctx.deinit();
    var plan: Plan(TestAction) = .{};
    defer plan.deinit(std.testing.allocator, &ctx);
    try plan.ensureUnusedCapacity(std.testing.allocator, 2);
    plan.appendAssumeCapacity(.{ .id = 4 });
    plan.appendAssumeCapacity(.{ .id = 5 });
    plan.commit(&ctx);
    try std.testing.expectEqualSlices(u8, &.{ 4, 5 }, ctx.applied.items);
    try std.testing.expectEqual(@as(usize, 0), ctx.aborted.items.len);
}

test "identity overlay reserves distinct ids without persistent mutation" {
    var persistent: std.AutoHashMapUnmanaged(IdentityKey, u64) = .{};
    defer persistent.deinit(std.testing.allocator);
    try persistent.put(std.testing.allocator, 10, 7);

    var overlay: IdentityOverlay = .{};
    defer overlay.deinit(std.testing.allocator);
    try overlay.prepare(std.testing.allocator, 2);
    try std.testing.expectEqual(@as(u64, 7), try overlay.reserve(10, persistent.get(10), &.{ 7, 8 }));
    try std.testing.expectEqual(@as(u64, 8), try overlay.reserve(11, persistent.get(11), &.{ 8, 9 }));
    try std.testing.expectEqual(@as(u64, 9), try overlay.reserve(12, persistent.get(12), &.{ 8, 9 }));
    try std.testing.expectEqual(@as(usize, 1), persistent.count());
    try std.testing.expect(persistent.get(11) == null);
    try std.testing.expectEqual(@as(u64, 8), overlay.lookup(11, null).?);
}

test "identity overlay abort permits clean retry" {
    var overlay: IdentityOverlay = .{};
    defer overlay.deinit(std.testing.allocator);
    try overlay.prepare(std.testing.allocator, 1);
    try std.testing.expectEqual(@as(u64, 3), try overlay.reserve(1, null, &.{3}));
    overlay.abort();
    try std.testing.expect(overlay.lookup(1, null) == null);

    try overlay.prepare(std.testing.allocator, 1);
    try std.testing.expectEqual(@as(u64, 3), try overlay.reserve(2, null, &.{3}));
    try std.testing.expectEqual(@as(usize, 1), overlay.intents.items.len);
}

test "identity overlay publishes only during allocation-free commit" {
    const Publisher = struct {
        persistent: *std.AutoHashMapUnmanaged(IdentityKey, u64),

        fn publishIdentity(self: @This(), key: IdentityKey, id: u64) void {
            self.persistent.putAssumeCapacity(key, id);
        }
    };

    var persistent: std.AutoHashMapUnmanaged(IdentityKey, u64) = .{};
    defer persistent.deinit(std.testing.allocator);
    try persistent.ensureUnusedCapacity(std.testing.allocator, 2);
    var overlay: IdentityOverlay = .{};
    defer overlay.deinit(std.testing.allocator);
    try overlay.prepare(std.testing.allocator, 2);
    _ = try overlay.reserve(20, null, &.{ 4, 5 });
    _ = try overlay.reserve(21, null, &.{ 4, 5 });
    try std.testing.expectEqual(@as(usize, 0), persistent.count());
    overlay.commit(Publisher{ .persistent = &persistent });
    try std.testing.expectEqual(@as(u64, 4), persistent.get(20).?);
    try std.testing.expectEqual(@as(u64, 5), persistent.get(21).?);
}

test "scope overlay uniquely reserves inactive slots for provisional hierarchy" {
    var overlay: ScopeOverlay = .{};
    defer overlay.deinit(std.testing.allocator);
    try overlay.prepare(std.testing.allocator, 3);
    const root_key: ScopeKey = .{ .parent_id = 0, .ordinal = 0, .kind = 1 };
    const root_id = try overlay.reserve(root_key, null, &.{ 4, 5, 6 });
    const child_a: ScopeKey = .{ .parent_id = root_id, .ordinal = 0, .kind = 2 };
    const child_b: ScopeKey = .{ .parent_id = root_id, .ordinal = 1, .kind = 2 };
    const child_a_id = try overlay.reserve(child_a, null, &.{ 4, 5, 6 });
    const child_b_id = try overlay.reserve(child_b, null, &.{ 4, 5, 6 });
    try std.testing.expectEqual(@as(u64, 4), root_id);
    try std.testing.expectEqual(@as(u64, 5), child_a_id);
    try std.testing.expectEqual(@as(u64, 6), child_b_id);
    try std.testing.expectEqual(child_a_id, overlay.lookup(child_a, null).?);
}

test "scope overlay abort leaves persistent scopes unchanged and permits retry" {
    var persistent: std.AutoHashMapUnmanaged(ScopeKey, u64) = .{};
    defer persistent.deinit(std.testing.allocator);
    const key: ScopeKey = .{ .parent_id = 1, .ordinal = 2, .kind = 3, .branch = 1 };
    var overlay: ScopeOverlay = .{};
    defer overlay.deinit(std.testing.allocator);
    try overlay.prepare(std.testing.allocator, 1);
    _ = try overlay.reserve(key, persistent.get(key), &.{9});
    try std.testing.expectEqual(@as(usize, 0), persistent.count());
    overlay.abort();
    try overlay.prepare(std.testing.allocator, 1);
    try std.testing.expectEqual(@as(u64, 9), try overlay.reserve(key, persistent.get(key), &.{9}));
}

test "provisional value initializer runs once and abort releases ownership" {
    const Tracker = struct {
        initializers: usize = 0,
        drops: usize = 0,
        published: usize = 0,

        fn initialize(self: *@This()) u64 {
            self.initializers += 1;
            return 42;
        }
        fn dropValue(self: *@This(), _: u64) void {
            self.drops += 1;
        }
        fn publishValue(self: *@This(), _: u64) void {
            self.published += 1;
        }
    };

    var tracker: Tracker = .{};
    var values: OwnedValues(u64) = .{};
    defer values.deinit(std.testing.allocator, &tracker);
    try values.prepare(std.testing.allocator, 1);
    values.appendAssumeCapacity(tracker.initialize());
    try std.testing.expectEqual(@as(usize, 1), tracker.initializers);
    try std.testing.expectEqual(@as(usize, 0), tracker.published);
    values.abort(&tracker);
    try std.testing.expectEqual(@as(usize, 1), tracker.drops);
}

test "provisional value commit transfers without rerunning initializer or drop" {
    const Tracker = struct {
        initializers: usize = 0,
        drops: usize = 0,
        published: usize = 0,

        fn initialize(self: *@This()) u64 {
            self.initializers += 1;
            return 7;
        }
        fn dropValue(self: *@This(), _: u64) void {
            self.drops += 1;
        }
        fn publishValue(self: *@This(), _: u64) void {
            self.published += 1;
        }
    };

    var tracker: Tracker = .{};
    var values: OwnedValues(u64) = .{};
    defer values.deinit(std.testing.allocator, &tracker);
    try values.prepare(std.testing.allocator, 1);
    values.appendAssumeCapacity(tracker.initialize());
    values.commit(&tracker);
    try std.testing.expectEqual(@as(usize, 1), tracker.initializers);
    try std.testing.expectEqual(@as(usize, 1), tracker.published);
    try std.testing.expectEqual(@as(usize, 0), tracker.drops);
}
