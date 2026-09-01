//! Host-agnostic adapter for invoking Roc "erased callable" thunks.
//!
//! Both Signals hosts (`native_host.zig`, `wasm_host.zig`) call retained Roc
//! closures through `abi.RocErasedCallable`. The calling convention — build a
//! packed args struct on the stack, hand the callable a result pointer plus its
//! capture pointer — is pure ABI with no host state, so it lives here once and
//! both hosts alias it. See `design.md` (one engine, two thin hosts).

const abi = @import("roc_platform_abi.zig");
const host_values = @import("host_values.zig");
const std = @import("std");

pub const HostValue = host_values.HostValue;
const RawHostValue = u64;
pub const HostValueList = abi.RocListWith(HostValue, false);
pub const U64List = abi.RocListWith(u64, false);
pub const Cmd = abi.NodeCmd;
pub const StartTaskCmd = @FieldType(abi.NodeCmdPayload, "start_task");
pub const UpdateStateCmd = @FieldType(abi.NodeCmdPayload, "update_state");
pub const RocBoxPair = extern struct {
    keep: abi.RocBox,
    out: abi.RocBox,
};

pub const ErasedUnitArgs = extern struct {};

pub const ErasedHostValueUnaryArgs = extern struct {
    arg0: RawHostValue,
};

pub const ErasedHostValueBinaryArgs = extern struct {
    arg0: RawHostValue,
    arg1: RawHostValue,
};

pub const ErasedHostValueTernaryArgs = extern struct {
    arg0: RawHostValue,
    arg1: RawHostValue,
    arg2: RawHostValue,
};

pub const ErasedHostValueU64Args = extern struct {
    arg0: RawHostValue,
    arg1: u64,
};

/// Exact app-compiled `Rows.compare_slots` argument layout. Both raw HostValues
/// and the primitive pair list transfer owned references into the Roc call.
pub const ErasedRowsCompareSlotsArgs = extern struct {
    arg0: RawHostValue,
    arg1: RawHostValue,
    arg2: U64List,
    arg3: u64,
};

pub const ErasedRocStrU64Args = extern struct {
    arg0: abi.RocStr,
    arg1: u64,
};

pub const ErasedHostValueListUnaryArgs = extern struct {
    arg0: HostValueList,
};

pub const ErasedRocBoxUnaryArgs = extern struct {
    arg0: abi.RocBox,
};

/// Returns the callable capture payload expected by the app-compiled trampoline.
pub fn erasedCallablePayload(callable: abi.RocErasedCallable) *abi.RocErasedCallablePayload {
    if (callable == null) @panic("host attempted to call a null Roc erased callable");
    return abi.rocErasedCallablePayloadPtr(callable);
}

fn callErasedCallable(payload: *abi.RocErasedCallablePayload, roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture: ?[*]u8) void {
    var out_desc: ?*const anyopaque = null;
    payload.callable_fn_ptr(roc_host, ret, args, capture, null, &out_desc);
}

/// Invokes the retained app-compiled callable using its exact ABI signature and ownership convention.
pub fn callValueInitThunk(roc_host: *abi.RocHost, callable: abi.RocErasedCallable) HostValue {
    const payload = erasedCallablePayload(callable);
    var result: HostValue = undefined;
    callErasedCallable(
        payload,
        roc_host,
        @ptrCast(&result),
        null,
        abi.rocErasedCallableCapturePtr(callable),
    );
    return result;
}

/// Invokes the retained app-compiled callable using its exact ABI signature and ownership convention.
pub fn callErasedHostValueToHostValue(roc_host: *abi.RocHost, callable: abi.RocErasedCallable, arg0: HostValue) HostValue {
    const payload = erasedCallablePayload(callable);
    var call_args = ErasedHostValueUnaryArgs{ .arg0 = arg0.toRaw() };
    var result: HostValue = undefined;
    callErasedCallable(
        payload,
        roc_host,
        @ptrCast(&result),
        @ptrCast(&call_args),
        abi.rocErasedCallableCapturePtr(callable),
    );
    return result;
}

/// Invokes a retained lazy-structure builder with one opaque typed value.
pub fn callErasedHostValueToElem(roc_host: *abi.RocHost, callable: abi.RocErasedCallable, arg0: HostValue) abi.Elem {
    const payload = erasedCallablePayload(callable);
    var call_args = ErasedHostValueUnaryArgs{ .arg0 = arg0.toRaw() };
    var result: abi.Elem = undefined;
    callErasedCallable(
        payload,
        roc_host,
        @ptrCast(&result),
        @ptrCast(&call_args),
        abi.rocErasedCallableCapturePtr(callable),
    );
    return result;
}

/// Invokes the retained app-compiled callable using its exact ABI signature and ownership convention.
pub fn callErasedHostValueToCmd(roc_host: *abi.RocHost, callable: abi.RocErasedCallable, arg0: HostValue) Cmd {
    const payload = erasedCallablePayload(callable);
    var call_args = ErasedHostValueUnaryArgs{ .arg0 = arg0.toRaw() };
    var result: Cmd = undefined;
    callErasedCallable(
        payload,
        roc_host,
        @ptrCast(&result),
        @ptrCast(&call_args),
        abi.rocErasedCallableCapturePtr(callable),
    );
    return result;
}

/// Invokes the retained app-compiled callable using its exact ABI signature and ownership convention.
pub fn callUnitToCmd(roc_host: *abi.RocHost, callable: abi.RocErasedCallable) Cmd {
    const payload = erasedCallablePayload(callable);
    var result: Cmd = undefined;
    callErasedCallable(
        payload,
        roc_host,
        @ptrCast(&result),
        null,
        abi.rocErasedCallableCapturePtr(callable),
    );
    return result;
}

/// Invokes the retained app-compiled callable using its exact ABI signature and ownership convention.
pub fn callErasedHostValueHostValueToHostValue(roc_host: *abi.RocHost, callable: abi.RocErasedCallable, arg0: HostValue, arg1: HostValue) HostValue {
    const payload = erasedCallablePayload(callable);
    var call_args = ErasedHostValueBinaryArgs{ .arg0 = arg0.toRaw(), .arg1 = arg1.toRaw() };
    var result: HostValue = undefined;
    callErasedCallable(
        payload,
        roc_host,
        @ptrCast(&result),
        @ptrCast(&call_args),
        abi.rocErasedCallableCapturePtr(callable),
    );
    return result;
}

/// Invokes the retained app-compiled callable using its exact ABI signature and ownership convention.
pub fn callErasedHostValueHostValueHostValueToHostValue(roc_host: *abi.RocHost, callable: abi.RocErasedCallable, arg0: HostValue, arg1: HostValue, arg2: HostValue) HostValue {
    const payload = erasedCallablePayload(callable);
    var result: HostValue = undefined;
    var call_args = ErasedHostValueTernaryArgs{ .arg0 = arg0.toRaw(), .arg1 = arg1.toRaw(), .arg2 = arg2.toRaw() };
    callErasedCallable(
        payload,
        roc_host,
        @ptrCast(&result),
        @ptrCast(&call_args),
        abi.rocErasedCallableCapturePtr(callable),
    );
    return result;
}

/// Invokes the retained app-compiled callable using its exact ABI signature and ownership convention.
pub fn callErasedHostValueHostValueToElem(roc_host: *abi.RocHost, callable: abi.RocErasedCallable, arg0: HostValue, arg1: HostValue) abi.Elem {
    const payload = erasedCallablePayload(callable);
    var call_args = ErasedHostValueBinaryArgs{ .arg0 = arg0.toRaw(), .arg1 = arg1.toRaw() };
    var result: abi.Elem = undefined;
    callErasedCallable(
        payload,
        roc_host,
        @ptrCast(&result),
        @ptrCast(&call_args),
        abi.rocErasedCallableCapturePtr(callable),
    );
    return result;
}

/// Invokes the retained app-compiled callable using its exact ABI signature and ownership convention.
pub fn callErasedHostValueHostValueToBool(roc_host: *abi.RocHost, callable: abi.RocErasedCallable, arg0: HostValue, arg1: HostValue) bool {
    const payload = erasedCallablePayload(callable);
    var call_args = ErasedHostValueBinaryArgs{ .arg0 = arg0.toRaw(), .arg1 = arg1.toRaw() };
    var result: usize = 0;
    callErasedCallable(
        payload,
        roc_host,
        @ptrCast(&result),
        @ptrCast(&call_args),
        abi.rocErasedCallableCapturePtr(callable),
    );
    return (result & 0xff) != 0;
}

/// Invokes the retained app-compiled callable using its exact ABI signature and ownership convention.
pub fn callErasedHostValueToUnit(roc_host: *abi.RocHost, callable: abi.RocErasedCallable, arg0: HostValue) void {
    const payload = erasedCallablePayload(callable);
    var call_args = ErasedHostValueUnaryArgs{ .arg0 = arg0.toRaw() };
    var result: usize = 0;
    callErasedCallable(
        payload,
        roc_host,
        @ptrCast(&result),
        @ptrCast(&call_args),
        abi.rocErasedCallableCapturePtr(callable),
    );
}

/// Invokes the retained app-compiled callable using its exact ABI signature and ownership convention.
pub fn callErasedHostValueToStr(roc_host: *abi.RocHost, callable: abi.RocErasedCallable, arg0: HostValue) abi.RocStr {
    const payload = erasedCallablePayload(callable);
    var call_args = ErasedHostValueUnaryArgs{ .arg0 = arg0.toRaw() };
    var result: abi.RocStr = undefined;
    callErasedCallable(
        payload,
        roc_host,
        @ptrCast(&result),
        @ptrCast(&call_args),
        abi.rocErasedCallableCapturePtr(callable),
    );
    return result;
}

/// Invokes the retained app-compiled callable using its exact ABI signature and ownership convention.
pub fn callErasedHostValueToBool(roc_host: *abi.RocHost, callable: abi.RocErasedCallable, arg0: HostValue) bool {
    const payload = erasedCallablePayload(callable);
    var call_args = ErasedHostValueUnaryArgs{ .arg0 = arg0.toRaw() };
    var result: usize = 0;
    callErasedCallable(
        payload,
        roc_host,
        @ptrCast(&result),
        @ptrCast(&call_args),
        abi.rocErasedCallableCapturePtr(callable),
    );
    return (result & 0xff) != 0;
}

/// Invokes the retained app-compiled callable using its exact ABI signature and ownership convention.
pub fn callErasedHostValueToU64(roc_host: *abi.RocHost, callable: abi.RocErasedCallable, arg0: HostValue) u64 {
    const payload = erasedCallablePayload(callable);
    var call_args = ErasedHostValueUnaryArgs{ .arg0 = arg0.toRaw() };
    var result: u64 = undefined;
    callErasedCallable(
        payload,
        roc_host,
        @ptrCast(&result),
        @ptrCast(&call_args),
        abi.rocErasedCallableCapturePtr(callable),
    );
    return result;
}

/// Invokes a collection adapter operation with an opaque collection and sink token.
pub fn callErasedHostValueU64ToU64(roc_host: *abi.RocHost, callable: abi.RocErasedCallable, arg0: HostValue, arg1: u64) u64 {
    const payload = erasedCallablePayload(callable);
    var call_args = ErasedHostValueU64Args{ .arg0 = arg0.toRaw(), .arg1 = arg1 };
    var result: u64 = undefined;
    callErasedCallable(payload, roc_host, @ptrCast(&result), @ptrCast(&call_args), abi.rocErasedCallableCapturePtr(callable));
    return result;
}

/// Invokes the pair-comparison adapter. The caller retains `arg2`; the Roc
/// callable receives and consumes the additional list reference created here.
pub fn callErasedHostValueHostValueU64ListU64ToU64(roc_host: *abi.RocHost, callable: abi.RocErasedCallable, arg0: HostValue, arg1: HostValue, arg2: U64List, arg3: u64) u64 {
    const payload = erasedCallablePayload(callable);
    arg2.incref(1);
    var call_args = ErasedRowsCompareSlotsArgs{
        .arg0 = arg0.toRaw(),
        .arg1 = arg1.toRaw(),
        .arg2 = arg2,
        .arg3 = arg3,
    };
    var result: u64 = undefined;
    callErasedCallable(payload, roc_host, @ptrCast(&result), @ptrCast(&call_args), abi.rocErasedCallableCapturePtr(callable));
    return result;
}

/// Invokes an indexed collection adapter and returns one independently owned host value.
pub fn callErasedHostValueU64ToHostValue(roc_host: *abi.RocHost, callable: abi.RocErasedCallable, arg0: HostValue, arg1: u64) HostValue {
    const payload = erasedCallablePayload(callable);
    var call_args = ErasedHostValueU64Args{ .arg0 = arg0.toRaw(), .arg1 = arg1 };
    var result: HostValue = undefined;
    callErasedCallable(payload, roc_host, @ptrCast(&result), @ptrCast(&call_args), abi.rocErasedCallableCapturePtr(callable));
    return result;
}

/// Invokes a row builder. `arg0` transfers one owned Roc string reference to
/// the callable; the returned element is independently owned by the caller.
pub fn callErasedRocStrU64ToElem(roc_host: *abi.RocHost, callable: abi.RocErasedCallable, arg0: abi.RocStr, arg1: u64) abi.Elem {
    const payload = erasedCallablePayload(callable);
    var call_args = ErasedRocStrU64Args{ .arg0 = arg0, .arg1 = arg1 };
    var result: abi.Elem = undefined;
    callErasedCallable(payload, roc_host, @ptrCast(&result), @ptrCast(&call_args), abi.rocErasedCallableCapturePtr(callable));
    return result;
}

/// Invokes the retained app-compiled callable using its exact ABI signature and ownership convention.
pub fn callErasedHostValueToHostValueList(roc_host: *abi.RocHost, callable: abi.RocErasedCallable, arg0: HostValue) HostValueList {
    const payload = erasedCallablePayload(callable);
    var call_args = ErasedHostValueUnaryArgs{ .arg0 = arg0.toRaw() };
    var result: HostValueList = undefined;
    callErasedCallable(
        payload,
        roc_host,
        @ptrCast(&result),
        @ptrCast(&call_args),
        abi.rocErasedCallableCapturePtr(callable),
    );
    return result;
}

/// Invokes the retained app-compiled callable using its exact ABI signature and ownership convention.
pub fn callErasedRocBoxToRocBoxPair(roc_host: *abi.RocHost, callable: abi.RocErasedCallable, arg0: abi.RocBox) RocBoxPair {
    const payload = erasedCallablePayload(callable);
    var call_args = ErasedRocBoxUnaryArgs{ .arg0 = arg0 };
    var result: RocBoxPair = undefined;
    callErasedCallable(
        payload,
        roc_host,
        @ptrCast(&result),
        @ptrCast(&call_args),
        abi.rocErasedCallableCapturePtr(callable),
    );
    return result;
}

/// Invokes the retained app-compiled callable using its exact ABI signature and ownership convention.
pub fn callErasedHostValueListToHostValue(roc_host: *abi.RocHost, callable: abi.RocErasedCallable, arg0: HostValueList) HostValue {
    const payload = erasedCallablePayload(callable);
    arg0.incref(1);
    var call_args = ErasedHostValueListUnaryArgs{ .arg0 = arg0 };
    var result: HostValue = undefined;
    callErasedCallable(
        payload,
        roc_host,
        @ptrCast(&result),
        @ptrCast(&call_args),
        abi.rocErasedCallableCapturePtr(callable),
    );
    return result;
}

test "collection adapter erased calls preserve generated argument layouts and results" {
    const Calls = struct {
        fn hostValueToU64(_: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, _: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
            const call_args: *const ErasedHostValueUnaryArgs = @ptrCast(@alignCast(args.?));
            const result: *u64 = @ptrCast(@alignCast(ret.?));
            result.* = call_args.arg0 + 1;
        }

        fn hostValueU64ToU64(_: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, _: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
            const call_args: *const ErasedHostValueU64Args = @ptrCast(@alignCast(args.?));
            const result: *u64 = @ptrCast(@alignCast(ret.?));
            result.* = call_args.arg0 + call_args.arg1;
        }

        fn comparePairs(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, _: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
            const call_args: *const ErasedRowsCompareSlotsArgs = @ptrCast(@alignCast(args.?));
            const result: *u64 = @ptrCast(@alignCast(ret.?));
            result.* = call_args.arg0 + call_args.arg1 + call_args.arg2.length + call_args.arg3;
            call_args.arg2.decref(roc_host);
        }

        fn cloneItem(_: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, _: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
            const call_args: *const ErasedHostValueU64Args = @ptrCast(@alignCast(args.?));
            const result: *HostValue = @ptrCast(@alignCast(ret.?));
            result.* = .fromRaw(call_args.arg0 + call_args.arg1);
        }

        fn buildRow(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, _: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
            const call_args: *const ErasedRocStrU64Args = @ptrCast(@alignCast(args.?));
            const result: *abi.Elem = @ptrCast(@alignCast(ret.?));
            const matches = std.mem.eql(u8, call_args.arg0.asSlice(), "stable-key") and call_args.arg1 == 9;
            abi.RocStrRelease.release(call_args.arg0, roc_host);
            result.* = std.mem.zeroes(abi.Elem);
            result.tag = if (matches) .Text else .Cleanup;
        }
    };

    var env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&env);
    const len = abi.rocErasedCallableAllocate(&roc_host, Calls.hostValueToU64, null, 0).?;
    defer abi.decrefErasedCallable(len, &roc_host);
    const copy_keys = abi.rocErasedCallableAllocate(&roc_host, Calls.hostValueU64ToU64, null, 0).?;
    defer abi.decrefErasedCallable(copy_keys, &roc_host);
    const compare = abi.rocErasedCallableAllocate(&roc_host, Calls.comparePairs, null, 0).?;
    defer abi.decrefErasedCallable(compare, &roc_host);
    const clone = abi.rocErasedCallableAllocate(&roc_host, Calls.cloneItem, null, 0).?;
    defer abi.decrefErasedCallable(clone, &roc_host);
    const row = abi.rocErasedCallableAllocate(&roc_host, Calls.buildRow, null, 0).?;
    defer abi.decrefErasedCallable(row, &roc_host);

    try std.testing.expectEqual(@as(u64, 42), callErasedHostValueToU64(&roc_host, len, .fromRaw(41)));
    try std.testing.expectEqual(@as(u64, 47), callErasedHostValueU64ToU64(&roc_host, copy_keys, .fromRaw(41), 6));
    var pairs = U64List.fromSlice(&.{ 2, 7, 11, 13 }, &roc_host);
    defer pairs.decref(&roc_host);
    try std.testing.expectEqual(@as(u64, 63), callErasedHostValueHostValueU64ListU64ToU64(&roc_host, compare, .fromRaw(10), .fromRaw(20), pairs, 29));
    try std.testing.expectEqual(@as(u64, 47), callErasedHostValueU64ToHostValue(&roc_host, clone, .fromRaw(41), 6).toRaw());

    const elem = callErasedRocStrU64ToElem(&roc_host, row, abi.RocStr.fromSlice("stable-key", &roc_host), 9);
    try std.testing.expectEqual(abi.ElemTag.Text, elem.tag);
    elem.decref(&roc_host);
}

test "collection adapter argument records match the generated native ABI" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(ErasedHostValueUnaryArgs));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(ErasedHostValueU64Args));
    if (@sizeOf(usize) == 8) {
        try std.testing.expectEqual(@as(usize, 48), @sizeOf(ErasedRowsCompareSlotsArgs));
        try std.testing.expectEqual(@as(usize, 40), @offsetOf(ErasedRowsCompareSlotsArgs, "arg3"));
        try std.testing.expectEqual(@as(usize, 32), @sizeOf(ErasedRocStrU64Args));
        try std.testing.expectEqual(@as(usize, 24), @offsetOf(ErasedRocStrU64Args, "arg1"));
    } else {
        try std.testing.expectEqual(@as(usize, 40), @sizeOf(ErasedRowsCompareSlotsArgs));
        try std.testing.expectEqual(@as(usize, 32), @offsetOf(ErasedRowsCompareSlotsArgs, "arg3"));
        try std.testing.expectEqual(@as(usize, 24), @sizeOf(ErasedRocStrU64Args));
        try std.testing.expectEqual(@as(usize, 16), @offsetOf(ErasedRocStrU64Args, "arg1"));
    }
}
