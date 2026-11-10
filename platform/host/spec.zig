//! The native host of the roc-signals platform: `roc build --target=x64musl`
//! of an app gives its `.scm` spec runner.
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
//! in a child process, as the browser runs it in a Web Worker: the child
//! calls the platform's `roc_engine_work`, the same entry a worker instance
//! calls, so a program that crashes poisons only the child, and the runner
//! receives the lost job's fault class as the page would.

const std = @import("std");
const resources = @import("resources.zig");

// The command-line entry the platform provides (`SpecRunner.main!`).
extern fn roc_spec_main(args: RocList) callconv(.c) i32;

// A worker instance's entry (`work_for_host` in `platform/main.roc`):
// `name:str input:rest` to the program's output bytes. Only a job's child
// process calls it.
extern fn roc_engine_work(payload: RocList, files: RocList) callconv(.c) RocList;

// musl libc.
extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern fn close(fd: c_int) c_int;
extern fn read(fd: c_int, buf: [*]u8, len: usize) isize;
extern fn write(fd: c_int, buf: [*]const u8, len: usize) isize;
extern fn malloc(len: usize) ?*anyopaque;
extern fn free(ptr: ?*anyopaque) void;
extern fn aligned_alloc(alignment: usize, len: usize) ?*anyopaque;
extern fn clock_gettime(clock: c_int, ts: *Timespec) c_int;
extern fn exit(code: c_int) noreturn;
extern fn _exit(code: c_int) noreturn;
extern fn fork() c_int;
extern fn pipe(fds: *[2]c_int) c_int;
extern fn poll(fds: [*]PollFd, n: c_ulong, timeout_ms: c_int) c_int;
extern fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
extern fn kill(pid: c_int, sig: c_int) c_int;

const Timespec = extern struct { sec: i64, nsec: i64 };
const PollFd = extern struct { fd: c_int, events: c_short, revents: c_short };
const pollin: c_short = 1;
const sigkill: c_int = 9;
const clock_monotonic: c_int = 1;
const o_rdonly: c_int = 0;
const o_directory: c_int = 0o200000;

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

fn writeAll(fd: c_int, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = write(fd, rest.ptr, rest.len);
        if (n <= 0) exit(3);
        rest = rest[@intCast(n)..];
    }
}

// ---------------------------------------------------------------------------
// The allocator and crash reporting Roc calls. Each allocation carries a
// header before the pointer Roc sees, holding the requested size, so
// `roc_realloc` knows how much to copy.

const header_size: usize = 16;

fn alignment(align_arg: usize) usize {
    return @max(align_arg, header_size);
}

export fn roc_alloc(size: usize, align_arg: usize) callconv(.c) *anyopaque {
    const a = alignment(align_arg);
    const total = std.mem.alignForward(usize, a + size, a);
    const base: [*]u8 = @ptrCast(aligned_alloc(a, total) orelse fail("out of memory", ""));
    const user = base + a;
    @as(*usize, @ptrCast(@alignCast(user - header_size))).* = size;
    return user;
}

export fn roc_dealloc(ptr: *anyopaque, align_arg: usize) callconv(.c) void {
    switch (blobs.route(ptr)) {
        .not_owned => {},
        .retired => return,
        .corrupt => fail("internal: a file handle was released twice", ""),
    }
    const user: [*]u8 = @ptrCast(ptr);
    free(user - alignment(align_arg));
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
    writeAll(2, "[dbg] ");
    writeAll(2, bytes[0..len]);
    writeAll(2, "\n");
}

export fn roc_expect_failed(bytes: [*]const u8, len: usize) callconv(.c) void {
    if (in_job) jobFault(5, bytes[0..len]);
    writeAll(2, "expect failed: ");
    writeAll(2, bytes[0..len]);
    writeAll(2, "\n");
    exit(71);
}

export fn roc_crashed(bytes: [*]const u8, len: usize) callconv(.c) void {
    if (in_job) jobFault(crashClass(bytes[0..len]), bytes[0..len]);
    writeAll(2, "crashed: ");
    writeAll(2, bytes[0..len]);
    writeAll(2, "\n");
    exit(70);
}

fn fail(comptime prefix: []const u8, detail: []const u8) noreturn {
    if (in_job and std.mem.eql(u8, prefix, "out of memory")) jobFault(3, prefix);
    writeAll(2, prefix);
    writeAll(2, detail);
    writeAll(2, "\n");
    exit(2);
}

/// A NUL-terminated copy of `path`, or null when it holds a NUL byte.
fn cPath(path: []const u8) ?[*:0]u8 {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return null;
    const buf: [*]u8 = @ptrCast(malloc(path.len + 1) orelse fail("out of memory copying a path: ", path));
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return @ptrCast(buf);
}

fn hostedReadFile(path: RocStr) callconv(.c) RocList {
    defer path.decref();
    const name = path.slice();
    const c_name = cPath(name) orelse fail("cannot read a path containing NUL: ", name);
    defer free(c_name);
    const fd = open(c_name, o_rdonly);
    if (fd < 0) fail("cannot open ", name);
    defer _ = close(fd);
    var cap: usize = 1 << 16;
    var len: usize = 0;
    var buf: [*]u8 = @ptrCast(malloc(cap) orelse fail("out of memory reading ", name));
    defer free(buf);
    while (true) {
        if (len == cap) {
            const bigger: [*]u8 = @ptrCast(malloc(cap * 2) orelse fail("out of memory reading ", name));
            @memcpy(bigger[0..len], buf[0..len]);
            free(buf);
            buf = bigger;
            cap *= 2;
        }
        const n = read(fd, buf + len, cap - len);
        if (n < 0) fail("cannot read ", name);
        if (n == 0) break;
        len += @intCast(n);
    }
    return bytesList(buf[0..len]);
}

fn hostedFileExists(path: RocStr) callconv(.c) bool {
    defer path.decref();
    const c_name = cPath(path.slice()) orelse return false;
    defer free(c_name);
    // A directory opens read-only too; refuse it so only files count.
    const dir = open(c_name, o_rdonly | o_directory);
    if (dir >= 0) {
        _ = close(dir);
        return false;
    }
    const fd = open(c_name, o_rdonly);
    if (fd < 0) return false;
    _ = close(fd);
    return true;
}

fn hostedStdout(text: RocStr) callconv(.c) void {
    defer text.decref();
    writeAll(1, text.slice());
}

fn hostedStderr(text: RocStr) callconv(.c) void {
    defer text.decref();
    writeAll(2, text.slice());
}

/// The native spec host's copy of the page's file handles (design.md,
/// "Files"): the same heap the Wasm host mints them in, so a spec observes
/// their release as the page's runtime does. Its bound is the page's. In a
/// task job's child process the same heap is the worker instance's, and
/// each slot carries what the worker script would hold for its token: a
/// file's bytes, or a builder's (see "Tasks" below). The runner's own
/// process never fills one in.
var blobs: resources.Heap(.blob, 64, Held) = .{};

/// What a task job's child holds behind a token, as the worker script
/// holds a `Blob` or a builder's parts: nothing (a page handle), a file's
/// bytes, an open builder, or a builder that was finished.
const Held = struct {
    kind: enum { none, file, builder, finished } = .none,
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

fn hostedNowNs() callconv(.c) u64 {
    var ts: Timespec = undefined;
    if (clock_gettime(clock_monotonic, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

// ---------------------------------------------------------------------------
// Worker jobs in child processes.

/// How long a job may run before the runner gives up on it. A spec's time is
/// manual, so a job's own deadline never ends it; this bound only turns a
/// program that never finishes into a failed step instead of a hung runner.
/// The browser runner applies the same bound.
const job_bound_ms: i64 = 30_000;

/// Set in a job's child process: a crash there ends the child with its
/// fault class instead of ending the runner.
var in_job: bool = false;

/// The program a job's child runs, for its fault report (at most 256 bytes
/// of the name, copied before the payload moves into Roc).
var job_name_buf: [256]u8 = undefined;
var job_name: []const u8 = "";

/// The exit status a child uses for fault class `class` (1 contract,
/// 2 resource_limit, 3 out_of_memory, 4 app_crash, 5 expect_failed).
const job_fault_base: c_int = 80;

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
    writeAll(2, "roc worker fault [");
    writeAll(2, fault_names[class]);
    writeAll(2, "] in program \"");
    writeAll(2, job_name);
    writeAll(2, "\": ");
    writeAll(2, msg);
    writeAll(2, "\n");
    _exit(job_fault_base + class);
}

fn nowMs() i64 {
    var ts: Timespec = undefined;
    if (clock_gettime(clock_monotonic, &ts) != 0) return 0;
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
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

/// `Cli.work!`: run one worker job, `payload` being `name:str input:rest`,
/// in a child process, and return the result payload the browser runtime
/// would deliver for it (design.md, Appendix B): tag 10 and the output, or
/// tag 11 and the fault class when the program's instance faulted (7,
/// executor, when the child died without a class, as a worker that traps
/// with none). An empty list means the job did not finish within
/// `job_bound_ms`; its child is killed.
///
/// The parent releases its reference to `payload` after the fork; the child
/// moves its copy into `roc_engine_work`, writes the output to a pipe and
/// exits without running any exit handlers. The parent reads the pipe to its
/// end before waiting, so a large output cannot block the child.
fn hostedWork(payload: RocList, files: RocList) callconv(.c) RocList {
    var fds: [2]c_int = undefined;
    if (pipe(&fds) != 0) fail("cannot create a pipe for a worker job", "");
    const pid = fork();
    if (pid < 0) fail("cannot fork a worker job", "");
    if (pid == 0) {
        in_job = true;
        _ = close(fds[0]);
        nameJob(payload);
        const out = roc_engine_work(payload, files);
        childWrite(fds[1], if (out.elements) |e| @as([*]const u8, @ptrCast(e))[0..out.length] else &.{});
        _exit(0);
    }
    releaseBytes(payload);
    releaseFiles(files);
    _ = close(fds[1]);
    return awaitJob(pid, fds[0], 10);
}

/// In a job's child: keep the program's name for its fault report (at most
/// 256 bytes, copied before the payload moves into Roc).
fn nameJob(payload: RocList) void {
    const e = payload.elements orelse return;
    const bytes = @as([*]const u8, @ptrCast(e))[0..payload.length];
    if (bytes.len < 4) return;
    const n = @min(std.mem.readInt(u32, bytes[0..4], .little), bytes.len - 4, job_name_buf.len);
    @memcpy(job_name_buf[0..n], bytes[4..][0..n]);
    job_name = job_name_buf[0..n];
}

/// In a job's child: write `bytes` to the parent's pipe, or end as an
/// executor fault when the pipe is gone.
fn childWrite(fd: c_int, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = write(fd, rest.ptr, rest.len);
        if (n <= 0) _exit(job_fault_base + 7);
        rest = rest[@intCast(n)..];
    }
}

/// In the runner: read job `pid`'s pipe `fd` to its end and wait for the
/// child, returning what it wrote after the byte `tag` (none when `tag` is
/// 0), or tag 11 and the fault class when the child faulted, or an empty
/// list when it did not finish within `job_bound_ms` (it is killed). The
/// pipe is read before waiting, so a large output cannot block the child,
/// and closed here.
fn awaitJob(pid: c_int, fd: c_int, tag: u8) RocList {
    defer _ = close(fd);
    var cap: usize = 1 << 12;
    var len: usize = if (tag == 0) 0 else 1;
    var buf: [*]u8 = @ptrCast(malloc(cap) orelse fail("out of memory reading a worker job", ""));
    defer free(buf);
    buf[0] = tag;
    const fds = [2]c_int{ fd, -1 };
    const start = nowMs();
    while (true) {
        const left = job_bound_ms - (nowMs() - start);
        var pfd = [_]PollFd{.{ .fd = fds[0], .events = pollin, .revents = 0 }};
        const ready = if (left > 0) poll(&pfd, 1, @intCast(left)) else 0;
        if (ready == 0) {
            _ = kill(pid, sigkill);
            var ignored: c_int = 0;
            _ = waitpid(pid, &ignored, 0);
            return .{ .elements = null, .length = 0, .capacity_or_alloc_ptr = 0 };
        }
        if (ready < 0) continue;
        if (len == cap) {
            const bigger: [*]u8 = @ptrCast(malloc(cap * 2) orelse fail("out of memory reading a worker job", ""));
            @memcpy(bigger[0..len], buf[0..len]);
            free(buf);
            buf = bigger;
            cap *= 2;
        }
        const n = read(fds[0], buf + len, cap - len);
        if (n < 0) continue;
        if (n == 0) break;
        len += @intCast(n);
    }
    var status: c_int = 0;
    while (waitpid(pid, &status, 0) < 0) {}
    // A normal exit keeps its code in bits 8-15; a signal leaves bits 0-6 set.
    const signalled = (status & 0x7f) != 0;
    const code = (status >> 8) & 0xff;
    if (!signalled and code == 0) return bytesList(buf[0..len]);
    const class: u8 = if (!signalled and code > job_fault_base and code <= job_fault_base + 5) @intCast(code - job_fault_base) else 7;
    if (class == 7) writeAll(2, "roc worker fault [executor]: the job's process died without a fault class\n");
    return bytesList(&[_]u8{ 11, class });
}

// ---------------------------------------------------------------------------
// Tasks (design.md, "Tasks"). A task job runs in a child process like a
// program's, through the platform's `roc_engine_task`, and its hosted
// effects (`roc_task_*`) are served here from the heap's slots: each file
// the job was sent holds its bytes, a builder collects copies of what is
// appended, and finishing one moves its bytes behind a fresh handle. This
// is what the worker script does with `Blob`s, so a spec's task answers
// the same natively and in Chrome. Everything lives in the child and goes
// with it; the runner's own process never runs a task.

// A worker instance's task entry (`task_for_host!` in `platform/main.roc`).
extern fn roc_engine_task(payload: RocList, handles: RocList) callconv(.c) RocList;

/// Set in a task job's child while its task runs: the hosted effects refuse
/// to act otherwise, as the Wasm host's do.
var in_task: bool = false;

/// The bytes a task job may still append to its builders (`maxOutputBytes`,
/// as the spec gives it).
var output_left: u64 = 0;

/// The most files a task's answer may hold (design.md, "Boundedness").
const max_answer_files: usize = 16;

fn outsideTask(comptime effect: []const u8) noreturn {
    const msg = "contract: " ++ effect ++ " is a task effect and ran outside a task's job; only a worker task (Worker.task) may call it";
    roc_crashed(msg.ptr, msg.len);
    unreachable;
}

/// A copy of `bytes` in memory of its own (the child's; never freed).
fn copyOf(bytes: []const u8) []u8 {
    if (bytes.len == 0) return &.{};
    const p: [*]u8 = @ptrCast(malloc(bytes.len) orelse fail("out of memory in a task job", ""));
    @memcpy(p[0..bytes.len], bytes);
    return p[0..bytes.len];
}

/// Append `bytes` to builder `b`, growing its buffer by doubling.
fn grow(b: *Held, bytes: []const u8) void {
    if (bytes.len == 0) return;
    const need = b.bytes.len + bytes.len;
    if (need > b.cap) {
        const cap = @max(need, b.cap * 2, 4096);
        const p: [*]u8 = @ptrCast(malloc(cap) orelse fail("out of memory in a task job", ""));
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
    if (!in_task) outsideTask("File.build!");
    return blobs.mint(.{}) orelse jobFault(2, "resource_limit: a task's job holds more than 64 files and builders at once");
}

fn hostedTaskOpen(token: u64, name: RocList, mime: RocList, from: u64, start: u64, len: u64) callconv(.c) u8 {
    if (!in_task) outsideTask("File.build!");
    defer releaseBytes(name);
    defer releaseBytes(mime);
    const b = blobs.get(token) orelse return 2;
    b.* = .{ .kind = .builder, .name = copyOf(listBytes(name)), .mime = copyOf(listBytes(mime)) };
    if (from != 0) grow(b, heldRange(from, start, len) orelse return 2);
    return 0;
}

fn hostedTaskAppend(token: u64, bytes: RocList) callconv(.c) u8 {
    if (!in_task) outsideTask("Builder.append!");
    defer releaseBytes(bytes);
    const b = blobs.get(token) orelse return 2;
    if (b.kind != .builder) return 2;
    if (bytes.length > output_left) return 1;
    output_left -= bytes.length;
    grow(b, listBytes(bytes));
    return 0;
}

fn hostedTaskAppendFile(token: u64, file: u64, start: u64, len: u64) callconv(.c) u8 {
    if (!in_task) outsideTask("Builder.append_file!");
    const b = blobs.get(token) orelse return 2;
    if (b.kind != .builder) return 2;
    grow(b, heldRange(file, start, len) orelse return 2);
    return 0;
}

fn hostedTaskFinish(token: u64, file: u64) callconv(.c) u8 {
    if (!in_task) outsideTask("Builder.finish!");
    const b = blobs.get(token) orelse return 2;
    if (b.kind != .builder) return 2;
    const f = blobs.get(file) orelse return 2;
    f.* = .{ .kind = .file, .bytes = b.bytes, .cap = b.cap, .name = b.name, .mime = b.mime };
    b.kind = .finished;
    return 0;
}

/// `Cli.task!`: run one task job in a child process and return the
/// runner's record of its answer (see `Cli.task!`): the child mints a
/// handle for each of `files` (the whole file each request entry names),
/// runs the task, and writes tag 20, the answer's files' sizes, names and
/// types, the output, and each file's bytes, so the runner can mint the
/// page's handles and serve the files' bytes afterwards. Ownership is as
/// for `Cli.work!`: the parent releases its references after the fork, and
/// the child moves its copies into Roc.
fn hostedTask(payload: RocList, files: RocList, max_output: u64) callconv(.c) RocList {
    var fds: [2]c_int = undefined;
    if (pipe(&fds) != 0) fail("cannot create a pipe for a task job", "");
    const pid = fork();
    if (pid < 0) fail("cannot fork a task job", "");
    if (pid == 0) {
        in_job = true;
        _ = close(fds[0]);
        nameJob(payload);
        output_left = max_output;
        // The job's handles, as a Roc `List(Box(U64))`: its length, then its
        // refcount (1), then each handle's payload address. Its single
        // reference, and each handle's, pass to Roc.
        const contents: [*]const RocList = if (files.elements) |e| @ptrCast(@alignCast(e)) else undefined;
        const count = files.length;
        var handles: RocList = .{ .elements = null, .length = 0, .capacity_or_alloc_ptr = 0 };
        if (count > 0) {
            const base: [*]u8 = @ptrCast(roc_alloc(@sizeOf(usize) * (count + 2), @alignOf(usize)));
            const words: [*]usize = @ptrCast(@alignCast(base));
            words[0] = count;
            words[1] = 1;
            const elems: [*]usize = words + 2;
            for (0..count) |i| {
                const p = blobs.mint(.{ .kind = .file, .bytes = copyOf(listBytes(contents[i])) }) orelse jobFault(2, "resource_limit: a task's job was sent more files than its instance holds");
                elems[i] = @intFromPtr(p);
            }
            handles = .{ .elements = @ptrCast(elems), .length = count, .capacity_or_alloc_ptr = count << 1 };
        }
        releaseFiles(files);
        in_task = true;
        const out = roc_engine_task(payload, handles);
        in_task = false;
        const answer = listBytes(out);
        if (answer.len < 4) jobFault(1, "contract: a task's entry returned an answer without its file count");
        const n = std.mem.readInt(u32, answer[0..4], .little);
        if (n > max_answer_files) {
            childWrite(fds[1], &[_]u8{ 13, 2 });
            _exit(0);
        }
        if (answer.len < 4 + 8 * @as(usize, n)) jobFault(1, "contract: a task's entry returned a truncated answer");
        var head: [5]u8 = undefined;
        head[0] = 20;
        std.mem.writeInt(u32, head[1..5], n, .little);
        childWrite(fds[1], &head);
        var held: [max_answer_files]*Held = undefined;
        for (0..n) |i| {
            const token = std.mem.readInt(u64, answer[4 + 8 * i ..][0..8], .little);
            const h = blobs.get(token) orelse jobFault(1, "contract: a task's answer names a handle its instance does not hold");
            if (h.kind != .file) jobFault(1, "contract: a task's answer names a builder; only a finished file can be in an answer");
            held[i] = h;
            var size: [8]u8 = undefined;
            std.mem.writeInt(u64, &size, h.bytes.len, .little);
            childWrite(fds[1], &size);
            childStr(fds[1], h.name);
            childStr(fds[1], h.mime);
        }
        const output = answer[4 + 8 * @as(usize, n) ..];
        var size: [8]u8 = undefined;
        std.mem.writeInt(u64, &size, output.len, .little);
        childWrite(fds[1], &size);
        childWrite(fds[1], output);
        for (held[0..n]) |h| childWrite(fds[1], h.bytes);
        _exit(0);
    }
    releaseBytes(payload);
    releaseFiles(files);
    _ = close(fds[1]);
    return awaitJob(pid, fds[0], 0);
}

/// In a task job's child: a string as the wire writes one, `len:u32 bytes`.
fn childStr(fd: c_int, bytes: []const u8) void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(bytes.len), .little);
    childWrite(fd, &len);
    childWrite(fd, bytes);
}

comptime {
    @export(&hostedTask, .{ .name = "roc_test_task" });
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
    // Exported by name rather than declared `pub fn main`, which Zig would
    // treat as its own program entry.
    @export(&cMain, .{ .name = "main" });
}

fn cMain(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    const count: usize = @intCast(argc);
    return roc_spec_main(argsList(argv[1..count]));
}
