//! Deterministic allocator fault injection shared by native and Wasm hosts.

const std = @import("std");

pub const FaultAllocator = struct {
    backing: std.mem.Allocator,
    fail_number: ?usize = null,
    attempts: usize = 0,
    induced_failures: usize = 0,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    /// Provides the `init` operation.
    pub fn init(backing: std.mem.Allocator) FaultAllocator {
        return .{ .backing = backing };
    }

    /// Provides the `allocator` operation.
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
        if (self.shouldFail()) return null;
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self = fromPtr(ptr);
        if (self.shouldFail()) return false;
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self = fromPtr(ptr);
        if (self.shouldFail()) return null;
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self = fromPtr(ptr);
        self.backing.rawFree(memory, alignment, ret_addr);
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
