//! The native spec host's operating-system services on Windows: the twin of
//! `os_posix.zig`, with the same functions over `kernel32.dll` alone. The
//! runner links no C runtime: `mainCRTStartup` here is the process entry,
//! Zig's compiler-rt (bundled into the host library) supplies `memcpy` and
//! the stack probes, and `kernel32.def` lists every function imported, from
//! which the platform build makes the import library the link uses.
//!
//! A worker job runs in a child process that the runner starts from its own
//! executable (`runJob`), as on every system: `CreateProcessW` with the job's
//! input on the child's standard input and its answer on the child's
//! standard output, and the runner's standard error shared so the child's
//! fault report reaches it. Windows has no `fork`, and an anonymous pipe
//! cannot be waited on with a timeout, so a thread reads the child's output
//! while the runner waits for that thread with the job's bound.

const std = @import("std");

const HANDLE = *anyopaque;
const BOOL = c_int;
const invalid_handle: usize = std.math.maxInt(usize);

extern "kernel32" fn GetProcessHeap() callconv(.winapi) ?HANDLE;
extern "kernel32" fn HeapAlloc(heap: HANDLE, flags: u32, len: usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn HeapFree(heap: HANDLE, flags: u32, ptr: *anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn GetStdHandle(which: u32) callconv(.winapi) ?HANDLE;
extern "kernel32" fn WriteFile(file: HANDLE, buf: [*]const u8, len: u32, written: *u32, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn ReadFile(file: HANDLE, buf: [*]u8, len: u32, got: *u32, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, disposition: u32, flags: u32, template: ?HANDLE) callconv(.winapi) usize;
extern "kernel32" fn GetFileAttributesW(name: [*:0]const u16) callconv(.winapi) u32;
extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn QueryPerformanceCounter(count: *i64) callconv(.winapi) BOOL;
extern "kernel32" fn QueryPerformanceFrequency(freq: *i64) callconv(.winapi) BOOL;
extern "kernel32" fn ExitProcess(code: u32) callconv(.winapi) noreturn;
extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]const u16;
extern "kernel32" fn GetModuleFileNameW(module: ?HANDLE, buf: [*]u16, len: u32) callconv(.winapi) u32;
extern "kernel32" fn CreatePipe(read_end: *HANDLE, write_end: *HANDLE, security: ?*const SecurityAttributes, size: u32) callconv(.winapi) BOOL;
extern "kernel32" fn SetHandleInformation(handle: HANDLE, mask: u32, flags: u32) callconv(.winapi) BOOL;
extern "kernel32" fn CreateProcessW(app: ?[*:0]const u16, cmd: ?[*:0]u16, process_security: ?*anyopaque, thread_security: ?*anyopaque, inherit: BOOL, flags: u32, env: ?*anyopaque, cwd: ?[*:0]const u16, startup: *const StartupInfo, info: *ProcessInformation) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(handle: HANDLE, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn GetExitCodeProcess(process: HANDLE, code: *u32) callconv(.winapi) BOOL;
extern "kernel32" fn TerminateProcess(process: HANDLE, code: u32) callconv(.winapi) BOOL;
extern "kernel32" fn CreateThread(security: ?*anyopaque, stack: usize, start: *const fn (?*anyopaque) callconv(.winapi) u32, param: ?*anyopaque, flags: u32, id: ?*u32) callconv(.winapi) ?HANDLE;
extern "kernel32" fn SetErrorMode(mode: u32) callconv(.winapi) u32;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
extern "kernel32" fn DuplicateHandle(source_process: HANDLE, source: HANDLE, target_process: HANDLE, target: *HANDLE, access: u32, inherit: BOOL, options: u32) callconv(.winapi) BOOL;

const SecurityAttributes = extern struct { length: u32, descriptor: ?*anyopaque, inherit: BOOL };
const StartupInfo = std.os.windows.STARTUPINFOW;
const ProcessInformation = extern struct { process: HANDLE, thread: HANDLE, process_id: u32, thread_id: u32 };

const std_input: u32 = @bitCast(@as(i32, -10));
const std_output: u32 = @bitCast(@as(i32, -11));
const std_error: u32 = @bitCast(@as(i32, -12));
const generic_read: u32 = 0x80000000;
const file_share_read: u32 = 0x1;
const open_existing: u32 = 3;
const file_attribute_normal: u32 = 0x80;
const file_attribute_directory: u32 = 0x10;
const invalid_file_attributes: u32 = 0xFFFFFFFF;
const handle_flag_inherit: u32 = 1;
const startf_usestdhandles: u32 = 0x100;
const duplicate_same_access: u32 = 2;
const wait_object_0: u32 = 0;
const infinite: u32 = 0xFFFFFFFF;
const sem_failcriticalerrors: u32 = 0x1;
const sem_nogpfaulterrorbox: u32 = 0x2;
const create_unicode_environment: u32 = 0x400;

/// A file opened for reading.
pub const File = HANDLE;

/// Where `writeAll` writes.
pub const Stream = enum { out, err };

var heap: HANDLE = undefined;

/// Prepare the process before anything runs: the heap every allocation
/// comes from, and no error dialog for a crash, so a job's child that
/// crashes ends at once (and its runner sees an exit code) instead of
/// waiting on a dialog nobody will answer.
pub fn init() void {
    heap = GetProcessHeap() orelse ExitProcess(2);
    _ = SetErrorMode(sem_failcriticalerrors | sem_nogpfaulterrorbox);
}

/// The process arguments, without the program's own name, as UTF-8 (WTF-8
/// for a name that is not valid UTF-16), parsed from the command line by
/// the rules the C runtime follows. They stay valid for the life of the
/// process. Called once, after `init`.
pub fn args() []const [*:0]const u8 {
    const line = std.mem.span(GetCommandLineW());
    const room = std.unicode.calcWtf8Len(line) + 1;
    // The iterator's one buffer, and the slices of the arguments: at most
    // one argument per two units of the line, plus the program's name.
    const most = line.len / 2 + 2;
    const words = most * @sizeOf([*:0]const u8);
    const parsing = std.mem.alignForward(usize, room + 64, 16);
    const bytes = alloc(16, parsing + words) orelse ExitProcess(2);
    var fixed = std.heap.FixedBufferAllocator.init(bytes[0..parsing]);
    var it = std.process.Args.Iterator.Windows.init(fixed.allocator(), line) catch ExitProcess(2);
    const list: [*][*:0]const u8 = @ptrCast(@alignCast(bytes + parsing));
    var n: usize = 0;
    _ = it.skip();
    while (it.next()) |arg| : (n += 1) list[n] = arg.ptr;
    return list[0..n];
}

/// `len` bytes aligned to `alignment` (a power of two of at least 16), or
/// null when the system has no memory left. Released with `release`. The
/// heap aligns to 16; a larger alignment over-allocates and keeps the heap's
/// address in the word before the pointer returned.
pub fn alloc(alignment: usize, len: usize) ?[*]u8 {
    const base: [*]u8 = @ptrCast(HeapAlloc(heap, 0, len + alignment) orelse return null);
    const user = std.mem.alignForward(usize, @intFromPtr(base) + @sizeOf(usize), alignment);
    @as(*usize, @ptrFromInt(user - @sizeOf(usize))).* = @intFromPtr(base);
    return @ptrFromInt(user);
}

/// Release memory `alloc` returned.
pub fn release(ptr: [*]u8) void {
    const base = @as(*const usize, @ptrFromInt(@intFromPtr(ptr) - @sizeOf(usize))).*;
    _ = HeapFree(heap, 0, @ptrFromInt(base));
}

fn writeHandle(handle: HANDLE, bytes: []const u8) bool {
    var rest = bytes;
    while (rest.len > 0) {
        var n: u32 = 0;
        const chunk: u32 = @intCast(@min(rest.len, 1 << 30));
        if (WriteFile(handle, rest.ptr, chunk, &n, null) == 0 or n == 0) return false;
        rest = rest[n..];
    }
    return true;
}

/// Write all of `bytes` to `stream`; false when the stream refuses them.
pub fn writeAll(stream: Stream, bytes: []const u8) bool {
    const handle = GetStdHandle(if (stream == .out) std_output else std_error) orelse return false;
    if (@intFromPtr(handle) == invalid_handle) return false;
    return writeHandle(handle, bytes);
}

/// `path` (UTF-8, NUL-terminated) as a NUL-terminated UTF-16 name, or null
/// when it is not valid or there is no memory. Released with `release`.
fn wide(path: [*:0]const u8) ?[*:0]u16 {
    const name = std.mem.span(path);
    const buf: [*]u16 = @ptrCast(@alignCast(alloc(16, (name.len + 1) * 2) orelse return null));
    const n = std.unicode.wtf8ToWtf16Le(buf[0..name.len], name) catch {
        release(@ptrCast(buf));
        return null;
    };
    buf[n] = 0;
    return @ptrCast(buf);
}

/// Open the file at `path` (UTF-8, NUL-terminated) for reading, or null.
pub fn openFile(path: [*:0]const u8) ?File {
    const name = wide(path) orelse return null;
    defer release(@ptrCast(name));
    const handle = CreateFileW(name, generic_read, file_share_read, null, open_existing, file_attribute_normal, null);
    return if (handle == invalid_handle) null else @ptrFromInt(handle);
}

/// Read up to `buf.len` bytes: the count (0 at the end), or null on error.
pub fn readSome(file: File, buf: []u8) ?usize {
    var n: u32 = 0;
    if (ReadFile(file, buf.ptr, @intCast(@min(buf.len, 1 << 30)), &n, null) == 0) return null;
    return n;
}

pub fn closeFile(file: File) void {
    _ = CloseHandle(file);
}

/// Whether `path` (UTF-8, NUL-terminated) names a file that is not a
/// directory and opens for reading.
pub fn isFile(path: [*:0]const u8) bool {
    const name = wide(path) orelse return false;
    defer release(@ptrCast(name));
    const attributes = GetFileAttributesW(name);
    if (attributes == invalid_file_attributes or attributes & file_attribute_directory != 0) return false;
    const file = openFile(path) orelse return false;
    closeFile(file);
    return true;
}

/// Monotonic time in nanoseconds.
pub fn nowNs() u64 {
    var count: i64 = 0;
    var freq: i64 = 0;
    if (QueryPerformanceCounter(&count) == 0 or QueryPerformanceFrequency(&freq) == 0 or freq <= 0) return 0;
    const c: u128 = @intCast(count);
    return @intCast(c * std.time.ns_per_s / @as(u128, @intCast(freq)));
}

/// End the process with `code`.
pub fn exitProcess(code: u8) noreturn {
    ExitProcess(code);
}

// ---------------------------------------------------------------------------
// Worker jobs.

/// How a job's child process ended.
pub const Ended = union(enum) {
    /// It exited with this status (a crash Windows ended it for has a
    /// status of its own, such as 0xC0000005).
    exited: u32,
    /// It was ended by a signal; never on Windows.
    died,
    /// It ran past the bound and was ended.
    timed_out,
};

/// The reader thread's state: the child's output end and where it goes.
fn Reader(comptime Out: type) type {
    return struct {
        pipe: HANDLE,
        out: Out,
        failed: bool = false,

        fn run(param: ?*anyopaque) callconv(.winapi) u32 {
            const self: *@This() = @ptrCast(@alignCast(param.?));
            while (true) {
                const room = self.out.room() orelse {
                    self.failed = true;
                    return 1;
                };
                var n: u32 = 0;
                // The end of the pipe (every write end closed) is an error
                // with nothing read.
                if (ReadFile(self.pipe, room.ptr, @intCast(@min(room.len, 1 << 30)), &n, null) == 0 or n == 0) return 0;
                self.out.len += n;
            }
        }
    };
}

/// A pipe whose one end, `child`, the job's process inherits.
fn childPipe(read_end: *HANDLE, write_end: *HANDLE, child: enum { reads, writes }) bool {
    const inheritable: SecurityAttributes = .{ .length = @sizeOf(SecurityAttributes), .descriptor = null, .inherit = 1 };
    if (CreatePipe(read_end, write_end, &inheritable, 0) == 0) return false;
    const own = if (child == .reads) write_end.* else read_end.*;
    _ = SetHandleInformation(own, handle_flag_inherit, 0);
    return true;
}

/// Run one job in a child process started from this executable with the
/// single argument `flag`: write `input` to its standard input and close it,
/// read its standard output to the end into `out` (a growing buffer with
/// `room()` and `len`, see `spec.zig`) on a thread of its own, and wait for
/// it. A child still running `bound_ms` after it started is ended and
/// answered `timed_out`. Null when the child cannot be started or `out`
/// cannot grow.
pub fn runJob(flag: [*:0]const u8, input: []const u8, bound_ms: u32, out: anytype) ?Ended {
    var path: [32768]u16 = undefined;
    const path_len = GetModuleFileNameW(null, &path, path.len - 1);
    if (path_len == 0 or path_len >= path.len - 1) return null;
    path[path_len] = 0;
    // The command line: the quoted path (a Windows path holds no quote),
    // a space and the flag (ASCII).
    const flag_bytes = std.mem.span(flag);
    const line_len = path_len + 3 + flag_bytes.len;
    const line: [*]u16 = @ptrCast(@alignCast(alloc(16, (line_len + 1) * 2) orelse return null));
    defer release(@ptrCast(line));
    line[0] = '"';
    @memcpy(line[1 .. 1 + path_len], path[0..path_len]);
    line[1 + path_len] = '"';
    line[2 + path_len] = ' ';
    for (flag_bytes, 0..) |c, i| line[3 + path_len + i] = c;
    line[line_len] = 0;

    var in_read: HANDLE = undefined;
    var in_write: HANDLE = undefined;
    var out_read: HANDLE = undefined;
    var out_write: HANDLE = undefined;
    if (!childPipe(&in_read, &in_write, .reads)) return null;
    if (!childPipe(&out_read, &out_write, .writes)) {
        _ = CloseHandle(in_read);
        _ = CloseHandle(in_write);
        return null;
    }
    // The runner's standard error, as an inheritable handle for the child.
    var err: ?HANDLE = null;
    if (GetStdHandle(std_error)) |e| {
        var dup: HANDLE = undefined;
        if (@intFromPtr(e) != invalid_handle and DuplicateHandle(GetCurrentProcess(), e, GetCurrentProcess(), &dup, 0, 1, duplicate_same_access) != 0) err = dup;
    }
    var startup: StartupInfo = std.mem.zeroes(StartupInfo);
    startup.cb = @sizeOf(StartupInfo);
    startup.dwFlags = startf_usestdhandles;
    startup.hStdInput = in_read;
    startup.hStdOutput = out_write;
    startup.hStdError = err;
    var info: ProcessInformation = undefined;
    const started = CreateProcessW(@ptrCast(&path), @ptrCast(line), null, null, 1, create_unicode_environment, null, null, &startup, &info);
    _ = CloseHandle(in_read);
    _ = CloseHandle(out_write);
    if (err) |e| _ = CloseHandle(e);
    if (started == 0) {
        _ = CloseHandle(in_write);
        _ = CloseHandle(out_read);
        return null;
    }
    defer _ = CloseHandle(info.process);
    _ = CloseHandle(info.thread);
    const start = nowNs();

    const R = Reader(@TypeOf(out));
    var reader: R = .{ .pipe = out_read, .out = out };
    const thread = CreateThread(null, 0, R.run, &reader, 0, null) orelse {
        _ = TerminateProcess(info.process, 1);
        _ = CloseHandle(in_write);
        _ = CloseHandle(out_read);
        return null;
    };
    defer _ = CloseHandle(thread);
    _ = writeHandle(in_write, input);
    _ = CloseHandle(in_write);
    const spent: u64 = (nowNs() - start) / std.time.ns_per_ms;
    const left: u32 = if (spent >= bound_ms) 0 else @intCast(bound_ms - spent);
    var timed_out = false;
    if (WaitForSingleObject(thread, left) != wait_object_0) {
        // Ending the child closes its end of the pipe, so the reader sees
        // the end and finishes.
        timed_out = true;
        _ = TerminateProcess(info.process, 1);
        _ = WaitForSingleObject(thread, infinite);
    }
    _ = CloseHandle(out_read);
    _ = WaitForSingleObject(info.process, infinite);
    if (reader.failed) return null;
    if (timed_out) return .timed_out;
    var code: u32 = 0;
    if (GetExitCodeProcess(info.process, &code) == 0) return .died;
    return .{ .exited = code };
}

/// In a job's child: read its whole standard input into `in` (a growing
/// buffer, as for `runJob`); false when it cannot be held. The end of a
/// pipe is a failed read, so any failed read ends the input, and a job cut
/// short is refused where `spec.zig` decodes it.
pub fn readJobInput(in: anytype) bool {
    const handle = GetStdHandle(std_input) orelse return false;
    while (true) {
        const room = in.room() orelse return false;
        var n: u32 = 0;
        if (ReadFile(handle, room.ptr, @intCast(@min(room.len, 1 << 30)), &n, null) == 0 or n == 0) return true;
        in.len += n;
    }
}
