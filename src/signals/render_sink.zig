//! Host-facing render sink interface for the shared Signals engine.
//!
//! This is intentionally a thin generic adapter. Slice 4d starts by routing the
//! native simulated DOM through this sink without changing behavior; later
//! slices move render decisions into the engine while each host keeps its own
//! concrete sink implementation.

const std = @import("std");
const boundary = @import("boundary.zig");
const render = @import("render_commands.zig");

pub const TextField = render.TextField;
pub const BoolField = render.BoolField;
pub const EventKind = render.EventKind;
pub const EventPolicy = render.EventPolicy;
pub const BoundaryPayloadDescriptor = boundary.BoundaryPayloadDescriptor;
pub const Counts = render.Counts;

pub const EventBindingKey = union(enum) {
    fixed: EventKind,
    named: []const u8,

    pub fn deliveryFor(self: EventBindingKey, requested: EventDeliveryRequest, policy: EventPolicy) EventDelivery {
        return EventDelivery.derive(requested, policy, self.deliveryTraits());
    }

    fn deliveryTraits(self: EventBindingKey) EventDeliveryTraits {
        return switch (self) {
            .fixed => |kind| switch (kind) {
                .pointer_down => .{ .pointer_drag = true },
                .pointer_up, .pointer_enter, .pointer_leave => .{ .prevent_default_for_pointer_events = true },
                else => .{},
            },
            .named => .{},
        };
    }
};

pub const EventDeliveryRequest = enum {
    auto,
    native,
};

pub const EventDeliveryEffective = enum {
    native,
    delegated,
};

pub const EventDeliveryReason = enum {
    requested_native,
    capture_policy,
    stop_immediate_policy,
    stop_propagation_policy,
    pointer_drag,
    prevent_default_policy,
    once_policy,
    passive_policy,
    self_filter,
    native_runtime_default,
};

pub const EventDeliveryTraits = struct {
    pointer_drag: bool = false,
    prevent_default_for_pointer_events: bool = false,
};

pub const EventDelivery = struct {
    requested: EventDeliveryRequest = .auto,
    effective: EventDeliveryEffective = .native,
    reason: EventDeliveryReason = .native_runtime_default,

    pub fn derive(requested: EventDeliveryRequest, policy: EventPolicy, traits: EventDeliveryTraits) EventDelivery {
        if (requested == .native) {
            return .{ .requested = requested, .effective = .native, .reason = .requested_native };
        }
        return .{
            .requested = requested,
            .effective = .native,
            .reason = nativeReason(policy, traits),
        };
    }

    fn nativeReason(policy: EventPolicy, traits: EventDeliveryTraits) EventDeliveryReason {
        if (policy.capture) return .capture_policy;
        if (policy.stop_immediate) return .stop_immediate_policy;
        if (policy.stop_propagation) return .stop_propagation_policy;
        if (traits.pointer_drag) return .pointer_drag;
        if (policy.prevent_default or traits.prevent_default_for_pointer_events) return .prevent_default_policy;
        if (policy.once) return .once_policy;
        if (policy.passive) return .passive_policy;
        if (policy.self) return .self_filter;
        return .native_runtime_default;
    }

    pub fn eql(self: EventDelivery, other: EventDelivery) bool {
        return self.requested == other.requested and
            self.effective == other.effective and
            self.reason == other.reason;
    }

    pub fn toWire(self: EventDelivery) render.EventDeliveryWire {
        return .{
            .requested = switch (self.requested) {
                .auto => .auto,
                .native => .native,
            },
            .effective = switch (self.effective) {
                .native => .native,
                .delegated => .delegated,
            },
            .reason = switch (self.reason) {
                .requested_native => .requested_native,
                .capture_policy => .capture_policy,
                .stop_immediate_policy => .stop_immediate_policy,
                .stop_propagation_policy => .stop_propagation_policy,
                .pointer_drag => .pointer_drag,
                .prevent_default_policy => .prevent_default_policy,
                .once_policy => .once_policy,
                .passive_policy => .passive_policy,
                .self_filter => .self_filter,
                .native_runtime_default => .native_runtime_default,
            },
        };
    }
};

pub const EventBinding = struct {
    event_id: u64,
    policy: EventPolicy = EventPolicy.none,
    delivery: EventDelivery = .{},
    payload_descriptor: BoundaryPayloadDescriptor,

    pub fn withDeliveryFor(self: EventBinding, key: EventBindingKey) EventBinding {
        var next = self;
        next.delivery = key.deliveryFor(next.delivery.requested, next.policy);
        return next;
    }

    pub fn eql(self: EventBinding, other: EventBinding) bool {
        return self.event_id == other.event_id and
            self.policy.eql(other.policy) and
            self.delivery.eql(other.delivery) and
            self.payload_descriptor.eql(other.payload_descriptor);
    }

    pub fn canUseFixedOpcode(self: EventBinding, kind: EventKind) bool {
        return self.policy.isNone() and self.payload_descriptor.eql(kind.payloadDescriptor());
    }
};

pub const EventBindCommand = struct {
    elem_id: u64,
    key: EventBindingKey,
    binding: EventBinding,
};

pub const EventClearCommand = struct {
    elem_id: u64,
    key: EventBindingKey,
};

pub fn DomSink(comptime Host: type) type {
    return struct {
        host: *Host,

        pub fn reset(self: @This()) void {
            self.host.sinkReset();
        }

        pub fn appendNode(self: @This(), elem_id: u64, parent_elem_id: u64, tag: []const u8) void {
            self.host.sinkAppendNode(elem_id, parent_elem_id, tag);
        }

        pub fn ensureNode(self: @This(), elem_id: u64, tag: []const u8) void {
            self.host.sinkEnsureNode(elem_id, tag);
        }

        pub fn removeNode(self: @This(), elem_id: u64) void {
            self.host.sinkRemoveNode(elem_id);
        }

        pub fn replaceChildren(self: @This(), parent_elem_id: u64, next_child_ids: []const u64) void {
            self.host.sinkReplaceChildren(parent_elem_id, next_child_ids);
        }

        pub fn replaceChildrenForMoves(self: @This(), parent_elem_id: u64, next_child_ids: []const u64) void {
            self.host.sinkReplaceChildrenForMoves(parent_elem_id, next_child_ids);
        }

        pub fn applyTextField(self: @This(), elem_id: u64, field: TextField, value: []const u8) void {
            self.host.sinkApplyTextField(elem_id, field, value);
        }

        pub fn applyTextAttr(self: @This(), elem_id: u64, name: []const u8, value: []const u8) void {
            self.host.sinkApplyTextAttr(elem_id, name, value);
        }

        pub fn applyBoolField(self: @This(), elem_id: u64, field: BoolField, value: bool) void {
            self.host.sinkApplyBoolField(elem_id, field, value);
        }

        pub fn clearTextField(self: @This(), elem_id: u64, field: TextField) void {
            self.host.sinkClearTextField(elem_id, field);
        }

        pub fn clearTextAttr(self: @This(), elem_id: u64, name: []const u8) void {
            self.host.sinkClearTextAttr(elem_id, name);
        }

        pub fn clearBoolField(self: @This(), elem_id: u64, field: BoolField) void {
            self.host.sinkClearBoolField(elem_id, field);
        }

        pub fn bindEvent(self: @This(), elem_id: u64, key: EventBindingKey, binding: EventBinding) void {
            self.host.sinkBindEvent(.{ .elem_id = elem_id, .key = key, .binding = binding });
        }

        pub fn clearEvent(self: @This(), elem_id: u64, key: EventBindingKey) void {
            self.host.sinkClearEvent(.{ .elem_id = elem_id, .key = key });
        }

        pub fn startInterval(self: @This(), token: u64, period_ms: u64) void {
            self.host.sinkStartInterval(token, period_ms);
        }

        pub fn cancelInterval(self: @This(), token: u64) void {
            self.host.sinkCancelInterval(token);
        }

        pub fn startTask(self: @This(), request_id: u64, task_name: []const u8, request: []const u8) void {
            self.host.sinkStartTask(request_id, task_name, request);
        }

        pub fn cancelTask(self: @This(), request_id: u64) void {
            self.host.sinkCancelTask(request_id);
        }

        pub fn debugAssertNode(self: @This(), elem_id: u64, active: bool, tag: ?[]const u8, parent_id: ?u64, children: []const u64, click_event: ?u64, input_event: ?u64, check_event: ?u64, pointer_down_event: ?u64, pointer_up_event: ?u64, pointer_enter_event: ?u64, pointer_leave_event: ?u64) void {
            self.host.sinkDebugAssertNode(elem_id, active, tag, parent_id, children, click_event, input_event, check_event, pointer_down_event, pointer_up_event, pointer_enter_event, pointer_leave_event);
        }
    };
}

test "event delivery derives native reasons from policy and fixed event traits" {
    const no_policy = EventPolicy.none;
    try std.testing.expectEqual(EventDeliveryReason.native_runtime_default, EventDelivery.derive(.auto, no_policy, .{}).reason);
    try std.testing.expectEqual(EventDeliveryReason.requested_native, EventDelivery.derive(.native, no_policy, .{}).reason);

    const capture_and_default = EventPolicy.fromBits(render.listener_option_capture | render.listener_option_prevent_default);
    try std.testing.expectEqual(EventDeliveryReason.capture_policy, EventDelivery.derive(.auto, capture_and_default, .{}).reason);

    const stop_immediate_and_stop = EventPolicy.fromBits(render.listener_option_stop_immediate | render.listener_option_stop_propagation);
    try std.testing.expectEqual(EventDeliveryReason.stop_immediate_policy, EventDelivery.derive(.auto, stop_immediate_and_stop, .{}).reason);

    const prevent_default = EventPolicy.fromBits(render.listener_option_prevent_default);
    try std.testing.expectEqual(EventDeliveryReason.pointer_drag, EventDelivery.derive(.auto, prevent_default, .{ .pointer_drag = true }).reason);
    try std.testing.expectEqual(EventDeliveryReason.prevent_default_policy, EventDelivery.derive(.auto, no_policy, .{ .prevent_default_for_pointer_events = true }).reason);

    const once = EventPolicy.fromBits(render.listener_option_once);
    try std.testing.expectEqual(EventDeliveryReason.once_policy, EventDelivery.derive(.auto, once, .{}).reason);

    const passive = EventPolicy.fromBits(render.listener_option_passive);
    try std.testing.expectEqual(EventDeliveryReason.passive_policy, EventDelivery.derive(.auto, passive, .{}).reason);

    const self_filter = EventPolicy.fromBits(render.listener_option_self | render.listener_option_trusted);
    try std.testing.expectEqual(EventDeliveryReason.self_filter, EventDelivery.derive(.auto, self_filter, .{}).reason);
}

test "fixed event compact opcode requires empty policy and canonical descriptor" {
    const canonical = EventBinding{
        .event_id = 1,
        .payload_descriptor = BoundaryPayloadDescriptor.init(.unit, .none),
    };
    try std.testing.expect(canonical.canUseFixedOpcode(.pointer_down));

    const payload_override = EventBinding{
        .event_id = 2,
        .payload_descriptor = BoundaryPayloadDescriptor.init(.str, .target_value),
    };
    try std.testing.expect(!payload_override.canUseFixedOpcode(.pointer_down));

    const policy_override = EventBinding{
        .event_id = 3,
        .policy = EventPolicy.fromBits(render.listener_option_once),
        .payload_descriptor = BoundaryPayloadDescriptor.init(.unit, .none),
    };
    try std.testing.expect(!policy_override.canUseFixedOpcode(.pointer_down));
}

test "event delivery maps to browser wire ids" {
    const delivery = (EventDelivery{
        .requested = .auto,
        .effective = .native,
        .reason = .stop_immediate_policy,
    }).toWire();
    try std.testing.expectEqual(render.EventDeliveryRequestWire.auto, delivery.requested);
    try std.testing.expectEqual(render.EventDeliveryEffectiveWire.native, delivery.effective);
    try std.testing.expectEqual(render.EventDeliveryReasonWire.stop_immediate_policy, delivery.reason);
}

test "DomSink forwards every render seam method to the host" {
    const TestHost = struct {
        seen: u32 = 0,
        last_event_descriptor: BoundaryPayloadDescriptor = BoundaryPayloadDescriptor.init(.unit, .none),
        last_task_name: []const u8 = "",
        last_task_request: []const u8 = "",
        last_children_len: usize = 0,
        last_debug_children_len: usize = 0,
        saw_fixed_bind: bool = false,
        saw_named_bind: bool = false,
        saw_fixed_clear: bool = false,
        saw_named_clear: bool = false,

        fn mark(self: *@This(), bit: u5) void {
            self.seen |= @as(u32, 1) << bit;
        }

        pub fn sinkReset(self: *@This()) void {
            self.mark(0);
        }

        pub fn sinkAppendNode(self: *@This(), _: u64, _: u64, _: []const u8) void {
            self.mark(1);
        }

        pub fn sinkEnsureNode(self: *@This(), _: u64, _: []const u8) void {
            self.mark(2);
        }

        pub fn sinkRemoveNode(self: *@This(), _: u64) void {
            self.mark(3);
        }

        pub fn sinkReplaceChildren(self: *@This(), _: u64, children: []const u64) void {
            self.mark(4);
            self.last_children_len = children.len;
        }

        pub fn sinkReplaceChildrenForMoves(self: *@This(), _: u64, _: []const u64) void {
            self.mark(5);
        }

        pub fn sinkApplyTextField(self: *@This(), _: u64, _: TextField, _: []const u8) void {
            self.mark(6);
        }

        pub fn sinkApplyTextAttr(self: *@This(), _: u64, _: []const u8, _: []const u8) void {
            self.mark(17);
        }

        pub fn sinkApplyBoolField(self: *@This(), _: u64, _: BoolField, _: bool) void {
            self.mark(7);
        }

        pub fn sinkClearTextField(self: *@This(), _: u64, _: TextField) void {
            self.mark(8);
        }

        pub fn sinkClearTextAttr(self: *@This(), _: u64, _: []const u8) void {
            self.mark(18);
        }

        pub fn sinkClearBoolField(self: *@This(), _: u64, _: BoolField) void {
            self.mark(9);
        }

        pub fn sinkBindEvent(self: *@This(), command: EventBindCommand) void {
            self.mark(10);
            self.last_event_descriptor = command.binding.payload_descriptor;
            switch (command.key) {
                .fixed => self.saw_fixed_bind = true,
                .named => self.saw_named_bind = true,
            }
        }

        pub fn sinkClearEvent(self: *@This(), command: EventClearCommand) void {
            self.mark(11);
            switch (command.key) {
                .fixed => self.saw_fixed_clear = true,
                .named => self.saw_named_clear = true,
            }
        }

        pub fn sinkStartInterval(self: *@This(), _: u64, _: u64) void {
            self.mark(12);
        }

        pub fn sinkCancelInterval(self: *@This(), _: u64) void {
            self.mark(13);
        }

        pub fn sinkStartTask(self: *@This(), _: u64, task_name: []const u8, request: []const u8) void {
            self.mark(14);
            self.last_task_name = task_name;
            self.last_task_request = request;
        }

        pub fn sinkCancelTask(self: *@This(), _: u64) void {
            self.mark(15);
        }

        pub fn sinkDebugAssertNode(self: *@This(), _: u64, _: bool, _: ?[]const u8, _: ?u64, children: []const u64, _: ?u64, _: ?u64, _: ?u64, _: ?u64, _: ?u64, _: ?u64, _: ?u64) void {
            self.mark(16);
            self.last_debug_children_len = children.len;
        }
    };

    var host: TestHost = .{};
    const sink: DomSink(TestHost) = .{ .host = &host };
    const children = [_]u64{ 3, 4 };

    sink.reset();
    sink.appendNode(1, 0, "div");
    sink.ensureNode(1, "div");
    sink.removeNode(9);
    sink.replaceChildren(1, &children);
    sink.replaceChildrenForMoves(1, &children);
    sink.applyTextField(1, .text, "hello");
    sink.applyTextAttr(1, "data-state", "ready");
    sink.applyBoolField(1, .disabled, true);
    sink.clearTextField(1, .label);
    sink.clearTextAttr(1, "data-state");
    sink.clearBoolField(1, .checked);
    sink.bindEvent(1, .{ .fixed = .input }, .{
        .event_id = 7,
        .payload_descriptor = BoundaryPayloadDescriptor.init(.str, .target_value),
    });
    sink.clearEvent(1, .{ .fixed = .input });
    sink.bindEvent(1, .{ .named = "keydown" }, .{
        .event_id = 8,
        .payload_descriptor = BoundaryPayloadDescriptor.init(.bytes, .record_key_shift),
    });
    sink.clearEvent(1, .{ .named = "keydown" });
    sink.startInterval(8, 1000);
    sink.cancelInterval(8);
    sink.startTask(9, "lookup", "roc");
    sink.cancelTask(9);
    sink.debugAssertNode(1, true, "div", 0, &children, 7, null, null, null, null, null, null);

    try std.testing.expectEqual((@as(u32, 1) << 19) - 1, host.seen);
    try std.testing.expectEqual(@as(usize, 2), host.last_children_len);
    try std.testing.expectEqual(@as(usize, 2), host.last_debug_children_len);
    try std.testing.expectEqual(BoundaryPayloadDescriptor.init(.bytes, .record_key_shift), host.last_event_descriptor);
    try std.testing.expect(host.saw_fixed_bind);
    try std.testing.expect(host.saw_named_bind);
    try std.testing.expect(host.saw_fixed_clear);
    try std.testing.expect(host.saw_named_clear);
    try std.testing.expectEqualStrings("lookup", host.last_task_name);
    try std.testing.expectEqualStrings("roc", host.last_task_request);
}
