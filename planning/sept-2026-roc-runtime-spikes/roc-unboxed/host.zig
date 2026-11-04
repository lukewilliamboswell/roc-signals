const std = @import("std");
const allocator = if (@import("builtin").cpu.arch == .wasm32) std.heap.wasm_allocator else std.heap.c_allocator;
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
var last_error: []const u8 = "no Roc diagnostic";
fn die(message: []const u8) noreturn { last_error = message; @trap(); }
export fn roc_crashed(ptr: [*]const u8, len: usize) noreturn { die(ptr[0..len]); }
export fn roc_expect_failed(ptr: [*]const u8, len: usize) noreturn { die(ptr[0..len]); }
export fn error_ptr() usize { return @intFromPtr(last_error.ptr); }
export fn error_len() usize { return last_error.len; }
const abi = @import("shared/roc_platform_abi.zig");

var dummy: u8 = 0;
var roc_host: abi.RocHost = .{ .env = &dummy, .roc_alloc = allocAdapter, .roc_dealloc = freeAdapter, .roc_realloc = reallocAdapter, .roc_dbg = debugAdapter, .roc_crashed = crashAdapter, .roc_expect_failed = crashAdapter };
fn allocAdapter(_: *abi.RocHost, size: usize, alignment: usize) callconv(.c) ?*anyopaque { return roc_alloc(size, alignment); }
fn freeAdapter(_: *abi.RocHost, ptr: *anyopaque, alignment: usize) callconv(.c) void { roc_dealloc(ptr, alignment); }
fn reallocAdapter(_: *abi.RocHost, ptr: *anyopaque, size: usize, alignment: usize) callconv(.c) ?*anyopaque { return roc_realloc(ptr, size, alignment); }
fn debugAdapter(_: *abi.RocHost, _: [*]const u8, _: usize) callconv(.c) void {}
fn crashAdapter(_: *abi.RocHost, ptr: [*]const u8, len: usize) callconv(.c) void { die(ptr[0..len]); }

// No value registry, boxed payload access, or reactive runtime exists here.
// These transfers preserve one owned callable reference. Only the compiler's
// on_drop callback interprets its capture; restoring checks the owning token.
export fn spike_erase(callable: abi.RocErasedCallable) abi.RocErasedCallable {
    return callable orelse die("null erased callable");
}
export fn spike_restore(callable: abi.RocErasedCallable, actual: u64, expected: u64) abi.RocErasedCallable {
    if (actual == 0 or actual != expected) die("CapabilityMismatch");
    return callable orelse die("null erased callable");
}
// The native experiment is single-threaded. Tokens never wrap or get reused.
var next_capability: u64 = 1;
export fn spike_fresh() u64 {
    if (next_capability == std.math.maxInt(u64)) die("capability identities exhausted");
    const token = next_capability;
    next_capability += 1;
    return token;
}
export fn spike_identity(callable: abi.RocErasedCallable) u64 {
    defer abi.decrefErasedCallable(callable, &roc_host);
    return @intFromPtr(callable orelse die("null identity"));
}
extern fn spike_init() *anyopaque;
extern fn spike_step(*anyopaque, u64) *anyopaque;
extern fn spike_finish(*anyopaque) void;
export fn start() void { if (state != null) die("already mounted"); state = spike_init(); }
export fn step(action: u64) void { const owned = state orelse die("not mounted"); state = null; state = spike_step(owned, action); }
export fn finish() void { const owned = state orelse die("not mounted"); state = null; spike_finish(owned); }
export fn metric(index: u32) u64 { return counts[index]; }
export fn reset_metrics() void { @memset(counts[0..4], 0); }
