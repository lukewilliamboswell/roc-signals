//! The native spec host's operating-system services on Linux (musl, linked
//! statically from the platform's `crt1.o` and `libc.a`) and macOS
//! (libSystem, which the Roc linker supplies). `spec.zig` reaches the system
//! only through the functions here, so the shared host says what it does
//! and this file says how the system does it.
//!
//! A worker job runs in a child process that the runner starts from its own
//! executable (`runJob`): `posix_spawn` with the job's input on the child's
//! standard input and its answer on the child's standard output, and the
//! runner's standard error shared so the child's fault report reaches it.

const std = @import("std");
const builtin = @import("builtin");

const darwin = builtin.os.tag.isDarwin();

extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern fn close(fd: c_int) c_int;
extern fn read(fd: c_int, buf: [*]u8, len: usize) isize;
extern fn write(fd: c_int, buf: [*]const u8, len: usize) isize;
extern fn posix_memalign(out: *?*anyopaque, alignment: usize, len: usize) c_int;
extern fn free(ptr: ?*anyopaque) void;
extern fn clock_gettime(clock: c_int, ts: *Timespec) c_int;
extern fn exit(code: c_int) noreturn;
extern fn pipe(fds: *[2]c_int) c_int;
extern fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
extern fn poll(fds: [*]PollFd, n: if (darwin) c_uint else c_ulong, timeout_ms: c_int) c_int;
extern fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
extern fn kill(pid: c_int, sig: c_int) c_int;
extern fn signal(sig: c_int, handler: usize) usize;
extern fn posix_spawn(pid: *c_int, path: [*:0]const u8, actions: *const SpawnActions, attr: ?*const anyopaque, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern fn posix_spawn_file_actions_init(actions: *SpawnActions) c_int;
extern fn posix_spawn_file_actions_adddup2(actions: *SpawnActions, fd: c_int, new_fd: c_int) c_int;
extern fn posix_spawn_file_actions_destroy(actions: *SpawnActions) c_int;
extern fn _NSGetExecutablePath(buf: [*]u8, size: *u32) c_int;
extern fn _NSGetEnviron() *[*:null]const ?[*:0]const u8;
extern var environ: [*:null]const ?[*:0]const u8;

const Timespec = extern struct { sec: isize, nsec: isize };
const PollFd = extern struct { fd: c_int, events: c_short, revents: c_short };

/// Storage for a `posix_spawn_file_actions_t`, which libc keeps opaque: a
/// pointer on macOS and 80 bytes on musl, so this holds either.
const SpawnActions = extern struct { words: [16]usize = @splat(0) };

const pollin: c_short = 1;
const sigkill: c_int = 9;
const sigpipe: c_int = 13;
const sig_ign: usize = 1;
const f_setfd: c_int = 2;
const fd_cloexec: c_int = 1;
const clock_monotonic: c_int = if (darwin) 6 else 1;
const o_rdonly: c_int = 0;
const o_directory: c_int = if (darwin) 0x100000 else 0o200000;

/// A file opened for reading.
pub const File = c_int;

/// Where `writeAll` writes.
pub const Stream = enum(c_int) { out = 1, err = 2 };

/// Prepare the process before anything runs: a job's child that ends
/// before reading its whole input must fail the runner's write, not end
/// the runner with `SIGPIPE`.
pub fn init() void {
    _ = signal(sigpipe, sig_ign);
}

/// The process arguments, without the program's own name, as `main`
/// receives them. They stay valid for the life of the process.
pub fn argsOf(argc: c_int, argv: [*]const [*:0]const u8) []const [*:0]const u8 {
    const count: usize = @intCast(argc);
    return if (count == 0) &.{} else argv[1..count];
}

/// `len` bytes aligned to `alignment` (a power of two of at least 16), or
/// null when the system has no memory left. Released with `free`.
pub fn alloc(alignment: usize, len: usize) ?[*]u8 {
    var out: ?*anyopaque = null;
    if (posix_memalign(&out, alignment, @max(len, 1)) != 0) return null;
    return @ptrCast(out);
}

/// Release memory `alloc` returned.
pub fn release(ptr: [*]u8) void {
    free(ptr);
}

/// Write all of `bytes` to `stream`; false when the stream refuses them.
pub fn writeAll(stream: Stream, bytes: []const u8) bool {
    var rest = bytes;
    while (rest.len > 0) {
        const n = write(@backingInt(stream), rest.ptr, rest.len);
        if (n <= 0) return false;
        rest = rest[@intCast(n)..];
    }
    return true;
}

/// Open the regular file at `path` (NUL-terminated) for reading, or null.
pub fn openFile(path: [*:0]const u8) ?File {
    const fd = open(path, o_rdonly);
    return if (fd < 0) null else fd;
}

/// Read up to `buf.len` bytes: the count (0 at the end), or null on error.
pub fn readSome(file: File, buf: []u8) ?usize {
    const n = read(file, buf.ptr, buf.len);
    return if (n < 0) null else @intCast(n);
}

pub fn closeFile(file: File) void {
    _ = close(file);
}

/// Whether `path` (NUL-terminated) names a readable file that is not a
/// directory (a directory opens read-only too, so it is refused first).
pub fn isFile(path: [*:0]const u8) bool {
    const dir = open(path, o_rdonly | o_directory);
    if (dir >= 0) {
        _ = close(dir);
        return false;
    }
    const fd = open(path, o_rdonly);
    if (fd < 0) return false;
    _ = close(fd);
    return true;
}

/// Monotonic time in nanoseconds.
pub fn nowNs() u64 {
    var ts: Timespec = undefined;
    if (clock_gettime(clock_monotonic, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// End the process with `code`.
pub fn exitProcess(code: u8) noreturn {
    exit(code);
}

// ---------------------------------------------------------------------------
// Worker jobs.

/// How a job's child process ended.
pub const Ended = union(enum) {
    /// It exited with this status.
    exited: u32,
    /// It was ended by a signal: a crash the host did not classify.
    died,
    /// It ran past the bound and was killed.
    timed_out,
};

/// The path of the running executable, for starting a job's child from it.
fn selfPath(buf: *[4096]u8) ?[*:0]const u8 {
    if (!darwin) return "/proc/self/exe";
    var size: u32 = buf.len;
    if (_NSGetExecutablePath(buf, &size) != 0) return null;
    return @ptrCast(buf);
}

fn environment() [*:null]const ?[*:0]const u8 {
    return if (darwin) _NSGetEnviron().* else environ;
}

fn cloexec(fd: c_int) void {
    _ = fcntl(fd, f_setfd, fd_cloexec);
}

fn msNow() i64 {
    return @intCast(nowNs() / std.time.ns_per_ms);
}

/// Run one job in a child process started from this executable with the
/// single argument `flag`: write `input` to its standard input and close it,
/// read its standard output to the end into `out` (a growing buffer with
/// `room()` and `len`, see `spec.zig`), and wait for it. A child still
/// running `bound_ms` after it started is killed and answered `timed_out`.
/// Null when the child cannot be started or `out` cannot grow.
///
/// The output is read before waiting, so a large answer cannot block the
/// child; a child that ends before reading all its input only shortens the
/// write (`SIGPIPE` is ignored, see `init`).
pub fn runJob(flag: [*:0]const u8, input: []const u8, bound_ms: u32, out: anytype) ?Ended {
    var path_buf: [4096]u8 = undefined;
    const path = selfPath(&path_buf) orelse return null;
    var to_child: [2]c_int = undefined;
    var from_child: [2]c_int = undefined;
    if (pipe(&to_child) != 0) return null;
    if (pipe(&from_child) != 0) {
        _ = close(to_child[0]);
        _ = close(to_child[1]);
        return null;
    }
    for ([_]c_int{ to_child[0], to_child[1], from_child[0], from_child[1] }) |fd| cloexec(fd);
    var actions: SpawnActions = .{};
    _ = posix_spawn_file_actions_init(&actions);
    _ = posix_spawn_file_actions_adddup2(&actions, to_child[0], 0);
    _ = posix_spawn_file_actions_adddup2(&actions, from_child[1], 1);
    const argv = [_:null]?[*:0]const u8{ path, flag };
    var pid: c_int = 0;
    const spawned = posix_spawn(&pid, path, &actions, null, &argv, environment());
    _ = posix_spawn_file_actions_destroy(&actions);
    _ = close(to_child[0]);
    _ = close(from_child[1]);
    if (spawned != 0) {
        _ = close(to_child[1]);
        _ = close(from_child[0]);
        return null;
    }
    const start = msNow();
    var rest = input;
    while (rest.len > 0) {
        const n = write(to_child[1], rest.ptr, rest.len);
        if (n <= 0) break;
        rest = rest[@intCast(n)..];
    }
    _ = close(to_child[1]);
    defer _ = close(from_child[0]);
    while (true) {
        const left = @as(i64, bound_ms) - (msNow() - start);
        var pfd = [_]PollFd{.{ .fd = from_child[0], .events = pollin, .revents = 0 }};
        const ready = if (left > 0) poll(&pfd, 1, @intCast(left)) else 0;
        if (ready == 0) {
            _ = kill(pid, sigkill);
            var ignored: c_int = 0;
            _ = waitpid(pid, &ignored, 0);
            return .timed_out;
        }
        if (ready < 0) continue;
        const room = out.room() orelse {
            _ = kill(pid, sigkill);
            var ignored: c_int = 0;
            _ = waitpid(pid, &ignored, 0);
            return null;
        };
        const n = read(from_child[0], room.ptr, room.len);
        if (n < 0) continue;
        if (n == 0) break;
        out.len += @intCast(n);
    }
    var status: c_int = 0;
    while (waitpid(pid, &status, 0) < 0) {}
    // A normal exit keeps its code in bits 8-15; a signal leaves bits 0-6 set.
    return if ((status & 0x7f) != 0) .died else .{ .exited = @intCast((status >> 8) & 0xff) };
}

/// In a job's child: read its whole standard input into `in` (a growing
/// buffer, as for `runJob`); false when it cannot be read or held.
pub fn readJobInput(in: anytype) bool {
    while (true) {
        const room = in.room() orelse return false;
        const n = read(0, room.ptr, room.len);
        if (n < 0) return false;
        if (n == 0) return true;
        in.len += @intCast(n);
    }
}
