//! Transaction journal used while preparing descriptor collection.
//!
//! Actions own every provisional resource until `commit`. Aborting destroys
//! them in reverse construction order. Commit is allocation-free: all action
//! storage and action-specific capacity must be prepared before it begins.

const std = @import("std");

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
