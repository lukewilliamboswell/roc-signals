//! Native spec runner that dispatches parsed UI commands against the simulated DOM.

const std = @import("std");

const signals = @import("signals");
const boundary = signals.boundary;
const engine = signals.engine;
const render = signals.render;
const runtime_limits = signals.runtime_limits;
const spec_parser = @import("spec_parser.zig");

const BoundaryPayloadDescriptor = boundary.BoundaryPayloadDescriptor;
const RuntimeMetrics = engine.RuntimeMetrics;
const SpecCommand = spec_parser.SpecCommand;
const SpecCommandType = spec_parser.SpecCommandType;

fn storageValueForCtx(comptime Ctx: type, host: *Ctx.Host, area: boundary.StorageArea, key: []const u8) ?[]const u8 {
    if (comptime @hasDecl(Ctx, "storageValue")) {
        return Ctx.storageValue(host, area, key);
    }
    return null;
}

fn documentTitleForCtx(comptime Ctx: type, host: *Ctx.Host) []const u8 {
    if (comptime @hasDecl(Ctx, "documentTitle")) {
        return Ctx.documentTitle(host);
    }
    return "";
}

fn writeLocatorFailureForCtx(comptime Ctx: type, line_num: usize, message: []const u8) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "TEST FAILED at line {d}: {s}\n", .{ line_num, message }) catch "TEST FAILED\n";
    Ctx.writeStderr(msg);
}

/// Locator-aware "not found" message.
///
/// A `text:` locator matches on rendered content, so when the value changes the
/// element stops resolving and the failure reads as "missing element" rather
/// than "wrong value". That has repeatedly been misread as "the text never
/// rendered", so say what actually happened and point at the fix.
fn writeLocatorMiss(comptime Ctx: type, line_num: usize, locator: spec_parser.Locator) void {
    var buf: [512]u8 = undefined;
    const msg = switch (locator.kind) {
        .text => std.fmt.bufPrint(
            &buf,
            "TEST FAILED at line {d}: no element has text \"{s}\"\n" ++
                "  A text: locator matches on content, so a changed value looks like a\n" ++
                "  missing element. Give the element a test_id and assert its value:\n" ++
                "    expect_text test_id:\"...\" \"{s}\"\n" ++
                "  To see what did render, assert a wrong value on the container:\n" ++
                "    expect_text role:region name:\"...\" \"PROBE\"\n",
            .{ line_num, locator.text orelse "", locator.text orelse "" },
        ) catch "TEST FAILED\n",
        else => std.fmt.bufPrint(
            &buf,
            "TEST FAILED at line {d}: locator did not resolve to one element\n",
            .{line_num},
        ) catch "TEST FAILED\n",
    };
    Ctx.writeStderr(msg);
}

const UnitEventDispatchResult = struct {
    ok: bool,
    default_prevented: bool = false,
    dispatched: bool = false,

    pub const failed: UnitEventDispatchResult = .{ .ok = false };
};

fn dispatchBubblingUnitEventById(comptime Ctx: type, host: *Ctx.Host, roc_host: *Ctx.RocHost, target_id: u64, fixed_kind: render.EventKind, event_name: []const u8, line_num: usize) UnitEventDispatchResult {
    var result = UnitEventDispatchResult{ .ok = true };
    var path: [runtime_limits.event_propagation_depth]u64 = undefined;
    var path_len: usize = 0;
    var next_id: ?u64 = target_id;
    while (next_id) |elem_id| {
        if (path_len >= path.len) {
            writeLocatorFailureForCtx(Ctx, line_num, "event propagation path exceeded native spec runner limit");
            return .failed;
        }
        const elem = Ctx.elementById(host, elem_id) orelse {
            writeLocatorFailureForCtx(Ctx, line_num, "event propagation path referenced a missing element");
            return .failed;
        };
        path[path_len] = elem.id;
        path_len += 1;
        next_id = elem.parent_id;
    }

    var capture_index = path_len;
    while (capture_index > 0) {
        capture_index -= 1;
        const elem_id = path[capture_index];
        const elem = Ctx.elementById(host, elem_id) orelse {
            writeLocatorFailureForCtx(Ctx, line_num, "event target was removed before dispatch completed");
            return .failed;
        };
        const event = Ctx.namedEvent(elem, event_name) orelse continue;
        if (!event.binding.policy.capture) continue;
        if (!eventPolicyMatchesSpecEvent(event.binding.policy, elem_id, target_id)) continue;
        if (!event.binding.payload_descriptor.eql(BoundaryPayloadDescriptor.init(.unit, .none))) {
            writeLocatorFailureForCtx(Ctx, line_num, "capturing event binding does not use a unit payload descriptor");
            return .failed;
        }
        result.dispatched = true;
        result.default_prevented = result.default_prevented or event.binding.policy.prevent_default;
        Ctx.dispatchRocEvent(host, roc_host, event.binding.event_id, event.binding.payload_descriptor, Ctx.hostValueUnit(host, roc_host));
        if (event.binding.policy.stop_propagation or event.binding.policy.stop_immediate) return result;
    }

    for (path[0..path_len]) |elem_id| {
        const elem = Ctx.elementById(host, elem_id) orelse {
            writeLocatorFailureForCtx(Ctx, line_num, "event target was removed before dispatch completed");
            return .failed;
        };

        if (Ctx.fixedEventId(elem, fixed_kind)) |event_id| {
            result.dispatched = true;
            Ctx.dispatchRocEvent(host, roc_host, event_id, BoundaryPayloadDescriptor.init(.unit, .none), Ctx.hostValueUnit(host, roc_host));
        }

        const event = Ctx.namedEvent(elem, event_name) orelse continue;
        if (event.binding.policy.capture) continue;
        if (!eventPolicyMatchesSpecEvent(event.binding.policy, elem_id, target_id)) continue;
        if (!event.binding.payload_descriptor.eql(BoundaryPayloadDescriptor.init(.unit, .none))) {
            writeLocatorFailureForCtx(Ctx, line_num, "bubbling event binding does not use a unit payload descriptor");
            return .failed;
        }
        result.dispatched = true;
        result.default_prevented = result.default_prevented or event.binding.policy.prevent_default;
        Ctx.dispatchRocEvent(host, roc_host, event.binding.event_id, event.binding.payload_descriptor, Ctx.hostValueUnit(host, roc_host));
        if (event.binding.policy.stop_propagation or event.binding.policy.stop_immediate) break;
    }

    return result;
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
    if (!event.binding.policy.prevent_default) {
        writeLocatorFailureForCtx(Ctx, line_num, "submit binding does not request prevent-default policy");
        return false;
    }
    Ctx.dispatchRocEvent(host, roc_host, event.binding.event_id, event.binding.payload_descriptor, Ctx.hostValueUnit(host, roc_host));
    return true;
}

fn dispatchResetEvent(comptime Ctx: type, host: *Ctx.Host, roc_host: *Ctx.RocHost, elem: anytype, line_num: usize) bool {
    if (elem.disabled) {
        writeLocatorFailureForCtx(Ctx, line_num, "target is disabled");
        return false;
    }
    const event = Ctx.namedEvent(elem, "reset") orelse {
        writeLocatorFailureForCtx(Ctx, line_num, "target has no reset binding");
        return false;
    };
    if (!event.binding.payload_descriptor.eql(BoundaryPayloadDescriptor.init(.unit, .none))) {
        writeLocatorFailureForCtx(Ctx, line_num, "reset binding does not use a unit payload descriptor");
        return false;
    }
    if (!event.binding.policy.prevent_default) {
        writeLocatorFailureForCtx(Ctx, line_num, "reset binding does not request prevent-default policy");
        return false;
    }
    Ctx.dispatchRocEvent(host, roc_host, event.binding.event_id, event.binding.payload_descriptor, Ctx.hostValueUnit(host, roc_host));
    return true;
}

fn isSubmitButton(comptime Ctx: type, elem: anytype) bool {
    if (!std.mem.eql(u8, elem.tag, "button")) return false;
    const button_type = Ctx.elementTextAttr(elem, "type") orelse return true;
    return !std.ascii.eqlIgnoreCase(button_type, "button") and
        !std.ascii.eqlIgnoreCase(button_type, "reset");
}

fn isResetButton(comptime Ctx: type, elem: anytype) bool {
    if (!std.mem.eql(u8, elem.tag, "button")) return false;
    const button_type = Ctx.elementTextAttr(elem, "type") orelse return false;
    return std.ascii.eqlIgnoreCase(button_type, "reset");
}

fn isCheckboxControl(comptime Ctx: type, elem: anytype) bool {
    if (!std.mem.eql(u8, elem.tag, "input")) return false;
    if (elem.role) |role| {
        if (std.mem.eql(u8, role, "checkbox")) return true;
    }
    const input_type = Ctx.elementTextAttr(elem, "type") orelse return false;
    return std.ascii.eqlIgnoreCase(input_type, "checkbox");
}

fn isRadioControl(comptime Ctx: type, elem: anytype) bool {
    if (!std.mem.eql(u8, elem.tag, "input")) return false;
    if (elem.role) |role| {
        if (std.mem.eql(u8, role, "radio")) return true;
    }
    const input_type = Ctx.elementTextAttr(elem, "type") orelse return false;
    return std.ascii.eqlIgnoreCase(input_type, "radio");
}

fn hasRealClickDefaultAction(comptime Ctx: type, elem: anytype) bool {
    return isSubmitButton(Ctx, elem) or isResetButton(Ctx, elem) or isCheckboxControl(Ctx, elem) or isRadioControl(Ctx, elem);
}

fn dispatchCheckedChangeEvent(comptime Ctx: type, host: *Ctx.Host, roc_host: *Ctx.RocHost, elem: anytype, checked: bool, line_num: usize) bool {
    if (Ctx.fixedEventId(elem, .check)) |event_id| {
        Ctx.dispatchRocEvent(host, roc_host, event_id, BoundaryPayloadDescriptor.init(.bool, .target_checked), Ctx.hostValueBool(host, roc_host, checked));
    } else if (Ctx.namedEvent(elem, "change")) |event| {
        if (!event.binding.payload_descriptor.eql(BoundaryPayloadDescriptor.init(.bool, .target_checked))) {
            writeLocatorFailureForCtx(Ctx, line_num, "checkbox change binding does not request the target checked payload descriptor");
            return false;
        }
        Ctx.dispatchRocEvent(host, roc_host, event.binding.event_id, event.binding.payload_descriptor, Ctx.hostValueBool(host, roc_host, checked));
    } else {
        _ = Ctx.setElementCheckedIfChanged(elem, checked);
    }
    return true;
}

fn dispatchRadioChangeEvent(comptime Ctx: type, host: *Ctx.Host, roc_host: *Ctx.RocHost, elem: anytype, line_num: usize) bool {
    if (!Ctx.setElementCheckedIfChanged(elem, true)) return true;

    const event = Ctx.namedEvent(elem, "change") orelse return true;
    if (!event.binding.payload_descriptor.eql(BoundaryPayloadDescriptor.init(.str, .target_value))) {
        writeLocatorFailureForCtx(Ctx, line_num, "radio change binding does not request the target value payload descriptor");
        return false;
    }
    const value = elem.value orelse {
        writeLocatorFailureForCtx(Ctx, line_num, "radio default action target has no value");
        return false;
    };
    Ctx.dispatchRocEvent(host, roc_host, event.binding.event_id, event.binding.payload_descriptor, Ctx.hostValueStr(host, roc_host, value));
    return true;
}

fn selectHasOptionValue(comptime Ctx: type, host: *Ctx.Host, elem: anytype, value: []const u8, line_num: usize) bool {
    for (elem.children.items) |child_id| {
        const child = Ctx.elementById(host, child_id) orelse {
            writeLocatorFailureForCtx(Ctx, line_num, "select option child was removed");
            return false;
        };
        if (!std.mem.eql(u8, child.tag, "option")) continue;
        const option_value = Ctx.elementTextAttr(child, "value") orelse continue;
        if (std.mem.eql(u8, option_value, value)) return true;
    }
    return false;
}

fn dispatchSelectOptionEvent(comptime Ctx: type, host: *Ctx.Host, roc_host: *Ctx.RocHost, elem: anytype, value: []const u8, line_num: usize) bool {
    if (!std.mem.eql(u8, elem.tag, "select")) {
        writeLocatorFailureForCtx(Ctx, line_num, "select_option target is not a select control");
        return false;
    }
    if (!selectHasOptionValue(Ctx, host, elem, value, line_num)) {
        writeLocatorFailureForCtx(Ctx, line_num, "select_option value does not match a rendered option");
        return false;
    }
    if (!Ctx.setElementValueIfChanged(host, elem, value)) return true;

    const event = Ctx.namedEvent(elem, "change") orelse return true;
    if (!event.binding.payload_descriptor.eql(BoundaryPayloadDescriptor.init(.str, .target_value))) {
        writeLocatorFailureForCtx(Ctx, line_num, "select change binding does not request the target value payload descriptor");
        return false;
    }
    Ctx.dispatchRocEvent(host, roc_host, event.binding.event_id, event.binding.payload_descriptor, Ctx.hostValueStr(host, roc_host, value));
    return true;
}

fn isTextLikeEnterSubmitControl(comptime Ctx: type, elem: anytype) bool {
    if (!std.mem.eql(u8, elem.tag, "input")) return false;
    const input_type = Ctx.elementTextAttr(elem, "type") orelse return true;
    const non_submit_types = [_][]const u8{
        "button",
        "checkbox",
        "color",
        "file",
        "hidden",
        "image",
        "radio",
        "range",
        "reset",
        "submit",
    };
    for (non_submit_types) |kind| {
        if (std.ascii.eqlIgnoreCase(input_type, kind)) return false;
    }
    return true;
}

fn dispatchEnterKeyDefaultAction(comptime Ctx: type, host: *Ctx.Host, roc_host: *Ctx.RocHost, target_id: u64, default_prevented: bool, line_num: usize) bool {
    if (default_prevented) return true;

    const target = Ctx.elementById(host, target_id) orelse {
        writeLocatorFailureForCtx(Ctx, line_num, "Enter key default action target was removed");
        return false;
    };
    if (!isTextLikeEnterSubmitControl(Ctx, target)) return true;

    var next_id = target.parent_id;
    while (next_id) |elem_id| {
        const elem = Ctx.elementById(host, elem_id) orelse {
            writeLocatorFailureForCtx(Ctx, line_num, "Enter key submit default referenced a missing ancestor");
            return false;
        };
        if (std.mem.eql(u8, elem.tag, "form")) {
            return dispatchSubmitEvent(Ctx, host, roc_host, elem, line_num);
        }
        next_id = elem.parent_id;
    }

    return true;
}

fn dispatchRealClickDefaultAction(comptime Ctx: type, host: *Ctx.Host, roc_host: *Ctx.RocHost, target_id: u64, click_result: UnitEventDispatchResult, line_num: usize) bool {
    if (click_result.default_prevented) return true;

    const target = Ctx.elementById(host, target_id) orelse {
        writeLocatorFailureForCtx(Ctx, line_num, "real_click default action target was removed");
        return false;
    };
    if (isCheckboxControl(Ctx, target)) {
        return dispatchCheckedChangeEvent(Ctx, host, roc_host, target, !target.checked, line_num);
    }
    if (isRadioControl(Ctx, target)) {
        return dispatchRadioChangeEvent(Ctx, host, roc_host, target, line_num);
    }
    if (isResetButton(Ctx, target)) {
        var next_id = target.parent_id;
        while (next_id) |elem_id| {
            const elem = Ctx.elementById(host, elem_id) orelse {
                writeLocatorFailureForCtx(Ctx, line_num, "real_click reset default referenced a missing ancestor");
                return false;
            };
            if (std.mem.eql(u8, elem.tag, "form")) {
                return dispatchResetEvent(Ctx, host, roc_host, elem, line_num);
            }
            next_id = elem.parent_id;
        }
        return true;
    }
    if (!isSubmitButton(Ctx, target)) return true;

    var next_id = target.parent_id;
    while (next_id) |elem_id| {
        const elem = Ctx.elementById(host, elem_id) orelse {
            writeLocatorFailureForCtx(Ctx, line_num, "real_click submit default referenced a missing ancestor");
            return false;
        };
        if (std.mem.eql(u8, elem.tag, "form")) {
            return dispatchSubmitEvent(Ctx, host, roc_host, elem, line_num);
        }
        next_id = elem.parent_id;
    }

    return true;
}

/// Depth-first concatenation of an element's descendant text.
///
/// `expect_text` reads an element's own `text` field first; containers whose
/// content comes from signal-backed text children have no such field, so this
/// walks the subtree to build the rendered text instead.
fn appendDescendantText(
    comptime Ctx: type,
    host: *Ctx.Host,
    elem: anytype,
    out: *std.ArrayListUnmanaged(u8),
) void {
    if (elem.text) |own_text| {
        out.appendSlice(Ctx.allocator(host), own_text) catch @panic("descendant text allocation failed");
    }
    for (elem.children.items) |child_id| {
        const child = Ctx.elementById(host, child_id) orelse continue;
        appendDescendantText(Ctx, host, child, out);
    }
}

/// Builds the semantic spec runner for a host adapter and its observable DOM surface.
pub fn Runner(comptime Ctx: type) type {
    return struct {
        const Host = Ctx.Host;
        const RocHost = Ctx.RocHost;

        /// Runs  using the host semantics and measurement boundaries defined by this module.
        pub fn run(host: *Host, roc_host: *RocHost, commands: []const SpecCommand, verbose: bool) c_int {
            var metrics_mark: ?RuntimeMetrics = null;

            for (commands) |cmd| {
                if (verbose) {
                    var buffer: [160]u8 = undefined;
                    const message = std.fmt.bufPrint(&buffer, "[SPEC] line {d}: {s}\n", .{ cmd.line_num, @tagName(cmd.cmd_type) }) catch "[SPEC] command\n";
                    Ctx.writeStderr(message);
                }
                switch (cmd.cmd_type) {
                    .mark_metrics => {
                        // Refresh absolute retained-allocation gauges at the
                        // command boundary. Mount and dispatch can release
                        // transferred values in outer defers after their last
                        // internal metrics flush.
                        Ctx.finishHostMetrics(host);
                        metrics_mark = Ctx.lastRuntimeMetrics(host);
                    },

                    .set_initial_location, .set_initial_visibility, .set_initial_online, .seed_local_storage, .seed_session_storage => {},

                    .set_visibility => {
                        if (comptime !@hasDecl(Ctx, "setVisibility")) {
                            writeLocatorFailure(cmd.line_num, "visibility commands are not supported by this runner");
                            return 1;
                        } else {
                            const text = cmd.expected_text orelse {
                                writeLocatorFailure(cmd.line_num, "set_visibility command had no visibility text");
                                return 1;
                            };
                            const visibility = visibilitySnapshotFromSpecText(cmd.line_num, text) orelse return 1;
                            _ = Ctx.setVisibility(host, roc_host, visibility);
                            Ctx.finishHostMetrics(host);
                        }
                    },

                    .set_online => {
                        if (comptime !@hasDecl(Ctx, "setOnline")) {
                            writeLocatorFailure(cmd.line_num, "online commands are not supported by this runner");
                            return 1;
                        } else {
                            const text = cmd.expected_text orelse {
                                writeLocatorFailure(cmd.line_num, "set_online command had no online text");
                                return 1;
                            };
                            const online = onlineSnapshotFromSpecText(cmd.line_num, text) orelse return 1;
                            _ = Ctx.setOnline(host, roc_host, online);
                            Ctx.finishHostMetrics(host);
                        }
                    },

                    .navigate => {
                        const text = cmd.expected_text orelse {
                            writeLocatorFailure(cmd.line_num, "navigate command had no URL text");
                            return 1;
                        };
                        const location = locationSnapshotFromSpecText(cmd.line_num, text) orelse return 1;
                        _ = Ctx.navigateLocation(host, roc_host, location);
                        Ctx.finishHostMetrics(host);
                    },

                    .history_back => {
                        _ = Ctx.historyBack(host, roc_host);
                        Ctx.finishHostMetrics(host);
                    },

                    .history_forward => {
                        _ = Ctx.historyForward(host, roc_host);
                        Ctx.finishHostMetrics(host);
                    },

                    .expect_current_location, .assert_current_location => {
                        const text = cmd.expected_text orelse {
                            writeLocatorFailure(cmd.line_num, "current-location assertion had no URL text");
                            return 1;
                        };
                        const expected = locationSnapshotFromSpecText(cmd.line_num, text) orelse return 1;
                        const actual = Ctx.currentLocation(host);
                        if (!std.mem.eql(u8, actual.path, expected.path)) {
                            writeStringMismatch(cmd.line_num, "location.path", expected.path, actual.path);
                            return 1;
                        }
                        if (!std.mem.eql(u8, actual.query, expected.query)) {
                            writeStringMismatch(cmd.line_num, "location.query", expected.query, actual.query);
                            return 1;
                        }
                        if (!std.mem.eql(u8, actual.hash, expected.hash)) {
                            writeStringMismatch(cmd.line_num, "location.hash", expected.hash, actual.hash);
                            return 1;
                        }
                    },

                    .expect_document_title => {
                        const expected = cmd.expected_text orelse {
                            writeLocatorFailure(cmd.line_num, "document-title assertion had no text");
                            return 1;
                        };
                        const actual = documentTitleForCtx(Ctx, host);
                        if (!std.mem.eql(u8, actual, expected)) {
                            writeStringMismatch(cmd.line_num, "document title", expected, actual);
                            return 1;
                        }
                    },

                    .expect_local_storage, .expect_session_storage => {
                        const key = cmd.task_name orelse {
                            writeLocatorFailure(cmd.line_num, "storage assertion had no key text");
                            return 1;
                        };
                        const expected = cmd.expected_text orelse {
                            writeLocatorFailure(cmd.line_num, "storage assertion had no value text");
                            return 1;
                        };
                        const area: boundary.StorageArea = switch (cmd.cmd_type) {
                            .expect_local_storage => .local,
                            .expect_session_storage => .session,
                            else => unreachable,
                        };
                        const actual = storageValueForCtx(Ctx, host, area, key) orelse {
                            writeLocatorFailure(cmd.line_num, "storage key was missing");
                            return 1;
                        };
                        if (!std.mem.eql(u8, actual, expected)) {
                            writeStringMismatch(cmd.line_num, "storage value", expected, actual);
                            return 1;
                        }
                    },

                    .expect_no_local_storage, .expect_no_session_storage => {
                        const key = cmd.task_name orelse {
                            writeLocatorFailure(cmd.line_num, "storage absence assertion had no key text");
                            return 1;
                        };
                        const area: boundary.StorageArea = switch (cmd.cmd_type) {
                            .expect_no_local_storage => .local,
                            .expect_no_session_storage => .session,
                            else => unreachable,
                        };
                        if (storageValueForCtx(Ctx, host, area, key)) |_| {
                            writeLocatorFailure(cmd.line_num, "storage key was present");
                            return 1;
                        }
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
                        if (!dispatchBubblingUnitEventById(Ctx, host, roc_host, target_id, .pointer_down, "pointerdown", cmd.line_num).ok) return 1;
                        if (!dispatchBubblingUnitEventById(Ctx, host, roc_host, target_id, .pointer_up, "pointerup", cmd.line_num).ok) return 1;
                        const click_result = dispatchBubblingUnitEventById(Ctx, host, roc_host, target_id, .click, "click", cmd.line_num);
                        if (!click_result.ok) return 1;
                        if (!click_result.dispatched and !hasRealClickDefaultAction(Ctx, elem)) {
                            writeLocatorFailure(cmd.line_num, "real_click did not find a click binding in the propagation path");
                            return 1;
                        }
                        if (!dispatchRealClickDefaultAction(Ctx, host, roc_host, target_id, click_result, cmd.line_num)) return 1;
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
                        const target_id = elem.id;
                        const payload_bytes = encodeKeyShiftPayload(Ctx.allocator(host), key, shift_key);
                        defer Ctx.allocator(host).free(payload_bytes);
                        Ctx.dispatchRocEvent(host, roc_host, event.binding.event_id, event.binding.payload_descriptor, Ctx.hostValueU8List(host, roc_host, payload_bytes));
                        if (std.mem.eql(u8, key, "Enter")) {
                            if (!dispatchEnterKeyDefaultAction(Ctx, host, roc_host, target_id, event.binding.policy.prevent_default, cmd.line_num)) return 1;
                        }
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
                        switch (cmd.cmd_type) {
                            .focus => Ctx.focusElement(host, elem),
                            .blur => Ctx.blurElement(host, elem),
                            .composition_start => Ctx.beginComposition(host, elem),
                            .composition_end => Ctx.endComposition(host, elem),
                            else => unreachable,
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

                    .select_option => {
                        const value = cmd.expected_text orelse "";
                        const elem = Ctx.findElementByLocator(host, cmd.locator, cmd.line_num) orelse {
                            writeLocatorFailure(cmd.line_num, "locator did not resolve to one element");
                            return 1;
                        };
                        if (elem.disabled) {
                            writeLocatorFailure(cmd.line_num, "target is disabled");
                            return 1;
                        }
                        if (!dispatchSelectOptionEvent(Ctx, host, roc_host, elem, value, cmd.line_num)) return 1;
                    },

                    .custom_event => {
                        const event_name = cmd.task_name orelse {
                            writeLocatorFailure(cmd.line_num, "custom_event command had no event name");
                            return 1;
                        };
                        const detail = cmd.expected_text orelse "";
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
                        if (!event.binding.payload_descriptor.eql(BoundaryPayloadDescriptor.init(.str, .detail))) {
                            writeLocatorFailure(cmd.line_num, "custom event binding does not request the detail payload descriptor");
                            return 1;
                        }
                        Ctx.dispatchRocEvent(host, roc_host, event.binding.event_id, event.binding.payload_descriptor, Ctx.hostValueStr(host, roc_host, detail));
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
                        _ = Ctx.setElementValueIfChanged(host, elem, value);
                        if (Ctx.fixedEventId(elem, .input)) |event_id| {
                            Ctx.dispatchRocEvent(host, roc_host, event_id, BoundaryPayloadDescriptor.init(.str, .target_value), Ctx.hostValueStr(host, roc_host, value));
                        } else if (Ctx.namedEvent(elem, "input")) |event| {
                            if (!event.binding.payload_descriptor.eql(BoundaryPayloadDescriptor.init(.str, .target_value))) {
                                writeLocatorFailure(cmd.line_num, "input binding does not request the target value payload descriptor");
                                return 1;
                            }
                            Ctx.dispatchRocEvent(host, roc_host, event.binding.event_id, event.binding.payload_descriptor, Ctx.hostValueStr(host, roc_host, value));
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
                        if (!dispatchCheckedChangeEvent(Ctx, host, roc_host, elem, checked, cmd.line_num)) return 1;
                    },

                    .resolve_task, .reject_task, .resolve_stale_task => {
                        const task_name = cmd.task_name orelse {
                            writeLocatorFailure(cmd.line_num, "task command had no task name");
                            return 1;
                        };
                        const payload = cmd.expected_text orelse "";
                        if (cmd.cmd_type == .resolve_stale_task) {
                            _ = Ctx.resolveStalePendingTask(host, roc_host, task_name, payload, false);
                        } else {
                            _ = Ctx.resolvePendingTask(host, roc_host, task_name, payload, cmd.cmd_type == .reject_task);
                        }
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
                            writeLocatorMiss(Ctx, cmd.line_num, cmd.locator);
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
                            writeLocatorMiss(Ctx, cmd.line_num, cmd.locator);
                            return 1;
                        };
                        if (elem.text) |own_text| {
                            if (!std.mem.eql(u8, own_text, expected)) {
                                writeStringMismatch(cmd.line_num, "text", expected, own_text);
                                return 1;
                            }
                        } else {
                            // An element with no text field of its own may still carry
                            // signal-backed text children. Fall back to the concatenated
                            // descendant text so a container can be asserted by its
                            // rendered content.
                            var buffer: std.ArrayListUnmanaged(u8) = .empty;
                            defer buffer.deinit(Ctx.allocator(host));
                            appendDescendantText(Ctx, host, elem, &buffer);
                            if (!std.mem.eql(u8, buffer.items, expected)) {
                                writeStringMismatch(cmd.line_num, "text", expected, buffer.items);
                                return 1;
                            }
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

                    .expect_canceled_task => {
                        const name = cmd.task_name orelse "";
                        const expected = cmd.expected_count orelse 0;
                        const actual = Ctx.canceledTaskCountByName(host, name);
                        if (actual != expected) {
                            var buf: [512]u8 = undefined;
                            const msg = std.fmt.bufPrint(&buf, "TEST FAILED at line {d}:\n  Expected canceled task \"{s}\": {d}\n  Got canceled task count:       {d}\n", .{ cmd.line_num, name, expected, actual }) catch "TEST FAILED\n";
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
                if (comptime @hasDecl(Ctx, "traceAllocationCheckpoint")) {
                    Ctx.traceAllocationCheckpoint(host, cmd.line_num, @tagName(cmd.cmd_type));
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
            if (std.mem.eql(u8, name, "dirty_source_roots")) return u64MetricAsI64(metrics.dirty_source_roots);
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
            if (std.mem.eql(u8, name, "stale_task_results_ignored")) return u64MetricAsI64(metrics.stale_task_results_ignored);
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

        fn locationSnapshotFromSpecText(line_num: usize, text: []const u8) ?boundary.LocationSnapshot {
            return spec_parser.locationSnapshotFromSpecText(text) catch {
                writeLocatorFailure(line_num, "location path must start with /");
                return null;
            };
        }

        fn visibilitySnapshotFromSpecText(line_num: usize, text: []const u8) ?boundary.VisibilitySnapshot {
            return spec_parser.visibilitySnapshotFromSpecText(text) catch {
                writeLocatorFailure(line_num, "visibility must be visible or hidden");
                return null;
            };
        }

        fn onlineSnapshotFromSpecText(line_num: usize, text: []const u8) ?boundary.OnlineSnapshot {
            return spec_parser.onlineSnapshotFromSpecText(text) catch {
                writeLocatorFailure(line_num, "online state must be online or offline");
                return null;
            };
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

        /// Writes a diagnostic directly to standard error without entering application semantics.
        pub fn writeStderr(_: []const u8) void {}

        /// Returns by id from the host's semantic render model.
        pub fn elementById(host: *Host, elem_id: u64) ?*sim_dom.Element {
            if (elem_id >= host.elements.items.len) return null;
            const elem = &host.elements.items[@intCast(elem_id)];
            if (!elem.active) return null;
            return elem;
        }

        /// Returns the dense id of the selected fixed event binding for spec dispatch.
        pub fn fixedEventId(elem: *const sim_dom.Element, kind: render.EventKind) ?u64 {
            return sim_dom.fixedEventId(elem, kind);
        }

        /// Returns the canonical named-event binding used by the spec or simulated DOM.
        pub fn namedEvent(elem: *const sim_dom.Element, name: []const u8) ?sim_dom.NamedEvent {
            return sim_dom.namedEvent(elem, name);
        }

        /// Dispatches roc event through validated routing and dependency-ordered propagation.
        pub fn dispatchRocEvent(host: *Host, _: *RocHost, event_id: u64, payload_descriptor: BoundaryPayloadDescriptor, payload: anytype) void {
            _ = payload;
            if (!payload_descriptor.eql(BoundaryPayloadDescriptor.init(.unit, .none))) {
                @panic("test expected a unit payload descriptor");
            }
            host.appendDispatch(event_id);
        }

        /// Materializes unit as a capability-owned host value for boundary delivery.
        pub fn hostValueUnit(_: *Host, _: *RocHost) void {}

        /// Materializes bool as a capability-owned host value for boundary delivery.
        pub fn hostValueBool(_: *Host, _: *RocHost, value: bool) bool {
            return value;
        }

        /// Updates checked if changed only when the simulated or browser field actually differs.
        pub fn setElementCheckedIfChanged(elem: *sim_dom.Element, checked: bool) bool {
            return sim_dom.setCheckedIfChanged(elem, checked);
        }
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

    try std.testing.expect(dispatchBubblingUnitEventById(TestCtx, &host, &roc_host, 2, .click, "click", 99).ok);
    try std.testing.expectEqualSlices(u64, &.{ 5, 20, 10 }, host.dispatches.items);

    host.dispatches.clearRetainingCapacity();
    sim_dom.bindEventKind(&host.elements.items[2], .click, .{
        .event_id = 15,
        .payload_descriptor = unit_descriptor,
    });
    sim_dom.bindEventName(allocator, &host.elements.items[2], "click", 20, render.EventPolicy.fromBits(render.listener_option_stop_propagation), unit_descriptor);
    try std.testing.expect(dispatchBubblingUnitEventById(TestCtx, &host, &roc_host, 2, .click, "click", 99).ok);
    try std.testing.expectEqualSlices(u64, &.{ 5, 15, 20 }, host.dispatches.items);
    sim_dom.clearEventKind(&host.elements.items[2], .click);

    host.dispatches.clearRetainingCapacity();
    sim_dom.bindEventName(allocator, &host.elements.items[2], "click", 20, render.EventPolicy.fromBits(render.listener_option_stop_propagation), unit_descriptor);
    try std.testing.expect(dispatchBubblingUnitEventById(TestCtx, &host, &roc_host, 2, .click, "click", 99).ok);
    try std.testing.expectEqualSlices(u64, &.{ 5, 20 }, host.dispatches.items);

    host.dispatches.clearRetainingCapacity();
    sim_dom.bindEventName(allocator, &host.elements.items[2], "click", 20, render.EventPolicy.fromBits(render.listener_option_stop_immediate), unit_descriptor);
    try std.testing.expect(dispatchBubblingUnitEventById(TestCtx, &host, &roc_host, 2, .click, "click", 99).ok);
    try std.testing.expectEqualSlices(u64, &.{ 5, 20 }, host.dispatches.items);

    host.dispatches.clearRetainingCapacity();
    const capture_stop = render.EventPolicy.fromBits(render.listener_option_capture | render.listener_option_stop_propagation);
    sim_dom.bindEventName(allocator, &host.elements.items[0], "click", 5, capture_stop, unit_descriptor);
    sim_dom.bindEventName(allocator, &host.elements.items[2], "click", 20, render.EventPolicy.none, unit_descriptor);
    try std.testing.expect(dispatchBubblingUnitEventById(TestCtx, &host, &roc_host, 2, .click, "click", 99).ok);
    try std.testing.expectEqualSlices(u64, &.{5}, host.dispatches.items);

    host.dispatches.clearRetainingCapacity();
    sim_dom.bindEventName(allocator, &host.elements.items[0], "click", 5, render.EventPolicy.fromBits(render.listener_option_capture | render.listener_option_self), unit_descriptor);
    sim_dom.bindEventName(allocator, &host.elements.items[1], "click", 10, render.EventPolicy.fromBits(render.listener_option_self), unit_descriptor);
    sim_dom.bindEventName(allocator, &host.elements.items[2], "click", 20, render.EventPolicy.none, unit_descriptor);
    try std.testing.expect(dispatchBubblingUnitEventById(TestCtx, &host, &roc_host, 2, .click, "click", 99).ok);
    try std.testing.expectEqualSlices(u64, &.{20}, host.dispatches.items);
}

test "spec runner real_click applies form button default actions" {
    const sim_dom = @import("../sim_dom.zig");

    const TestPayload = union(enum) {
        unit: void,
        bool: bool,
        str: []const u8,
    };

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

        /// Writes a diagnostic directly to standard error without entering application semantics.
        pub fn writeStderr(_: []const u8) void {}

        /// Returns by id from the host's semantic render model.
        pub fn elementById(host: *Host, elem_id: u64) ?*sim_dom.Element {
            if (elem_id >= host.elements.items.len) return null;
            const elem = &host.elements.items[@intCast(elem_id)];
            if (!elem.active) return null;
            return elem;
        }

        /// Returns the dense id of the selected fixed event binding for spec dispatch.
        pub fn fixedEventId(elem: *const sim_dom.Element, kind: render.EventKind) ?u64 {
            return sim_dom.fixedEventId(elem, kind);
        }

        /// Returns the canonical named-event binding used by the spec or simulated DOM.
        pub fn namedEvent(elem: *const sim_dom.Element, name: []const u8) ?sim_dom.NamedEvent {
            return sim_dom.namedEvent(elem, name);
        }

        /// Returns text attr from the host's semantic render model.
        pub fn elementTextAttr(elem: *const sim_dom.Element, name: []const u8) ?[]const u8 {
            return sim_dom.textAttr(elem, name);
        }

        /// Dispatches roc event through validated routing and dependency-ordered propagation.
        pub fn dispatchRocEvent(host: *Host, _: *RocHost, event_id: u64, payload_descriptor: BoundaryPayloadDescriptor, payload: TestPayload) void {
            if (!payload_descriptor.eql(BoundaryPayloadDescriptor.init(.unit, .none))) {
                @panic("test expected a unit payload descriptor");
            }
            switch (payload) {
                .unit => {},
                .bool => @panic("test expected a unit payload"),
                .str => @panic("test expected a unit payload"),
            }
            host.appendDispatch(event_id);
        }

        /// Materializes unit as a capability-owned host value for boundary delivery.
        pub fn hostValueUnit(_: *Host, _: *RocHost) TestPayload {
            return .{ .unit = {} };
        }

        /// Materializes bool as a capability-owned host value for boundary delivery.
        pub fn hostValueBool(_: *Host, _: *RocHost, value: bool) TestPayload {
            return .{ .bool = value };
        }

        /// Materializes str as a capability-owned host value for boundary delivery.
        pub fn hostValueStr(_: *Host, _: *RocHost, value: []const u8) TestPayload {
            return .{ .str = value };
        }

        /// Updates checked if changed only when the simulated or browser field actually differs.
        pub fn setElementCheckedIfChanged(elem: *sim_dom.Element, checked: bool) bool {
            return sim_dom.setCheckedIfChanged(elem, checked);
        }
    };

    const allocator = std.testing.allocator;
    var host = TestHost.init(allocator);
    defer host.deinit();
    var roc_host: void = {};

    sim_dom.reset(allocator, &host.elements);
    sim_dom.appendDetached(allocator, &host.elements, 1, "form");
    sim_dom.appendDetached(allocator, &host.elements, 2, "button");
    sim_dom.appendChild(allocator, &host.elements.items[0], &host.elements.items[1]);
    sim_dom.appendChild(allocator, &host.elements.items[1], &host.elements.items[2]);

    const unit_descriptor = BoundaryPayloadDescriptor.init(.unit, .none);
    sim_dom.bindEventKind(&host.elements.items[2], .click, .{
        .event_id = 10,
        .payload_descriptor = unit_descriptor,
    });
    sim_dom.bindEventName(allocator, &host.elements.items[1], "submit", 20, render.EventPolicy.fromBits(render.listener_option_prevent_default), unit_descriptor);

    const click_result = dispatchBubblingUnitEventById(TestCtx, &host, &roc_host, 2, .click, "click", 200);
    try std.testing.expect(click_result.ok);
    try std.testing.expect(!click_result.default_prevented);
    try std.testing.expect(dispatchRealClickDefaultAction(TestCtx, &host, &roc_host, 2, click_result, 200));
    try std.testing.expectEqualSlices(u64, &.{ 10, 20 }, host.dispatches.items);

    host.dispatches.clearRetainingCapacity();
    sim_dom.clearEventKind(&host.elements.items[2], .click);
    const no_click_result = dispatchBubblingUnitEventById(TestCtx, &host, &roc_host, 2, .click, "click", 201);
    try std.testing.expect(no_click_result.ok);
    try std.testing.expect(!no_click_result.dispatched);
    try std.testing.expect(dispatchRealClickDefaultAction(TestCtx, &host, &roc_host, 2, no_click_result, 201));
    try std.testing.expectEqualSlices(u64, &.{20}, host.dispatches.items);

    host.dispatches.clearRetainingCapacity();
    sim_dom.bindEventName(allocator, &host.elements.items[2], "click", 30, render.EventPolicy.fromBits(render.listener_option_prevent_default), unit_descriptor);
    const prevented_click = dispatchBubblingUnitEventById(TestCtx, &host, &roc_host, 2, .click, "click", 202);
    try std.testing.expect(prevented_click.ok);
    try std.testing.expect(prevented_click.default_prevented);
    try std.testing.expect(dispatchRealClickDefaultAction(TestCtx, &host, &roc_host, 2, prevented_click, 202));
    try std.testing.expectEqualSlices(u64, &.{30}, host.dispatches.items);

    host.dispatches.clearRetainingCapacity();
    sim_dom.clearEventName(allocator, &host.elements.items[2], "click");
    sim_dom.setTextAttr(allocator, &host.elements.items[2], "type", "reset");
    sim_dom.bindEventName(allocator, &host.elements.items[1], "reset", 40, render.EventPolicy.fromBits(render.listener_option_prevent_default), unit_descriptor);
    const reset_click = dispatchBubblingUnitEventById(TestCtx, &host, &roc_host, 2, .click, "click", 203);
    try std.testing.expect(reset_click.ok);
    try std.testing.expect(dispatchRealClickDefaultAction(TestCtx, &host, &roc_host, 2, reset_click, 203));
    try std.testing.expectEqualSlices(u64, &.{40}, host.dispatches.items);

    host.dispatches.clearRetainingCapacity();
    sim_dom.bindEventName(allocator, &host.elements.items[1], "reset", 41, render.EventPolicy.none, unit_descriptor);
    try std.testing.expect(!dispatchRealClickDefaultAction(TestCtx, &host, &roc_host, 2, reset_click, 204));
    try std.testing.expectEqual(@as(usize, 0), host.dispatches.items.len);
}

test "spec runner real_click applies checkbox default action" {
    const sim_dom = @import("../sim_dom.zig");

    const TestPayload = union(enum) {
        unit: void,
        bool: bool,
        str: []const u8,
    };

    const BoolDispatch = struct {
        event_id: u64,
        value: bool,
    };

    const TestHost = struct {
        allocator: std.mem.Allocator,
        elements: std.ArrayListUnmanaged(sim_dom.Element) = .empty,
        unit_dispatches: std.ArrayListUnmanaged(u64) = .empty,
        bool_dispatches: std.ArrayListUnmanaged(BoolDispatch) = .empty,

        fn init(allocator: std.mem.Allocator) @This() {
            return .{ .allocator = allocator };
        }

        fn deinit(self: *@This()) void {
            for (self.elements.items) |*elem| {
                elem.deinit(self.allocator);
            }
            self.elements.deinit(self.allocator);
            self.unit_dispatches.deinit(self.allocator);
            self.bool_dispatches.deinit(self.allocator);
        }
    };

    const TestCtx = struct {
        pub const Host = TestHost;
        pub const RocHost = void;

        /// Writes a diagnostic directly to standard error without entering application semantics.
        pub fn writeStderr(_: []const u8) void {}

        /// Returns by id from the host's semantic render model.
        pub fn elementById(host: *Host, elem_id: u64) ?*sim_dom.Element {
            if (elem_id >= host.elements.items.len) return null;
            const elem = &host.elements.items[@intCast(elem_id)];
            if (!elem.active) return null;
            return elem;
        }

        /// Returns the dense id of the selected fixed event binding for spec dispatch.
        pub fn fixedEventId(elem: *const sim_dom.Element, kind: render.EventKind) ?u64 {
            return sim_dom.fixedEventId(elem, kind);
        }

        /// Returns the canonical named-event binding used by the spec or simulated DOM.
        pub fn namedEvent(elem: *const sim_dom.Element, name: []const u8) ?sim_dom.NamedEvent {
            return sim_dom.namedEvent(elem, name);
        }

        /// Returns text attr from the host's semantic render model.
        pub fn elementTextAttr(elem: *const sim_dom.Element, name: []const u8) ?[]const u8 {
            return sim_dom.textAttr(elem, name);
        }

        /// Dispatches roc event through validated routing and dependency-ordered propagation.
        pub fn dispatchRocEvent(host: *Host, _: *RocHost, event_id: u64, payload_descriptor: BoundaryPayloadDescriptor, payload: TestPayload) void {
            if (payload_descriptor.eql(BoundaryPayloadDescriptor.init(.unit, .none))) {
                switch (payload) {
                    .unit => {},
                    .bool => @panic("test expected a unit payload"),
                }
                host.unit_dispatches.append(host.allocator, event_id) catch @panic("test dispatch log allocation failed");
                return;
            }
            if (payload_descriptor.eql(BoundaryPayloadDescriptor.init(.bool, .target_checked))) {
                const value = switch (payload) {
                    .unit => @panic("test expected a bool payload"),
                    .bool => |value| value,
                    .str => @panic("test expected a bool payload"),
                };
                host.bool_dispatches.append(host.allocator, .{ .event_id = event_id, .value = value }) catch @panic("test dispatch log allocation failed");
                return;
            }
            @panic("test expected unit or checked payload descriptor");
        }

        /// Materializes unit as a capability-owned host value for boundary delivery.
        pub fn hostValueUnit(_: *Host, _: *RocHost) TestPayload {
            return .{ .unit = {} };
        }

        /// Materializes bool as a capability-owned host value for boundary delivery.
        pub fn hostValueBool(_: *Host, _: *RocHost, value: bool) TestPayload {
            return .{ .bool = value };
        }

        /// Materializes str as a capability-owned host value for boundary delivery.
        pub fn hostValueStr(_: *Host, _: *RocHost, value: []const u8) TestPayload {
            return .{ .str = value };
        }

        /// Updates checked if changed only when the simulated or browser field actually differs.
        pub fn setElementCheckedIfChanged(elem: *sim_dom.Element, checked: bool) bool {
            return sim_dom.setCheckedIfChanged(elem, checked);
        }
    };

    const allocator = std.testing.allocator;
    var host = TestHost.init(allocator);
    defer host.deinit();
    var roc_host: void = {};

    sim_dom.reset(allocator, &host.elements);
    sim_dom.appendDetached(allocator, &host.elements, 1, "input");
    sim_dom.appendChild(allocator, &host.elements.items[0], &host.elements.items[1]);
    sim_dom.setOwnedString(allocator, &host.elements.items[1].role, "checkbox");
    sim_dom.setOwnedString(allocator, &host.elements.items[1].label, "Accept terms");

    const bool_descriptor = BoundaryPayloadDescriptor.init(.bool, .target_checked);
    const click_result = dispatchBubblingUnitEventById(TestCtx, &host, &roc_host, 1, .click, "click", 300);
    try std.testing.expect(click_result.ok);
    try std.testing.expect(!click_result.dispatched);
    try std.testing.expect(hasRealClickDefaultAction(TestCtx, &host.elements.items[1]));
    try std.testing.expect(dispatchRealClickDefaultAction(TestCtx, &host, &roc_host, 1, click_result, 300));
    try std.testing.expect(host.elements.items[1].checked);

    host.elements.items[1].checked = false;
    sim_dom.bindEventKind(&host.elements.items[1], .check, .{
        .event_id = 40,
        .payload_descriptor = bool_descriptor,
    });
    const bound_click = dispatchBubblingUnitEventById(TestCtx, &host, &roc_host, 1, .click, "click", 301);
    try std.testing.expect(bound_click.ok);
    try std.testing.expect(!bound_click.dispatched);
    try std.testing.expect(dispatchRealClickDefaultAction(TestCtx, &host, &roc_host, 1, bound_click, 301));
    try std.testing.expectEqualSlices(BoolDispatch, &.{.{ .event_id = 40, .value = true }}, host.bool_dispatches.items);
    try std.testing.expectEqual(@as(usize, 0), host.unit_dispatches.items.len);
}

test "spec runner real_click applies radio default action" {
    const sim_dom = @import("../sim_dom.zig");

    const TestPayload = union(enum) {
        unit: void,
        bool: bool,
        str: []const u8,
    };

    const StrDispatch = struct {
        event_id: u64,
        value: []const u8,
    };

    const TestHost = struct {
        allocator: std.mem.Allocator,
        elements: std.ArrayListUnmanaged(sim_dom.Element) = .empty,
        unit_dispatches: std.ArrayListUnmanaged(u64) = .empty,
        str_dispatches: std.ArrayListUnmanaged(StrDispatch) = .empty,

        fn init(allocator: std.mem.Allocator) @This() {
            return .{ .allocator = allocator };
        }

        fn deinit(self: *@This()) void {
            for (self.elements.items) |*elem| {
                elem.deinit(self.allocator);
            }
            self.elements.deinit(self.allocator);
            self.unit_dispatches.deinit(self.allocator);
            self.str_dispatches.deinit(self.allocator);
        }
    };

    const TestCtx = struct {
        pub const Host = TestHost;
        pub const RocHost = void;

        /// Writes a diagnostic directly to standard error without entering application semantics.
        pub fn writeStderr(_: []const u8) void {}

        /// Returns by id from the host's semantic render model.
        pub fn elementById(host: *Host, elem_id: u64) ?*sim_dom.Element {
            if (elem_id >= host.elements.items.len) return null;
            const elem = &host.elements.items[@intCast(elem_id)];
            if (!elem.active) return null;
            return elem;
        }

        /// Returns the dense id of the selected fixed event binding for spec dispatch.
        pub fn fixedEventId(elem: *const sim_dom.Element, kind: render.EventKind) ?u64 {
            return sim_dom.fixedEventId(elem, kind);
        }

        /// Returns the canonical named-event binding used by the spec or simulated DOM.
        pub fn namedEvent(elem: *const sim_dom.Element, name: []const u8) ?sim_dom.NamedEvent {
            return sim_dom.namedEvent(elem, name);
        }

        /// Returns text attr from the host's semantic render model.
        pub fn elementTextAttr(elem: *const sim_dom.Element, name: []const u8) ?[]const u8 {
            return sim_dom.textAttr(elem, name);
        }

        /// Dispatches roc event through validated routing and dependency-ordered propagation.
        pub fn dispatchRocEvent(host: *Host, _: *RocHost, event_id: u64, payload_descriptor: BoundaryPayloadDescriptor, payload: TestPayload) void {
            if (payload_descriptor.eql(BoundaryPayloadDescriptor.init(.unit, .none))) {
                switch (payload) {
                    .unit => {},
                    .bool, .str => @panic("test expected a unit payload"),
                }
                host.unit_dispatches.append(host.allocator, event_id) catch @panic("test dispatch log allocation failed");
                return;
            }
            if (payload_descriptor.eql(BoundaryPayloadDescriptor.init(.str, .target_value))) {
                const value = switch (payload) {
                    .unit, .bool => @panic("test expected a string payload"),
                    .str => |value| value,
                };
                host.str_dispatches.append(host.allocator, .{ .event_id = event_id, .value = value }) catch @panic("test dispatch log allocation failed");
                return;
            }
            @panic("test expected unit or target-value payload descriptor");
        }

        /// Materializes unit as a capability-owned host value for boundary delivery.
        pub fn hostValueUnit(_: *Host, _: *RocHost) TestPayload {
            return .{ .unit = {} };
        }

        /// Materializes bool as a capability-owned host value for boundary delivery.
        pub fn hostValueBool(_: *Host, _: *RocHost, value: bool) TestPayload {
            return .{ .bool = value };
        }

        /// Materializes str as a capability-owned host value for boundary delivery.
        pub fn hostValueStr(_: *Host, _: *RocHost, value: []const u8) TestPayload {
            return .{ .str = value };
        }

        /// Updates checked if changed only when the simulated or browser field actually differs.
        pub fn setElementCheckedIfChanged(elem: *sim_dom.Element, checked: bool) bool {
            return sim_dom.setCheckedIfChanged(elem, checked);
        }
    };

    const allocator = std.testing.allocator;
    var host = TestHost.init(allocator);
    defer host.deinit();
    var roc_host: void = {};

    sim_dom.reset(allocator, &host.elements);
    sim_dom.appendDetached(allocator, &host.elements, 1, "input");
    sim_dom.appendChild(allocator, &host.elements.items[0], &host.elements.items[1]);
    sim_dom.setOwnedString(allocator, &host.elements.items[1].role, "radio");
    sim_dom.setOwnedString(allocator, &host.elements.items[1].label, "Annual");
    sim_dom.setValue(allocator, &host.elements.items[1], "annual");

    sim_dom.bindEventName(allocator, &host.elements.items[1], "change", 50, render.EventPolicy.none, BoundaryPayloadDescriptor.init(.str, .target_value));
    const click_result = dispatchBubblingUnitEventById(TestCtx, &host, &roc_host, 1, .click, "click", 400);
    try std.testing.expect(click_result.ok);
    try std.testing.expect(!click_result.dispatched);
    try std.testing.expect(hasRealClickDefaultAction(TestCtx, &host.elements.items[1]));
    try std.testing.expect(dispatchRealClickDefaultAction(TestCtx, &host, &roc_host, 1, click_result, 400));
    try std.testing.expect(host.elements.items[1].checked);
    try std.testing.expectEqual(@as(usize, 1), host.str_dispatches.items.len);
    try std.testing.expectEqual(@as(u64, 50), host.str_dispatches.items[0].event_id);
    try std.testing.expectEqualStrings("annual", host.str_dispatches.items[0].value);
    try std.testing.expectEqual(@as(usize, 0), host.unit_dispatches.items.len);

    host.str_dispatches.clearRetainingCapacity();
    const second_click = dispatchBubblingUnitEventById(TestCtx, &host, &roc_host, 1, .click, "click", 401);
    try std.testing.expect(second_click.ok);
    try std.testing.expect(dispatchRealClickDefaultAction(TestCtx, &host, &roc_host, 1, second_click, 401));
    try std.testing.expectEqual(@as(usize, 0), host.str_dispatches.items.len);
}

test "spec runner select_option applies select default action" {
    const sim_dom = @import("../sim_dom.zig");

    const TestPayload = union(enum) {
        unit: void,
        str: []const u8,
    };

    const StrDispatch = struct {
        event_id: u64,
        value: []const u8,
    };

    const TestHost = struct {
        allocator: std.mem.Allocator,
        elements: std.ArrayListUnmanaged(sim_dom.Element) = .empty,
        str_dispatches: std.ArrayListUnmanaged(StrDispatch) = .empty,

        fn init(allocator: std.mem.Allocator) @This() {
            return .{ .allocator = allocator };
        }

        fn deinit(self: *@This()) void {
            for (self.elements.items) |*elem| {
                elem.deinit(self.allocator);
            }
            self.elements.deinit(self.allocator);
            self.str_dispatches.deinit(self.allocator);
        }
    };

    const TestCtx = struct {
        pub const Host = TestHost;
        pub const RocHost = void;

        /// Writes a diagnostic directly to standard error without entering application semantics.
        pub fn writeStderr(_: []const u8) void {}

        /// Returns by id from the host's semantic render model.
        pub fn elementById(host: *Host, elem_id: u64) ?*sim_dom.Element {
            if (elem_id >= host.elements.items.len) return null;
            const elem = &host.elements.items[@intCast(elem_id)];
            if (!elem.active) return null;
            return elem;
        }

        /// Returns the canonical named-event binding used by the spec or simulated DOM.
        pub fn namedEvent(elem: *const sim_dom.Element, name: []const u8) ?sim_dom.NamedEvent {
            return sim_dom.namedEvent(elem, name);
        }

        /// Returns text attr from the host's semantic render model.
        pub fn elementTextAttr(elem: *const sim_dom.Element, name: []const u8) ?[]const u8 {
            return sim_dom.textAttr(elem, name);
        }

        /// Dispatches roc event through validated routing and dependency-ordered propagation.
        pub fn dispatchRocEvent(host: *Host, _: *RocHost, event_id: u64, payload_descriptor: BoundaryPayloadDescriptor, payload: TestPayload) void {
            if (!payload_descriptor.eql(BoundaryPayloadDescriptor.init(.str, .target_value))) {
                @panic("test expected a target-value payload descriptor");
            }
            const value = switch (payload) {
                .unit => @panic("test expected a string payload"),
                .str => |value| value,
            };
            host.str_dispatches.append(host.allocator, .{ .event_id = event_id, .value = value }) catch @panic("test dispatch log allocation failed");
        }

        /// Materializes str as a capability-owned host value for boundary delivery.
        pub fn hostValueStr(_: *Host, _: *RocHost, value: []const u8) TestPayload {
            return .{ .str = value };
        }

        /// Updates value if changed only when the simulated or browser field actually differs.
        pub fn setElementValueIfChanged(host: *Host, elem: *sim_dom.Element, value: []const u8) bool {
            return sim_dom.setUserValueIfChanged(host.allocator, elem, value);
        }
    };

    const allocator = std.testing.allocator;
    var host = TestHost.init(allocator);
    defer host.deinit();
    var roc_host: void = {};

    sim_dom.reset(allocator, &host.elements);
    sim_dom.appendDetached(allocator, &host.elements, 1, "select");
    sim_dom.appendDetached(allocator, &host.elements, 2, "option");
    sim_dom.appendDetached(allocator, &host.elements, 3, "option");
    sim_dom.appendChild(allocator, &host.elements.items[0], &host.elements.items[1]);
    sim_dom.appendChild(allocator, &host.elements.items[1], &host.elements.items[2]);
    sim_dom.appendChild(allocator, &host.elements.items[1], &host.elements.items[3]);
    sim_dom.setValue(allocator, &host.elements.items[1], "starter");
    sim_dom.setTextAttr(allocator, &host.elements.items[2], "value", "starter");
    sim_dom.setTextAttr(allocator, &host.elements.items[3], "value", "growth");
    sim_dom.bindEventName(allocator, &host.elements.items[1], "change", 60, render.EventPolicy.none, BoundaryPayloadDescriptor.init(.str, .target_value));

    try std.testing.expect(dispatchSelectOptionEvent(TestCtx, &host, &roc_host, &host.elements.items[1], "growth", 500));
    try std.testing.expectEqualStrings("growth", host.elements.items[1].value.?);
    try std.testing.expectEqual(@as(usize, 1), host.str_dispatches.items.len);
    try std.testing.expectEqual(@as(u64, 60), host.str_dispatches.items[0].event_id);
    try std.testing.expectEqualStrings("growth", host.str_dispatches.items[0].value);

    host.str_dispatches.clearRetainingCapacity();
    try std.testing.expect(dispatchSelectOptionEvent(TestCtx, &host, &roc_host, &host.elements.items[1], "growth", 501));
    try std.testing.expectEqual(@as(usize, 0), host.str_dispatches.items.len);

    try std.testing.expect(!dispatchSelectOptionEvent(TestCtx, &host, &roc_host, &host.elements.items[1], "missing", 502));
}

test "spec runner Enter key applies text-input submit default action" {
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
    };

    const TestCtx = struct {
        pub const Host = TestHost;
        pub const RocHost = void;

        /// Writes a diagnostic directly to standard error without entering application semantics.
        pub fn writeStderr(_: []const u8) void {}

        /// Returns by id from the host's semantic render model.
        pub fn elementById(host: *Host, elem_id: u64) ?*sim_dom.Element {
            if (elem_id >= host.elements.items.len) return null;
            const elem = &host.elements.items[@intCast(elem_id)];
            if (!elem.active) return null;
            return elem;
        }

        /// Returns the canonical named-event binding used by the spec or simulated DOM.
        pub fn namedEvent(elem: *const sim_dom.Element, name: []const u8) ?sim_dom.NamedEvent {
            return sim_dom.namedEvent(elem, name);
        }

        /// Returns text attr from the host's semantic render model.
        pub fn elementTextAttr(elem: *const sim_dom.Element, name: []const u8) ?[]const u8 {
            return sim_dom.textAttr(elem, name);
        }

        /// Dispatches roc event through validated routing and dependency-ordered propagation.
        pub fn dispatchRocEvent(host: *Host, _: *RocHost, event_id: u64, payload_descriptor: BoundaryPayloadDescriptor, _: void) void {
            if (!payload_descriptor.eql(BoundaryPayloadDescriptor.init(.unit, .none))) {
                @panic("test expected a unit payload descriptor");
            }
            host.dispatches.append(host.allocator, event_id) catch @panic("test dispatch log allocation failed");
        }

        /// Materializes unit as a capability-owned host value for boundary delivery.
        pub fn hostValueUnit(_: *Host, _: *RocHost) void {}
    };

    const allocator = std.testing.allocator;
    var host = TestHost.init(allocator);
    defer host.deinit();
    var roc_host: void = {};

    sim_dom.reset(allocator, &host.elements);
    sim_dom.appendDetached(allocator, &host.elements, 1, "form");
    sim_dom.appendDetached(allocator, &host.elements, 2, "input");
    sim_dom.appendChild(allocator, &host.elements.items[0], &host.elements.items[1]);
    sim_dom.appendChild(allocator, &host.elements.items[1], &host.elements.items[2]);
    sim_dom.bindEventName(allocator, &host.elements.items[1], "submit", 70, render.EventPolicy.fromBits(render.listener_option_prevent_default), BoundaryPayloadDescriptor.init(.unit, .none));

    try std.testing.expect(dispatchEnterKeyDefaultAction(TestCtx, &host, &roc_host, 2, false, 600));
    try std.testing.expectEqualSlices(u64, &.{70}, host.dispatches.items);

    host.dispatches.clearRetainingCapacity();
    try std.testing.expect(dispatchEnterKeyDefaultAction(TestCtx, &host, &roc_host, 2, true, 601));
    try std.testing.expectEqual(@as(usize, 0), host.dispatches.items.len);

    sim_dom.setTextAttr(allocator, &host.elements.items[2], "type", "checkbox");
    try std.testing.expect(dispatchEnterKeyDefaultAction(TestCtx, &host, &roc_host, 2, false, 602));
    try std.testing.expectEqual(@as(usize, 0), host.dispatches.items.len);
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

        /// Writes a diagnostic directly to standard error without entering application semantics.
        pub fn writeStderr(_: []const u8) void {}

        /// Returns the canonical named-event binding used by the spec or simulated DOM.
        pub fn namedEvent(elem: *const sim_dom.Element, name: []const u8) ?sim_dom.NamedEvent {
            return sim_dom.namedEvent(elem, name);
        }

        /// Dispatches roc event through validated routing and dependency-ordered propagation.
        pub fn dispatchRocEvent(host: *Host, _: *RocHost, event_id: u64, payload_descriptor: BoundaryPayloadDescriptor, _: void) void {
            if (!payload_descriptor.eql(BoundaryPayloadDescriptor.init(.unit, .none))) {
                @panic("test expected a unit payload descriptor");
            }
            host.appendDispatch(event_id);
        }

        /// Materializes unit as a capability-owned host value for boundary delivery.
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
    sim_dom.bindEventName(allocator, &host.elements.items[1], "submit", 30, render.EventPolicy.fromBits(render.listener_option_prevent_default), unit_descriptor);
    try std.testing.expect(dispatchSubmitEvent(TestCtx, &host, &roc_host, &host.elements.items[1], 120));
    try std.testing.expectEqualSlices(u64, &.{30}, host.dispatches.items);

    host.dispatches.clearRetainingCapacity();
    sim_dom.bindEventName(allocator, &host.elements.items[1], "submit", 31, render.EventPolicy.none, BoundaryPayloadDescriptor.init(.str, .target_value));
    try std.testing.expect(!dispatchSubmitEvent(TestCtx, &host, &roc_host, &host.elements.items[1], 121));
    try std.testing.expectEqual(@as(usize, 0), host.dispatches.items.len);

    sim_dom.bindEventName(allocator, &host.elements.items[1], "submit", 32, render.EventPolicy.none, unit_descriptor);
    try std.testing.expect(!dispatchSubmitEvent(TestCtx, &host, &roc_host, &host.elements.items[1], 122));
    try std.testing.expectEqual(@as(usize, 0), host.dispatches.items.len);

    sim_dom.bindEventName(allocator, &host.elements.items[1], "submit", 32, render.EventPolicy.none, unit_descriptor);
    sim_dom.setDisabled(&host.elements.items[1], true);
    try std.testing.expect(!dispatchSubmitEvent(TestCtx, &host, &roc_host, &host.elements.items[1], 123));
    try std.testing.expectEqual(@as(usize, 0), host.dispatches.items.len);
}

test "spec runner resolves runtime metric names" {
    const TestCtx = struct {
        pub const Host = void;
        pub const RocHost = void;

        /// Terminates this test or host path because continuing could leave runtime meaning incoherent.
        pub fn fail(_: []const u8) noreturn {
            unreachable;
        }

        /// Writes a diagnostic directly to standard error without entering application semantics.
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
