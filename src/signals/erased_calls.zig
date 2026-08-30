//! Host-agnostic adapter for invoking Roc "erased callable" thunks.
//!
//! Both Signals hosts (`native_host.zig`, `wasm_host.zig`) call retained Roc
//! closures through `abi.RocErasedCallable`. The calling convention — build a
//! packed args struct on the stack, hand the callable a result pointer plus its
//! capture pointer — is pure ABI with no host state, so it lives here once and
//! both hosts alias it. See `design.md` (one engine, two thin hosts).

const abi = @import("roc_platform_abi.zig");
const host_values = @import("host_values.zig");

pub const HostValue = host_values.HostValue;
const RawHostValue = u64;
pub const HostValueList = abi.RocListWith(HostValue, false);
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
