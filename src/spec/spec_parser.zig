//! Parser for text-based Signals example specs and assertions.

const std = @import("std");
const signals = @import("signals");
const boundary = signals.boundary;
const sexpr = @import("sexpr.zig");
const file_fixtures = @import("file_fixtures.zig");
const http_fixtures = @import("http_fixtures.zig");

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
    stub_file_result,
    seed_file_result,
    stub_http_result,
    seed_http_result,
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
    assert_current_location,
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
        try writer.print("  {d}: {s}", .{ cmd.line_num, @tagName(cmd.cmd_type) });
        try writer.print(" locator={s}", .{@tagName(cmd.locator.kind)});
        try writeField(writer, "role", cmd.locator.role);
        try writeField(writer, "name", cmd.locator.name);
        try writeField(writer, "label", cmd.locator.label);
        try writeField(writer, "text", cmd.locator.text);
        try writeField(writer, "test_id", cmd.locator.test_id);
        try writeField(writer, "task", cmd.task_name);
        if (cmd.file_stub) |stub| try writeFileStub(writer, stub);
        if (cmd.http_stub) |stub| try writeHttpStub(writer, stub);
        try writeField(writer, "attr", cmd.expected_attr);
        if (cmd.interval_ms) |value| try writer.print(" interval={d}", .{value});
        if (cmd.shortcut) |chord| try writer.print(" shortcut={d}+{d}", .{ chord.key, chord.modifiers });
        try writeField(writer, "expected", cmd.expected_text);
        if (cmd.expected_count) |value| try writer.print(" count={d}", .{value});
        if (cmd.expected_metric_delta) |value| try writer.print(" delta={d}", .{value});
        if (cmd.expected_bool) |value| try writer.print(" bool={}", .{value});
        try writer.writeByte('\n');
    }
}

/// A scripted file answer, every field spelled out in the order the form
/// declares them, so a stub that changes shape moves a golden line.
fn writeFileStub(writer: *std.Io.Writer, stub: file_fixtures.Stub) std.Io.Writer.Error!void {
    try writer.print(" file={s}", .{@tagName(stub)});
    switch (stub) {
        .choice => |path| {
            try writer.writeAll(" path=");
            try writeOptionalQuoted(writer, path);
        },
        .stat => |value| {
            try writeField(writer, "path", value.path);
            try writer.print(" kind={s} bytes={d} device={d} inode={d}", .{ @tagName(value.kind), value.bytes, value.device, value.inode });
        },
        .read => |value| {
            try writeField(writer, "path", value.path);
            try writeField(writer, "bytes", value.bytes);
            if (value.offset) |offset| try writer.print(" offset={d}", .{offset});
            if (value.size) |size| try writer.print(" size={d}", .{size});
        },
        .directory => |value| {
            try writeField(writer, "path", value.path);
            try writer.writeAll(" entries=[");
            for (value.entries, 0..) |entry, index| {
                if (index > 0) try writer.writeByte(' ');
                try writer.print("{s}:{d}:", .{ @tagName(entry.kind), entry.bytes });
                try writeQuoted(writer, entry.path);
            }
            try writer.writeByte(']');
        },
        .open => |path| try writeField(writer, "path", path),
        .reject => |value| {
            try writer.print(" kind={s}", .{@tagName(value.kind)});
            try writeField(writer, "detail", value.detail);
        },
    }
}

/// A scripted HTTP answer in the same spirit.
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

pub const SpecCommand = struct {
    cmd_type: SpecCommandType,
    locator: Locator,
    task_name: ?[]const u8 = null,
    expected_attr: ?[]const u8 = null,
    interval_ms: ?u64 = null,
    shortcut: ?signals.key_chord.Chord = null,
    expected_text: ?[]const u8,
    expected_count: ?u64,
    expected_metric_delta: ?i64 = null,
    expected_bool: ?bool,
    file_stub: ?file_fixtures.Stub = null,
    http_stub: ?http_fixtures.Stub = null,
    line_num: usize,
};

/// Releases every allocation owned by spec commands.
pub fn freeSpecCommands(allocator: std.mem.Allocator, commands: []SpecCommand) void {
    for (commands) |cmd| {
        cmd.locator.deinit(allocator);
        if (cmd.task_name) |name| allocator.free(name);
        if (cmd.expected_attr) |attr| allocator.free(attr);
        if (cmd.expected_text) |text| allocator.free(text);
        if (cmd.file_stub) |stub| stub.deinit(allocator);
        if (cmd.http_stub) |stub| stub.deinit(allocator);
    }
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

    return parseSExprTestSpecFrom(allocator, content, std.fs.path.dirname(file_path) orelse "");
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
    return parseSExprTestSpecFrom(allocator, content, "");
}

/// Parses spec text whose relative file references resolve against `base_dir`.
pub fn parseSExprTestSpecFrom(allocator: std.mem.Allocator, content: []const u8, base_dir: []const u8) ParseError!ParsedTestSpec {
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
            for (section_items[1..]) |form| try appendDecodedForm(allocator, &commands, form, true, base_dir);
        } else if (exprSymbolEql(section_items[0], "steps")) {
            if (saw_steps) return ParseError.InvalidFormat;
            saw_steps = true;
            if (section_items.len == 1) return ParseError.InvalidFormat;
            for (section_items[1..]) |form| try appendDecodedForm(allocator, &commands, form, false, base_dir);
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
            switch (cmd.cmd_type) {
                .resolve_task, .resolve_stale_task, .reject_task => return ParseError.InvalidFormat,
                .close => if (index + 1 != commands.items.len) return ParseError.InvalidFormat,
                else => {},
            }
        }
    } else {
        for (commands.items) |cmd| if (isWindowOnly(cmd.cmd_type)) return ParseError.InvalidFormat;
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
/// the head is not one. These never pass through the legacy line grammar.
fn decodeWindowForm(allocator: std.mem.Allocator, head: []const u8, args: []const sexpr.Expr, line: usize) ParseError!?SpecCommand {
    var command: SpecCommand = .{
        .cmd_type = .wait,
        .locator = emptyLocator(),
        .expected_text = null,
        .expected_count = null,
        .expected_bool = null,
        .line_num = line,
    };
    if (std.mem.eql(u8, head, "wait")) {
        if (args.len != 1) return ParseError.InvalidFormat;
        command.interval_ms = try exprUnsigned(args[0]);
    } else if (std.mem.eql(u8, head, "type")) {
        if (args.len != 2) return ParseError.InvalidFormat;
        command.cmd_type = .type_text;
        command.locator = try locatorFromExpr(allocator, args[0]);
        errdefer command.locator.deinit(allocator);
        const text = exprString(args[1]) orelse return ParseError.InvalidFormat;
        if (text.len == 0) return ParseError.InvalidFormat;
        command.expected_text = try dupePlain(allocator, text);
    } else if (std.mem.eql(u8, head, "key")) {
        if (args.len != 1) return ParseError.InvalidFormat;
        command.cmd_type = .key;
        const text = exprString(args[0]) orelse return ParseError.InvalidFormat;
        if (text.len == 0) return ParseError.InvalidFormat;
        command.expected_text = try dupePlain(allocator, text);
    } else if (std.mem.eql(u8, head, "expect-onscreen")) {
        if (args.len != 1) return ParseError.InvalidFormat;
        command.cmd_type = .expect_onscreen;
        command.locator = try locatorFromExpr(allocator, args[0]);
    } else if (std.mem.eql(u8, head, "expect-focused")) {
        if (args.len != 1) return ParseError.InvalidFormat;
        command.cmd_type = .expect_focused;
        command.locator = try locatorFromExpr(allocator, args[0]);
    } else if (std.mem.eql(u8, head, "expect-selected")) {
        if (args.len != 2) return ParseError.InvalidFormat;
        command.cmd_type = .expect_selected;
        command.locator = try locatorFromExpr(allocator, args[0]);
        errdefer command.locator.deinit(allocator);
        command.expected_bool = try exprBool(args[1]);
    } else if (std.mem.eql(u8, head, "expect-history")) {
        if (args.len != 2) return ParseError.InvalidFormat;
        command.cmd_type = .expect_history;
        command.locator = try locatorFromExpr(allocator, args[0]);
        errdefer command.locator.deinit(allocator);
        command.expected_count = try exprUnsigned(args[1]);
    } else if (std.mem.eql(u8, head, "expect-count")) {
        if (args.len != 2) return ParseError.InvalidFormat;
        command.cmd_type = .expect_count;
        const prefix = exprString(args[0]) orelse return ParseError.InvalidFormat;
        if (prefix.len == 0) return ParseError.InvalidFormat;
        command.expected_text = try dupePlain(allocator, prefix);
        errdefer allocator.free(command.expected_text.?);
        command.expected_count = try exprUnsigned(args[1]);
    } else if (std.mem.eql(u8, head, "snapshot")) {
        if (args.len != 1) return ParseError.InvalidFormat;
        command.cmd_type = .snapshot;
        const text = exprString(args[0]) orelse return ParseError.InvalidFormat;
        if (text.len == 0) return ParseError.InvalidFormat;
        command.expected_text = try dupePlain(allocator, text);
    } else if (std.mem.eql(u8, head, "close")) {
        if (args.len != 0) return ParseError.InvalidFormat;
        command.cmd_type = .close;
    } else {
        return null;
    }
    return command;
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
    base_dir: []const u8,
) ParseError!void {
    const items = exprList(form) orelse return ParseError.InvalidFormat;
    if (items.len == 0) return ParseError.InvalidFormat;
    const head = exprSymbol(items[0]) orelse return ParseError.InvalidFormat;
    const args = items[1..];
    const line = form.span.line;

    // Scripted primitives are allowed in both sections: in setup they seed
    // the answer before the application mounts, in steps they stub it.
    const command: SpecCommand = if (file_fixtures.recognizes(head))
        try decodeFileFixtureForm(allocator, base_dir, head, args, is_setup, line)
    else if (http_fixtures.recognizes(head))
        try decodeHttpFixtureForm(allocator, head, args, is_setup, line)
    else if (is_setup)
        try decodeSetupForm(allocator, head, args, line)
    else if (try decodeWindowForm(allocator, head, args, line)) |window|
        window
    else
        try decodeStepForm(allocator, head, args, line);

    commands.append(allocator, command) catch {
        freeOneCommand(allocator, command);
        return ParseError.OutOfMemory;
    };
}

/// A scripted file primitive: a `(stub-file-* ...)` step, or the same form in
/// `(setup ...)`, which seeds the answer before the application mounts.
fn decodeFileFixtureForm(allocator: std.mem.Allocator, base_dir: []const u8, head: []const u8, args: []const sexpr.Expr, is_setup: bool, line: usize) ParseError!SpecCommand {
    const fixture = try file_fixtures.parse(allocator, base_dir, head, args);
    return .{
        .cmd_type = if (is_setup) .seed_file_result else .stub_file_result,
        .locator = emptyLocator(),
        .task_name = fixture.label,
        .expected_text = null,
        .expected_count = null,
        .expected_bool = null,
        .file_stub = fixture.stub,
        .line_num = line,
    };
}

/// A scripted HTTP exchange, stubbed in the steps or seeded in the setup.
fn decodeHttpFixtureForm(allocator: std.mem.Allocator, head: []const u8, args: []const sexpr.Expr, is_setup: bool, line: usize) ParseError!SpecCommand {
    const fixture = try http_fixtures.parse(allocator, head, args);
    return .{
        .cmd_type = if (is_setup) .seed_http_result else .stub_http_result,
        .locator = emptyLocator(),
        .task_name = fixture.label,
        .expected_text = null,
        .expected_count = null,
        .expected_bool = null,
        .http_stub = fixture.stub,
        .line_num = line,
    };
}

/// A bare command with nothing but its type and line; the decoders below fill
/// in what each form carries and free what they took if a later argument fails.
fn bare(cmd_type: SpecCommandType, line: usize) SpecCommand {
    return .{
        .cmd_type = cmd_type,
        .locator = emptyLocator(),
        .expected_text = null,
        .expected_count = null,
        .expected_bool = null,
        .line_num = line,
    };
}

/// The pre-mount state a `(setup ...)` may declare. Setup is declarative:
/// nothing here dispatches an event or touches the tree.
fn decodeSetupForm(allocator: std.mem.Allocator, head: []const u8, args: []const sexpr.Expr, line: usize) ParseError!SpecCommand {
    if (std.mem.eql(u8, head, "initial-location")) {
        return textForm(allocator, .set_initial_location, args, line);
    } else if (std.mem.eql(u8, head, "initial-visibility")) {
        return symbolForm(allocator, .set_initial_visibility, args, line);
    } else if (std.mem.eql(u8, head, "initial-online")) {
        return symbolForm(allocator, .set_initial_online, args, line);
    } else if (std.mem.eql(u8, head, "local-storage")) {
        return keyValueForm(allocator, .seed_local_storage, args, line);
    } else if (std.mem.eql(u8, head, "session-storage")) {
        return keyValueForm(allocator, .seed_session_storage, args, line);
    }
    return ParseError.InvalidFormat;
}

/// Every step a `(test ...)` may take, decoded straight from its form. The
/// head is the spec spelling; the command type is the runner's. Argument
/// shapes are checked here once, with the line of the form in every refusal.
fn decodeStepForm(allocator: std.mem.Allocator, head: []const u8, args: []const sexpr.Expr, line: usize) ParseError!SpecCommand {
    // Setup vocabulary is refused inside steps by falling through to the
    // unknown-head refusal below: none of these heads is a step.
    const Shape = enum { locator, locator_text, locator_bool, locator_count, text, symbol, key_value, key, count_after_key, interval, interval_count, metric_delta, none };
    const Form = struct { head: []const u8, cmd_type: SpecCommandType, shape: Shape };
    const forms = [_]Form{
        .{ .head = "click", .cmd_type = .click, .shape = .locator },
        .{ .head = "real-click", .cmd_type = .real_click, .shape = .locator },
        .{ .head = "pointer-down", .cmd_type = .pointer_down, .shape = .locator },
        .{ .head = "pointer-up", .cmd_type = .pointer_up, .shape = .locator },
        .{ .head = "pointer-enter", .cmd_type = .pointer_enter, .shape = .locator },
        .{ .head = "pointer-leave", .cmd_type = .pointer_leave, .shape = .locator },
        .{ .head = "focus", .cmd_type = .focus, .shape = .locator },
        .{ .head = "blur", .cmd_type = .blur, .shape = .locator },
        .{ .head = "composition-start", .cmd_type = .composition_start, .shape = .locator },
        .{ .head = "composition-end", .cmd_type = .composition_end, .shape = .locator },
        .{ .head = "submit", .cmd_type = .submit, .shape = .locator },
        .{ .head = "check", .cmd_type = .check, .shape = .locator },
        .{ .head = "uncheck", .cmd_type = .uncheck, .shape = .locator },
        .{ .head = "expect-visible", .cmd_type = .expect_visible, .shape = .locator },
        .{ .head = "expect-absent", .cmd_type = .expect_absent, .shape = .locator },
        .{ .head = "fill", .cmd_type = .fill, .shape = .locator_text },
        .{ .head = "change", .cmd_type = .change, .shape = .locator_text },
        .{ .head = "select-option", .cmd_type = .select_option, .shape = .locator_text },
        .{ .head = "expect-text", .cmd_type = .expect_text, .shape = .locator_text },
        .{ .head = "expect-value", .cmd_type = .expect_value, .shape = .locator_text },
        .{ .head = "expect-checked", .cmd_type = .expect_checked, .shape = .locator_bool },
        .{ .head = "expect-disabled", .cmd_type = .expect_disabled, .shape = .locator_bool },
        .{ .head = "expect-updates", .cmd_type = .expect_updates, .shape = .locator_count },
        .{ .head = "navigate", .cmd_type = .navigate, .shape = .text },
        .{ .head = "expect-current-location", .cmd_type = .expect_current_location, .shape = .text },
        .{ .head = "assert-current-location", .cmd_type = .expect_current_location, .shape = .text },
        .{ .head = "expect-document-title", .cmd_type = .expect_document_title, .shape = .text },
        .{ .head = "set-visibility", .cmd_type = .set_visibility, .shape = .symbol },
        .{ .head = "set-online", .cmd_type = .set_online, .shape = .symbol },
        .{ .head = "history-back", .cmd_type = .history_back, .shape = .none },
        .{ .head = "history-forward", .cmd_type = .history_forward, .shape = .none },
        .{ .head = "request-window-close", .cmd_type = .request_window_close, .shape = .none },
        .{ .head = "mark-metrics", .cmd_type = .mark_metrics, .shape = .none },
        .{ .head = "resolve-task", .cmd_type = .resolve_task, .shape = .key_value },
        .{ .head = "resolve-stale-task", .cmd_type = .resolve_stale_task, .shape = .key_value },
        .{ .head = "reject-task", .cmd_type = .reject_task, .shape = .key_value },
        .{ .head = "expect-local-storage", .cmd_type = .expect_local_storage, .shape = .key_value },
        .{ .head = "expect-session-storage", .cmd_type = .expect_session_storage, .shape = .key_value },
        .{ .head = "expect-no-local-storage", .cmd_type = .expect_no_local_storage, .shape = .key },
        .{ .head = "expect-no-session-storage", .cmd_type = .expect_no_session_storage, .shape = .key },
        .{ .head = "expect-cleanup", .cmd_type = .expect_cleanup, .shape = .count_after_key },
        .{ .head = "expect-pending-task", .cmd_type = .expect_pending_task, .shape = .count_after_key },
        .{ .head = "expect-canceled-task", .cmd_type = .expect_canceled_task, .shape = .count_after_key },
        .{ .head = "tick-interval", .cmd_type = .tick_interval, .shape = .interval },
        .{ .head = "tick-interval-if-active", .cmd_type = .tick_interval_if_active, .shape = .interval },
        .{ .head = "expect-interval", .cmd_type = .expect_interval, .shape = .interval_count },
        .{ .head = "expect-metric-delta", .cmd_type = .expect_metric_delta, .shape = .metric_delta },
        .{ .head = "expect-metric-delta-at-most", .cmd_type = .expect_metric_delta_at_most, .shape = .metric_delta },
    };
    for (forms) |form| {
        if (!std.mem.eql(u8, head, form.head)) continue;
        return switch (form.shape) {
            .locator => locatorForm(allocator, form.cmd_type, args, line),
            .locator_text => locatorTextForm(allocator, form.cmd_type, args, line),
            .locator_bool => locatorBoolForm(allocator, form.cmd_type, args, line),
            .locator_count => locatorCountForm(allocator, form.cmd_type, args, line),
            .text => textForm(allocator, form.cmd_type, args, line),
            .symbol => symbolForm(allocator, form.cmd_type, args, line),
            .key_value => keyValueForm(allocator, form.cmd_type, args, line),
            .key => keyForm(allocator, form.cmd_type, args, line),
            .count_after_key => countAfterKeyForm(allocator, form.cmd_type, args, line),
            .interval => intervalForm(form.cmd_type, args, line),
            .interval_count => intervalCountForm(args, line),
            .metric_delta => metricDeltaForm(allocator, form.cmd_type, args, line),
            .none => if (args.len == 0) bare(form.cmd_type, line) else ParseError.InvalidFormat,
        };
    }
    // The few forms whose shape is their own.
    if (std.mem.eql(u8, head, "key-down")) {
        if (args.len != 3) return ParseError.InvalidFormat;
        var command = bare(.key_down, line);
        command.locator = try locatorFromExpr(allocator, args[0]);
        errdefer command.locator.deinit(allocator);
        command.expected_text = try dupePlain(allocator, exprString(args[1]) orelse return ParseError.InvalidFormat);
        errdefer allocator.free(command.expected_text.?);
        command.expected_bool = try exprBool(args[2]);
        return command;
    } else if (std.mem.eql(u8, head, "shortcut")) {
        if (args.len != 3) return ParseError.InvalidFormat;
        const key = exprString(args[1]) orelse return ParseError.InvalidFormat;
        const modifiers = try exprUnsigned(args[2]);
        if (modifiers > std.math.maxInt(u32)) return ParseError.InvalidFormat;
        const chord = signals.key_chord.parse(key, @intCast(modifiers)) catch return ParseError.InvalidFormat;
        var command = bare(.shortcut, line);
        command.locator = try locatorFromExpr(allocator, args[0]);
        command.shortcut = chord;
        return command;
    } else if (std.mem.eql(u8, head, "custom-event")) {
        if (args.len != 3) return ParseError.InvalidFormat;
        var command = bare(.custom_event, line);
        command.locator = try locatorFromExpr(allocator, args[0]);
        errdefer command.locator.deinit(allocator);
        command.task_name = try dupePlain(allocator, exprString(args[1]) orelse return ParseError.InvalidFormat);
        errdefer allocator.free(command.task_name.?);
        command.expected_text = try dupePlain(allocator, exprString(args[2]) orelse return ParseError.InvalidFormat);
        return command;
    } else if (std.mem.eql(u8, head, "expect-attr")) {
        if (args.len != 3) return ParseError.InvalidFormat;
        var command = bare(.expect_attr, line);
        command.locator = try locatorFromExpr(allocator, args[0]);
        errdefer command.locator.deinit(allocator);
        command.expected_attr = try dupePlain(allocator, exprSymbol(args[1]) orelse exprString(args[1]) orelse return ParseError.InvalidFormat);
        errdefer allocator.free(command.expected_attr.?);
        command.expected_text = try dupePlain(allocator, exprString(args[2]) orelse return ParseError.InvalidFormat);
        return command;
    } else if (std.mem.eql(u8, head, "expect-no-attr")) {
        if (args.len != 2) return ParseError.InvalidFormat;
        var command = bare(.expect_no_attr, line);
        command.locator = try locatorFromExpr(allocator, args[0]);
        errdefer command.locator.deinit(allocator);
        command.expected_attr = try dupePlain(allocator, exprSymbol(args[1]) orelse exprString(args[1]) orelse return ParseError.InvalidFormat);
        return command;
    } else if (std.mem.eql(u8, head, "expect-window-closed")) {
        if (args.len != 1) return ParseError.InvalidFormat;
        var command = bare(.expect_window_closed, line);
        command.expected_bool = try exprBool(args[0]);
        return command;
    }
    return ParseError.InvalidFormat;
}

fn locatorForm(allocator: std.mem.Allocator, cmd_type: SpecCommandType, args: []const sexpr.Expr, line: usize) ParseError!SpecCommand {
    if (args.len != 1) return ParseError.InvalidFormat;
    var command = bare(cmd_type, line);
    command.locator = try locatorFromExpr(allocator, args[0]);
    return command;
}

fn locatorTextForm(allocator: std.mem.Allocator, cmd_type: SpecCommandType, args: []const sexpr.Expr, line: usize) ParseError!SpecCommand {
    if (args.len != 2) return ParseError.InvalidFormat;
    var command = bare(cmd_type, line);
    command.locator = try locatorFromExpr(allocator, args[0]);
    errdefer command.locator.deinit(allocator);
    command.expected_text = try dupePlain(allocator, exprString(args[1]) orelse return ParseError.InvalidFormat);
    return command;
}

fn locatorBoolForm(allocator: std.mem.Allocator, cmd_type: SpecCommandType, args: []const sexpr.Expr, line: usize) ParseError!SpecCommand {
    if (args.len != 2) return ParseError.InvalidFormat;
    var command = bare(cmd_type, line);
    command.locator = try locatorFromExpr(allocator, args[0]);
    errdefer command.locator.deinit(allocator);
    command.expected_bool = try exprBool(args[1]);
    return command;
}

fn locatorCountForm(allocator: std.mem.Allocator, cmd_type: SpecCommandType, args: []const sexpr.Expr, line: usize) ParseError!SpecCommand {
    if (args.len != 2) return ParseError.InvalidFormat;
    var command = bare(cmd_type, line);
    command.locator = try locatorFromExpr(allocator, args[0]);
    errdefer command.locator.deinit(allocator);
    command.expected_count = try exprUnsigned(args[1]);
    return command;
}

fn textForm(allocator: std.mem.Allocator, cmd_type: SpecCommandType, args: []const sexpr.Expr, line: usize) ParseError!SpecCommand {
    if (args.len != 1) return ParseError.InvalidFormat;
    var command = bare(cmd_type, line);
    command.expected_text = try dupePlain(allocator, exprString(args[0]) orelse return ParseError.InvalidFormat);
    return command;
}

/// A bare-word value such as `hidden` or `offline`; the host validates the
/// vocabulary through `visibilitySnapshotFromSpecText` and its siblings.
fn symbolForm(allocator: std.mem.Allocator, cmd_type: SpecCommandType, args: []const sexpr.Expr, line: usize) ParseError!SpecCommand {
    if (args.len != 1) return ParseError.InvalidFormat;
    var command = bare(cmd_type, line);
    command.expected_text = try dupePlain(allocator, exprSymbol(args[0]) orelse return ParseError.InvalidFormat);
    return command;
}

fn keyValueForm(allocator: std.mem.Allocator, cmd_type: SpecCommandType, args: []const sexpr.Expr, line: usize) ParseError!SpecCommand {
    if (args.len != 2) return ParseError.InvalidFormat;
    var command = bare(cmd_type, line);
    command.task_name = try dupePlain(allocator, exprString(args[0]) orelse return ParseError.InvalidFormat);
    errdefer allocator.free(command.task_name.?);
    command.expected_text = try dupePlain(allocator, exprString(args[1]) orelse return ParseError.InvalidFormat);
    return command;
}

fn keyForm(allocator: std.mem.Allocator, cmd_type: SpecCommandType, args: []const sexpr.Expr, line: usize) ParseError!SpecCommand {
    if (args.len != 1) return ParseError.InvalidFormat;
    var command = bare(cmd_type, line);
    command.task_name = try dupePlain(allocator, exprString(args[0]) orelse return ParseError.InvalidFormat);
    return command;
}

fn countAfterKeyForm(allocator: std.mem.Allocator, cmd_type: SpecCommandType, args: []const sexpr.Expr, line: usize) ParseError!SpecCommand {
    if (args.len != 2) return ParseError.InvalidFormat;
    var command = bare(cmd_type, line);
    command.task_name = try dupePlain(allocator, exprString(args[0]) orelse return ParseError.InvalidFormat);
    errdefer allocator.free(command.task_name.?);
    command.expected_count = try exprUnsigned(args[1]);
    return command;
}

fn intervalForm(cmd_type: SpecCommandType, args: []const sexpr.Expr, line: usize) ParseError!SpecCommand {
    if (args.len != 1) return ParseError.InvalidFormat;
    var command = bare(cmd_type, line);
    command.interval_ms = try exprUnsigned(args[0]);
    return command;
}

fn intervalCountForm(args: []const sexpr.Expr, line: usize) ParseError!SpecCommand {
    if (args.len != 2) return ParseError.InvalidFormat;
    var command = bare(.expect_interval, line);
    command.interval_ms = try exprUnsigned(args[0]);
    command.expected_count = try exprUnsigned(args[1]);
    return command;
}

fn metricDeltaForm(allocator: std.mem.Allocator, cmd_type: SpecCommandType, args: []const sexpr.Expr, line: usize) ParseError!SpecCommand {
    if (args.len != 2) return ParseError.InvalidFormat;
    var command = bare(cmd_type, line);
    command.expected_text = try dupePlain(allocator, exprSymbol(args[0]) orelse return ParseError.InvalidFormat);
    errdefer allocator.free(command.expected_text.?);
    command.expected_metric_delta = try exprInteger(args[1]);
    return command;
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
    command.locator.deinit(allocator);
    if (command.task_name) |name| allocator.free(name);
    if (command.expected_attr) |attr| allocator.free(attr);
    if (command.expected_text) |text| allocator.free(text);
    if (command.file_stub) |stub| stub.deinit(allocator);
    if (command.http_stub) |stub| stub.deinit(allocator);
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
    try std.testing.expectEqual(SpecCommandType.set_initial_location, spec.commands[0].cmd_type);
    try std.testing.expectEqual(@as(usize, 4), spec.commands[0].line_num);
    try std.testing.expectEqual(SpecCommandType.seed_local_storage, spec.commands[2].cmd_type);
    try std.testing.expectEqual(SpecCommandType.fill, spec.commands[3].cmd_type);
    try std.testing.expectEqual(LocatorKind.label, spec.commands[3].locator.kind);
    try std.testing.expectEqualStrings("a@example.com", spec.commands[3].expected_text.?);
    try std.testing.expectEqual(SpecCommandType.real_click, spec.commands[4].cmd_type);
    try std.testing.expectEqual(LocatorKind.role_name, spec.commands[4].locator.kind);
    try std.testing.expectEqual(SpecCommandType.expect_metric_delta, spec.commands[6].cmd_type);
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

    try std.testing.expectEqual(LocatorKind.label, spec.commands[0].locator.kind);
    try std.testing.expectEqualStrings("Go to C:\\Users", spec.commands[0].locator.label.?);
    try std.testing.expectEqual(LocatorKind.role_name, spec.commands[1].locator.kind);
    try std.testing.expectEqualStrings("say \"hi\"", spec.commands[1].locator.name.?);
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
    try std.testing.expectEqual(SpecCommandType.click, spec.commands[0].cmd_type);
    try std.testing.expectEqual(SpecCommandType.wait, spec.commands[1].cmd_type);
    try std.testing.expectEqual(@as(u64, 800), spec.commands[1].interval_ms.?);
    try std.testing.expectEqual(SpecCommandType.expect_count, spec.commands[2].cmd_type);
    try std.testing.expectEqualStrings("event-", spec.commands[2].expected_text.?);
    try std.testing.expectEqual(@as(u64, 3), spec.commands[2].expected_count.?);
    try std.testing.expectEqual(SpecCommandType.type_text, spec.commands[3].cmd_type);
    try std.testing.expectEqual(LocatorKind.label, spec.commands[3].locator.kind);
    try std.testing.expectEqualStrings("hello", spec.commands[3].expected_text.?);
    try std.testing.expectEqual(SpecCommandType.key, spec.commands[4].cmd_type);
    try std.testing.expectEqual(SpecCommandType.expect_onscreen, spec.commands[5].cmd_type);
    try std.testing.expectEqualStrings("count", spec.commands[5].locator.test_id.?);
    try std.testing.expectEqual(@as(u64, 0), spec.commands[6].expected_count.?);
    try std.testing.expectEqual(true, spec.commands[7].expected_bool.?);
    try std.testing.expectEqual(SpecCommandType.expect_focused, spec.commands[8].cmd_type);
    try std.testing.expectEqualStrings("following", spec.commands[9].expected_text.?);
    try std.testing.expectEqual(SpecCommandType.close, spec.commands[10].cmd_type);
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
    try std.testing.expectEqual(SpecCommandType.expect_disabled, plain.commands[1].cmd_type);
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
    try std.testing.expectEqual(SpecCommandType.set_initial_location, commands[0].cmd_type);
    try std.testing.expectEqualStrings("/services/api?tab=logs#tail", commands[0].expected_text.?);
    try std.testing.expectEqual(SpecCommandType.set_initial_visibility, commands[1].cmd_type);
    try std.testing.expectEqualStrings("hidden", commands[1].expected_text.?);
    try std.testing.expectEqual(SpecCommandType.set_initial_online, commands[2].cmd_type);
    try std.testing.expectEqualStrings("offline", commands[2].expected_text.?);
    try std.testing.expectEqual(SpecCommandType.seed_local_storage, commands[3].cmd_type);
    try std.testing.expectEqualStrings("checkout:draft", commands[3].task_name.?);
    try std.testing.expectEqualStrings("saved", commands[3].expected_text.?);
    try std.testing.expectEqual(SpecCommandType.seed_session_storage, commands[4].cmd_type);
    try std.testing.expectEqualStrings("checkout:flash", commands[4].task_name.?);
    try std.testing.expectEqualStrings("shown", commands[4].expected_text.?);
    try std.testing.expectEqual(SpecCommandType.click, commands[5].cmd_type);
    try std.testing.expectEqual(LocatorKind.role_name, commands[5].locator.kind);
    try std.testing.expectEqualStrings("button", commands[5].locator.role.?);
    try std.testing.expectEqualStrings("Save", commands[5].locator.name.?);
    try std.testing.expectEqual(SpecCommandType.real_click, commands[6].cmd_type);
    try std.testing.expectEqualStrings("a@example.com", commands[7].expected_text.?);
    try std.testing.expectEqual(SpecCommandType.focus, commands[8].cmd_type);
    try std.testing.expectEqual(SpecCommandType.blur, commands[9].cmd_type);
    try std.testing.expectEqual(SpecCommandType.change, commands[10].cmd_type);
    try std.testing.expectEqualStrings("changed@example.com", commands[10].expected_text.?);
    try std.testing.expectEqual(SpecCommandType.select_option, commands[11].cmd_type);
    try std.testing.expectEqualStrings("growth", commands[11].expected_text.?);
    try std.testing.expectEqual(SpecCommandType.composition_start, commands[12].cmd_type);
    try std.testing.expectEqual(SpecCommandType.composition_end, commands[13].cmd_type);
    try std.testing.expectEqual(SpecCommandType.custom_event, commands[14].cmd_type);
    try std.testing.expectEqualStrings("chart", commands[14].locator.test_id.?);
    try std.testing.expectEqualStrings("chart-select", commands[14].task_name.?);
    try std.testing.expectEqualStrings("now | 1,200 rpm", commands[14].expected_text.?);
    try std.testing.expectEqualStrings("data-state", commands[15].expected_attr.?);
    try std.testing.expectEqualStrings("ready", commands[15].expected_text.?);
    try std.testing.expectEqualStrings("aria-invalid", commands[16].expected_attr.?);
    try std.testing.expectEqual(@as(?u64, 250), commands[17].interval_ms);
    try std.testing.expectEqual(SpecCommandType.tick_interval_if_active, commands[18].cmd_type);
    try std.testing.expectEqual(@as(?u64, 250), commands[18].interval_ms);
    try std.testing.expectEqual(@as(?u64, 1), commands[19].expected_count);
    try std.testing.expectEqual(@as(?u64, 250), commands[19].interval_ms);
    try std.testing.expectEqual(SpecCommandType.navigate, commands[20].cmd_type);
    try std.testing.expectEqualStrings("/services/web?tab=deploys#events", commands[20].expected_text.?);
    try std.testing.expectEqualStrings("visible", commands[21].expected_text.?);
    try std.testing.expectEqualStrings("online", commands[22].expected_text.?);
    try std.testing.expectEqual(SpecCommandType.history_back, commands[23].cmd_type);
    try std.testing.expectEqual(SpecCommandType.history_forward, commands[24].cmd_type);
    try std.testing.expectEqual(SpecCommandType.expect_current_location, commands[25].cmd_type);
    // `assert-current-location` is the older spelling of the same assertion.
    try std.testing.expectEqual(SpecCommandType.expect_current_location, commands[26].cmd_type);
    try std.testing.expectEqualStrings("Service Ops Center", commands[27].expected_text.?);
    try std.testing.expectEqualStrings("checkout:draft", commands[28].task_name.?);
    try std.testing.expectEqualStrings("saved", commands[28].expected_text.?);
    try std.testing.expectEqualStrings("checkout:flash", commands[29].task_name.?);
    try std.testing.expectEqual(SpecCommandType.expect_no_local_storage, commands[30].cmd_type);
    try std.testing.expectEqualStrings("checkout:missing", commands[30].task_name.?);
    try std.testing.expectEqual(SpecCommandType.expect_no_session_storage, commands[31].cmd_type);
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
    try std.testing.expectEqual(SpecCommandType.key_down, commands[0].cmd_type);
    try std.testing.expectEqual(@as(usize, 4), commands[0].line_num);
    try std.testing.expectEqualStrings("textbox", commands[0].locator.role.?);
    try std.testing.expectEqualStrings("Search", commands[0].locator.name.?);
    try std.testing.expectEqualStrings("Enter", commands[0].expected_text.?);
    try std.testing.expectEqual(@as(?bool, true), commands[0].expected_bool);
    try std.testing.expectEqual(SpecCommandType.expect_checked, commands[1].cmd_type);
    try std.testing.expectEqualStrings("Enabled", commands[1].locator.label.?);
    try std.testing.expectEqual(@as(?bool, false), commands[1].expected_bool);
    try std.testing.expectEqual(SpecCommandType.expect_disabled, commands[2].cmd_type);
    try std.testing.expectEqualStrings("submit", commands[2].locator.test_id.?);
    try std.testing.expectEqual(@as(?bool, true), commands[2].expected_bool);
    try std.testing.expectEqual(SpecCommandType.resolve_task, commands[3].cmd_type);
    try std.testing.expectEqualStrings("fetch user", commands[3].task_name.?);
    try std.testing.expectEqualStrings("hello\n\"world\"\\", commands[3].expected_text.?);
    try std.testing.expectEqual(SpecCommandType.resolve_stale_task, commands[4].cmd_type);
    try std.testing.expectEqualStrings("late", commands[4].expected_text.?);
    try std.testing.expectEqual(SpecCommandType.reject_task, commands[5].cmd_type);
    try std.testing.expectEqualStrings("bad\trequest", commands[5].expected_text.?);
    try std.testing.expectEqual(SpecCommandType.expect_cleanup, commands[6].cmd_type);
    try std.testing.expectEqualStrings("fetch user", commands[6].task_name.?);
    try std.testing.expectEqual(@as(?u64, 2), commands[6].expected_count);
    try std.testing.expectEqual(SpecCommandType.expect_pending_task, commands[7].cmd_type);
    try std.testing.expectEqual(@as(?u64, 1), commands[7].expected_count);
    try std.testing.expectEqual(SpecCommandType.expect_canceled_task, commands[8].cmd_type);
    try std.testing.expectEqual(SpecCommandType.mark_metrics, commands[9].cmd_type);
    try std.testing.expectEqual(SpecCommandType.expect_metric_delta, commands[10].cmd_type);
    try std.testing.expectEqualStrings("closure_releases", commands[10].expected_text.?);
    try std.testing.expectEqual(@as(?i64, -1), commands[10].expected_metric_delta);
    try std.testing.expectEqual(SpecCommandType.expect_metric_delta_at_most, commands[11].cmd_type);
    try std.testing.expectEqualStrings("host_retained_alloc_delta", commands[11].expected_text.?);
    try std.testing.expectEqual(@as(?i64, 0), commands[11].expected_metric_delta);
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
    try std.testing.expectEqual(SpecCommandType.pointer_down, commands[0].cmd_type);
    try std.testing.expectEqualStrings("drag-handle", commands[0].locator.test_id.?);
    try std.testing.expectEqual(SpecCommandType.pointer_up, commands[1].cmd_type);
    try std.testing.expectEqual(SpecCommandType.pointer_enter, commands[2].cmd_type);
    try std.testing.expectEqualStrings("Drop zone", commands[2].locator.text.?);
    try std.testing.expectEqual(SpecCommandType.pointer_leave, commands[3].cmd_type);
    try std.testing.expectEqual(SpecCommandType.submit, commands[4].cmd_type);
    try std.testing.expectEqualStrings("Save", commands[4].locator.name.?);
    try std.testing.expectEqual(SpecCommandType.check, commands[5].cmd_type);
    try std.testing.expectEqual(SpecCommandType.uncheck, commands[6].cmd_type);
    try std.testing.expectEqualStrings("Enabled", commands[6].locator.label.?);
    try std.testing.expectEqual(SpecCommandType.expect_text, commands[7].cmd_type);
    try std.testing.expectEqualStrings("Ready", commands[7].expected_text.?);
    try std.testing.expectEqual(SpecCommandType.expect_visible, commands[8].cmd_type);
    try std.testing.expectEqual(SpecCommandType.expect_absent, commands[9].cmd_type);
    try std.testing.expectEqualStrings("Loading", commands[9].locator.text.?);
    try std.testing.expectEqual(SpecCommandType.expect_value, commands[10].cmd_type);
    try std.testing.expectEqualStrings("a@example.com", commands[10].expected_text.?);
    try std.testing.expectEqual(SpecCommandType.expect_updates, commands[11].cmd_type);
    try std.testing.expectEqual(@as(?u64, 3), commands[11].expected_count);
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
    try std.testing.expectEqual(SpecCommandType.shortcut, commands[0].cmd_type);
    try std.testing.expectEqualStrings("editor", commands[0].locator.test_id.?);
    try std.testing.expect(commands[0].shortcut.?.eql(try signals.key_chord.parse("s", 1)));
    try std.testing.expect(commands[1].shortcut.?.eql(try signals.key_chord.parse("s", 3)));
    try std.testing.expect(commands[2].shortcut.?.eql(try signals.key_chord.parse("Escape", 0)));
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
    try std.testing.expectEqual(SpecCommandType.shortcut, spec.commands[0].cmd_type);
    try std.testing.expect(spec.commands[0].shortcut.?.eql(try signals.key_chord.parse("s", 3)));
}

test "file fixture forms reject malformed values and release partial allocations" {
    const invalid = [_][]const u8{
        "(stub-file-choice \"open\" (chosen \"relative\"))",
        "(stub-file-choice \"open\" (canceled \"extra\"))",
        "(stub-file-choice \"open\" (chosen \"/tmp/a\") \"extra\")",
        "(stub-file-read \"read\" :path \"/tmp/a\" :path \"duplicate\")",
        "(stub-file-read \"read\" :path \"/tmp/a\" :wrong \"value\")",
        "(stub-file-read \"read\" :path \"/tmp/a\" :text false)",
        "(stub-file-read \"read\" :path \"/tmp/a\" :text \"abc\" :size 2)",
        "(stub-file-stat \"stat\" :path \"/tmp/a\" :kind file :bytes -1)",
        "(stub-file-reject \"read\" :kind invented :detail \"no\")",
        "(stub-file-reject \"read\" :kind canceled :detail \"\")",
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
        \\    (stub-file-choice "open" (chosen "/tmp/λ:note.txt"))
        \\    (stub-file-choice "save" (canceled))
        \\    (stub-file-read "read" :path "/tmp/a" :text "first\nλ")
        \\    (stub-file-stat "stat" :bytes 0 :path "/tmp/a" :kind directory)
        \\    (stub-file-reject "read" :detail "not allowed" :kind permission-denied)))
    );
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 5), parsed.commands.len);
    try std.testing.expectEqualStrings("/tmp/λ:note.txt", parsed.commands[0].file_stub.?.choice.?);
    try std.testing.expect(parsed.commands[1].file_stub.?.choice == null);
    try std.testing.expectEqual(file_fixtures.Kind.directory, parsed.commands[3].file_stub.?.stat.kind);
    try std.testing.expectEqual(SpecCommandType.stub_file_result, parsed.commands[4].cmd_type);
    try std.testing.expectEqual(file_fixtures.ErrorKind.permission_denied, parsed.commands[4].file_stub.?.reject.kind);
}

test "file fixture parsing owns every allocation on success and refusal" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseFileFixtureAllocationCase, .{});
}

test "window close requests and assertions decode without locators" {
    const spec = try parseSExprTestSpec(std.testing.allocator,
        \\(test "closing" (steps (request-window-close) (expect-window-closed false)))
    );
    defer spec.deinit(std.testing.allocator);
    try std.testing.expectEqual(SpecCommandType.request_window_close, spec.commands[0].cmd_type);
    try std.testing.expectEqual(false, spec.commands[1].expected_bool.?);
    try std.testing.expectError(ParseError.InvalidFormat, parseSExprTestSpec(std.testing.allocator, "(test \"t\" (steps (request-window-close extra)))"));
    try std.testing.expectError(ParseError.InvalidFormat, parseSExprTestSpec(std.testing.allocator, "(test \"t\" (steps (expect-window-closed yes)))"));
}

fn parseExtendedFileFixtureAllocationCase(allocator: std.mem.Allocator) !void {
    var parsed = try parseSExprTestSpec(allocator,
        \\(test "native content"
        \\ (steps
        \\  (stub-file-stat "tail" :path "/tmp/log" :kind file :bytes 18446744073709551615 :device 1 :inode 13)
        \\  (stub-file-directory "folder" :path "/tmp" :entries ((file "/tmp/λ" 18446744073709551615) (directory "/tmp/child" 0) (symbolic-link "/tmp/link" 9)))
        \\  (stub-file-read "preview" :path "/tmp/λ" :text "first\nsecond" :offset 3 :size 70000)
        \\  (stub-file-open "launch" :path "/tmp/λ")))
    );
    defer parsed.deinit(allocator);
    const meta = parsed.commands[0].file_stub.?.stat;
    try std.testing.expectEqual(@as(u64, 18446744073709551615), meta.bytes);
    try std.testing.expectEqual(@as(u64, 13), meta.inode);
    const directory = parsed.commands[1].file_stub.?.directory;
    try std.testing.expectEqual(@as(usize, 3), directory.entries.len);
    try std.testing.expectEqual(file_fixtures.Kind.symbolic_link, directory.entries[2].kind);
    try std.testing.expectEqual(@as(u64, 18446744073709551615), directory.entries[0].bytes);
    const read = parsed.commands[2].file_stub.?.read;
    try std.testing.expectEqual(@as(?u64, 3), read.offset);
    try std.testing.expectEqual(@as(?u64, 70000), read.size);
    try std.testing.expectEqualStrings("/tmp/λ", parsed.commands[3].file_stub.?.open);
}

test "extended file fixtures preserve full unsigned cursors under allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseExtendedFileFixtureAllocationCase, .{});
}

test "extended file fixtures reject noncanonical unsigned numbers and unknown tags" {
    for ([_][]const u8{ "-1", "+1", "00", "01", "18446744073709551616", "\"123\"" }) |number| {
        const text = try std.fmt.allocPrint(std.testing.allocator, "(test \"bad cursor\" (steps (stub-file-stat \"tail\" :path \"/tmp/log\" :kind file :bytes 1 :device {s} :inode 1)))", .{number});
        defer std.testing.allocator.free(text);
        try std.testing.expectError(error.InvalidFormat, parseSExprTestSpec(std.testing.allocator, text));
    }
    for ([_][]const u8{
        "(stub-file-read \"preview\" :path \"/tmp/a\" :text \"x\" :truncated true)",
        "(stub-file-directory \"folder\" :path \"/tmp\" :entries ((imaginary \"/tmp/a\" 1)))",
        "(stub-file-directory \"folder\" :path \"/tmp\" :entries ((file \"/tmp/a\" +1)))",
        "(stub-file-stat \"tail\" :path \"/tmp/log\" :kind pipe :bytes 1)",
        "(stub-file-stat \"tail\" :path \"/tmp/log\" :kind file)",
        "(stub-file-stat \"tail\" :path \"/tmp/log\" :kind file :bytes 1 :device 1 :device 2)",
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
    const text = try std.fmt.allocPrint(std.testing.allocator, "(test \"too large\" (steps (stub-file-preview \"preview\" :path \"/tmp/a\" :text \"{s}\" :truncated false)))", .{oversized});
    defer std.testing.allocator.free(text);
    try std.testing.expectError(error.InvalidFormat, parseSExprTestSpec(std.testing.allocator, text));
}
