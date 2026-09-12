//! Deterministic allocator fault injection shared by native and Wasm hosts.

const std = @import("std");

pub const FaultAllocator = struct {
    backing: std.mem.Allocator,
    fail_number: ?usize = null,
    attempts: usize = 0,
    induced_failures: usize = 0,
    bytes: ByteMetrics = .{},

    /// Requested-byte accounting for every allocation that passed through
    /// this allocator. Sizes are the caller's requested lengths, not the
    /// backing allocator's rounded blocks, so two runs of the same code
    /// report identical numbers regardless of the backing allocator.
    pub const ByteMetrics = struct {
        /// Bytes currently owned by callers.
        live: usize = 0,
        /// Highest `live` observed since the last reset.
        peak: usize = 0,
        /// Bytes returned through `free` or shrunk through resize/remap.
        /// Frees of memory that predates this instance (tests that re-create
        /// the allocator around one live host) saturate `live` at zero.
        freed: usize = 0,
        /// Bytes requested through alloc or growth, successful or not.
        requested: usize = 0,

        fn grow(self: *ByteMetrics, delta: usize) void {
            self.live += delta;
            self.peak = @max(self.peak, self.live);
        }

        fn shrink(self: *ByteMetrics, delta: usize) void {
            self.live -|= delta;
            self.freed += delta;
        }
    };

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    /// Creates an initialized value with the ownership and capacity invariants required by this module.
    pub fn init(backing: std.mem.Allocator) FaultAllocator {
        return .{ .backing = backing };
    }

    /// Returns the allocator owned by this host context for shared-engine work.
    pub fn allocator(self: *FaultAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// `number` is one-based. Null disables injection. The Nth allocation,
    /// resize, or remap attempt and all subsequent attempts fail until this is
    /// reconfigured, so fallback through another vtable operation cannot
    /// swallow the injected failure.
    pub fn configure(self: *FaultAllocator, number: ?usize) void {
        self.fail_number = number;
        self.attempts = 0;
        self.induced_failures = 0;
    }

    /// Restarts byte accounting at the current live size so a caller can
    /// measure the peak and freed bytes of one bounded operation. Live bytes
    /// are preserved because they describe memory that is still owned.
    pub fn resetByteMetrics(self: *FaultAllocator) void {
        self.bytes = .{ .live = self.bytes.live, .peak = self.bytes.live };
    }

    fn shouldFail(self: *FaultAllocator) bool {
        self.attempts += 1;
        if (self.fail_number) |number| if (self.attempts >= number) {
            if (self.induced_failures == 0) self.induced_failures = 1;
            return true;
        };
        return false;
    }

    fn fromPtr(ptr: *anyopaque) *FaultAllocator {
        return @ptrCast(@alignCast(ptr));
    }

    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self = fromPtr(ptr);
        self.bytes.requested += len;
        if (self.shouldFail()) return null;
        const result = self.backing.rawAlloc(len, alignment, ret_addr);
        if (result != null) self.bytes.grow(len);
        return result;
    }

    fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self = fromPtr(ptr);
        if (new_len > memory.len) self.bytes.requested += new_len - memory.len;
        if (self.shouldFail()) return false;
        const resized = self.backing.rawResize(memory, alignment, new_len, ret_addr);
        if (resized) self.recordResize(memory.len, new_len);
        return resized;
    }

    fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self = fromPtr(ptr);
        if (new_len > memory.len) self.bytes.requested += new_len - memory.len;
        if (self.shouldFail()) return null;
        const remapped = self.backing.rawRemap(memory, alignment, new_len, ret_addr);
        if (remapped != null) self.recordResize(memory.len, new_len);
        return remapped;
    }

    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self = fromPtr(ptr);
        self.bytes.shrink(memory.len);
        self.backing.rawFree(memory, alignment, ret_addr);
    }

    fn recordResize(self: *FaultAllocator, old_len: usize, new_len: usize) void {
        if (new_len >= old_len) self.bytes.grow(new_len - old_len) else self.bytes.shrink(old_len - new_len);
    }
};

fn exercise(allocator: std.mem.Allocator) !void {
    var first = try std.ArrayList(u8).initCapacity(allocator, 4);
    defer first.deinit(allocator);
    var second = try std.ArrayList(u64).initCapacity(allocator, 8);
    defer second.deinit(allocator);
    try first.appendSlice(allocator, "allocation sweep");
    try second.appendSlice(allocator, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9 });
}

test "fault allocator sweeps allocation and growth attempts and teardown never fails" {
    var counter = FaultAllocator.init(std.testing.allocator);
    try exercise(counter.allocator());
    const attempt_count = counter.attempts;
    try std.testing.expect(attempt_count >= 4);

    for (1..attempt_count + 1) |failure_number| {
        var fault = FaultAllocator.init(std.testing.allocator);
        fault.configure(failure_number);
        try std.testing.expectError(error.OutOfMemory, exercise(fault.allocator()));
        try std.testing.expectEqual(@as(usize, 1), fault.induced_failures);

        // Deallocation is never a failure point, and disabling the injected
        // fault makes the same allocator usable after cleanup.
        fault.configure(null);
        try exercise(fault.allocator());
    }
}

test "fault allocator injects direct resize and remap failures" {
    var fault = FaultAllocator.init(std.testing.allocator);
    const allocator = fault.allocator();

    const resized = try allocator.alloc(u8, 8);
    fault.configure(1);
    try std.testing.expect(!allocator.rawResize(resized, .of(u8), 16, @returnAddress()));
    try std.testing.expectEqual(@as(usize, 1), fault.attempts);
    fault.configure(null);
    allocator.free(resized);

    const remapped = try allocator.alloc(u8, 8);
    fault.configure(1);
    try std.testing.expect(allocator.rawRemap(remapped, .of(u8), 16, @returnAddress()) == null);
    try std.testing.expectEqual(@as(usize, 1), fault.attempts);
    fault.configure(null);
    allocator.free(remapped);
}

test "teardown remains allocation-free while faults are armed" {
    var fault = FaultAllocator.init(std.testing.allocator);
    const allocator = fault.allocator();
    const first = try allocator.alloc(u8, 17);
    const second = try allocator.alloc(u64, 9);

    fault.configure(1);
    allocator.free(second);
    allocator.free(first);

    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqual(@as(usize, 0), fault.induced_failures);
}

test "fault allocator meters requested live, peak, and freed bytes" {
    var fault = FaultAllocator.init(std.testing.allocator);
    const allocator = fault.allocator();

    const first = try allocator.alloc(u8, 32);
    const second = try allocator.alloc(u8, 16);
    try std.testing.expectEqual(@as(usize, 48), fault.bytes.live);
    try std.testing.expectEqual(@as(usize, 48), fault.bytes.peak);
    try std.testing.expectEqual(@as(usize, 48), fault.bytes.requested);
    allocator.free(second);
    try std.testing.expectEqual(@as(usize, 32), fault.bytes.live);
    try std.testing.expectEqual(@as(usize, 48), fault.bytes.peak);
    try std.testing.expectEqual(@as(usize, 16), fault.bytes.freed);

    fault.resetByteMetrics();
    try std.testing.expectEqual(@as(usize, 32), fault.bytes.live);
    try std.testing.expectEqual(@as(usize, 32), fault.bytes.peak);
    try std.testing.expectEqual(@as(usize, 0), fault.bytes.freed);
    try std.testing.expectEqual(@as(usize, 0), fault.bytes.requested);

    // A refused allocation is requested but never live.
    fault.configure(1);
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 64));
    try std.testing.expectEqual(@as(usize, 64), fault.bytes.requested);
    try std.testing.expectEqual(@as(usize, 32), fault.bytes.live);
    fault.configure(null);
    allocator.free(first);
    try std.testing.expectEqual(@as(usize, 0), fault.bytes.live);
}
