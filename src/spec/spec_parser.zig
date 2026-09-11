//! Parser for text-based Signals example specs and assertions.

const std = @import("std");
const signals = @import("signals");
const boundary = signals.boundary;
const sexpr = @import("sexpr.zig");
const file_fixtures = @import("file_fixtures.zig");

pub const SpecCommandType = enum {
    click,
    real_click,
    pointer_down,
    pointer_up,
    pointer_enter,
    pointer_leave,
    key_down,
    shortcut,
    request_window_close,
    expect_window_closed,
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
    resolve_task,
    resolve_stale_task,
    reject_task,
    tick_interval,
    tick_interval_if_active,
    expect_cleanup,
    expect_pending_task,
    expect_canceled_task,
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
    // Window-only steps. A `(scenario ...)` runs against the real window through
    // the GUI host, where these observe layout, native editor history and the
    // window's own lifecycle; the display-free runner refuses them by name.
    wait,
    type_text,
    key,
    expect_onscreen,
    expect_history,
    expect_count,
    expect_selected,
    expect_focused,
    snapshot,
    close,
};

/// Whether a step exists only for a scenario driven against a real window.
pub fn isWindowOnly(cmd_type: SpecCommandType) bool {
    return switch (cmd_type) {
        .wait, .type_text, .key, .expect_onscreen, .expect_history, .expect_count, .expect_selected, .expect_focused, .snapshot, .close => true,
        else => false,
    };
}

/// The window-only steps the GUI host decodes by tag name. The Rust decoder
/// carries the same list; a test on each side pins the two together, because
/// the tag names cross the ABI as strings and nothing else checks them.
pub const window_step_tags = [_][]const u8{
    "wait",           "click",         "focus",           "type_text",      "key",             "shortcut",
    "expect_visible", "expect_absent", "expect_text",     "expect_value",   "expect_disabled", "expect_selected",
    "expect_focused", "expect_count",  "expect_onscreen", "expect_history", "snapshot",        "close",
};

/// Writes a parsed spec in one deterministic line per command, every field
/// spelled out. This is what a spec *means* to the runner, independent of how
/// it was spelled, and the checked-in golden of every spec's canonical form is
/// the proof that a parser change changed nothing: the same spec must produce
/// the same command sequence.
pub fn writeCanonical(writer: *std.Io.Writer, spec: ParsedTestSpec) std.Io.Writer.Error!void {
    try writer.print("{s} ", .{if (spec.scenario != null) "scenario" else "test"});
    try writeQuoted(writer, spec.name);
    if (spec.scenario) |header| {
        try writer.print(" window={d}x{d}", .{ header.window_width, header.window_height });
        try writer.writeAll(" assets=");
        try writeOptionalQuoted(writer, header.assets);
        try writer.writeAll(" choose=[");
        for (header.choices, 0..) |choice, index| {
            if (index > 0) try writer.writeByte(' ');
            try writeQuoted(writer, choice);
        }
        try writer.writeAll("] diagnostic=");
        try writeOptionalQuoted(writer, header.diagnostic);
        try writer.writeAll(" on=[");
        for (header.on, 0..) |token, index| {
            if (index > 0) try writer.writeByte(' ');
            try writer.writeAll(token);
        }
        try writer.writeByte(']');
    }
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
        if (view.kinds != 0) try writer.print(" kinds={x}", .{view.kinds});
        try writeField(writer, "attr", view.attr);
        if (view.interval) |value| try writer.print(" interval={d}", .{value});
        if (view.shortcut) |chord| try writer.print(" shortcut={d}+{d}", .{ chord.key, chord.modifiers });
        try writeField(writer, "expected", view.expected);
        if (view.count) |value| try writer.print(" count={d}", .{value});
        if (view.delta) |value| try writer.print(" delta={d}", .{value});
        if (view.boolean) |value| try writer.print(" bool={}", .{value});
        try writer.writeByte('\n');
    }
}

/// The flat view of a step the canonical form and the scenario ABI both
/// spell: one slot per kind of value, so a step's payload is legible without
/// knowing its type. The typed union is the model; this is its projection.
pub const LegacyView = struct {
    locator: Locator = .{ .kind = .none },
    task: ?[]const u8 = null,
    kinds: u64 = 0,
    attr: ?[]const u8 = null,
    interval: ?u64 = null,
    shortcut: ?signals.key_chord.Chord = null,
    expected: ?[]const u8 = null,
    count: ?u64 = null,
    delta: ?i64 = null,
    boolean: ?bool = null,
};

/// Projects a typed step onto the flat view. Every string here borrows the step.
pub fn legacyView(step: Step) LegacyView {
    return switch (step) {
        .click, .real_click, .pointer_down, .pointer_up, .pointer_enter, .pointer_leave, .focus, .blur, .composition_start, .composition_end, .submit, .check, .uncheck, .expect_visible, .expect_absent, .expect_onscreen, .expect_focused => |target| .{ .locator = target },
        .change, .select_option, .fill, .expect_text, .expect_value, .type_text => |args| .{ .locator = args.target, .expected = args.text },
        .expect_checked, .expect_disabled, .expect_selected => |args| .{ .locator = args.target, .boolean = args.expected },
        .expect_updates, .expect_history => |args| .{ .locator = args.target, .count = args.count },
        .key_down => |args| .{ .locator = args.target, .expected = args.key, .boolean = args.shift },
        .shortcut => |args| .{ .locator = args.target, .shortcut = args.chord },
        .custom_event => |args| .{ .locator = args.target, .task = args.name, .expected = args.detail },
        .expect_attr => |args| .{ .locator = args.target, .attr = args.name, .expected = args.value },
        .expect_no_attr => |args| .{ .locator = args.target, .attr = args.name },
        .resolve_task, .resolve_stale_task, .reject_task => |args| .{ .task = args.name, .kinds = args.kinds, .expected = args.payload },
        .tick_interval, .tick_interval_if_active, .wait => |period| .{ .interval = period },
        .expect_cleanup, .expect_pending_task, .expect_canceled_task => |args| .{ .task = args.name, .count = args.count },
        .expect_interval => |args| .{ .interval = args.period_ms, .count = args.count },
        .set_initial_location, .set_initial_visibility, .set_initial_online, .navigate, .set_visibility, .set_online, .expect_current_location, .expect_document_title, .key, .snapshot => |text| .{ .expected = text },
        .expect_no_local_storage, .expect_no_session_storage => |key| .{ .task = key },
        .seed_local_storage, .seed_session_storage, .expect_local_storage, .expect_session_storage => |pair| .{ .task = pair.key, .expected = pair.value },
        .expect_metric_delta, .expect_metric_delta_at_most => |args| .{ .expected = args.metric, .delta = args.delta },
        .expect_count => |args| .{ .expected = args.prefix, .count = args.count },
        .expect_window_closed => |flag| .{ .boolean = flag },
        .request_window_close, .history_back, .history_forward, .mark_metrics, .close => .{},
    };
}

fn writeField(writer: *std.Io.Writer, name: []const u8, value: ?[]const u8) std.Io.Writer.Error!void {
    if (value) |text| {
        try writer.print(" {s}=", .{name});
        try writeQuoted(writer, text);
    }
}

fn writeOptionalQuoted(writer: *std.Io.Writer, value: ?[]const u8) std.Io.Writer.Error!void {
    if (value) |text| try writeQuoted(writer, text) else try writer.writeAll("none");
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

/// The header of a `(scenario ...)`: what the window run needs before its
/// first step. Everything here used to be script front matter read by the
/// Python driver; the host owns it now so that one parser decides.
pub const Scenario = struct {
    /// Requested window size in logical pixels; zero means the host default.
    window_width: u32 = 0,
    window_height: u32 = 0,
    /// Assets root, relative to the example directory, or null for `assets/`.
    assets: ?[]const u8 = null,
    /// Paths handed to the file and folder choosers in order, relative to the
    /// example directory, instead of opening native dialogs.
    choices: [][]const u8 = &.{},
    /// A defect this scenario documents; its failure is reported, not fatal.
    diagnostic: ?[]const u8 = null,
    /// Where the diagnostic applies: systems (`linux`, `macos`, `windows`) or
    /// the frame the run saw (`client-frame`, `server-frame`). Empty means everywhere.
    on: [][]const u8 = &.{},

    /// Releases every string this header owns.
    pub fn deinit(self: Scenario, allocator: std.mem.Allocator) void {
        if (self.assets) |value| allocator.free(value);
        for (self.choices) |choice| allocator.free(choice);
        if (self.choices.len > 0) allocator.free(self.choices);
        if (self.diagnostic) |value| allocator.free(value);
        for (self.on) |token| allocator.free(token);
        if (self.on.len > 0) allocator.free(self.on);
    }
};

pub const LocatorKind = enum {
    none,
    role_name,
    label,
    text,
    test_id,
};

pub const Locator = struct {
    kind: LocatorKind,
    role: ?[]const u8 = null,
    name: ?[]const u8 = null,
    label: ?[]const u8 = null,
    text: ?[]const u8 = null,
    test_id: ?[]const u8 = null,

    fn deinit(self: Locator, allocator: std.mem.Allocator) void {
        if (self.role) |value| allocator.free(value);
        if (self.name) |value| allocator.free(value);
        if (self.label) |value| allocator.free(value);
        if (self.text) |value| allocator.free(value);
        if (self.test_id) |value| allocator.free(value);
    }
};

fn emptyLocator() Locator {
    return .{ .kind = .none };
}

pub const LocatorText = struct { target: Locator, text: []const u8 };
pub const LocatorBool = struct { target: Locator, expected: bool };
pub const LocatorCount = struct { target: Locator, count: u64 };
pub const KeyDown = struct { target: Locator, key: []const u8, shift: bool };
pub const Shortcut = struct { target: Locator, chord: signals.key_chord.Chord };
pub const CustomEvent = struct { target: Locator, name: []const u8, detail: []const u8 };
pub const Attr = struct { target: Locator, name: []const u8, value: []const u8 };
pub const AttrName = struct { target: Locator, name: []const u8 };
/// A settled task: the name the application gave it, the encoded result frames,
/// and the task kinds a typed fixture admits (zero for a raw `resolve-task`).
pub const TaskSettlement = struct { name: []const u8, payload: []const u8, kinds: u64 = 0 };
pub const NamedCount = struct { name: []const u8, count: u64 };
pub const IntervalCount = struct { period_ms: u64, count: u64 };
pub const KeyValue = struct { key: []const u8, value: []const u8 };
pub const MetricDelta = struct { metric: []const u8, delta: i64 };
pub const PrefixCount = struct { prefix: []const u8, count: u64 };

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
    shortcut: Shortcut,
    request_window_close: void,
    expect_window_closed: bool,
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
    resolve_task: TaskSettlement,
    resolve_stale_task: TaskSettlement,
    reject_task: TaskSettlement,
    tick_interval: u64,
    tick_interval_if_active: u64,
    expect_cleanup: NamedCount,
    expect_pending_task: NamedCount,
    expect_canceled_task: NamedCount,
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
    wait: u64,
    type_text: LocatorText,
    key: []const u8,
    expect_onscreen: Locator,
    expect_history: LocatorCount,
    expect_count: PrefixCount,
    expect_selected: LocatorBool,
    expect_focused: Locator,
    snapshot: []const u8,
    close: void,

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
    if (T == void or T == bool or T == u64 or T == i64 or T == signals.key_chord.Chord) return;
    if (T == []const u8) return allocator.free(payload);
    if (T == Locator) return payload.deinit(allocator);
    inline for (std.meta.fields(T)) |field| freePayload(allocator, @field(payload, field.name));
}

pub const SpecCommand = struct {
    step: Step,
    line_num: usize,

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
    /// Present for a `(scenario ...)`, absent for a `(test ...)`.
    scenario: ?Scenario = null,

    /// Releases every resource owned by this value and leaves no retained host or Roc ownership behind.
    pub fn deinit(self: ParsedTestSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        freeSpecCommands(allocator, self.commands);
        if (self.scenario) |scenario| scenario.deinit(allocator);
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
    const is_scenario = exprSymbolEql(root_items[0], "scenario");
    if (!is_scenario and !exprSymbolEql(root_items[0], "test")) return ParseError.InvalidFormat;
    const name = exprString(root_items[1]) orelse return ParseError.InvalidFormat;
    const name_copy = allocator.dupe(u8, name) catch return ParseError.OutOfMemory;
    errdefer allocator.free(name_copy);

    var scenario: ?Scenario = null;
    errdefer if (scenario) |header| header.deinit(allocator);
    var sections_from: usize = 2;
    if (is_scenario) {
        const header = try parseScenarioHeader(allocator, root_items[2..]);
        scenario = header.scenario;
        sections_from += header.consumed;
    }

    var commands: std.ArrayListUnmanaged(SpecCommand) = .empty;
    errdefer freeCommandList(allocator, &commands);
    var saw_setup = false;
    var saw_steps = false;

    for (root_items[sections_from..]) |section| {
        const section_items = exprList(section) orelse return ParseError.InvalidFormat;
        if (section_items.len == 0) return ParseError.InvalidFormat;
        if (exprSymbolEql(section_items[0], "setup")) {
            if (is_scenario or saw_setup or saw_steps) return ParseError.InvalidFormat;
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
    if (is_scenario) {
        // A scenario runs the real file workers, so a fixture that resolves a
        // task by name has nothing to resolve; and closing the window ends the
        // run, so nothing may follow it.
        for (commands.items, 0..) |cmd, index| {
            switch (cmd.step) {
                .resolve_task, .resolve_stale_task, .reject_task => return ParseError.InvalidFormat,
                .close => if (index + 1 != commands.items.len) return ParseError.InvalidFormat,
                else => {},
            }
        }
    } else {
        for (commands.items) |cmd| if (isWindowOnly(cmd.kind())) return ParseError.InvalidFormat;
    }

    return .{
        .name = name_copy,
        .commands = commands.toOwnedSlice(allocator) catch return ParseError.OutOfMemory,
        .scenario = scenario,
    };
}

/// Reads the `:keyword value` pairs between a scenario's name and its `(steps ...)`.
fn parseScenarioHeader(allocator: std.mem.Allocator, items: []const sexpr.Expr) ParseError!struct { scenario: Scenario, consumed: usize } {
    var scenario: Scenario = .{};
    errdefer scenario.deinit(allocator);
    var index: usize = 0;
    while (index < items.len) {
        const key = exprSymbol(items[index]) orelse break;
        if (key.len == 0 or key[0] != ':') break;
        if (index + 1 >= items.len) return ParseError.InvalidFormat;
        const value = items[index + 1];
        if (std.mem.eql(u8, key, ":window")) {
            if (scenario.window_width != 0) return ParseError.InvalidFormat;
            const text = exprString(value) orelse return ParseError.InvalidFormat;
            const separator = std.mem.indexOfAny(u8, text, "xX") orelse return ParseError.InvalidFormat;
            scenario.window_width = std.fmt.parseInt(u32, text[0..separator], 10) catch return ParseError.InvalidFormat;
            scenario.window_height = std.fmt.parseInt(u32, text[separator + 1 ..], 10) catch return ParseError.InvalidFormat;
            if (scenario.window_width == 0 or scenario.window_height == 0) return ParseError.InvalidFormat;
        } else if (std.mem.eql(u8, key, ":assets")) {
            if (scenario.assets != null) return ParseError.InvalidFormat;
            const text = exprString(value) orelse return ParseError.InvalidFormat;
            if (text.len == 0) return ParseError.InvalidFormat;
            scenario.assets = try dupePlain(allocator, text);
        } else if (std.mem.eql(u8, key, ":choose")) {
            if (scenario.choices.len != 0) return ParseError.InvalidFormat;
            scenario.choices = try dupeStringList(allocator, value, false);
        } else if (std.mem.eql(u8, key, ":diagnostic")) {
            if (scenario.diagnostic != null) return ParseError.InvalidFormat;
            const text = exprString(value) orelse return ParseError.InvalidFormat;
            if (text.len == 0) return ParseError.InvalidFormat;
            scenario.diagnostic = try dupePlain(allocator, text);
        } else if (std.mem.eql(u8, key, ":on")) {
            if (scenario.on.len != 0) return ParseError.InvalidFormat;
            scenario.on = try dupeStringList(allocator, value, true);
            for (scenario.on) |token| {
                const known = [_][]const u8{ "linux", "macos", "windows", "client-frame", "server-frame" };
                var recognized = false;
                for (known) |candidate| recognized = recognized or std.mem.eql(u8, token, candidate);
                if (!recognized) return ParseError.InvalidFormat;
            }
        } else {
            return ParseError.InvalidFormat;
        }
        index += 2;
    }
    // A scope without a diagnostic scopes nothing.
    if (scenario.on.len != 0 and scenario.diagnostic == null) return ParseError.InvalidFormat;
    return .{ .scenario = scenario, .consumed = index };
}

/// Copies a non-empty list of strings (or, for `symbols`, of bare symbols).
fn dupeStringList(allocator: std.mem.Allocator, value: sexpr.Expr, symbols: bool) ParseError![][]const u8 {
    const items = exprList(value) orelse return ParseError.InvalidFormat;
    if (items.len == 0) return ParseError.InvalidFormat;
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit(allocator);
    }
    for (items) |item| {
        const text = (if (symbols) exprSymbol(item) else exprString(item)) orelse return ParseError.InvalidFormat;
        if (text.len == 0) return ParseError.InvalidFormat;
        out.append(allocator, try dupePlain(allocator, text)) catch return ParseError.OutOfMemory;
    }
    return out.toOwnedSlice(allocator) catch return ParseError.OutOfMemory;
}

/// Decodes a window-only step directly from its form, or returns null when
/// the head is not one.
fn decodeWindowForm(allocator: std.mem.Allocator, head: []const u8, args: []const sexpr.Expr, line: usize) ParseError!?SpecCommand {
    const step: Step = if (std.mem.eql(u8, head, "wait")) blk: {
        if (args.len != 1) return ParseError.InvalidFormat;
        break :blk .{ .wait = try exprUnsigned(args[0]) };
    } else if (std.mem.eql(u8, head, "type")) blk: {
        break :blk .{ .type_text = try locatorText(allocator, args) };
    } else if (std.mem.eql(u8, head, "key")) blk: {
        break :blk .{ .key = try oneText(allocator, args) };
    } else if (std.mem.eql(u8, head, "expect-onscreen")) blk: {
        break :blk .{ .expect_onscreen = try oneLocator(allocator, args) };
    } else if (std.mem.eql(u8, head, "expect-focused")) blk: {
        break :blk .{ .expect_focused = try oneLocator(allocator, args) };
    } else if (std.mem.eql(u8, head, "expect-selected")) blk: {
        break :blk .{ .expect_selected = try locatorBool(allocator, args) };
    } else if (std.mem.eql(u8, head, "expect-history")) blk: {
        break :blk .{ .expect_history = try locatorCount(allocator, args) };
    } else if (std.mem.eql(u8, head, "expect-count")) blk: {
        if (args.len != 2) return ParseError.InvalidFormat;
        const prefix = try dupePlain(allocator, try nonEmptyString(args[0]));
        errdefer allocator.free(prefix);
        break :blk .{ .expect_count = .{ .prefix = prefix, .count = try exprUnsigned(args[1]) } };
    } else if (std.mem.eql(u8, head, "snapshot")) blk: {
        break :blk .{ .snapshot = try oneText(allocator, args) };
    } else if (std.mem.eql(u8, head, "close")) blk: {
        if (args.len != 0) return ParseError.InvalidFormat;
        break :blk .close;
    } else return null;
    return .{ .step = step, .line_num = line };
}

fn decodeFixtureForm(allocator: std.mem.Allocator, head: []const u8, args: []const sexpr.Expr, line: usize) ParseError!SpecCommand {
    const fixture = try file_fixtures.parse(allocator, head, args);
    const settlement: TaskSettlement = .{ .name = fixture.task_name, .payload = fixture.payload, .kinds = fixture.kinds };
    return .{
        .step = if (fixture.failed) .{ .reject_task = settlement } else .{ .resolve_task = settlement },
        .line_num = line,
    };
}

/// The pre-mount state a `(setup ...)` may declare. Setup is declarative:
/// nothing here dispatches an event or touches the tree.
fn decodeSetupForm(allocator: std.mem.Allocator, head: []const u8, args: []const sexpr.Expr, line: usize) ParseError!SpecCommand {
    const step: Step = if (std.mem.eql(u8, head, "initial-location"))
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
        .{ .head = "request-window-close", .tag = .request_window_close, .shape = .none },
        .{ .head = "mark-metrics", .tag = .mark_metrics, .shape = .none },
        .{ .head = "resolve-task", .tag = .resolve_task, .shape = .key_value },
        .{ .head = "resolve-stale-task", .tag = .resolve_stale_task, .shape = .key_value },
        .{ .head = "reject-task", .tag = .reject_task, .shape = .key_value },
        .{ .head = "expect-local-storage", .tag = .expect_local_storage, .shape = .key_value },
        .{ .head = "expect-session-storage", .tag = .expect_session_storage, .shape = .key_value },
        .{ .head = "expect-no-local-storage", .tag = .expect_no_local_storage, .shape = .key },
        .{ .head = "expect-no-session-storage", .tag = .expect_no_session_storage, .shape = .key },
        .{ .head = "expect-cleanup", .tag = .expect_cleanup, .shape = .named_count },
        .{ .head = "expect-pending-task", .tag = .expect_pending_task, .shape = .named_count },
        .{ .head = "expect-canceled-task", .tag = .expect_canceled_task, .shape = .named_count },
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
                .key_value => if (form.tag == .resolve_task or form.tag == .resolve_stale_task or form.tag == .reject_task)
                    @unionInit(Step, name, try rawSettlement(allocator, args))
                else
                    @unionInit(Step, name, try keyValue(allocator, args)),
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
    } else if (std.mem.eql(u8, head, "shortcut")) blk: {
        if (args.len != 3) return ParseError.InvalidFormat;
        const key = exprString(args[1]) orelse return ParseError.InvalidFormat;
        const modifiers = try exprUnsigned(args[2]);
        if (modifiers > std.math.maxInt(u32)) return ParseError.InvalidFormat;
        const chord = signals.key_chord.parse(key, @intCast(modifiers)) catch return ParseError.InvalidFormat;
        break :blk .{ .shortcut = .{ .target = try locatorFromExpr(allocator, args[0]), .chord = chord } };
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
    } else if (std.mem.eql(u8, head, "expect-window-closed")) blk: {
        if (args.len != 1) return ParseError.InvalidFormat;
        break :blk .{ .expect_window_closed = try exprBool(args[0]) };
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

/// A raw `(resolve-task "name" "payload")`: the payload is already wire bytes
/// and no task kind is admitted, so the runner checks nothing about its shape.
fn rawSettlement(allocator: std.mem.Allocator, args: []const sexpr.Expr) ParseError!TaskSettlement {
    const pair = try keyValue(allocator, args);
    return .{ .name = pair.key, .payload = pair.value, .kinds = 0 };
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
        return .{ .kind = .role_name, .role = role_copy, .name = try dupePlain(allocator, name) };
    }
    if (items.len != 2) return ParseError.InvalidFormat;
    const value = exprString(items[1]) orelse return ParseError.InvalidFormat;
    if (std.mem.eql(u8, kind, "label")) return .{ .kind = .label, .label = try dupePlain(allocator, value) };
    if (std.mem.eql(u8, kind, "text")) return .{ .kind = .text, .text = try dupePlain(allocator, value) };
    if (std.mem.eql(u8, kind, "test-id")) return .{ .kind = .test_id, .test_id = try dupePlain(allocator, value) };
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

    const command: SpecCommand = if (is_setup)
        try decodeSetupForm(allocator, head, args, line)
    else if (try decodeWindowForm(allocator, head, args, line)) |window|
        window
    else if (file_fixtures.recognizes(head))
        try decodeFixtureForm(allocator, head, args, line)
    else
        try decodeStepForm(allocator, head, args, line);

    commands.append(allocator, command) catch {
        freeOneCommand(allocator, command);
        return ParseError.OutOfMemory;
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

test "a scenario carries its header and window-only steps" {
    const content =
        \\(scenario "follow and close"
        \\  :window "800x600"
        \\  :assets "assets"
        \\  :choose ("specs/fixtures/events.log")
        \\  :diagnostic "GUI-35. The frame takes 48 pixels."
        \\  :on (client-frame linux)
        \\  (steps
        \\    (click (role button :name "Open log…"))
        \\    (wait 800)
        \\    (expect-count "event-" 3)
        \\    (type (label "Note text") "hello")
        \\    (key "ctrl-s")
        \\    (expect-onscreen (test-id "count"))
        \\    (expect-history (label "Task notes") 0)
        \\    (expect-selected (test-id "task-4") true)
        \\    (expect-focused (test-id "Increment"))
        \\    (snapshot "following")
        \\    (close)))
    ;
    const spec = try parseSExprTestSpec(std.testing.allocator, content);
    defer spec.deinit(std.testing.allocator);
    const scenario = spec.scenario.?;
    try std.testing.expectEqual(@as(u32, 800), scenario.window_width);
    try std.testing.expectEqual(@as(u32, 600), scenario.window_height);
    try std.testing.expectEqualStrings("assets", scenario.assets.?);
    try std.testing.expectEqual(@as(usize, 1), scenario.choices.len);
    try std.testing.expectEqualStrings("specs/fixtures/events.log", scenario.choices[0]);
    try std.testing.expectEqualStrings("GUI-35. The frame takes 48 pixels.", scenario.diagnostic.?);
    try std.testing.expectEqual(@as(usize, 2), scenario.on.len);
    try std.testing.expectEqualStrings("client-frame", scenario.on[0]);
    try std.testing.expectEqual(@as(usize, 11), spec.commands.len);
    try std.testing.expectEqual(SpecCommandType.click, spec.commands[0].kind());
    try std.testing.expectEqual(SpecCommandType.wait, spec.commands[1].kind());
    try std.testing.expectEqual(@as(u64, 800), legacyView(spec.commands[1].step).interval.?);
    try std.testing.expectEqual(SpecCommandType.expect_count, spec.commands[2].kind());
    try std.testing.expectEqualStrings("event-", legacyView(spec.commands[2].step).expected.?);
    try std.testing.expectEqual(@as(u64, 3), legacyView(spec.commands[2].step).count.?);
    try std.testing.expectEqual(SpecCommandType.type_text, spec.commands[3].kind());
    try std.testing.expectEqual(LocatorKind.label, legacyView(spec.commands[3].step).locator.kind);
    try std.testing.expectEqualStrings("hello", legacyView(spec.commands[3].step).expected.?);
    try std.testing.expectEqual(SpecCommandType.key, spec.commands[4].kind());
    try std.testing.expectEqual(SpecCommandType.expect_onscreen, spec.commands[5].kind());
    try std.testing.expectEqualStrings("count", legacyView(spec.commands[5].step).locator.test_id.?);
    try std.testing.expectEqual(@as(u64, 0), legacyView(spec.commands[6].step).count.?);
    try std.testing.expectEqual(true, legacyView(spec.commands[7].step).boolean.?);
    try std.testing.expectEqual(SpecCommandType.expect_focused, spec.commands[8].kind());
    try std.testing.expectEqualStrings("following", legacyView(spec.commands[9].step).expected.?);
    try std.testing.expectEqual(SpecCommandType.close, spec.commands[10].kind());
    try std.testing.expectEqual(@as(usize, 18), spec.commands[10].line_num);
}

test "a scenario and a test each refuse the other's steps" {
    // A test cannot wait on a real clock or read layout bounds.
    try std.testing.expectError(ParseError.InvalidFormat, parseSExprTestSpec(std.testing.allocator, "(test \"t\" (steps (wait 5)))"));
    try std.testing.expectError(ParseError.InvalidFormat, parseSExprTestSpec(std.testing.allocator, "(test \"t\" (steps (close)))"));
    // A scenario runs the real workers, so a fixture has nothing to resolve.
    try std.testing.expectError(ParseError.InvalidFormat, parseSExprTestSpec(std.testing.allocator, "(scenario \"s\" (steps (resolve-file-choice \"open\" (canceled))))"));
    // Nothing can follow the close that ends the run.
    try std.testing.expectError(ParseError.InvalidFormat, parseSExprTestSpec(std.testing.allocator, "(scenario \"s\" (steps (close) (wait 1)))"));
    // Setup is pre-mount state for the display-free host only.
    try std.testing.expectError(ParseError.InvalidFormat, parseSExprTestSpec(std.testing.allocator, "(scenario \"s\" (setup (initial-online offline)) (steps (wait 1)))"));
    // Header values are checked, and a scope needs something to scope.
    try std.testing.expectError(ParseError.InvalidFormat, parseSExprTestSpec(std.testing.allocator, "(scenario \"s\" :window \"wide\" (steps (wait 1)))"));
    try std.testing.expectError(ParseError.InvalidFormat, parseSExprTestSpec(std.testing.allocator, "(scenario \"s\" :on (linux) (steps (wait 1)))"));
    try std.testing.expectError(ParseError.InvalidFormat, parseSExprTestSpec(std.testing.allocator, "(scenario \"s\" :diagnostic \"x\" :on (beos) (steps (wait 1)))"));
    try std.testing.expectError(ParseError.InvalidFormat, parseSExprTestSpec(std.testing.allocator, "(scenario \"s\" :size \"1x1\" (steps (wait 1)))"));
    // A plain scenario with no header is fine, and the shared steps still parse.
    const plain = try parseSExprTestSpec(std.testing.allocator, "(scenario \"s\" (steps (expect-visible (text \"0\")) (expect-disabled (role button :name \"Save\") true)))");
    defer plain.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), plain.scenario.?.window_width);
    try std.testing.expectEqual(SpecCommandType.expect_disabled, plain.commands[1].kind());
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
    for ([_][]const u8{ "examples-web", "examples-gui", "test/gui" }) |directory| {
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

/// The window steps and their argument names and types, reflected from the
/// `Step` union the way the scenario ABI publishes them. The Rust decoder's
/// tests read this file, so a renamed tag or payload field is caught on both
/// sides. Regenerated with the decode golden.
const spec_steps_path = "test/spec-steps.json";

fn writeStepManifest(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    inline for (std.meta.fields(Step)) |field| {
        const tag = @field(SpecCommandType, field.name);
        if (isWindowOnly(tag) or tag == .click or tag == .focus or tag == .shortcut or tag == .expect_visible or tag == .expect_absent or tag == .expect_text or tag == .expect_value or tag == .expect_disabled) {
            try writer.writeAll(field.name);
            try writeArgManifest(writer, field.type, "value");
            try writer.writeByte('\n');
        }
    }
}

fn writeArgManifest(writer: *std.Io.Writer, comptime T: type, comptime name: []const u8) std.Io.Writer.Error!void {
    if (T == void or T == Locator) return;
    if (T == []const u8) return writer.print(" {s}:text", .{name});
    if (T == u64) return writer.print(" {s}:unsigned", .{name});
    if (T == i64) return writer.print(" {s}:signed", .{name});
    if (T == bool) return writer.print(" {s}:boolean", .{name});
    if (T == signals.key_chord.Chord) return writer.writeAll(" key:unsigned modifiers:unsigned");
    inline for (std.meta.fields(T)) |field| try writeArgManifest(writer, field.type, field.name);
}

test "the published window steps match the committed manifest" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeStepManifest(&out.writer);
    if (std.process.Environ.getPosix(std.testing.environ, "SIGNALS_UPDATE_SPEC_GOLDEN") != null) {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = spec_steps_path, .data = out.written() });
        return;
    }
    const expected = try std.Io.Dir.cwd().readFileAlloc(io, spec_steps_path, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "the window step vocabulary the GUI host decodes is exactly the tags it needs" {
    // Every window-only step must be in the list the Rust host decodes, and
    // every listed tag must exist, so a renamed tag fails here and in the Rust
    // twin of this test rather than at run time as "no meaning against a window".
    inline for (std.meta.tags(SpecCommandType)) |tag| {
        var listed = false;
        for (window_step_tags) |name| listed = listed or std.mem.eql(u8, name, @tagName(tag));
        if (isWindowOnly(tag)) try std.testing.expect(listed);
    }
    for (window_step_tags) |name| {
        try std.testing.expect(std.meta.stringToEnum(SpecCommandType, name) != null);
    }
}

test "the canonical form spells every field and escapes text" {
    const spec = try parseSExprTestSpec(std.testing.allocator, "(scenario \"s\" :window \"800x600\" :choose (\"a b\") (steps (type (label \"Note\") \"x\\ny\") (expect-count \"row-\" 2)))");
    defer spec.deinit(std.testing.allocator);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeCanonical(&out.writer, spec);
    try std.testing.expectEqualStrings(
        "scenario \"s\" window=800x600 assets=none choose=[\"a b\"] diagnostic=none on=[]\n" ++
            "  1: type_text locator=label label=\"Note\" expected=\"x\\ny\"\n" ++
            "  1: expect_count locator=none expected=\"row-\" count=2\n",
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
        \\    (resolve-task "fetch user" "hello\n\"world\"\\")
        \\    (resolve-stale-task "fetch user" "late")
        \\    (reject-task "fetch user" "bad\trequest")
        \\    (expect-cleanup "fetch user" 2)
        \\    (expect-pending-task "fetch user" 1)
        \\    (expect-canceled-task "fetch user" 1)
        \\    (mark-metrics)
        \\    (expect-metric-delta closure_releases -1)
        \\    (expect-metric-delta-at-most host_retained_alloc_delta 0)))
    );
    defer spec.deinit(std.testing.allocator);
    const commands = spec.commands;

    try std.testing.expectEqual(@as(usize, 12), commands.len);
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
    try std.testing.expectEqual(SpecCommandType.resolve_task, commands[3].kind());
    try std.testing.expectEqualStrings("fetch user", legacyView(commands[3].step).task.?);
    try std.testing.expectEqualStrings("hello\n\"world\"\\", legacyView(commands[3].step).expected.?);
    try std.testing.expectEqual(SpecCommandType.resolve_stale_task, commands[4].kind());
    try std.testing.expectEqualStrings("late", legacyView(commands[4].step).expected.?);
    try std.testing.expectEqual(SpecCommandType.reject_task, commands[5].kind());
    try std.testing.expectEqualStrings("bad\trequest", legacyView(commands[5].step).expected.?);
    try std.testing.expectEqual(SpecCommandType.expect_cleanup, commands[6].kind());
    try std.testing.expectEqualStrings("fetch user", legacyView(commands[6].step).task.?);
    try std.testing.expectEqual(@as(?u64, 2), legacyView(commands[6].step).count);
    try std.testing.expectEqual(SpecCommandType.expect_pending_task, commands[7].kind());
    try std.testing.expectEqual(@as(?u64, 1), legacyView(commands[7].step).count);
    try std.testing.expectEqual(SpecCommandType.expect_canceled_task, commands[8].kind());
    try std.testing.expectEqual(SpecCommandType.mark_metrics, commands[9].kind());
    try std.testing.expectEqual(SpecCommandType.expect_metric_delta, commands[10].kind());
    try std.testing.expectEqualStrings("closure_releases", legacyView(commands[10].step).expected.?);
    try std.testing.expectEqual(@as(?i64, -1), legacyView(commands[10].step).delta);
    try std.testing.expectEqual(SpecCommandType.expect_metric_delta_at_most, commands[11].kind());
    try std.testing.expectEqualStrings("host_retained_alloc_delta", legacyView(commands[11].step).expected.?);
    try std.testing.expectEqual(@as(?i64, 0), legacyView(commands[11].step).delta);
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

test "spec parser validates exact native shortcut keys and modifiers" {
    const spec = try parseSExprTestSpec(std.testing.allocator,
        \\(test "shortcuts" (steps
        \\  (shortcut (test-id "editor") "s" 1)
        \\  (shortcut (test-id "editor") "s" 3)
        \\  (shortcut (test-id "editor") "Escape" 0)))
    );
    defer spec.deinit(std.testing.allocator);
    const commands = spec.commands;
    try std.testing.expectEqual(@as(usize, 3), commands.len);
    try std.testing.expectEqual(SpecCommandType.shortcut, commands[0].kind());
    try std.testing.expectEqualStrings("editor", legacyView(commands[0].step).locator.test_id.?);
    try std.testing.expect(legacyView(commands[0].step).shortcut.?.eql(try signals.key_chord.parse("s", 1)));
    try std.testing.expect(legacyView(commands[1].step).shortcut.?.eql(try signals.key_chord.parse("s", 3)));
    try std.testing.expect(legacyView(commands[2].step).shortcut.?.eql(try signals.key_chord.parse("Escape", 0)));
    for ([_][]const u8{
        "(shortcut (test-id \"editor\") \"S\" 1)",
        "(shortcut (test-id \"editor\") \"ctrl-s\" 1)",
        "(shortcut (test-id \"editor\") \"s\" 16)",
        "(shortcut (test-id \"editor\") \"s\" -1)",
        "(shortcut (test-id \"editor\") \"s\" true)",
    }) |step| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "(test \"t\" (steps {s}))", .{step});
        defer std.testing.allocator.free(source);
        try std.testing.expectError(ParseError.InvalidFormat, parseSExprTestSpec(std.testing.allocator, source));
    }
}

test "S-expression spec parser decodes native shortcuts" {
    const spec = try parseSExprTestSpec(std.testing.allocator,
        \\(test "save" (steps (shortcut (test-id "editor") "s" 3)))
    );
    defer spec.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), spec.commands.len);
    try std.testing.expectEqual(SpecCommandType.shortcut, spec.commands[0].kind());
    try std.testing.expect(legacyView(spec.commands[0].step).shortcut.?.eql(try signals.key_chord.parse("s", 3)));
}

test "file fixture forms reject malformed values and release partial allocations" {
    const invalid = [_][]const u8{
        "(resolve-file-choice \"open\" (chosen \"relative\"))",
        "(resolve-file-choice \"open\" (canceled \"extra\"))",
        "(resolve-file-choice \"open\" (chosen \"/tmp/a\") \"extra\")",
        "(resolve-file-read \"read\" :path \"/tmp/a\" :path \"duplicate\")",
        "(resolve-file-read \"read\" :path \"/tmp/a\" :wrong \"value\")",
        "(resolve-file-read \"read\" :path \"/tmp/a\" :text false)",
        "(resolve-file-write \"write\" :path \"/tmp/a\" :bytes -1)",
        "(resolve-file-write \"write\" :path \"/tmp/a\" :bytes 1048577)",
        "(reject-file \"read\" :kind invented :detail \"no\")",
        "(reject-file \"read\" :kind canceled :detail \"not empty\")",
    };
    for (invalid) |form| {
        const content = try std.fmt.allocPrint(std.testing.allocator, "(test \"invalid\" (steps {s}))", .{form});
        defer std.testing.allocator.free(content);
        try std.testing.expectError(error.InvalidFormat, parseSExprTestSpec(std.testing.allocator, content));
    }
}

fn parseFileFixtureAllocationCase(allocator: std.mem.Allocator) !void {
    var parsed = try parseSExprTestSpec(allocator,
        \\(test "file workflow"
        \\  (steps
        \\    (resolve-file-choice "open" (chosen "/tmp/λ:note.txt"))
        \\    (resolve-file-choice "save" (canceled))
        \\    (resolve-file-read "read" :path "/tmp/a" :text "first\nλ")
        \\    (resolve-file-write "write" :bytes 0 :path "/tmp/a")
        \\    (reject-file "read" :detail "not allowed" :kind permission-denied)))
    );
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 5), parsed.commands.len);
    try std.testing.expectEqualStrings("6:files18:canceled", legacyView(parsed.commands[1].step).expected.?);
    try std.testing.expectEqualStrings("6:files16:/tmp/a1:0", legacyView(parsed.commands[3].step).expected.?);
    try std.testing.expectEqual(SpecCommandType.reject_task, parsed.commands[4].kind());
    try std.testing.expectEqual(@as(usize, 4), parsed.commands[1].line_num);
}

test "file fixture parsing owns every allocation on success and refusal" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseFileFixtureAllocationCase, .{});
}

test "window close requests and assertions decode without locators" {
    const spec = try parseSExprTestSpec(std.testing.allocator,
        \\(test "closing" (steps (request-window-close) (expect-window-closed false)))
    );
    defer spec.deinit(std.testing.allocator);
    try std.testing.expectEqual(SpecCommandType.request_window_close, spec.commands[0].kind());
    try std.testing.expectEqual(false, legacyView(spec.commands[1].step).boolean.?);
    try std.testing.expectError(ParseError.InvalidFormat, parseSExprTestSpec(std.testing.allocator, "(test \"t\" (steps (request-window-close extra)))"));
    try std.testing.expectError(ParseError.InvalidFormat, parseSExprTestSpec(std.testing.allocator, "(test \"t\" (steps (expect-window-closed yes)))"));
}

fn parseExtendedFileFixtureAllocationCase(allocator: std.mem.Allocator) !void {
    var parsed = try parseSExprTestSpec(allocator,
        \\(test "native content"
        \\ (steps
        \\  (resolve-file-log "tail" :path "/tmp/log" :text "λ\n" :device 18446744073709551615 :inode 13 :offset 3 :change rotated :state partial-utf8)
        \\  (resolve-file-directory "folder" :path "/tmp" :entries ((file "/tmp/λ" 18446744073709551615) (directory "/tmp/child" 0) (symbolic-link "/tmp/link" 9)))
        \\  (resolve-file-preview "preview" :path "/tmp/λ" :text "first\nsecond" :truncated true)
        \\  (resolve-file-open "launch" :path "/tmp/λ")))
    );
    defer parsed.deinit(allocator);
    try std.testing.expectEqualStrings("6:files18:/tmp/log3:λ\n20:184467440737095516152:131:37:rotated12:partial-utf8", legacyView(parsed.commands[0].step).expected.?);
    try std.testing.expect(file_fixtures.admits(legacyView(parsed.commands[0].step).kinds, .read_log));
    try std.testing.expect(!file_fixtures.admits(legacyView(parsed.commands[0].step).kinds, .read_text));
    try std.testing.expect(file_fixtures.admits(legacyView(parsed.commands[1].step).kinds, .list_directory));
    try std.testing.expect(!file_fixtures.admits(legacyView(parsed.commands[1].step).kinds, .scan_directory));
    try std.testing.expectEqualStrings("6:files17:/tmp/λ12:first\nsecond4:true", legacyView(parsed.commands[2].step).expected.?);
    try std.testing.expectEqualStrings("6:files17:/tmp/λ", legacyView(parsed.commands[3].step).expected.?);
}

test "extended file fixtures preserve full unsigned cursors under allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseExtendedFileFixtureAllocationCase, .{});
}

test "extended file fixtures reject noncanonical unsigned numbers and unknown tags" {
    for ([_][]const u8{ "-1", "+1", "00", "01", "18446744073709551616", "\"123\"" }) |number| {
        const text = try std.fmt.allocPrint(std.testing.allocator, "(test \"bad cursor\" (steps (resolve-file-log \"tail\" :path \"/tmp/log\" :text \"\" :device {s} :inode 1 :offset 0 :change initial :state at-end)))", .{number});
        defer std.testing.allocator.free(text);
        try std.testing.expectError(error.InvalidFormat, parseSExprTestSpec(std.testing.allocator, text));
    }
    for ([_][]const u8{
        "(resolve-file-preview \"preview\" :path \"/tmp/a\" :text \"x\" :truncated \"true\")",
        "(resolve-file-directory \"folder\" :path \"/tmp\" :entries ((imaginary \"/tmp/a\" 1)))",
        "(resolve-file-directory \"folder\" :path \"/tmp\" :entries ((file \"/tmp/a\" +1)))",
        "(resolve-file-log \"tail\" :path \"/tmp/log\" :text \"\" :device 1 :inode 2 :offset 0 :change replaced :state at-end)",
        "(resolve-file-log \"tail\" :path \"/tmp/log\" :text \"\" :device 1 :inode 2 :offset 0 :change initial :state finished)",
        "(resolve-file-log \"tail\" :path \"/tmp/log\" :text \"\" :device 1 :inode 2 :offset 0 :change initial :change at-end)",
    }) |form| {
        const text = try std.fmt.allocPrint(std.testing.allocator, "(test \"bad native content\" (steps {s}))", .{form});
        defer std.testing.allocator.free(text);
        try std.testing.expectError(error.InvalidFormat, parseSExprTestSpec(std.testing.allocator, text));
    }
}

test "extended file fixtures reject oversized preview text before settlement" {
    const oversized = try std.testing.allocator.alloc(u8, 65537);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'a');
    const text = try std.fmt.allocPrint(std.testing.allocator, "(test \"too large\" (steps (resolve-file-preview \"preview\" :path \"/tmp/a\" :text \"{s}\" :truncated false)))", .{oversized});
    defer std.testing.allocator.free(text);
    try std.testing.expectError(error.InvalidFormat, parseSExprTestSpec(std.testing.allocator, text));
}
