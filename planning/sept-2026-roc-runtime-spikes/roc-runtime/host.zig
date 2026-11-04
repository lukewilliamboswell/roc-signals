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
var last_error: []const u8 = "no Roc diagnostic";
fn die(message: []const u8) noreturn { last_error = message; @trap(); }
export fn roc_crashed(ptr: [*]const u8, len: usize) noreturn { die(ptr[0..len]); }
export fn roc_expect_failed(ptr: [*]const u8, len: usize) noreturn { die(ptr[0..len]); }
export fn error_ptr() usize { return @intFromPtr(last_error.ptr); }
export fn error_len() usize { return last_error.len; }
const abi = @import("shared/roc_platform_abi.zig");
const hv = @import("shared/host_values.zig");
const reg = @import("shared/host_value_registry.zig");
const calls = @import("shared/erased_calls.zig");
const roles = @import("shared/callable_roles.zig");
const Cap = hv.HostValueCapabilityHandle;
var registry: reg.Registry(Cap) = .{};
var active: hv.ActiveCapabilityStack = .{};
var dummy: u8 = 0;
var roc_host: abi.RocHost = .{ .env = &dummy, .roc_alloc = allocAdapter, .roc_dealloc = freeAdapter, .roc_realloc = reallocAdapter, .roc_dbg = debugAdapter, .roc_crashed = crashAdapter, .roc_expect_failed = crashAdapter };
fn allocAdapter(_: *abi.RocHost, size: usize, alignment: usize) callconv(.c) ?*anyopaque { return roc_alloc(size, alignment); }
fn freeAdapter(_: *abi.RocHost, ptr: *anyopaque, alignment: usize) callconv(.c) void { roc_dealloc(ptr, alignment); }
fn reallocAdapter(_: *abi.RocHost, ptr: *anyopaque, size: usize, alignment: usize) callconv(.c) ?*anyopaque { return roc_realloc(ptr, size, alignment); }
fn debugAdapter(_: *abi.RocHost, _: [*]const u8, _: usize) callconv(.c) void {}
fn crashAdapter(_: *abi.RocHost, _: [*]const u8, _: usize) callconv(.c) void { @trap(); }
fn ops() hv.RegistryOps() { return .{ .roc_host = &roc_host, .active_capabilities = &active }; }
fn value(raw: u64) hv.HostValue { return hv.HostValue.fromRaw(raw); }
export fn spike_identity(callable: abi.RocErasedCallable) u64 {
    defer abi.decrefErasedCallable(callable, &roc_host);
    return @intFromPtr(callable orelse @trap());
}
export fn spike_equal(cap: Cap, a: u64, b: u64) bool {
    defer hv.releaseHostValueCapability(cap, &roc_host);
    registry.assertCapability(value(a), cap, ops()) catch |err| die(@errorName(err));
    registry.assertCapability(value(b), cap, ops()) catch |err| die(@errorName(err));
    active.push(&.{cap}); defer active.pop();
    return calls.callErasedHostValueHostValueToBool(&roc_host, hv.hostValueCapabilityEq(cap), value(a), value(b));
}
export fn spike_drop(cap: Cap, a: u64) void {
    defer hv.releaseHostValueCapability(cap, &roc_host);
    registry.assertCapability(value(a), cap, ops()) catch |err| die(@errorName(err));
    active.push(&.{cap}); defer active.pop();
    calls.callErasedHostValueToUnit(&roc_host, hv.hostValueCapabilityDrop(cap), value(a));
}
export fn roc_host_value_store_with_capability(box: abi.RocBox, cap: Cap) u64 { return (registry.storeOwnedCapability(allocator, box, cap, ops()) catch |err| die(@errorName(err))).toRaw(); }
export fn roc_host_value_store_with_existing_capability(box: abi.RocBox, raw: u64) u64 { return (registry.storeRetainedExistingCapability(allocator, box, value(raw), ops()) catch |err| die(@errorName(err))).toRaw(); }
export fn roc_host_value_get_with_capability(raw: u64, cap: Cap) abi.RocBox { defer hv.releaseHostValueCapability(cap, &roc_host); return registry.getWithCapability(allocator, value(raw), cap, ops()) catch |err| die(@errorName(err)); }
export fn roc_host_value_take_with_capability(raw: u64, cap: Cap) abi.RocBox { defer hv.releaseHostValueCapability(cap, &roc_host); return registry.takeWithCapability(value(raw), cap, ops()) catch |err| die(@errorName(err)); }
export fn roc_host_value_get_with_split(raw: u64, split: abi.RocErasedCallable) abi.RocBox { defer abi.decrefErasedCallable(split, &roc_host); return registry.getWithSplit(value(raw), roles.CapabilitySplit.fromAbi(split), ops()) catch |err| die(@errorName(err)); }
export fn roc_host_value_take_with_split(raw: u64, split: abi.RocErasedCallable) abi.RocBox { defer abi.decrefErasedCallable(split, &roc_host); return registry.takeWithSplit(value(raw), roles.CapabilitySplit.fromAbi(split), ops()) catch |err| die(@errorName(err)); }
export fn roc_host_value_clone(raw: u64) u64 { return (registry.clone(allocator, value(raw), ops()) catch |err| die(@errorName(err))).toRaw(); }
extern fn spike_init() *anyopaque;
extern fn spike_step(*anyopaque, u64) *anyopaque;
extern fn spike_finish(*anyopaque) void;
export fn start() void { if (state != null) @trap(); state = spike_init(); }
export fn step(action: u64) void { const owned = state orelse @trap(); state = null; state = spike_step(owned, action); }
export fn finish() void { const owned = state orelse @trap(); state = null; spike_finish(owned); if (registry.hasLiveValues()) die("live values after teardown"); registry.deinit(allocator); registry = .{}; }
export fn metric(index: u32) u64 { return counts[index]; }
export fn live_values() u64 { return registry.liveCount(); }
