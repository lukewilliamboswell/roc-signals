//! Parser for text-based Signals example specs and assertions.

const std = @import("std");
const signals = @import("signals");
const boundary = signals.boundary;
const sexpr = @import("sexpr.zig");
const http_fixtures = @import("http_fixtures.zig");

pub const SpecCommandType = enum {
    click,
    real_click,
    pointer_down,
    pointer_up,
    pointer_enter,
    pointer_leave,
    key_down,
    focus,
    blur,
    change,
    select_option,
    composition_start,
    composition_end,
    custom_event,
    submit,
    fill,
    check,
    uncheck,
    expect_text,
    expect_visible,
    expect_absent,
    expect_value,
    expect_attr,
    expect_no_attr,
    expect_checked,
    expect_disabled,
    expect_updates,
    stub_http_result,
    seed_http_result,
    manual_effects,
    run_effect,
    expect_pending_effects,
    tick_interval,
    tick_interval_if_active,
    expect_cleanup,
    expect_interval,
    set_initial_location,
    set_initial_visibility,
    set_initial_online,
    seed_local_storage,
    seed_session_storage,
    navigate,
    set_visibility,
    set_online,
    history_back,
    history_forward,
    expect_current_location,
    expect_document_title,
    expect_local_storage,
    expect_session_storage,
    expect_no_local_storage,
    expect_no_session_storage,
    mark_metrics,
    expect_metric_delta,
    expect_metric_delta_at_most,
};

/// The lifecycle role of a command in a complete spec execution.
///
/// This is deliberately exhaustive: adding vocabulary requires declaring how
/// runners sequence it instead of silently dropping the new command.
pub const StepRole = enum { setup, operation, assertion, measurement_boundary };

/// Returns the execution role that every runner must preserve for this step.
pub fn stepRole(kind: SpecCommandType) StepRole {
    return switch (kind) {
        .set_initial_location, .set_initial_visibility, .set_initial_online, .seed_local_storage, .seed_session_storage, .seed_http_result, .manual_effects => .setup,

        .click, .real_click, .pointer_down, .pointer_up, .pointer_enter, .pointer_leave, .key_down, .focus, .blur, .change, .select_option, .composition_start, .composition_end, .custom_event, .submit, .fill, .check, .uncheck, .stub_http_result, .run_effect, .tick_interval, .tick_interval_if_active, .navigate, .set_visibility, .set_online, .history_back, .history_forward => .operation,

        .expect_text, .expect_visible, .expect_absent, .expect_value, .expect_attr, .expect_no_attr, .expect_checked, .expect_disabled, .expect_updates, .expect_pending_effects, .expect_cleanup, .expect_interval, .expect_current_location, .expect_document_title, .expect_local_storage, .expect_session_storage, .expect_no_local_storage, .expect_no_session_storage, .expect_metric_delta, .expect_metric_delta_at_most => .assertion,

        .mark_metrics => .measurement_boundary,
    };
}

test "step roles distinguish ordered fixtures from setup and assertions" {
    try std.testing.expectEqual(StepRole.setup, stepRole(.seed_http_result));
    try std.testing.expectEqual(StepRole.operation, stepRole(.stub_http_result));
    try std.testing.expectEqual(StepRole.operation, stepRole(.run_effect));
    try std.testing.expectEqual(StepRole.assertion, stepRole(.expect_pending_effects));
    try std.testing.expectEqual(StepRole.measurement_boundary, stepRole(.mark_metrics));
}

/// Writes a parsed spec in one deterministic line per command, every field
/// spelled out. This is what a spec *means* to the runner, independent of how
/// it was spelled, and the checked-in golden of every spec's canonical form is
/// the proof that a parser change changed nothing: the same spec must produce
/// the same command sequence.
pub fn writeCanonical(writer: *std.Io.Writer, spec: ParsedTestSpec) std.Io.Writer.Error!void {
    try writer.writeAll("test ");
    try writeQuoted(writer, spec.name);
    try writer.writeByte('\n');
    for (spec.commands) |cmd| {
        const view = legacyView(cmd.step);
        try writer.print("  {d}: {s}", .{ cmd.line_num, @tagName(cmd.step) });
        try writer.print(" locator={s}", .{@tagName(view.locator.kind)});
        try writeField(writer, "role", view.locator.role);
        try writeField(writer, "name", view.locator.name);
        try writeField(writer, "label", view.locator.label);
        try writeField(writer, "text", view.locator.text);
        try writeField(writer, "test_id", view.locator.test_id);
        try writeField(writer, "task", view.task);
        if (view.http_stub) |stub| try writeHttpStub(writer, stub);
        try writeField(writer, "attr", view.attr);
        if (view.interval) |value| try writer.print(" interval={d}", .{value});
        try writeField(writer, "expected", view.expected);
        if (view.count) |value| try writer.print(" count={d}", .{value});
        if (view.delta) |value| try writer.print(" delta={d}", .{value});
        if (view.boolean) |value| try writer.print(" bool={}", .{value});
        try writer.writeByte('\n');
    }
}

/// A scripted HTTP answer, every field spelled out in the order the form
/// declares them, so a stub that changes shape moves a golden line.
fn writeHttpStub(writer: *std.Io.Writer, stub: http_fixtures.Stub) std.Io.Writer.Error!void {
    try writer.print(" http={s}", .{@tagName(stub)});
    switch (stub) {
        .response => |value| {
            try writeField(writer, "uri", value.uri);
            try writer.print(" status={d} headers=[", .{value.status});
            for (value.headers, 0..) |header, index| {
                if (index > 0) try writer.writeByte(' ');
                try writeQuoted(writer, header.name);
                try writer.writeByte('=');
                try writeQuoted(writer, header.value);
            }
            try writer.writeByte(']');
            try writeField(writer, "body", value.body);
        },
        .reject => |value| {
            try writer.print(" kind={s}", .{@tagName(value.kind)});
            try writeField(writer, "detail", value.detail);
        },
    }
}

/// The flat view of a step the canonical form spells: one slot per kind of value, so a step's payload is legible without
/// knowing its type. The typed union is the model; this is its projection.
pub const LegacyLocator = struct {
    kind: LocatorKind = .none,
    role: ?[]const u8 = null,
    name: ?[]const u8 = null,
    label: ?[]const u8 = null,
    text: ?[]const u8 = null,
    test_id: ?[]const u8 = null,
};

pub const LegacyView = struct {
    locator: LegacyLocator = .{},
    task: ?[]const u8 = null,
    http_stub: ?http_fixtures.Stub = null,
    attr: ?[]const u8 = null,
    interval: ?u64 = null,
    expected: ?[]const u8 = null,
    count: ?u64 = null,
    delta: ?i64 = null,
    boolean: ?bool = null,
};

/// Projects a typed step onto the flat view. Every string here borrows the step.
pub fn legacyView(step: Step) LegacyView {
    return switch (step) {
        .click, .real_click, .pointer_down, .pointer_up, .pointer_enter, .pointer_leave, .focus, .blur, .composition_start, .composition_end, .submit, .check, .uncheck, .expect_visible, .expect_absent => |target| .{ .locator = target.legacy() },
        .change, .select_option, .fill, .expect_text, .expect_value => |args| .{ .locator = args.target.legacy(), .expected = args.text },
        .expect_checked, .expect_disabled => |args| .{ .locator = args.target.legacy(), .boolean = args.expected },
        .expect_updates => |args| .{ .locator = args.target.legacy(), .count = args.count },
        .key_down => |args| .{ .locator = args.target.legacy(), .expected = args.key, .boolean = args.shift },
        .custom_event => |args| .{ .locator = args.target.legacy(), .task = args.name, .expected = args.detail },
        .expect_attr => |args| .{ .locator = args.target.legacy(), .attr = args.name, .expected = args.value },
        .expect_no_attr => |args| .{ .locator = args.target.legacy(), .attr = args.name },
        .stub_http_result, .seed_http_result => |args| .{ .task = args.label, .http_stub = args.stub },
        .tick_interval, .tick_interval_if_active => |period| .{ .interval = period },
        .expect_cleanup => |args| .{ .task = args.name, .count = args.count },
        .run_effect, .expect_pending_effects => |count| .{ .count = count },
        .expect_interval => |args| .{ .interval = args.period_ms, .count = args.count },
        .set_initial_location, .set_initial_visibility, .set_initial_online, .navigate, .set_visibility, .set_online, .expect_current_location, .expect_document_title => |text| .{ .expected = text },
        .expect_no_local_storage, .expect_no_session_storage => |key| .{ .task = key },
        .seed_local_storage, .seed_session_storage, .expect_local_storage, .expect_session_storage => |pair| .{ .task = pair.key, .expected = pair.value },
        .expect_metric_delta, .expect_metric_delta_at_most => |args| .{ .expected = args.metric, .delta = args.delta },
        .history_back, .history_forward, .mark_metrics, .manual_effects => .{},
    };
}

fn writeField(writer: *std.Io.Writer, name: []const u8, value: ?[]const u8) std.Io.Writer.Error!void {
    if (value) |text| {
        try writer.print(" {s}=", .{name});
        try writeQuoted(writer, text);
    }
}

/// Quotes with the same escapes the reader accepts, so a golden line is
/// unambiguous even for text holding quotes, backslashes, or line ends.
fn writeQuoted(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    for (text) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

pub const LocatorKind = enum {
    none,
    role_name,
    label,
    text,
    test_id,
};

pub const RoleName = struct { role: []const u8, name: []const u8 };

/// A semantic locator with exactly the payload its kind requires. Impossible
/// combinations such as a label locator carrying a test id cannot be built.
pub const Locator = union(LocatorKind) {
    none: void,
    role_name: RoleName,
    label: []const u8,
    text: []const u8,
    test_id: []const u8,

    fn deinit(self: Locator, allocator: std.mem.Allocator) void {
        switch (self) {
            .none => {},
            .role_name => |value| {
                allocator.free(value.role);
                allocator.free(value.name);
            },
            .label, .text, .test_id => |value| allocator.free(value),
        }
    }

    /// Projects the typed locator only at the raw cross-language boundary.
    pub fn legacy(self: Locator) LegacyLocator {
        return switch (self) {
            .none => .{},
            .role_name => |value| .{ .kind = .role_name, .role = value.role, .name = value.name },
            .label => |value| .{ .kind = .label, .label = value },
            .text => |value| .{ .kind = .text, .text = value },
            .test_id => |value| .{ .kind = .test_id, .test_id = value },
        };
    }
};

fn emptyLocator() Locator {
    return .none;
}

pub const LocatorText = struct { target: Locator, text: []const u8 };
pub const LocatorBool = struct { target: Locator, expected: bool };
pub const LocatorCount = struct { target: Locator, count: u64 };
pub const KeyDown = struct { target: Locator, key: []const u8, shift: bool };
pub const CustomEvent = struct { target: Locator, name: []const u8, detail: []const u8 };
pub const Attr = struct { target: Locator, name: []const u8, value: []const u8 };
pub const AttrName = struct { target: Locator, name: []const u8 };
/// A scripted HTTP answer with the label the spec gave it.
pub const HttpStub = struct { label: []const u8, stub: http_fixtures.Stub };
pub const NamedCount = struct { name: []const u8, count: u64 };
pub const IntervalCount = struct { period_ms: u64, count: u64 };
pub const KeyValue = struct { key: []const u8, value: []const u8 };
pub const MetricDelta = struct { metric: []const u8, delta: i64 };

/// One step with exactly the payload its kind carries. The union is tagged by
/// `SpecCommandType` so `@tagName` still spells the step for the ABI and the
/// reports, and a runner switch that forgets a kind fails to compile.
pub const Step = union(SpecCommandType) {
    click: Locator,
    real_click: Locator,
    pointer_down: Locator,
    pointer_up: Locator,
    pointer_enter: Locator,
    pointer_leave: Locator,
    key_down: KeyDown,
    focus: Locator,
    blur: Locator,
    change: LocatorText,
    select_option: LocatorText,
    composition_start: Locator,
    composition_end: Locator,
    custom_event: CustomEvent,
    submit: Locator,
    fill: LocatorText,
    check: Locator,
    uncheck: Locator,
    expect_text: LocatorText,
    expect_visible: Locator,
    expect_absent: Locator,
    expect_value: LocatorText,
    expect_attr: Attr,
    expect_no_attr: AttrName,
    expect_checked: LocatorBool,
    expect_disabled: LocatorBool,
    expect_updates: LocatorCount,
    stub_http_result: HttpStub,
    seed_http_result: HttpStub,
    manual_effects: void,
    run_effect: u64,
    expect_pending_effects: u64,
    tick_interval: u64,
    tick_interval_if_active: u64,
    expect_cleanup: NamedCount,
    expect_interval: IntervalCount,
    set_initial_location: []const u8,
    set_initial_visibility: []const u8,
    set_initial_online: []const u8,
    seed_local_storage: KeyValue,
    seed_session_storage: KeyValue,
    navigate: []const u8,
    set_visibility: []const u8,
    set_online: []const u8,
    history_back: void,
    history_forward: void,
    expect_current_location: []const u8,
    expect_document_title: []const u8,
    expect_local_storage: KeyValue,
    expect_session_storage: KeyValue,
    expect_no_local_storage: []const u8,
    expect_no_session_storage: []const u8,
    mark_metrics: void,
    expect_metric_delta: MetricDelta,
    expect_metric_delta_at_most: MetricDelta,

    /// The kind of this step, for reports and the ABI.
    pub fn kind(self: Step) SpecCommandType {
        return std.meta.activeTag(self);
    }

    /// Releases every string and locator the payload owns, by walking its
    /// fields: a new payload type needs no new release code.
    pub fn deinit(self: Step, allocator: std.mem.Allocator) void {
        switch (self) {
            inline else => |payload| freePayload(allocator, payload),
        }
    }
};

fn freePayload(allocator: std.mem.Allocator, payload: anytype) void {
    const T = @TypeOf(payload);
    if (T == void or T == bool or T == u64 or T == i64) return;
    if (T == []const u8) return allocator.free(payload);
    if (T == Locator or T == http_fixtures.Stub) return payload.deinit(allocator);
    inline for (std.meta.fields(T)) |field| freePayload(allocator, @field(payload, field.name));
}

pub const SpecCommand = struct {
    step: Step,
    line_num: usize,
    /// One-based source column of the step form. Older synthetic commands may
    /// omit it and retain the conventional first column.
    column_num: usize = 1,

    /// The kind of this command, for reports and the ABI.
    pub fn kind(self: SpecCommand) SpecCommandType {
        return self.step.kind();
    }
};

/// Releases every allocation owned by spec commands.
pub fn freeSpecCommands(allocator: std.mem.Allocator, commands: []SpecCommand) void {
    for (commands) |cmd| cmd.step.deinit(allocator);
    if (commands.len > 0) {
        allocator.free(commands);
    }
}

pub const ParsedTestSpec = struct {
    name: []const u8,
    commands: []SpecCommand,

    /// Releases every resource owned by this value and leaves no retained host or Roc ownership behind.
    pub fn deinit(self: ParsedTestSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        freeSpecCommands(allocator, self.commands);
    }
};

pub const ParseError = error{
    InvalidFormat,
    OutOfMemory,
    FileNotFound,
    IoError,
};

/// Parses test spec file and rejects malformed input without semantic recovery.
pub fn parseTestSpecFile(allocator: std.mem.Allocator, file_path: []const u8) ParseError!ParsedTestSpec {
    const io = std.Io.Threaded.global_single_threaded.io();
    const content = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return ParseError.FileNotFound,
        else => return ParseError.IoError,
    };
    defer allocator.free(content);

    return parseSExprTestSpec(allocator, content);
}

fn dupePlain(allocator: std.mem.Allocator, input: []const u8) ParseError![]u8 {
    return allocator.dupe(u8, input) catch return ParseError.OutOfMemory;
}

/// Parses a deterministic location snapshot fixture from spec text.
pub fn locationSnapshotFromSpecText(text: []const u8) ParseError!boundary.LocationSnapshot {
    var before_hash = text;
    var hash: []const u8 = "";
    if (std.mem.indexOfScalar(u8, text, '#')) |hash_index| {
        before_hash = text[0..hash_index];
        hash = text[hash_index + 1 ..];
    }

    var path = before_hash;
    var query: []const u8 = "";
    if (std.mem.indexOfScalar(u8, before_hash, '?')) |query_index| {
        path = before_hash[0..query_index];
        query = before_hash[query_index + 1 ..];
    }
    if (path.len == 0) path = "/";
    if (path[0] != '/') return ParseError.InvalidFormat;

    return .{ .path = path, .query = query, .hash = hash };
}

/// Parses a deterministic visibility snapshot fixture from spec text.
pub fn visibilitySnapshotFromSpecText(text: []const u8) ParseError!boundary.VisibilitySnapshot {
    if (std.mem.eql(u8, text, "visible")) return .visible;
    if (std.mem.eql(u8, text, "hidden")) return .hidden;
    return ParseError.InvalidFormat;
}

/// Parses a deterministic online snapshot fixture from spec text.
pub fn onlineSnapshotFromSpecText(text: []const u8) ParseError!boundary.OnlineSnapshot {
    if (std.mem.eql(u8, text, "online")) return .online;
    if (std.mem.eql(u8, text, "offline")) return .offline;
    return ParseError.InvalidFormat;
}

/// Parses sexpr test spec and rejects malformed input without semantic recovery.
pub fn parseSExprTestSpec(allocator: std.mem.Allocator, content: []const u8) ParseError!ParsedTestSpec {
    var reader = sexpr.Reader.init(allocator, content);
    const root = reader.readOne() catch |err| switch (err) {
        error.InvalidSyntax => return ParseError.InvalidFormat,
        error.OutOfMemory => return ParseError.OutOfMemory,
    };
    defer root.deinit(allocator);

    const root_items = exprList(root) orelse return ParseError.InvalidFormat;
    if (root_items.len < 3) return ParseError.InvalidFormat;
    if (!exprSymbolEql(root_items[0], "test")) return ParseError.InvalidFormat;
    const name = exprString(root_items[1]) orelse return ParseError.InvalidFormat;
    const name_copy = allocator.dupe(u8, name) catch return ParseError.OutOfMemory;
    errdefer allocator.free(name_copy);

    var commands: std.ArrayListUnmanaged(SpecCommand) = .empty;
    errdefer freeCommandList(allocator, &commands);
    var saw_setup = false;
    var saw_steps = false;

    for (root_items[2..]) |section| {
        const section_items = exprList(section) orelse return ParseError.InvalidFormat;
        if (section_items.len == 0) return ParseError.InvalidFormat;
        if (exprSymbolEql(section_items[0], "setup")) {
            if (saw_setup or saw_steps) return ParseError.InvalidFormat;
            saw_setup = true;
            for (section_items[1..]) |form| try appendDecodedForm(allocator, &commands, form, true);
        } else if (exprSymbolEql(section_items[0], "steps")) {
            if (saw_steps) return ParseError.InvalidFormat;
            saw_steps = true;
            if (section_items.len == 1) return ParseError.InvalidFormat;
            for (section_items[1..]) |form| try appendDecodedForm(allocator, &commands, form, false);
        } else {
            return ParseError.InvalidFormat;
        }
    }
    if (!saw_steps) return ParseError.InvalidFormat;
    return .{
        .name = name_copy,
        .commands = commands.toOwnedSlice(allocator) catch return ParseError.OutOfMemory,
    };
}

/// The pre-mount state a `(setup ...)` may declare. Setup is declarative:
/// nothing here dispatches an event or touches the tree.
fn decodeSetupForm(allocator: std.mem.Allocator, head: []const u8, args: []const sexpr.Expr, line: usize) ParseError!SpecCommand {
    const step: Step = if (std.mem.eql(u8, head, "manual-effects")) blk: {
        if (args.len != 0) return ParseError.InvalidFormat;
        break :blk .manual_effects;
    } else if (std.mem.eql(u8, head, "initial-location"))
        .{ .set_initial_location = try oneText(allocator, args) }
    else if (std.mem.eql(u8, head, "initial-visibility"))
        .{ .set_initial_visibility = try oneSymbol(allocator, args) }
    else if (std.mem.eql(u8, head, "initial-online"))
        .{ .set_initial_online = try oneSymbol(allocator, args) }
    else if (std.mem.eql(u8, head, "local-storage"))
        .{ .seed_local_storage = try keyValue(allocator, args) }
    else if (std.mem.eql(u8, head, "session-storage"))
        .{ .seed_session_storage = try keyValue(allocator, args) }
    else
        return ParseError.InvalidFormat;
    return .{ .step = step, .line_num = line };
}

/// Every step a `(test ...)` may take, decoded straight from its form. The
/// head is the spec spelling; the tag is the runner's. Argument shapes are
/// checked here once, with the line of the form in every refusal. Setup
/// vocabulary is refused inside steps by falling through to the unknown-head
/// refusal: none of those heads is a step.
fn decodeStepForm(allocator: std.mem.Allocator, head: []const u8, args: []const sexpr.Expr, line: usize) ParseError!SpecCommand {
    if (std.mem.eql(u8, head, "run-effect") or std.mem.eql(u8, head, "expect-pending-effects")) {
        if (args.len != 1) return ParseError.InvalidFormat;
        const count = try exprUnsigned(args[0]);
        return .{
            .step = if (std.mem.eql(u8, head, "run-effect")) .{ .run_effect = count } else .{ .expect_pending_effects = count },
            .line_num = line,
        };
    }
    const Shape = enum { locator, locator_text, locator_bool, locator_count, text, symbol, key_value, key, named_count, interval, metric_delta, none };
    const Form = struct { head: []const u8, tag: SpecCommandType, shape: Shape };
    const forms = [_]Form{
        .{ .head = "click", .tag = .click, .shape = .locator },
        .{ .head = "real-click", .tag = .real_click, .shape = .locator },
        .{ .head = "pointer-down", .tag = .pointer_down, .shape = .locator },
        .{ .head = "pointer-up", .tag = .pointer_up, .shape = .locator },
        .{ .head = "pointer-enter", .tag = .pointer_enter, .shape = .locator },
        .{ .head = "pointer-leave", .tag = .pointer_leave, .shape = .locator },
        .{ .head = "focus", .tag = .focus, .shape = .locator },
        .{ .head = "blur", .tag = .blur, .shape = .locator },
        .{ .head = "composition-start", .tag = .composition_start, .shape = .locator },
        .{ .head = "composition-end", .tag = .composition_end, .shape = .locator },
        .{ .head = "submit", .tag = .submit, .shape = .locator },
        .{ .head = "check", .tag = .check, .shape = .locator },
        .{ .head = "uncheck", .tag = .uncheck, .shape = .locator },
        .{ .head = "expect-visible", .tag = .expect_visible, .shape = .locator },
        .{ .head = "expect-absent", .tag = .expect_absent, .shape = .locator },
        .{ .head = "fill", .tag = .fill, .shape = .locator_text },
        .{ .head = "change", .tag = .change, .shape = .locator_text },
        .{ .head = "select-option", .tag = .select_option, .shape = .locator_text },
        .{ .head = "expect-text", .tag = .expect_text, .shape = .locator_text },
        .{ .head = "expect-value", .tag = .expect_value, .shape = .locator_text },
        .{ .head = "expect-checked", .tag = .expect_checked, .shape = .locator_bool },
        .{ .head = "expect-disabled", .tag = .expect_disabled, .shape = .locator_bool },
        .{ .head = "expect-updates", .tag = .expect_updates, .shape = .locator_count },
        .{ .head = "navigate", .tag = .navigate, .shape = .text },
        .{ .head = "expect-current-location", .tag = .expect_current_location, .shape = .text },
        .{ .head = "assert-current-location", .tag = .expect_current_location, .shape = .text },
        .{ .head = "expect-document-title", .tag = .expect_document_title, .shape = .text },
        .{ .head = "set-visibility", .tag = .set_visibility, .shape = .symbol },
        .{ .head = "set-online", .tag = .set_online, .shape = .symbol },
        .{ .head = "history-back", .tag = .history_back, .shape = .none },
        .{ .head = "history-forward", .tag = .history_forward, .shape = .none },
        .{ .head = "mark-metrics", .tag = .mark_metrics, .shape = .none },
        .{ .head = "expect-local-storage", .tag = .expect_local_storage, .shape = .key_value },
        .{ .head = "expect-session-storage", .tag = .expect_session_storage, .shape = .key_value },
        .{ .head = "expect-no-local-storage", .tag = .expect_no_local_storage, .shape = .key },
        .{ .head = "expect-no-session-storage", .tag = .expect_no_session_storage, .shape = .key },
        .{ .head = "expect-cleanup", .tag = .expect_cleanup, .shape = .named_count },
        .{ .head = "tick-interval", .tag = .tick_interval, .shape = .interval },
        .{ .head = "tick-interval-if-active", .tag = .tick_interval_if_active, .shape = .interval },
        .{ .head = "expect-metric-delta", .tag = .expect_metric_delta, .shape = .metric_delta },
        .{ .head = "expect-metric-delta-at-most", .tag = .expect_metric_delta_at_most, .shape = .metric_delta },
    };
    inline for (forms) |form| {
        if (std.mem.eql(u8, head, form.head)) {
            const name = @tagName(form.tag);
            const step: Step = switch (form.shape) {
                .locator => @unionInit(Step, name, try oneLocator(allocator, args)),
                .locator_text => @unionInit(Step, name, try locatorText(allocator, args)),
                .locator_bool => @unionInit(Step, name, try locatorBool(allocator, args)),
                .locator_count => @unionInit(Step, name, try locatorCount(allocator, args)),
                .text => @unionInit(Step, name, try oneText(allocator, args)),
                .symbol => @unionInit(Step, name, try oneSymbol(allocator, args)),
                .key_value => @unionInit(Step, name, try keyValue(allocator, args)),
                .key => @unionInit(Step, name, try oneText(allocator, args)),
                .named_count => @unionInit(Step, name, try namedCount(allocator, args)),
                .interval => blk: {
                    if (args.len != 1) return ParseError.InvalidFormat;
                    break :blk @unionInit(Step, name, try exprUnsigned(args[0]));
                },
                .metric_delta => @unionInit(Step, name, try metricDelta(allocator, args)),
                .none => if (args.len == 0) @unionInit(Step, name, {}) else return ParseError.InvalidFormat,
            };
            return .{ .step = step, .line_num = line };
        }
    }
    // The forms whose shape is their own.
    const step: Step = if (std.mem.eql(u8, head, "key-down")) blk: {
        if (args.len != 3) return ParseError.InvalidFormat;
        const target = try locatorFromExpr(allocator, args[0]);
        errdefer target.deinit(allocator);
        const key = try dupePlain(allocator, exprString(args[1]) orelse return ParseError.InvalidFormat);
        errdefer allocator.free(key);
        break :blk .{ .key_down = .{ .target = target, .key = key, .shift = try exprBool(args[2]) } };
    } else if (std.mem.eql(u8, head, "custom-event")) blk: {
        if (args.len != 3) return ParseError.InvalidFormat;
        const target = try locatorFromExpr(allocator, args[0]);
        errdefer target.deinit(allocator);
        const name = try dupePlain(allocator, exprString(args[1]) orelse return ParseError.InvalidFormat);
        errdefer allocator.free(name);
        const detail = try dupePlain(allocator, exprString(args[2]) orelse return ParseError.InvalidFormat);
        break :blk .{ .custom_event = .{ .target = target, .name = name, .detail = detail } };
    } else if (std.mem.eql(u8, head, "expect-attr")) blk: {
        if (args.len != 3) return ParseError.InvalidFormat;
        const target = try locatorFromExpr(allocator, args[0]);
        errdefer target.deinit(allocator);
        const name = try dupePlain(allocator, exprSymbol(args[1]) orelse exprString(args[1]) orelse return ParseError.InvalidFormat);
        errdefer allocator.free(name);
        const value = try dupePlain(allocator, exprString(args[2]) orelse return ParseError.InvalidFormat);
        break :blk .{ .expect_attr = .{ .target = target, .name = name, .value = value } };
    } else if (std.mem.eql(u8, head, "expect-no-attr")) blk: {
        if (args.len != 2) return ParseError.InvalidFormat;
        const target = try locatorFromExpr(allocator, args[0]);
        errdefer target.deinit(allocator);
        const name = try dupePlain(allocator, exprSymbol(args[1]) orelse exprString(args[1]) orelse return ParseError.InvalidFormat);
        break :blk .{ .expect_no_attr = .{ .target = target, .name = name } };
    } else if (std.mem.eql(u8, head, "expect-interval")) blk: {
        if (args.len != 2) return ParseError.InvalidFormat;
        break :blk .{ .expect_interval = .{ .period_ms = try exprUnsigned(args[0]), .count = try exprUnsigned(args[1]) } };
    } else return ParseError.InvalidFormat;
    return .{ .step = step, .line_num = line };
}

fn nonEmptyString(expr: sexpr.Expr) ParseError![]const u8 {
    const text = exprString(expr) orelse return ParseError.InvalidFormat;
    if (text.len == 0) return ParseError.InvalidFormat;
    return text;
}

fn oneLocator(allocator: std.mem.Allocator, args: []const sexpr.Expr) ParseError!Locator {
    if (args.len != 1) return ParseError.InvalidFormat;
    return locatorFromExpr(allocator, args[0]);
}

fn oneText(allocator: std.mem.Allocator, args: []const sexpr.Expr) ParseError![]const u8 {
    if (args.len != 1) return ParseError.InvalidFormat;
    return dupePlain(allocator, exprString(args[0]) orelse return ParseError.InvalidFormat);
}

/// A bare-word value such as `hidden` or `offline`; the host validates the
/// vocabulary through `visibilitySnapshotFromSpecText` and its siblings.
fn oneSymbol(allocator: std.mem.Allocator, args: []const sexpr.Expr) ParseError![]const u8 {
    if (args.len != 1) return ParseError.InvalidFormat;
    return dupePlain(allocator, exprSymbol(args[0]) orelse return ParseError.InvalidFormat);
}

fn locatorText(allocator: std.mem.Allocator, args: []const sexpr.Expr) ParseError!LocatorText {
    if (args.len != 2) return ParseError.InvalidFormat;
    const target = try locatorFromExpr(allocator, args[0]);
    errdefer target.deinit(allocator);
    return .{ .target = target, .text = try dupePlain(allocator, exprString(args[1]) orelse return ParseError.InvalidFormat) };
}

fn locatorBool(allocator: std.mem.Allocator, args: []const sexpr.Expr) ParseError!LocatorBool {
    if (args.len != 2) return ParseError.InvalidFormat;
    const target = try locatorFromExpr(allocator, args[0]);
    errdefer target.deinit(allocator);
    return .{ .target = target, .expected = try exprBool(args[1]) };
}

fn locatorCount(allocator: std.mem.Allocator, args: []const sexpr.Expr) ParseError!LocatorCount {
    if (args.len != 2) return ParseError.InvalidFormat;
    const target = try locatorFromExpr(allocator, args[0]);
    errdefer target.deinit(allocator);
    return .{ .target = target, .count = try exprUnsigned(args[1]) };
}

fn keyValue(allocator: std.mem.Allocator, args: []const sexpr.Expr) ParseError!KeyValue {
    if (args.len != 2) return ParseError.InvalidFormat;
    const key = try dupePlain(allocator, exprString(args[0]) orelse return ParseError.InvalidFormat);
    errdefer allocator.free(key);
    return .{ .key = key, .value = try dupePlain(allocator, exprString(args[1]) orelse return ParseError.InvalidFormat) };
}

fn namedCount(allocator: std.mem.Allocator, args: []const sexpr.Expr) ParseError!NamedCount {
    if (args.len != 2) return ParseError.InvalidFormat;
    const name = try dupePlain(allocator, exprString(args[0]) orelse return ParseError.InvalidFormat);
    errdefer allocator.free(name);
    return .{ .name = name, .count = try exprUnsigned(args[1]) };
}

fn metricDelta(allocator: std.mem.Allocator, args: []const sexpr.Expr) ParseError!MetricDelta {
    if (args.len != 2) return ParseError.InvalidFormat;
    const metric = try dupePlain(allocator, exprSymbol(args[0]) orelse return ParseError.InvalidFormat);
    errdefer allocator.free(metric);
    return .{ .metric = metric, .delta = try exprInteger(args[1]) };
}

fn exprInteger(expr: sexpr.Expr) ParseError!i64 {
    return switch (expr.value) {
        .atom => |atom| switch (atom) {
            .integer => |value| value,
            else => ParseError.InvalidFormat,
        },
        else => ParseError.InvalidFormat,
    };
}

fn exprUnsigned(expr: sexpr.Expr) ParseError!u64 {
    return switch (expr.value) {
        .atom => |atom| switch (atom) {
            .integer => |value| if (value < 0) ParseError.InvalidFormat else @intCast(value),
            else => ParseError.InvalidFormat,
        },
        else => ParseError.InvalidFormat,
    };
}

fn exprBool(expr: sexpr.Expr) ParseError!bool {
    return switch (expr.value) {
        .atom => |atom| switch (atom) {
            .boolean => |value| value,
            else => ParseError.InvalidFormat,
        },
        else => ParseError.InvalidFormat,
    };
}

/// Decodes a locator form: `(role button :name "Save")`, `(label "Email")`,
/// `(text "Loading")` or `(test-id "status")`. This is the one locator decoder;
/// every host resolves the value it produces.
fn locatorFromExpr(allocator: std.mem.Allocator, expr: sexpr.Expr) ParseError!Locator {
    const items = exprList(expr) orelse return ParseError.InvalidFormat;
    if (items.len == 0) return ParseError.InvalidFormat;
    const kind = exprSymbol(items[0]) orelse return ParseError.InvalidFormat;
    if (std.mem.eql(u8, kind, "role")) {
        if (items.len != 4 or !exprSymbolEql(items[2], ":name")) return ParseError.InvalidFormat;
        const role = exprSymbol(items[1]) orelse exprString(items[1]) orelse return ParseError.InvalidFormat;
        const name = exprString(items[3]) orelse return ParseError.InvalidFormat;
        const role_copy = try dupePlain(allocator, role);
        errdefer allocator.free(role_copy);
        return .{ .role_name = .{ .role = role_copy, .name = try dupePlain(allocator, name) } };
    }
    if (items.len != 2) return ParseError.InvalidFormat;
    const value = exprString(items[1]) orelse return ParseError.InvalidFormat;
    if (std.mem.eql(u8, kind, "label")) return .{ .label = try dupePlain(allocator, value) };
    if (std.mem.eql(u8, kind, "text")) return .{ .text = try dupePlain(allocator, value) };
    if (std.mem.eql(u8, kind, "test-id")) return .{ .test_id = try dupePlain(allocator, value) };
    return ParseError.InvalidFormat;
}

fn appendDecodedForm(
    allocator: std.mem.Allocator,
    commands: *std.ArrayListUnmanaged(SpecCommand),
    form: sexpr.Expr,
    is_setup: bool,
) ParseError!void {
    const items = exprList(form) orelse return ParseError.InvalidFormat;
    if (items.len == 0) return ParseError.InvalidFormat;
    const head = exprSymbol(items[0]) orelse return ParseError.InvalidFormat;
    const args = items[1..];
    const line = form.span.line;

    // Scripted primitives are allowed in both sections: in setup they seed
    // the answer before the application mounts, in steps they stub it.
    var command: SpecCommand = if (http_fixtures.recognizes(head))
        try decodeHttpFixtureForm(allocator, head, args, is_setup, line)
    else if (is_setup)
        try decodeSetupForm(allocator, head, args, line)
    else
        try decodeStepForm(allocator, head, args, line);
    command.column_num = form.span.column;

    commands.append(allocator, command) catch {
        freeOneCommand(allocator, command);
        return ParseError.OutOfMemory;
    };
}

/// A scripted HTTP exchange, stubbed in the steps or seeded in the setup.
fn decodeHttpFixtureForm(allocator: std.mem.Allocator, head: []const u8, args: []const sexpr.Expr, is_setup: bool, line: usize) ParseError!SpecCommand {
    const fixture = try http_fixtures.parse(allocator, head, args);
    const payload: HttpStub = .{ .label = fixture.label, .stub = fixture.stub };
    return .{
        .step = if (is_setup) .{ .seed_http_result = payload } else .{ .stub_http_result = payload },
        .line_num = line,
    };
}

fn exprList(expr: sexpr.Expr) ?[]const sexpr.Expr {
    return switch (expr.value) {
        .list => |items| items,
        else => null,
    };
}

fn exprSymbol(expr: sexpr.Expr) ?[]const u8 {
    return switch (expr.value) {
        .atom => |atom| switch (atom) {
            .symbol => |value| value,
            else => null,
        },
        else => null,
    };
}

fn exprString(expr: sexpr.Expr) ?[]const u8 {
    return switch (expr.value) {
        .atom => |atom| switch (atom) {
            .string => |value| value,
            else => null,
        },
        else => null,
    };
}

fn exprSymbolEql(expr: sexpr.Expr, expected: []const u8) bool {
    const actual = exprSymbol(expr) orelse return false;
    return std.mem.eql(u8, actual, expected);
}

fn freeOneCommand(allocator: std.mem.Allocator, command: SpecCommand) void {
    command.step.deinit(allocator);
}

fn freeCommandList(allocator: std.mem.Allocator, commands: *std.ArrayListUnmanaged(SpecCommand)) void {
    for (commands.items) |command| freeOneCommand(allocator, command);
    commands.deinit(allocator);
}

test "S-expression spec parser decodes setup locators actions and assertions" {
    const content =
        \\(test "save a profile"
        \\  ; setup is applied before roc_ui_init
        \\  (setup
        \\    (initial-location "/profile")
        \\    (initial-online offline)
        \\    (local-storage "draft" "saved"))
        \\  (steps
        \\    (fill (label "Email") "a@example.com")
        \\    (real-click (role button :name "Save"))
        \\    (expect-text (test-id "status") "Saved")
        \\    (expect-metric-delta rows_reused 2)))
    ;
    const spec = try parseSExprTestSpec(std.testing.allocator, content);
    defer spec.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("save a profile", spec.name);
    try std.testing.expectEqual(@as(usize, 7), spec.commands.len);
    try std.testing.expectEqual(SpecCommandType.set_initial_location, spec.commands[0].kind());
    try std.testing.expectEqual(@as(usize, 4), spec.commands[0].line_num);
    try std.testing.expectEqual(@as(usize, 5), spec.commands[0].column_num);
    try std.testing.expectEqual(SpecCommandType.seed_local_storage, spec.commands[2].kind());
    try std.testing.expectEqual(SpecCommandType.fill, spec.commands[3].kind());
    try std.testing.expectEqual(LocatorKind.label, legacyView(spec.commands[3].step).locator.kind);
    try std.testing.expectEqualStrings("a@example.com", legacyView(spec.commands[3].step).expected.?);
    try std.testing.expectEqual(SpecCommandType.real_click, spec.commands[4].kind());
    try std.testing.expectEqual(LocatorKind.role_name, legacyView(spec.commands[4].step).locator.kind);
    try std.testing.expectEqual(SpecCommandType.expect_metric_delta, spec.commands[6].kind());
}

test "S-expression locators name text containing separators and quotes" {
    const content =
        \\(test "windows breadcrumb"
        \\  (steps
        \\    (click (label "Go to C:\\Users"))
        \\    (expect-text (role button :name "say \"hi\"") "ok")))
    ;
    const spec = try parseSExprTestSpec(std.testing.allocator, content);
    defer spec.deinit(std.testing.allocator);

    try std.testing.expectEqual(LocatorKind.label, legacyView(spec.commands[0].step).locator.kind);
    try std.testing.expectEqualStrings("Go to C:\\Users", legacyView(spec.commands[0].step).locator.label.?);
    try std.testing.expectEqual(LocatorKind.role_name, legacyView(spec.commands[1].step).locator.kind);
    try std.testing.expectEqualStrings("say \"hi\"", legacyView(spec.commands[1].step).locator.name.?);
}

test "manual effect controls distinguish setup mode from occurrence execution" {
    const spec = try parseSExprTestSpec(
        std.testing.allocator,
        "(test \"manual\" (setup (manual-effects)) (steps (expect-pending-effects 2) (run-effect 2)))",
    );
    defer spec.deinit(std.testing.allocator);
    try std.testing.expectEqual(SpecCommandType.manual_effects, spec.commands[0].kind());
    try std.testing.expectEqual(SpecCommandType.expect_pending_effects, spec.commands[1].kind());
    try std.testing.expectEqual(@as(u64, 2), spec.commands[1].step.expect_pending_effects);
    try std.testing.expectEqual(SpecCommandType.run_effect, spec.commands[2].kind());
    try std.testing.expectEqual(@as(u64, 2), spec.commands[2].step.run_effect);
    for ([_][]const u8{
        "(test \"bad\" (steps (manual-effects)))",
        "(test \"bad\" (setup (manual-effects 1)) (steps (run-effect 1)))",
        "(test \"bad\" (setup (run-effect 1)) (steps (run-effect 1)))",
        "(test \"bad\" (steps (run-effect -1)))",
        "(test \"bad\" (steps (run-effect 1 2)))",
        "(test \"bad\" (steps (expect-pending-effects)))",
    }) |source| {
        try std.testing.expectError(ParseError.InvalidFormat, parseSExprTestSpec(std.testing.allocator, source));
    }
}

test "spec parser rejects retired task simulation controls" {
    for ([_][]const u8{
        "(resolve-task \"request\" \"result\")",
        "(resolve-stale-task \"request\" \"result\")",
        "(reject-task \"request\" \"offline\")",
        "(expect-pending-task \"request\" 1)",
        "(expect-canceled-task \"request\" 1)",
    }) |step| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "(test \"retired control\" (steps {s}))", .{step});
        defer std.testing.allocator.free(source);
        try std.testing.expectError(ParseError.InvalidFormat, parseSExprTestSpec(std.testing.allocator, source));
    }
}

test "S-expression spec parser rejects executable setup and empty steps" {
    try std.testing.expectError(
        ParseError.InvalidFormat,
        parseSExprTestSpec(std.testing.allocator,
            \\(test "bad" (setup (click (text "No"))) (steps (mark-metrics)))
        ),
    );
    try std.testing.expectError(
        ParseError.InvalidFormat,
        parseSExprTestSpec(std.testing.allocator,
            \\(test "bad" (steps))
        ),
    );
}

/// The checked-in canonical decoding of every spec in the repository.
/// Regenerate deliberately with `SIGNALS_UPDATE_SPEC_GOLDEN=1 zig build test`
/// and review the diff: a line that changed is a spec whose meaning changed.
const spec_golden_path = "test/spec-decode.golden";

test "all checked-in specs decode to the committed golden" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const allocator = std.testing.allocator;
    var paths: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    for ([_][]const u8{"examples-web"}) |directory| {
        const examples = try std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true });
        defer examples.close(io);
        var walker = try examples.walk(allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".scm")) continue;
            try paths.append(allocator, try std.fs.path.join(allocator, &.{ directory, entry.path }));
        }
    }
    // Directory walk order is not a contract; the golden is.
    std.mem.sort([]u8, paths.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    try std.testing.expect(paths.items.len > 100);

    var canonical: std.Io.Writer.Allocating = .init(allocator);
    defer canonical.deinit();
    for (paths.items) |path| {
        var parsed = parseTestSpecFile(allocator, path) catch |err| {
            std.debug.print("failed to parse {s}: {s}\n", .{ path, @errorName(err) });
            return err;
        };
        defer parsed.deinit(allocator);
        try canonical.writer.print("== {s}\n", .{path});
        try writeCanonical(&canonical.writer, parsed);
    }
    const actual = canonical.written();

    if (std.process.Environ.getPosix(std.testing.environ, "SIGNALS_UPDATE_SPEC_GOLDEN") != null) {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = spec_golden_path, .data = actual });
        return;
    }
    const expected = std.Io.Dir.cwd().readFileAlloc(io, spec_golden_path, allocator, .limited(16 * 1024 * 1024)) catch |err| {
        std.debug.print("cannot read {s} ({s}); regenerate with SIGNALS_UPDATE_SPEC_GOLDEN=1 zig build test\n", .{ spec_golden_path, @errorName(err) });
        return err;
    };
    defer allocator.free(expected);
    if (!std.mem.eql(u8, expected, actual)) {
        // Name the first differing line so the reviewer knows which spec moved.
        var expected_lines = std.mem.splitScalar(u8, expected, '\n');
        var actual_lines = std.mem.splitScalar(u8, actual, '\n');
        var line: usize = 1;
        while (true) : (line += 1) {
            const want = expected_lines.next();
            const got = actual_lines.next();
            if (want == null and got == null) break;
            if (want == null or got == null or !std.mem.eql(u8, want.?, got.?)) {
                std.debug.print("{s}:{d}: spec decoding changed\n  golden: {s}\n  now:    {s}\nIf the change is intended, regenerate with SIGNALS_UPDATE_SPEC_GOLDEN=1 zig build test and review the diff.\n", .{ spec_golden_path, line, want orelse "<end>", got orelse "<end>" });
                break;
            }
        }
        return error.SpecDecodingChanged;
    }
}

test "the canonical form spells every field and escapes text" {
    const spec = try parseSExprTestSpec(std.testing.allocator, "(test \"s\" (steps (fill (label \"Note\") \"x\\ny\") (expect-updates (test-id \"row\") 2)))");
    defer spec.deinit(std.testing.allocator);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeCanonical(&out.writer, spec);
    try std.testing.expectEqualStrings(
        "test \"s\"\n" ++
            "  1: fill locator=label label=\"Note\" expected=\"x\\ny\"\n" ++
            "  1: expect_updates locator=test_id test_id=\"row\" count=2\n",
        out.written(),
    );
}

test "spec parser parses actions and assertions" {
    const spec = try parseSExprTestSpec(std.testing.allocator,
        \\(test "actions"
        \\  (setup
        \\    (initial-location "/services/api?tab=logs#tail")
        \\    (initial-visibility hidden)
        \\    (initial-online offline)
        \\    (local-storage "checkout:draft" "saved")
        \\    (session-storage "checkout:flash" "shown"))
        \\  (steps
        \\    (click (role button :name "Save"))
        \\    (real-click (role button :name "Save"))
        \\    (fill (label "Email") "a@example.com")
        \\    (focus (label "Email"))
        \\    (blur (label "Email"))
        \\    (change (label "Email") "changed@example.com")
        \\    (select-option (label "Plan") "growth")
        \\    (composition-start (label "Email"))
        \\    (composition-end (label "Email"))
        \\    (custom-event (test-id "chart") "chart-select" "now | 1,200 rpm")
        \\    (expect-attr (test-id "status") data-state "ready")
        \\    (expect-no-attr (label "Email") aria-invalid)
        \\    (tick-interval 250)
        \\    (tick-interval-if-active 250)
        \\    (expect-interval 250 1)
        \\    (navigate "/services/web?tab=deploys#events")
        \\    (set-visibility visible)
        \\    (set-online online)
        \\    (history-back)
        \\    (history-forward)
        \\    (expect-current-location "/services/web?tab=deploys#events")
        \\    (assert-current-location "/services/web?tab=deploys#events")
        \\    (expect-document-title "Service Ops Center")
        \\    (expect-local-storage "checkout:draft" "saved")
        \\    (expect-session-storage "checkout:flash" "shown")
        \\    (expect-no-local-storage "checkout:missing")
        \\    (expect-no-session-storage "checkout:missing")))
    );
    defer spec.deinit(std.testing.allocator);
    const commands = spec.commands;

    try std.testing.expectEqual(@as(usize, 32), commands.len);
    try std.testing.expectEqual(SpecCommandType.set_initial_location, commands[0].kind());
    try std.testing.expectEqualStrings("/services/api?tab=logs#tail", legacyView(commands[0].step).expected.?);
    try std.testing.expectEqual(SpecCommandType.set_initial_visibility, commands[1].kind());
    try std.testing.expectEqualStrings("hidden", legacyView(commands[1].step).expected.?);
    try std.testing.expectEqual(SpecCommandType.set_initial_online, commands[2].kind());
    try std.testing.expectEqualStrings("offline", legacyView(commands[2].step).expected.?);
    try std.testing.expectEqual(SpecCommandType.seed_local_storage, commands[3].kind());
    try std.testing.expectEqualStrings("checkout:draft", legacyView(commands[3].step).task.?);
    try std.testing.expectEqualStrings("saved", legacyView(commands[3].step).expected.?);
    try std.testing.expectEqual(SpecCommandType.seed_session_storage, commands[4].kind());
    try std.testing.expectEqualStrings("checkout:flash", legacyView(commands[4].step).task.?);
    try std.testing.expectEqualStrings("shown", legacyView(commands[4].step).expected.?);
    try std.testing.expectEqual(SpecCommandType.click, commands[5].kind());
    try std.testing.expectEqual(LocatorKind.role_name, legacyView(commands[5].step).locator.kind);
    try std.testing.expectEqualStrings("button", legacyView(commands[5].step).locator.role.?);
    try std.testing.expectEqualStrings("Save", legacyView(commands[5].step).locator.name.?);
    try std.testing.expectEqual(SpecCommandType.real_click, commands[6].kind());
    try std.testing.expectEqualStrings("a@example.com", legacyView(commands[7].step).expected.?);
    try std.testing.expectEqual(SpecCommandType.focus, commands[8].kind());
    try std.testing.expectEqual(SpecCommandType.blur, commands[9].kind());
    try std.testing.expectEqual(SpecCommandType.change, commands[10].kind());
    try std.testing.expectEqualStrings("changed@example.com", legacyView(commands[10].step).expected.?);
    try std.testing.expectEqual(SpecCommandType.select_option, commands[11].kind());
    try std.testing.expectEqualStrings("growth", legacyView(commands[11].step).expected.?);
    try std.testing.expectEqual(SpecCommandType.composition_start, commands[12].kind());
    try std.testing.expectEqual(SpecCommandType.composition_end, commands[13].kind());
    try std.testing.expectEqual(SpecCommandType.custom_event, commands[14].kind());
    try std.testing.expectEqualStrings("chart", legacyView(commands[14].step).locator.test_id.?);
    try std.testing.expectEqualStrings("chart-select", legacyView(commands[14].step).task.?);
    try std.testing.expectEqualStrings("now | 1,200 rpm", legacyView(commands[14].step).expected.?);
    try std.testing.expectEqualStrings("data-state", legacyView(commands[15].step).attr.?);
    try std.testing.expectEqualStrings("ready", legacyView(commands[15].step).expected.?);
    try std.testing.expectEqualStrings("aria-invalid", legacyView(commands[16].step).attr.?);
    try std.testing.expectEqual(@as(?u64, 250), legacyView(commands[17].step).interval);
    try std.testing.expectEqual(SpecCommandType.tick_interval_if_active, commands[18].kind());
    try std.testing.expectEqual(@as(?u64, 250), legacyView(commands[18].step).interval);
    try std.testing.expectEqual(@as(?u64, 1), legacyView(commands[19].step).count);
    try std.testing.expectEqual(@as(?u64, 250), legacyView(commands[19].step).interval);
    try std.testing.expectEqual(SpecCommandType.navigate, commands[20].kind());
    try std.testing.expectEqualStrings("/services/web?tab=deploys#events", legacyView(commands[20].step).expected.?);
    try std.testing.expectEqualStrings("visible", legacyView(commands[21].step).expected.?);
    try std.testing.expectEqualStrings("online", legacyView(commands[22].step).expected.?);
    try std.testing.expectEqual(SpecCommandType.history_back, commands[23].kind());
    try std.testing.expectEqual(SpecCommandType.history_forward, commands[24].kind());
    try std.testing.expectEqual(SpecCommandType.expect_current_location, commands[25].kind());
    // `assert-current-location` is the older spelling of the same assertion.
    try std.testing.expectEqual(SpecCommandType.expect_current_location, commands[26].kind());
    try std.testing.expectEqualStrings("Service Ops Center", legacyView(commands[27].step).expected.?);
    try std.testing.expectEqualStrings("checkout:draft", legacyView(commands[28].step).task.?);
    try std.testing.expectEqualStrings("saved", legacyView(commands[28].step).expected.?);
    try std.testing.expectEqualStrings("checkout:flash", legacyView(commands[29].step).task.?);
    try std.testing.expectEqual(SpecCommandType.expect_no_local_storage, commands[30].kind());
    try std.testing.expectEqualStrings("checkout:missing", legacyView(commands[30].step).task.?);
    try std.testing.expectEqual(SpecCommandType.expect_no_session_storage, commands[31].kind());
}

test "spec parser parses browser environment value text" {
    const location = try locationSnapshotFromSpecText("/services/api?tab=logs#tail");
    try std.testing.expectEqualStrings("/services/api", location.path);
    try std.testing.expectEqualStrings("tab=logs", location.query);
    try std.testing.expectEqualStrings("tail", location.hash);

    const root = try locationSnapshotFromSpecText("?q=1#top");
    try std.testing.expectEqualStrings("/", root.path);
    try std.testing.expectEqualStrings("q=1", root.query);
    try std.testing.expectEqualStrings("top", root.hash);

    try std.testing.expectEqual(boundary.VisibilitySnapshot.visible, try visibilitySnapshotFromSpecText("visible"));
    try std.testing.expectEqual(boundary.VisibilitySnapshot.hidden, try visibilitySnapshotFromSpecText("hidden"));
    try std.testing.expectEqual(boundary.OnlineSnapshot.online, try onlineSnapshotFromSpecText("online"));
    try std.testing.expectEqual(boundary.OnlineSnapshot.offline, try onlineSnapshotFromSpecText("offline"));
}

test "spec parser parses async cleanup metrics and boolean commands" {
    const spec = try parseSExprTestSpec(std.testing.allocator,
        \\(test "async"
        \\  ; parser fixtures should keep native specs honest
        \\  (steps
        \\    (key-down (role textbox :name "Search") "Enter" true)
        \\    (expect-checked (label "Enabled") false)
        \\    (expect-disabled (test-id "submit") true)
        \\    (expect-cleanup "fetch user" 2)
        \\    (mark-metrics)
        \\    (expect-metric-delta closure_releases -1)
        \\    (expect-metric-delta-at-most host_retained_alloc_delta 0)))
    );
    defer spec.deinit(std.testing.allocator);
    const commands = spec.commands;

    try std.testing.expectEqual(@as(usize, 7), commands.len);
    try std.testing.expectEqual(SpecCommandType.key_down, commands[0].kind());
    try std.testing.expectEqual(@as(usize, 4), commands[0].line_num);
    try std.testing.expectEqualStrings("textbox", legacyView(commands[0].step).locator.role.?);
    try std.testing.expectEqualStrings("Search", legacyView(commands[0].step).locator.name.?);
    try std.testing.expectEqualStrings("Enter", legacyView(commands[0].step).expected.?);
    try std.testing.expectEqual(@as(?bool, true), legacyView(commands[0].step).boolean);
    try std.testing.expectEqual(SpecCommandType.expect_checked, commands[1].kind());
    try std.testing.expectEqualStrings("Enabled", legacyView(commands[1].step).locator.label.?);
    try std.testing.expectEqual(@as(?bool, false), legacyView(commands[1].step).boolean);
    try std.testing.expectEqual(SpecCommandType.expect_disabled, commands[2].kind());
    try std.testing.expectEqualStrings("submit", legacyView(commands[2].step).locator.test_id.?);
    try std.testing.expectEqual(@as(?bool, true), legacyView(commands[2].step).boolean);
    try std.testing.expectEqual(SpecCommandType.expect_cleanup, commands[3].kind());
    try std.testing.expectEqualStrings("fetch user", legacyView(commands[3].step).task.?);
    try std.testing.expectEqual(@as(?u64, 2), legacyView(commands[3].step).count);
    try std.testing.expectEqual(SpecCommandType.mark_metrics, commands[4].kind());
    try std.testing.expectEqual(SpecCommandType.expect_metric_delta, commands[5].kind());
    try std.testing.expectEqualStrings("closure_releases", legacyView(commands[5].step).expected.?);
    try std.testing.expectEqual(@as(?i64, -1), legacyView(commands[5].step).delta);
    try std.testing.expectEqual(SpecCommandType.expect_metric_delta_at_most, commands[6].kind());
    try std.testing.expectEqualStrings("host_retained_alloc_delta", legacyView(commands[6].step).expected.?);
    try std.testing.expectEqual(@as(?i64, 0), legacyView(commands[6].step).delta);
}

test "spec parser parses pointer form and visibility commands" {
    const spec = try parseSExprTestSpec(std.testing.allocator,
        \\(test "pointer" (steps
        \\  (pointer-down (test-id "drag-handle"))
        \\  (pointer-up (test-id "drag-handle"))
        \\  (pointer-enter (text "Drop zone"))
        \\  (pointer-leave (text "Drop zone"))
        \\  (submit (role button :name "Save"))
        \\  (check (label "Enabled"))
        \\  (uncheck (label "Enabled"))
        \\  (expect-text (test-id "status") "Ready")
        \\  (expect-visible (role button :name "Save"))
        \\  (expect-absent (text "Loading"))
        \\  (expect-value (label "Email") "a@example.com")
        \\  (expect-updates (test-id "status") 3)))
    );
    defer spec.deinit(std.testing.allocator);
    const commands = spec.commands;

    try std.testing.expectEqual(@as(usize, 12), commands.len);
    try std.testing.expectEqual(SpecCommandType.pointer_down, commands[0].kind());
    try std.testing.expectEqualStrings("drag-handle", legacyView(commands[0].step).locator.test_id.?);
    try std.testing.expectEqual(SpecCommandType.pointer_up, commands[1].kind());
    try std.testing.expectEqual(SpecCommandType.pointer_enter, commands[2].kind());
    try std.testing.expectEqualStrings("Drop zone", legacyView(commands[2].step).locator.text.?);
    try std.testing.expectEqual(SpecCommandType.pointer_leave, commands[3].kind());
    try std.testing.expectEqual(SpecCommandType.submit, commands[4].kind());
    try std.testing.expectEqualStrings("Save", legacyView(commands[4].step).locator.name.?);
    try std.testing.expectEqual(SpecCommandType.check, commands[5].kind());
    try std.testing.expectEqual(SpecCommandType.uncheck, commands[6].kind());
    try std.testing.expectEqualStrings("Enabled", legacyView(commands[6].step).locator.label.?);
    try std.testing.expectEqual(SpecCommandType.expect_text, commands[7].kind());
    try std.testing.expectEqualStrings("Ready", legacyView(commands[7].step).expected.?);
    try std.testing.expectEqual(SpecCommandType.expect_visible, commands[8].kind());
    try std.testing.expectEqual(SpecCommandType.expect_absent, commands[9].kind());
    try std.testing.expectEqualStrings("Loading", legacyView(commands[9].step).locator.text.?);
    try std.testing.expectEqual(SpecCommandType.expect_value, commands[10].kind());
    try std.testing.expectEqualStrings("a@example.com", legacyView(commands[10].step).expected.?);
    try std.testing.expectEqual(SpecCommandType.expect_updates, commands[11].kind());
    try std.testing.expectEqual(@as(?u64, 3), legacyView(commands[11].step).count);
}

test "spec parser rejects malformed commands" {
    try std.testing.expectError(ParseError.InvalidFormat, locationSnapshotFromSpecText("services/api"));
    try std.testing.expectError(ParseError.InvalidFormat, visibilitySnapshotFromSpecText("maybe"));
    try std.testing.expectError(ParseError.InvalidFormat, onlineSnapshotFromSpecText("maybe"));
    for ([_][]const u8{
        "(click missing_locator)",
        "(click (role button))",
        "(click (test-id status))",
        "(custom-event (test-id \"chart\") \"chart-select\")",
        "(custom-event (test-id \"chart\") chart-select \"detail\")",
        "(resolve-stale-task \"fetch user\")",
        "(expect-canceled-task \"fetch user\" nope)",
        "(expect-canceled-task fetch 1)",
        "(expect-checked (label \"x\") maybe)",
        "(tick-interval -5)",
        "(expect-metric-delta \"rows\" 1)",
        "(history-back now)",
        "(wiggle (test-id \"x\"))",
        "(initial-online offline)",
    }) |step| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "(test \"t\" (steps {s}))", .{step});
        defer std.testing.allocator.free(source);
        try std.testing.expectError(ParseError.InvalidFormat, parseSExprTestSpec(std.testing.allocator, source));
    }
}
