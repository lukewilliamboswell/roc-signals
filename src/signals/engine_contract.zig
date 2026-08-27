//! Compile-time contract checks for host contexts used by the shared engine.

const std = @import("std");
const abi = @import("roc_platform_abi.zig");
const boundary = @import("boundary.zig");
const erased_calls = @import("erased_calls.zig");
const render = @import("render_commands.zig");
const render_sink = @import("render_sink.zig");
const hv = @import("host_values.zig");
const engine_metrics = @import("engine_metrics.zig");

pub const HostValue = u64;
pub const HostValueCapability = hv.HostValueCapabilityHandle;

const RenderTextField = render.TextField;
const RenderBoolField = render.BoolField;
const BoundaryPayloadDescriptor = boundary.BoundaryPayloadDescriptor;
const EventBindingKey = render_sink.EventBindingKey;
const EventBinding = render_sink.EventBinding;
const NavigationKind = render_sink.NavigationKind;
const LocationSnapshot = render_sink.LocationSnapshot;

fn verifyDeclFn(comptime owner_name: []const u8, comptime Owner: type, comptime decl_name: []const u8, comptime params: anytype, comptime return_type: type) void {
    if (!@hasDecl(Owner, decl_name)) {
        @compileError(owner_name ++ " is missing " ++ decl_name);
    }

    const fn_type = @TypeOf(@field(Owner, decl_name));
    const type_info = @typeInfo(fn_type);
    if (type_info != .@"fn") {
        @compileError(owner_name ++ "." ++ decl_name ++ " must be a function");
    }

    const fn_info = type_info.@"fn";
    if (fn_info.params.len != params.len) {
        @compileError(owner_name ++ "." ++ decl_name ++ " has the wrong parameter count");
    }
    inline for (params, 0..) |expected, index| {
        const actual = fn_info.params[index].type orelse {
            @compileError(owner_name ++ "." ++ decl_name ++ " must not use anytype parameters");
        };
        if (actual != expected) {
            @compileError(owner_name ++ "." ++ decl_name ++ " has an incompatible parameter type");
        }
    }
    const actual_return = fn_info.return_type orelse void;
    if (actual_return != return_type) {
        @compileError(owner_name ++ "." ++ decl_name ++ " has an incompatible return type");
    }
}

fn verifyTypeDecl(comptime owner_name: []const u8, comptime Owner: type, comptime decl_name: []const u8) void {
    if (!@hasDecl(Owner, decl_name)) {
        @compileError(owner_name ++ " is missing " ++ decl_name);
    }
    if (@TypeOf(@field(Owner, decl_name)) != type) {
        @compileError(owner_name ++ "." ++ decl_name ++ " must be a type");
    }
}

/// Provides the `verifyRegistryOps` operation.
pub fn verifyRegistryOps(comptime Ops: type) void {
    verifyDeclFn("engine RegistryOps", Ops, "retainCapability", .{ Ops, HostValueCapability }, void);
    verifyDeclFn("engine RegistryOps", Ops, "releaseCapability", .{ Ops, HostValueCapability }, void);
    verifyDeclFn("engine RegistryOps", Ops, "capabilitiesMatch", .{ Ops, HostValueCapability, HostValueCapability }, bool);
    verifyDeclFn("engine RegistryOps", Ops, "capabilityIsActive", .{ Ops, HostValueCapability }, bool);
    verifyDeclFn("engine RegistryOps", Ops, "cloneValueWithCapability", .{ Ops, HostValue, HostValueCapability }, HostValue);
    verifyDeclFn("engine RegistryOps", Ops, "callHostValueToHostValueWithCapability", .{ Ops, HostValueCapability, abi.RocErasedCallable, HostValue }, HostValue);
    verifyDeclFn("engine RegistryOps", Ops, "splitBoxWithSplit", .{ Ops, abi.RocBox, abi.RocErasedCallable }, erased_calls.RocBoxPair);
}

/// Provides the `verifySink` operation.
pub fn verifySink(comptime Sink: type) void {
    verifyDeclFn("engine Sink", Sink, "reset", .{Sink}, void);
    verifyDeclFn("engine Sink", Sink, "appendNode", .{ Sink, u64, u64, []const u8 }, void);
    verifyDeclFn("engine Sink", Sink, "ensureNode", .{ Sink, u64, []const u8 }, void);
    verifyDeclFn("engine Sink", Sink, "removeNode", .{ Sink, u64 }, void);
    verifyDeclFn("engine Sink", Sink, "replaceChildren", .{ Sink, u64, []const u64 }, void);
    verifyDeclFn("engine Sink", Sink, "replaceChildrenForMoves", .{ Sink, u64, []const u64 }, void);
    verifyDeclFn("engine Sink", Sink, "applyTextField", .{ Sink, u64, RenderTextField, []const u8 }, void);
    verifyDeclFn("engine Sink", Sink, "applyTextAttr", .{ Sink, u64, []const u8, []const u8 }, void);
    verifyDeclFn("engine Sink", Sink, "applyBoolField", .{ Sink, u64, RenderBoolField, bool }, void);
    verifyDeclFn("engine Sink", Sink, "clearTextField", .{ Sink, u64, RenderTextField }, void);
    verifyDeclFn("engine Sink", Sink, "clearTextAttr", .{ Sink, u64, []const u8 }, void);
    verifyDeclFn("engine Sink", Sink, "clearBoolField", .{ Sink, u64, RenderBoolField }, void);
    verifyDeclFn("engine Sink", Sink, "bindEvent", .{ Sink, u64, EventBindingKey, EventBinding }, void);
    verifyDeclFn("engine Sink", Sink, "clearEvent", .{ Sink, u64, EventBindingKey }, void);
    verifyDeclFn("engine Sink", Sink, "startInterval", .{ Sink, u64, u64 }, void);
    verifyDeclFn("engine Sink", Sink, "cancelInterval", .{ Sink, u64 }, void);
    verifyDeclFn("engine Sink", Sink, "startTask", .{ Sink, u64, []const u8, []const u8 }, void);
    verifyDeclFn("engine Sink", Sink, "cancelTask", .{ Sink, u64 }, void);
    verifyDeclFn("engine Sink", Sink, "navigate", .{ Sink, NavigationKind, LocationSnapshot }, void);
    verifyDeclFn("engine Sink", Sink, "setDocumentTitle", .{ Sink, []const u8 }, void);
    verifyDeclFn("engine Sink", Sink, "debugAssertNode", .{ Sink, u64, bool, ?[]const u8, ?u64, []const u64, ?u64, ?u64, ?u64, ?u64, ?u64, ?u64, ?u64 }, void);
}

/// Provides the `verifyMetrics` operation.
pub fn verifyMetrics(comptime Metrics: type) void {
    verifyDeclFn("engine Metrics", Metrics, "bump", .{ *Metrics, engine_metrics.RuntimeMetrics.Field, u64 }, void);
}

/// Provides the `verifyCtx` operation.
pub fn verifyCtx(comptime Ctx: type) void {
    verifyTypeDecl("engine Ctx", Ctx, "Handle");
    verifyTypeDecl("engine Ctx", Ctx, "RegistryOps");
    verifyTypeDecl("engine Ctx", Ctx, "Metrics");
    verifyTypeDecl("engine Ctx", Ctx, "Sink");

    verifyDeclFn("engine Ctx", Ctx, "zeroMetrics", .{}, Ctx.Metrics);
    verifyDeclFn("engine Ctx", Ctx, "allocator", .{Ctx.Handle}, std.mem.Allocator);
    verifyDeclFn("engine Ctx", Ctx, "cloneHostValue", .{ Ctx.Handle, HostValue }, HostValue);
    verifyDeclFn("engine Ctx", Ctx, "pushHostValueCapabilities", .{ Ctx.Handle, []const HostValueCapability }, void);
    verifyDeclFn("engine Ctx", Ctx, "popHostValueCapabilities", .{Ctx.Handle}, void);
    verifyDeclFn("engine Ctx", Ctx, "stateValueByNodeId", .{ Ctx.Handle, u64 }, HostValue);
    verifyDeclFn("engine Ctx", Ctx, "stateCapability", .{ Ctx.Handle, u64 }, HostValueCapability);
    verifyDeclFn("engine Ctx", Ctx, "initialLocationPayload", .{ Ctx.Handle, *abi.RocHost, HostValueCapability }, HostValue);
    verifyDeclFn("engine Ctx", Ctx, "sink", .{Ctx.Handle}, Ctx.Sink);
    verifyRegistryOps(Ctx.RegistryOps);
    verifyMetrics(Ctx.Metrics);
    verifySink(Ctx.Sink);
}

const VerifySink = struct {
    /// Provides the `reset` operation.
    pub fn reset(_: VerifySink) void {}
    /// Provides the `appendNode` operation.
    pub fn appendNode(_: VerifySink, _: u64, _: u64, _: []const u8) void {}
    /// Provides the `ensureNode` operation.
    pub fn ensureNode(_: VerifySink, _: u64, _: []const u8) void {}
    /// Provides the `removeNode` operation.
    pub fn removeNode(_: VerifySink, _: u64) void {}
    /// Provides the `replaceChildren` operation.
    pub fn replaceChildren(_: VerifySink, _: u64, _: []const u64) void {}
    /// Provides the `replaceChildrenForMoves` operation.
    pub fn replaceChildrenForMoves(_: VerifySink, _: u64, _: []const u64) void {}
    /// Provides the `applyTextField` operation.
    pub fn applyTextField(_: VerifySink, _: u64, _: RenderTextField, _: []const u8) void {}
    /// Provides the `applyTextAttr` operation.
    pub fn applyTextAttr(_: VerifySink, _: u64, _: []const u8, _: []const u8) void {}
    /// Provides the `applyBoolField` operation.
    pub fn applyBoolField(_: VerifySink, _: u64, _: RenderBoolField, _: bool) void {}
    /// Provides the `clearTextField` operation.
    pub fn clearTextField(_: VerifySink, _: u64, _: RenderTextField) void {}
    /// Provides the `clearTextAttr` operation.
    pub fn clearTextAttr(_: VerifySink, _: u64, _: []const u8) void {}
    /// Provides the `clearBoolField` operation.
    pub fn clearBoolField(_: VerifySink, _: u64, _: RenderBoolField) void {}
    /// Provides the `bindEvent` operation.
    pub fn bindEvent(_: VerifySink, _: u64, _: EventBindingKey, _: EventBinding) void {}
    /// Provides the `clearEvent` operation.
    pub fn clearEvent(_: VerifySink, _: u64, _: EventBindingKey) void {}
    /// Provides the `startInterval` operation.
    pub fn startInterval(_: VerifySink, _: u64, _: u64) void {}
    /// Provides the `cancelInterval` operation.
    pub fn cancelInterval(_: VerifySink, _: u64) void {}
    /// Provides the `startTask` operation.
    pub fn startTask(_: VerifySink, _: u64, _: []const u8, _: []const u8) void {}
    /// Provides the `cancelTask` operation.
    pub fn cancelTask(_: VerifySink, _: u64) void {}
    /// Provides the `navigate` operation.
    pub fn navigate(_: VerifySink, _: NavigationKind, _: LocationSnapshot) void {}
    /// Provides the `setDocumentTitle` operation.
    pub fn setDocumentTitle(_: VerifySink, _: []const u8) void {}
    /// Provides the `debugAssertNode` operation.
    pub fn debugAssertNode(_: VerifySink, _: u64, _: bool, _: ?[]const u8, _: ?u64, _: []const u64, _: ?u64, _: ?u64, _: ?u64, _: ?u64, _: ?u64, _: ?u64, _: ?u64) void {}
};

const VerifyCtxHost = struct {};

const VerifyCtx = struct {
    pub const Handle = *VerifyCtxHost;
    pub const RegistryOps = hv.RegistryOps();
    pub const Metrics = engine_metrics.RuntimeMetrics;
    pub const Sink = VerifySink;

    /// Provides the `zeroMetrics` operation.
    pub fn zeroMetrics() Metrics {
        return engine_metrics.zeroRuntimeMetrics();
    }

    /// Provides the `allocator` operation.
    pub fn allocator(_: Handle) std.mem.Allocator {
        return std.heap.page_allocator;
    }

    /// Provides the `cloneHostValue` operation.
    pub fn cloneHostValue(_: Handle, value: HostValue) HostValue {
        return value;
    }

    /// Provides the `pushHostValueCapabilities` operation.
    pub fn pushHostValueCapabilities(_: Handle, _: []const HostValueCapability) void {}

    /// Provides the `popHostValueCapabilities` operation.
    pub fn popHostValueCapabilities(_: Handle) void {}

    /// Provides the `stateValueByNodeId` operation.
    pub fn stateValueByNodeId(_: Handle, _: u64) HostValue {
        return 0;
    }

    /// Provides the `stateCapability` operation.
    pub fn stateCapability(_: Handle, _: u64) HostValueCapability {
        return undefined;
    }

    /// Provides the `initialLocationPayload` operation.
    pub fn initialLocationPayload(_: Handle, _: *abi.RocHost, _: HostValueCapability) HostValue {
        return 0;
    }

    /// Provides the `sink` operation.
    pub fn sink(_: Handle) Sink {
        return .{};
    }
};

test "verifyCtx accepts a complete signals engine context" {
    comptime verifyCtx(VerifyCtx);
}
