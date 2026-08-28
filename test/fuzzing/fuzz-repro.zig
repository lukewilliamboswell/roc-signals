//! Command-line runner that replays a single fuzz input outside AFL++.
//!
//! The AFL++ persistent-mode harness is fast but cannot be driven from a shell,
//! so every `fuzz-<name>` target is also linked into a `repro-<name>` executable
//! built from this file. It feeds one input through the same `zig_fuzz_test_inner`
//! entry point with `debug` set, which turns on the target's own tracing and
//! swaps in a leak-checking allocator, so a crash file saved by AFL++ can be
//! re-run under a debugger and its generated program printed.

const std = @import("std");
const fuzz_test = @import("fuzz_test");

const max_input_bytes = std.math.maxInt(u32);

const usage =
    \\Replays one fuzz input through its target.
    \\
    \\  repro-<target> <file>          read the input from a file
    \\  repro-<target> -b <base64>     read the input from a base64 argument
    \\  repro-<target>                 read the input from stdin
    \\
    \\  -v, --verbose                  print the generated program and extra tracing
    \\  -h, --help                     show this message
    \\
;

/// Entry point for the fuzz reproduction executables.
pub fn main(init: std.process.Init) anyerror!void {
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var input_arg: ?[]const u8 = null;
    var base64 = false;
    var verbose = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--base64")) {
            base64 = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print(usage, .{});
            return;
        } else if (input_arg == null) {
            input_arg = arg;
        } else {
            std.debug.print("unexpected argument: '{s}'\n\n" ++ usage, .{arg});
            std.process.exit(2);
        }
    }

    const bytes = try readInput(gpa, init.io, input_arg, base64);
    defer gpa.free(bytes);

    fuzz_test.zig_fuzz_init();
    fuzz_test.zig_fuzz_test_inner(bytes.ptr, @intCast(bytes.len), verbose);
}

fn readInput(gpa: std.mem.Allocator, io: std.Io, input_arg: ?[]const u8, base64: bool) ![]u8 {
    const arg = input_arg orelse {
        if (base64) {
            std.debug.print("--base64 requires an argument; it cannot read stdin\n", .{});
            std.process.exit(2);
        }
        return readStdin(gpa, io);
    };

    if (base64) {
        const decoder = std.base64.standard.Decoder;
        const decoded = try gpa.alloc(u8, try decoder.calcSizeForSlice(arg));
        errdefer gpa.free(decoded);
        try decoder.decode(decoded, arg);
        return decoded;
    }

    return std.Io.Dir.cwd().readFileAllocOptions(
        io,
        arg,
        gpa,
        .limited(max_input_bytes),
        std.mem.Alignment.of(u8),
        null,
    );
}

fn readStdin(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    var read_buf: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(io, &read_buf);

    var contents: std.ArrayList(u8) = .empty;
    errdefer contents.deinit(gpa);
    while (true) {
        const buf = try contents.addManyAsSlice(gpa, 4096);
        const n = stdin.interface.readSliceShort(buf) catch 0;
        contents.shrinkRetainingCapacity(contents.items.len - 4096 + n);
        if (n == 0) break;
    }
    return contents.toOwnedSlice(gpa);
}
