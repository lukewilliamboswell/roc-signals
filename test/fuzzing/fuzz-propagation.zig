//! Placeholder for the propagation fuzz target; the harness is filled in separately.

const std = @import("std");
const signals = @import("signals");
const FuzzReader = @import("FuzzReader.zig");

/// AFL++ persistent-mode initialization hook.
pub export fn zig_fuzz_init() void {}

/// AFL++ persistent-mode entry point.
pub export fn zig_fuzz_test(buf: [*]u8, len: isize) void {
    zig_fuzz_test_inner(buf, len, false);
}

/// Runs one fuzz input.
pub fn zig_fuzz_test_inner(buf: [*]u8, len: isize, debug: bool) void {
    _ = debug;
    var reader = FuzzReader.init(buf[0..@intCast(len)]);
    _ = reader.readByte();
    _ = signals;
    _ = std;
}
