const std = @import("std");

const signals = @import("signals");
const boundary = signals.boundary;
const engine = signals.engine;
const render = signals.render;
const spec_parser = @import("spec_parser.zig");

const BoundaryPayloadDescriptor = boundary.BoundaryPayloadDescriptor;
const RuntimeMetrics = engine.RuntimeMetrics;
const SpecCommand = spec_parser.SpecCommand;
const SpecCommandType = spec_parser.SpecCommandType;

fn writeLocatorFailureForCtx(comptime Ctx: type, line_num: usize, message: []const u8) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "TEST FAILED at line {d}: {s}\n", .{ line_num, message }) catch "TEST FAILED\n";
    Ctx.writeStderr(msg);
}

fn dispatchBubblingUnitEventById(comptime Ctx: type, host: *Ctx.Host, roc_host: *Ctx.RocHost, target_id: u64, fixed_kind: render.EventKind, event_name: []const u8, line_num: usize) bool {
    var path: [128]u64 = undefined;
    var path_len: usize = 0;
    var next_id: ?u64 = target_id;
    while (next_id) |elem_id| {
        if (path_len >= path.len) {
            writeLocatorFailureForCtx(Ctx, line_num, "event propagation path exceeded native spec runner limit");
            return false;
        }
        const elem = Ctx.elementById(host, elem_id) orelse {
            writeLocatorFailureForCtx(Ctx, line_num, "event propagation path referenced a missing element");
            return false;
        };
        path[path_len] = elem.id;
        path_len += 1;
        next_id = elem.parent_id;
    }

    var dispatched = false;
    var capture_index = path_len;
    while (capture_index > 0) {
        capture_index -= 1;
        const elem_id = path[capture_index];
        const elem = Ctx.elementById(host, elem_id) orelse {
            writeLocatorFailureForCtx(Ctx, line_num, "event target was removed before dispatch completed");
            return false;
        };
        const event = Ctx.namedEvent(elem, event_name) orelse continue;
        if (!event.binding.policy.capture) continue;
        if (!eventPolicyMatchesSpecEvent(event.binding.policy, elem_id, target_id)) continue;
        if (!event.binding.payload_descriptor.eql(BoundaryPayloadDescriptor.init(.unit, .none))) {
            writeLocatorFailureForCtx(Ctx, line_num, "capturing event binding does not use a unit payload descriptor");
            return false;
        }
        dispatched = true;
        Ctx.dispatchRocEvent(host, roc_host, event.binding.event_id, event.binding.payload_descriptor, Ctx.hostValueUnit(host, roc_host));
        if (event.binding.policy.stop_propagation or event.binding.policy.stop_immediate) return true;
    }

    for (path[0..path_len]) |elem_id| {
        const elem = Ctx.elementById(host, elem_id) orelse {
            writeLocatorFailureForCtx(Ctx, line_num, "event target was removed before dispatch completed");
            return false;
        };

        if (Ctx.fixedEventId(elem, fixed_kind)) |event_id| {
            dispatched = true;
            Ctx.dispatchRocEvent(host, roc_host, event_id, BoundaryPayloadDescriptor.init(.unit, .none), Ctx.hostValueUnit(host, roc_host));
        }

        const event = Ctx.namedEvent(elem, event_name) orelse continue;
        if (event.binding.policy.capture) continue;
        if (!eventPolicyMatchesSpecEvent(event.binding.policy, elem_id, target_id)) continue;
        if (!event.binding.payload_descriptor.eql(BoundaryPayloadDescriptor.init(.unit, .none))) {
            writeLocatorFailureForCtx(Ctx, line_num, "bubbling event binding does not use a unit payload descriptor");
            return false;
        }
        dispatched = true;
        Ctx.dispatchRocEvent(host, roc_host, event.binding.event_id, event.binding.payload_descriptor, Ctx.hostValueUnit(host, roc_host));
        if (event.binding.policy.stop_propagation or event.binding.policy.stop_immediate) break;
    }

    if (std.mem.eql(u8, event_name, "click") and !dispatched) {
        writeLocatorFailureForCtx(Ctx, line_num, "real_click did not find a click binding in the propagation path");
        return false;
    }
    return true;
}

fn eventPolicyMatchesSpecEvent(policy: render.EventPolicy, elem_id: u64, target_id: u64) bool {
    if (policy.self and elem_id != target_id) return false;
    return true;
}

fn dispatchSubmitEvent(comptime Ctx: type, host: *Ctx.Host, roc_host: *Ctx.RocHost, elem: anytype, line_num: usize) bool {
    if (elem.disabled) {
        writeLocatorFailureForCtx(Ctx, line_num, "target is disabled");
        return false;
    }
    const event = Ctx.namedEvent(elem, "submit") orelse {
        writeLocatorFailureForCtx(Ctx, line_num, "target has no submit binding");
        return false;
    };
    if (!event.binding.payload_descriptor.eql(BoundaryPayloadDescriptor.init(.unit, .none))) {
        writeLocatorFailureForCtx(Ctx, line_num, "submit binding does not use a unit payload descriptor");
        return false;
    }
    Ctx.dispatchRocEvent(host, roc_host, event.binding.event_id, event.binding.payload_descriptor, Ctx.hostValueUnit(host, roc_host));
    return true;
}

pub fn Runner(comptime Ctx: type) type {
    return struct {
        const Host = Ctx.Host;
        const RocHost = Ctx.RocHost;

        pub fn run(host: *Host, roc_host: *RocHost, commands: []const SpecCommand, verbose: bool) c_int {
            var metrics_mark: ?RuntimeMetrics = null;

            for (commands) |cmd| {
                switch (cmd.cmd_type) {
                    .mark_metrics => {
                        metrics_mark = Ctx.lastRuntimeMetrics(host);
                    },

                    .click => {
                        const elem = Ctx.findElementByLocator(host, cmd.locator, cmd.line_num) orelse {
                            writeLocatorFailure(cmd.line_num, "locator did not resolve to one element");
                            return 1;
                        };
                        if (elem.disabled) {
                            writeLocatorFailure(cmd.line_num, "target is disabled");
                            return 1;
                        }
                        const event_id = Ctx.fixedEventId(elem, .click) orelse blk: {
                            const event = Ctx.namedEvent(elem, "click") orelse {
                                writeLocatorFailure(cmd.line_num, "target has no click binding");
                                return 1;
                            };
                            if (!event.binding.payload_descriptor.eql(BoundaryPayloadDescriptor.init(.unit, .none))) {
                                writeLocatorFailure(cmd.line_num, "click binding does not use a unit payload descriptor");
                                return 1;
                            }
                            break :blk event.binding.event_id;
                        };
                        Ctx.dispatchRocEvent(host, roc_host, event_id, BoundaryPayloadDescriptor.init(.unit, .none), Ctx.hostValueUnit(host, roc_host));
                    },

                    .real_click => {
                        const elem = Ctx.findElementByLocator(host, cmd.locator, cmd.line_num) orelse {
                            writeLocatorFailure(cmd.line_num, "locator did not resolve to one element");
                            return 1;
                        };
                        if (elem.disabled) {
                            writeLocatorFailure(cmd.line_num, "target is disabled");
                            return 1;
                        }
                        const target_id = elem.id;
                        if (!dispatchBubblingUnitEventById(Ctx, host, roc_host, target_id, .pointer_down, "pointerdown", cmd.line_num)) return 1;
                        if (!dispatchBubblingUnitEventById(Ctx, host, roc_host, target_id, .pointer_up, "pointerup", cmd.line_num)) return 1;
                        if (!dispatchBubblingUnitEventById(Ctx, host, roc_host, target_id, .click, "click", cmd.line_num)) return 1;
                    },

                    .pointer_down, .pointer_up, .pointer_enter, .pointer_leave => {
                        const elem = Ctx.findElementByLocator(host, cmd.locator, cmd.line_num) orelse {
                            writeLocatorFailure(cmd.line_num, "locator did not resolve to one element");
                            return 1;
                        };
                        if (elem.disabled) {
                            writeLocatorFailure(cmd.line_num, "target is disabled");
                            return 1;
                        }
                        const event_id = pointerEventIdForCommand(elem, cmd.cmd_type) orelse blk: {
                            const event_name = pointerEventNameForCommand(cmd.cmd_type) orelse {
                                writeLocatorFailure(cmd.line_num, "unsupported pointer event command");
                                return 1;
                            };
                            const event = Ctx.namedEvent(elem, event_name) orelse {
                                writeLocatorFailure(cmd.line_num, "target has no pointer binding");
                                return 1;
                            };
                            if (!event.binding.payload_descriptor.eql(BoundaryPayloadDescriptor.init(.unit, .none))) {
                                writeLocatorFailure(cmd.line_num, "pointer binding does not use a unit payload descriptor");
                                return 1;
                            }
                            break :blk event.binding.event_id;
                        };
                        Ctx.dispatchRocEvent(host, roc_host, event_id, BoundaryPayloadDescriptor.init(.unit, .none), Ctx.hostValueUnit(host, roc_host));
                    },

                    .key_down => {
                        const elem = Ctx.findElementByLocator(host, cmd.locator, cmd.line_num) orelse {
                            writeLocatorFailure(cmd.line_num, "locator did not resolve to one element");
                            return 1;
                        };
                        if (elem.disabled) {
                            writeLocatorFailure(cmd.line_num, "target is disabled");
                            return 1;
                        }
                        const event = Ctx.namedEvent(elem, "keydown") orelse {
                            writeLocatorFailure(cmd.line_num, "target has no keydown binding");
                            return 1;
                        };
                        if (!event.binding.payload_descriptor.eql(BoundaryPayloadDescriptor.init(.bytes, .record_key_shift))) {
                            writeLocatorFailure(cmd.line_num, "keydown binding does not request the key/shift payload descriptor");
                            return 1;
                        }
                        const key = cmd.expected_text orelse {
                            writeLocatorFailure(cmd.line_num, "key_down command is missing key text");
                            return 1;
                        };
                        const shift_key = cmd.expected_bool orelse {
                            writeLocatorFailure(cmd.line_num, "key_down command is missing shift flag");
                            return 1;
                        };
                        const payload_bytes = encodeKeyShiftPayload(Ctx.allocator(host), key, shift_key);
                        defer Ctx.allocator(host).free(payload_bytes);
                        Ctx.dispatchRocEvent(host, roc_host, event.binding.event_id, event.binding.payload_descriptor, Ctx.hostValueU8List(host, roc_host, payload_bytes));
                    },

                    .focus, .blur, .composition_start, .composition_end => {
                        const event_name = namedUnitEventNameForCommand(cmd.cmd_type) orelse {
                            writeLocatorFailure(cmd.line_num, "unsupported named unit event command");
                            return 1;
                        };
                        const elem = Ctx.findElementByLocator(host, cmd.locator, cmd.line_num) orelse {
                            writeLocatorFailure(cmd.line_num, "locator did not resolve to one element");
                            return 1;
                        };
                        if (elem.disabled) {
                            writeLocatorFailure(cmd.line_num, "target is disabled");
                            return 1;
                        }
                        const event = Ctx.namedEvent(elem, event_name) orelse {
                            writeLocatorFailure(cmd.line_num, "target has no named event binding");
                            return 1;
                        };
                        if (!event.binding.payload_descriptor.eql(BoundaryPayloadDescriptor.init(.unit, .none))) {
                            writeLocatorFailure(cmd.line_num, "named event binding does not use a unit payload descriptor");
                            return 1;
                        }
                        Ctx.dispatchRocEvent(host, roc_host, event.binding.event_id, event.binding.payload_descriptor, Ctx.hostValueUnit(host, roc_host));
                    },

                    .change => {
                        const value = cmd.expected_text orelse "";
                        const elem = Ctx.findElementByLocator(host, cmd.locator, cmd.line_num) orelse {
                            writeLocatorFailure(cmd.line_num, "locator did not resolve to one element");
                            return 1;
                        };
                        if (elem.disabled) {
                            writeLocatorFailure(cmd.line_num, "target is disabled");
                            return 1;
                        }
                        const event = Ctx.namedEvent(elem, "change") orelse {
                            writeLocatorFailure(cmd.line_num, "target has no change binding");
                            return 1;
                        };
                        if (!event.binding.payload_descriptor.eql(BoundaryPayloadDescriptor.init(.str, .target_value))) {
                            writeLocatorFailure(cmd.line_num, "change binding does not request the target value payload descriptor");
                            return 1;
                        }
                        _ = Ctx.setElementValueIfChanged(host, elem, value);
                        Ctx.dispatchRocEvent(host, roc_host, event.binding.event_id, event.binding.payload_descriptor, Ctx.hostValueStr(host, roc_host, value));
                    },

                    .submit => {
                        const elem = Ctx.findElementByLocator(host, cmd.locator, cmd.line_num) orelse {
                            writeLocatorFailure(cmd.line_num, "locator did not resolve to one element");
                            return 1;
                        };
                        if (!dispatchSubmitEvent(Ctx, host, roc_host, elem, cmd.line_num)) return 1;
                    },

                    .fill => {
                        const value = cmd.expected_text orelse "";
                        const elem = Ctx.findElementByLocator(host, cmd.locator, cmd.line_num) orelse {
                            writeLocatorFailure(cmd.line_num, "locator did not resolve to one element");
                            return 1;
                        };
                        if (elem.disabled) {
                            writeLocatorFailure(cmd.line_num, "target is disabled");
                            return 1;
                        }
                        if (Ctx.fixedEventId(elem, .input)) |event_id| {
                            Ctx.dispatchRocEvent(host, roc_host, event_id, BoundaryPayloadDescriptor.init(.str, .target_value), Ctx.hostValueStr(host, roc_host, value));
                        } else if (Ctx.namedEvent(elem, "input")) |event| {
                            if (!event.binding.payload_descriptor.eql(BoundaryPayloadDescriptor.init(.str, .target_value))) {
                                writeLocatorFailure(cmd.line_num, "input binding does not request the target value payload descriptor");
                                return 1;
                            }
                            Ctx.dispatchRocEvent(host, roc_host, event.binding.event_id, event.binding.payload_descriptor, Ctx.hostValueStr(host, roc_host, value));
                        } else {
                            _ = Ctx.setElementValueIfChanged(host, elem, value);
                        }
                    },

                    .check, .uncheck => {
                        const checked = cmd.cmd_type == .check;
                        const elem = Ctx.findElementByLocator(host, cmd.locator, cmd.line_num) orelse {
                            writeLocatorFailure(cmd.line_num, "locator did not resolve to one element");
                            return 1;
                        };
                        if (elem.disabled) {
                            writeLocatorFailure(cmd.line_num, "target is disabled");
                            return 1;
                        }
                        if (Ctx.fixedEventId(elem, .check)) |event_id| {
                            Ctx.dispatchRocEvent(host, roc_host, event_id, BoundaryPayloadDescriptor.init(.bool, .target_checked), Ctx.hostValueBool(host, roc_host, checked));
                        } else if (Ctx.namedEvent(elem, "change")) |event| {
                            if (!event.binding.payload_descriptor.eql(BoundaryPayloadDescriptor.init(.bool, .target_checked))) {
                                writeLocatorFailure(cmd.line_num, "checkbox change binding does not request the target checked payload descriptor");
                                return 1;
                            }
                            Ctx.dispatchRocEvent(host, roc_host, event.binding.event_id, event.binding.payload_descriptor, Ctx.hostValueBool(host, roc_host, checked));
                        } else {
                            _ = Ctx.setElementCheckedIfChanged(elem, checked);
                        }
                    },

                    .resolve_task, .reject_task => {
                        const task_name = cmd.task_name orelse {
                            writeLocatorFailure(cmd.line_num, "task command had no task name");
                            return 1;
                        };
                        const payload = cmd.expected_text orelse "";
                        _ = Ctx.resolvePendingTask(host, roc_host, task_name, payload, cmd.cmd_type == .reject_task);
                        Ctx.finishHostMetrics(host);
                    },

                    .tick_interval => {
                        const period_ms = cmd.interval_ms orelse {
                            writeLocatorFailure(cmd.line_num, "interval command had no period");
                            return 1;
                        };
                        _ = Ctx.tickIntervalSource(host, roc_host, period_ms);
                        Ctx.finishHostMetrics(host);
                    },

                    .tick_interval_if_active => {
                        const period_ms = cmd.interval_ms orelse {
                            writeLocatorFailure(cmd.line_num, "interval command had no period");
                            return 1;
                        };
                        if (Ctx.activeIntervalRecordCountByPeriod(host, period_ms) != 0) {
                            _ = Ctx.tickIntervalSource(host, roc_host, period_ms);
                            Ctx.finishHostMetrics(host);
                        }
                    },

                    .expect_visible => {
                        _ = Ctx.findElementByLocator(host, cmd.locator, cmd.line_num) orelse {
                            writeLocatorFailure(cmd.line_num, "locator did not resolve to one visible element");
                            return 1;
                        };
                    },

                    .expect_absent => {
                        const match_count = Ctx.countElementsByLocator(host, cmd.locator);
                        if (match_count != 0) {
                            writeAbsentFailure(cmd.line_num, match_count);
                            return 1;
                        }
                    },

                    .expect_text => {
                        const expected = cmd.expected_text orelse "";
                        const elem = Ctx.findElementByLocator(host, cmd.locator, cmd.line_num) orelse {
                            writeLocatorFailure(cmd.line_num, "locator did not resolve to one element");
                            return 1;
                        };
                        const actual = elem.text orelse "";
                        if (!std.mem.eql(u8, actual, expected)) {
                            writeStringMismatch(cmd.line_num, "text", expected, actual);
                            return 1;
                        }
                    },

                    .expect_value => {
                        const expected = cmd.expected_text orelse "";
                        const elem = Ctx.findElementByLocator(host, cmd.locator, cmd.line_num) orelse {
                            writeLocatorFailure(cmd.line_num, "locator did not resolve to one element");
                            return 1;
                        };
                        const actual = elem.value orelse "";
                        if (!std.mem.eql(u8, actual, expected)) {
                            writeStringMismatch(cmd.line_num, "value", expected, actual);
                            return 1;
                        }
                    },

                    .expect_attr => {
                        const attr_name = cmd.expected_attr orelse {
                            writeLocatorFailure(cmd.line_num, "attr assertion had no attr name");
                            return 1;
                        };
                        const expected = cmd.expected_text orelse "";
                        const elem = Ctx.findElementByLocator(host, cmd.locator, cmd.line_num) orelse {
                            writeLocatorFailure(cmd.line_num, "locator did not resolve to one element");
                            return 1;
                        };
                        const actual = Ctx.elementTextAttr(elem, attr_name) orelse {
                            writeMissingAttr(cmd.line_num, attr_name);
                            return 1;
                        };
                        if (!std.mem.eql(u8, actual, expected)) {
                            writeStringMismatch(cmd.line_num, attr_name, expected, actual);
                            return 1;
                        }
                    },

                    .expect_no_attr => {
                        const attr_name = cmd.expected_attr orelse {
                            writeLocatorFailure(cmd.line_num, "attr assertion had no attr name");
                            return 1;
                        };
                        const elem = Ctx.findElementByLocator(host, cmd.locator, cmd.line_num) orelse {
                            writeLocatorFailure(cmd.line_num, "locator did not resolve to one element");
                            return 1;
                        };
                        if (Ctx.elementTextAttr(elem, attr_name) != null) {
                            writeUnexpectedAttr(cmd.line_num, attr_name);
                            return 1;
                        }
                    },

                    .expect_checked => {
                        const expected = cmd.expected_bool orelse false;
                        const elem = Ctx.findElementByLocator(host, cmd.locator, cmd.line_num) orelse {
                            writeLocatorFailure(cmd.line_num, "locator did not resolve to one element");
                            return 1;
                        };
                        if (elem.checked != expected) {
                            writeBoolMismatch(cmd.line_num, "checked", expected, elem.checked);
                            return 1;
                        }
                    },

                    .expect_disabled => {
                        const expected = cmd.expected_bool orelse false;
                        const elem = Ctx.findElementByLocator(host, cmd.locator, cmd.line_num) orelse {
                            writeLocatorFailure(cmd.line_num, "locator did not resolve to one element");
                            return 1;
                        };
                        if (elem.disabled != expected) {
                            writeBoolMismatch(cmd.line_num, "disabled", expected, elem.disabled);
                            return 1;
                        }
                    },

                    .expect_updates => {
                        const expected = cmd.expected_count orelse 0;
                        const elem = Ctx.findElementByLocator(host, cmd.locator, cmd.line_num) orelse {
                            writeLocatorFailure(cmd.line_num, "locator did not resolve to one element");
                            return 1;
                        };
                        const actual = elem.text_update_count + elem.value_update_count + elem.checked_update_count + elem.disabled_update_count;
                        if (actual != expected) {
                            var buf: [512]u8 = undefined;
                            const msg = std.fmt.bufPrint(&buf, "TEST FAILED at line {d}:\n  Expected updates: {d}\n  Got updates:      {d}\n", .{ cmd.line_num, expected, actual }) catch "TEST FAILED\n";
                            Ctx.writeStderr(msg);
                            return 1;
                        }
                    },

                    .expect_cleanup => {
                        const name = cmd.task_name orelse "";
                        const expected = cmd.expected_count orelse 0;
                        const actual = Ctx.cleanupEventCount(host, name);
                        if (actual != expected) {
                            var buf: [512]u8 = undefined;
                            const msg = std.fmt.bufPrint(&buf, "TEST FAILED at line {d}:\n  Expected cleanup \"{s}\": {d}\n  Got cleanup count:       {d}\n", .{ cmd.line_num, name, expected, actual }) catch "TEST FAILED\n";
                            Ctx.writeStderr(msg);
                            return 1;
                        }
                    },

                    .expect_pending_task => {
                        const name = cmd.task_name orelse "";
                        const expected = cmd.expected_count orelse 0;
                        const actual = Ctx.pendingTaskCountByName(host, name);
                        if (actual != expected) {
                            var buf: [512]u8 = undefined;
                            const msg = std.fmt.bufPrint(&buf, "TEST FAILED at line {d}:\n  Expected pending task \"{s}\": {d}\n  Got pending task count:       {d}\n", .{ cmd.line_num, name, expected, actual }) catch "TEST FAILED\n";
                            Ctx.writeStderr(msg);
                            return 1;
                        }
                    },

                    .expect_interval => {
                        const period_ms = cmd.interval_ms orelse 0;
                        const expected = cmd.expected_count orelse 0;
                        const actual = Ctx.activeIntervalRecordCountByPeriod(host, period_ms);
                        if (actual != expected) {
                            var buf: [512]u8 = undefined;
                            const msg = std.fmt.bufPrint(&buf, "TEST FAILED at line {d}:\n  Expected active interval {d}ms: {d}\n  Got active interval count:   {d}\n", .{ cmd.line_num, period_ms, expected, actual }) catch "TEST FAILED\n";
                            Ctx.writeStderr(msg);
                            return 1;
                        }
                    },

                    .expect_metric_delta => {
                        const metric_name = cmd.expected_text orelse "";
                        const expected = cmd.expected_metric_delta orelse 0;
                        const marked = metrics_mark orelse {
                            writeMetricFailure(cmd.line_num, "mark_metrics must run before expect_metric_delta");
                            return 1;
                        };
                        const start = runtimeMetricValue(marked, metric_name) orelse {
                            writeUnknownMetric(cmd.line_num, metric_name);
                            return 1;
                        };
                        const current = runtimeMetricValue(Ctx.lastRuntimeMetrics(host), metric_name) orelse {
                            writeUnknownMetric(cmd.line_num, metric_name);
                            return 1;
                        };
                        const actual = current - start;
                        if (actual != expected) {
                            writeMetricDeltaMismatch(cmd.line_num, metric_name, expected, actual);
                            return 1;
                        }
                    },

                    .expect_metric_delta_at_most => {
                        const metric_name = cmd.expected_text orelse "";
                        const expected = cmd.expected_metric_delta orelse 0;
                        const marked = metrics_mark orelse {
                            writeMetricFailure(cmd.line_num, "mark_metrics must run before expect_metric_delta_at_most");
                            return 1;
                        };
                        const start = runtimeMetricValue(marked, metric_name) orelse {
                            writeUnknownMetric(cmd.line_num, metric_name);
                            return 1;
                        };
                        const current = runtimeMetricValue(Ctx.lastRuntimeMetrics(host), metric_name) orelse {
                            writeUnknownMetric(cmd.line_num, metric_name);
                            return 1;
                        };
                        const actual = current - start;
                        if (actual > expected) {
                            writeMetricDeltaExceeded(cmd.line_num, metric_name, expected, actual);
                            return 1;
                        }
                    },
                }
            }

            if (verbose) {
                Ctx.writeStderr("[PASS] All tests passed\n");
            }

            return 0;
        }

        fn u64MetricAsI64(value: u64) i64 {
            return std.math.cast(i64, value) orelse Ctx.fail("runtime metric exceeded signed assertion range");
        }

        fn runtimeMetricValue(metrics: RuntimeMetrics, name: []const u8) ?i64 {
            if (std.mem.eql(u8, name, "active_graph_records_rebuilt")) return u64MetricAsI64(metrics.active_graph_records_rebuilt);
            if (std.mem.eql(u8, name, "active_intervals_synced")) return u64MetricAsI64(metrics.active_intervals_synced);
            if (std.mem.eql(u8, name, "reset_dom")) return u64MetricAsI64(metrics.reset_dom);
            if (std.mem.eql(u8, name, "create_element")) return u64MetricAsI64(metrics.create_element);
            if (std.mem.eql(u8, name, "append_child")) return u64MetricAsI64(metrics.append_child);
            if (std.mem.eql(u8, name, "remove_node")) return u64MetricAsI64(metrics.remove_node);
            if (std.mem.eql(u8, name, "move_before")) return u64MetricAsI64(metrics.move_before);
            if (std.mem.eql(u8, name, "set_text")) return u64MetricAsI64(metrics.set_text);
            if (std.mem.eql(u8, name, "set_value")) return u64MetricAsI64(metrics.set_value);
            if (std.mem.eql(u8, name, "set_checked")) return u64MetricAsI64(metrics.set_checked);
            if (std.mem.eql(u8, name, "set_disabled")) return u64MetricAsI64(metrics.set_disabled);
            if (std.mem.eql(u8, name, "set_metadata")) return u64MetricAsI64(metrics.set_metadata);
            if (std.mem.eql(u8, name, "bind_event")) return u64MetricAsI64(metrics.bind_event);
            if (std.mem.eql(u8, name, "allocs_this_event")) return u64MetricAsI64(metrics.allocs_this_event);
            if (std.mem.eql(u8, name, "deallocs_this_event")) return u64MetricAsI64(metrics.deallocs_this_event);
            if (std.mem.eql(u8, name, "host_allocs_this_event")) return u64MetricAsI64(metrics.host_allocs_this_event);
            if (std.mem.eql(u8, name, "host_deallocs_this_event")) return u64MetricAsI64(metrics.host_deallocs_this_event);
            if (std.mem.eql(u8, name, "host_alloc_bytes_this_event")) return u64MetricAsI64(metrics.host_alloc_bytes_this_event);
            if (std.mem.eql(u8, name, "host_dealloc_bytes_this_event")) return u64MetricAsI64(metrics.host_dealloc_bytes_this_event);
            if (std.mem.eql(u8, name, "events_processed")) return u64MetricAsI64(metrics.events_processed);
            if (std.mem.eql(u8, name, "nodes_recomputed")) return u64MetricAsI64(metrics.nodes_recomputed);
            if (std.mem.eql(u8, name, "propagation_prunes")) return u64MetricAsI64(metrics.propagation_prunes);
            if (std.mem.eql(u8, name, "derived_calls_into_roc")) return u64MetricAsI64(metrics.derived_calls_into_roc);
            if (std.mem.eql(u8, name, "each_key_compares")) return u64MetricAsI64(metrics.each_key_compares);
            if (std.mem.eql(u8, name, "each_key_hashes")) return u64MetricAsI64(metrics.each_key_hashes);
            if (std.mem.eql(u8, name, "each_key_reuse_compares")) return u64MetricAsI64(metrics.each_key_reuse_compares);
            if (std.mem.eql(u8, name, "each_key_duplicate_compares")) return u64MetricAsI64(metrics.each_key_duplicate_compares);
            if (std.mem.eql(u8, name, "each_item_compares")) return u64MetricAsI64(metrics.each_item_compares);
            if (std.mem.eql(u8, name, "each_syncs")) return u64MetricAsI64(metrics.each_syncs);
            if (std.mem.eql(u8, name, "each_sync_keys")) return u64MetricAsI64(metrics.each_sync_keys);
            if (std.mem.eql(u8, name, "each_sync_existing_rows")) return u64MetricAsI64(metrics.each_sync_existing_rows);
            if (std.mem.eql(u8, name, "recompute_batches")) return u64MetricAsI64(metrics.recompute_batches);
            if (std.mem.eql(u8, name, "patches_emitted")) return u64MetricAsI64(metrics.patches_emitted);
            if (std.mem.eql(u8, name, "scopes_created")) return u64MetricAsI64(metrics.scopes_created);
            if (std.mem.eql(u8, name, "scopes_disposed")) return u64MetricAsI64(metrics.scopes_disposed);
            if (std.mem.eql(u8, name, "rows_reused")) return u64MetricAsI64(metrics.rows_reused);
            if (std.mem.eql(u8, name, "rows_created")) return u64MetricAsI64(metrics.rows_created);
            if (std.mem.eql(u8, name, "rows_removed")) return u64MetricAsI64(metrics.rows_removed);
            if (std.mem.eql(u8, name, "closure_retains")) return u64MetricAsI64(metrics.closure_retains);
            if (std.mem.eql(u8, name, "closure_releases")) return u64MetricAsI64(metrics.closure_releases);
            if (std.mem.eql(u8, name, "render_indexes_refreshed")) return u64MetricAsI64(metrics.render_indexes_refreshed);
            if (std.mem.eql(u8, name, "signal_record_table_rebuilt")) return u64MetricAsI64(metrics.signal_record_table_rebuilt);
            if (std.mem.eql(u8, name, "stream_nodes_scanned")) return u64MetricAsI64(metrics.stream_nodes_scanned);
            if (std.mem.eql(u8, name, "stream_nodes_scanned_apply")) return u64MetricAsI64(metrics.stream_nodes_scanned_apply);
            if (std.mem.eql(u8, name, "stream_nodes_scanned_children")) return u64MetricAsI64(metrics.stream_nodes_scanned_children);
            if (std.mem.eql(u8, name, "stream_nodes_scanned_dirty_scope")) return u64MetricAsI64(metrics.stream_nodes_scanned_dirty_scope);
            if (std.mem.eql(u8, name, "stream_nodes_scanned_events")) return u64MetricAsI64(metrics.stream_nodes_scanned_events);
            if (std.mem.eql(u8, name, "stream_nodes_scanned_mounts")) return u64MetricAsI64(metrics.stream_nodes_scanned_mounts);
            if (std.mem.eql(u8, name, "stream_nodes_scanned_remove_target")) return u64MetricAsI64(metrics.stream_nodes_scanned_remove_target);
            if (std.mem.eql(u8, name, "stream_nodes_scanned_render_scope")) return u64MetricAsI64(metrics.stream_nodes_scanned_render_scope);
            if (std.mem.eql(u8, name, "stream_nodes_scanned_splice")) return u64MetricAsI64(metrics.stream_nodes_scanned_splice);
            if (std.mem.eql(u8, name, "retained_alloc_delta")) return metrics.retained_alloc_delta;
            if (std.mem.eql(u8, name, "host_retained_alloc_delta")) return metrics.host_retained_alloc_delta;
            if (std.mem.eql(u8, name, "host_retained_bytes_delta")) return metrics.host_retained_bytes_delta;
            return null;
        }

        fn encodeKeyShiftPayload(allocator: std.mem.Allocator, key: []const u8, shift_key: bool) []u8 {
            const bytes = allocator.alloc(u8, @sizeOf(u32) + key.len + 1) catch std.process.exit(1);
            std.mem.writeInt(u32, bytes[0..@sizeOf(u32)], @intCast(key.len), .little);
            @memcpy(bytes[@sizeOf(u32)..][0..key.len], key);
            bytes[@sizeOf(u32) + key.len] = if (shift_key) 1 else 0;
            return bytes;
        }

        fn pointerEventIdForCommand(elem: anytype, cmd_type: SpecCommandType) ?u64 {
            return switch (cmd_type) {
                .pointer_down => Ctx.fixedEventId(elem, .pointer_down),
                .pointer_up => Ctx.fixedEventId(elem, .pointer_up),
                .pointer_enter => Ctx.fixedEventId(elem, .pointer_enter),
                .pointer_leave => Ctx.fixedEventId(elem, .pointer_leave),
                else => null,
            };
        }

        fn pointerEventNameForCommand(cmd_type: SpecCommandType) ?[]const u8 {
            return switch (cmd_type) {
                .pointer_down => "pointerdown",
                .pointer_up => "pointerup",
                .pointer_enter => "pointerenter",
                .pointer_leave => "pointerleave",
                else => null,
            };
        }

        fn namedUnitEventNameForCommand(cmd_type: SpecCommandType) ?[]const u8 {
            return switch (cmd_type) {
                .focus => "focus",
                .blur => "blur",
                .composition_start => "compositionstart",
                .composition_end => "compositionend",
                else => null,
            };
        }

        fn writeLocatorFailure(line_num: usize, message: []const u8) void {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "TEST FAILED at line {d}: {s}\n", .{ line_num, message }) catch "TEST FAILED\n";
            Ctx.writeStderr(msg);
        }

        fn writeAbsentFailure(line_num: usize, match_count: usize) void {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "TEST FAILED at line {d}: expected no matching elements, found {d}\n", .{ line_num, match_count }) catch "TEST FAILED\n";
            Ctx.writeStderr(msg);
        }

        fn writeStringMismatch(line_num: usize, field: []const u8, expected: []const u8, actual: []const u8) void {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "TEST FAILED at line {d}:\n  Expected {s}: \"{s}\"\n  Got {s}:      \"{s}\"\n", .{ line_num, field, expected, field, actual }) catch "TEST FAILED\n";
            Ctx.writeStderr(msg);
        }

        fn writeUnexpectedAttr(line_num: usize, field: []const u8) void {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "TEST FAILED at line {d}: expected attr \"{s}\" to be absent\n", .{ line_num, field }) catch "TEST FAILED\n";
            Ctx.writeStderr(msg);
        }

        fn writeMissingAttr(line_num: usize, field: []const u8) void {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "TEST FAILED at line {d}: expected attr \"{s}\" to be present\n", .{ line_num, field }) catch "TEST FAILED\n";
            Ctx.writeStderr(msg);
        }

        fn writeBoolMismatch(line_num: usize, field: []const u8, expected: bool, actual: bool) void {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "TEST FAILED at line {d}:\n  Expected {s}: {}\n  Got {s}:      {}\n", .{ line_num, field, expected, field, actual }) catch "TEST FAILED\n";
            Ctx.writeStderr(msg);
        }

        fn writeMetricFailure(line_num: usize, message: []const u8) void {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "TEST FAILED at line {d}: {s}\n", .{ line_num, message }) catch "TEST FAILED\n";
            Ctx.writeStderr(msg);
        }

        fn writeUnknownMetric(line_num: usize, metric_name: []const u8) void {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "TEST FAILED at line {d}: unknown metric \"{s}\"\n", .{ line_num, metric_name }) catch "TEST FAILED\n";
            Ctx.writeStderr(msg);
        }

        fn writeMetricDeltaMismatch(line_num: usize, metric_name: []const u8, expected: i64, actual: i64) void {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "TEST FAILED at line {d}:\n  Expected {s} delta: {d}\n  Got {s} delta:      {d}\n", .{ line_num, metric_name, expected, metric_name, actual }) catch "TEST FAILED\n";
            Ctx.writeStderr(msg);
        }

        fn writeMetricDeltaExceeded(line_num: usize, metric_name: []const u8, expected: i64, actual: i64) void {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "TEST FAILED at line {d}:\n  Expected {s} delta at most: {d}\n  Got {s} delta:             {d}\n", .{ line_num, metric_name, expected, metric_name, actual }) catch "TEST FAILED\n";
            Ctx.writeStderr(msg);
        }
    };
}

test "spec runner real_click dispatch honors capture bubble and stop policies" {
    const sim_dom = @import("../sim_dom.zig");

    const TestHost = struct {
        allocator: std.mem.Allocator,
        elements: std.ArrayListUnmanaged(sim_dom.Element) = .empty,
        dispatches: std.ArrayListUnmanaged(u64) = .empty,

        fn init(allocator: std.mem.Allocator) @This() {
            return .{ .allocator = allocator };
        }

        fn deinit(self: *@This()) void {
            for (self.elements.items) |*elem| {
                elem.deinit(self.allocator);
            }
            self.elements.deinit(self.allocator);
            self.dispatches.deinit(self.allocator);
        }

        fn appendDispatch(self: *@This(), event_id: u64) void {
            self.dispatches.append(self.allocator, event_id) catch @panic("test dispatch log allocation failed");
        }
    };

    const TestCtx = struct {
        pub const Host = TestHost;
        pub const RocHost = void;

        pub fn writeStderr(_: []const u8) void {}

        pub fn elementById(host: *Host, elem_id: u64) ?*sim_dom.Element {
            if (elem_id >= host.elements.items.len) return null;
            const elem = &host.elements.items[@intCast(elem_id)];
            if (!elem.active) return null;
            return elem;
        }

        pub fn fixedEventId(elem: *const sim_dom.Element, kind: render.EventKind) ?u64 {
            return sim_dom.fixedEventId(elem, kind);
        }

        pub fn namedEvent(elem: *const sim_dom.Element, name: []const u8) ?sim_dom.NamedEvent {
            return sim_dom.namedEvent(elem, name);
        }

        pub fn dispatchRocEvent(host: *Host, _: *RocHost, event_id: u64, payload_descriptor: BoundaryPayloadDescriptor, _: void) void {
            if (!payload_descriptor.eql(BoundaryPayloadDescriptor.init(.unit, .none))) {
                @panic("test expected a unit payload descriptor");
            }
            host.appendDispatch(event_id);
        }

        pub fn hostValueUnit(_: *Host, _: *RocHost) void {}
    };

    const allocator = std.testing.allocator;
    var host = TestHost.init(allocator);
    defer host.deinit();
    var roc_host: void = {};

    sim_dom.reset(allocator, &host.elements);
    sim_dom.appendDetached(allocator, &host.elements, 1, "section");
    sim_dom.appendDetached(allocator, &host.elements, 2, "button");
    sim_dom.appendChild(allocator, &host.elements.items[0], &host.elements.items[1]);
    sim_dom.appendChild(allocator, &host.elements.items[1], &host.elements.items[2]);

    const unit_descriptor = BoundaryPayloadDescriptor.init(.unit, .none);
    sim_dom.bindEventName(allocator, &host.elements.items[0], "click", 5, render.EventPolicy.fromBits(render.listener_option_capture | render.listener_option_trusted), unit_descriptor);
    sim_dom.bindEventName(allocator, &host.elements.items[1], "click", 10, render.EventPolicy.none, unit_descriptor);
    sim_dom.bindEventName(allocator, &host.elements.items[2], "click", 20, render.EventPolicy.none, unit_descriptor);

    try std.testing.expect(dispatchBubblingUnitEventById(TestCtx, &host, &roc_host, 2, .click, "click", 99));
    try std.testing.expectEqualSlices(u64, &.{ 5, 20, 10 }, host.dispatches.items);

    host.dispatches.clearRetainingCapacity();
    sim_dom.bindEventKind(&host.elements.items[2], .click, .{
        .event_id = 15,
        .payload_descriptor = unit_descriptor,
    });
    sim_dom.bindEventName(allocator, &host.elements.items[2], "click", 20, render.EventPolicy.fromBits(render.listener_option_stop_propagation), unit_descriptor);
    try std.testing.expect(dispatchBubblingUnitEventById(TestCtx, &host, &roc_host, 2, .click, "click", 99));
    try std.testing.expectEqualSlices(u64, &.{ 5, 15, 20 }, host.dispatches.items);
    sim_dom.clearEventKind(&host.elements.items[2], .click);

    host.dispatches.clearRetainingCapacity();
    sim_dom.bindEventName(allocator, &host.elements.items[2], "click", 20, render.EventPolicy.fromBits(render.listener_option_stop_propagation), unit_descriptor);
    try std.testing.expect(dispatchBubblingUnitEventById(TestCtx, &host, &roc_host, 2, .click, "click", 99));
    try std.testing.expectEqualSlices(u64, &.{ 5, 20 }, host.dispatches.items);

    host.dispatches.clearRetainingCapacity();
    sim_dom.bindEventName(allocator, &host.elements.items[2], "click", 20, render.EventPolicy.fromBits(render.listener_option_stop_immediate), unit_descriptor);
    try std.testing.expect(dispatchBubblingUnitEventById(TestCtx, &host, &roc_host, 2, .click, "click", 99));
    try std.testing.expectEqualSlices(u64, &.{ 5, 20 }, host.dispatches.items);

    host.dispatches.clearRetainingCapacity();
    const capture_stop = render.EventPolicy.fromBits(render.listener_option_capture | render.listener_option_stop_propagation);
    sim_dom.bindEventName(allocator, &host.elements.items[0], "click", 5, capture_stop, unit_descriptor);
    sim_dom.bindEventName(allocator, &host.elements.items[2], "click", 20, render.EventPolicy.none, unit_descriptor);
    try std.testing.expect(dispatchBubblingUnitEventById(TestCtx, &host, &roc_host, 2, .click, "click", 99));
    try std.testing.expectEqualSlices(u64, &.{5}, host.dispatches.items);

    host.dispatches.clearRetainingCapacity();
    sim_dom.bindEventName(allocator, &host.elements.items[0], "click", 5, render.EventPolicy.fromBits(render.listener_option_capture | render.listener_option_self), unit_descriptor);
    sim_dom.bindEventName(allocator, &host.elements.items[1], "click", 10, render.EventPolicy.fromBits(render.listener_option_self), unit_descriptor);
    sim_dom.bindEventName(allocator, &host.elements.items[2], "click", 20, render.EventPolicy.none, unit_descriptor);
    try std.testing.expect(dispatchBubblingUnitEventById(TestCtx, &host, &roc_host, 2, .click, "click", 99));
    try std.testing.expectEqualSlices(u64, &.{20}, host.dispatches.items);
}

test "spec runner submit dispatches enabled unit bindings" {
    const sim_dom = @import("../sim_dom.zig");

    const TestHost = struct {
        allocator: std.mem.Allocator,
        elements: std.ArrayListUnmanaged(sim_dom.Element) = .empty,
        dispatches: std.ArrayListUnmanaged(u64) = .empty,

        fn init(allocator: std.mem.Allocator) @This() {
            return .{ .allocator = allocator };
        }

        fn deinit(self: *@This()) void {
            for (self.elements.items) |*elem| {
                elem.deinit(self.allocator);
            }
            self.elements.deinit(self.allocator);
            self.dispatches.deinit(self.allocator);
        }

        fn appendDispatch(self: *@This(), event_id: u64) void {
            self.dispatches.append(self.allocator, event_id) catch @panic("test dispatch log allocation failed");
        }
    };

    const TestCtx = struct {
        pub const Host = TestHost;
        pub const RocHost = void;

        pub fn writeStderr(_: []const u8) void {}

        pub fn namedEvent(elem: *const sim_dom.Element, name: []const u8) ?sim_dom.NamedEvent {
            return sim_dom.namedEvent(elem, name);
        }

        pub fn dispatchRocEvent(host: *Host, _: *RocHost, event_id: u64, payload_descriptor: BoundaryPayloadDescriptor, _: void) void {
            if (!payload_descriptor.eql(BoundaryPayloadDescriptor.init(.unit, .none))) {
                @panic("test expected a unit payload descriptor");
            }
            host.appendDispatch(event_id);
        }

        pub fn hostValueUnit(_: *Host, _: *RocHost) void {}
    };

    const allocator = std.testing.allocator;
    var host = TestHost.init(allocator);
    defer host.deinit();
    var roc_host: void = {};

    sim_dom.reset(allocator, &host.elements);
    sim_dom.appendDetached(allocator, &host.elements, 1, "form");
    sim_dom.appendChild(allocator, &host.elements.items[0], &host.elements.items[1]);

    const unit_descriptor = BoundaryPayloadDescriptor.init(.unit, .none);
    sim_dom.bindEventName(allocator, &host.elements.items[1], "submit", 30, render.EventPolicy.none, unit_descriptor);
    try std.testing.expect(dispatchSubmitEvent(TestCtx, &host, &roc_host, &host.elements.items[1], 120));
    try std.testing.expectEqualSlices(u64, &.{30}, host.dispatches.items);

    host.dispatches.clearRetainingCapacity();
    sim_dom.bindEventName(allocator, &host.elements.items[1], "submit", 31, render.EventPolicy.none, BoundaryPayloadDescriptor.init(.str, .target_value));
    try std.testing.expect(!dispatchSubmitEvent(TestCtx, &host, &roc_host, &host.elements.items[1], 121));
    try std.testing.expectEqual(@as(usize, 0), host.dispatches.items.len);

    sim_dom.bindEventName(allocator, &host.elements.items[1], "submit", 32, render.EventPolicy.none, unit_descriptor);
    sim_dom.setDisabled(&host.elements.items[1], true);
    try std.testing.expect(!dispatchSubmitEvent(TestCtx, &host, &roc_host, &host.elements.items[1], 122));
    try std.testing.expectEqual(@as(usize, 0), host.dispatches.items.len);
}

test "spec runner resolves runtime metric names" {
    const TestCtx = struct {
        pub const Host = void;
        pub const RocHost = void;

        pub fn fail(_: []const u8) noreturn {
            unreachable;
        }

        pub fn writeStderr(_: []const u8) void {}
    };
    const TestRunner = Runner(TestCtx);
    var metrics = engine.zeroRuntimeMetrics();
    metrics.rows_reused = 7;
    metrics.retained_alloc_delta = -2;

    try std.testing.expectEqual(@as(?i64, 7), TestRunner.runtimeMetricValue(metrics, "rows_reused"));
    try std.testing.expectEqual(@as(?i64, -2), TestRunner.runtimeMetricValue(metrics, "retained_alloc_delta"));
    try std.testing.expectEqual(@as(?i64, null), TestRunner.runtimeMetricValue(metrics, "missing_metric"));
}
