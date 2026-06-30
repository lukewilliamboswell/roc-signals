//! Minimal compatibility surface copied from Roc's base module.

pub const signal_handler = @import("signal_handler.zig");

test {
    @import("std").testing.refAllDecls(signal_handler);
}
