//! Minimal panic and stderr handlers for concise native-host failures.

const std = @import("std");

pub const std_options: std.Options = .{
    .logFn = std.log.defaultLog,
    .log_level = .warn,
    .allow_stack_tracing = false,
};

pub const panic = std.debug.FullPanic(panicImpl);

pub fn writeStderr(bytes: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), bytes) catch {};
}

fn panicImpl(msg: []const u8, addr: ?usize) noreturn {
    writeStderr("\n=== PANIC (no stack trace) ===\n");
    writeStderr(msg);
    if (addr) |a| {
        var buf: [32]u8 = undefined;
        const hex = std.fmt.bufPrint(&buf, " at address 0x{x}\n", .{a}) catch "";
        writeStderr(hex);
    } else {
        writeStderr("\n");
    }
    std.process.abort();
}
