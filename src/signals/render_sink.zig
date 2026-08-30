//! Host-facing render sink interface for the shared Signals engine.
//!
//! This is intentionally a thin generic adapter. Slice 4d starts by routing the
//! native simulated DOM through this sink without changing behavior; later
//! slices move render decisions into the engine while each host keeps its own
//! concrete sink implementation.

const std = @import("std");
const boundary = @import("boundary.zig");
const render = @import("render_commands.zig");
const ids = @import("ids.zig");

pub const ElemId = ids.ElemId;
pub const EventId = ids.EventId;
pub const TaskRequestId = ids.TaskRequestId;
pub const IntervalToken = ids.IntervalToken;

pub const TextField = render.TextField;
pub const BoolField = render.BoolField;
pub const EventKind = render.EventKind;
pub const EventPolicy = render.EventPolicy;
pub const BoundaryPayloadDescriptor = boundary.BoundaryPayloadDescriptor;
pub const Counts = render.Counts;
pub const LocationSnapshot = boundary.LocationSnapshot;
pub const StorageArea = boundary.StorageArea;

pub const NavigationKind = enum {
    push,
    replace,
};

pub const EventBindingKey = union(enum) {
    fixed: EventKind,
    named: []const u8,

    /// Derives effective event delivery and its reason from the canonical policy.
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

    /// Derives canonical event-delivery metadata before render-cache publication.
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

    /// Compares values through their owning capability rather than inspecting erased bytes.
    pub fn eql(self: EventDelivery, other: EventDelivery) bool {
        return self.requested == other.requested and
            self.effective == other.effective and
            self.reason == other.reason;
    }

    /// Encodes validated delivery metadata into the versioned browser wire representation.
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
    event_id: EventId,
    policy: EventPolicy = EventPolicy.none,
    delivery: EventDelivery = .{},
    payload_descriptor: BoundaryPayloadDescriptor,

    /// Returns the canonical binding with effective delivery derived from its policy.
    pub fn withDeliveryFor(self: EventBinding, key: EventBindingKey) EventBinding {
        var next = self;
        next.delivery = key.deliveryFor(next.delivery.requested, next.policy);
        return next;
    }

    /// Compares values through their owning capability rather than inspecting erased bytes.
    pub fn eql(self: EventBinding, other: EventBinding) bool {
        return self.event_id == other.event_id and
            self.policy.eql(other.policy) and
            self.delivery.eql(other.delivery) and
            self.payload_descriptor.eql(other.payload_descriptor);
    }

    /// Reports whether this binding exactly matches the compact fixed-event wire contract.
    pub fn canUseFixedOpcode(self: EventBinding, kind: EventKind) bool {
        return self.policy.isNone() and self.payload_descriptor.eql(kind.payloadDescriptor());
    }
};

pub const EventBindCommand = struct {
    elem_id: ElemId,
    key: EventBindingKey,
    binding: EventBinding,
};

pub const EventClearCommand = struct {
    elem_id: ElemId,
    key: EventBindingKey,
};

/// Builds the thin DOM-command adapter consumed by the shared engine.
pub fn DomSink(comptime Host: type) type {
    return struct {
        host: *Host,

        /// Stages a complete render-surface reset in the host command sink.
        pub fn reset(self: @This()) void {
            self.host.sinkReset();
        }

        /// Preflights sink capacity for all nodes in the pending command transaction.
        pub fn reserveNodes(self: @This(), capacity: usize) void {
            self.host.sinkReserveNodes(capacity);
        }

        /// Emits the already-decided command that attaches a newly created render node.
        pub fn appendNode(self: @This(), elem_id: ElemId, parent_elem_id: ElemId, tag: []const u8) void {
            self.host.sinkAppendNode(elem_id, parent_elem_id, tag);
        }

        /// Ensures the host render surface contains the engine-selected node and tag.
        pub fn ensureNode(self: @This(), elem_id: ElemId, tag: []const u8) void {
            self.host.sinkEnsureNode(elem_id, tag);
        }

        /// Emits removal of a node whose owning scope has already been disposed by the engine.
        pub fn removeNode(self: @This(), elem_id: ElemId) void {
            self.host.sinkRemoveNode(elem_id);
        }

        /// Publishes the engine-selected child order for one parent.
        pub fn replaceChildren(self: @This(), parent_elem_id: ElemId, next_child_ids: []const ElemId) void {
            self.host.sinkReplaceChildren(parent_elem_id, next_child_ids);
        }

        /// Publishes a moves-only child reorder without rebuilding surviving row structure.
        pub fn replaceChildrenForMoves(self: @This(), parent_elem_id: ElemId, next_child_ids: []const ElemId) void {
            self.host.sinkReplaceChildrenForMoves(parent_elem_id, next_child_ids);
        }

        /// Applies an engine-decided text field value to one render node.
        pub fn applyTextField(self: @This(), elem_id: ElemId, field: TextField, value: []const u8) void {
            self.host.sinkApplyTextField(elem_id, field, value);
        }

        /// Applies an engine-decided custom text attribute to one render node.
        pub fn applyTextAttr(self: @This(), elem_id: ElemId, name: []const u8, value: []const u8) void {
            self.host.sinkApplyTextAttr(elem_id, name, value);
        }

        /// Applies an engine-decided boolean field value to one render node.
        pub fn applyBoolField(self: @This(), elem_id: ElemId, field: BoolField, value: bool) void {
            self.host.sinkApplyBoolField(elem_id, field, value);
        }

        /// Clears an engine-decided text field from one render node.
        pub fn clearTextField(self: @This(), elem_id: ElemId, field: TextField) void {
            self.host.sinkClearTextField(elem_id, field);
        }

        /// Clears an engine-decided custom text attribute from one render node.
        pub fn clearTextAttr(self: @This(), elem_id: ElemId, name: []const u8) void {
            self.host.sinkClearTextAttr(elem_id, name);
        }

        /// Clears an engine-decided boolean field from one render node.
        pub fn clearBoolField(self: @This(), elem_id: ElemId, field: BoolField) void {
            self.host.sinkClearBoolField(elem_id, field);
        }

        /// Publishes a validated canonical event binding selected by the engine.
        pub fn bindEvent(self: @This(), elem_id: ElemId, key: EventBindingKey, binding: EventBinding) void {
            self.host.sinkBindEvent(.{ .elem_id = elem_id, .key = key, .binding = binding });
        }

        /// Removes a host event registration whose engine-owned binding is no longer active.
        pub fn clearEvent(self: @This(), elem_id: ElemId, key: EventBindingKey) void {
            self.host.sinkClearEvent(.{ .elem_id = elem_id, .key = key });
        }

        /// Starts the bounded host registration for an engine-owned interval source.
        pub fn startInterval(self: @This(), token: IntervalToken, period_ms: u64) void {
            self.host.sinkStartInterval(token, period_ms);
        }

        /// Cancels the host registration for an interval whose owning scope is no longer active.
        pub fn cancelInterval(self: @This(), token: IntervalToken) void {
            self.host.sinkCancelInterval(token);
        }

        /// Starts bounded asynchronous host work for an engine-issued task request.
        pub fn startTask(self: @This(), request_id: TaskRequestId, task_name: []const u8, request: []const u8) void {
            self.host.sinkStartTask(request_id, task_name, request);
        }

        /// Cancels host work for a task request retired by engine lifecycle policy.
        pub fn cancelTask(self: @This(), request_id: TaskRequestId) void {
            self.host.sinkCancelTask(request_id);
        }

        /// Applies an engine-issued browser-history command without deriving routing semantics.
        pub fn navigate(self: @This(), kind: NavigationKind, location: LocationSnapshot) void {
            self.host.sinkNavigate(kind, location);
        }

        /// Applies the document title already selected by graph propagation.
        pub fn setDocumentTitle(self: @This(), title: []const u8) void {
            self.host.sinkSetDocumentTitle(title);
        }

        /// Writes one engine-issued text value to the selected browser storage area.
        pub fn setStorageText(self: @This(), area: StorageArea, key: []const u8, value: []const u8) void {
            self.host.sinkSetStorageText(area, key, value);
        }

        /// Removes one engine-issued key from the selected browser storage area.
        pub fn removeStorage(self: @This(), area: StorageArea, key: []const u8) void {
            self.host.sinkRemoveStorage(area, key);
        }

        /// Checks that the host render surface matches the engine's committed node metadata.
        pub fn debugAssertNode(self: @This(), elem_id: ElemId, active: bool, tag: ?[]const u8, parent_id: ?ElemId, children: []const ElemId, click_event: ?EventId, input_event: ?EventId, check_event: ?EventId, pointer_down_event: ?EventId, pointer_up_event: ?EventId, pointer_enter_event: ?EventId, pointer_leave_event: ?EventId) void {
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
        .event_id = EventId.fromRaw(1),
        .payload_descriptor = BoundaryPayloadDescriptor.init(.unit, .none),
    };
    try std.testing.expect(canonical.canUseFixedOpcode(.pointer_down));

    const payload_override = EventBinding{
        .event_id = EventId.fromRaw(2),
        .payload_descriptor = BoundaryPayloadDescriptor.init(.str, .target_value),
    };
    try std.testing.expect(!payload_override.canUseFixedOpcode(.pointer_down));

    const policy_override = EventBinding{
        .event_id = EventId.fromRaw(3),
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
        last_dynamic_value: []const u8 = "",
        last_children_len: usize = 0,
        last_debug_children_len: usize = 0,
        saw_fixed_bind: bool = false,
        saw_named_bind: bool = false,
        saw_fixed_clear: bool = false,
        saw_named_clear: bool = false,

        fn mark(self: *@This(), bit: u5) void {
            self.seen |= @as(u32, 1) << bit;
        }

        /// Adapts the shared engine's reset command to this host without re-deciding reactive meaning.
        pub fn sinkReset(self: *@This()) void {
            self.mark(0);
        }

        /// Adapts the shared engine's append node command to this host without re-deciding reactive meaning.
        pub fn sinkAppendNode(self: *@This(), _: ElemId, _: ElemId, _: []const u8) void {
            self.mark(1);
        }

        /// Adapts the shared engine's ensure node command to this host without re-deciding reactive meaning.
        pub fn sinkEnsureNode(self: *@This(), _: ElemId, _: []const u8) void {
            self.mark(2);
        }

        /// Adapts the shared engine's remove node command to this host without re-deciding reactive meaning.
        pub fn sinkRemoveNode(self: *@This(), _: ElemId) void {
            self.mark(3);
        }

        /// Adapts the shared engine's replace children command to this host without re-deciding reactive meaning.
        pub fn sinkReplaceChildren(self: *@This(), _: ElemId, children: []const ElemId) void {
            self.mark(4);
            self.last_children_len = children.len;
        }

        /// Adapts the shared engine's replace children for moves command to this host without re-deciding reactive meaning.
        pub fn sinkReplaceChildrenForMoves(self: *@This(), _: ElemId, _: []const ElemId) void {
            self.mark(5);
        }

        /// Adapts the shared engine's apply text field command to this host without re-deciding reactive meaning.
        pub fn sinkApplyTextField(self: *@This(), _: ElemId, _: TextField, _: []const u8) void {
            self.mark(6);
        }

        /// Adapts the shared engine's apply text attr command to this host without re-deciding reactive meaning.
        pub fn sinkApplyTextAttr(self: *@This(), _: ElemId, _: []const u8, _: []const u8) void {
            self.mark(17);
        }

        /// Adapts the shared engine's apply bool field command to this host without re-deciding reactive meaning.
        pub fn sinkApplyBoolField(self: *@This(), _: ElemId, _: BoolField, _: bool) void {
            self.mark(7);
        }

        /// Adapts the shared engine's clear text field command to this host without re-deciding reactive meaning.
        pub fn sinkClearTextField(self: *@This(), _: ElemId, _: TextField) void {
            self.mark(8);
        }

        /// Adapts the shared engine's clear text attr command to this host without re-deciding reactive meaning.
        pub fn sinkClearTextAttr(self: *@This(), _: ElemId, _: []const u8) void {
            self.mark(18);
        }

        /// Adapts the shared engine's clear bool field command to this host without re-deciding reactive meaning.
        pub fn sinkClearBoolField(self: *@This(), _: ElemId, _: BoolField) void {
            self.mark(9);
        }

        /// Adapts the shared engine's bind event command to this host without re-deciding reactive meaning.
        pub fn sinkBindEvent(self: *@This(), command: EventBindCommand) void {
            self.mark(10);
            self.last_event_descriptor = command.binding.payload_descriptor;
            switch (command.key) {
                .fixed => self.saw_fixed_bind = true,
                .named => self.saw_named_bind = true,
            }
        }

        /// Adapts the shared engine's clear event command to this host without re-deciding reactive meaning.
        pub fn sinkClearEvent(self: *@This(), command: EventClearCommand) void {
            self.mark(11);
            switch (command.key) {
                .fixed => self.saw_fixed_clear = true,
                .named => self.saw_named_clear = true,
            }
        }

        /// Adapts the shared engine's start interval command to this host without re-deciding reactive meaning.
        pub fn sinkStartInterval(self: *@This(), _: IntervalToken, _: u64) void {
            self.mark(12);
        }

        /// Adapts the shared engine's cancel interval command to this host without re-deciding reactive meaning.
        pub fn sinkCancelInterval(self: *@This(), _: IntervalToken) void {
            self.mark(13);
        }

        /// Adapts the shared engine's start task command to this host without re-deciding reactive meaning.
        pub fn sinkStartTask(self: *@This(), _: TaskRequestId, task_name: []const u8, request: []const u8) void {
            self.mark(14);
            self.last_task_name = task_name;
            self.last_task_request = request;
        }

        /// Adapts the shared engine's cancel task command to this host without re-deciding reactive meaning.
        pub fn sinkCancelTask(self: *@This(), _: TaskRequestId) void {
            self.mark(15);
        }

        /// Adapts the shared engine's navigate command to this host without re-deciding reactive meaning.
        pub fn sinkNavigate(self: *@This(), kind: NavigationKind, location: LocationSnapshot) void {
            self.mark(19);
            self.last_task_name = switch (kind) {
                .push => "push",
                .replace => "replace",
            };
            self.last_task_request = location.path;
        }

        /// Adapts the shared engine's set document title command to this host without re-deciding reactive meaning.
        pub fn sinkSetDocumentTitle(self: *@This(), title: []const u8) void {
            self.mark(22);
            self.last_task_name = "title";
            self.last_task_request = title;
        }

        /// Adapts the shared engine's set storage text command to this host without re-deciding reactive meaning.
        pub fn sinkSetStorageText(self: *@This(), area: StorageArea, key: []const u8, value: []const u8) void {
            self.mark(20);
            self.last_task_name = switch (area) {
                .local => "local",
                .session => "session",
            };
            self.last_task_request = key;
            self.last_dynamic_value = value;
        }

        /// Adapts the shared engine's remove storage command to this host without re-deciding reactive meaning.
        pub fn sinkRemoveStorage(self: *@This(), area: StorageArea, key: []const u8) void {
            self.mark(21);
            self.last_task_name = switch (area) {
                .local => "local",
                .session => "session",
            };
            self.last_task_request = key;
        }

        /// Adapts the shared engine's debug assert node command to this host without re-deciding reactive meaning.
        pub fn sinkDebugAssertNode(self: *@This(), _: ElemId, _: bool, _: ?[]const u8, _: ?ElemId, children: []const ElemId, _: ?EventId, _: ?EventId, _: ?EventId, _: ?EventId, _: ?EventId, _: ?EventId, _: ?EventId) void {
            self.mark(16);
            self.last_debug_children_len = children.len;
        }
    };

    var host: TestHost = .{};
    const sink: DomSink(TestHost) = .{ .host = &host };
    const children = [_]ElemId{ ElemId.fromRaw(3), ElemId.fromRaw(4) };
    const elem = ElemId.fromRaw(1);

    sink.reset();
    sink.appendNode(elem, ids.root_elem, "div");
    sink.ensureNode(elem, "div");
    sink.removeNode(ElemId.fromRaw(9));
    sink.replaceChildren(elem, &children);
    sink.replaceChildrenForMoves(elem, &children);
    sink.applyTextField(elem, .text, "hello");
    sink.applyTextAttr(elem, "data-state", "ready");
    sink.applyBoolField(elem, .disabled, true);
    sink.clearTextField(elem, .label);
    sink.clearTextAttr(elem, "data-state");
    sink.clearBoolField(elem, .checked);
    sink.bindEvent(elem, .{ .fixed = .input }, .{
        .event_id = EventId.fromRaw(7),
        .payload_descriptor = BoundaryPayloadDescriptor.init(.str, .target_value),
    });
    sink.clearEvent(elem, .{ .fixed = .input });
    sink.bindEvent(elem, .{ .named = "keydown" }, .{
        .event_id = EventId.fromRaw(8),
        .payload_descriptor = BoundaryPayloadDescriptor.init(.bytes, .record_key_shift),
    });
    sink.clearEvent(elem, .{ .named = "keydown" });
    sink.startInterval(IntervalToken.fromRaw(8), 1000);
    sink.cancelInterval(IntervalToken.fromRaw(8));
    sink.startTask(TaskRequestId.fromRaw(9), "lookup", "roc");
    sink.cancelTask(TaskRequestId.fromRaw(9));
    sink.setStorageText(.local, "checkout:draft", "saved");
    sink.removeStorage(.session, "checkout:flash");
    sink.navigate(.replace, .{ .path = "/done", .query = "tab=1", .hash = "tail" });
    sink.debugAssertNode(elem, true, "div", ids.root_elem, &children, EventId.fromRaw(7), null, null, null, null, null, null);

    try std.testing.expectEqual((@as(u32, 1) << 22) - 1, host.seen);
    try std.testing.expectEqual(@as(usize, 2), host.last_children_len);
    try std.testing.expectEqual(@as(usize, 2), host.last_debug_children_len);
    try std.testing.expectEqual(BoundaryPayloadDescriptor.init(.bytes, .record_key_shift), host.last_event_descriptor);
    try std.testing.expect(host.saw_fixed_bind);
    try std.testing.expect(host.saw_named_bind);
    try std.testing.expect(host.saw_fixed_clear);
    try std.testing.expect(host.saw_named_clear);
    try std.testing.expectEqualStrings("replace", host.last_task_name);
    try std.testing.expectEqualStrings("/done", host.last_task_request);
    try std.testing.expectEqualStrings("saved", host.last_dynamic_value);
}
