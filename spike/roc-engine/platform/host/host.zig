//! Phase 1 spike host for the pure Roc engine (`platform-roc/Engine.roc`).
//!
//! The host owns exactly two things between calls: one opaque `Box(Instance)`
//! and the command byte list of the last transaction. It never interprets
//! either. Each call moves both into Roc (clearing the slots first, so a trap
//! mid-call cannot leave a dangling owner) and stores the replacements Roc
//! returns. JavaScript reads the command bytes straight from linear memory via
//! `cmd_ptr`/`cmd_len`; they stay valid until the next `event` or `drop`.
//! Running out of memory or a Roc crash traps the instance (no recovery).
const std = @import("std");

const RocList = extern struct {
    ptr: ?[*]u8,
    len: usize,
    cap: usize,

    const empty: RocList = .{ .ptr = null, .len = 0, .cap = 0 };
};

/// Roc lays out `{ cmds : List(U8), state : Box(Instance) }` by alignment and
/// then field name: both are pointer-aligned here, so `cmds` comes first.
const Step = extern struct {
    cmds: RocList,
    state: *anyopaque,
};

extern fn roc_engine_init() callconv(.c) Step;
extern fn roc_engine_event(state: *anyopaque, buf: RocList, node: u32, handler: u32, payload: RocList) callconv(.c) Step;
extern fn roc_engine_drop(state: *anyopaque, buf: RocList) callconv(.c) void;

var state: ?*anyopaque = null;
var cmds: RocList = RocList.empty;

// ---------------------------------------------------------------------------
// Allocator: the same inline-header scheme as the production Wasm host, over
// the Zig Wasm page allocator. Counters are always on (a few adds per call).

const Header = extern struct { requested: usize, backing: usize };

/// alloc calls, dealloc calls, requested bytes, realloc calls, live count, live bytes
var counters: [6]u64 = @splat(0);
/// p3copy probe: sizes of the first 32 allocations since reset.
var sizes: [32]u64 = @splat(0);

fn alignment(bytes: usize) std.mem.Alignment {
    return std.mem.Alignment.fromByteUnits(@max(bytes, @sizeOf(usize)));
}

fn headerOffset(a: std.mem.Alignment) usize {
    return std.mem.alignForward(usize, @sizeOf(Header), a.toByteUnits());
}

fn allocRaw(size: usize, align_arg: usize) *anyopaque {
    const a = alignment(align_arg);
    const offset = headerOffset(a);
    const backing = offset + size;
    const base = std.heap.wasm_allocator.rawAlloc(backing, a, @returnAddress()) orelse @trap();
    const user = base + offset;
    const header: *Header = @ptrFromInt(@intFromPtr(user) - @sizeOf(Header));
    header.* = .{ .requested = size, .backing = backing };
    if (counters[0] < 32) sizes[@intCast(counters[0])] = size;
    counters[0] += 1;
    counters[2] += size;
    counters[4] += 1;
    counters[5] += size;
    return user;
}

fn freeRaw(ptr: *anyopaque, align_arg: usize) usize {
    const a = alignment(align_arg);
    const user: [*]u8 = @ptrCast(ptr);
    const header: *const Header = @ptrFromInt(@intFromPtr(user) - @sizeOf(Header));
    const h = header.*;
    counters[1] += 1;
    counters[4] -= 1;
    counters[5] -= h.requested;
    const base = user - headerOffset(a);
    std.heap.wasm_allocator.rawFree(base[0..h.backing], a, @returnAddress());
    return h.requested;
}

export fn roc_alloc(size: usize, align_arg: usize) callconv(.c) *anyopaque {
    return allocRaw(size, align_arg);
}

export fn roc_dealloc(ptr: *anyopaque, align_arg: usize) callconv(.c) void {
    _ = freeRaw(ptr, align_arg);
}

export fn roc_realloc(ptr: *anyopaque, size: usize, align_arg: usize) callconv(.c) *anyopaque {
    const user: [*]u8 = @ptrCast(ptr);
    const header: *const Header = @ptrFromInt(@intFromPtr(user) - @sizeOf(Header));
    const copied = @min(header.requested, size);
    const next = allocRaw(size, align_arg);
    @memcpy(@as([*]u8, @ptrCast(next))[0..copied], user[0..copied]);
    _ = freeRaw(ptr, align_arg);
    counters[3] += 1;
    // A realloc is one allocation request in the Roc ledger, not alloc + free.
    counters[0] -= 1;
    counters[1] -= 1;
    return next;
}

var last_error: [512]u8 = undefined;
var last_error_len: usize = 0;

fn keepError(bytes: [*]const u8, len: usize) void {
    const n = @min(len, last_error.len);
    @memcpy(last_error[0..n], bytes[0..n]);
    last_error_len = n;
}

export fn roc_dbg(bytes: [*]const u8, len: usize) callconv(.c) void {
    keepError(bytes, len);
}

export fn roc_expect_failed(bytes: [*]const u8, len: usize) callconv(.c) void {
    keepError(bytes, len);
    @trap();
}

export fn roc_crashed(bytes: [*]const u8, len: usize) callconv(.c) void {
    keepError(bytes, len);
    @trap();
}

// ---------------------------------------------------------------------------
// JavaScript-facing exports.

/// Mount the app: builds the instance and leaves the mount commands readable.
export fn init() callconv(.c) void {
    if (state != null) @trap();
    const step = roc_engine_init();
    state = step.state;
    cmds = step.cmds;
}

/// One DOM event = one transaction. The previous command bytes are handed back
/// to Roc for reuse; the new ones are readable until the next call.
export fn event(node: u32, handler: u32) callconv(.c) void {
    const owned = state orelse @trap();
    const buf = cmds;
    state = null;
    cmds = RocList.empty;
    // p4apps: size-measurement host. The event payload (input values) is not
    // marshalled from JavaScript yet; every event carries an empty payload.
    const step = roc_engine_event(owned, buf, node, handler, RocList.empty);
    state = step.state;
    cmds = step.cmds;
}

/// Release the instance and the command buffer (teardown).
export fn drop() callconv(.c) void {
    const owned = state orelse @trap();
    const buf = cmds;
    state = null;
    cmds = RocList.empty;
    roc_engine_drop(owned, buf);
}

export fn cmd_ptr() callconv(.c) usize {
    return if (cmds.ptr) |p| @intFromPtr(p) else 0;
}

export fn cmd_len() callconv(.c) usize {
    return cmds.len;
}

export fn metric(index: u32) callconv(.c) u64 {
    if (index >= 100 and index < 132) return sizes[index - 100];
    return if (index < counters.len) counters[index] else 0;
}

export fn reset_metrics() callconv(.c) void {
    @memset(counters[0..4], 0);
}

export fn err_ptr() callconv(.c) usize {
    return @intFromPtr(&last_error);
}

export fn err_len() callconv(.c) usize {
    return last_error_len;
}
