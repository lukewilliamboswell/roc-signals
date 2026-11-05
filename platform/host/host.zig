//! The Wasm host of the web platform for the pure Roc engine (`platform/Engine.roc`).
//!
//! The host owns exactly three things between calls: one opaque
//! `Box(Instance)`, the command byte list of the last transaction and the
//! engine's work record. It never interprets the state or the commands. Each
//! call moves all three into Roc (clearing the slots first, so a trap mid-call
//! cannot leave a dangling owner) and stores the replacements Roc returns.
//! JavaScript reads the command bytes and the work record straight from linear
//! memory via `cmd_ptr`/`cmd_len` and `work_ptr`/`work_len`; they stay valid
//! until the next `event` or `drop`.
//! Running out of memory or a Roc crash traps the instance (no recovery).
const std = @import("std");

const RocList = extern struct {
    ptr: ?[*]u8,
    len: usize,
    cap: usize,

    const empty: RocList = .{ .ptr = null, .len = 0, .cap = 0 };
};

/// Roc lays out `{ cmds : List(U8), state : Box(Instance), work : List(U8) }`
/// by alignment and then field name: all three are pointer-aligned here, so
/// the order is alphabetical.
const Step = extern struct {
    cmds: RocList,
    state: *anyopaque,
    work: RocList,
};

extern fn roc_engine_version() callconv(.c) u32;
extern fn roc_engine_keys() callconv(.c) RocList;
extern fn roc_engine_init(boot: RocList) callconv(.c) Step;
extern fn roc_engine_event(state: *anyopaque, buf: RocList, wbuf: RocList, node: u32, handler: u32, payload: RocList) callconv(.c) Step;
extern fn roc_engine_drop(state: *anyopaque, buf: RocList, wbuf: RocList) callconv(.c) void;

var state: ?*anyopaque = null;
var cmds: RocList = RocList.empty;
/// The engine's work record after the last call (design.md, Appendix B):
/// `count:u32 (counter:u64)*count`, then the cleanup runs by name.
var work: RocList = RocList.empty;

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
    const base = std.heap.wasm_allocator.rawAlloc(backing, a, @returnAddress()) orelse outOfMemory(size);
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

// ---------------------------------------------------------------------------
// Fault containment (design.md, "Memory management and allocation failure"
// and "Diagnostics contract"). A Roc crash, a failed expect or an allocation
// failure poisons the instance: the diagnostic is written to storage reserved
// here (no allocation, bounded), staged commands are discarded, and the call
// traps. A poisoned instance never re-enters Roc: every engine entry point
// traps immediately; only `fault`, `err_ptr`/`err_len`, `metric` and
// `cmd_len` (0) answer. Recovery is a fresh instance (JavaScript side).

/// Error classes (closed set): 0 healthy, 1 contract, 2 resource_limit,
/// 3 out_of_memory, 4 app_crash (any other Roc crash), 5 expect_failed.
var fault_class: u32 = 0;

var last_error: [512]u8 = undefined;
var last_error_len: usize = 0;

fn keepError(bytes: [*]const u8, len: usize) void {
    const n = @min(len, last_error.len);
    @memcpy(last_error[0..n], bytes[0..n]);
    last_error_len = n;
}

fn startsWith(bytes: [*]const u8, len: usize, prefix: []const u8) bool {
    return len >= prefix.len and std.mem.eql(u8, bytes[0..prefix.len], prefix);
}

fn poison(class: u32) noreturn {
    fault_class = class;
    // Staged (unpublished) commands are never observed; nothing is freed:
    // the Roc heap may be mid-mutation, so it is abandoned with the instance.
    cmds = RocList.empty;
    work = RocList.empty;
    pending_payload = RocList.empty;
    state = null;
    @trap();
}

fn outOfMemory(size: usize) noreturn {
    const msg = "out_of_memory: allocation failed";
    keepError(msg.ptr, msg.len);
    _ = size;
    poison(3);
}

export fn roc_dbg(bytes: [*]const u8, len: usize) callconv(.c) void {
    if (fault_class == 0) keepError(bytes, len);
}

export fn roc_expect_failed(bytes: [*]const u8, len: usize) callconv(.c) void {
    keepError(bytes, len);
    poison(5);
}

export fn roc_crashed(bytes: [*]const u8, len: usize) callconv(.c) void {
    keepError(bytes, len);
    const class: u32 = if (startsWith(bytes, len, "contract:")) 1 else if (startsWith(bytes, len, "resource_limit:")) 2 else 4;
    poison(class);
}

/// 0 when healthy, else the fault class of the poisoned instance.
export fn fault() callconv(.c) u32 {
    return fault_class;
}

/// The wire protocol version of the engine linked into this module. The
/// runtime reads it before anything else and refuses to mount a module whose
/// version it does not implement, so a stale `runtime.mjs` never misreads a
/// newer command stream. Pure: it allocates nothing and answers even when the
/// instance is poisoned.
export fn protocol_version() callconv(.c) u32 {
    return roc_engine_version();
}

fn refuseIfPoisoned() void {
    if (fault_class != 0) @trap();
}

// ---------------------------------------------------------------------------
// JavaScript-facing exports.

/// Before mount: the storage keys the app declares (count:u32 then key:str
/// each), readable through `cmd_ptr`/`cmd_len` until `init`. JavaScript reads
/// their values and stages the boot bytes with `payload_reserve`.
export fn boot_keys() callconv(.c) void {
    refuseIfPoisoned();
    if (state != null or cmds.ptr != null) @trap();
    cmds = roc_engine_keys();
}

/// Mount the app with the staged boot bytes (URL and storage values; empty
/// when nothing was staged): builds the instance and leaves the mount
/// commands readable. The key list buffer, if any, is released by Roc.
export fn init() callconv(.c) void {
    refuseIfPoisoned();
    if (state != null) @trap();
    const boot = pending_payload;
    pending_payload = RocList.empty;
    const keys = cmds;
    cmds = RocList.empty;
    const step = roc_engine_init(boot);
    state = step.state;
    cmds = step.cmds;
    work = step.work;
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
    refuseIfPoisoned();
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
    refuseIfPoisoned();
    const owned = state orelse @trap();
    const buf = cmds;
    const wbuf = work;
    const payload = pending_payload;
    state = null;
    cmds = RocList.empty;
    work = RocList.empty;
    pending_payload = RocList.empty;
    const step = roc_engine_event(owned, buf, wbuf, node, handler, payload);
    state = step.state;
    cmds = step.cmds;
    work = step.work;
}

/// Release the instance and the command buffer (teardown).
/// Teardown. Idempotent at the containment boundary: a poisoned instance
/// (or one already dropped) does nothing.
export fn drop() callconv(.c) void {
    if (fault_class != 0 or state == null) return;
    dropPending();
    const owned = state orelse @trap();
    const buf = cmds;
    const wbuf = work;
    state = null;
    cmds = RocList.empty;
    work = RocList.empty;
    roc_engine_drop(owned, buf, wbuf);
}

export fn cmd_ptr() callconv(.c) usize {
    return if (cmds.ptr) |p| @intFromPtr(p) else 0;
}

export fn cmd_len() callconv(.c) usize {
    return cmds.len;
}

/// The engine's work record after the last call, readable until the next
/// `event` or `drop` (0 and 0 before mount).
export fn work_ptr() callconv(.c) usize {
    return if (work.ptr) |p| @intFromPtr(p) else 0;
}

export fn work_len() callconv(.c) usize {
    return work.len;
}

/// Base of the engine's work counters in `metric`.
const work_base: u32 = 16;

/// Allocator counters (0-5), the engine's work counters (`16 + k` reads
/// counter `k` of the work record; 0 past its end), and the spike's
/// first-allocation sizes probe (100-131). The work counters are copied out
/// of the record the engine returned with the last call; the host does not
/// compute them.
export fn metric(index: u32) callconv(.c) u64 {
    if (index >= 100 and index < 132) return sizes[index - 100];
    if (index >= work_base and index < 100) return workCounter(index - work_base);
    return if (index < counters.len) counters[index] else 0;
}

fn workCounter(k: u32) u64 {
    const p = work.ptr orelse return 0;
    if (work.len < 4) return 0;
    const count = std.mem.readInt(u32, p[0..4], .little);
    if (k >= count) return 0;
    const at = 4 + @as(usize, k) * 8;
    if (at + 8 > work.len) return 0;
    return std.mem.readInt(u64, p[at..][0..8], .little);
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
