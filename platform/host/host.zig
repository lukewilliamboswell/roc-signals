//! The Wasm host of the web platform for the pure Roc engine (`platform/Engine.roc`).
//!
//! The host owns exactly three things between calls: one opaque engine
//! handle (`Box(Iter(App))`), the command byte list of the last transaction and the
//! engine's work record. It never interprets the state or the commands. Each
//! call moves all three into Roc (clearing the slots first, so a trap mid-call
//! cannot leave a dangling owner) and stores the replacements Roc returns.
//! JavaScript reads the command bytes and the work record straight from linear
//! memory via `cmd_ptr`/`cmd_len` and `work_ptr`/`work_len`; they stay valid
//! until the next `event` or `drop`.
//! An instance a Web Worker runs never mounts: its engine calls are a
//! job's (`work`, or `prepare` and `ask` for a preparation's task), whose
//! answer occupies the command buffer's slot.
//! Running out of memory or a Roc crash traps the instance (no recovery).
const std = @import("std");
const resources = @import("resources.zig");

const RocList = extern struct {
    ptr: ?[*]u8,
    len: usize,
    cap: usize,

    const empty: RocList = .{ .ptr = null, .len = 0, .cap = 0 };
};

/// Roc lays out `{ cmds : List(U8), state : Box(Iter(App)), work : List(U8) }`
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
extern fn roc_engine_files(state: *anyopaque, buf: RocList, wbuf: RocList, node: u32, handler: u32, record: RocList, blobs: RocList) callconv(.c) Step;
extern fn roc_engine_work(payload: RocList, handles: RocList) callconv(.c) RocList;

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

// Large allocations (a megabyte or more) bypass the Zig Wasm allocator, which
// rounds them up to a power of two of 64 KiB pages: a 64 MiB list would hold
// 128 MiB of linear memory. They come instead from whole Wasm pages, taken
// with `memory.grow` and kept, once freed, on a free list of runs sorted by
// address so that neighbours coalesce. Linear memory never shrinks, so a
// freed run is only ever reused. Smaller allocations are unchanged.

const wasm_page: usize = 64 * 1024;
const large_threshold: usize = 1024 * 1024;

/// A free run of whole pages, stored in its own first bytes.
const FreeRun = struct { pages: usize, next: ?*FreeRun };

/// Free runs in ascending address order.
var free_runs: ?*FreeRun = null;

fn runAddress(run: *FreeRun) usize {
    return @intFromPtr(run);
}

/// `pages` whole pages: the first free run large enough, split from its
/// front, or new pages from `memory.grow`. Null when memory cannot grow.
fn largeAlloc(pages: usize) ?[*]u8 {
    var link: *?*FreeRun = &free_runs;
    while (link.*) |run| : (link = &run.next) {
        if (run.pages < pages) continue;
        if (run.pages == pages) {
            link.* = run.next;
        } else {
            const rest: *FreeRun = @ptrFromInt(runAddress(run) + pages * wasm_page);
            rest.* = .{ .pages = run.pages - pages, .next = run.next };
            link.* = rest;
        }
        return @ptrCast(run);
    }
    const before = @wasmMemoryGrow(0, pages);
    if (before < 0) return null;
    return @ptrFromInt(@as(usize, @intCast(before)) * wasm_page);
}

/// Return `pages` whole pages at `base` to the free list, merging with the
/// runs on either side.
fn largeFree(base: [*]u8, pages: usize) void {
    const address = @intFromPtr(base);
    var prev: ?*FreeRun = null;
    var next = free_runs;
    while (next) |run| : (next = run.next) {
        if (runAddress(run) > address) break;
        prev = run;
    }
    var run: *FreeRun = @ptrCast(@alignCast(base));
    run.* = .{ .pages = pages, .next = next };
    if (next) |n| if (address + pages * wasm_page == runAddress(n)) {
        run.pages += n.pages;
        run.next = n.next;
    };
    if (prev) |p| {
        if (runAddress(p) + p.pages * wasm_page == address) {
            p.pages += run.pages;
            p.next = run.next;
            run = p;
        } else p.next = run;
    } else free_runs = run;
}

fn largePages(backing: usize) usize {
    return (backing + wasm_page - 1) / wasm_page;
}

fn allocRaw(size: usize, align_arg: usize) *anyopaque {
    const a = alignment(align_arg);
    const offset = headerOffset(a);
    const backing = offset + size;
    const base = (if (backing >= large_threshold) largeAlloc(largePages(backing)) else std.heap.wasm_allocator.rawAlloc(backing, a, @returnAddress())) orelse outOfMemory(size);
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
    if (h.backing >= large_threshold) largeFree(base, largePages(h.backing)) else std.heap.wasm_allocator.rawFree(base[0..h.backing], a, @returnAddress());
    return h.requested;
}

export fn roc_alloc(size: usize, align_arg: usize) callconv(.c) *anyopaque {
    return allocRaw(size, align_arg);
}

export fn roc_dealloc(ptr: *anyopaque, align_arg: usize) callconv(.c) void {
    switch (blobs.route(ptr)) {
        .not_owned => _ = freeRaw(ptr, align_arg),
        .retired => return,
        .corrupt => corruptHandle(),
    }
}

export fn roc_realloc(ptr: *anyopaque, size: usize, align_arg: usize) callconv(.c) *anyopaque {
    if (blobs.contains(ptr)) corruptHandle();
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
    // the Roc heap may be mid-mutation, so it is abandoned with the instance,
    // and so are its handles (the runtime lets go of every file it holds).
    cmds = RocList.empty;
    work = RocList.empty;
    pending_payload = RocList.empty;
    pending_blobs = RocList.empty;
    blobs.abandon(nothing);
    state = null;
    held = null;
    @trap();
}

fn nothing(_: anytype) void {}

/// Roc freed or resized an address inside the handle table that is not a
/// handle's last release: the instance's ownership is incoherent.
fn corruptHandle() noreturn {
    const msg = "internal: a file handle was released twice or resized";
    keepError(msg.ptr, msg.len);
    poison(4);
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

/// Run one worker job (design.md, "Workers" and Appendix B). The staged
/// payload, `name:str input:rest`, and the handles `files_stage` minted for
/// the job's files, in the request's order, move into Roc, which runs the
/// catalogue's task of that name; its answer, `n:u32 (token:u64)*
/// output:rest`, takes the command buffer's slot and stays readable through
/// `cmd_ptr`/`cmd_len` until the next call, and the previous call's answer
/// is released first, so a worker instance holds at most one. Ownership:
/// the payload and the handle list belong to Roc from the call on; the
/// answer belongs to the host until the next call; the handles the answer
/// names are released by Roc when the call returns (retired, not freed), so
/// their tokens still resolve until the worker script drains
/// `files_released`. The task may call the hosted effects below for the
/// length of the call. A mounted instance (the page's) never runs a job:
/// calling it there is a contract fault, and so is a crash in the job (an
/// unknown name or an undecodable payload is a `contract:` crash), which
/// poisons this instance like any other call; the slots were cleared
/// before the call, so nothing dangles. Exported as `work` (the name
/// `work` here is the work record's slot).
fn runWork() callconv(.c) void {
    refuseIfWorkOnPage("work");
    const payload = pending_payload;
    const handles = pending_blobs;
    const previous = cmds;
    pending_payload = RocList.empty;
    pending_blobs = RocList.empty;
    cmds = RocList.empty;
    releaseList(previous);
    in_task = true;
    cmds = roc_engine_work(payload, handles);
    in_task = false;
}

/// A job's entry called on a poisoned instance traps; one called on the
/// page's mounted instance is a contract fault of that instance.
fn refuseIfWorkOnPage(comptime entry: []const u8) void {
    refuseIfPoisoned();
    if (state != null) {
        const msg = "contract: " ++ entry ++ "() was called on the page's instance; a job runs only in a worker instance";
        keepError(msg.ptr, msg.len);
        poison(1);
    }
}

/// The elements of a fresh Roc list of `n` refcounted elements of `size`
/// bytes, laid out as Roc lays one out: the list's original length, then
/// its refcount (1), each a `usize`, then the elements. Roc frees it two
/// `usize`s before the elements.
fn refcountedList(n: usize, size: usize) [*]u8 {
    const base: [*]u8 = @ptrCast(allocRaw(n * size + 2 * @sizeOf(usize), @alignOf(usize)));
    const words: [*]usize = @ptrCast(@alignCast(base));
    words[0] = n;
    words[1] = 1;
    return base + 2 * @sizeOf(usize);
}

comptime {
    @export(&runWork, .{ .name = "work" });
}

// ---------------------------------------------------------------------------
// Prepared state (design.md, "Prepared state"). A worker instance may keep
// one prepared state between jobs: an opaque `Box(Kept)` the host owns
// exactly as a page's host owns its engine handle. It never interprets it. Each call
// clears the slot before moving the box into Roc, so a trap mid-call
// abandons it with the heap and nothing dangles. Both calls may perform the
// hosted effects, as a job does; the files a state keeps are handles it
// holds, which stay live (and their objects in the worker script) for as
// long as the state does.

const Held = extern struct {
    held: *anyopaque,
    out: RocList,
};

extern fn roc_engine_prepare(payload: RocList, handles: RocList) callconv(.c) *anyopaque;
extern fn roc_engine_ask(held: *anyopaque, payload: RocList, handles: RocList) callconv(.c) Held;
extern fn roc_engine_forget(held: *anyopaque) callconv(.c) void;

/// The prepared state this worker instance keeps, if any (at most one).
var held: ?*anyopaque = null;

/// Let Roc drop the held state, if there is one.
fn forgetHeld() void {
    const owned = held orelse return;
    held = null;
    roc_engine_forget(owned);
}

/// Prepare and keep a state (design.md, Appendix B): the state held before
/// is released first, so an instance never holds two, then the staged
/// payload, `prep:str init:rest`, and the handles `files_stage` minted for
/// the preparation's files move into Roc, which runs that preparation and
/// returns the state the host keeps. The previous job's answer is released
/// too; a prepare has none. Refuses like `work` when an engine state is
/// mounted or the instance is poisoned; a crash in the preparation poisons
/// this instance, and the slot was already empty. The worker script closes
/// every builder the preparation opened when it returns, so a builder the
/// state keeps is refused to every later job.
export fn prepare() callconv(.c) void {
    refuseIfWorkOnPage("prepare");
    forgetHeld();
    const previous = cmds;
    cmds = RocList.empty;
    releaseList(previous);
    const payload = pending_payload;
    const handles = pending_blobs;
    pending_payload = RocList.empty;
    pending_blobs = RocList.empty;
    in_task = true;
    held = roc_engine_prepare(payload, handles);
    in_task = false;
}

/// Run a preparation's task on the held state: the staged payload,
/// `task:str input:rest`, and the handles minted for the job's own files
/// move into Roc with the state, which comes back with the job's answer;
/// the answer is readable through `cmd_ptr`/`cmd_len` until the next call,
/// as for `work`. Traps when no state is held: the runtime asks only an
/// instance it prepared.
export fn ask() callconv(.c) void {
    refuseIfWorkOnPage("ask");
    const owned = held orelse @trap();
    held = null;
    const previous = cmds;
    cmds = RocList.empty;
    releaseList(previous);
    const payload = pending_payload;
    const handles = pending_blobs;
    pending_payload = RocList.empty;
    pending_blobs = RocList.empty;
    in_task = true;
    const step = roc_engine_ask(owned, payload, handles);
    in_task = false;
    held = step.held;
    cmds = step.out;
}

/// Release the held state (eviction, or before the instance prepares
/// another); a no-op when none is held or the instance is poisoned. The
/// last job's output is released with it, so afterwards the instance holds
/// nothing a job left behind.
export fn forget() callconv(.c) void {
    if (fault_class != 0) return;
    forgetHeld();
    const previous = cmds;
    cmds = RocList.empty;
    releaseList(previous);
}

// ---------------------------------------------------------------------------
// File handles (design.md, "Files"). The runtime holds each browser `Blob`
// under a token; the host mints a `Box(U64)` holding that token in its blob
// heap, and Roc's reference count decides when the app is done with it. A
// handle whose last reference went is retired, not freed: its token stays
// valid until the runtime has performed the batch's effects (which may still
// name it) and then drains the released list with `files_released`.

/// The most file handles live at once in one instance (design.md,
/// "Boundedness"). Files an event carries beyond the free slots are refused.
const max_files: usize = 64;

var blobs: resources.Heap(.blob, max_files, void) = .{};

/// The handles minted for the next `event_files`, as a Roc
/// `List(Box(U64))` the host owns until the call moves it into Roc.
var pending_blobs: RocList = RocList.empty;

/// The tokens of the staged handles, then of the released ones, for
/// JavaScript to read (`files_tokens`).
var tokens: [max_files]u64 = @splat(0);

/// Mint up to `n` handles for the next `event_files`, as many as there are
/// free slots: returns how many, their tokens readable at `files_tokens()`.
/// Handles staged before and never delivered are released first, so at most
/// one staged set exists. JavaScript must re-read `memory.buffer` after this
/// call.
export fn files_stage(n: u32) callconv(.c) u32 {
    refuseIfPoisoned();
    dropPendingBlobs();
    const want = @min(@as(usize, n), max_files - blobs.live_count);
    if (want == 0) return 0;
    // A list of box pointers, each element the address of a handle's payload.
    const elems: [*]usize = @ptrCast(@alignCast(refcountedList(want, @sizeOf(usize))));
    for (0..want) |i| {
        const payload = blobs.mint({}) orelse unreachable;
        elems[i] = @intFromPtr(payload);
        tokens[i] = payload.*;
    }
    pending_blobs = .{ .ptr = @ptrCast(elems), .len = want, .cap = want << 1 };
    return @intCast(want);
}

/// Release staged handles no call took: nothing in Roc refers to them yet,
/// so the host retires them itself.
fn dropPendingBlobs() void {
    const p = pending_blobs.ptr orelse return;
    const elems: [*]usize = @ptrCast(@alignCast(p));
    for (0..pending_blobs.len) |i| _ = blobs.route(@ptrFromInt(elems[i] - 8));
    _ = freeRaw(p - 2 * @sizeOf(usize), @alignOf(usize));
    pending_blobs = RocList.empty;
}

/// Where `files_stage` and `files_released` leave their tokens.
export fn files_tokens() callconv(.c) usize {
    return @intFromPtr(&tokens);
}

/// A `:files` event (design.md, Appendix B): the staged payload is the
/// event's file record and the staged handles its files, in order; both move
/// into Roc for one transaction, like `event`.
export fn event_files(node: u32, handler: u32) callconv(.c) void {
    refuseIfPoisoned();
    const owned = state orelse @trap();
    const buf = cmds;
    const wbuf = work;
    const record = pending_payload;
    const staged = pending_blobs;
    state = null;
    cmds = RocList.empty;
    work = RocList.empty;
    pending_payload = RocList.empty;
    pending_blobs = RocList.empty;
    const step = roc_engine_files(owned, buf, wbuf, node, handler, record, staged);
    state = step.state;
    cmds = step.cmds;
    work = step.work;
}

/// After JavaScript has applied a batch and performed its effects: free the
/// slots of the handles Roc released and return how many, their tokens
/// readable at `files_tokens()`, so the runtime lets their `Blob`s go.
export fn files_released() callconv(.c) u32 {
    if (fault_class != 0) return 0;
    var n: usize = 0;
    var token: u64 = 0;
    while (n < max_files and blobs.releaseOne(&token, nothing)) : (n += 1) tokens[n] = token;
    return @intCast(n);
}

// ---------------------------------------------------------------------------
// Hosted effects (design.md, "Workers"). A worker instance runs a job with
// `work()` (or `prepare()` and `ask()`): the job's files are handles the
// worker script staged with `files_stage`, in the request's order, and the
// task calls the platform's hosted effects on them (`roc_task_*`, below).
// Each hosted effect is performed by an import of the worker script, which
// holds the browser objects behind the tokens; the host only checks that a
// job is running, moves bytes in and out of linear memory, and mints
// handles. Builders and their parts live in the worker script, named by a
// token of this instance's blob heap, never here.

/// The worker script's halves of the hosted effects. A page instance
/// supplies stubs that throw; the host never calls one outside a job.
extern "env" fn js_file_read(token: u64, start: u64, len: u64, dst: usize) u32;
extern "env" fn js_file_size(token: u64) u64;
extern "env" fn js_builder_open(token: u64, name: usize, name_len: usize, mime: usize, mime_len: usize, from: u64, start: u64, len: u64) u32;
extern "env" fn js_builder_append(token: u64, src: usize, len: usize) u32;
extern "env" fn js_builder_append_file(token: u64, file: u64, start: u64, len: u64) u32;
extern "env" fn js_builder_finish(token: u64, file: u64) u32;

/// Whether a job (or a preparation) is running: the hosted effects refuse
/// to act otherwise. Set only for the length of `work()`, `prepare()` and
/// `ask()`.
var in_task: bool = false;

/// A hosted effect reached outside a job: a contract fault of this
/// instance, classified like any other, rather than a JavaScript exception
/// unwinding through Wasm.
fn outsideTask(comptime effect: []const u8) noreturn {
    const msg = "contract: " ++ effect ++ " is a worker effect and ran outside a job; only a worker task's job (Worker.task) may call it";
    keepError(msg.ptr, msg.len);
    poison(1);
}

/// Release one reference to a `List(U8)` a hosted function was given
/// (hosted functions own their arguments). A seamless slice keeps its
/// allocation's address, tagged in the low bit, in place of the capacity.
fn releaseArg(list: RocList) void {
    const alloc_ptr: [*]u8 = if (list.cap & 1 != 0) @ptrFromInt(list.cap & ~@as(usize, 1)) else (list.ptr orelse return);
    const rc: *isize = @ptrCast(@alignCast(alloc_ptr - @sizeOf(usize)));
    if (rc.* == 0) return;
    if (rc.* == 1) {
        roc_dealloc(alloc_ptr - @sizeOf(usize), @alignOf(usize));
    } else rc.* -= 1;
}

/// `Hosted.read!`: `len` bytes at `start` of the file behind `token`, read
/// by the worker script straight into a fresh Roc list the host allocates
/// (one copy). The list's single reference passes to Roc. When the browser
/// cannot read the file the list is freed and an empty one returned, which
/// Roc reads as `Unreadable` (it asked for `len` bytes).
fn hostedRead(token: u64, start: u64, len: u64) callconv(.c) RocList {
    if (!in_task) outsideTask("File.read!");
    if (len == 0) return RocList.empty;
    const n: usize = std.math.cast(usize, len) orelse outOfMemory(std.math.maxInt(usize));
    const base: [*]u8 = @ptrCast(allocRaw(n + @sizeOf(usize), @alignOf(usize)));
    @as(*isize, @ptrCast(@alignCast(base))).* = 1;
    const data = base + @sizeOf(usize);
    if (js_file_read(token, start, len, @intFromPtr(data)) == 0) {
        _ = freeRaw(base, @alignOf(usize));
        return RocList.empty;
    }
    return .{ .ptr = data, .len = n, .cap = n << 1 };
}

/// `Hosted.size!`: the size of the file behind `token`.
fn hostedSize(token: u64) callconv(.c) u64 {
    if (!in_task) outsideTask("Builder.finish!");
    return js_file_size(token);
}

/// `Hosted.mint!`: a fresh handle in this instance's blob heap, refcount 1,
/// owned by Roc. Its last release retires the slot; the worker script lets
/// go of the object behind it when it drains `files_released` after the
/// job. A job that holds more handles than the heap has is a
/// resource-limit fault.
fn hostedMint() callconv(.c) *u64 {
    if (!in_task) outsideTask("File.build!");
    return blobs.mint({}) orelse {
        const msg = "resource_limit: a task's job holds more than 64 files and builders at once";
        keepError(msg.ptr, msg.len);
        poison(2);
    };
}

/// `Hosted.open!`: make `token` a builder. The name and type lists are
/// read in place and released here.
fn hostedOpen(token: u64, name: RocList, mime: RocList, from: u64, start: u64, len: u64) callconv(.c) u8 {
    if (!in_task) outsideTask("File.build!");
    const status = js_builder_open(token, if (name.ptr) |p| @intFromPtr(p) else 0, name.len, if (mime.ptr) |p| @intFromPtr(p) else 0, mime.len, from, start, len);
    releaseArg(name);
    releaseArg(mime);
    return @intCast(status);
}

/// `Hosted.append!`: the worker script copies `bytes` out of linear memory
/// into a part of its own (the one copy of a written byte), then the list
/// is released here.
fn hostedAppend(token: u64, bytes: RocList) callconv(.c) u8 {
    if (!in_task) outsideTask("Builder.append!");
    const status = js_builder_append(token, if (bytes.ptr) |p| @intFromPtr(p) else 0, bytes.len);
    releaseArg(bytes);
    return @intCast(status);
}

/// `Hosted.append_file!`: a range of a file, by reference.
fn hostedAppendFile(token: u64, file: u64, start: u64, len: u64) callconv(.c) u8 {
    if (!in_task) outsideTask("Builder.append_file!");
    return @intCast(js_builder_append_file(token, file, start, len));
}

/// `Hosted.finish!`: the worker script composes the builder's parts into
/// one immutable object behind the fresh handle `file`.
fn hostedFinish(token: u64, file: u64) callconv(.c) u8 {
    if (!in_task) outsideTask("Builder.finish!");
    return @intCast(js_builder_finish(token, file));
}

comptime {
    @export(&hostedRead, .{ .name = "roc_task_read" });
    @export(&hostedSize, .{ .name = "roc_task_size" });
    @export(&hostedMint, .{ .name = "roc_task_mint" });
    @export(&hostedOpen, .{ .name = "roc_task_open" });
    @export(&hostedAppend, .{ .name = "roc_task_append" });
    @export(&hostedAppendFile, .{ .name = "roc_task_append_file" });
    @export(&hostedFinish, .{ .name = "roc_task_finish" });
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

/// Allocator counters (0-5), the live file handles (6), whether a prepared
/// state is held (8: 1 or 0), the engine's work counters (`16 + k` reads
/// counter `k` of the work record; 0 past its end), and the spike's
/// first-allocation sizes probe (100-131). The work counters are copied out
/// of the record the engine returned with the last call; the host does not
/// compute them.
export fn metric(index: u32) callconv(.c) u64 {
    if (index >= 100 and index < 132) return sizes[index - 100];
    if (index == 6) return blobs.live_count;
    if (index == 8) return @intFromBool(held != null);
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
