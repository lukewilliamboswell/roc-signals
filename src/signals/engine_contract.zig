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

/// Performs verify registry ops inside the shared engine while preserving transaction and changed-set invariants.
pub fn verifyRegistryOps(comptime Ops: type) void {
    verifyDeclFn("engine RegistryOps", Ops, "retainCapability", .{ Ops, HostValueCapability }, void);
    verifyDeclFn("engine RegistryOps", Ops, "releaseCapability", .{ Ops, HostValueCapability }, void);
    verifyDeclFn("engine RegistryOps", Ops, "capabilitiesMatch", .{ Ops, HostValueCapability, HostValueCapability }, bool);
    verifyDeclFn("engine RegistryOps", Ops, "capabilityIsActive", .{ Ops, HostValueCapability }, bool);
    verifyDeclFn("engine RegistryOps", Ops, "cloneValueWithCapability", .{ Ops, HostValue, HostValueCapability }, HostValue);
    verifyDeclFn("engine RegistryOps", Ops, "callHostValueToHostValueWithCapability", .{ Ops, HostValueCapability, abi.RocErasedCallable, HostValue }, HostValue);
    verifyDeclFn("engine RegistryOps", Ops, "splitBoxWithSplit", .{ Ops, abi.RocBox, abi.RocErasedCallable }, erased_calls.RocBoxPair);
}

/// Performs verify sink inside the shared engine while preserving transaction and changed-set invariants.
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

/// Performs verify metrics inside the shared engine while preserving transaction and changed-set invariants.
pub fn verifyMetrics(comptime Metrics: type) void {
    verifyDeclFn("engine Metrics", Metrics, "bump", .{ *Metrics, engine_metrics.RuntimeMetrics.Field, u64 }, void);
}

/// Performs verify ctx inside the shared engine while preserving transaction and changed-set invariants.
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
    /// Stages a complete render-surface reset in the host command sink.
    pub fn reset(_: VerifySink) void {}
    /// Emits the already-decided command that attaches a newly created render node.
    pub fn appendNode(_: VerifySink, _: u64, _: u64, _: []const u8) void {}
    /// Ensures the host render surface contains the engine-selected node and tag.
    pub fn ensureNode(_: VerifySink, _: u64, _: []const u8) void {}
    /// Emits removal of a node whose owning scope has already been disposed by the engine.
    pub fn removeNode(_: VerifySink, _: u64) void {}
    /// Publishes the engine-selected child order for one parent.
    pub fn replaceChildren(_: VerifySink, _: u64, _: []const u64) void {}
    /// Publishes a moves-only child reorder without rebuilding surviving row structure.
    pub fn replaceChildrenForMoves(_: VerifySink, _: u64, _: []const u64) void {}
    /// Applies an engine-decided text field value to one render node.
    pub fn applyTextField(_: VerifySink, _: u64, _: RenderTextField, _: []const u8) void {}
    /// Applies an engine-decided custom text attribute to one render node.
    pub fn applyTextAttr(_: VerifySink, _: u64, _: []const u8, _: []const u8) void {}
    /// Applies an engine-decided boolean field value to one render node.
    pub fn applyBoolField(_: VerifySink, _: u64, _: RenderBoolField, _: bool) void {}
    /// Clears an engine-decided text field from one render node.
    pub fn clearTextField(_: VerifySink, _: u64, _: RenderTextField) void {}
    /// Clears an engine-decided custom text attribute from one render node.
    pub fn clearTextAttr(_: VerifySink, _: u64, _: []const u8) void {}
    /// Clears an engine-decided boolean field from one render node.
    pub fn clearBoolField(_: VerifySink, _: u64, _: RenderBoolField) void {}
    /// Publishes a validated canonical event binding selected by the engine.
    pub fn bindEvent(_: VerifySink, _: u64, _: EventBindingKey, _: EventBinding) void {}
    /// Removes a host event registration whose engine-owned binding is no longer active.
    pub fn clearEvent(_: VerifySink, _: u64, _: EventBindingKey) void {}
    /// Starts the bounded host registration for an engine-owned interval source.
    pub fn startInterval(_: VerifySink, _: u64, _: u64) void {}
    /// Cancels the host registration for an interval whose owning scope is no longer active.
    pub fn cancelInterval(_: VerifySink, _: u64) void {}
    /// Starts bounded asynchronous host work for an engine-issued task request.
    pub fn startTask(_: VerifySink, _: u64, _: []const u8, _: []const u8) void {}
    /// Cancels host work for a task request retired by engine lifecycle policy.
    pub fn cancelTask(_: VerifySink, _: u64) void {}
    /// Applies an engine-issued browser-history command without deriving routing semantics.
    pub fn navigate(_: VerifySink, _: NavigationKind, _: LocationSnapshot) void {}
    /// Applies the document title already selected by graph propagation.
    pub fn setDocumentTitle(_: VerifySink, _: []const u8) void {}
    /// Checks that the host render surface matches the engine's committed node metadata.
    pub fn debugAssertNode(_: VerifySink, _: u64, _: bool, _: ?[]const u8, _: ?u64, _: []const u64, _: ?u64, _: ?u64, _: ?u64, _: ?u64, _: ?u64, _: ?u64, _: ?u64) void {}
};

const VerifyCtxHost = struct {};

const VerifyCtx = struct {
    pub const Handle = *VerifyCtxHost;
    pub const RegistryOps = hv.RegistryOps();
    pub const Metrics = engine_metrics.RuntimeMetrics;
    pub const Sink = VerifySink;

    /// Creates the host's zeroed metric accumulator for a new engine operation.
    pub fn zeroMetrics() Metrics {
        return engine_metrics.zeroRuntimeMetrics();
    }

    /// Returns the allocator owned by this host context for shared-engine work.
    pub fn allocator(_: Handle) std.mem.Allocator {
        return std.heap.page_allocator;
    }

    /// Produces an independently owned copy through the value's app-compiled capability.
    pub fn cloneHostValue(_: Handle, value: HostValue) HostValue {
        return value;
    }

    /// Opens a checked capability frame for an app-compiled erased call.
    pub fn pushHostValueCapabilities(_: Handle, _: []const HostValueCapability) void {}

    /// Closes the current capability frame after an app-compiled erased call.
    pub fn popHostValueCapabilities(_: Handle) void {}

    /// Resolves a state cell by dense node id without scanning the signal graph.
    pub fn stateValueByNodeId(_: Handle, _: u64) HostValue {
        return 0;
    }

    /// Returns the exact app-compiled capability that owns the requested state cell.
    pub fn stateCapability(_: Handle, _: u64) HostValueCapability {
        return undefined;
    }

    /// Materializes the mount-time browser location through the source's owning capability.
    pub fn initialLocationPayload(_: Handle, _: *abi.RocHost, _: HostValueCapability) HostValue {
        return 0;
    }

    /// Returns the thin render-command sink used by the shared engine.
    pub fn sink(_: Handle) Sink {
        return .{};
    }
};

test "verifyCtx accepts a complete signals engine context" {
    comptime verifyCtx(VerifyCtx);
}
