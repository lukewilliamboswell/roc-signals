const std = @import("std");
comptime { _ = @import("host.zig"); }
extern fn start() void;
extern fn step(u64) void;
extern fn finish() void;
extern fn reset_metrics() void;
extern fn metric(u32) u64;
extern fn printf([*:0]const u8, ...) c_int;

fn report(phase: [*:0]const u8) void {
    _ = printf("{\"phase\":\"%s\",\"build\":\"Zig Debug + Roc dev\",\"allocs\":%llu,\"frees\":%llu,\"allocated_bytes\":%llu,\"live_allocs\":%llu,\"live_bytes\":%llu}\n", phase, metric(0), metric(1), metric(2), metric(4), metric(5));
}

export fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    start();
    report("mount");
    const actions: u64 = if (argc > 1 and std.mem.eql(u8, std.mem.span(argv[1]), "fixture")) 6 else 2;
    for (0..actions) |action| {
        reset_metrics();
        step(action);
        report(if (actions == 2 and action == 1) "clear" else "update");
    }
    reset_metrics();
    finish();
    report("teardown");
    return if (metric(4) == 0 and metric(5) == 0) 0 else 1;
}
