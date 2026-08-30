//! Typed views over generated Roc ABI descriptors used by the engine.

const std = @import("std");

const abi = @import("roc_platform_abi.zig");
const boundary = @import("boundary.zig");
const render = @import("render_commands.zig");
const render_sink = @import("render_sink.zig");
const retained = @import("retained_values.zig");
const roles = @import("callable_roles.zig");

pub const HostValueCapability = retained.HostValueCapability;
pub const HostTextRead = retained.HostTextRead;
pub const HostBoolRead = retained.HostBoolRead;
pub const HostEventReducer = retained.HostEventReducer;
pub const HostEachOps = retained.HostEachOps;

pub const node_text_field_custom: u64 = 7;
pub const node_bool_field_custom: u64 = 3;

pub const TextField = render.TextField;
pub const BoolField = render.BoolField;
pub const EventKind = render.EventKind;
pub const EventPolicy = render.EventPolicy;
pub const EventDeliveryRequest = render_sink.EventDeliveryRequest;
pub const EventPayloadKind = boundary.PayloadKind;
pub const EventExtractionPlanKind = boundary.EventExtractionPlanKind;
pub const BoundaryPayloadDescriptor = boundary.BoundaryPayloadDescriptor;

pub const RocStrView = struct {
    value: abi.RocStr,

    /// Builds a borrowed typed view over a previously validated raw ABI record.
    pub fn fromAbi(value: abi.RocStr) RocStrView {
        return .{ .value = value };
    }

    /// Returns a borrowed slice over validated ABI list storage without taking ownership.
    pub fn asSlice(self: *const RocStrView) []const u8 {
        return self.value.asSlice();
    }
};

pub const SignalToken = struct {
    callable: retained.HostSignalToken,

    /// Builds a borrowed typed view over a previously validated raw ABI record.
    pub fn fromAbi(callable: abi.RocErasedCallable) SignalToken {
        return .{ .callable = retained.hostSignalTokenFromCallable(callable) };
    }
};

pub const StateBinderToken = struct {
    callable: retained.HostSignalToken,

    /// Builds a borrowed typed view over a previously validated raw ABI record.
    pub fn fromAbi(callable: abi.RocErasedCallable) StateBinderToken {
        return .{ .callable = retained.hostSignalTokenFromCallable(callable) };
    }
};

fn validateIdentityCallable(token: SignalToken, evaluator: abi.RocErasedCallable) void {
    if (token.callable != retained.hostSignalTokenFromCallable(evaluator)) {
        @panic("signal identity callable did not match its evaluator");
    }
}

pub const SignalRef = struct {
    binder: StateBinderToken,
};

pub const ConstValueSignal = struct {
    token: SignalToken,
    init: roles.Initializer,
    capability: HostValueCapability,
};

pub const MapSignal = struct {
    token: SignalToken,
    input: *const abi.NodeSignalExpr,
    transform: roles.Transform,
    capability: HostValueCapability,
};

pub const Map2Signal = struct {
    token: SignalToken,
    left: *const abi.NodeSignalExpr,
    right: *const abi.NodeSignalExpr,
    transform: roles.Transform,
    capability: HostValueCapability,
};

pub const CombineSignal = struct {
    token: SignalToken,
    children: []const abi.NodeSignalExpr,
    transform: roles.Transform,
    capability: HostValueCapability,
};

pub const SelectSignal = struct {
    token: SignalToken,
    input: *const abi.NodeSignalExpr,
    key: RocStrView,
    input_read: HostTextRead,
    false_init: roles.Initializer,
    true_init: roles.Initializer,
    capability: HostValueCapability,
};

pub const TaskSourceSignal = struct {
    token: SignalToken,
    name: RocStrView,
    payload_capability: HostValueCapability,
    initial: roles.Initializer,
    done: roles.Transform,
    failed: roles.Transform,
    capability: HostValueCapability,
    reset_on_start: bool,
};

pub const IntervalSourceSignal = struct {
    token: SignalToken,
    period_ms: u64,
    initial: roles.Initializer,
    tick: roles.Transform,
    capability: HostValueCapability,
};

pub const LocationSourceSignal = struct {
    token: SignalToken,
    from_payload: roles.Transform,
    capability: HostValueCapability,
    payload_capability: HostValueCapability,
};

pub const VisibilitySourceSignal = struct {
    token: SignalToken,
    from_payload: roles.Transform,
    capability: HostValueCapability,
    payload_capability: HostValueCapability,
};

pub const OnlineSourceSignal = struct {
    token: SignalToken,
    from_payload: roles.Transform,
    capability: HostValueCapability,
    payload_capability: HostValueCapability,
};

pub const StorageSourceSignal = struct {
    token: SignalToken,
    area: boundary.StorageArea,
    key: RocStrView,
    from_payload: roles.Transform,
    capability: HostValueCapability,
    payload_capability: HostValueCapability,
};

pub const SignalExpr = union(enum) {
    ref: SignalRef,
    const_value: ConstValueSignal,
    map: MapSignal,
    map2: Map2Signal,
    select: SelectSignal,
    combine: CombineSignal,
    task_source: TaskSourceSignal,
    interval_source: IntervalSourceSignal,
    location_source: LocationSourceSignal,
    online_source: OnlineSourceSignal,
    visibility_source: VisibilitySourceSignal,
    storage_source: StorageSourceSignal,

    /// Builds a borrowed typed view over a previously validated raw ABI record.
    pub fn fromAbi(expr: abi.NodeSignalExpr) SignalExpr {
        return switch (expr.tag) {
            .Ref => .{ .ref = .{
                .binder = StateBinderToken.fromAbi(expr.payload_ref()),
            } },
            .ConstValue => blk: {
                const payload = expr.payload_const_value();
                const token = SignalToken.fromAbi(payload._0);
                validateIdentityCallable(token, payload._1);
                break :blk .{ .const_value = .{
                    .token = token,
                    .init = .fromAbi(payload._1),
                    .capability = payload._2,
                } };
            },
            .Map => blk: {
                const payload = expr.payload_map();
                const token = SignalToken.fromAbi(payload._0);
                validateIdentityCallable(token, payload._2);
                break :blk .{ .map = .{
                    .token = token,
                    .input = payload._1,
                    .transform = .fromAbi(payload._2),
                    .capability = payload._3,
                } };
            },
            .Map2 => blk: {
                const payload = expr.payload_map2();
                const token = SignalToken.fromAbi(payload._0);
                validateIdentityCallable(token, payload._3);
                break :blk .{ .map2 = .{
                    .token = token,
                    .left = payload._1,
                    .right = payload._2,
                    .transform = .fromAbi(payload._3),
                    .capability = payload._4,
                } };
            },
            .Select => blk: {
                const payload = expr.payload_select();
                const token = SignalToken.fromAbi(payload._0);
                validateIdentityCallable(token, payload._4);
                break :blk .{ .select = .{
                    .token = token,
                    .input = payload._1,
                    .key = RocStrView.fromAbi(payload._2),
                    .input_read = payload._3,
                    .false_init = .fromAbi(payload._4),
                    .true_init = .fromAbi(payload._5),
                    .capability = payload._6,
                } };
            },
            .Combine => blk: {
                const payload = expr.payload_combine();
                const token = SignalToken.fromAbi(payload._0);
                validateIdentityCallable(token, payload._2);
                break :blk .{ .combine = .{
                    .token = token,
                    .children = payload._1.items(),
                    .transform = .fromAbi(payload._2),
                    .capability = payload._3,
                } };
            },
            .TaskSource => blk: {
                const payload = expr.payload_task_source();
                const token = SignalToken.fromAbi(payload.token);
                validateIdentityCallable(token, payload.initial);
                break :blk .{ .task_source = .{
                    .token = token,
                    .name = RocStrView.fromAbi(payload.name),
                    .payload_capability = payload.payload_cap,
                    .initial = .fromAbi(payload.initial),
                    .done = .fromAbi(payload.done),
                    .failed = .fromAbi(payload.failed),
                    .capability = payload.cap,
                    .reset_on_start = payload.reset_on_start,
                } };
            },
            .IntervalSource => blk: {
                const payload = expr.payload_interval_source();
                const token = SignalToken.fromAbi(payload.token);
                validateIdentityCallable(token, payload.initial);
                break :blk .{ .interval_source = .{
                    .token = token,
                    .period_ms = payload.period_ms,
                    .initial = .fromAbi(payload.initial),
                    .tick = .fromAbi(payload.tick),
                    .capability = payload.cap,
                } };
            },
            .LocationSource => blk: {
                const payload = expr.payload_location_source();
                const token = SignalToken.fromAbi(payload._0);
                validateIdentityCallable(token, payload._1);
                break :blk .{ .location_source = .{
                    .token = token,
                    .from_payload = .fromAbi(payload._1),
                    .capability = payload._2,
                    .payload_capability = payload._3,
                } };
            },
            .VisibilitySource => blk: {
                const payload = expr.payload_visibility_source();
                const token = SignalToken.fromAbi(payload._0);
                validateIdentityCallable(token, payload._1);
                break :blk .{ .visibility_source = .{
                    .token = token,
                    .from_payload = .fromAbi(payload._1),
                    .capability = payload._2,
                    .payload_capability = payload._3,
                } };
            },
            .OnlineSource => blk: {
                const payload = expr.payload_online_source();
                const token = SignalToken.fromAbi(payload._0);
                validateIdentityCallable(token, payload._1);
                break :blk .{ .online_source = .{
                    .token = token,
                    .from_payload = .fromAbi(payload._1),
                    .capability = payload._2,
                    .payload_capability = payload._3,
                } };
            },
            .StorageSource => blk: {
                const payload = expr.payload_storage_source();
                const area = boundary.StorageArea.fromId(payload._1) orelse @panic("StorageSource referenced an unknown storage area");
                const token = SignalToken.fromAbi(payload._0);
                validateIdentityCallable(token, payload._3);
                break :blk .{ .storage_source = .{
                    .token = token,
                    .area = area,
                    .key = RocStrView.fromAbi(payload._2),
                    .from_payload = .fromAbi(payload._3),
                    .capability = payload._4,
                    .payload_capability = payload._5,
                } };
            },
        };
    }
};

pub const TextAttrTarget = union(enum) {
    fixed: TextField,
    custom: RocStrView,

    /// Builds a borrowed typed view over a previously validated raw ABI record.
    pub fn fromAbi(field: abi.NodeTextField, name: abi.RocStr) TextAttrTarget {
        const field_id = field.id;
        const name_slice = name.asSlice();
        if (field_id == node_text_field_custom) {
            if (name_slice.len == 0) @panic("custom text attr descriptor used an empty name");
            return .{ .custom = RocStrView.fromAbi(name) };
        }
        if (name_slice.len != 0) @panic("fixed text attr descriptor carried a custom name");
        return .{ .fixed = textFieldFromAbi(field_id) };
    }
};

pub const BoolAttrTarget = union(enum) {
    fixed: BoolField,
    custom: RocStrView,

    /// Builds a borrowed typed view over a previously validated raw ABI record.
    pub fn fromAbi(field: abi.NodeBoolField, name: abi.RocStr) BoolAttrTarget {
        const field_id = field.id;
        const name_slice = name.asSlice();
        if (field_id == node_bool_field_custom) {
            if (name_slice.len == 0) @panic("custom bool attr descriptor used an empty name");
            return .{ .custom = RocStrView.fromAbi(name) };
        }
        if (name_slice.len != 0) @panic("fixed bool attr descriptor carried a custom name");
        return .{ .fixed = boolFieldFromAbi(field_id) };
    }
};

pub const StaticTextAttr = struct {
    target: TextAttrTarget,
    value: RocStrView,
};

pub const SignalTextAttr = struct {
    target: TextAttrTarget,
    signal: *const abi.NodeSignalExpr,
    read: HostTextRead,
};

pub const SignalOptionalTextAttr = struct {
    target: TextAttrTarget,
    signal: *const abi.NodeSignalExpr,
    present: HostBoolRead,
    read: HostTextRead,
};

pub const StaticBoolAttr = struct {
    target: BoolAttrTarget,
    value: bool,
};

pub const SignalBoolAttr = struct {
    target: BoolAttrTarget,
    signal: *const abi.NodeSignalExpr,
    read: HostBoolRead,
};

pub const EventMessage = struct {
    binder: StateBinderToken,
    read_binder: StateBinderToken,
    payload_descriptor: BoundaryPayloadDescriptor,
    payload_reducer: HostEventReducer,

    /// Builds a borrowed typed view over a previously validated raw ABI record.
    pub fn fromAbi(msg: anytype) EventMessage {
        return .{
            .binder = StateBinderToken.fromAbi(msg.binder),
            .read_binder = StateBinderToken.fromAbi(msg.read_binder),
            .payload_descriptor = boundary.boundaryPayloadDescriptorFromExtractionBytes(msg.event_extraction_plan.bytes.items()),
            .payload_reducer = msg.payload_reducer,
        };
    }
};

pub const EventAttr = struct {
    kind: EventKind,
    delivery_request: EventDeliveryRequest,
    msg: EventMessage,
};

pub const NamedEventAttr = struct {
    name: RocStrView,
    policy: EventPolicy,
    delivery_request: EventDeliveryRequest,
    msg: EventMessage,
};

/// Converts the raw ABI representation of event policy into the engine's exhaustive enum.
pub fn eventPolicyFromAbi(policy: abi.NodeEventBindingPolicy) EventPolicy {
    return .{
        .prevent_default = policy.prevent_default,
        .stop_propagation = policy.stop_propagation,
        .stop_immediate = policy.stop_immediate,
        .capture = policy.capture,
        .passive = policy.passive,
        .once = policy.once,
        .self = policy.self,
        .trusted = policy.trusted,
    };
}

/// Converts the raw ABI representation of event delivery request into the engine's exhaustive enum.
pub fn eventDeliveryRequestFromAbi(delivery: abi.NodeEventDelivery) EventDeliveryRequest {
    return if (delivery.native) .native else .auto;
}

pub const NodeAttr = union(enum) {
    static_text: StaticTextAttr,
    signal_text: SignalTextAttr,
    signal_optional_text: SignalOptionalTextAttr,
    static_bool: StaticBoolAttr,
    signal_bool: SignalBoolAttr,
    event: EventAttr,
    named_event: NamedEventAttr,

    /// Builds a borrowed typed view over a previously validated raw ABI record.
    pub fn fromAbi(attr: abi.NodeAttr) NodeAttr {
        return switch (attr.tag) {
            .StaticText => blk: {
                const payload = attr.payload_static_text();
                break :blk .{ .static_text = .{
                    .target = TextAttrTarget.fromAbi(payload.field, payload.name),
                    .value = RocStrView.fromAbi(payload.value),
                } };
            },
            .SignalText => blk: {
                const payload = attr.payload_signal_text();
                break :blk .{ .signal_text = .{
                    .target = TextAttrTarget.fromAbi(payload.field, payload.name),
                    .signal = payload.signal,
                    .read = payload.read,
                } };
            },
            .TextOptionalSignal => blk: {
                const payload = attr.payload_text_optional_signal();
                break :blk .{ .signal_optional_text = .{
                    .target = TextAttrTarget.fromAbi(payload.field, payload.name),
                    .signal = payload.signal,
                    .present = payload.present,
                    .read = payload.read,
                } };
            },
            .StaticBool => blk: {
                const payload = attr.payload_static_bool();
                break :blk .{ .static_bool = .{
                    .target = BoolAttrTarget.fromAbi(payload.field, payload.name),
                    .value = payload.value,
                } };
            },
            .SignalBool => blk: {
                const payload = attr.payload_signal_bool();
                break :blk .{ .signal_bool = .{
                    .target = BoolAttrTarget.fromAbi(payload.field, payload.name),
                    .signal = payload.signal,
                    .read = payload.read,
                } };
            },
            .On => blk: {
                const payload = attr.payload_on();
                const kind_id = payload.kind.id;
                const policy = eventPolicyFromAbi(payload.policy);
                if (kind_id == 0) {
                    if (payload.name.asSlice().len == 0) @panic("named event descriptor used an empty name");
                    break :blk .{ .named_event = .{
                        .name = RocStrView.fromAbi(payload.name),
                        .policy = policy,
                        .delivery_request = eventDeliveryRequestFromAbi(payload.delivery),
                        .msg = EventMessage.fromAbi(payload.msg),
                    } };
                }
                if (payload.name.asSlice().len != 0) @panic("fixed event descriptor carried a named event");
                if (!policy.isNone()) {
                    std.debug.panic("fixed event descriptor carried named event policy: kind_id={} policy_bits={} name_len={}", .{
                        kind_id,
                        policy.toWireBits(),
                        payload.name.asSlice().len,
                    });
                }
                break :blk .{ .event = .{
                    .kind = eventKindFromAbi(kind_id),
                    .delivery_request = eventDeliveryRequestFromAbi(payload.delivery),
                    .msg = EventMessage.fromAbi(payload.msg),
                } };
            },
        };
    }
};

pub const ElementElem = struct {
    tag: RocStrView,
    attrs: []const abi.NodeAttr,
    children: []const abi.Elem,
};

pub const TextElem = struct {
    text: RocStrView,
};

pub const TextSignalElem = struct {
    signal: *const abi.NodeSignalExpr,
    read: HostTextRead,
};

pub const CleanupElem = struct {
    name: RocStrView,
};

pub const OnChangeElem = struct {
    run_initial: bool,
    signal: *const abi.NodeSignalExpr,
    to_cmd: roles.CommandBuilder,
};

pub const OnMountElem = struct {
    to_cmd: roles.CommandBuilder,
};

pub const StateElem = struct {
    binder: StateBinderToken,
    initial: roles.Initializer,
    capability: HostValueCapability,
    child: *const abi.Elem,
};

pub const ComponentElem = struct {
    child: *const abi.Elem,
};

pub const WhenElem = struct {
    condition: *const abi.NodeSignalExpr,
    read: HostBoolRead,
    when_false: *const abi.Elem,
    when_true: *const abi.Elem,
};

pub const EachElem = struct {
    items: *const abi.NodeSignalExpr,
    ops: HostEachOps,
};

pub const Elem = union(enum) {
    element: ElementElem,
    text: TextElem,
    text_signal: TextSignalElem,
    cleanup: CleanupElem,
    on_change: OnChangeElem,
    on_mount: OnMountElem,
    state: StateElem,
    component: ComponentElem,
    when: WhenElem,
    each: EachElem,

    /// Builds a borrowed typed view over a previously validated raw ABI record.
    pub fn fromAbi(elem: abi.Elem) Elem {
        return switch (elem.tag) {
            .Element => blk: {
                const payload = elem.payload_element();
                break :blk .{ .element = .{
                    .tag = RocStrView.fromAbi(payload.tag),
                    .attrs = payload.attrs.items(),
                    .children = payload.children.items(),
                } };
            },
            .Text => .{ .text = .{
                .text = RocStrView.fromAbi(elem.payload_text()),
            } },
            .TextSignal => blk: {
                const payload = elem.payload_text_signal();
                break :blk .{ .text_signal = .{
                    .signal = payload.signal,
                    .read = payload.read,
                } };
            },
            .Cleanup => blk: {
                const payload = elem.payload_cleanup();
                break :blk .{ .cleanup = .{
                    .name = RocStrView.fromAbi(payload.cleanup),
                } };
            },
            .OnChange => blk: {
                const payload = elem.payload_on_change();
                break :blk .{ .on_change = .{
                    .run_initial = false,
                    .signal = payload.signal,
                    .to_cmd = .fromAbi(payload.to_cmd),
                } };
            },
            .OnChangeInitial => blk: {
                const payload = elem.payload_on_change_initial();
                break :blk .{ .on_change = .{
                    .run_initial = true,
                    .signal = payload.signal,
                    .to_cmd = .fromAbi(payload.to_cmd),
                } };
            },
            .OnMount => blk: {
                const payload = elem.payload_on_mount();
                break :blk .{ .on_mount = .{
                    .to_cmd = .fromAbi(payload.to_cmd),
                } };
            },
            .State => blk: {
                const payload = elem.payload_state();
                const binder = StateBinderToken.fromAbi(payload.binder);
                if (binder.callable != retained.hostSignalTokenFromCallable(payload.initial)) {
                    @panic("state binder identity callable did not match its initializer");
                }
                break :blk .{ .state = .{
                    .binder = binder,
                    .initial = .fromAbi(payload.initial),
                    .capability = payload.cap,
                    .child = payload.child,
                } };
            },
            .Component => blk: {
                const payload = elem.payload_component();
                break :blk .{ .component = .{
                    .child = payload.child,
                } };
            },
            .When => blk: {
                const payload = elem.payload_when();
                break :blk .{ .when = .{
                    .condition = payload.condition,
                    .read = payload.read,
                    .when_false = payload.when_false,
                    .when_true = payload.when_true,
                } };
            },
            .Each => blk: {
                const payload = elem.payload_each();
                break :blk .{ .each = .{
                    .items = payload.items,
                    .ops = payload.ops,
                } };
            },
        };
    }
};

/// Converts the raw ABI representation of text field into the engine's exhaustive enum.
pub fn textFieldFromAbi(field: u64) TextField {
    return enumFromAbi(TextField, field, "Roc render text descriptor used an unknown field");
}

/// Converts the raw ABI representation of bool field into the engine's exhaustive enum.
pub fn boolFieldFromAbi(field: u64) BoolField {
    return enumFromAbi(BoolField, field, "Roc render bool descriptor used an unknown field");
}

/// Converts the raw ABI representation of event kind into the engine's exhaustive enum.
pub fn eventKindFromAbi(kind: u64) EventKind {
    return enumFromAbi(EventKind, kind, "Roc render event descriptor used an unknown event kind");
}

fn enumFromAbi(comptime T: type, value: u64, comptime message: []const u8) T {
    inline for (std.meta.fields(T)) |field| {
        if (value == field.value) return @field(T, field.name);
    }
    @panic(message);
}

fn testCallableToken(address: usize) retained.HostSignalToken {
    return @ptrFromInt(address);
}

test "signal token wrappers keep binder and signal tokens distinct" {
    comptime {
        if (SignalToken == StateBinderToken) {
            @compileError("signal tokens and state binder tokens must remain distinct types");
        }
    }
}

test "RocStrView keeps small string bytes valid after return" {
    const view = makeSmallRocStrView();
    try std.testing.expectEqualStrings("small", view.asSlice());
}

fn makeSmallRocStrView() RocStrView {
    return RocStrView.fromAbi(borrowedRocStr("small"));
}

test "SignalExpr.fromAbi decodes ref and const value expressions" {
    const binder_token = testCallableToken(0x1000);
    const ref_expr = abi.NodeSignalExpr{
        .payload = .{ .ref = binder_token },
        .tag = .Ref,
    };
    switch (SignalExpr.fromAbi(ref_expr)) {
        .ref => |payload| try std.testing.expectEqual(binder_token, payload.binder.callable),
        else => return error.TestUnexpectedResult,
    }

    const signal_token = testCallableToken(0x2000);
    const capability = std.mem.zeroes(HostValueCapability);
    const const_expr = abi.NodeSignalExpr{
        .payload = .{ .const_value = .{
            ._0 = signal_token,
            ._1 = signal_token,
            ._2 = capability,
        } },
        .tag = .ConstValue,
    };
    switch (SignalExpr.fromAbi(const_expr)) {
        .const_value => |payload| {
            try std.testing.expectEqual(signal_token, payload.token.callable);
            try std.testing.expectEqual(@as(abi.RocErasedCallable, signal_token), payload.init.toAbi());
            try std.testing.expectEqual(capability, payload.capability);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "SignalExpr.fromAbi decodes map, map2, select, and combine expressions" {
    const input_token = testCallableToken(0x3000);
    var input = abi.NodeSignalExpr{
        .payload = .{ .ref = input_token },
        .tag = .Ref,
    };
    const right_token = testCallableToken(0x4000);
    var right = abi.NodeSignalExpr{
        .payload = .{ .ref = right_token },
        .tag = .Ref,
    };
    const capability = std.mem.zeroes(HostValueCapability);

    const map_token = testCallableToken(0x5000);
    const map_expr = abi.NodeSignalExpr{
        .payload = .{ .map = .{
            ._0 = map_token,
            ._1 = &input,
            ._2 = map_token,
            ._3 = capability,
        } },
        .tag = .Map,
    };
    switch (SignalExpr.fromAbi(map_expr)) {
        .map => |payload| {
            try std.testing.expectEqual(map_token, payload.token.callable);
            try std.testing.expectEqual(&input, payload.input);
            try std.testing.expectEqual(capability, payload.capability);
        },
        else => return error.TestUnexpectedResult,
    }

    const map2_token = testCallableToken(0x6000);
    const map2_expr = abi.NodeSignalExpr{
        .payload = .{ .map2 = .{
            ._0 = map2_token,
            ._1 = &input,
            ._2 = &right,
            ._3 = map2_token,
            ._4 = capability,
        } },
        .tag = .Map2,
    };
    switch (SignalExpr.fromAbi(map2_expr)) {
        .map2 => |payload| {
            try std.testing.expectEqual(map2_token, payload.token.callable);
            try std.testing.expectEqual(&input, payload.left);
            try std.testing.expectEqual(&right, payload.right);
            try std.testing.expectEqual(capability, payload.capability);
        },
        else => return error.TestUnexpectedResult,
    }

    const select_token = testCallableToken(0x6800);
    const true_init = testCallableToken(0x6900);
    const input_read = std.mem.zeroes(HostTextRead);
    const select_expr = abi.NodeSignalExpr{
        .payload = .{ .select = .{
            ._0 = select_token,
            ._1 = &input,
            ._2 = borrowedRocStr("selected-row"),
            ._3 = input_read,
            ._4 = select_token,
            ._5 = true_init,
            ._6 = capability,
        } },
        .tag = .Select,
    };
    switch (SignalExpr.fromAbi(select_expr)) {
        .select => |payload| {
            try std.testing.expectEqual(select_token, payload.token.callable);
            try std.testing.expectEqual(&input, payload.input);
            try std.testing.expectEqualStrings("selected-row", payload.key.asSlice());
            try std.testing.expectEqual(input_read, payload.input_read);
            try std.testing.expectEqual(select_token, payload.false_init.toAbi());
            try std.testing.expectEqual(true_init, payload.true_init.toAbi());
            try std.testing.expectEqual(capability, payload.capability);
        },
        else => return error.TestUnexpectedResult,
    }

    const combine_token = testCallableToken(0x7000);
    var children = [_]abi.NodeSignalExpr{ input, right };
    const combine_expr = abi.NodeSignalExpr{
        .payload = .{ .combine = .{
            ._0 = combine_token,
            ._1 = borrowedSignalExprList(children[0..]),
            ._2 = combine_token,
            ._3 = capability,
        } },
        .tag = .Combine,
    };
    switch (SignalExpr.fromAbi(combine_expr)) {
        .combine => |payload| {
            try std.testing.expectEqual(combine_token, payload.token.callable);
            try std.testing.expectEqual(@as(usize, 2), payload.children.len);
            try std.testing.expectEqual(abi.NodeSignalExprTag.Ref, payload.children[0].tag);
            try std.testing.expectEqual(abi.NodeSignalExprTag.Ref, payload.children[1].tag);
            try std.testing.expectEqual(capability, payload.capability);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "SignalExpr.fromAbi decodes effect source expressions" {
    const capability = std.mem.zeroes(HostValueCapability);

    const task_token = testCallableToken(0x8000);
    const task_expr = abi.NodeSignalExpr{
        .payload = .{ .task_source = .{
            .token = task_token,
            .name = borrowedRocStr("load-user"),
            .payload_cap = capability,
            .initial = task_token,
            .done = null,
            .failed = null,
            .cap = capability,
            .reset_on_start = true,
        } },
        .tag = .TaskSource,
    };
    switch (SignalExpr.fromAbi(task_expr)) {
        .task_source => |payload| {
            try std.testing.expectEqual(task_token, payload.token.callable);
            try std.testing.expectEqualStrings("load-user", payload.name.asSlice());
            try std.testing.expect(payload.reset_on_start);
            try std.testing.expectEqual(capability, payload.payload_capability);
            try std.testing.expectEqual(capability, payload.capability);
        },
        else => return error.TestUnexpectedResult,
    }

    const interval_token = testCallableToken(0x9000);
    const interval_expr = abi.NodeSignalExpr{
        .payload = .{ .interval_source = .{
            .token = interval_token,
            .period_ms = 250,
            .initial = interval_token,
            .tick = null,
            .cap = capability,
        } },
        .tag = .IntervalSource,
    };
    switch (SignalExpr.fromAbi(interval_expr)) {
        .interval_source => |payload| {
            try std.testing.expectEqual(interval_token, payload.token.callable);
            try std.testing.expectEqual(@as(u64, 250), payload.period_ms);
            try std.testing.expectEqual(capability, payload.capability);
        },
        else => return error.TestUnexpectedResult,
    }

    const location_token = testCallableToken(0xa000);
    const location_expr = abi.NodeSignalExpr{
        .payload = .{ .location_source = .{
            ._0 = location_token,
            ._1 = location_token,
            ._2 = capability,
            ._3 = capability,
        } },
        .tag = .LocationSource,
    };
    switch (SignalExpr.fromAbi(location_expr)) {
        .location_source => |payload| {
            try std.testing.expectEqual(location_token, payload.token.callable);
            try std.testing.expectEqual(@as(abi.RocErasedCallable, location_token), payload.from_payload.toAbi());
            try std.testing.expectEqual(capability, payload.capability);
            try std.testing.expectEqual(capability, payload.payload_capability);
        },
        else => return error.TestUnexpectedResult,
    }

    const visibility_token = testCallableToken(0xb000);
    const visibility_expr = abi.NodeSignalExpr{
        .payload = .{ .visibility_source = .{
            ._0 = visibility_token,
            ._1 = visibility_token,
            ._2 = capability,
            ._3 = capability,
        } },
        .tag = .VisibilitySource,
    };
    switch (SignalExpr.fromAbi(visibility_expr)) {
        .visibility_source => |payload| {
            try std.testing.expectEqual(visibility_token, payload.token.callable);
            try std.testing.expectEqual(@as(abi.RocErasedCallable, visibility_token), payload.from_payload.toAbi());
            try std.testing.expectEqual(capability, payload.capability);
            try std.testing.expectEqual(capability, payload.payload_capability);
        },
        else => return error.TestUnexpectedResult,
    }

    const online_token = testCallableToken(0xc000);
    const online_expr = abi.NodeSignalExpr{
        .payload = .{ .online_source = .{
            ._0 = online_token,
            ._1 = online_token,
            ._2 = capability,
            ._3 = capability,
        } },
        .tag = .OnlineSource,
    };
    switch (SignalExpr.fromAbi(online_expr)) {
        .online_source => |payload| {
            try std.testing.expectEqual(online_token, payload.token.callable);
            try std.testing.expectEqual(@as(abi.RocErasedCallable, online_token), payload.from_payload.toAbi());
            try std.testing.expectEqual(capability, payload.capability);
            try std.testing.expectEqual(capability, payload.payload_capability);
        },
        else => return error.TestUnexpectedResult,
    }

    const storage_token = testCallableToken(0xd000);
    const storage_expr = abi.NodeSignalExpr{
        .payload = .{ .storage_source = .{
            ._1 = @intFromEnum(boundary.StorageArea.local),
            ._0 = storage_token,
            ._2 = borrowedRocStr("checkout:draft"),
            ._3 = storage_token,
            ._4 = capability,
            ._5 = capability,
        } },
        .tag = .StorageSource,
    };
    switch (SignalExpr.fromAbi(storage_expr)) {
        .storage_source => |payload| {
            try std.testing.expectEqual(storage_token, payload.token.callable);
            try std.testing.expectEqual(boundary.StorageArea.local, payload.area);
            try std.testing.expectEqualStrings("checkout:draft", payload.key.asSlice());
            try std.testing.expectEqual(@as(abi.RocErasedCallable, storage_token), payload.from_payload.toAbi());
            try std.testing.expectEqual(capability, payload.capability);
            try std.testing.expectEqual(capability, payload.payload_capability);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "NodeAttr.fromAbi decodes text attr targets" {
    const fixed = abi.NodeAttr{
        .payload = .{ .static_text = .{
            .field = .{ .id = @intFromEnum(TextField.label) },
            .name = abi.RocStr.empty(),
            .value = borrowedRocStr("ready"),
        } },
        .tag = .StaticText,
    };
    switch (NodeAttr.fromAbi(fixed)) {
        .static_text => |payload| {
            switch (payload.target) {
                .fixed => |field| try std.testing.expectEqual(TextField.label, field),
                else => return error.TestUnexpectedResult,
            }
            try std.testing.expectEqualStrings("ready", payload.value.asSlice());
        },
        else => return error.TestUnexpectedResult,
    }

    const custom = abi.NodeAttr{
        .payload = .{ .static_text = .{
            .field = .{ .id = node_text_field_custom },
            .name = borrowedRocStr("data-id"),
            .value = borrowedRocStr("42"),
        } },
        .tag = .StaticText,
    };
    switch (NodeAttr.fromAbi(custom)) {
        .static_text => |payload| {
            switch (payload.target) {
                .custom => |name| try std.testing.expectEqualStrings("data-id", name.asSlice()),
                else => return error.TestUnexpectedResult,
            }
            try std.testing.expectEqualStrings("42", payload.value.asSlice());
        },
        else => return error.TestUnexpectedResult,
    }
}

test "NodeAttr.fromAbi decodes signal text and bool attrs" {
    const token = testCallableToken(0xe000);
    var signal = abi.NodeSignalExpr{
        .payload = .{ .ref = token },
        .tag = .Ref,
    };
    const text_read = std.mem.zeroes(HostTextRead);
    const bool_read = std.mem.zeroes(HostBoolRead);

    const text_attr = abi.NodeAttr{
        .payload = .{ .signal_text = .{
            .field = .{ .id = @intFromEnum(TextField.value) },
            .name = abi.RocStr.empty(),
            .read = text_read,
            .signal = &signal,
        } },
        .tag = .SignalText,
    };
    switch (NodeAttr.fromAbi(text_attr)) {
        .signal_text => |payload| {
            switch (payload.target) {
                .fixed => |field| try std.testing.expectEqual(TextField.value, field),
                else => return error.TestUnexpectedResult,
            }
            try std.testing.expectEqual(&signal, payload.signal);
            try std.testing.expectEqual(text_read, payload.read);
        },
        else => return error.TestUnexpectedResult,
    }

    const bool_attr = abi.NodeAttr{
        .payload = .{ .signal_bool = .{
            .field = .{ .id = node_bool_field_custom },
            .name = borrowedRocStr("aria-expanded"),
            .read = bool_read,
            .signal = &signal,
        } },
        .tag = .SignalBool,
    };
    switch (NodeAttr.fromAbi(bool_attr)) {
        .signal_bool => |payload| {
            switch (payload.target) {
                .custom => |name| try std.testing.expectEqualStrings("aria-expanded", name.asSlice()),
                else => return error.TestUnexpectedResult,
            }
            try std.testing.expectEqual(&signal, payload.signal);
            try std.testing.expectEqual(bool_read, payload.read);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "NodeAttr.fromAbi decodes static bool attrs and events" {
    const static_bool = abi.NodeAttr{
        .payload = .{ .static_bool = .{
            .field = .{ .id = @intFromEnum(BoolField.disabled) },
            .name = abi.RocStr.empty(),
            .value = true,
        } },
        .tag = .StaticBool,
    };
    switch (NodeAttr.fromAbi(static_bool)) {
        .static_bool => |payload| {
            switch (payload.target) {
                .fixed => |field| try std.testing.expectEqual(BoolField.disabled, field),
                else => return error.TestUnexpectedResult,
            }
            try std.testing.expect(payload.value);
        },
        else => return error.TestUnexpectedResult,
    }

    const binder = testCallableToken(0xf000);
    const reducer = std.mem.zeroes(HostEventReducer);
    const event = abi.NodeAttr{
        .payload = .{ .on = .{
            .kind = .{ .id = @intFromEnum(EventKind.pointer_down) },
            .msg = .{
                .binder = binder,
                .read_binder = binder,
                .event_extraction_plan = testEventExtractionPlan(.record_key_shift),
                .payload_reducer = reducer,
            },
            .name = abi.RocStr.empty(),
            .delivery = testEventDelivery(true),
            .policy = testEventPolicy(0),
        } },
        .tag = .On,
    };
    switch (NodeAttr.fromAbi(event)) {
        .event => |payload| {
            try std.testing.expectEqual(EventKind.pointer_down, payload.kind);
            try std.testing.expectEqual(EventDeliveryRequest.native, payload.delivery_request);
            try std.testing.expectEqual(binder, payload.msg.binder.callable);
            try std.testing.expectEqual(BoundaryPayloadDescriptor.init(.bytes, .record_key_shift), payload.msg.payload_descriptor);
            try std.testing.expectEqual(reducer, payload.msg.payload_reducer);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "NodeAttr.fromAbi decodes named events" {
    const binder = testCallableToken(0x10000);
    const reducer = std.mem.zeroes(HostEventReducer);
    const attr = abi.NodeAttr{
        .payload = .{ .on = .{
            .kind = .{ .id = 0 },
            .msg = .{
                .binder = binder,
                .read_binder = binder,
                .event_extraction_plan = testEventExtractionPlan(.none),
                .payload_reducer = reducer,
            },
            .name = borrowedRocStr("keydown"),
            .delivery = testEventDelivery(false),
            .policy = testEventPolicy(render.listener_option_prevent_default | render.listener_option_self | render.listener_option_trusted),
        } },
        .tag = .On,
    };
    switch (NodeAttr.fromAbi(attr)) {
        .named_event => |payload| {
            try std.testing.expectEqualStrings("keydown", payload.name.asSlice());
            try std.testing.expect(payload.policy.eql(EventPolicy.fromBits(render.listener_option_prevent_default | render.listener_option_self | render.listener_option_trusted)));
            try std.testing.expectEqual(EventDeliveryRequest.auto, payload.delivery_request);
            try std.testing.expectEqual(binder, payload.msg.binder.callable);
            try std.testing.expectEqual(BoundaryPayloadDescriptor.init(.unit, .none), payload.msg.payload_descriptor);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "Elem.fromAbi decodes element text and cleanup payloads" {
    const attr = abi.NodeAttr{
        .payload = .{ .static_bool = .{
            .field = .{ .id = @intFromEnum(BoolField.disabled) },
            .name = abi.RocStr.empty(),
            .value = true,
        } },
        .tag = .StaticBool,
    };
    const child = abi.Elem{
        .payload = .{ .text = borrowedRocStr("child") },
        .tag = .Text,
    };
    var attrs = [_]abi.NodeAttr{attr};
    var children = [_]abi.Elem{child};
    const element = abi.Elem{
        .payload = .{ .element = .{
            .attrs = borrowedNodeAttrList(attrs[0..]),
            .children = borrowedElemList(children[0..]),
            .tag = borrowedRocStr("button"),
        } },
        .tag = .Element,
    };
    switch (Elem.fromAbi(element)) {
        .element => |payload| {
            try std.testing.expectEqualStrings("button", payload.tag.asSlice());
            try std.testing.expectEqual(@as(usize, 1), payload.attrs.len);
            try std.testing.expectEqual(abi.NodeAttrTag.StaticBool, payload.attrs[0].tag);
            try std.testing.expectEqual(@as(usize, 1), payload.children.len);
            try std.testing.expectEqual(abi.ElemTag.Text, payload.children[0].tag);
        },
        else => return error.TestUnexpectedResult,
    }

    switch (Elem.fromAbi(child)) {
        .text => |payload| try std.testing.expectEqualStrings("child", payload.text.asSlice()),
        else => return error.TestUnexpectedResult,
    }

    const cleanup = abi.Elem{
        .payload = .{ .cleanup = .{
            .cleanup = borrowedRocStr("close-menu"),
        } },
        .tag = .Cleanup,
    };
    switch (Elem.fromAbi(cleanup)) {
        .cleanup => |payload| try std.testing.expectEqualStrings("close-menu", payload.name.asSlice()),
        else => return error.TestUnexpectedResult,
    }
}

test "Elem.fromAbi decodes lifecycle and state payloads" {
    const signal_token = testCallableToken(0x11000);
    var signal = abi.NodeSignalExpr{
        .payload = .{ .ref = signal_token },
        .tag = .Ref,
    };
    const text_read = std.mem.zeroes(HostTextRead);
    const text_signal = abi.Elem{
        .payload = .{ .text_signal = .{
            .read = text_read,
            .signal = &signal,
        } },
        .tag = .TextSignal,
    };
    switch (Elem.fromAbi(text_signal)) {
        .text_signal => |payload| {
            try std.testing.expectEqual(&signal, payload.signal);
            try std.testing.expectEqual(text_read, payload.read);
        },
        else => return error.TestUnexpectedResult,
    }

    const on_change_cmd: abi.RocErasedCallable = @ptrFromInt(0x1010);
    const on_change = abi.Elem{
        .payload = .{ .on_change = .{
            .signal = &signal,
            .to_cmd = on_change_cmd,
        } },
        .tag = .OnChange,
    };
    switch (Elem.fromAbi(on_change)) {
        .on_change => |payload| {
            try std.testing.expect(!payload.run_initial);
            try std.testing.expectEqual(&signal, payload.signal);
            try std.testing.expectEqual(on_change_cmd, payload.to_cmd.toAbi());
        },
        else => return error.TestUnexpectedResult,
    }

    const on_change_initial = abi.Elem{
        .payload = .{ .on_change_initial = .{
            .signal = &signal,
            .to_cmd = on_change_cmd,
        } },
        .tag = .OnChangeInitial,
    };
    switch (Elem.fromAbi(on_change_initial)) {
        .on_change => |payload| {
            try std.testing.expect(payload.run_initial);
            try std.testing.expectEqual(&signal, payload.signal);
            try std.testing.expectEqual(on_change_cmd, payload.to_cmd.toAbi());
        },
        else => return error.TestUnexpectedResult,
    }

    const on_mount_cmd: abi.RocErasedCallable = @ptrFromInt(0x2020);
    const on_mount = abi.Elem{
        .payload = .{ .on_mount = .{
            .to_cmd = on_mount_cmd,
        } },
        .tag = .OnMount,
    };
    switch (Elem.fromAbi(on_mount)) {
        .on_mount => |payload| try std.testing.expectEqual(on_mount_cmd, payload.to_cmd.toAbi()),
        else => return error.TestUnexpectedResult,
    }

    var child = abi.Elem{
        .payload = .{ .text = borrowedRocStr("state-child") },
        .tag = .Text,
    };
    const initial: abi.RocErasedCallable = @ptrFromInt(0x3030);
    const capability = std.mem.zeroes(HostValueCapability);
    const state = abi.Elem{
        .payload = .{ .state = .{
            .binder = initial,
            .cap = capability,
            .child = &child,
            .initial = initial,
        } },
        .tag = .State,
    };
    switch (Elem.fromAbi(state)) {
        .state => |payload| {
            try std.testing.expectEqual(retained.hostSignalTokenFromCallable(initial), payload.binder.callable);
            try std.testing.expectEqual(initial, payload.initial.toAbi());
            try std.testing.expectEqual(capability, payload.capability);
            try std.testing.expectEqual(&child, payload.child);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "Elem.fromAbi decodes component when and each payloads" {
    var component_child = abi.Elem{
        .payload = .{ .text = borrowedRocStr("component-child") },
        .tag = .Text,
    };
    const component = abi.Elem{
        .payload = .{ .component = .{
            .child = &component_child,
        } },
        .tag = .Component,
    };
    switch (Elem.fromAbi(component)) {
        .component => |payload| try std.testing.expectEqual(&component_child, payload.child),
        else => return error.TestUnexpectedResult,
    }

    const condition_token = testCallableToken(0x12000);
    var condition = abi.NodeSignalExpr{
        .payload = .{ .ref = condition_token },
        .tag = .Ref,
    };
    var when_false = abi.Elem{
        .payload = .{ .text = borrowedRocStr("false") },
        .tag = .Text,
    };
    var when_true = abi.Elem{
        .payload = .{ .text = borrowedRocStr("true") },
        .tag = .Text,
    };
    const bool_read = std.mem.zeroes(HostBoolRead);
    const when = abi.Elem{
        .payload = .{ .when = .{
            .condition = &condition,
            .read = bool_read,
            .when_false = &when_false,
            .when_true = &when_true,
        } },
        .tag = .When,
    };
    switch (Elem.fromAbi(when)) {
        .when => |payload| {
            try std.testing.expectEqual(&condition, payload.condition);
            try std.testing.expectEqual(bool_read, payload.read);
            try std.testing.expectEqual(&when_false, payload.when_false);
            try std.testing.expectEqual(&when_true, payload.when_true);
        },
        else => return error.TestUnexpectedResult,
    }

    const items_token = testCallableToken(0x13000);
    var items = abi.NodeSignalExpr{
        .payload = .{ .ref = items_token },
        .tag = .Ref,
    };
    const ops = std.mem.zeroes(HostEachOps);
    const each = abi.Elem{
        .payload = .{ .each = .{
            .items = &items,
            .ops = ops,
        } },
        .tag = .Each,
    };
    switch (Elem.fromAbi(each)) {
        .each => |payload| {
            try std.testing.expectEqual(&items, payload.items);
            try std.testing.expectEqual(ops, payload.ops);
        },
        else => return error.TestUnexpectedResult,
    }
}

fn borrowedSignalExprList(items: []const abi.NodeSignalExpr) abi.RocList(abi.NodeSignalExpr) {
    if (items.len == 0) return abi.RocList(abi.NodeSignalExpr).empty();
    return .{
        .elements_ptr = @constCast(items.ptr),
        .length = items.len,
        .capacity_or_alloc_ptr = items.len << 1,
    };
}

fn borrowedNodeAttrList(items: []const abi.NodeAttr) abi.RocList(abi.NodeAttr) {
    if (items.len == 0) return abi.RocList(abi.NodeAttr).empty();
    return .{
        .elements_ptr = @constCast(items.ptr),
        .length = items.len,
        .capacity_or_alloc_ptr = items.len << 1,
    };
}

fn borrowedElemList(items: []const abi.Elem) abi.RocList(abi.Elem) {
    if (items.len == 0) return abi.RocList(abi.Elem).empty();
    return .{
        .elements_ptr = @constCast(items.ptr),
        .length = items.len,
        .capacity_or_alloc_ptr = items.len << 1,
    };
}

fn borrowedU8List(bytes: []const u8) abi.RocListWith(u8, false) {
    if (bytes.len == 0) return abi.RocListWith(u8, false).empty();
    return .{
        .elements_ptr = @constCast(bytes.ptr),
        .length = bytes.len,
        .capacity_or_alloc_ptr = bytes.len << 1,
    };
}

fn borrowedRocStr(bytes: []const u8) abi.RocStr {
    if (bytes.len == 0) return abi.RocStr.empty();
    return .{
        .bytes = @constCast(bytes.ptr),
        .capacity_or_alloc_ptr = bytes.len << 1,
        .length = bytes.len,
    };
}

fn testEventExtractionPlan(plan: EventExtractionPlanKind) abi.NodeEventExtractionPlan {
    return .{
        .bytes = borrowedU8List(plan.bytes()),
    };
}

fn testEventPolicy(bits: u32) abi.NodeEventBindingPolicy {
    const policy = EventPolicy.fromWireBits(bits);
    return .{
        .capture = policy.capture,
        .once = policy.once,
        .passive = policy.passive,
        .prevent_default = policy.prevent_default,
        .self = policy.self,
        .stop_immediate = policy.stop_immediate,
        .stop_propagation = policy.stop_propagation,
        .trusted = policy.trusted,
    };
}

fn testEventDelivery(native: bool) abi.NodeEventDelivery {
    return .{ .native = native };
}
