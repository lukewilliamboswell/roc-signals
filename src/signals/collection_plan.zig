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
        self.provisional_by_key.clearRetainingCapacity();
        self.reserved_ids.clearRetainingCapacity();
        self.intents.clearRetainingCapacity();
        self.prepared_remaining = 0;
    }
};

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
