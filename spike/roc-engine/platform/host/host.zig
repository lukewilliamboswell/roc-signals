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

extern fn roc_engine_keys() callconv(.c) RocList;
extern fn roc_engine_init(boot: RocList) callconv(.c) Step;
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

/// Before mount: the storage keys the app declares (count:u32 then key:str
/// each), readable through `cmd_ptr`/`cmd_len` until `init`. JavaScript reads
/// their values and stages the boot bytes with `payload_reserve`.
export fn boot_keys() callconv(.c) void {
    if (state != null or cmds.ptr != null) @trap();
    cmds = roc_engine_keys();
}

/// Mount the app with the staged boot bytes (URL and storage values; empty
/// when nothing was staged): builds the instance and leaves the mount
/// commands readable. The key list buffer, if any, is released by Roc.
export fn init() callconv(.c) void {
    if (state != null) @trap();
    const boot = pending_payload;
    pending_payload = RocList.empty;
    const keys = cmds;
    cmds = RocList.empty;
    const step = roc_engine_init(boot);
    state = step.state;
    cmds = step.cmds;
    releaseList(keys);
}

/// Drop one reference to a Roc `List(U8)` the host owns (no-op for empty or
/// static lists); frees the allocation when it was the last one.
fn releaseList(list: RocList) void {
    if (list.cap & 1 != 0) @trap(); // the host never holds a seamless slice
    const p = list.ptr orelse return;
    const rc: *isize = @ptrCast(@alignCast(p - @sizeOf(usize)));
    if (rc.* == 0) return;
    if (rc.* == 1) {
        _ = freeRaw(p - @sizeOf(usize), @alignOf(usize));
    } else rc.* -= 1;
}

/// Payload bytes for the next `event`, staged by JavaScript through
/// `payload_reserve`. Owned by the host until `event` moves it into Roc.
var pending_payload: RocList = RocList.empty;

/// Allocate a Roc `List(U8)` of `len` bytes for the next event's payload and
/// return the address JavaScript writes the bytes to (0 when `len` is 0).
/// The list is laid out as Roc expects for a non-refcounted element type: one
/// usize refcount (1) directly before the elements, and the capacity stored
/// shifted left by one (the low bit tags a seamless slice). A
/// previously staged payload that was never delivered is freed first, so at
/// most one staged payload exists. JavaScript must re-read `memory.buffer`
/// after this call (the allocation may grow memory).
export fn payload_reserve(len: usize) callconv(.c) usize {
    dropPending();
    if (len == 0) return 0;
    const base: [*]u8 = @ptrCast(allocRaw(len + @sizeOf(usize), @alignOf(usize)));
    const rc: *isize = @ptrCast(@alignCast(base));
    rc.* = 1;
    const data = base + @sizeOf(usize);
    pending_payload = .{ .ptr = data, .len = len, .cap = len << 1 };
    return @intFromPtr(data);
}

fn dropPending() void {
    if (pending_payload.ptr) |p| _ = freeRaw(p - @sizeOf(usize), @alignOf(usize));
    pending_payload = RocList.empty;
}

/// One DOM event (or effect result) = one transaction. The previous command
/// bytes are handed back to Roc for reuse; the staged payload (if any) moves
/// into Roc, which owns and frees it. The new commands are readable until the
/// next call.
export fn event(node: u32, handler: u32) callconv(.c) void {
    const owned = state orelse @trap();
    const buf = cmds;
    const payload = pending_payload;
    state = null;
    cmds = RocList.empty;
    pending_payload = RocList.empty;
    const step = roc_engine_event(owned, buf, node, handler, payload);
    state = step.state;
    cmds = step.cmds;
}

/// Release the instance and the command buffer (teardown).
export fn drop() callconv(.c) void {
    dropPending();
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
