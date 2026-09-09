//! Shared runtime-sized buffer relocation behind typed list storage.
//!
//! Every typed `std.ArrayListUnmanaged(T)` in the engine specializes its growth
//! path per element type, so the browser artifact carries one remap/allocate/
//! copy/free body per list type. This module implements that algorithm once,
//! taking element size and alignment as ordinary runtime values, and offers a
//! small typed `List(T)` adapter with the operations the engine actually uses.
//!
//! Sharing here is about code, not representation: each `List(T)` still owns a
//! typed `items` slice and capacity, exactly like the standard list. Relocation
//! moves raw bytes of host-owned elements. Retained Roc values that live inside
//! host containers are opaque handles owned through their capability; moving
//! the handle bytes to a new backing buffer neither clones nor drops the value,
//! which is exactly what the standard list already did. Values with internal
//! pointers into their own storage must not use ordinary byte relocation.
//!
//! Ownership and failure contract: `relocate` publishes nothing on failure. The
//! old buffer, its live elements, and the caller's length remain valid, so the
//! caller may retry or release the list normally. On success the caller adopts
//! the returned pointer and the requested capacity; the old buffer is gone.

const std = @import("std");
const math = std.math;
const mem = std.mem;
const Allocator = mem.Allocator;

/// Relocates one host-owned backing buffer to `new_capacity` elements.
///
/// Mirrors the standard list growth policy: attempt an in-place remap first so
/// unused capacity is not copied; when the allocator refuses, allocate a new
/// buffer, copy only the `live_count` elements, and release the old buffer
/// after the copy succeeds. A zero `old_capacity` means there is no old buffer
/// and `old_ptr` is ignored. Element size must be non-zero; typed adapters
/// handle zero-sized elements without reaching this function.
///
/// Returns the new buffer pointer, aligned to `alignment`. On `OutOfMemory` the
/// old buffer is untouched and still owned by the caller. `return_address` is
/// forwarded to the allocator so leak and fault reports attribute the request
/// to the typed caller rather than to this shared body. Deliberately not
/// inlined: the whole point is that one copy of this body serves every type.
pub noinline fn relocate(
    gpa: Allocator,
    old_ptr: [*]u8,
    live_count: usize,
    old_capacity: usize,
    new_capacity: usize,
    element_size: usize,
    alignment: mem.Alignment,
    return_address: usize,
) Allocator.Error![*]u8 {
    std.debug.assert(element_size != 0);
    std.debug.assert(live_count <= old_capacity or old_capacity == 0);
    std.debug.assert(live_count <= new_capacity);
    const new_bytes = math.mul(usize, new_capacity, element_size) catch return error.OutOfMemory;
    // The old buffer was allocated with these dimensions, so this cannot overflow.
    const old_bytes = old_capacity * element_size;
    const live_bytes = live_count * element_size;
    const old_memory = old_ptr[0..old_bytes];
    if (old_bytes != 0) {
        if (gpa.rawRemap(old_memory, alignment, new_bytes, return_address)) |remapped| return remapped;
    }
    const next = gpa.rawAlloc(new_bytes, alignment, return_address) orelse return error.OutOfMemory;
    @memcpy(next[0..live_bytes], old_ptr[0..live_bytes]);
    if (old_bytes != 0) gpa.rawFree(old_memory, alignment, return_address);
    return next;
}

/// Returns the standard super-linear growth target for `minimum` elements.
///
/// Kept identical to `std.ArrayListUnmanaged(T).growCapacity` so migrating a
/// list changes emitted code, not allocation traffic or capacity plateaus.
pub fn growCapacity(comptime T: type, minimum: usize) usize {
    if (@sizeOf(T) == 0) return math.maxInt(usize);
    const init_capacity: comptime_int = @max(1, std.atomic.cache_line / @sizeOf(T));
    return minimum +| (minimum / 2 + init_capacity);
}

/// A typed, unmanaged growable list whose relocation is shared across types.
///
/// The public shape (`items`, `capacity`, `.empty`, allocator-per-call) matches
/// the standard unmanaged list so callers migrate by changing the type name.
/// Only the operations the engine needs are provided; do not grow this into a
/// copy of the standard API. Element pointers are invalidated by any operation
/// that may relocate, exactly as documented on the standard list.
pub fn List(comptime T: type) type {
    return struct {
        const Self = @This();
        const alignment: mem.Alignment = .of(T);

        /// Live elements. Length is the logical size; pointer and capacity are
        /// published together only after a relocation succeeds.
        items: []T = &.{},
        /// Number of elements the backing buffer can hold.
        capacity: usize = 0,

        /// A list with no backing buffer; safe to `deinit` without use.
        pub const empty: Self = .{};

        /// Creates a list with room for `count` elements and zero length.
        pub fn initCapacity(gpa: Allocator, count: usize) Allocator.Error!Self {
            var self: Self = .empty;
            try self.ensureTotalCapacityPrecise(gpa, count);
            return self;
        }

        /// Releases the backing buffer. Elements are not visited: retained Roc
        /// values stored here must already have been dropped through their
        /// capability by the owning structure.
        pub fn deinit(self: *Self, gpa: Allocator) void {
            gpa.free(self.allocatedSlice());
            self.* = undefined;
        }

        /// The whole backing buffer, including unused capacity.
        pub fn allocatedSlice(self: Self) []T {
            return self.items.ptr[0..self.capacity];
        }

        /// The capacity beyond the live elements, as an uninitialized slice.
        pub fn unusedCapacitySlice(self: Self) []T {
            return self.allocatedSlice()[self.items.len..];
        }

        /// Ensures room for at least `new_capacity` elements using the standard
        /// super-linear growth policy.
        pub fn ensureTotalCapacity(self: *Self, gpa: Allocator, new_capacity: usize) Allocator.Error!void {
            if (self.capacity >= new_capacity) return;
            return self.ensureTotalCapacityPrecise(gpa, growCapacity(T, new_capacity));
        }

        /// Ensures room for exactly `new_capacity` elements when growth is
        /// needed. On failure the list is unchanged and remains usable.
        pub fn ensureTotalCapacityPrecise(self: *Self, gpa: Allocator, new_capacity: usize) Allocator.Error!void {
            if (@sizeOf(T) == 0) {
                self.capacity = math.maxInt(usize);
                return;
            }
            if (self.capacity >= new_capacity) return;
            const next = try relocate(
                gpa,
                @ptrCast(self.items.ptr),
                self.items.len,
                self.capacity,
                new_capacity,
                @sizeOf(T),
                alignment,
                @returnAddress(),
            );
            self.items.ptr = @ptrCast(@alignCast(next));
            self.capacity = new_capacity;
        }

        /// Ensures room for `additional` more elements beyond the current length.
        pub fn ensureUnusedCapacity(self: *Self, gpa: Allocator, additional: usize) Allocator.Error!void {
            const total = math.add(usize, self.items.len, additional) catch return error.OutOfMemory;
            return self.ensureTotalCapacity(gpa, total);
        }

        /// Appends one element, growing if needed.
        pub fn append(self: *Self, gpa: Allocator, item: T) Allocator.Error!void {
            const slot = try self.addOne(gpa);
            slot.* = item;
        }

        /// Appends one element into already reserved capacity.
        pub fn appendAssumeCapacity(self: *Self, item: T) void {
            self.addOneAssumeCapacity().* = item;
        }

        /// Appends every element of `items`, growing if needed.
        pub fn appendSlice(self: *Self, gpa: Allocator, items: []const T) Allocator.Error!void {
            try self.ensureUnusedCapacity(gpa, items.len);
            self.appendSliceAssumeCapacity(items);
        }

        /// Appends every element of `items` into already reserved capacity.
        pub fn appendSliceAssumeCapacity(self: *Self, items: []const T) void {
            const old_len = self.items.len;
            const new_len = old_len + items.len;
            std.debug.assert(new_len <= self.capacity);
            self.items.len = new_len;
            @memcpy(self.items[old_len..][0..items.len], items);
        }

        /// Grows the length by one and returns the new slot, growing if needed.
        pub fn addOne(self: *Self, gpa: Allocator) Allocator.Error!*T {
            try self.ensureUnusedCapacity(gpa, 1);
            return self.addOneAssumeCapacity();
        }

        /// Grows the length by one into reserved capacity and returns the slot.
        pub fn addOneAssumeCapacity(self: *Self) *T {
            std.debug.assert(self.items.len < self.capacity);
            self.items.len += 1;
            return &self.items[self.items.len - 1];
        }

        /// Grows the length by `n` and returns the new uninitialized tail.
        pub fn addManyAsSlice(self: *Self, gpa: Allocator, n: usize) Allocator.Error![]T {
            try self.ensureUnusedCapacity(gpa, n);
            return self.addManyAsSliceAssumeCapacity(n);
        }

        /// Grows the length by `n` into reserved capacity and returns the tail.
        pub fn addManyAsSliceAssumeCapacity(self: *Self, n: usize) []T {
            const old_len = self.items.len;
            std.debug.assert(old_len + n <= self.capacity);
            self.items.len = old_len + n;
            return self.items[old_len..];
        }

        /// Inserts `item` at `index`, shifting later elements up by one.
        pub fn insert(self: *Self, gpa: Allocator, index: usize, item: T) Allocator.Error!void {
            try self.ensureUnusedCapacity(gpa, 1);
            self.insertAssumeCapacity(index, item);
        }

        /// Inserts `item` at `index` into reserved capacity.
        pub fn insertAssumeCapacity(self: *Self, index: usize, item: T) void {
            std.debug.assert(index <= self.items.len);
            std.debug.assert(self.items.len < self.capacity);
            self.items.len += 1;
            mem.copyBackwards(T, self.items[index + 1 ..], self.items[index .. self.items.len - 1]);
            self.items[index] = item;
        }

        /// Replaces `len` elements starting at `start` with `replacement`,
        /// growing if the replacement is longer. On failure nothing changes.
        pub fn replaceRange(self: *Self, gpa: Allocator, start: usize, len: usize, replacement: []const T) Allocator.Error!void {
            if (replacement.len > len) try self.ensureUnusedCapacity(gpa, replacement.len - len);
            self.replaceRangeAssumeCapacity(start, len, replacement);
        }

        /// Replaces `len` elements starting at `start` with `replacement`
        /// within reserved capacity, shifting the tail as needed.
        pub fn replaceRangeAssumeCapacity(self: *Self, start: usize, len: usize, replacement: []const T) void {
            const after = start + len;
            std.debug.assert(after <= self.items.len);
            const tail = self.items[after..];
            const new_len = self.items.len - len + replacement.len;
            std.debug.assert(new_len <= self.capacity);
            if (replacement.len == len) {
                @memcpy(self.items[start..after], replacement);
            } else if (replacement.len < len) {
                mem.copyForwards(T, self.items[start + replacement.len ..], tail);
                @memcpy(self.items[start..][0..replacement.len], replacement);
                self.items.len = new_len;
            } else {
                self.items.len = new_len;
                mem.copyBackwards(T, self.items[start + replacement.len ..], tail);
                @memcpy(self.items[start..][0..replacement.len], replacement);
            }
        }

        /// Removes and returns the element at `index`, preserving order.
        pub fn orderedRemove(self: *Self, index: usize) T {
            const removed = self.items[index];
            const new_len = self.items.len - 1;
            mem.copyForwards(T, self.items[index..new_len], self.items[index + 1 ..]);
            self.items.len = new_len;
            return removed;
        }

        /// Removes and returns the element at `index` by moving the last
        /// element into its place.
        pub fn swapRemove(self: *Self, index: usize) T {
            const removed = self.items[index];
            self.items[index] = self.items[self.items.len - 1];
            self.items.len -= 1;
            return removed;
        }

        /// Removes and returns the last element, or null when empty.
        pub fn pop(self: *Self) ?T {
            if (self.items.len == 0) return null;
            const last = self.items[self.items.len - 1];
            self.items.len -= 1;
            return last;
        }

        /// Returns the last element; asserts the list is not empty.
        pub fn getLast(self: Self) T {
            return self.items[self.items.len - 1];
        }

        /// Sets the length to `new_len`, growing if needed. New elements are
        /// uninitialized; shrinking does not release capacity.
        pub fn resize(self: *Self, gpa: Allocator, new_len: usize) Allocator.Error!void {
            try self.ensureTotalCapacity(gpa, new_len);
            self.items.len = new_len;
        }

        /// Sets the length to zero without releasing the backing buffer.
        pub fn clearRetainingCapacity(self: *Self) void {
            self.items.len = 0;
        }

        /// Releases the backing buffer and resets to `empty`.
        pub fn clearAndFree(self: *Self, gpa: Allocator) void {
            gpa.free(self.allocatedSlice());
            self.* = .empty;
        }

        /// Reduces the length to `new_len` without releasing capacity.
        pub fn shrinkRetainingCapacity(self: *Self, new_len: usize) void {
            std.debug.assert(new_len <= self.items.len);
            self.items.len = new_len;
        }

        /// Transfers the live elements to the caller as an exactly sized
        /// slice and resets the list to `empty`. On failure the list is
        /// unchanged and still owns its buffer.
        pub fn toOwnedSlice(self: *Self, gpa: Allocator) Allocator.Error![]T {
            if (@sizeOf(T) == 0) {
                const result = self.items;
                self.* = .empty;
                return result;
            }
            if (self.items.len == 0) {
                self.clearAndFree(gpa);
                return &.{};
            }
            const next = try relocate(
                gpa,
                @ptrCast(self.items.ptr),
                self.items.len,
                self.capacity,
                self.items.len,
                @sizeOf(T),
                alignment,
                @returnAddress(),
            );
            const typed: [*]T = @ptrCast(@alignCast(next));
            const result = typed[0..self.items.len];
            self.* = .empty;
            return result;
        }

        /// Adopts a caller-owned slice as the live elements and full capacity.
        pub fn fromOwnedSlice(slice: []T) Self {
            return .{ .items = slice, .capacity = slice.len };
        }
    };
}

/// A bump allocator with deterministic remap behavior for tests: a remap of the
/// most recent allocation succeeds in place when it fits; any other remap is
/// refused. Every operation can also be refused explicitly.
const TestAllocator = struct {
    buffer: []u8,
    used: usize = 0,
    last_ptr: ?[*]u8 = null,
    refuse_remap: bool = false,
    refuse_alloc: bool = false,
    remap_calls: usize = 0,
    alloc_calls: usize = 0,
    free_calls: usize = 0,
    live_allocations: usize = 0,

    const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn allocator(self: *TestAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn fromPtr(ptr: *anyopaque) *TestAllocator {
        return @ptrCast(@alignCast(ptr));
    }

    fn alloc(ptr: *anyopaque, len: usize, alignment: mem.Alignment, _: usize) ?[*]u8 {
        const self = fromPtr(ptr);
        self.alloc_calls += 1;
        if (self.refuse_alloc) return null;
        const base = @intFromPtr(self.buffer.ptr) + self.used;
        const aligned = alignment.forward(base);
        const start = aligned - @intFromPtr(self.buffer.ptr);
        if (start + len > self.buffer.len) return null;
        self.used = start + len;
        self.live_allocations += 1;
        const result = self.buffer.ptr + start;
        self.last_ptr = result;
        return result;
    }

    fn resize(_: *anyopaque, _: []u8, _: mem.Alignment, _: usize, _: usize) bool {
        return false;
    }

    fn remap(ptr: *anyopaque, memory: []u8, _: mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
        const self = fromPtr(ptr);
        self.remap_calls += 1;
        if (self.refuse_remap) return null;
        if (self.last_ptr != memory.ptr) return null;
        const start = @intFromPtr(memory.ptr) - @intFromPtr(self.buffer.ptr);
        if (start + new_len > self.buffer.len) return null;
        self.used = start + new_len;
        return memory.ptr;
    }

    fn free(ptr: *anyopaque, _: []u8, _: mem.Alignment, _: usize) void {
        const self = fromPtr(ptr);
        self.free_calls += 1;
        self.live_allocations -= 1;
    }
};

fn expectSequence(items: []const u32, count: usize) !void {
    try std.testing.expectEqual(count, items.len);
    for (items, 0..) |value, index| try std.testing.expectEqual(@as(u32, @intCast(index)), value);
}

test "empty list needs no allocation and tears down once" {
    var backing: [64]u8 = undefined;
    var ta: TestAllocator = .{ .buffer = &backing };
    var list: List(u32) = .empty;
    try std.testing.expectEqual(0, list.items.len);
    try std.testing.expectEqual(null, list.pop());
    list.clearRetainingCapacity();
    list.deinit(ta.allocator());
    try std.testing.expectEqual(0, ta.alloc_calls);
    try std.testing.expectEqual(0, ta.live_allocations);
}

test "zero-sized elements never touch the allocator" {
    var backing: [16]u8 = undefined;
    var ta: TestAllocator = .{ .buffer = &backing };
    var list: List(void) = .empty;
    try list.append(ta.allocator(), {});
    try list.ensureUnusedCapacity(ta.allocator(), 1000);
    try list.append(ta.allocator(), {});
    try std.testing.expectEqual(2, list.items.len);
    try std.testing.expectEqual(math.maxInt(usize), list.capacity);
    const owned = try list.toOwnedSlice(ta.allocator());
    try std.testing.expectEqual(2, owned.len);
    try std.testing.expectEqual(0, ta.alloc_calls);
    try std.testing.expectEqual(0, ta.remap_calls);
}

test "initial allocation and standard growth policy" {
    var list: List(u32) = .empty;
    defer list.deinit(std.testing.allocator);
    try list.append(std.testing.allocator, 0);
    try std.testing.expectEqual(growCapacity(u32, 1), list.capacity);
    var reference: std.ArrayListUnmanaged(u32) = .empty;
    defer reference.deinit(std.testing.allocator);
    try reference.append(std.testing.allocator, 0);
    var i: u32 = 1;
    while (i < 500) : (i += 1) {
        try list.append(std.testing.allocator, i);
        try reference.append(std.testing.allocator, i);
        try std.testing.expectEqual(reference.capacity + 0, list.capacity);
    }
    try expectSequence(list.items, 500);
}

test "successful remap keeps the pointer and copies nothing" {
    var backing: [4096]u8 = undefined;
    var ta: TestAllocator = .{ .buffer = &backing };
    var list: List(u32) = .empty;
    try list.ensureTotalCapacityPrecise(ta.allocator(), 4);
    for (0..4) |i| list.appendAssumeCapacity(@intCast(i));
    const before = list.items.ptr;
    try list.ensureTotalCapacityPrecise(ta.allocator(), 64);
    try std.testing.expectEqual(before, list.items.ptr);
    try std.testing.expectEqual(64, list.capacity);
    try std.testing.expectEqual(1, ta.alloc_calls);
    try std.testing.expectEqual(1, ta.remap_calls);
    try std.testing.expectEqual(0, ta.free_calls);
    try expectSequence(list.items, 4);
    list.deinit(ta.allocator());
    try std.testing.expectEqual(0, ta.live_allocations);
}

test "remap refusal falls back to allocate, copy live elements, and free" {
    var backing: [4096]u8 = undefined;
    var ta: TestAllocator = .{ .buffer = &backing };
    var list: List(u32) = .empty;
    try list.ensureTotalCapacityPrecise(ta.allocator(), 8);
    for (0..3) |i| list.appendAssumeCapacity(@intCast(i));
    // Fill the unused capacity with a marker to prove only live elements move.
    for (list.unusedCapacitySlice()) |*slot| slot.* = 0xDEAD_BEEF;
    ta.refuse_remap = true;
    const before = list.items.ptr;
    try list.ensureTotalCapacityPrecise(ta.allocator(), 16);
    try std.testing.expect(before != list.items.ptr);
    try std.testing.expectEqual(16, list.capacity);
    try std.testing.expectEqual(2, ta.alloc_calls);
    try std.testing.expectEqual(1, ta.remap_calls);
    try std.testing.expectEqual(1, ta.free_calls);
    try std.testing.expectEqual(1, ta.live_allocations);
    try expectSequence(list.items, 3);
    list.deinit(ta.allocator());
    try std.testing.expectEqual(0, ta.live_allocations);
}

test "refusal of both remap and allocation leaves the list intact and retryable" {
    var backing: [4096]u8 = undefined;
    var ta: TestAllocator = .{ .buffer = &backing };
    var list: List(u32) = .empty;
    defer list.deinit(ta.allocator());
    try list.ensureTotalCapacityPrecise(ta.allocator(), 4);
    for (0..4) |i| list.appendAssumeCapacity(@intCast(i));
    const ptr = list.items.ptr;
    ta.refuse_remap = true;
    ta.refuse_alloc = true;
    try std.testing.expectError(error.OutOfMemory, list.append(ta.allocator(), 4));
    try std.testing.expectError(error.OutOfMemory, list.ensureUnusedCapacity(ta.allocator(), 100));
    try std.testing.expectEqual(ptr, list.items.ptr);
    try std.testing.expectEqual(4, list.capacity);
    try std.testing.expectEqual(0, ta.free_calls);
    try expectSequence(list.items, 4);
    // Retry after the allocator recovers.
    ta.refuse_alloc = false;
    try list.append(ta.allocator(), 4);
    try expectSequence(list.items, 5);
    try std.testing.expectEqual(1, ta.free_calls);
}

test "over-aligned elements are honoured across relocation" {
    const Big = struct { value: u64 align(64) };
    var list: List(Big) = .empty;
    defer list.deinit(std.testing.allocator);
    for (0..40) |i| {
        try list.append(std.testing.allocator, .{ .value = i });
        try std.testing.expectEqual(0, @intFromPtr(list.items.ptr) % 64);
    }
    for (list.items, 0..) |item, i| try std.testing.expectEqual(@as(u64, i), item.value);
}

test "arithmetic overflow is reported as out of memory without touching the list" {
    var list: List(u64) = .empty;
    defer list.deinit(std.testing.allocator);
    try list.append(std.testing.allocator, 1);
    const ptr = list.items.ptr;
    try std.testing.expectError(error.OutOfMemory, list.ensureTotalCapacityPrecise(std.testing.allocator, math.maxInt(usize) / 4));
    try std.testing.expectError(error.OutOfMemory, list.ensureUnusedCapacity(std.testing.allocator, math.maxInt(usize)));
    try std.testing.expectEqual(ptr, list.items.ptr);
    try std.testing.expectEqual(1, list.items.len);
}

test "live length smaller than capacity copies only live elements on relocation" {
    var list: List(u16) = .empty;
    defer list.deinit(std.testing.allocator);
    try list.ensureTotalCapacityPrecise(std.testing.allocator, 100);
    try list.appendSlice(std.testing.allocator, &.{ 1, 2, 3 });
    try list.ensureTotalCapacityPrecise(std.testing.allocator, 1000);
    try std.testing.expectEqualSlices(u16, &.{ 1, 2, 3 }, list.items);
    try std.testing.expectEqual(1000, list.capacity);
}

test "element operations preserve order and reuse capacity" {
    var list: List(u32) = .empty;
    defer list.deinit(std.testing.allocator);
    try list.appendSlice(std.testing.allocator, &.{ 0, 1, 2, 3, 4 });
    try list.insert(std.testing.allocator, 2, 99);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 99, 2, 3, 4 }, list.items);
    try std.testing.expectEqual(99, list.orderedRemove(2));
    try std.testing.expectEqual(0, list.swapRemove(0));
    try std.testing.expectEqualSlices(u32, &.{ 4, 1, 2, 3 }, list.items);
    try std.testing.expectEqual(3, list.pop());
    try std.testing.expectEqual(2, list.getLast());
    try list.replaceRange(std.testing.allocator, 1, 1, &.{ 7, 8, 9 });
    try std.testing.expectEqualSlices(u32, &.{ 4, 7, 8, 9, 2 }, list.items);
    try list.replaceRange(std.testing.allocator, 0, 3, &.{5});
    try std.testing.expectEqualSlices(u32, &.{ 5, 9, 2 }, list.items);
    try list.replaceRange(std.testing.allocator, 1, 1, &.{6});
    try std.testing.expectEqualSlices(u32, &.{ 5, 6, 2 }, list.items);
    try list.resize(std.testing.allocator, 2);
    const capacity = list.capacity;
    list.clearRetainingCapacity();
    try std.testing.expectEqual(capacity, list.capacity);
    try list.appendSlice(std.testing.allocator, &.{ 1, 2 });
    const slots = try list.addManyAsSlice(std.testing.allocator, 2);
    slots[0] = 3;
    slots[1] = 4;
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4 }, list.items);
    const owned = try list.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(owned);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4 }, owned);
    try std.testing.expectEqual(0, list.capacity);
    var adopted = List(u32).fromOwnedSlice(try std.testing.allocator.dupe(u32, owned));
    defer adopted.deinit(std.testing.allocator);
    try std.testing.expectEqual(4, adopted.capacity);
}

test "relocating retained handles neither clones nor drops them" {
    const Counters = struct { clones: usize = 0, drops: usize = 0 };
    const Handle = struct {
        counters: *Counters,
        payload: u64,
        fn clone(self: @This()) @This() {
            self.counters.clones += 1;
            return .{ .counters = self.counters, .payload = self.payload };
        }
        fn drop(self: @This()) void {
            self.counters.drops += 1;
        }
    };
    var counters: Counters = .{};
    var list: List(Handle) = .empty;
    for (0..200) |i| try list.append(std.testing.allocator, .{ .counters = &counters, .payload = i });
    try std.testing.expectEqual(0, counters.clones);
    try std.testing.expectEqual(0, counters.drops);
    for (list.items, 0..) |handle, i| try std.testing.expectEqual(@as(u64, i), handle.payload);
    // Ownership transfer: exactly one drop per handle, driven by the owner.
    for (list.items) |handle| handle.drop();
    list.deinit(std.testing.allocator);
    try std.testing.expectEqual(200, counters.drops);
    try std.testing.expectEqual(0, counters.clones);
}
