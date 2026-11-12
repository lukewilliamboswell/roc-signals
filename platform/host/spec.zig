//! The native host of the roc-signals platform: `roc build --target=<system>`
//! of an app gives its `.scm` spec runner, for Linux (`x64musl`), macOS
//! (`arm64mac`, `x64mac`) and Windows (`x64win`).
//!
//! It owns the process entry point, the allocator, crash reporting and the
//! `Cli` services the runner uses (`platform/Cli.roc`), and hands the
//! command-line arguments to the platform's `roc_spec_main` (the
//! `SpecRunner.main!` of the app's `main`), exiting with its result. Roc owns
//! every value it receives: the argument list is allocated with `roc_alloc`,
//! hosted arguments are released here, and the file contents returned by
//! `roc_test_read_file` are a fresh Roc list whose single reference passes to
//! Roc. A Roc crash or a failed `expect` prints its message to stderr and
//! exits with status 70 and 71: a runner whose state may be incoherent has
//! nothing correct left to report.
//!
//! A worker job is the exception (`roc_test_work`). The runner runs each job
//! in a child process started from its own executable, as the browser runs
//! it in a Web Worker, a fresh instance of the same module: the child reads
//! the job from its standard input, calls the platform's `roc_engine_work`
//! (or `roc_engine_prepare` and `roc_engine_ask`), the entries a worker
//! instance calls, serves the job's hosted effects, and writes the answer to
//! its standard output, so a task that crashes poisons only the child, and
//! the runner receives the lost job's fault class as the page would. Every
//! system takes this one path; only how a process is started, fed and
//! waited for differs, and that lives with the rest of each system's
//! services in `os_posix.zig` and `os_windows.zig`.

const std = @import("std");
const builtin = @import("builtin");
const resources = @import("resources.zig");

/// The system's services: files, output, time, memory, the process and
/// its job children.
const os = if (builtin.os.tag == .windows) @import("os_windows.zig") else @import("os_posix.zig");

// The command-line entry the platform provides (`SpecRunner.main!`).
extern fn roc_spec_main(args: RocList) callconv(.c) i32;

const RocStr = extern struct {
    bytes: ?[*]u8,
    capacity_or_alloc_ptr: usize,
    length: usize,

    const small_bit: usize = @as(usize, 1) << (@bitSizeOf(usize) - 1);

    fn isSmall(self: *const RocStr) bool {
        return (self.length & small_bit) != 0;
    }

    fn slice(self: *const RocStr) []const u8 {
        if (self.isSmall()) {
            const raw: [*]const u8 = @ptrCast(self);
            return raw[0 .. raw[@sizeOf(RocStr) - 1] ^ 0x80];
        }
        const ptr = self.bytes orelse return &.{};
        return ptr[0..self.length];
    }

    fn fromSlice(bytes: []const u8) RocStr {
        if (bytes.len < @sizeOf(RocStr)) {
            var result: RocStr = .{ .bytes = null, .capacity_or_alloc_ptr = 0, .length = 0 };
            const raw: [*]u8 = @ptrCast(&result);
            @memset(raw[0..@sizeOf(RocStr)], 0);
            @memcpy(raw[0..bytes.len], bytes);
            raw[@sizeOf(RocStr) - 1] = @as(u8, @intCast(bytes.len)) | 0x80;
            return result;
        }
        const base: [*]u8 = @ptrCast(roc_alloc(@sizeOf(usize) + bytes.len, @alignOf(usize)));
        const data = base + @sizeOf(usize);
        @as(*isize, @ptrCast(@alignCast(base))).* = 1;
        @memcpy(data[0..bytes.len], bytes);
        return .{ .bytes = data, .capacity_or_alloc_ptr = bytes.len << 1, .length = bytes.len };
    }

    /// Release one reference; hosted functions own their string arguments.
    fn decref(self: RocStr) void {
        if (self.isSmall()) return;
        const alloc_addr: usize = if ((self.capacity_or_alloc_ptr & 1) != 0)
            self.capacity_or_alloc_ptr & ~@as(usize, 1)
        else
            @intFromPtr(self.bytes orelse return);
        const rc: *isize = @ptrFromInt(alloc_addr - @sizeOf(isize));
        if (rc.* == 0) return; // static data
        rc.* -= 1;
        if (rc.* == 0) roc_dealloc(@ptrFromInt(alloc_addr - @sizeOf(usize)), @alignOf(usize));
    }
};

const RocList = extern struct {
    elements: ?*anyopaque,
    length: usize,
    capacity_or_alloc_ptr: usize,
};

/// A fresh `List(U8)` holding a copy of `bytes`, owned by the caller.
fn bytesList(bytes: []const u8) RocList {
    if (bytes.len == 0) return .{ .elements = null, .length = 0, .capacity_or_alloc_ptr = 0 };
    const base: [*]u8 = @ptrCast(roc_alloc(@sizeOf(usize) + bytes.len, @alignOf(usize)));
    @as(*isize, @ptrCast(@alignCast(base))).* = 1;
    const data = base + @sizeOf(usize);
    @memcpy(data[0..bytes.len], bytes);
    return .{ .elements = data, .length = bytes.len, .capacity_or_alloc_ptr = bytes.len << 1 };
}

/// A fresh `List(Str)` of the process arguments, owned by the caller. A list
/// of refcounted elements carries its element count before the refcount.
fn argsList(args: []const [*:0]const u8) RocList {
    if (args.len == 0) return .{ .elements = null, .length = 0, .capacity_or_alloc_ptr = 0 };
    const header = 2 * @sizeOf(usize);
    const base: [*]u8 = @ptrCast(roc_alloc(header + args.len * @sizeOf(RocStr), @alignOf(usize)));
    const words: [*]usize = @ptrCast(@alignCast(base));
    words[0] = args.len;
    @as(*isize, @ptrCast(&words[1])).* = 1;
    const items: [*]RocStr = @ptrCast(@alignCast(base + header));
    for (args, 0..) |arg, index| items[index] = RocStr.fromSlice(std.mem.span(arg));
    return .{ .elements = items, .length = args.len, .capacity_or_alloc_ptr = args.len << 1 };
}

/// Write to standard error or output; a runner that cannot report has
/// nothing correct left to do, and exits with status 3.
fn writeErr(bytes: []const u8) void {
    if (!os.writeAll(.err, bytes)) os.exitProcess(3);
}

fn writeOut(bytes: []const u8) void {
    if (!os.writeAll(.out, bytes)) os.exitProcess(3);
}

// ---------------------------------------------------------------------------
// The allocator and crash reporting Roc calls. Each allocation carries a
// header before the pointer Roc sees, holding the requested size, so
// `roc_realloc` knows how much to copy.

const header_size: usize = 16;

// How many of Roc's allocations are live, and how many bytes they asked
// for: the runner's soak reads them around each replayed round trip
// (`Cli.live_allocations!`, `Cli.live_bytes!`) and requires both flat after
// a warm-up. A handle's box comes from the handle heap, not from here, and
// is not counted. The counts are this process's: a worker job runs in a
// child process of its own, whose allocations end with it, and a soak's
// replay delivers the answer it recorded rather than starting a child, so
// it measures the runner's engine alone.
var live_allocations: u64 = 0;
var live_bytes: u64 = 0;

fn alignment(align_arg: usize) usize {
    return @max(align_arg, header_size);
}

export fn roc_alloc(size: usize, align_arg: usize) callconv(.c) *anyopaque {
    const a = alignment(align_arg);
    const total = std.mem.alignForward(usize, a + size, a);
    const base: [*]u8 = @ptrCast(os.alloc(a, total) orelse fail("out of memory", ""));
    const user = base + a;
    @as(*usize, @ptrCast(@alignCast(user - header_size))).* = size;
    live_allocations += 1;
    live_bytes += size;
    return user;
}

export fn roc_dealloc(ptr: *anyopaque, align_arg: usize) callconv(.c) void {
    switch (blobs.route(ptr)) {
        .not_owned => {},
        .retired => return,
        .corrupt => fail("internal: a file handle was released twice", ""),
    }
    const user: [*]u8 = @ptrCast(ptr);
    live_allocations -= 1;
    live_bytes -= @as(*const usize, @ptrCast(@alignCast(user - header_size))).*;
    os.release(user - alignment(align_arg));
}

export fn roc_realloc(ptr: *anyopaque, size: usize, align_arg: usize) callconv(.c) *anyopaque {
    if (blobs.contains(ptr)) fail("internal: a file handle was resized", "");
    const user: [*]u8 = @ptrCast(ptr);
    const old = @as(*const usize, @ptrCast(@alignCast(user - header_size))).*;
    const next = roc_alloc(size, align_arg);
    @memcpy(@as([*]u8, @ptrCast(next))[0..@min(old, size)], user[0..@min(old, size)]);
    roc_dealloc(ptr, align_arg);
    return next;
}

export fn roc_dbg(bytes: [*]const u8, len: usize) callconv(.c) void {
    writeErr("[dbg] ");
    writeErr(bytes[0..len]);
    writeErr("\n");
}

export fn roc_expect_failed(bytes: [*]const u8, len: usize) callconv(.c) void {
    if (in_job) jobFault(5, bytes[0..len]);
    writeErr("expect failed: ");
    writeErr(bytes[0..len]);
    writeErr("\n");
    os.exitProcess(71);
}

export fn roc_crashed(bytes: [*]const u8, len: usize) callconv(.c) void {
    if (in_job) jobFault(crashClass(bytes[0..len]), bytes[0..len]);
    writeErr("crashed: ");
    writeErr(bytes[0..len]);
    writeErr("\n");
    os.exitProcess(70);
}

fn fail(comptime prefix: []const u8, detail: []const u8) noreturn {
    if (in_job and std.mem.eql(u8, prefix, "out of memory")) jobFault(3, prefix);
    writeErr(prefix);
    writeErr(detail);
    writeErr("\n");
    os.exitProcess(2);
}

/// A NUL-terminated copy of `path`, or null when it holds a NUL byte.
fn cPath(path: []const u8) ?[*:0]u8 {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return null;
    const buf = os.alloc(16, path.len + 1) orelse fail("out of memory copying a path: ", path);
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return @ptrCast(buf);
}

fn hostedReadFile(path: RocStr) callconv(.c) RocList {
    defer path.decref();
    const name = path.slice();
    const c_name = cPath(name) orelse fail("cannot read a path containing NUL: ", name);
    defer os.release(c_name);
    const file = os.openFile(c_name) orelse fail("cannot open ", name);
    defer os.closeFile(file);
    var buf: Growing = .{};
    defer buf.deinit();
    while (true) {
        const room = buf.room() orelse fail("out of memory reading ", name);
        const n = os.readSome(file, room) orelse fail("cannot read ", name);
        if (n == 0) break;
        buf.len += n;
    }
    return bytesList(buf.bytes());
}

fn hostedFileExists(path: RocStr) callconv(.c) bool {
    defer path.decref();
    const c_name = cPath(path.slice()) orelse return false;
    defer os.release(c_name);
    return os.isFile(c_name);
}

fn hostedStdout(text: RocStr) callconv(.c) void {
    defer text.decref();
    writeOut(text.slice());
}

fn hostedStderr(text: RocStr) callconv(.c) void {
    defer text.decref();
    writeErr(text.slice());
}

/// The native spec host's copy of the page's file handles (design.md,
/// "Files"): the same heap the Wasm host mints them in, so a spec observes
/// their release as the page's runtime does. Its bound is the page's. In a
/// task job's child process the same heap is the worker instance's, and
/// each slot carries what the worker script would hold for its token: a
/// file's bytes, or a builder's (see "Tasks" below). The runner's own
/// process never fills one in.
var blobs: resources.Heap(.blob, 64, Held) = .{};

/// What a job's child holds behind a token, as the worker script holds a
/// `Blob` or a builder's parts: nothing (a page handle), a file's bytes, an
/// open builder, a builder that was finished, or one the call that opened
/// it has left behind (a builder a prepared state kept).
const Held = struct {
    kind: enum { none, file, builder, finished, expired } = .none,
    bytes: []u8 = &.{},
    cap: usize = 0,
    name: []const u8 = "",
    mime: []const u8 = "",
};

fn nothing(_: anytype) void {}

/// `Cli.mint_files!`: up to `n` fresh handles (fewer when the heap is
/// nearly full), as a Roc `List(Box(U64))` whose single reference passes to
/// Roc, each element the address of a handle's payload with refcount 1.
fn hostedMintFiles(n: u64) callconv(.c) RocList {
    const want: usize = @min(@as(usize, @intCast(n)), 64 - blobs.live_count);
    if (want == 0) return .{ .elements = null, .length = 0, .capacity_or_alloc_ptr = 0 };
    // A list of refcounted elements, laid out as Roc lays one out: its
    // original length, then its refcount (1), then the elements.
    const base: [*]u8 = @ptrCast(roc_alloc(@sizeOf(usize) * (want + 2), @alignOf(usize)));
    const words: [*]usize = @ptrCast(@alignCast(base));
    words[0] = want;
    words[1] = 1;
    const elems: [*]usize = words + 2;
    for (0..want) |i| elems[i] = @intFromPtr(blobs.mint(.{}) orelse unreachable);
    return .{ .elements = @ptrCast(elems), .length = want, .capacity_or_alloc_ptr = want << 1 };
}

/// `Cli.live_files!`: free the slots of the handles Roc released, as the
/// page's runtime does after each call, and count those still live.
fn hostedLiveFiles() callconv(.c) u64 {
    var token: u64 = 0;
    while (blobs.releaseOne(&token, nothing)) {}
    return blobs.live_count;
}

/// `Cli.sha256!`: the SHA-256 digest of `bytes`, computed with Zig's
/// standard library, as the browser runtime computes a file's digest with
/// WebCrypto: the native runner answers a spec's digest request with the
/// same 32 bytes Chrome would. The argument is released here (a hosted
/// function owns it) and the digest is a fresh list whose single reference
/// passes to Roc.
fn hostedSha256(bytes: RocList) callconv(.c) RocList {
    defer releaseBytes(bytes);
    const data: []const u8 = if (bytes.elements) |e| @as([*]const u8, @ptrCast(e))[0..bytes.length] else &.{};
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return bytesList(&digest);
}

/// `Cli.live_allocations!`: how many allocations Roc has made and not yet
/// released in this process. The soak compares it before and after each
/// replayed round trip; it is a leak check, never a baseline.
fn hostedLiveAllocations() callconv(.c) u64 {
    return live_allocations;
}

/// `Cli.live_bytes!`: the bytes Roc asked for in the allocations still
/// live, as `roc_alloc` recorded them (alignment padding not counted).
fn hostedLiveBytes() callconv(.c) u64 {
    return live_bytes;
}

fn hostedNowNs() callconv(.c) u64 {
    return os.nowNs();
}

// ---------------------------------------------------------------------------
// Worker jobs in child processes.

/// How long a job may run before the runner gives up on it. A spec's time is
/// manual, so a job's own deadline never ends it; this bound only turns a
/// job that never finishes into a failed step instead of a hung runner.
/// The browser runner applies the same bound.
const job_bound_ms: u32 = 30_000;

/// The one argument that starts the runner's executable as a job's child
/// (see `runMain`). No spec runner command line takes this form.
const job_flag = "--roc-signals-worker-job";

/// Set in a job's child process: a crash there ends the child with its
/// fault class instead of ending the runner.
var in_job: bool = false;

/// The task a job's child runs, for its fault report (at most 256 bytes
/// of the name).
var job_name_buf: [256]u8 = undefined;
var job_name: []const u8 = "";

/// The exit status a child uses for fault class `class` (1 contract,
/// 2 resource_limit, 3 out_of_memory, 4 app_crash, 5 expect_failed, and
/// 7 executor when the child's own process failed the job).
const job_fault_base: u8 = 80;

const fault_names = [_][]const u8{ "", "contract", "resource_limit", "out_of_memory", "app_crash", "expect_failed" };

/// The class of a Roc crash message, as the Wasm host classifies it
/// (`host.zig`, `roc_crashed`): the engine's `contract:` and
/// `resource_limit:` messages, and anything else is an app crash.
fn crashClass(msg: []const u8) u8 {
    if (std.mem.startsWith(u8, msg, "contract:")) return 1;
    if (std.mem.startsWith(u8, msg, "resource_limit:")) return 2;
    return 4;
}

/// In a job's child: report the fault as the browser runtime reports a lost
/// job (`roc worker fault [class] ...` on stderr) and end the child with
/// the class in its exit status.
fn jobFault(class: u8, msg: []const u8) noreturn {
    writeErr("roc worker fault [");
    writeErr(fault_names[class]);
    writeErr("] in task \"");
    writeErr(job_name);
    writeErr("\": ");
    writeErr(msg);
    writeErr("\n");
    os.exitProcess(job_fault_base + class);
}

/// In a job's child: end as an executor fault, the child's own process
/// having failed the job (its input unreadable, or its runner gone).
fn jobLost(msg: []const u8) noreturn {
    _ = os.writeAll(.err, "roc worker fault [executor]: ");
    _ = os.writeAll(.err, msg);
    _ = os.writeAll(.err, "\n");
    os.exitProcess(job_fault_base + 7);
}

/// Release one reference to a `List(U8)` (a hosted function owns its
/// argument). A seamless slice keeps its allocation's address, tagged in the
/// low bit, in place of the capacity.
fn releaseBytes(list: RocList) void {
    const alloc_addr: usize = if ((list.capacity_or_alloc_ptr & 1) != 0)
        list.capacity_or_alloc_ptr & ~@as(usize, 1)
    else
        @intFromPtr(list.elements orelse return);
    const rc: *isize = @ptrFromInt(alloc_addr - @sizeOf(isize));
    if (rc.* == 0) return; // static data
    rc.* -= 1;
    if (rc.* == 0) roc_dealloc(@ptrFromInt(alloc_addr - @sizeOf(usize)), @alignOf(usize));
}

/// Release a hosted `List(List(U8))` argument: the outer list's reference,
/// and each inner list's when the outer one goes.
fn releaseFiles(list: RocList) void {
    const elems = list.elements orelse return;
    const alloc_addr: usize = if ((list.capacity_or_alloc_ptr & 1) != 0) list.capacity_or_alloc_ptr & ~@as(usize, 1) else @intFromPtr(elems);
    const rc: *isize = @ptrFromInt(alloc_addr - @sizeOf(isize));
    if (rc.* == 0) return;
    rc.* -= 1;
    if (rc.* != 0) return;
    const inner: [*]const RocList = @ptrCast(@alignCast(elems));
    for (inner[0..list.length]) |l| releaseBytes(l);
    // A list of refcounted elements keeps its length before its refcount.
    roc_dealloc(@ptrFromInt(alloc_addr - 2 * @sizeOf(usize)), @alignOf(usize));
}

/// The items of a `List(List(U8))`, read in place.
fn listItems(list: RocList) []const RocList {
    return if (list.elements) |e| @as([*]const RocList, @ptrCast(@alignCast(e)))[0..list.length] else &.{};
}

/// In a job's child: keep the task's name, from its payload (`name:str
/// input:rest`), for its fault report.
fn nameJob(payload: []const u8) void {
    if (payload.len < 4) return;
    const n = @min(std.mem.readInt(u32, payload[0..4], .little), payload.len - 4, job_name_buf.len);
    @memcpy(job_name_buf[0..n], payload[4..][0..n]);
    job_name = job_name_buf[0..n];
}

/// In a job's child: write `bytes` of the answer to the runner, or end as
/// an executor fault when the runner is gone.
fn childWrite(bytes: []const u8) void {
    if (!os.writeAll(.out, bytes)) jobLost("the runner stopped reading the job's answer");
}

/// A buffer in the system's memory that doubles as it fills: a file being
/// read, a job being written for its child or read by it, a job's answer.
/// The system services fill it through `room` and `len`.
const Growing = struct {
    buf: ?[*]u8 = null,
    cap: usize = 0,
    len: usize = 0,

    /// The free space at the end, after growing when there is none; null
    /// when the system has no memory for it. Filling it is adding to `len`.
    pub fn room(g: *Growing) ?[]u8 {
        if (g.len == g.cap) {
            const cap = @max(g.cap * 2, 1 << 12);
            const next = os.alloc(16, cap) orelse return null;
            if (g.buf) |old| {
                @memcpy(next[0..g.len], old[0..g.len]);
                os.release(old);
            }
            g.buf = next;
            g.cap = cap;
        }
        return g.buf.?[g.len..g.cap];
    }

    /// Append `data`; a runner with no memory for a job fails.
    fn append(g: *Growing, data: []const u8) void {
        var rest = data;
        while (rest.len > 0) {
            const space = g.room() orelse fail("out of memory writing a worker job", "");
            const n = @min(space.len, rest.len);
            @memcpy(space[0..n], rest[0..n]);
            g.len += n;
            rest = rest[n..];
        }
    }

    fn appendInt(g: *Growing, comptime T: type, value: T) void {
        var raw: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &raw, value, .little);
        g.append(&raw);
    }

    fn bytes(g: *const Growing) []u8 {
        return if (g.buf) |b| b[0..g.len] else &.{};
    }

    fn deinit(g: *Growing) void {
        if (g.buf) |b| os.release(b);
        g.* = .{};
    }
};

/// The job as the runner writes it to its child's standard input:
/// `max_output:u64 payload:bytes prepare:bytes n:u32 (file:bytes)* m:u32
/// (file:bytes)*`, the preparation's files and then the job's, where each
/// `bytes` is a `u64` length and the bytes.
fn encodeJob(in: *Growing, payload: RocList, files: RocList, prepare: RocList, prepare_files: RocList, max_output: u64) void {
    in.appendInt(u64, max_output);
    for ([_]RocList{ payload, prepare }) |list| {
        in.appendInt(u64, list.length);
        in.append(listBytes(list));
    }
    for ([_]RocList{ prepare_files, files }) |list| {
        const items = listItems(list);
        in.appendInt(u32, @intCast(items.len));
        for (items) |item| {
            in.appendInt(u64, item.length);
            in.append(listBytes(item));
        }
    }
}

/// In a job's child: the job its runner wrote (`encodeJob`), read in place.
/// A job that ends early is the runner's failure, never the task's.
const JobInput = struct {
    rest: []u8,

    fn take(j: *JobInput, n: u64) []u8 {
        if (n > j.rest.len) jobLost("the runner sent a truncated job");
        const out = j.rest[0..@intCast(n)];
        j.rest = j.rest[@intCast(n)..];
        return out;
    }

    fn int(j: *JobInput, comptime T: type) T {
        return std.mem.readInt(T, j.take(@sizeOf(T))[0..@sizeOf(T)], .little);
    }

    fn bytes(j: *JobInput) []u8 {
        return j.take(j.int(u64));
    }
};

// ---------------------------------------------------------------------------
// Hosted effects (design.md, "Workers"). A job runs in a child process,
// through the platform's `roc_engine_work` (or `roc_engine_prepare` and
// `roc_engine_ask` for a preparation's task), the entries a worker
// instance calls, and its hosted effects (`roc_task_*`) are served here
// from the heap's slots: each file the job was sent holds its bytes, a
// builder collects copies of what is appended, and finishing one moves its
// bytes behind a fresh handle. This is what the worker script does with
// `Blob`s, so a spec's job answers the same natively and in Chrome.
// Everything lives in the child and goes with it; the runner's own process
// never runs a job.

// A worker instance's entries (`work_for_host!`, `prepare_for_host!` and
// `ask_for_host!` in `platform/main.roc`).
extern fn roc_engine_work(payload: RocList, handles: RocList) callconv(.c) RocList;
extern fn roc_engine_prepare(payload: RocList, handles: RocList) callconv(.c) *anyopaque;
extern fn roc_engine_ask(held: *anyopaque, payload: RocList, handles: RocList) callconv(.c) AskStep;

/// Roc lays out `{ held : Box(Kept), out : List(U8) }` by alignment and
/// then field name.
const AskStep = extern struct { held: *anyopaque, out: RocList };

/// Set in a job's child while its job or preparation runs: the hosted
/// effects refuse to act otherwise, as the Wasm host's do.
var in_task: bool = false;

/// The bytes a job may still append to its builders (`maxOutputBytes`, as
/// the spec gives it).
var output_left: u64 = 0;

/// The most files a job's answer may hold (design.md, "Boundedness"). The
/// engine refuses a larger answer itself; this only bounds the copy below.
const max_answer_files: usize = 16;

/// The builders the running call opened, so they can be closed when it
/// returns (at most the heap's slots).
var opened: [64]u64 = @splat(0);
var opened_count: usize = 0;

fn outsideTask(comptime effect: []const u8) noreturn {
    const msg = "contract: " ++ effect ++ " is a worker effect and ran outside a job; only a worker task's job (Worker.task) may call it";
    roc_crashed(msg.ptr, msg.len);
    unreachable;
}

/// A copy of `bytes` in memory of its own (the child's; never freed).
fn copyOf(bytes: []const u8) []u8 {
    if (bytes.len == 0) return &.{};
    const p = os.alloc(16, bytes.len) orelse fail("out of memory in a worker job", "");
    @memcpy(p[0..bytes.len], bytes);
    return p[0..bytes.len];
}

/// Append `bytes` to builder `b`, growing its buffer by doubling.
fn grow(b: *Held, bytes: []const u8) void {
    if (bytes.len == 0) return;
    const need = b.bytes.len + bytes.len;
    if (need > b.cap) {
        const cap = @max(need, b.cap * 2, 4096);
        const p = os.alloc(16, cap) orelse fail("out of memory in a worker job", "");
        @memcpy(p[0..b.bytes.len], b.bytes);
        b.bytes = p[0..b.bytes.len];
        b.cap = cap;
    }
    const p = b.bytes.ptr;
    @memcpy(p[b.bytes.len..need], bytes);
    b.bytes = p[0..need];
}

/// The bytes of the file behind `token`'s range, or null when there is no
/// such file or the range does not lie within it.
fn heldRange(token: u64, start: u64, len: u64) ?[]const u8 {
    const h = blobs.get(token) orelse return null;
    if (h.kind != .file) return null;
    if (start > h.bytes.len or len > h.bytes.len - start) return null;
    return h.bytes[@intCast(start)..][0..@intCast(len)];
}

/// The bytes of a `List(U8)` argument, read in place.
fn listBytes(list: RocList) []const u8 {
    return if (list.elements) |e| @as([*]const u8, @ptrCast(e))[0..list.length] else &.{};
}

/// The status a builder effect answers for `token`: null when it is an
/// open builder, else 2 (not an open builder: finished, or not one) or 3
/// (a builder the call that opened it has left behind).
fn builderRefusal(token: u64) ?u8 {
    const b = blobs.get(token) orelse return 2;
    return switch (b.kind) {
        .builder => null,
        .expired => 3,
        else => 2,
    };
}

fn hostedTaskRead(token: u64, start: u64, len: u64) callconv(.c) RocList {
    if (!in_task) outsideTask("File.read!");
    const range = heldRange(token, start, len) orelse return .{ .elements = null, .length = 0, .capacity_or_alloc_ptr = 0 };
    return bytesList(range);
}

fn hostedTaskSize(token: u64) callconv(.c) u64 {
    if (!in_task) outsideTask("Builder.finish!");
    const h = blobs.get(token) orelse return 0;
    return h.bytes.len;
}

fn hostedTaskMint() callconv(.c) *u64 {
    if (!in_task) outsideTask("Files.build!");
    return blobs.mint(.{}) orelse jobFault(2, "resource_limit: a worker job holds more than 64 files and builders at once");
}

fn hostedTaskOpen(token: u64, name: RocList, mime: RocList, from: u64, start: u64, len: u64) callconv(.c) u8 {
    if (!in_task) outsideTask("Files.build!");
    defer releaseBytes(name);
    defer releaseBytes(mime);
    const b = blobs.get(token) orelse return 2;
    b.* = .{ .kind = .builder, .name = copyOf(listBytes(name)), .mime = copyOf(listBytes(mime)) };
    if (opened_count < opened.len) {
        opened[opened_count] = token;
        opened_count += 1;
    }
    if (from != 0) grow(b, heldRange(from, start, len) orelse return 2);
    return 0;
}

fn hostedTaskAppend(token: u64, bytes: RocList) callconv(.c) u8 {
    if (!in_task) outsideTask("Builder.append!");
    defer releaseBytes(bytes);
    if (builderRefusal(token)) |status| return status;
    const b = blobs.get(token).?;
    if (bytes.length > output_left) return 1;
    output_left -= bytes.length;
    grow(b, listBytes(bytes));
    return 0;
}

fn hostedTaskAppendFile(token: u64, file: u64, start: u64, len: u64) callconv(.c) u8 {
    if (!in_task) outsideTask("Builder.append_file!");
    if (builderRefusal(token)) |status| return status;
    const b = blobs.get(token).?;
    grow(b, heldRange(file, start, len) orelse return 2);
    return 0;
}

fn hostedTaskFinish(token: u64, file: u64) callconv(.c) u8 {
    if (!in_task) outsideTask("Builder.finish!");
    if (builderRefusal(token)) |status| return status;
    const b = blobs.get(token).?;
    const f = blobs.get(file) orelse return 2;
    f.* = .{ .kind = .file, .bytes = b.bytes, .cap = b.cap, .name = b.name, .mime = b.mime };
    b.kind = .finished;
    return 0;
}

/// In a job's child: close every builder the call that just returned
/// opened, as the worker script does, so a builder a prepared state kept
/// is refused (status 3) to the job that uses it.
fn closeOpened() void {
    for (opened[0..opened_count]) |token| {
        if (blobs.get(token)) |b| {
            if (b.kind == .builder) b.kind = .expired;
        }
    }
    opened_count = 0;
}

/// In a job's child: a Roc `List(Box(U64))` of fresh handles for the job's
/// next `n:u32 (file:bytes)*` files, each holding its file's bytes where
/// they lie in the job's input (which the child never frees). Its single
/// reference, and each handle's, pass to Roc.
fn handlesFor(job: *JobInput) RocList {
    const count: usize = job.int(u32);
    if (count == 0) return .{ .elements = null, .length = 0, .capacity_or_alloc_ptr = 0 };
    // A list of refcounted elements, laid out as Roc lays one out: its
    // original length, then its refcount (1), then the elements.
    const base: [*]u8 = @ptrCast(roc_alloc(@sizeOf(usize) * (count + 2), @alignOf(usize)));
    const words: [*]usize = @ptrCast(@alignCast(base));
    words[0] = count;
    words[1] = 1;
    const elems: [*]usize = words + 2;
    for (0..count) |i| {
        const p = blobs.mint(.{ .kind = .file, .bytes = job.bytes() }) orelse jobFault(2, "resource_limit: a worker job was sent more files than its instance holds");
        elems[i] = @intFromPtr(p);
    }
    return .{ .elements = @ptrCast(elems), .length = count, .capacity_or_alloc_ptr = count << 1 };
}

/// `Cli.work!`: run one worker job in a child process and return the
/// runner's record of its answer (see `Cli.work!`). The runner writes the
/// job to the child (`encodeJob`) and reads back what `jobMain` writes:
/// tag 10, the answer's files' sizes, names and types, the output, and
/// each file's bytes, so the runner can mint the page's handles and serve
/// the files' bytes afterwards. A fault in the child is answered tag 11
/// with its class (7, executor, when the child ended without one), and a
/// child that does not finish within `job_bound_ms` is ended and answered
/// with an empty list.
///
/// Ownership: the runner copies every argument into the job's input and
/// releases its references before the child starts; the child owns its
/// copy and everything it makes, all of which goes with its process. A
/// runner that cannot start a child, or has no memory for the job, fails
/// with exit status 2: it has nothing correct left to report.
fn hostedWork(payload: RocList, files: RocList, prepare: RocList, prepare_files: RocList, max_output: u64) callconv(.c) RocList {
    var in: Growing = .{};
    defer in.deinit();
    encodeJob(&in, payload, files, prepare, prepare_files, max_output);
    releaseBytes(payload);
    releaseFiles(files);
    releaseBytes(prepare);
    releaseFiles(prepare_files);
    var out: Growing = .{};
    defer out.deinit();
    const ended = os.runJob(job_flag, in.bytes(), job_bound_ms, &out) orelse fail("cannot run a worker job in a child process", "");
    const class: u8 = switch (ended) {
        .timed_out => return .{ .elements = null, .length = 0, .capacity_or_alloc_ptr = 0 },
        .exited => |code| if (code == 0)
            return bytesList(out.bytes())
        else if (code > job_fault_base and code <= job_fault_base + 5)
            @intCast(code - job_fault_base)
        else
            7,
        .died => 7,
    };
    // A child that reported its own executor fault has said why already.
    const reported = switch (ended) {
        .exited => |code| code == job_fault_base + 7,
        else => false,
    };
    if (class == 7 and !reported) writeErr("roc worker fault [executor]: the job's process died without a fault class\n");
    return bytesList(&[_]u8{ 11, class });
}

/// A job's child, started by `hostedWork` through `os.runJob`: read the
/// job, run it as a worker instance would, write the answer and exit. When
/// the job names a preparation the child first mints handles for the
/// preparation's files and runs it, as a worker instance that holds no
/// state does, closes the builders it opened, and runs the job on the
/// state; otherwise it runs the job as a task of its own. Either way it
/// mints a handle for each of the job's files first. A fault ends the child
/// with its class (`jobFault`).
fn jobMain() noreturn {
    in_job = true;
    var input: Growing = .{};
    if (!os.readJobInput(&input)) jobLost("cannot read the job from the runner");
    var job: JobInput = .{ .rest = input.bytes() };
    output_left = job.int(u64);
    const payload = job.bytes();
    const prepare = job.bytes();
    nameJob(payload);
    var out: RocList = undefined;
    if (prepare.len > 0) {
        const prep_handles = handlesFor(&job);
        in_task = true;
        const held = roc_engine_prepare(bytesList(prepare), prep_handles);
        in_task = false;
        closeOpened();
        const handles = handlesFor(&job);
        in_task = true;
        const step = roc_engine_ask(held, bytesList(payload), handles);
        in_task = false;
        out = step.out;
    } else {
        // Files sent for no preparation are not the job's.
        for (0..job.int(u32)) |_| _ = job.bytes();
        const handles = handlesFor(&job);
        in_task = true;
        out = roc_engine_work(bytesList(payload), handles);
        in_task = false;
    }
    closeOpened();
    const answer = listBytes(out);
    if (answer.len < 4) jobFault(1, "contract: a job's entry returned an answer without its file count");
    const n = std.mem.readInt(u32, answer[0..4], .little);
    if (n > max_answer_files) jobFault(1, "contract: a job's entry returned more files than an answer holds");
    if (answer.len < 4 + 8 * @as(usize, n)) jobFault(1, "contract: a job's entry returned a truncated answer");
    var head: [5]u8 = undefined;
    head[0] = 10;
    std.mem.writeInt(u32, head[1..5], n, .little);
    childWrite(&head);
    var held_files: [max_answer_files]*Held = undefined;
    for (0..n) |i| {
        const token = std.mem.readInt(u64, answer[4 + 8 * i ..][0..8], .little);
        const h = blobs.get(token) orelse jobFault(1, "contract: a job's answer names a handle its instance does not hold");
        if (h.kind != .file) jobFault(1, "contract: a job's answer names a builder; only a finished file can be in an answer");
        held_files[i] = h;
        var size: [8]u8 = undefined;
        std.mem.writeInt(u64, &size, h.bytes.len, .little);
        childWrite(&size);
        childStr(h.name);
        childStr(h.mime);
    }
    const output = answer[4 + 8 * @as(usize, n) ..];
    var size: [8]u8 = undefined;
    std.mem.writeInt(u64, &size, output.len, .little);
    childWrite(&size);
    childWrite(output);
    for (held_files[0..n]) |h| childWrite(h.bytes);
    os.exitProcess(0);
}

/// In a job's child: a string as the wire writes one, `len:u32 bytes`.
fn childStr(bytes: []const u8) void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(bytes.len), .little);
    childWrite(&len);
    childWrite(bytes);
}

comptime {
    @export(&hostedTaskRead, .{ .name = "roc_task_read" });
    @export(&hostedTaskSize, .{ .name = "roc_task_size" });
    @export(&hostedTaskMint, .{ .name = "roc_task_mint" });
    @export(&hostedTaskOpen, .{ .name = "roc_task_open" });
    @export(&hostedTaskAppend, .{ .name = "roc_task_append" });
    @export(&hostedTaskAppendFile, .{ .name = "roc_task_append_file" });
    @export(&hostedTaskFinish, .{ .name = "roc_task_finish" });
}

comptime {
    @export(&hostedWork, .{ .name = "roc_test_work" });
    @export(&hostedMintFiles, .{ .name = "roc_test_mint_files" });
    @export(&hostedLiveFiles, .{ .name = "roc_test_live_files" });
    @export(&hostedReadFile, .{ .name = "roc_test_read_file" });
    @export(&hostedSha256, .{ .name = "roc_test_sha256" });
    @export(&hostedFileExists, .{ .name = "roc_test_file_exists" });
    @export(&hostedStdout, .{ .name = "roc_test_stdout" });
    @export(&hostedStderr, .{ .name = "roc_test_stderr" });
    @export(&hostedNowNs, .{ .name = "roc_test_now_ns" });
    @export(&hostedLiveAllocations, .{ .name = "roc_test_live_allocations" });
    @export(&hostedLiveBytes, .{ .name = "roc_test_live_bytes" });
    // The process entry, exported by name rather than declared `pub fn
    // main`, which Zig would treat as its own program entry: `main` for
    // the C runtime (musl's `crt1.o`) or libSystem to call, and on Windows,
    // where the runner links no C runtime, the entry the linker looks for.
    if (builtin.os.tag == .windows)
        @export(&windowsMain, .{ .name = "mainCRTStartup" })
    else
        @export(&cMain, .{ .name = "main" });
}

/// Run the spec runner over `args` (the arguments after the program's
/// name), or run a job when the runner started this process for one.
fn runMain(args: []const [*:0]const u8) i32 {
    if (args.len == 1 and std.mem.eql(u8, std.mem.span(args[0]), job_flag)) jobMain();
    return roc_spec_main(argsList(args));
}

fn cMain(argc: c_int, argv: [*]const [*:0]const u8) callconv(.c) c_int {
    os.init();
    return runMain(os.argsOf(argc, argv));
}

fn windowsMain() callconv(.c) noreturn {
    os.init();
    os.exitProcess(@truncate(@as(u32, @bitCast(runMain(os.args())))));
}
