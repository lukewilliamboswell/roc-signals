//! roc-signals addition to the roc-fuzz host: the process entry point and the
//! `Cli` services of `platform-test`.
//!
//! The roc-fuzz host (`libhost.a`, from the roc-fuzz 0.5.0 release) provides
//! the allocator, crash reporting and the libFuzzer callbacks. libFuzzer
//! normally supplies `main` from its own archive member; this object defines
//! `main` first, so the linker never pulls that member, and hands every
//! invocation except `spec` to `LLVMFuzzerRunDriver` exactly as libFuzzer's
//! own `main` does. Fuzz targets therefore behave as on roc-fuzz.
//!
//! `TARGET spec ARGS...` instead calls the target's `Target.cli` entry with
//! ARGS and exits with its result. Roc owns every value it receives: the
//! argument list is allocated with `roc_alloc`, hosted arguments are released
//! here, and the file contents returned by `roc_test_read_file` are a fresh
//! Roc list whose single reference passes to Roc.

const std = @import("std");

// Runtime symbols exported by the roc-fuzz host.
extern fn roc_alloc(length: usize, alignment: usize) callconv(.c) *anyopaque;
extern fn roc_dealloc(ptr: *anyopaque, alignment: usize) callconv(.c) void;

// libFuzzer and the roc-fuzz host.
extern fn LLVMFuzzerRunDriver(argc: *c_int, argv: *[*][*:0]u8, callback: *const fn (?[*]const u8, usize) callconv(.c) c_int) callconv(.c) c_int;
extern fn LLVMFuzzerTestOneInput(data: ?[*]const u8, size: usize) callconv(.c) c_int;

// The command-line entry the platform provides (`Target.cli!`).
extern fn roc_test_cli(args: RocList) callconv(.c) i32;

// musl libc.
extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern fn close(fd: c_int) c_int;
extern fn read(fd: c_int, buf: [*]u8, len: usize) isize;
extern fn write(fd: c_int, buf: [*]const u8, len: usize) isize;
extern fn malloc(len: usize) ?*anyopaque;
extern fn free(ptr: ?*anyopaque) void;
extern fn clock_gettime(clock: c_int, ts: *Timespec) c_int;
extern fn exit(code: c_int) noreturn;

const Timespec = extern struct { sec: i64, nsec: i64 };
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

fn fail(comptime prefix: []const u8, detail: []const u8) noreturn {
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

fn hostedNowNs() callconv(.c) u64 {
    var ts: Timespec = undefined;
    if (clock_gettime(clock_monotonic, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

comptime {
    @export(&hostedReadFile, .{ .name = "roc_test_read_file" });
    @export(&hostedFileExists, .{ .name = "roc_test_file_exists" });
    @export(&hostedStdout, .{ .name = "roc_test_stdout" });
    @export(&hostedStderr, .{ .name = "roc_test_stderr" });
    @export(&hostedNowNs, .{ .name = "roc_test_now_ns" });
    // Exported by name rather than declared `pub fn main`, which Zig would
    // treat as its own program entry.
    @export(&cMain, .{ .name = "main" });
}

fn cMain(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    if (argc >= 2 and std.mem.eql(u8, std.mem.span(argv[1]), "spec")) {
        const count: usize = @intCast(argc);
        const code = roc_test_cli(argsList(argv[2..count]));
        return code;
    }
    var count = argc;
    var args = argv;
    return LLVMFuzzerRunDriver(&count, &args, &LLVMFuzzerTestOneInput);
}
