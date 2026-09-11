//! Compiled stack-local guards for overlapping browser effect suspensions.
//! Ordinary events and memory growth must not overwrite either saved frame.
extern "env" fn suspend_effect(id: u32) u32;
extern "env" fn set_limits(top: usize, bottom: usize) void;
const stack = @import("effect_stack");

var effect_stacks: [2][65536]u8 align(16) = undefined;
var main_stack: usize = 0;
var results: [2]u32 = undefined;

export fn set_main(value: usize) void {
    main_stack = value;
}

export fn set_stack(value: usize) void {
    stack.set(value);
}

export fn result(id: u32) u32 {
    return results[id];
}

export fn stack_pointer() usize {
    return stack.get();
}

export fn effect_stack_top(id: u32) usize {
    return @intFromPtr(&effect_stacks[id]) + 65536;
}

export fn effect_stack_bottom(id: u32) usize {
    return @intFromPtr(&effect_stacks[id]) + 128;
}

export fn run_effect(id: u32) void {
    const seed = (id + 1) * 10;
    var guard: [64]u32 = undefined;
    const retained: *volatile [64]u32 = &guard;
    for (0..64) |index| retained[index] = seed;
    const value = effect_body(id, seed);
    results[id] = value + retained[63] - seed;
}

noinline fn effect_body(id: u32, seed: u32) u32 {
    var values: [512]u32 = undefined;
    for (&values, 0..) |*value, index| value.* = seed + @as(u32, @intCast(index));
    // Force the array to remain in linear memory across the suspending import.
    const retained: *volatile [512]u32 = &values;
    const saved_stack = stack.get();
    set_limits(main_stack, 0);
    stack.set(main_stack);
    const response = suspend_effect(id);
    set_limits(effect_stack_top(id), effect_stack_bottom(id));
    stack.set(saved_stack);
    var sum: u32 = response;
    for (0..512) |index| sum +%= retained[index];
    return sum;
}

export fn event(seed: u32) u32 {
    var values: [1024]u32 = undefined;
    const retained: *volatile [1024]u32 = &values;
    for (0..1024) |index| retained[index] = seed;
    return retained[1023];
}
