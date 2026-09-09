//! Bounded native transport reservations, independent of Roc values and scheduling.
//! A canceled running operation retains its slot until the native worker settles.
const std = @import("std");

pub const max_requests = 16;
pub const max_payload_bytes = 8 * 1024 * 1024;

/// Owns primitive request buffers between engine publication and native completion.
/// The engine selects service kinds and request identities; this queue only
/// reserves storage, preserves publication order, and invalidates delivery.
pub fn Queue(comptime Kind: type) type {
    return struct {
        const Self = @This();
        const State = enum { queued, running, canceled };
        const Slot = struct {
            id: u64,
            kind: Kind,
            request: []const u8,
            state: State,
            sequence: u64,
            cancel_sequence: ?u64 = null,
        };
        slots: [max_requests]?Slot = @splat(null),
        sequence: u64 = 0,

        pub const Message = union(enum) {
            start: struct { id: u64, kind: Kind, request: []const u8 },
            cancel: u64,
        };

        /// Checks a fixed transport bound without allocating or changing work.
        pub fn canAdmit(self: *const Self, payload_length: usize) bool {
            if (payload_length > max_payload_bytes) return false;
            for (self.slots) |slot| if (slot == null) return true;
            return false;
        }

        /// Copies a request into an unpublished reservation. The sole UI-thread
        /// owner must commit or abandon it before another request is prepared.
        pub fn prepare(self: *Self, allocator: std.mem.Allocator, id: u64, kind: Kind, request: []const u8) error{ OutOfMemory, ResourceLimit }!Prepared {
            if (!self.canAdmit(request.len)) return error.ResourceLimit;
            if (self.index(id) != null or id == 0) @panic("duplicate native task identity");
            for (self.slots, 0..) |slot, i| if (slot == null) {
                return .{ .queue = self, .allocator = allocator, .index = i, .slot = .{
                    .id = id,
                    .kind = kind,
                    .request = try allocator.dupe(u8, request),
                    .state = .queued,
                    .sequence = 0,
                } };
            };
            unreachable;
        }

        pub const Prepared = struct {
            queue: *Self,
            allocator: std.mem.Allocator,
            index: usize,
            slot: ?Slot,

            /// Publishes the complete primitive request with no allocation.
            pub fn commit(self: *Prepared) void {
                var slot = self.slot orelse @panic("native task reservation committed twice");
                if (self.queue.slots[self.index] != null) @panic("native task reservation reused before commit");
                slot.sequence = self.queue.nextSequence();
                self.queue.slots[self.index] = slot;
                self.slot = null;
            }

            /// Releases an unpublished request; committed slots belong to Queue.
            pub fn deinit(self: *Prepared) void {
                if (self.slot) |slot| self.allocator.free(slot.request);
                self.slot = null;
            }
        };

        /// Returns the next engine-published operation in order. Borrowed request
        /// bytes remain valid until completion, cancellation before start, or teardown.
        pub fn next(self: *Self) ?Message {
            var selected: ?usize = null;
            var sequence: u64 = std.math.maxInt(u64);
            for (self.slots, 0..) |slot_optional, i| if (slot_optional) |slot| {
                const candidate = if (slot.state == .queued) slot.sequence else slot.cancel_sequence orelse continue;
                if (candidate < sequence) {
                    selected = i;
                    sequence = candidate;
                }
            };
            const slot = &(self.slots[selected orelse return null].?);
            if (slot.state == .queued) {
                slot.state = .running;
                return .{ .start = .{ .id = slot.id, .kind = slot.kind, .request = slot.request } };
            }
            slot.cancel_sequence = null;
            return .{ .cancel = slot.id };
        }

        /// Invalidates delivery immediately. Work not yet dispatched is released;
        /// a running worker receives cancellation and retains its reservation.
        pub fn cancel(self: *Self, allocator: std.mem.Allocator, id: u64) void {
            const i = self.index(id) orelse @panic("canceling an unknown native task");
            const slot = &self.slots[i].?;
            switch (slot.state) {
                .queued => self.releaseAt(allocator, i),
                .running => {
                    slot.state = .canceled;
                    slot.cancel_sequence = self.nextSequence();
                },
                .canceled => {},
            }
        }

        /// Identifies an invalidated result before the adapter can invoke any Roc
        /// decoder. Unknown IDs are protocol errors, including duplicate completion.
        pub fn isCanceled(self: *const Self, id: u64) bool {
            const i = self.index(id) orelse @panic("completion for an unknown native task");
            return self.slots[i].?.state == .canceled;
        }

        /// Releases a settled worker's reservation. The engine calls this during
        /// result commit, before observers can admit their next request.
        pub fn complete(self: *Self, allocator: std.mem.Allocator, id: u64) void {
            const i = self.index(id) orelse @panic("completing an unknown native task");
            if (self.slots[i].?.state == .queued) @panic("native task completed before dispatch");
            self.releaseAt(allocator, i);
        }

        /// Releases all primitive buffers during host teardown. Native workers own
        /// independent copies and their owner invalidates callbacks before shutdown.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            for (0..self.slots.len) |i| if (self.slots[i] != null) self.releaseAt(allocator, i);
            self.* = .{};
        }

        fn releaseAt(self: *Self, allocator: std.mem.Allocator, i: usize) void {
            allocator.free(self.slots[i].?.request);
            self.slots[i] = null;
        }

        fn index(self: *const Self, id: u64) ?usize {
            for (self.slots, 0..) |slot, i| if (slot) |value| if (value.id == id) return i;
            return null;
        }

        fn nextSequence(self: *Self) u64 {
            if (self.sequence == std.math.maxInt(u64)) @panic("native task publication sequence exhausted");
            self.sequence += 1;
            return self.sequence;
        }
    };
}

const TestKind = enum { read, scan };

test "native task queue reserves cancellation until completion and preserves order" {
    var queue: Queue(TestKind) = .{};
    defer queue.deinit(std.testing.allocator);
    var first = try queue.prepare(std.testing.allocator, 1, .read, "first");
    defer first.deinit();
    try std.testing.expect(queue.next() == null);
    first.commit();
    try std.testing.expectEqual(@as(u64, 1), queue.next().?.start.id);
    var second = try queue.prepare(std.testing.allocator, 2, .scan, "second");
    defer second.deinit();
    second.commit();
    queue.cancel(std.testing.allocator, 1);
    try std.testing.expectEqual(@as(u64, 2), queue.next().?.start.id);
    try std.testing.expectEqual(@as(u64, 1), queue.next().?.cancel);
    try std.testing.expect(queue.isCanceled(1));
    queue.complete(std.testing.allocator, 1);
    queue.complete(std.testing.allocator, 2);
    try std.testing.expect(queue.next() == null);
}

test "native task queue refuses saturation including canceled workers" {
    var queue: Queue(TestKind) = .{};
    defer queue.deinit(std.testing.allocator);
    for (1..max_requests + 1) |id| {
        var prepared = try queue.prepare(std.testing.allocator, id, .read, "request");
        defer prepared.deinit();
        prepared.commit();
        _ = queue.next();
        queue.cancel(std.testing.allocator, id);
        _ = queue.next();
    }
    try std.testing.expect(!queue.canAdmit(0));
    try std.testing.expectError(error.ResourceLimit, queue.prepare(std.testing.allocator, 100, .read, "request"));
    queue.complete(std.testing.allocator, 1);
    try std.testing.expect(queue.canAdmit(0));
    var abandoned = try queue.prepare(std.testing.allocator, 100, .read, "request");
    abandoned.deinit();
    try std.testing.expect(queue.canAdmit(0));
    try std.testing.expect(!queue.canAdmit(max_payload_bytes + 1));
}

test "native task queue cancellation before dispatch releases unpublished work" {
    var queue: Queue(TestKind) = .{};
    defer queue.deinit(std.testing.allocator);
    var prepared = try queue.prepare(std.testing.allocator, 1, .read, "request");
    defer prepared.deinit();
    prepared.commit();
    queue.cancel(std.testing.allocator, 1);
    try std.testing.expect(queue.next() == null);
    try std.testing.expect(queue.canAdmit(0));
}

test "native task request allocation refusal leaves every reservation unchanged" {
    var queue: Queue(TestKind) = .{};
    defer queue.deinit(std.testing.allocator);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, queue.prepare(failing.allocator(), 1, .read, "request"));
    try std.testing.expect(queue.next() == null);
    try std.testing.expect(queue.canAdmit(0));
    var retry = try queue.prepare(std.testing.allocator, 1, .read, "request");
    defer retry.deinit();
    retry.commit();
    try std.testing.expectEqualStrings("request", queue.next().?.start.request);
}
