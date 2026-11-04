const std = @import("std");
const allocator = std.heap.wasm_allocator;
var counts: [6]u64 = @splat(0); // allocs, frees, requested bytes, realloc-copy bytes, live allocations, live bytes
var state: ?*anyopaque = null;
const Header = extern struct { size: usize, total: usize, alignment: usize, base: usize };

export fn roc_alloc(size: usize, alignment: usize) ?*anyopaque {
    const a = @max(alignment, @alignOf(Header));
    const offset = std.mem.alignForward(usize, @sizeOf(Header), a);
    const total = offset + size;
    const base = allocator.rawAlloc(total, std.mem.Alignment.fromByteUnits(a), @returnAddress()) orelse @trap();
    const ptr = base + offset;
    const header: *Header = @ptrFromInt(@intFromPtr(ptr) - @sizeOf(Header));
    header.* = .{ .size = size, .total = total, .alignment = a, .base = @intFromPtr(base) };
    counts[0] += 1;
    counts[2] += size;
    counts[4] += 1;
    counts[5] += size;
    return ptr;
}
export fn roc_dealloc(ptr: *anyopaque, _: usize) void {
    const header: *Header = @ptrFromInt(@intFromPtr(ptr) - @sizeOf(Header));
    const h = header.*;
    counts[1] += 1;
    counts[4] -= 1;
    counts[5] -= h.size;
    const base: [*]u8 = @ptrFromInt(h.base);
    allocator.rawFree(base[0..h.total], std.mem.Alignment.fromByteUnits(h.alignment), @returnAddress());
}
export fn roc_realloc(ptr: *anyopaque, size: usize, alignment: usize) ?*anyopaque {
    const header: *Header = @ptrFromInt(@intFromPtr(ptr) - @sizeOf(Header));
    const copied = @min(header.size, size);
    const next = roc_alloc(size, alignment).?;
    @memcpy(@as([*]u8, @ptrCast(next))[0..copied], @as([*]u8, @ptrCast(ptr))[0..copied]);
    counts[3] += copied;
    roc_dealloc(ptr, alignment);
    return next;
}
export fn roc_dbg(_: [*]const u8, _: usize) void {}
export fn roc_crashed(_: [*]const u8, _: usize) noreturn { @trap(); }
export fn roc_expect_failed(_: [*]const u8, _: usize) noreturn { @trap(); }
extern fn graph_create(u64, u64) *anyopaque;
extern fn graph_step(*anyopaque, u64, u64) *anyopaque;
extern fn graph_finish(*anyopaque, u64) u64;
extern fn graph_drop(*anyopaque) void;
extern fn graph_handoff(*anyopaque) *anyopaque;
export fn handoff() void {
    const owned = state orelse @trap();
    state = null;
    state = graph_handoff(owned);
    if (state != owned) @trap();
}
export fn start(count: u64, retain: u64) void {
    if (state != null) @trap();
    state = graph_create(count, retain);
}
export fn update(index: u64, iterations: u64) void {
    const owned = state orelse @trap();
    state = null;
    state = graph_step(owned, index, iterations);
}
export fn drop_state() void {
    const owned = state orelse @trap();
    state = null;
    graph_drop(owned);
}
export fn finish(expected: u64) u64 {
    const owned = state orelse @trap();
    state = null;
    return graph_finish(owned, expected);
}
export fn reset_metrics() void { @memset(counts[0..4], 0); }
export fn metric(index: u32) u64 { return counts[index]; }
