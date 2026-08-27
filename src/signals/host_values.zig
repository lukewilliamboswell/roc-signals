//! Host-agnostic HostValue adapter shared by both Signals hosts.
//!
//! `host_value_registry.zig` owns the handle table; this module owns the thin
//! layer above it that both hosts share: capability retain/release/equality,
//! capability-driven splitting, and the boxed value constructors. The pieces
//! that genuinely differ per host — which allocator/registry/`roc_host` to use,
//! and native-only test-kind bookkeeping — are supplied by the caller.

const std = @import("std");
const DebugPhase = @import("debug_phase.zig").Phase;
const abi = @import("roc_platform_abi.zig");

pub const HostValue = u64;
pub const HostValueCapabilityHandle = abi.HostValueCapabilityHandle;
pub const U8List = abi.RocListWith(u8, false);

pub const ActiveCapabilityStack = struct {
    const max_frames = 64;
    const max_capabilities = 128;

    const Frame = struct {
        start: usize,
        len: usize,
    };

    frames: [max_frames]Frame = undefined,
    frame_len: usize = 0,
    capabilities: [max_capabilities]HostValueCapabilityHandle = undefined,
    capability_len: usize = 0,

    /// Pushes a bounded capability frame used to validate erased calls.
    pub fn push(self: *ActiveCapabilityStack, caps: []const HostValueCapabilityHandle) void {
        if (self.frame_len >= max_frames) @panic("HostValue active capability frame stack overflow");
        if (self.capability_len + caps.len > max_capabilities) @panic("HostValue active capability stack overflow");

        self.frames[self.frame_len] = .{
            .start = self.capability_len,
            .len = caps.len,
        };
        self.frame_len += 1;

        for (caps) |cap| {
            self.capabilities[self.capability_len] = cap;
            self.capability_len += 1;
        }
    }

    /// Pops the capability frame for the completed erased call.
    pub fn pop(self: *ActiveCapabilityStack) void {
        if (self.frame_len == 0) @panic("HostValue active capability stack underflow");
        self.frame_len -= 1;
        const frame = self.frames[self.frame_len];
        self.capability_len = frame.start;
    }

    /// Checks whether a capability is authorized by any active erased-call frame.
    pub fn contains(self: *const ActiveCapabilityStack, capability: HostValueCapabilityHandle) bool {
        for (self.capabilities[0..self.capability_len]) |active| {
            if (hostValueCapabilitiesMatch(active, capability)) return true;
        }
        return false;
    }
};

/// Carrier-type category recorded for a freshly boxed value. The native host
/// uses it for debug type assertions; the browser host ignores it.
pub const ValueKind = enum { unit, str, bool, i64, u8_list };

/// Retains the app-compiled ownership operations for a host value.
pub fn retainHostValueCapability(capability: HostValueCapabilityHandle) HostValueCapabilityHandle {
    capability.incref(1);
    return capability;
}

/// Releases the app-compiled ownership operations for a host value.
pub fn releaseHostValueCapability(capability: HostValueCapabilityHandle, roc_host: *abi.RocHost) void {
    capability.decref(roc_host);
}

/// Materializes capability id as a capability-owned host value for boundary delivery.
pub fn hostValueCapabilityId(capability: HostValueCapabilityHandle) usize {
    return @intFromPtr(capability.clone);
}

/// Materializes capability clone as a capability-owned host value for boundary delivery.
pub fn hostValueCapabilityClone(capability: HostValueCapabilityHandle) abi.RocErasedCallable {
    return capability.clone;
}

/// Materializes capability eq as a capability-owned host value for boundary delivery.
pub fn hostValueCapabilityEq(capability: HostValueCapabilityHandle) abi.RocErasedCallable {
    return capability.eq;
}

/// Materializes capability drop as a capability-owned host value for boundary delivery.
pub fn hostValueCapabilityDrop(capability: HostValueCapabilityHandle) abi.RocErasedCallable {
    return capability.drop;
}

/// Materializes capability eq fn as a capability-owned host value for boundary delivery.
pub fn hostValueCapabilityEqFn(capability: HostValueCapabilityHandle) ?abi.RocErasedCallableFn {
    const eq = hostValueCapabilityEq(capability) orelse return null;
    return abi.rocErasedCallablePayloadPtr(eq).callable_fn_ptr;
}

/// Materializes capability clone fn as a capability-owned host value for boundary delivery.
pub fn hostValueCapabilityCloneFn(capability: HostValueCapabilityHandle) ?abi.RocErasedCallableFn {
    const clone = hostValueCapabilityClone(capability) orelse return null;
    return abi.rocErasedCallablePayloadPtr(clone).callable_fn_ptr;
}

/// Materializes capability drop fn as a capability-owned host value for boundary delivery.
pub fn hostValueCapabilityDropFn(capability: HostValueCapabilityHandle) ?abi.RocErasedCallableFn {
    const drop = hostValueCapabilityDrop(capability) orelse return null;
    return abi.rocErasedCallablePayloadPtr(drop).callable_fn_ptr;
}

/// Materializes capabilities match as a capability-owned host value for boundary delivery.
pub fn hostValueCapabilitiesMatch(actual: HostValueCapabilityHandle, expected: HostValueCapabilityHandle) bool {
    return actual.clone == expected.clone and actual.eq == expected.eq and actual.drop == expected.drop;
}

/// Registry-ops adapter passed to `host_value_registry.Registry` calls. It
/// refcounts boxes and capabilities through one active `roc_host`.
pub fn RegistryOps() type {
    return struct {
        roc_host: *abi.RocHost,
        active_capabilities: *ActiveCapabilityStack,
        debug_phase: ?*const DebugPhase = null,

        /// Retains every callable needed to clone, compare, and drop values on this edge.
        pub fn retainCapability(_: @This(), capability: HostValueCapabilityHandle) void {
            capability.incref(1);
        }

        /// Releases the callable bundle owned by a retained edge.
        pub fn releaseCapability(self: @This(), capability: HostValueCapabilityHandle) void {
            releaseHostValueCapability(capability, self.roc_host);
        }

        /// Checks capability identity so erased values cannot cross into the wrong typed edge.
        pub fn capabilitiesMatch(_: @This(), actual: HostValueCapabilityHandle, expected: HostValueCapabilityHandle) bool {
            return hostValueCapabilitiesMatch(actual, expected);
        }

        /// Checks that the owning capability is present in the current app-call frame.
        pub fn capabilityIsActive(self: @This(), actual: HostValueCapabilityHandle) bool {
            return self.active_capabilities.contains(actual);
        }

        /// Clones an opaque value only after validating its owning capability.
        pub fn cloneValueWithCapability(self: @This(), value: HostValue, capability: HostValueCapabilityHandle) HostValue {
            return self.callHostValueToHostValueWithCapability(capability, hostValueCapabilityClone(capability), value);
        }

        /// Invokes the retained app-compiled callable using its exact ABI signature and ownership convention.
        pub fn callHostValueToHostValueWithCapability(self: @This(), capability: HostValueCapabilityHandle, callable: abi.RocErasedCallable, value: HostValue) HostValue {
            const caps = [_]HostValueCapabilityHandle{capability};
            self.active_capabilities.push(&caps);
            defer self.active_capabilities.pop();
            return @import("erased_calls.zig").callErasedHostValueToHostValue(self.roc_host, callable, value);
        }

        /// Uses the app-compiled split callable to create independent keep and output ownership.
        pub fn splitBoxWithSplit(self: @This(), box: abi.RocBox, split: abi.RocErasedCallable) @import("erased_calls.zig").RocBoxPair {
            return @import("erased_calls.zig").callErasedRocBoxToRocBoxPair(self.roc_host, split, box);
        }
    };
}

// Boxed-value constructors. `ctx` must expose:
//   - `store(box: abi.RocBox) HostValue` — store a value that will receive a
//     capability before typed access.
//   - `storeWithCapability(box: abi.RocBox, cap: HostValueCapabilityHandle)
//     HostValue` — store a value with a retained capability.
//   - `recordKind(value: HostValue, kind: ValueKind) void` — native test-kind
//     instrumentation; a no-op on the browser host.
// `roc_host` is threaded explicitly so the box allocation matches the active
// host.

const StaticUnitBox = extern struct {
    refcount: isize,
    payload: u8,
};

// Unit has no payload to tear down. A static Roc box avoids allocating a fresh
// empty box for every unit browser event; Roc's refcount value 0 marks static
// data and makes all generated incref/decref operations no-ops.
var static_unit_box: StaticUnitBox = .{ .refcount = 0, .payload = 0 };

fn staticUnitPayload() abi.RocBox {
    return @ptrCast(&static_unit_box.payload);
}

/// Constructs unit with the host references required by the shared engine contract.
pub fn makeUnit(ctx: anytype, roc_host: *abi.RocHost) HostValue {
    _ = roc_host;
    const value = ctx.store(staticUnitPayload());
    ctx.recordKind(value, .unit);
    return value;
}

/// Constructs unit with capability with the host references required by the shared engine contract.
pub fn makeUnitWithCapability(ctx: anytype, roc_host: *abi.RocHost, cap: HostValueCapabilityHandle) HostValue {
    _ = roc_host;
    const value = ctx.storeWithCapability(staticUnitPayload(), cap);
    ctx.recordKind(value, .unit);
    return value;
}

/// Constructs str with the host references required by the shared engine contract.
pub fn makeStr(ctx: anytype, roc_host: *abi.RocHost, bytes: []const u8) HostValue {
    const payload: *abi.RocStr = @ptrCast(@alignCast(abi.allocateBox(@sizeOf(abi.RocStr), @alignOf(abi.RocStr), true, roc_host)));
    payload.* = abi.RocStr.fromSlice(bytes, roc_host);
    const value = ctx.store(@ptrCast(payload));
    ctx.recordKind(value, .str);
    return value;
}

/// Constructs str with capability with the host references required by the shared engine contract.
pub fn makeStrWithCapability(ctx: anytype, roc_host: *abi.RocHost, bytes: []const u8, cap: HostValueCapabilityHandle) HostValue {
    const payload: *abi.RocStr = @ptrCast(@alignCast(abi.allocateBox(@sizeOf(abi.RocStr), @alignOf(abi.RocStr), true, roc_host)));
    payload.* = abi.RocStr.fromSlice(bytes, roc_host);
    const value = ctx.storeWithCapability(@ptrCast(payload), cap);
    ctx.recordKind(value, .str);
    return value;
}

/// Constructs bool with the host references required by the shared engine contract.
pub fn makeBool(ctx: anytype, roc_host: *abi.RocHost, b: bool) HostValue {
    const payload: *bool = @ptrCast(@alignCast(abi.allocateBox(@sizeOf(bool), @alignOf(bool), false, roc_host)));
    payload.* = b;
    const value = ctx.store(@ptrCast(payload));
    ctx.recordKind(value, .bool);
    return value;
}

/// Constructs bool with capability with the host references required by the shared engine contract.
pub fn makeBoolWithCapability(ctx: anytype, roc_host: *abi.RocHost, b: bool, cap: HostValueCapabilityHandle) HostValue {
    const payload: *bool = @ptrCast(@alignCast(abi.allocateBox(@sizeOf(bool), @alignOf(bool), false, roc_host)));
    payload.* = b;
    const value = ctx.storeWithCapability(@ptrCast(payload), cap);
    ctx.recordKind(value, .bool);
    return value;
}

/// Constructs i64 with the host references required by the shared engine contract.
pub fn makeI64(ctx: anytype, roc_host: *abi.RocHost, n: i64) HostValue {
    const payload: *i64 = @ptrCast(@alignCast(abi.allocateBox(@sizeOf(i64), @alignOf(i64), false, roc_host)));
    payload.* = n;
    const value = ctx.store(@ptrCast(payload));
    ctx.recordKind(value, .i64);
    return value;
}

/// Constructs i64 with capability with the host references required by the shared engine contract.
pub fn makeI64WithCapability(ctx: anytype, roc_host: *abi.RocHost, n: i64, cap: HostValueCapabilityHandle) HostValue {
    const payload: *i64 = @ptrCast(@alignCast(abi.allocateBox(@sizeOf(i64), @alignOf(i64), false, roc_host)));
    payload.* = n;
    const value = ctx.storeWithCapability(@ptrCast(payload), cap);
    ctx.recordKind(value, .i64);
    return value;
}

/// Constructs u8 list with the host references required by the shared engine contract.
pub fn makeU8List(ctx: anytype, roc_host: *abi.RocHost, bytes: []const u8) HostValue {
    const payload: *U8List = @ptrCast(@alignCast(abi.allocateBox(@sizeOf(U8List), @alignOf(U8List), true, roc_host)));
    payload.* = U8List.fromSlice(bytes, roc_host);
    const value = ctx.store(@ptrCast(payload));
    ctx.recordKind(value, .u8_list);
    return value;
}

/// Constructs u8 list with capability with the host references required by the shared engine contract.
pub fn makeU8ListWithCapability(ctx: anytype, roc_host: *abi.RocHost, bytes: []const u8, cap: HostValueCapabilityHandle) HostValue {
    const payload: *U8List = @ptrCast(@alignCast(abi.allocateBox(@sizeOf(U8List), @alignOf(U8List), true, roc_host)));
    payload.* = U8List.fromSlice(bytes, roc_host);
    const value = ctx.storeWithCapability(@ptrCast(payload), cap);
    ctx.recordKind(value, .u8_list);
    return value;
}

test "unit payload uses one static Roc box" {
    const first = staticUnitPayload() orelse unreachable;
    const second = staticUnitPayload() orelse unreachable;
    try std.testing.expectEqual(@intFromPtr(first), @intFromPtr(second));

    const rc: *const isize = @ptrFromInt(@intFromPtr(first) - @sizeOf(isize));
    try std.testing.expectEqual(@as(isize, 0), rc.*);
    abi.increfBox(first, 1);
    try std.testing.expectEqual(@as(isize, 0), rc.*);
}
