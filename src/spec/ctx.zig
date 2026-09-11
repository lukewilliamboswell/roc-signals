//! The contract a host must satisfy to run specs, checked when the runner is
//! instantiated rather than discovered function by function as steps run.
//!
//! The runner is generic over a `Ctx`, and until now the surface that type had
//! to provide was implied by whatever the runner happened to call: a host
//! learned it was missing something when a spec reached the step that needed
//! it. This module names the surface once. The required declarations are what
//! every spec host provides; the optional ones come in capability groups, all
//! or nothing, so a host cannot half-implement one and a step can ask
//! `Ctx.capabilities.window` at compile time instead of `@hasDecl` scattered
//! through the runner.

const std = @import("std");

/// What a host can do beyond the required surface. Each true group adds a
/// fixed set of declarations to the contract.
pub const Capabilities = struct {
    /// Browser-shaped environment: visibility, online state, storage areas
    /// and the document title.
    environment: bool = false,
    /// A window whose closure the application may veto.
    window: bool = false,
    /// Scripted Files and HTTP responses for deterministic effect execution.
    effect_fixtures: bool = false,
    /// Explicit inspection and execution of queued effect occurrences.
    manual_effects: bool = false,
    /// Per-step allocation checkpoints for the trace-allocations mode.
    allocation_trace: bool = false,
    /// Benchmark observation around calls into this same runner context.
    measured: bool = false,
    /// Declarative host state that must be installed before application mount.
    setup: bool = false,
};

/// The declarations every spec host provides.
pub const required = [_][]const u8{
    "fail",                       "writeStderr",       "allocator",
    "findElementByLocator",       "elementById",       "countElementsByLocator",
    "namedEvent",                 "shortcutEvent",     "fixedEventId",
    "dispatchRocEvent",           "hostValueUnit",     "hostValueStr",
    "hostValueBool",              "hostValueU8List",   "setElementValueIfChanged",
    "setElementCheckedIfChanged", "focusElement",      "blurElement",
    "beginComposition",           "endComposition",    "elementTextAttr",
    "tickIntervalSource",         "navigateLocation",  "historyBack",
    "historyForward",             "currentLocation",   "finishHostMetrics",
    "lastRuntimeMetrics",         "cleanupEventCount", "activeIntervalRecordCountByPeriod",
};

const environment_decls = [_][]const u8{ "setVisibility", "setOnline", "storageValue", "documentTitle" };
const window_decls = [_][]const u8{ "requestWindowClose", "windowClosed" };
const effect_fixture_decls = [_][]const u8{ "stubFileResult", "stubHttpResult" };
const manual_effect_decls = [_][]const u8{ "pendingEffectCount", "runSpecEffect" };
const allocation_trace_decls = [_][]const u8{"traceAllocationCheckpoint"};
const measured_decls = [_][]const u8{ "beginMeasurement", "endMeasurement" };
const setup_decls = [_][]const u8{
    "setInitialLocation", "setInitialVisibility", "setInitialOnline",
    "seedStorage",        "enableManualEffects",
};

/// Refuses, at compile time, a host that does not satisfy the runner contract:
/// a missing required declaration, a missing `capabilities` value, or a
/// capability that is declared but not fully implemented.
pub fn assertRunnerCtx(comptime Ctx: type) void {
    comptime {
        if (!@hasDecl(Ctx, "Host") or @TypeOf(Ctx.Host) != type) @compileError(@typeName(Ctx) ++ " must declare Host");
        if (!@hasDecl(Ctx, "RocHost") or @TypeOf(Ctx.RocHost) != type) @compileError(@typeName(Ctx) ++ " must declare RocHost");
        if (!@hasDecl(Ctx, "capabilities")) @compileError(@typeName(Ctx) ++ " must declare `pub const capabilities: ctx.Capabilities`");
        const caps: Capabilities = Ctx.capabilities;
        for (required) |name| requireFn(Ctx, name, "the spec runner");
        if (caps.environment) for (environment_decls) |name| requireFn(Ctx, name, "the environment capability");
        if (caps.window) for (window_decls) |name| requireFn(Ctx, name, "the window capability");
        if (caps.effect_fixtures) for (effect_fixture_decls) |name| requireFn(Ctx, name, "the effect_fixtures capability");
        if (caps.manual_effects) for (manual_effect_decls) |name| requireFn(Ctx, name, "the manual_effects capability");
        if (caps.allocation_trace) for (allocation_trace_decls) |name| requireFn(Ctx, name, "the allocation_trace capability");
        if (caps.measured) for (measured_decls) |name| requireFn(Ctx, name, "the measured capability");
        if (caps.setup) for (setup_decls) |name| requireFn(Ctx, name, "the setup capability");
    }
}

fn requireFn(comptime Ctx: type, comptime name: []const u8, comptime needed_by: []const u8) void {
    if (!@hasDecl(Ctx, name)) @compileError(@typeName(Ctx) ++ " is missing " ++ name ++ ", which " ++ needed_by ++ " requires");
    if (@typeInfo(@TypeOf(@field(Ctx, name))) != .@"fn") @compileError(@typeName(Ctx) ++ "." ++ name ++ " must be a function");
}

/// Whether a context declares a capability. A context with no `capabilities`
/// at all — the small test contexts that exercise one helper — has none, so
/// helpers can be called from them without satisfying the whole contract.
pub fn has(comptime Ctx: type, comptime capability: std.meta.FieldEnum(Capabilities)) bool {
    if (!@hasDecl(Ctx, "capabilities")) return false;
    const caps: Capabilities = Ctx.capabilities;
    return @field(caps, @tagName(capability));
}

test "a capability is all or nothing and an absent declaration is named" {
    const Complete = struct {
        pub const capabilities: Capabilities = .{ .window = true };
        /// Stands in for a host's close request.
        pub fn requestWindowClose() void {}
        /// Stands in for a host's closed-state read.
        pub fn windowClosed() bool {
            return false;
        }
    };
    try std.testing.expect(has(Complete, .window));
    try std.testing.expect(!has(Complete, .environment));
    const Bare = struct {};
    try std.testing.expect(!has(Bare, .window));
}
