//! Retained Roc value and capability wrappers used by host-agnostic runtime code.

const std = @import("std");
const abi = @import("roc_platform_abi.zig");
const erased_calls = @import("erased_calls.zig");
const hv = @import("host_values.zig");
const callable_roles = @import("callable_roles.zig");

pub const HostValue = hv.HostValue;
pub const HostValueCapability = hv.HostValueCapabilityHandle;
pub const HostTextRead = abi.HostValueTextReadHandle;
pub const HostBoolRead = abi.HostValueBoolReadHandle;
pub const HostEventReducer = abi.HostValueEventReducerHandle;
pub const HostTaskRequestRead = abi.HostValueTaskRequestReadHandle;
pub const HostEachOps = abi.ElemEachOps;
/// Non-null erased-callable pointer used as signal graph identity.
pub const HostSignalToken = [*]u8;
pub const HostValueList = abi.RocListWith(HostValue, false);

/// Semantic roles for independently routed retained callables. Reader,
/// reducer, and row-operation roles use their distinct generated
/// capability-bearing handle types above instead.
pub const InitializerCallable = callable_roles.Initializer;
pub const TransformCallable = callable_roles.Transform;
pub const CommandBuilderCallable = callable_roles.CommandBuilder;
pub const CapabilityCloneCallable = callable_roles.CapabilityClone;
pub const CapabilityEqCallable = callable_roles.CapabilityEq;
pub const CapabilityDropCallable = callable_roles.CapabilityDrop;

/// A retained Roc value plus the capability that owns its equality/drop
/// operations. Holds exactly one refcount on the capability while live.
pub const HostValueCell = struct {
    value: HostValue,
    cap: HostValueCapability,

    /// Creates a cell that owns one retained opaque value and its exact capability.
    pub fn initRetained(value: HostValue, cap: HostValueCapability, metrics: anytype) HostValueCell {
        _ = retainHostValueCapability(cap, metrics);
        return .{ .value = value, .cap = cap };
    }

    /// Clone the cell, retaining the capability and cloning the boxed value through
    /// `ctx.cloneHostValue` (which the host implements with its registry).
    pub fn cloneRetained(self: HostValueCell, ctx: anytype, metrics: anytype) HostValueCell {
        const value = ctx.cloneHostValue(self.value);
        _ = retainHostValueCapability(self.cap, metrics);
        return .{ .value = value, .cap = self.cap };
    }

    /// Releases every resource owned by this value and leaves no retained host or Roc ownership behind.
    pub fn deinit(self: *HostValueCell, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype) void {
        const caps = [_]HostValueCapability{self.cap};
        ctx.pushHostValueCapabilities(&caps);
        defer ctx.popHostValueCapabilities();
        callCapabilityDrop(roc_host, hv.hostValueCapabilityDropCallable(self.cap), self.value);
        releaseHostValueCapability(self.cap, roc_host, metrics);
        self.* = undefined;
    }

    /// Compares the retained value through its capability for equality pruning.
    pub fn valueEquals(self: *const HostValueCell, ctx: anytype, roc_host: *abi.RocHost, value: HostValue) bool {
        const caps = [_]HostValueCapability{self.cap};
        ctx.pushHostValueCapabilities(&caps);
        defer ctx.popHostValueCapabilities();
        return callCapabilityEq(roc_host, hv.hostValueCapabilityEqCallable(self.cap), self.value, value);
    }

    /// Compares the retained value through its capability for equality pruning.
    pub fn valueEqualsIncoming(self: *const HostValueCell, ctx: anytype, roc_host: *abi.RocHost, value: HostValue, incoming_cap: HostValueCapability) bool {
        const caps = [_]HostValueCapability{ self.cap, incoming_cap };
        ctx.pushHostValueCapabilities(&caps);
        defer ctx.popHostValueCapabilities();
        return callCapabilityEq(roc_host, hv.hostValueCapabilityEqCallable(self.cap), self.value, value);
    }

    /// Drops an uncommitted incoming value through the capability that produced it.
    pub fn dropIncoming(self: *const HostValueCell, ctx: anytype, roc_host: *abi.RocHost, value: HostValue) void {
        const caps = [_]HostValueCapability{self.cap};
        ctx.pushHostValueCapabilities(&caps);
        defer ctx.popHostValueCapabilities();
        callCapabilityDrop(roc_host, hv.hostValueCapabilityDropCallable(self.cap), value);
    }

    /// Atomically replaces the retained cell and releases the displaced value.
    pub fn replaceValue(self: *HostValueCell, ctx: anytype, roc_host: *abi.RocHost, value: HostValue) void {
        const caps = [_]HostValueCapability{self.cap};
        ctx.pushHostValueCapabilities(&caps);
        defer ctx.popHostValueCapabilities();
        callCapabilityDrop(roc_host, hv.hostValueCapabilityDropCallable(self.cap), self.value);
        self.value = value;
    }

    /// Replaces retained while releasing displaced ownership exactly once.
    pub fn replaceRetained(self: *HostValueCell, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype, value: HostValue, cap: HostValueCapability) void {
        const old_cap = self.cap;
        _ = retainHostValueCapability(cap, metrics);
        const caps = [_]HostValueCapability{old_cap};
        ctx.pushHostValueCapabilities(&caps);
        defer ctx.popHostValueCapabilities();
        callCapabilityDrop(roc_host, hv.hostValueCapabilityDropCallable(old_cap), self.value);
        releaseHostValueCapability(old_cap, roc_host, metrics);
        self.* = .{ .value = value, .cap = cap };
    }
};

/// Invokes only a capability's drop operation; other callable roles are not accepted.
pub fn callCapabilityDrop(roc_host: *abi.RocHost, callable: CapabilityDropCallable, value: HostValue) void {
    erased_calls.callErasedHostValueToUnit(roc_host, callable.toAbi(), value);
}

/// Invokes only a capability's equality operation; other callable roles are not accepted.
pub fn callCapabilityEq(roc_host: *abi.RocHost, callable: CapabilityEqCallable, left: HostValue, right: HostValue) bool {
    return erased_calls.callErasedHostValueHostValueToBool(roc_host, callable.toAbi(), left, right);
}

/// Retain one refcount on a Roc thunk the host is about to store.
pub fn retainHostCallable(callable: anytype, metrics: anytype) @TypeOf(callable) {
    abi.increfErasedCallable(callable.toAbi(), 1);
    metrics.bump(.closure_retains, 1);
    return callable;
}

/// Derives host-private signal identity from the retained callable that already owns the construction site.
pub fn hostSignalTokenFromCallable(callable: abi.RocErasedCallable) HostSignalToken {
    return callable orelse @panic("signal identity callable was null");
}

test "host signal tokens preserve non-null callable addresses" {
    const callable: abi.RocErasedCallable = @ptrFromInt(0x1000);
    try std.testing.expectEqual(callable.?, hostSignalTokenFromCallable(callable));
}

/// Retains callable-backed signal identity without exposing native pointers to applications.
pub fn retainHostSignalToken(token: HostSignalToken) HostSignalToken {
    abi.increfErasedCallable(token, 1);
    return token;
}

/// Releases callable-backed signal identity without exposing native pointers to applications.
pub fn releaseHostSignalToken(token: HostSignalToken, roc_host: *abi.RocHost) void {
    abi.decrefErasedCallable(token, roc_host);
}

/// Retains the app-compiled ownership operations for a host value.
pub fn retainHostValueCapability(capability: HostValueCapability, metrics: anytype) HostValueCapability {
    metrics.bump(.closure_retains, 3);
    return hv.retainHostValueCapability(capability);
}

/// Releases the app-compiled ownership operations for a host value.
pub fn releaseHostValueCapability(capability: HostValueCapability, roc_host: *abi.RocHost, metrics: anytype) void {
    metrics.bump(.closure_releases, 3);
    hv.releaseHostValueCapability(capability, roc_host);
}

/// Rejects mismatched value capabilities before invoking app-compiled code.
pub fn assertHostValueCapabilitiesMatch(actual: HostValueCapability, expected: HostValueCapability, message: []const u8) void {
    if (!hv.hostValueCapabilitiesMatch(actual, expected)) @panic(message);
}

fn pushCapabilities(comptime Ctx: type, ctx: Ctx.Handle, caps: []const HostValueCapability) void {
    Ctx.pushHostValueCapabilities(ctx, caps);
}

fn popCapabilities(comptime Ctx: type, ctx: Ctx.Handle) void {
    Ctx.popHostValueCapabilities(ctx);
}

/// Invokes the app-compiled callable inside capability frames for every erased value argument.
pub fn callHostValueToUnitWithCapability(comptime Ctx: type, ctx: Ctx.Handle, roc_host: *abi.RocHost, cap: HostValueCapability, callable: abi.RocErasedCallable, value: HostValue) void {
    const caps = [_]HostValueCapability{cap};
    pushCapabilities(Ctx, ctx, &caps);
    defer popCapabilities(Ctx, ctx);
    erased_calls.callErasedHostValueToUnit(roc_host, callable, value);
}

/// Invokes the app-compiled callable inside capability frames for every erased value argument.
pub fn callHostValueToHostValueWithCapability(comptime Ctx: type, ctx: Ctx.Handle, roc_host: *abi.RocHost, cap: HostValueCapability, callable: abi.RocErasedCallable, value: HostValue) HostValue {
    const caps = [_]HostValueCapability{cap};
    pushCapabilities(Ctx, ctx, &caps);
    defer popCapabilities(Ctx, ctx);
    return erased_calls.callErasedHostValueToHostValue(roc_host, callable, value);
}

/// Invokes the app-compiled callable inside capability frames for every erased value argument.
pub fn callHostValueToCmdWithCapability(comptime Ctx: type, ctx: Ctx.Handle, roc_host: *abi.RocHost, cap: HostValueCapability, callable: abi.RocErasedCallable, value: HostValue) erased_calls.Cmd {
    const caps = [_]HostValueCapability{cap};
    pushCapabilities(Ctx, ctx, &caps);
    defer popCapabilities(Ctx, ctx);
    return erased_calls.callErasedHostValueToCmd(roc_host, callable, value);
}

/// Invokes the app-compiled callable inside capability frames for every erased value argument.
pub fn callHostValueToStrWithCapability(comptime Ctx: type, ctx: Ctx.Handle, roc_host: *abi.RocHost, cap: HostValueCapability, callable: abi.RocErasedCallable, value: HostValue) abi.RocStr {
    const caps = [_]HostValueCapability{cap};
    pushCapabilities(Ctx, ctx, &caps);
    defer popCapabilities(Ctx, ctx);
    return erased_calls.callErasedHostValueToStr(roc_host, callable, value);
}

/// Invokes the app-compiled callable inside capability frames for every erased value argument.
pub fn callHostValueToBoolWithCapability(comptime Ctx: type, ctx: Ctx.Handle, roc_host: *abi.RocHost, cap: HostValueCapability, callable: abi.RocErasedCallable, value: HostValue) bool {
    const caps = [_]HostValueCapability{cap};
    pushCapabilities(Ctx, ctx, &caps);
    defer popCapabilities(Ctx, ctx);
    return erased_calls.callErasedHostValueToBool(roc_host, callable, value);
}

/// Invokes the app-compiled callable inside capability frames for every erased value argument.
pub fn callHostValueToHostValueListWithCapability(comptime Ctx: type, ctx: Ctx.Handle, roc_host: *abi.RocHost, cap: HostValueCapability, callable: abi.RocErasedCallable, value: HostValue) HostValueList {
    const caps = [_]HostValueCapability{cap};
    pushCapabilities(Ctx, ctx, &caps);
    defer popCapabilities(Ctx, ctx);
    return erased_calls.callErasedHostValueToHostValueList(roc_host, callable, value);
}

/// Invokes the app-compiled callable inside capability frames for every erased value argument.
pub fn callHostValueListToHostValueWithCapability(comptime Ctx: type, ctx: Ctx.Handle, roc_host: *abi.RocHost, cap: HostValueCapability, callable: abi.RocErasedCallable, value: HostValueList) HostValue {
    const caps = [_]HostValueCapability{cap};
    pushCapabilities(Ctx, ctx, &caps);
    defer popCapabilities(Ctx, ctx);
    return erased_calls.callErasedHostValueListToHostValue(roc_host, callable, value);
}

/// Invokes the app-compiled callable inside capability frames for every erased value argument.
pub fn callHostValueHostValueToBoolWithCapability(comptime Ctx: type, ctx: Ctx.Handle, roc_host: *abi.RocHost, cap: HostValueCapability, callable: abi.RocErasedCallable, left: HostValue, right: HostValue) bool {
    const caps = [_]HostValueCapability{cap};
    pushCapabilities(Ctx, ctx, &caps);
    defer popCapabilities(Ctx, ctx);
    return erased_calls.callErasedHostValueHostValueToBool(roc_host, callable, left, right);
}

/// Invokes the app-compiled callable inside capability frames for every erased value argument.
pub fn callHostValueHostValueToHostValueWithCapabilities(comptime Ctx: type, ctx: Ctx.Handle, roc_host: *abi.RocHost, left_cap: HostValueCapability, right_cap: HostValueCapability, callable: abi.RocErasedCallable, left: HostValue, right: HostValue) HostValue {
    const caps = [_]HostValueCapability{ left_cap, right_cap };
    pushCapabilities(Ctx, ctx, &caps);
    defer popCapabilities(Ctx, ctx);
    return erased_calls.callErasedHostValueHostValueToHostValue(roc_host, callable, left, right);
}

/// Invokes the app-compiled callable inside capability frames for every erased value argument.
pub fn callHostValueHostValueHostValueToHostValueWithCapabilities(comptime Ctx: type, ctx: Ctx.Handle, roc_host: *abi.RocHost, first_cap: HostValueCapability, second_cap: HostValueCapability, third_cap: HostValueCapability, callable: abi.RocErasedCallable, first: HostValue, second: HostValue, third: HostValue) HostValue {
    const caps = [_]HostValueCapability{ first_cap, second_cap, third_cap };
    pushCapabilities(Ctx, ctx, &caps);
    defer popCapabilities(Ctx, ctx);
    return erased_calls.callErasedHostValueHostValueHostValueToHostValue(roc_host, callable, first, second, third);
}

/// Invokes the app-compiled callable inside capability frames for every erased value argument.
pub fn callHostValueHostValueToElemWithCapabilities(comptime Ctx: type, ctx: Ctx.Handle, roc_host: *abi.RocHost, left_cap: HostValueCapability, right_cap: HostValueCapability, callable: abi.RocErasedCallable, left: HostValue, right: HostValue) abi.Elem {
    const caps = [_]HostValueCapability{ left_cap, right_cap };
    pushCapabilities(Ctx, ctx, &caps);
    defer popCapabilities(Ctx, ctx);
    return erased_calls.callErasedHostValueHostValueToElem(roc_host, callable, left, right);
}

/// Retains every callable and capability owned by text read.
pub fn retainHostTextRead(read: HostTextRead, metrics: anytype) HostTextRead {
    _ = retainHostValueCapability(read.capability, metrics);
    abi.increfErasedCallable(read.read, 1);
    metrics.bump(.closure_retains, 1);
    return read;
}

/// Releases every callable and capability owned by text read.
pub fn releaseHostTextRead(read: HostTextRead, roc_host: *abi.RocHost, metrics: anytype) void {
    releaseHostValueCapability(read.capability, roc_host, metrics);
    abi.decrefErasedCallable(read.read, roc_host);
    metrics.bump(.closure_releases, 1);
}

/// Retains every callable and capability owned by bool read.
pub fn retainHostBoolRead(read: HostBoolRead, metrics: anytype) HostBoolRead {
    _ = retainHostValueCapability(read.capability, metrics);
    abi.increfErasedCallable(read.read, 1);
    metrics.bump(.closure_retains, 1);
    return read;
}

/// Releases every callable and capability owned by bool read.
pub fn releaseHostBoolRead(read: HostBoolRead, roc_host: *abi.RocHost, metrics: anytype) void {
    releaseHostValueCapability(read.capability, roc_host, metrics);
    abi.decrefErasedCallable(read.read, roc_host);
    metrics.bump(.closure_releases, 1);
}

/// Retains every callable and capability owned by event reducer.
pub fn retainHostEventReducer(reducer: HostEventReducer, metrics: anytype) HostEventReducer {
    _ = retainHostValueCapability(reducer.capability, metrics);
    _ = retainHostValueCapability(reducer.read_capability, metrics);
    abi.increfErasedCallable(reducer.transform, 1);
    metrics.bump(.closure_retains, 1);
    return reducer;
}

/// Releases every callable and capability owned by event reducer.
pub fn releaseHostEventReducer(reducer: HostEventReducer, roc_host: *abi.RocHost, metrics: anytype) void {
    releaseHostValueCapability(reducer.capability, roc_host, metrics);
    releaseHostValueCapability(reducer.read_capability, roc_host, metrics);
    abi.decrefErasedCallable(reducer.transform, roc_host);
    metrics.bump(.closure_releases, 1);
}

/// Retains every callable and capability owned by each ops.
pub fn retainHostEachOps(ops: HostEachOps, metrics: anytype) HostEachOps {
    _ = retainHostValueCapability(ops.items_capability, metrics);
    _ = retainHostValueCapability(ops.item_capability, metrics);
    _ = retainHostValueCapability(ops.key_capability, metrics);
    abi.increfErasedCallable(ops.items_to_values, 1);
    abi.increfErasedCallable(ops.key_text, 1);
    abi.increfErasedCallable(ops.key_of, 1);
    abi.increfErasedCallable(ops.row, 1);
    metrics.bump(.closure_retains, 4);
    return ops;
}

/// Releases every callable and capability owned by each ops.
pub fn releaseHostEachOps(ops: HostEachOps, roc_host: *abi.RocHost, metrics: anytype) void {
    releaseHostValueCapability(ops.items_capability, roc_host, metrics);
    releaseHostValueCapability(ops.item_capability, roc_host, metrics);
    releaseHostValueCapability(ops.key_capability, roc_host, metrics);
    abi.decrefErasedCallable(ops.items_to_values, roc_host);
    abi.decrefErasedCallable(ops.key_text, roc_host);
    abi.decrefErasedCallable(ops.key_of, roc_host);
    abi.decrefErasedCallable(ops.row, roc_host);
    metrics.bump(.closure_releases, 4);
}
