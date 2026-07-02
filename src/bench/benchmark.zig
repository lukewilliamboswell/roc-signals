//! Benchmark helpers for measuring Signals host runtime phases and command counts.

const std = @import("std");

const signals = @import("signals");
const engine = signals.engine;
const render = signals.render;
const spec_parser = @import("../spec/spec_parser.zig");

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

pub fn nowNs() u64 {
    const ns = std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds;
    return @intCast(@max(ns, 0));
}

pub fn commandIsAction(cmd: spec_parser.SpecCommand) bool {
    return switch (cmd.cmd_type) {
        .click, .real_click, .pointer_down, .pointer_up, .pointer_enter, .pointer_leave, .key_down, .focus, .blur, .change, .composition_start, .composition_end, .submit, .fill, .check, .uncheck, .resolve_task, .reject_task, .tick_interval, .tick_interval_if_active => true,
        else => false,
    };
}

fn namedUnitEventNameForCommand(cmd_type: spec_parser.SpecCommandType) ?[]const u8 {
    return switch (cmd_type) {
        .focus => "focus",
        .blur => "blur",
        .composition_start => "compositionstart",
        .composition_end => "compositionend",
        else => null,
    };
}

fn eventPolicyMatchesBenchmarkEvent(policy: render.EventPolicy, elem_id: u64, target_id: u64) bool {
    if (policy.self and elem_id != target_id) return false;
    return true;
}

fn writeStdout(bytes: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), bytes) catch {};
}

fn printStdout(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeStdout(out);
}

pub fn printHeader() void {
    writeStdout("case,sample,iterations,actions,init_roc_ns,init_apply_ns,dispatch_roc_ns,dispatch_apply_ns,total_ns,allocs,deallocs,retained_alloc_delta,commands,reset_dom,create_element,append_child,remove_node,move_before,set_text,set_value,set_checked,set_disabled,set_metadata,bind_event,active_graph_records_rebuilt,stream_nodes_scanned,stream_nodes_scanned_apply,stream_nodes_scanned_children,stream_nodes_scanned_dirty_scope,stream_nodes_scanned_events,stream_nodes_scanned_mounts,stream_nodes_scanned_remove_target,stream_nodes_scanned_render_scope,stream_nodes_scanned_splice,signal_record_table_rebuilt,active_intervals_synced,render_indexes_refreshed,each_key_compares,each_key_hashes,each_key_reuse_compares,each_key_duplicate_compares,each_item_compares,each_syncs,each_sync_keys,each_sync_existing_rows,allocs_this_event,deallocs_this_event,host_allocs_this_event,host_deallocs_this_event,host_alloc_bytes_this_event,host_dealloc_bytes_this_event,events_processed,nodes_recomputed,propagation_prunes,derived_calls_into_roc,recompute_batches,patches_emitted,scopes_created,scopes_disposed,rows_reused,rows_created,rows_removed,closure_retains,closure_releases,metrics_retained_alloc_delta,host_retained_alloc_delta,host_retained_bytes_delta\n");
}

pub fn printRow(case_name: []const u8, sample: usize, iterations: usize, stats: Stats) void {
    const total_ns = stats.init_roc_ns + stats.init_apply_ns + stats.dispatch_roc_ns + stats.dispatch_apply_ns;
    printStdout(
        "{s},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},",
        .{
            case_name,
            sample,
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
            stats.metrics.nodes_recomputed,
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

pub fn Runner(comptime Ctx: type) type {
    return struct {
        const Host = Ctx.Host;
        const RocHost = Ctx.RocHost;
        const SpecCommand = spec_parser.SpecCommand;

        pub fn runAppBenchmarks(spec_file: []const u8, case_name: []const u8, iterations: usize, samples: usize, verbose: bool) error{}!c_int {
            var bench_gpa = std.heap.DebugAllocator(.{ .safety = true }){};
            defer _ = bench_gpa.deinit();
            const allocator = bench_gpa.allocator();
            const commands = spec_parser.parseTestSpecFile(allocator, spec_file) catch |err| {
                switch (err) {
                    spec_parser.ParseError.FileNotFound => writeStderr("Error: Test spec file not found\n"),
                    spec_parser.ParseError.InvalidFormat => writeStderr("Error: Invalid test spec format\n"),
                    else => writeStderr("Error: Failed to parse test spec\n"),
                }
                return 1;
            };
            defer spec_parser.freeSpecCommands(allocator, commands);

            printHeader();
            for (0..samples) |sample| {
                var stats: Stats = .{};
                for (0..iterations) |_| {
                    runBenchmarkIteration(commands, verbose, &stats);
                }
                printRow(case_name, sample, iterations, stats);
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

            const init_start_ns = nowNs();
            const init_result = Ctx.initRocUi();
            stats.init_roc_ns += nowNs() - init_start_ns;
            Ctx.acceptInitElemMeasured(&host, &roc_host, init_result, &stats.init_apply_ns, &stats.commands);

            for (commands) |cmd| {
                if (commandIsAction(cmd)) {
                    runActionCommandMeasured(&host, &roc_host, cmd, stats);
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
            switch (cmd.cmd_type) {
                .click => {
                    const elem = Ctx.findElementByLocator(host, cmd.locator, cmd.line_num) orelse Ctx.fail("benchmark click locator did not resolve");
                    if (Ctx.elementDisabled(elem)) Ctx.fail("benchmark click target is disabled");
                    const event_id = Ctx.clickEventId(elem) orelse Ctx.fail("benchmark click target has no binding");
                    Ctx.dispatchRocEventMeasured(host, roc_host, event_id, engine.BoundaryPayloadDescriptor.init(.unit, .none), Ctx.hostValueUnit(host, roc_host), stats);
                },

                .real_click => {
                    const elem = Ctx.findElementByLocator(host, cmd.locator, cmd.line_num) orelse Ctx.fail("benchmark real_click locator did not resolve");
                    if (Ctx.elementDisabled(elem)) Ctx.fail("benchmark real_click target is disabled");
                    dispatchBubblingUnitEventMeasured(host, roc_host, elem.id, .pointer_down, "pointerdown", stats);
                    dispatchBubblingUnitEventMeasured(host, roc_host, elem.id, .pointer_up, "pointerup", stats);
                    dispatchBubblingUnitEventMeasured(host, roc_host, elem.id, .click, "click", stats);
                },

                .pointer_down, .pointer_up, .pointer_enter, .pointer_leave => {
                    const elem = Ctx.findElementByLocator(host, cmd.locator, cmd.line_num) orelse Ctx.fail("benchmark pointer locator did not resolve");
                    if (Ctx.elementDisabled(elem)) Ctx.fail("benchmark pointer target is disabled");
                    const event_id = Ctx.pointerEventId(elem, cmd.cmd_type) orelse Ctx.fail("benchmark pointer target has no binding");
                    Ctx.dispatchRocEventMeasured(host, roc_host, event_id, engine.BoundaryPayloadDescriptor.init(.unit, .none), Ctx.hostValueUnit(host, roc_host), stats);
                },

                .key_down => {
                    const elem = Ctx.findElementByLocator(host, cmd.locator, cmd.line_num) orelse Ctx.fail("benchmark key_down locator did not resolve");
                    if (Ctx.elementDisabled(elem)) Ctx.fail("benchmark key_down target is disabled");
                    Ctx.dispatchKeyDownMeasured(
                        host,
                        roc_host,
                        elem,
                        cmd.expected_text orelse Ctx.fail("benchmark key_down command is missing key text"),
                        cmd.expected_bool orelse Ctx.fail("benchmark key_down command is missing shift flag"),
                        stats,
                    );
                },

                .focus, .blur, .composition_start, .composition_end => {
                    const event_name = namedUnitEventNameForCommand(cmd.cmd_type) orelse Ctx.fail("benchmark named event command had no event name");
                    const elem = Ctx.findElementByLocator(host, cmd.locator, cmd.line_num) orelse Ctx.fail("benchmark named event locator did not resolve");
                    if (Ctx.elementDisabled(elem)) Ctx.fail("benchmark named event target is disabled");
                    const event = Ctx.namedEvent(elem, event_name) orelse Ctx.fail("benchmark named event target has no binding");
                    if (!event.binding.payload_descriptor.eql(engine.BoundaryPayloadDescriptor.init(.unit, .none))) Ctx.fail("benchmark named event binding does not use a unit payload descriptor");
                    Ctx.dispatchRocEventMeasured(host, roc_host, event.binding.event_id, event.binding.payload_descriptor, Ctx.hostValueUnit(host, roc_host), stats);
                },

                .change => {
                    const value = cmd.expected_text orelse "";
                    const elem = Ctx.findElementByLocator(host, cmd.locator, cmd.line_num) orelse Ctx.fail("benchmark change locator did not resolve");
                    if (Ctx.elementDisabled(elem)) Ctx.fail("benchmark change target is disabled");
                    const event = Ctx.namedEvent(elem, "change") orelse Ctx.fail("benchmark change target has no binding");
                    if (!event.binding.payload_descriptor.eql(engine.BoundaryPayloadDescriptor.init(.str, .target_value))) Ctx.fail("benchmark change binding does not request the target value payload descriptor");
                    _ = Ctx.setElementValueIfChanged(host, elem, value);
                    Ctx.dispatchRocEventMeasured(host, roc_host, event.binding.event_id, event.binding.payload_descriptor, Ctx.hostValueStr(host, roc_host, value), stats);
                },

                .submit => {
                    const elem = Ctx.findElementByLocator(host, cmd.locator, cmd.line_num) orelse Ctx.fail("benchmark submit locator did not resolve");
                    if (Ctx.elementDisabled(elem)) Ctx.fail("benchmark submit target is disabled");
                    Ctx.dispatchSubmitMeasured(host, roc_host, elem, stats);
                },

                .fill => {
                    const value = cmd.expected_text orelse "";
                    const elem = Ctx.findElementByLocator(host, cmd.locator, cmd.line_num) orelse Ctx.fail("benchmark fill locator did not resolve");
                    if (Ctx.elementDisabled(elem)) Ctx.fail("benchmark fill target is disabled");
                    if (Ctx.inputEventId(elem)) |event_id| {
                        Ctx.dispatchRocEventMeasured(host, roc_host, event_id, engine.BoundaryPayloadDescriptor.init(.str, .target_value), Ctx.hostValueStr(host, roc_host, value), stats);
                    } else {
                        _ = Ctx.setElementValueIfChanged(host, elem, value);
                    }
                },

                .check, .uncheck => {
                    const checked = cmd.cmd_type == .check;
                    const elem = Ctx.findElementByLocator(host, cmd.locator, cmd.line_num) orelse Ctx.fail("benchmark check locator did not resolve");
                    if (Ctx.elementDisabled(elem)) Ctx.fail("benchmark check target is disabled");
                    if (Ctx.checkEventId(elem)) |event_id| {
                        Ctx.dispatchRocEventMeasured(host, roc_host, event_id, engine.BoundaryPayloadDescriptor.init(.bool, .target_checked), Ctx.hostValueBool(host, roc_host, checked), stats);
                    } else {
                        _ = Ctx.setElementCheckedIfChanged(elem, checked);
                    }
                },

                .resolve_task, .reject_task => {
                    const task_name = cmd.task_name orelse Ctx.fail("benchmark task command had no task name");
                    const payload = cmd.expected_text orelse "";
                    const start_ns = nowNs();
                    const counts = Ctx.resolvePendingTask(host, roc_host, task_name, payload, cmd.cmd_type == .reject_task);
                    stats.dispatch_apply_ns += nowNs() - start_ns;
                    stats.commands.addAll(counts);
                    Ctx.finishHostMetrics(host);
                    stats.actions += 1;
                },

                .tick_interval => {
                    const period_ms = cmd.interval_ms orelse Ctx.fail("benchmark interval command had no period");
                    const start_ns = nowNs();
                    const counts = Ctx.tickIntervalSource(host, roc_host, period_ms);
                    stats.dispatch_apply_ns += nowNs() - start_ns;
                    stats.commands.addAll(counts);
                    Ctx.finishHostMetrics(host);
                    stats.actions += 1;
                },

                .tick_interval_if_active => {
                    const period_ms = cmd.interval_ms orelse Ctx.fail("benchmark interval command had no period");
                    if (Ctx.activeIntervalRecordCountByPeriod(host, period_ms) != 0) {
                        const start_ns = nowNs();
                        const counts = Ctx.tickIntervalSource(host, roc_host, period_ms);
                        stats.dispatch_apply_ns += nowNs() - start_ns;
                        stats.commands.addAll(counts);
                        Ctx.finishHostMetrics(host);
                    }
                    stats.actions += 1;
                },

                else => {},
            }
        }

        fn dispatchBubblingUnitEventMeasured(host: *Host, roc_host: *RocHost, target_id: u64, fixed_kind: render.EventKind, event_name: []const u8, stats: *Stats) void {
            var path: [128]u64 = undefined;
            var path_len: usize = 0;
            var next_id: ?u64 = target_id;
            while (next_id) |elem_id| {
                if (path_len >= path.len) Ctx.fail("benchmark event propagation path exceeded limit");
                const elem = Ctx.elementById(host, elem_id) orelse Ctx.fail("benchmark event propagation path referenced missing element");
                path[path_len] = elem.id;
                path_len += 1;
                next_id = elem.parent_id;
            }

            const unit_descriptor = engine.BoundaryPayloadDescriptor.init(.unit, .none);
            var dispatched = false;

            var capture_index = path_len;
            while (capture_index > 0) {
                capture_index -= 1;
                const elem_id = path[capture_index];
                const elem = Ctx.elementById(host, elem_id) orelse Ctx.fail("benchmark event target was removed during capture");
                const event = Ctx.namedEvent(elem, event_name) orelse continue;
                if (!event.binding.policy.capture) continue;
                if (!eventPolicyMatchesBenchmarkEvent(event.binding.policy, elem_id, target_id)) continue;
                if (!event.binding.payload_descriptor.eql(unit_descriptor)) Ctx.fail("benchmark capturing event binding does not use a unit payload descriptor");
                dispatched = true;
                Ctx.dispatchRocEventMeasured(host, roc_host, event.binding.event_id, event.binding.payload_descriptor, Ctx.hostValueUnit(host, roc_host), stats);
                if (event.binding.policy.stop_propagation or event.binding.policy.stop_immediate) return;
            }

            for (path[0..path_len]) |elem_id| {
                const elem = Ctx.elementById(host, elem_id) orelse Ctx.fail("benchmark event target was removed during bubble");
                if (Ctx.fixedEventId(elem, fixed_kind)) |event_id| {
                    dispatched = true;
                    Ctx.dispatchRocEventMeasured(host, roc_host, event_id, unit_descriptor, Ctx.hostValueUnit(host, roc_host), stats);
                }

                const event = Ctx.namedEvent(elem, event_name) orelse continue;
                if (event.binding.policy.capture) continue;
                if (!eventPolicyMatchesBenchmarkEvent(event.binding.policy, elem_id, target_id)) continue;
                if (!event.binding.payload_descriptor.eql(unit_descriptor)) Ctx.fail("benchmark bubbling event binding does not use a unit payload descriptor");
                dispatched = true;
                Ctx.dispatchRocEventMeasured(host, roc_host, event.binding.event_id, event.binding.payload_descriptor, Ctx.hostValueUnit(host, roc_host), stats);
                if (event.binding.policy.stop_propagation or event.binding.policy.stop_immediate) break;
            }

            if (std.mem.eql(u8, event_name, "click") and !dispatched) {
                Ctx.fail("benchmark real_click did not find a click binding in the propagation path");
            }
        }
    };
}

test "commandIsAction recognizes only mutating commands" {
    try std.testing.expect(commandIsAction(.{
        .cmd_type = .click,
        .locator = .{ .kind = .none },
        .expected_text = null,
        .expected_count = null,
        .expected_bool = null,
        .line_num = 1,
    }));
    try std.testing.expect(commandIsAction(.{
        .cmd_type = .focus,
        .locator = .{ .kind = .none },
        .expected_text = null,
        .expected_count = null,
        .expected_bool = null,
        .line_num = 2,
    }));
    try std.testing.expect(!commandIsAction(.{
        .cmd_type = .expect_text,
        .locator = .{ .kind = .none },
        .expected_text = null,
        .expected_count = null,
        .expected_bool = null,
        .line_num = 3,
    }));
}
