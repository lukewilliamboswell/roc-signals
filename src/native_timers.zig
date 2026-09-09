//! Bounded native timer notifications selected by the shared engine.
//! One UI-thread owner drains changes after each complete engine operation.
const std = @import("std");

pub const max_active = 256;
const slot_count = 2 * max_active;
const none = std.math.maxInt(u16);

/// A copied primitive timer instruction. Tokens are engine lifetime identities.
pub const Message = extern struct { token: u64, period_ms: u64, action: u32, reserved: u32 = 0 };

/// Coalesces unpublished starts and cancellations without scanning live timers.
/// Canceled announced timers retain a slot until their cancellation is read;
/// the second slot bank bounds those notifications independently of live work.
pub const Registry = struct {
    const Slot = struct {
        token: u64,
        period_ms: u64,
        active: bool = true,
        announced: bool = false,
        queued: bool = false,
        previous: u16 = none,
        next: u16 = none,
    };
    slots: [slot_count]Slot = undefined,
    free_slots: [slot_count]u16 = undefined,
    free_count: usize = 0,
    allocated: usize = 0,
    active_count: usize = 0,
    by_token: std.AutoHashMapUnmanaged(u64, u16) = .empty,
    first: u16 = none,
    last: u16 = none,

    /// Reserves the fixed identity table before engine publication. The bound
    /// includes committed registrations plus this transaction's new sources.
    pub fn reserve(self: *Registry, allocator: std.mem.Allocator, additional: usize) error{ OutOfMemory, ResourceLimit }!void {
        if (additional > max_active - self.active_count) return error.ResourceLimit;
        if (additional == 0) return;
        try self.by_token.ensureTotalCapacity(allocator, slot_count);
    }

    /// Publishes one preflighted start. A zero-millisecond period follows the
    /// platform's event-loop timer behavior; each wake still enters the engine.
    pub fn start(self: *Registry, token: u64, period_ms: u64) void {
        if (token == 0 or self.by_token.contains(token) or self.active_count == max_active) @panic("invalid or unreserved native timer start");
        const index: u16 = if (self.free_count != 0) free: {
            self.free_count -= 1;
            break :free self.free_slots[self.free_count];
        } else fresh: {
            if (self.allocated == slot_count) @panic("native timer notification bound exceeded");
            const value: u16 = @intCast(self.allocated);
            self.allocated += 1;
            break :fresh value;
        };
        self.slots[index] = .{ .token = token, .period_ms = period_ms };
        self.by_token.putAssumeCapacity(token, index);
        self.active_count += 1;
        self.enqueue(index);
    }

    /// Invalidates callback delivery immediately. An unannounced start disappears
    /// entirely; an announced timer emits exactly one cancellation.
    pub fn cancel(self: *Registry, token: u64) void {
        const index = self.by_token.get(token) orelse @panic("native timer cancellation missed its identity");
        const slot = &self.slots[index];
        if (!slot.active) @panic("native timer canceled twice");
        slot.active = false;
        self.active_count -= 1;
        if (!slot.announced) {
            self.release(index);
        } else self.enqueue(index);
    }

    /// Reads one committed notification in publication order. No Roc values or
    /// borrowed buffers cross this adapter boundary.
    pub fn next(self: *Registry) ?Message {
        const index = self.first;
        if (index == none) return null;
        self.unlink(index);
        const slot = &self.slots[index];
        const message: Message = .{ .token = slot.token, .period_ms = if (slot.active) slot.period_ms else 0, .action = if (slot.active) 1 else 2 };
        if (slot.active) slot.announced = true else self.release(index);
        return message;
    }

    /// Rejects a callback queued before scope disposal without invoking Roc.
    pub fn isActive(self: *const Registry, token: u64) bool {
        const index = self.by_token.get(token) orelse return false;
        return self.slots[index].active;
    }

    /// Releases transport storage after the native owner cancels its timer jobs.
    pub fn deinit(self: *Registry, allocator: std.mem.Allocator) void {
        self.by_token.deinit(allocator);
        self.* = .{};
    }

    fn enqueue(self: *Registry, index: u16) void {
        const slot = &self.slots[index];
        if (slot.queued) return;
        slot.previous = self.last;
        slot.next = none;
        slot.queued = true;
        if (self.last != none) self.slots[self.last].next = index else self.first = index;
        self.last = index;
    }

    fn unlink(self: *Registry, index: u16) void {
        const slot = &self.slots[index];
        if (!slot.queued) return;
        if (slot.previous != none) self.slots[slot.previous].next = slot.next else self.first = slot.next;
        if (slot.next != none) self.slots[slot.next].previous = slot.previous else self.last = slot.previous;
        slot.queued = false;
        slot.previous = none;
        slot.next = none;
    }

    fn release(self: *Registry, index: u16) void {
        self.unlink(index);
        if (!self.by_token.remove(self.slots[index].token)) @panic("native timer index was missing during release");
        self.free_slots[self.free_count] = index;
        self.free_count += 1;
    }
};

test "native timers coalesce unpublished work and reject stale callbacks" {
    var registry: Registry = .{};
    defer registry.deinit(std.testing.allocator);
    try registry.reserve(std.testing.allocator, 2);
    registry.start(1, 500);
    registry.start(2, 1000);
    registry.cancel(1);
    try std.testing.expect(!registry.isActive(1));
    const start = registry.next().?;
    try std.testing.expectEqual(@as(u64, 2), start.token);
    try std.testing.expectEqual(@as(u32, 1), start.action);
    registry.cancel(2);
    try std.testing.expect(!registry.isActive(2));
    try std.testing.expectEqual(@as(u32, 2), registry.next().?.action);
    try std.testing.expectEqual(null, registry.next());
    for (3..10000) |id| {
        registry.start(id, 500);
        registry.cancel(id);
    }
    try std.testing.expectEqual(@as(usize, 0), registry.by_token.count());
}

test "native timers reserve cancellation capacity and refuse saturation before publication" {
    const FaultAllocator = @import("signals").fault_allocator.FaultAllocator;
    var fault = FaultAllocator.init(std.testing.allocator);
    var registry: Registry = .{};
    defer registry.deinit(fault.allocator());
    try registry.reserve(fault.allocator(), max_active);
    fault.configure(1);
    for (1..max_active + 1) |id| {
        registry.start(id, 500);
        _ = registry.next();
    }
    try std.testing.expectError(error.ResourceLimit, registry.reserve(fault.allocator(), 1));
    for (1..max_active + 1) |id| registry.cancel(id);
    for (max_active + 1..2 * max_active + 1) |id| registry.start(id, 250);
    var notifications: usize = 0;
    while (registry.next()) |_| notifications += 1;
    try std.testing.expectEqual(@as(usize, 2 * max_active), notifications);
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    fault.configure(null);
}
