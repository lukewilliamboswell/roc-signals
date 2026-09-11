//! Benchmark helpers for measuring Signals host runtime phases and command counts.

const std = @import("std");

const signals = @import("signals");
const engine = signals.engine;
const render = signals.render;
const spec_parser = @import("../spec/spec_parser.zig");
const spec_runner = @import("../spec/spec_runner.zig");

pub const Stats = struct {
    init_roc_ns: u64 = 0,
    init_apply_ns: u64 = 0,
    dispatch_roc_ns: u64 = 0,
    dispatch_apply_ns: u64 = 0,
    actions: u64 = 0,
    allocs: u64 = 0,
    deallocs: u64 = 0,
    retained_alloc_delta: i64 = 0,
    commands: render.Counts = .{},
    metrics: engine.RuntimeMetrics = engine.zeroRuntimeMetrics(),
};

/// Reads the monotonic clock used only for benchmark measurement.
pub fn nowNs() u64 {
    const ns = std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds;
    return @intCast(@max(ns, 0));
}

/// Classifies whether a spec command mutates app state and therefore belongs in benchmark replay.
pub fn commandIsAction(cmd: spec_parser.SpecCommand) bool {
    return switch (cmd.step) {
        .click, .real_click, .pointer_down, .pointer_up, .pointer_enter, .pointer_leave, .key_down, .focus, .blur, .change, .select_option, .custom_event, .composition_start, .composition_end, .submit, .fill, .check, .uncheck, .tick_interval, .tick_interval_if_active, .navigate, .set_visibility, .set_online, .history_back, .history_forward => true,
        else => false,
    };
}

fn writeStdout(bytes: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), bytes) catch {};
}

fn printStdout(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeStdout(out);
}

/// Writes header in the stable benchmark-report format.
pub fn printHeader() void {
    writeStdout("case,sample,warmup_iterations,iterations,actions,init_roc_ns,init_apply_ns,dispatch_roc_ns,dispatch_apply_ns,total_ns,allocs,deallocs,retained_alloc_delta,commands,reset_dom,create_element,append_child,remove_node,move_before,set_text,set_value,set_checked,set_disabled,set_metadata,bind_event,active_graph_records_rebuilt,stream_nodes_scanned,stream_nodes_scanned_apply,stream_nodes_scanned_children,stream_nodes_scanned_dirty_scope,stream_nodes_scanned_events,stream_nodes_scanned_mounts,stream_nodes_scanned_remove_target,stream_nodes_scanned_render_scope,stream_nodes_scanned_splice,signal_record_table_rebuilt,active_intervals_synced,render_indexes_refreshed,each_key_compares,each_key_hashes,each_key_reuse_compares,each_key_duplicate_compares,each_item_compares,each_syncs,each_sync_keys,each_sync_existing_rows,allocs_this_event,deallocs_this_event,host_allocs_this_event,host_deallocs_this_event,host_alloc_bytes_this_event,host_dealloc_bytes_this_event,events_processed,dirty_source_roots,propagation_prunes,derived_calls_into_roc,recompute_batches,patches_emitted,scopes_created,scopes_disposed,rows_reused,rows_created,rows_removed,closure_retains,closure_releases,metrics_retained_alloc_delta,host_retained_alloc_delta,host_retained_bytes_delta\n");
}

/// Writes row in the stable benchmark-report format.
pub fn printRow(case_name: []const u8, sample: usize, warmup_iterations: usize, iterations: usize, stats: Stats) void {
    const total_ns = stats.init_roc_ns + stats.init_apply_ns + stats.dispatch_roc_ns + stats.dispatch_apply_ns;
    printStdout(
        "{s},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},",
        .{
            case_name,
            sample,
            warmup_iterations,
            iterations,
            stats.actions,
            stats.init_roc_ns,
            stats.init_apply_ns,
            stats.dispatch_roc_ns,
            stats.dispatch_apply_ns,
            total_ns,
            stats.allocs,
            stats.deallocs,
            stats.retained_alloc_delta,
        },
    );
    printStdout(
        "{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},",
        .{
            stats.commands.total,
            stats.commands.reset_dom,
            stats.commands.create_element,
            stats.commands.append_child,
            stats.commands.remove_node,
            stats.commands.move_before,
            stats.commands.set_text,
            stats.commands.set_value,
            stats.commands.set_checked,
            stats.commands.set_disabled,
            stats.commands.set_metadata,
            stats.commands.bind_event,
        },
    );
    printStdout(
        "{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},",
        .{
            stats.metrics.active_graph_records_rebuilt,
            stats.metrics.stream_nodes_scanned,
            stats.metrics.stream_nodes_scanned_apply,
            stats.metrics.stream_nodes_scanned_children,
            stats.metrics.stream_nodes_scanned_dirty_scope,
            stats.metrics.stream_nodes_scanned_events,
            stats.metrics.stream_nodes_scanned_mounts,
            stats.metrics.stream_nodes_scanned_remove_target,
            stats.metrics.stream_nodes_scanned_render_scope,
            stats.metrics.stream_nodes_scanned_splice,
            stats.metrics.signal_record_table_rebuilt,
            stats.metrics.active_intervals_synced,
            stats.metrics.render_indexes_refreshed,
            stats.metrics.each_key_compares,
            stats.metrics.each_key_hashes,
            stats.metrics.each_key_reuse_compares,
            stats.metrics.each_key_duplicate_compares,
            stats.metrics.each_item_compares,
            stats.metrics.each_syncs,
            stats.metrics.each_sync_keys,
            stats.metrics.each_sync_existing_rows,
        },
    );
    printStdout(
        "{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d}\n",
        .{
            stats.metrics.allocs_this_event,
            stats.metrics.deallocs_this_event,
            stats.metrics.host_allocs_this_event,
            stats.metrics.host_deallocs_this_event,
            stats.metrics.host_alloc_bytes_this_event,
            stats.metrics.host_dealloc_bytes_this_event,
            stats.metrics.events_processed,
            stats.metrics.dirty_source_roots,
            stats.metrics.propagation_prunes,
            stats.metrics.derived_calls_into_roc,
            stats.metrics.recompute_batches,
            stats.metrics.patches_emitted,
            stats.metrics.scopes_created,
            stats.metrics.scopes_disposed,
            stats.metrics.rows_reused,
            stats.metrics.rows_created,
            stats.metrics.rows_removed,
            stats.metrics.closure_retains,
            stats.metrics.closure_releases,
            stats.metrics.retained_alloc_delta,
            stats.metrics.host_retained_alloc_delta,
            stats.metrics.host_retained_bytes_delta,
        },
    );
}

fn writeStderr(bytes: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), bytes) catch {};
}

fn metricAsI64(comptime Ctx: type, value: u64) i64 {
    return std.math.cast(i64, value) orelse Ctx.fail("runtime metric exceeded signed assertion range");
}

/// Builds the benchmark runner adapter around a host context without changing engine semantics.
pub fn Runner(comptime Ctx: type) type {
    return struct {
        const Host = Ctx.Host;
        const RocHost = Ctx.RocHost;
        const SpecCommand = spec_parser.SpecCommand;

        /// Runs app benchmarks using the host semantics and measurement boundaries defined by this module.
        pub fn runAppBenchmarks(spec_file: []const u8, case_name: []const u8, warmup_iterations: usize, iterations: usize, samples: usize, verbose: bool) error{}!c_int {
            var bench_gpa = std.heap.DebugAllocator(.{ .safety = true }){};
            defer _ = bench_gpa.deinit();
            const allocator = bench_gpa.allocator();
            const spec = spec_parser.parseTestSpecFile(allocator, spec_file) catch |err| {
                switch (err) {
                    spec_parser.ParseError.FileNotFound => writeStderr("Error: Test spec file not found\n"),
                    spec_parser.ParseError.InvalidFormat => writeStderr("Error: Invalid test spec format\n"),
                    else => writeStderr("Error: Failed to parse test spec\n"),
                }
                return 1;
            };
            defer spec.deinit(allocator);

            printHeader();
            for (0..samples) |sample| {
                for (0..warmup_iterations) |_| {
                    var warmup_stats: Stats = .{};
                    runBenchmarkIteration(spec.commands, verbose, &warmup_stats);
                }
                var stats: Stats = .{};
                for (0..iterations) |_| {
                    runBenchmarkIteration(spec.commands, verbose, &stats);
                }
                printRow(case_name, sample, warmup_iterations, iterations, stats);
            }

            return 0;
        }

        fn runBenchmarkIteration(commands: []const SpecCommand, verbose: bool, stats: *Stats) void {
            var host = Ctx.initHost();
            Ctx.setVerbose(&host, verbose);

            var roc_host = Ctx.makeRocHost(&host);
            Ctx.attachRocHost(&host, &roc_host);
            Ctx.enterCurrent(&host, &roc_host);
            defer Ctx.leaveCurrent();
            defer Ctx.deinitHost(&host);

            if (spec_runner.Runner(Ctx).applySetup(&host, commands) != 0) {
                Ctx.fail("benchmark setup was rejected by the shared spec runner");
            }

            const init_start_ns = nowNs();
            const init_result = Ctx.initRocUi();
            stats.init_roc_ns += nowNs() - init_start_ns;
            Ctx.acceptInitElemMeasured(&host, &roc_host, init_result, &stats.init_apply_ns, &stats.commands);

            var measurement_started = true;
            for (commands) |cmd| {
                if (cmd.kind() == .mark_metrics) {
                    measurement_started = false;
                    break;
                }
            }
            for (commands) |cmd| {
                if (cmd.kind() == .mark_metrics) {
                    measurement_started = true;
                } else if (commandIsAction(cmd)) {
                    if (measurement_started) {
                        runActionCommandMeasured(&host, &roc_host, cmd, stats);
                    } else {
                        // Setup actions before a mark establish the benchmark's
                        // required table size without contaminating the timed operation.
                        var setup_stats: Stats = .{};
                        runActionCommandMeasured(&host, &roc_host, cmd, &setup_stats);
                    }
                }
            }

            const retained_delta = @as(i64, @intCast(Ctx.allocCount(&host))) - @as(i64, @intCast(Ctx.deallocCount(&host)));
            var iteration_metrics = Ctx.lastRuntimeMetrics(&host);
            iteration_metrics.retained_alloc_delta = retained_delta;
            iteration_metrics.host_retained_alloc_delta = metricAsI64(Ctx, Ctx.hostAllocCount(&host)) - metricAsI64(Ctx, Ctx.hostDeallocCount(&host));
            iteration_metrics.host_retained_bytes_delta = metricAsI64(Ctx, Ctx.hostAllocBytes(&host)) - metricAsI64(Ctx, Ctx.hostDeallocBytes(&host));
            stats.metrics = Ctx.addRuntimeMetrics(stats.metrics, iteration_metrics);
            stats.allocs += @intCast(Ctx.allocCount(&host));
            stats.deallocs += @intCast(Ctx.deallocCount(&host));
            stats.retained_alloc_delta += retained_delta;
        }

        fn runActionCommandMeasured(host: *Host, roc_host: *RocHost, cmd: SpecCommand, stats: *Stats) void {
            Ctx.beginMeasurement(host, stats);
            defer Ctx.endMeasurement(host);
            const actions_before = stats.actions;
            switch (spec_runner.Runner(Ctx).dispatch(host, roc_host, cmd)) {
                .handled => {},
                .unsupported => Ctx.fail("benchmark selected a command unsupported by the semantic host"),
                .failed => Ctx.fail("benchmark action was rejected by the shared spec runner"),
            }
            // An inactive conditional tick still counts as an attempted
            // benchmark action even though it deliberately dispatches nothing.
            if (cmd.kind() == .tick_interval_if_active and stats.actions == actions_before) {
                stats.actions += 1;
            }
        }
    };
}

test "commandIsAction recognizes only mutating commands" {
    const none: spec_parser.Locator = .none;
    try std.testing.expect(commandIsAction(.{ .step = .{ .click = none }, .line_num = 1 }));
    try std.testing.expect(commandIsAction(.{ .step = .{ .focus = none }, .line_num = 2 }));
    try std.testing.expect(commandIsAction(.{ .step = .{ .navigate = "/" }, .line_num = 3 }));
    try std.testing.expect(commandIsAction(.{ .step = .{ .set_visibility = "hidden" }, .line_num = 4 }));
    try std.testing.expect(commandIsAction(.{ .step = .{ .custom_event = .{ .target = none, .name = "n", .detail = "" } }, .line_num = 5 }));
    try std.testing.expect(!commandIsAction(.{ .step = .{ .expect_text = .{ .target = none, .text = "" } }, .line_num = 6 }));
    try std.testing.expect(!commandIsAction(.{ .step = .mark_metrics, .line_num = 7 }));
    try std.testing.expect(!commandIsAction(.{ .step = .{ .expect_metric_delta = .{ .metric = "m", .delta = 0 } }, .line_num = 8 }));
}
