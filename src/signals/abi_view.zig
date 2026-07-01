const std = @import("std");

const abi = @import("roc_platform_abi.zig");
const retained = @import("retained_values.zig");

pub const HostValueCapability = retained.HostValueCapability;

pub const SignalToken = struct {
    ptr: retained.HostSignalToken,

    pub fn fromAbi(ptr: retained.HostSignalToken) SignalToken {
        return .{ .ptr = ptr };
    }
};

pub const StateBinderToken = struct {
    ptr: *u64,

    pub fn fromAbi(ptr: *u64) StateBinderToken {
        return .{ .ptr = ptr };
    }
};

pub const SignalRef = struct {
    binder: StateBinderToken,
};

pub const ConstValueSignal = struct {
    token: SignalToken,
    init: abi.RocErasedCallable,
    capability: HostValueCapability,
};

pub const MapSignal = struct {
    token: SignalToken,
    input: *const abi.NodeSignalExpr,
    transform: abi.RocErasedCallable,
    capability: HostValueCapability,
};

pub const Map2Signal = struct {
    token: SignalToken,
    left: *const abi.NodeSignalExpr,
    right: *const abi.NodeSignalExpr,
    transform: abi.RocErasedCallable,
    capability: HostValueCapability,
};

pub const CombineSignal = struct {
    token: SignalToken,
    children: []const abi.NodeSignalExpr,
    transform: abi.RocErasedCallable,
    capability: HostValueCapability,
};

pub const TaskSourceSignal = struct {
    token: SignalToken,
    name: []const u8,
    payload_capability: HostValueCapability,
    initial: abi.RocErasedCallable,
    done: abi.RocErasedCallable,
    failed: abi.RocErasedCallable,
    capability: HostValueCapability,
    reset_on_start: bool,
};

pub const IntervalSourceSignal = struct {
    token: SignalToken,
    period_ms: u64,
    initial: abi.RocErasedCallable,
    tick: abi.RocErasedCallable,
    capability: HostValueCapability,
};

pub const SignalExpr = union(enum) {
    ref: SignalRef,
    const_value: ConstValueSignal,
    map: MapSignal,
    map2: Map2Signal,
    combine: CombineSignal,
    task_source: TaskSourceSignal,
    interval_source: IntervalSourceSignal,

    pub fn fromAbi(expr: abi.NodeSignalExpr) SignalExpr {
        return switch (expr.tag) {
            .Ref => .{ .ref = .{
                .binder = StateBinderToken.fromAbi(expr.payload_ref()),
            } },
            .ConstValue => blk: {
                const payload = expr.payload_const_value();
                break :blk .{ .const_value = .{
                    .token = SignalToken.fromAbi(payload._0),
                    .init = payload._1,
                    .capability = payload._2,
                } };
            },
            .Map => blk: {
                const payload = expr.payload_map();
                break :blk .{ .map = .{
                    .token = SignalToken.fromAbi(payload._0),
                    .input = payload._1,
                    .transform = payload._2,
                    .capability = payload._3,
                } };
            },
            .Map2 => blk: {
                const payload = expr.payload_map2();
                break :blk .{ .map2 = .{
                    .token = SignalToken.fromAbi(payload._0),
                    .left = payload._1,
                    .right = payload._2,
                    .transform = payload._3,
                    .capability = payload._4,
                } };
            },
            .Combine => blk: {
                const payload = expr.payload_combine();
                break :blk .{ .combine = .{
                    .token = SignalToken.fromAbi(payload._0),
                    .children = payload._1.items(),
                    .transform = payload._2,
                    .capability = payload._3,
                } };
            },
            .TaskSource => blk: {
                const payload = expr.payload_task_source();
                break :blk .{ .task_source = .{
                    .token = SignalToken.fromAbi(payload.token),
                    .name = payload.name.asSlice(),
                    .payload_capability = payload.payload_cap,
                    .initial = payload.initial,
                    .done = payload.done,
                    .failed = payload.failed,
                    .capability = payload.cap,
                    .reset_on_start = payload.reset_on_start,
                } };
            },
            .IntervalSource => blk: {
                const payload = expr.payload_interval_source();
                break :blk .{ .interval_source = .{
                    .token = SignalToken.fromAbi(payload.token),
                    .period_ms = payload.period_ms,
                    .initial = payload.initial,
                    .tick = payload.tick,
                    .capability = payload.cap,
                } };
            },
        };
    }
};

test "signal token wrappers keep binder and signal tokens distinct" {
    comptime {
        if (SignalToken == StateBinderToken) {
            @compileError("signal tokens and state binder tokens must remain distinct types");
        }
    }
}

test "SignalExpr.fromAbi decodes ref and const value expressions" {
    var binder_token: u64 = 1;
    const ref_expr = abi.NodeSignalExpr{
        .payload = .{ .ref = &binder_token },
        .tag = .Ref,
    };
    switch (SignalExpr.fromAbi(ref_expr)) {
        .ref => |payload| try std.testing.expectEqual(&binder_token, payload.binder.ptr),
        else => return error.TestUnexpectedResult,
    }

    var signal_token: u64 = 2;
    const capability = std.mem.zeroes(HostValueCapability);
    const const_expr = abi.NodeSignalExpr{
        .payload = .{ .const_value = .{
            ._0 = &signal_token,
            ._1 = null,
            ._2 = capability,
        } },
        .tag = .ConstValue,
    };
    switch (SignalExpr.fromAbi(const_expr)) {
        .const_value => |payload| {
            try std.testing.expectEqual(&signal_token, payload.token.ptr);
            try std.testing.expectEqual(@as(abi.RocErasedCallable, null), payload.init);
            try std.testing.expectEqual(capability, payload.capability);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "SignalExpr.fromAbi decodes map, map2, and combine expressions" {
    var input_token: u64 = 3;
    var input = abi.NodeSignalExpr{
        .payload = .{ .ref = &input_token },
        .tag = .Ref,
    };
    var right_token: u64 = 4;
    var right = abi.NodeSignalExpr{
        .payload = .{ .ref = &right_token },
        .tag = .Ref,
    };
    const capability = std.mem.zeroes(HostValueCapability);

    var map_token: u64 = 5;
    const map_expr = abi.NodeSignalExpr{
        .payload = .{ .map = .{
            ._0 = &map_token,
            ._1 = &input,
            ._2 = null,
            ._3 = capability,
        } },
        .tag = .Map,
    };
    switch (SignalExpr.fromAbi(map_expr)) {
        .map => |payload| {
            try std.testing.expectEqual(&map_token, payload.token.ptr);
            try std.testing.expectEqual(&input, payload.input);
            try std.testing.expectEqual(capability, payload.capability);
        },
        else => return error.TestUnexpectedResult,
    }

    var map2_token: u64 = 6;
    const map2_expr = abi.NodeSignalExpr{
        .payload = .{ .map2 = .{
            ._0 = &map2_token,
            ._1 = &input,
            ._2 = &right,
            ._3 = null,
            ._4 = capability,
        } },
        .tag = .Map2,
    };
    switch (SignalExpr.fromAbi(map2_expr)) {
        .map2 => |payload| {
            try std.testing.expectEqual(&map2_token, payload.token.ptr);
            try std.testing.expectEqual(&input, payload.left);
            try std.testing.expectEqual(&right, payload.right);
            try std.testing.expectEqual(capability, payload.capability);
        },
        else => return error.TestUnexpectedResult,
    }

    var combine_token: u64 = 7;
    var children = [_]abi.NodeSignalExpr{ input, right };
    const combine_expr = abi.NodeSignalExpr{
        .payload = .{ .combine = .{
            ._0 = &combine_token,
            ._1 = borrowedSignalExprList(children[0..]),
            ._2 = null,
            ._3 = capability,
        } },
        .tag = .Combine,
    };
    switch (SignalExpr.fromAbi(combine_expr)) {
        .combine => |payload| {
            try std.testing.expectEqual(&combine_token, payload.token.ptr);
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

    var task_token: u64 = 8;
    const task_expr = abi.NodeSignalExpr{
        .payload = .{ .task_source = .{
            .token = &task_token,
            .name = borrowedRocStr("load-user"),
            .payload_cap = capability,
            .initial = null,
            .done = null,
            .failed = null,
            .cap = capability,
            .reset_on_start = true,
        } },
        .tag = .TaskSource,
    };
    switch (SignalExpr.fromAbi(task_expr)) {
        .task_source => |payload| {
            try std.testing.expectEqual(&task_token, payload.token.ptr);
            try std.testing.expectEqualStrings("load-user", payload.name);
            try std.testing.expect(payload.reset_on_start);
            try std.testing.expectEqual(capability, payload.payload_capability);
            try std.testing.expectEqual(capability, payload.capability);
        },
        else => return error.TestUnexpectedResult,
    }

    var interval_token: u64 = 9;
    const interval_expr = abi.NodeSignalExpr{
        .payload = .{ .interval_source = .{
            .token = &interval_token,
            .period_ms = 250,
            .initial = null,
            .tick = null,
            .cap = capability,
        } },
        .tag = .IntervalSource,
    };
    switch (SignalExpr.fromAbi(interval_expr)) {
        .interval_source => |payload| {
            try std.testing.expectEqual(&interval_token, payload.token.ptr);
            try std.testing.expectEqual(@as(u64, 250), payload.period_ms);
            try std.testing.expectEqual(capability, payload.capability);
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

fn borrowedRocStr(bytes: []const u8) abi.RocStr {
    if (bytes.len == 0) return abi.RocStr.empty();
    return .{
        .bytes = @constCast(bytes.ptr),
        .capacity_or_alloc_ptr = bytes.len << 1,
        .length = bytes.len,
    };
}
