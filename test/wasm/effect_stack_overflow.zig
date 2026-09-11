//! Deliberately oversized frame used to verify pre-write stack containment.
//! The second stack grows toward a sentinel in the first allocation.
var stacks: [2][65536]u8 align(16) = undefined;

export fn runtime_stack_top(_: u32) usize {
    return effect_stack_top();
}

export fn runtime_stack_bottom(_: u32) usize {
    return @intFromPtr(&stacks[1]);
}

export fn runtime_set_main(_: usize) void {}

export fn runtime_run(_: u32) void {
    _ = overflow();
}

export fn effect_stack_top() usize {
    return @intFromPtr(&stacks[1]) + stacks[1].len;
}

export fn sentinel() u32 {
    const value: *volatile u8 = &stacks[0][60000];
    return value.*;
}

export fn prepare() void {
    const value: *volatile u8 = &stacks[0][60000];
    value.* = 42;
}

export fn overflow() u32 {
    var frame: [80000]u8 = undefined;
    const retained: *volatile [80000]u8 = &frame;
    for (0..frame.len) |index| retained[index] = 99;
    return retained[frame.len - 1];
}
