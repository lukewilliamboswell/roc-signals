//! Parser for text-based Signals example specs and assertions.

const std = @import("std");
const signals = @import("signals");
const boundary = signals.boundary;
const sexpr = @import("sexpr.zig");

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
    assert_current_location,
    expect_document_title,
    expect_local_storage,
    expect_session_storage,
    expect_no_local_storage,
    expect_no_session_storage,
    mark_metrics,
    expect_metric_delta,
    expect_metric_delta_at_most,
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
    expected_text: ?[]const u8,
    expected_count: ?u64,
    expected_metric_delta: ?i64 = null,
    expected_bool: ?bool,
    line_num: usize,
};

/// Provides the `freeSpecCommands` operation.
pub fn freeSpecCommands(allocator: std.mem.Allocator, commands: []SpecCommand) void {
    for (commands) |cmd| {
        cmd.locator.deinit(allocator);
        if (cmd.task_name) |name| allocator.free(name);
        if (cmd.expected_attr) |attr| allocator.free(attr);
        if (cmd.expected_text) |text| allocator.free(text);
    }
    if (commands.len > 0) {
        allocator.free(commands);
    }
}

pub const ParsedTestSpec = struct {
    name: []const u8,
    commands: []SpecCommand,

    /// Provides the `deinit` operation.
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

/// Provides the `parseTestSpecFile` operation.
pub fn parseTestSpecFile(allocator: std.mem.Allocator, file_path: []const u8) ParseError!ParsedTestSpec {
    const io = std.Io.Threaded.global_single_threaded.io();
    const content = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return ParseError.FileNotFound,
        else => return ParseError.IoError,
    };
    defer allocator.free(content);

    return parseSExprTestSpec(allocator, content);
}

const SplitTrailingQuoted = struct {
    head: []const u8,
    quoted: []const u8,
};

/// True when the byte at `idx` is escaped by an odd run of preceding backslashes.
fn isEscapedAt(input: []const u8, idx: usize) bool {
    var backslashes: usize = 0;
    var i = idx;
    while (i > 0) {
        i -= 1;
        if (input[i] != '\\') break;
        backslashes += 1;
    }
    return backslashes % 2 == 1;
}

/// Index of the last `"` that is not itself escaped.
///
/// The quoted values are unescaped later, so the delimiter scan has to skip
/// `\"` — otherwise an expected string containing a quote splits in the wrong
/// place and the whole line fails to parse.
fn findUnescapedQuoteLast(input: []const u8) ?usize {
    var i = input.len;
    while (i > 0) {
        i -= 1;
        if (input[i] == '"' and !isEscapedAt(input, i)) return i;
    }
    return null;
}

fn splitTrailingQuoted(input: []const u8) ParseError!SplitTrailingQuoted {
    const end_quote = findUnescapedQuoteLast(input) orelse return ParseError.InvalidFormat;
    if (end_quote == 0) return ParseError.InvalidFormat;
    const before_end = input[0..end_quote];
    const start_quote = findUnescapedQuoteLast(before_end) orelse return ParseError.InvalidFormat;
    const tail = std.mem.trim(u8, input[end_quote + 1 ..], " \t");
    if (tail.len != 0) return ParseError.InvalidFormat;
    return .{
        .head = std.mem.trim(u8, input[0..start_quote], " \t"),
        .quoted = input[start_quote + 1 .. end_quote],
    };
}

fn splitTrailingToken(input: []const u8) ParseError!struct { head: []const u8, token: []const u8 } {
    const trimmed = std.mem.trim(u8, input, " \t");
    const space_idx = std.mem.findLastAny(u8, trimmed, " \t") orelse return ParseError.InvalidFormat;
    return .{
        .head = std.mem.trim(u8, trimmed[0..space_idx], " \t"),
        .token = std.mem.trim(u8, trimmed[space_idx + 1 ..], " \t"),
    };
}

fn parseSingleQuoted(input: []const u8) ParseError![]const u8 {
    const trimmed = std.mem.trim(u8, input, " \t");
    if (trimmed.len < 2 or trimmed[0] != '"' or trimmed[trimmed.len - 1] != '"') return ParseError.InvalidFormat;
    return trimmed[1 .. trimmed.len - 1];
}

fn splitTwoQuoted(input: []const u8) ParseError!struct { first: []const u8, second: []const u8 } {
    const trimmed = std.mem.trim(u8, input, " \t");
    if (trimmed.len < 5 or trimmed[0] != '"') return ParseError.InvalidFormat;
    const first_end = std.mem.findScalarPos(u8, trimmed, 1, '"') orelse return ParseError.InvalidFormat;
    const rest = std.mem.trim(u8, trimmed[first_end + 1 ..], " \t");
    if (rest.len < 2 or rest[0] != '"' or rest[rest.len - 1] != '"') return ParseError.InvalidFormat;
    return .{
        .first = trimmed[1..first_end],
        .second = rest[1 .. rest.len - 1],
    };
}

fn dupeUnescapedQuoted(allocator: std.mem.Allocator, input: []const u8) ParseError![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (index < input.len) {
        const byte = input[index];
        if (byte != '\\') {
            out.append(allocator, byte) catch return ParseError.OutOfMemory;
            index += 1;
            continue;
        }

        index += 1;
        if (index >= input.len) return ParseError.InvalidFormat;
        const escaped: u8 = switch (input[index]) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            '\\' => '\\',
            '"' => '"',
            else => return ParseError.InvalidFormat,
        };
        out.append(allocator, escaped) catch return ParseError.OutOfMemory;
        index += 1;
    }

    return out.toOwnedSlice(allocator) catch return ParseError.OutOfMemory;
}

fn dupePlain(allocator: std.mem.Allocator, input: []const u8) ParseError![]u8 {
    return allocator.dupe(u8, input) catch return ParseError.OutOfMemory;
}

/// Provides the `locationSnapshotFromSpecText` operation.
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

/// Provides the `visibilitySnapshotFromSpecText` operation.
pub fn visibilitySnapshotFromSpecText(text: []const u8) ParseError!boundary.VisibilitySnapshot {
    if (std.mem.eql(u8, text, "visible")) return .visible;
    if (std.mem.eql(u8, text, "hidden")) return .hidden;
    return ParseError.InvalidFormat;
}

/// Provides the `onlineSnapshotFromSpecText` operation.
pub fn onlineSnapshotFromSpecText(text: []const u8) ParseError!boundary.OnlineSnapshot {
    if (std.mem.eql(u8, text, "online")) return .online;
    if (std.mem.eql(u8, text, "offline")) return .offline;
    return ParseError.InvalidFormat;
}

fn parseQuotedValue(allocator: std.mem.Allocator, prefix: []const u8, input: []const u8) ParseError!?[]const u8 {
    if (!std.mem.startsWith(u8, input, prefix)) return null;
    const rest = std.mem.trim(u8, input[prefix.len..], " \t");
    if (rest.len < 2 or rest[0] != '"' or rest[rest.len - 1] != '"') return ParseError.InvalidFormat;
    return allocator.dupe(u8, rest[1 .. rest.len - 1]) catch ParseError.OutOfMemory;
}

fn parseLocator(allocator: std.mem.Allocator, input: []const u8) ParseError!Locator {
    const trimmed = std.mem.trim(u8, input, " \t");
    if (trimmed.len == 0) return ParseError.InvalidFormat;

    if (std.mem.startsWith(u8, trimmed, "role:")) {
        const rest = trimmed["role:".len..];
        const space_idx = std.mem.findAny(u8, rest, " \t") orelse return ParseError.InvalidFormat;
        const role = rest[0..space_idx];
        const name_part = std.mem.trim(u8, rest[space_idx + 1 ..], " \t");
        const name = (try parseQuotedValue(allocator, "name:", name_part)) orelse return ParseError.InvalidFormat;
        const role_copy = allocator.dupe(u8, role) catch return ParseError.OutOfMemory;
        return .{
            .kind = .role_name,
            .role = role_copy,
            .name = name,
        };
    }

    if ((try parseQuotedValue(allocator, "label:", trimmed))) |value| return .{ .kind = .label, .label = value };
    if ((try parseQuotedValue(allocator, "text:", trimmed))) |value| return .{ .kind = .text, .text = value };
    if ((try parseQuotedValue(allocator, "test_id:", trimmed))) |value| return .{ .kind = .test_id, .test_id = value };

    return ParseError.InvalidFormat;
}

fn appendSpecCommand(
    commands: *std.ArrayListUnmanaged(SpecCommand),
    allocator: std.mem.Allocator,
    cmd_type: SpecCommandType,
    locator: Locator,
    expected_text: ?[]const u8,
    expected_count: ?u64,
    expected_bool: ?bool,
    line_num: usize,
) ParseError!void {
    commands.append(allocator, .{
        .cmd_type = cmd_type,
        .locator = locator,
        .expected_text = expected_text,
        .expected_count = expected_count,
        .expected_metric_delta = null,
        .expected_bool = expected_bool,
        .line_num = line_num,
    }) catch return ParseError.OutOfMemory;
}

fn parseBoolToken(token: []const u8) ParseError!bool {
    if (std.mem.eql(u8, token, "true")) return true;
    if (std.mem.eql(u8, token, "false")) return false;
    return ParseError.InvalidFormat;
}

/// Provides the `parseTestSpec` operation.
pub fn parseTestSpec(allocator: std.mem.Allocator, content: []const u8) ParseError![]SpecCommand {
    var commands: std.ArrayListUnmanaged(SpecCommand) = .empty;
    errdefer commands.deinit(allocator);

    var line_num: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');

    while (lines.next()) |line| {
        line_num += 1;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.mem.startsWith(u8, trimmed, "click ")) {
            try appendSpecCommand(&commands, allocator, .click, try parseLocator(allocator, trimmed[6..]), null, null, null, line_num);
        } else if (std.mem.startsWith(u8, trimmed, "real_click ")) {
            try appendSpecCommand(&commands, allocator, .real_click, try parseLocator(allocator, trimmed["real_click ".len..]), null, null, null, line_num);
        } else if (std.mem.startsWith(u8, trimmed, "pointer_down ")) {
            try appendSpecCommand(&commands, allocator, .pointer_down, try parseLocator(allocator, trimmed["pointer_down ".len..]), null, null, null, line_num);
        } else if (std.mem.startsWith(u8, trimmed, "pointer_up ")) {
            try appendSpecCommand(&commands, allocator, .pointer_up, try parseLocator(allocator, trimmed["pointer_up ".len..]), null, null, null, line_num);
        } else if (std.mem.startsWith(u8, trimmed, "pointer_enter ")) {
            try appendSpecCommand(&commands, allocator, .pointer_enter, try parseLocator(allocator, trimmed["pointer_enter ".len..]), null, null, null, line_num);
        } else if (std.mem.startsWith(u8, trimmed, "pointer_leave ")) {
            try appendSpecCommand(&commands, allocator, .pointer_leave, try parseLocator(allocator, trimmed["pointer_leave ".len..]), null, null, null, line_num);
        } else if (std.mem.startsWith(u8, trimmed, "key_down ")) {
            const shift_split = try splitTrailingToken(trimmed["key_down ".len..]);
            const key_split = try splitTrailingQuoted(shift_split.head);
            const key_copy = try dupeUnescapedQuoted(allocator, key_split.quoted);
            errdefer allocator.free(key_copy);
            try appendSpecCommand(&commands, allocator, .key_down, try parseLocator(allocator, key_split.head), key_copy, null, try parseBoolToken(shift_split.token), line_num);
        } else if (std.mem.startsWith(u8, trimmed, "focus ")) {
            try appendSpecCommand(&commands, allocator, .focus, try parseLocator(allocator, trimmed["focus ".len..]), null, null, null, line_num);
        } else if (std.mem.startsWith(u8, trimmed, "blur ")) {
            try appendSpecCommand(&commands, allocator, .blur, try parseLocator(allocator, trimmed["blur ".len..]), null, null, null, line_num);
        } else if (std.mem.startsWith(u8, trimmed, "change ")) {
            const split = try splitTrailingQuoted(trimmed["change ".len..]);
            const value_copy = try dupeUnescapedQuoted(allocator, split.quoted);
            try appendSpecCommand(&commands, allocator, .change, try parseLocator(allocator, split.head), value_copy, null, null, line_num);
        } else if (std.mem.startsWith(u8, trimmed, "select_option ")) {
            const split = try splitTrailingQuoted(trimmed["select_option ".len..]);
            const value_copy = try dupeUnescapedQuoted(allocator, split.quoted);
            try appendSpecCommand(&commands, allocator, .select_option, try parseLocator(allocator, split.head), value_copy, null, null, line_num);
        } else if (std.mem.startsWith(u8, trimmed, "composition_start ")) {
            try appendSpecCommand(&commands, allocator, .composition_start, try parseLocator(allocator, trimmed["composition_start ".len..]), null, null, null, line_num);
        } else if (std.mem.startsWith(u8, trimmed, "composition_end ")) {
            try appendSpecCommand(&commands, allocator, .composition_end, try parseLocator(allocator, trimmed["composition_end ".len..]), null, null, null, line_num);
        } else if (std.mem.startsWith(u8, trimmed, "custom_event ")) {
            const detail_split = try splitTrailingQuoted(trimmed["custom_event ".len..]);
            const event_split = try splitTrailingQuoted(detail_split.head);
            const event_name = try dupeUnescapedQuoted(allocator, event_split.quoted);
            errdefer allocator.free(event_name);
            const detail = try dupeUnescapedQuoted(allocator, detail_split.quoted);
            errdefer allocator.free(detail);
            try appendSpecCommand(&commands, allocator, .custom_event, try parseLocator(allocator, event_split.head), detail, null, null, line_num);
            commands.items[commands.items.len - 1].task_name = event_name;
        } else if (std.mem.startsWith(u8, trimmed, "submit ")) {
            try appendSpecCommand(&commands, allocator, .submit, try parseLocator(allocator, trimmed["submit ".len..]), null, null, null, line_num);
        } else if (std.mem.eql(u8, trimmed, "mark_metrics")) {
            try appendSpecCommand(&commands, allocator, .mark_metrics, emptyLocator(), null, null, null, line_num);
        } else if (std.mem.startsWith(u8, trimmed, "fill ")) {
            const split = try splitTrailingQuoted(trimmed[5..]);
            const value_copy = try dupeUnescapedQuoted(allocator, split.quoted);
            try appendSpecCommand(&commands, allocator, .fill, try parseLocator(allocator, split.head), value_copy, null, null, line_num);
        } else if (std.mem.startsWith(u8, trimmed, "check ")) {
            try appendSpecCommand(&commands, allocator, .check, try parseLocator(allocator, trimmed[6..]), null, null, null, line_num);
        } else if (std.mem.startsWith(u8, trimmed, "uncheck ")) {
            try appendSpecCommand(&commands, allocator, .uncheck, try parseLocator(allocator, trimmed[8..]), null, null, null, line_num);
        } else if (std.mem.startsWith(u8, trimmed, "expect_text ")) {
            const split = try splitTrailingQuoted(trimmed[12..]);
            const text_copy = try dupeUnescapedQuoted(allocator, split.quoted);
            try appendSpecCommand(&commands, allocator, .expect_text, try parseLocator(allocator, split.head), text_copy, null, null, line_num);
        } else if (std.mem.startsWith(u8, trimmed, "expect_visible ")) {
            try appendSpecCommand(&commands, allocator, .expect_visible, try parseLocator(allocator, trimmed[15..]), null, null, null, line_num);
        } else if (std.mem.startsWith(u8, trimmed, "expect_absent ")) {
            try appendSpecCommand(&commands, allocator, .expect_absent, try parseLocator(allocator, trimmed[14..]), null, null, null, line_num);
        } else if (std.mem.startsWith(u8, trimmed, "expect_value ")) {
            const split = try splitTrailingQuoted(trimmed[13..]);
            const value_copy = try dupeUnescapedQuoted(allocator, split.quoted);
            try appendSpecCommand(&commands, allocator, .expect_value, try parseLocator(allocator, split.head), value_copy, null, null, line_num);
        } else if (std.mem.startsWith(u8, trimmed, "expect_attr ")) {
            const value_split = try splitTrailingQuoted(trimmed["expect_attr ".len..]);
            const name_split = try splitTrailingToken(value_split.head);
            const attr_name = allocator.dupe(u8, name_split.token) catch return ParseError.OutOfMemory;
            errdefer allocator.free(attr_name);
            const value_copy = try dupeUnescapedQuoted(allocator, value_split.quoted);
            errdefer allocator.free(value_copy);
            try appendSpecCommand(&commands, allocator, .expect_attr, try parseLocator(allocator, name_split.head), value_copy, null, null, line_num);
            commands.items[commands.items.len - 1].expected_attr = attr_name;
        } else if (std.mem.startsWith(u8, trimmed, "expect_no_attr ")) {
            const name_split = try splitTrailingToken(trimmed["expect_no_attr ".len..]);
            const attr_name = allocator.dupe(u8, name_split.token) catch return ParseError.OutOfMemory;
            errdefer allocator.free(attr_name);
            try appendSpecCommand(&commands, allocator, .expect_no_attr, try parseLocator(allocator, name_split.head), null, null, null, line_num);
            commands.items[commands.items.len - 1].expected_attr = attr_name;
        } else if (std.mem.startsWith(u8, trimmed, "expect_checked ")) {
            const split = try splitTrailingToken(trimmed[15..]);
            try appendSpecCommand(&commands, allocator, .expect_checked, try parseLocator(allocator, split.head), null, null, try parseBoolToken(split.token), line_num);
        } else if (std.mem.startsWith(u8, trimmed, "expect_disabled ")) {
            const split = try splitTrailingToken(trimmed[16..]);
            try appendSpecCommand(&commands, allocator, .expect_disabled, try parseLocator(allocator, split.head), null, null, try parseBoolToken(split.token), line_num);
        } else if (std.mem.startsWith(u8, trimmed, "expect_updates ")) {
            const split = try splitTrailingToken(trimmed[15..]);
            const expected_count = std.fmt.parseInt(u64, split.token, 10) catch return ParseError.InvalidFormat;
            try appendSpecCommand(&commands, allocator, .expect_updates, try parseLocator(allocator, split.head), null, expected_count, null, line_num);
        } else if (std.mem.startsWith(u8, trimmed, "resolve_task ")) {
            const split = try splitTwoQuoted(trimmed["resolve_task ".len..]);
            const task_name = try dupePlain(allocator, split.first);
            errdefer allocator.free(task_name);
            const payload = try dupeUnescapedQuoted(allocator, split.second);
            errdefer allocator.free(payload);
            try appendSpecCommand(&commands, allocator, .resolve_task, emptyLocator(), payload, null, null, line_num);
            commands.items[commands.items.len - 1].task_name = task_name;
        } else if (std.mem.startsWith(u8, trimmed, "resolve_stale_task ")) {
            const split = try splitTwoQuoted(trimmed["resolve_stale_task ".len..]);
            const task_name = try dupePlain(allocator, split.first);
            errdefer allocator.free(task_name);
            const payload = try dupeUnescapedQuoted(allocator, split.second);
            errdefer allocator.free(payload);
            try appendSpecCommand(&commands, allocator, .resolve_stale_task, emptyLocator(), payload, null, null, line_num);
            commands.items[commands.items.len - 1].task_name = task_name;
        } else if (std.mem.startsWith(u8, trimmed, "reject_task ")) {
            const split = try splitTwoQuoted(trimmed["reject_task ".len..]);
            const task_name = try dupePlain(allocator, split.first);
            errdefer allocator.free(task_name);
            const payload = try dupeUnescapedQuoted(allocator, split.second);
            errdefer allocator.free(payload);
            try appendSpecCommand(&commands, allocator, .reject_task, emptyLocator(), payload, null, null, line_num);
            commands.items[commands.items.len - 1].task_name = task_name;
        } else if (std.mem.startsWith(u8, trimmed, "tick_interval ")) {
            const period_text = std.mem.trim(u8, trimmed["tick_interval ".len..], " \t");
            const period_ms = std.fmt.parseInt(u64, period_text, 10) catch return ParseError.InvalidFormat;
            try appendSpecCommand(&commands, allocator, .tick_interval, emptyLocator(), null, null, null, line_num);
            commands.items[commands.items.len - 1].interval_ms = period_ms;
        } else if (std.mem.startsWith(u8, trimmed, "tick_interval_if_active ")) {
            const period_text = std.mem.trim(u8, trimmed["tick_interval_if_active ".len..], " \t");
            const period_ms = std.fmt.parseInt(u64, period_text, 10) catch return ParseError.InvalidFormat;
            try appendSpecCommand(&commands, allocator, .tick_interval_if_active, emptyLocator(), null, null, null, line_num);
            commands.items[commands.items.len - 1].interval_ms = period_ms;
        } else if (std.mem.startsWith(u8, trimmed, "expect_cleanup ")) {
            const split = try splitTrailingToken(trimmed["expect_cleanup ".len..]);
            const name_value = try parseSingleQuoted(split.head);
            const task_name = allocator.dupe(u8, name_value) catch return ParseError.OutOfMemory;
            errdefer allocator.free(task_name);
            const expected_count = std.fmt.parseInt(u64, split.token, 10) catch return ParseError.InvalidFormat;
            try appendSpecCommand(&commands, allocator, .expect_cleanup, emptyLocator(), null, expected_count, null, line_num);
            commands.items[commands.items.len - 1].task_name = task_name;
        } else if (std.mem.startsWith(u8, trimmed, "expect_pending_task ")) {
            const split = try splitTrailingToken(trimmed["expect_pending_task ".len..]);
            const name_value = try parseSingleQuoted(split.head);
            const task_name = allocator.dupe(u8, name_value) catch return ParseError.OutOfMemory;
            errdefer allocator.free(task_name);
            const expected_count = std.fmt.parseInt(u64, split.token, 10) catch return ParseError.InvalidFormat;
            try appendSpecCommand(&commands, allocator, .expect_pending_task, emptyLocator(), null, expected_count, null, line_num);
            commands.items[commands.items.len - 1].task_name = task_name;
        } else if (std.mem.startsWith(u8, trimmed, "expect_canceled_task ")) {
            const split = try splitTrailingToken(trimmed["expect_canceled_task ".len..]);
            const name_value = try parseSingleQuoted(split.head);
            const task_name = allocator.dupe(u8, name_value) catch return ParseError.OutOfMemory;
            errdefer allocator.free(task_name);
            const expected_count = std.fmt.parseInt(u64, split.token, 10) catch return ParseError.InvalidFormat;
            try appendSpecCommand(&commands, allocator, .expect_canceled_task, emptyLocator(), null, expected_count, null, line_num);
            commands.items[commands.items.len - 1].task_name = task_name;
        } else if (std.mem.startsWith(u8, trimmed, "expect_interval ")) {
            const split = try splitTrailingToken(trimmed["expect_interval ".len..]);
            const period_ms = std.fmt.parseInt(u64, split.head, 10) catch return ParseError.InvalidFormat;
            const expected_count = std.fmt.parseInt(u64, split.token, 10) catch return ParseError.InvalidFormat;
            try appendSpecCommand(&commands, allocator, .expect_interval, emptyLocator(), null, expected_count, null, line_num);
            commands.items[commands.items.len - 1].interval_ms = period_ms;
        } else if (std.mem.startsWith(u8, trimmed, "set_initial_location ")) {
            const location = try parseSingleQuoted(trimmed["set_initial_location ".len..]);
            const location_copy = allocator.dupe(u8, location) catch return ParseError.OutOfMemory;
            try appendSpecCommand(&commands, allocator, .set_initial_location, emptyLocator(), location_copy, null, null, line_num);
        } else if (std.mem.startsWith(u8, trimmed, "set_initial_visibility ")) {
            const visibility_text = std.mem.trim(u8, trimmed["set_initial_visibility ".len..], " \t");
            const visibility_copy = allocator.dupe(u8, visibility_text) catch return ParseError.OutOfMemory;
            try appendSpecCommand(&commands, allocator, .set_initial_visibility, emptyLocator(), visibility_copy, null, null, line_num);
        } else if (std.mem.startsWith(u8, trimmed, "set_initial_online ")) {
            const online_text = std.mem.trim(u8, trimmed["set_initial_online ".len..], " \t");
            const online_copy = allocator.dupe(u8, online_text) catch return ParseError.OutOfMemory;
            try appendSpecCommand(&commands, allocator, .set_initial_online, emptyLocator(), online_copy, null, null, line_num);
        } else if (std.mem.startsWith(u8, trimmed, "seed_local_storage ")) {
            const split = try splitTwoQuoted(trimmed["seed_local_storage ".len..]);
            const key = try dupePlain(allocator, split.first);
            errdefer allocator.free(key);
            const value = try dupePlain(allocator, split.second);
            errdefer allocator.free(value);
            try appendSpecCommand(&commands, allocator, .seed_local_storage, emptyLocator(), value, null, null, line_num);
            commands.items[commands.items.len - 1].task_name = key;
        } else if (std.mem.startsWith(u8, trimmed, "seed_session_storage ")) {
            const split = try splitTwoQuoted(trimmed["seed_session_storage ".len..]);
            const key = try dupePlain(allocator, split.first);
            errdefer allocator.free(key);
            const value = try dupePlain(allocator, split.second);
            errdefer allocator.free(value);
            try appendSpecCommand(&commands, allocator, .seed_session_storage, emptyLocator(), value, null, null, line_num);
            commands.items[commands.items.len - 1].task_name = key;
        } else if (std.mem.startsWith(u8, trimmed, "navigate ")) {
            const location = try parseSingleQuoted(trimmed["navigate ".len..]);
            const location_copy = allocator.dupe(u8, location) catch return ParseError.OutOfMemory;
            try appendSpecCommand(&commands, allocator, .navigate, emptyLocator(), location_copy, null, null, line_num);
        } else if (std.mem.startsWith(u8, trimmed, "set_visibility ")) {
            const visibility_text = std.mem.trim(u8, trimmed["set_visibility ".len..], " \t");
            const visibility_copy = allocator.dupe(u8, visibility_text) catch return ParseError.OutOfMemory;
            try appendSpecCommand(&commands, allocator, .set_visibility, emptyLocator(), visibility_copy, null, null, line_num);
        } else if (std.mem.startsWith(u8, trimmed, "set_online ")) {
            const online_text = std.mem.trim(u8, trimmed["set_online ".len..], " \t");
            const online_copy = allocator.dupe(u8, online_text) catch return ParseError.OutOfMemory;
            try appendSpecCommand(&commands, allocator, .set_online, emptyLocator(), online_copy, null, null, line_num);
        } else if (std.mem.eql(u8, trimmed, "history_back")) {
            try appendSpecCommand(&commands, allocator, .history_back, emptyLocator(), null, null, null, line_num);
        } else if (std.mem.eql(u8, trimmed, "history_forward")) {
            try appendSpecCommand(&commands, allocator, .history_forward, emptyLocator(), null, null, null, line_num);
        } else if (std.mem.startsWith(u8, trimmed, "expect_current_location ")) {
            const location = try parseSingleQuoted(trimmed["expect_current_location ".len..]);
            const location_copy = allocator.dupe(u8, location) catch return ParseError.OutOfMemory;
            try appendSpecCommand(&commands, allocator, .expect_current_location, emptyLocator(), location_copy, null, null, line_num);
        } else if (std.mem.startsWith(u8, trimmed, "assert_current_location ")) {
            const location = try parseSingleQuoted(trimmed["assert_current_location ".len..]);
            const location_copy = allocator.dupe(u8, location) catch return ParseError.OutOfMemory;
            try appendSpecCommand(&commands, allocator, .assert_current_location, emptyLocator(), location_copy, null, null, line_num);
        } else if (std.mem.startsWith(u8, trimmed, "expect_document_title ")) {
            const title = try parseSingleQuoted(trimmed["expect_document_title ".len..]);
            const title_copy = allocator.dupe(u8, title) catch return ParseError.OutOfMemory;
            try appendSpecCommand(&commands, allocator, .expect_document_title, emptyLocator(), title_copy, null, null, line_num);
        } else if (std.mem.startsWith(u8, trimmed, "expect_local_storage ")) {
            const split = try splitTwoQuoted(trimmed["expect_local_storage ".len..]);
            const key = try dupePlain(allocator, split.first);
            errdefer allocator.free(key);
            const value = try dupePlain(allocator, split.second);
            errdefer allocator.free(value);
            try appendSpecCommand(&commands, allocator, .expect_local_storage, emptyLocator(), value, null, null, line_num);
            commands.items[commands.items.len - 1].task_name = key;
        } else if (std.mem.startsWith(u8, trimmed, "expect_session_storage ")) {
            const split = try splitTwoQuoted(trimmed["expect_session_storage ".len..]);
            const key = try dupePlain(allocator, split.first);
            errdefer allocator.free(key);
            const value = try dupePlain(allocator, split.second);
            errdefer allocator.free(value);
            try appendSpecCommand(&commands, allocator, .expect_session_storage, emptyLocator(), value, null, null, line_num);
            commands.items[commands.items.len - 1].task_name = key;
        } else if (std.mem.startsWith(u8, trimmed, "expect_no_local_storage ")) {
            const key_value = try parseSingleQuoted(trimmed["expect_no_local_storage ".len..]);
            const key = try dupePlain(allocator, key_value);
            errdefer allocator.free(key);
            try appendSpecCommand(&commands, allocator, .expect_no_local_storage, emptyLocator(), null, null, null, line_num);
            commands.items[commands.items.len - 1].task_name = key;
        } else if (std.mem.startsWith(u8, trimmed, "expect_no_session_storage ")) {
            const key_value = try parseSingleQuoted(trimmed["expect_no_session_storage ".len..]);
            const key = try dupePlain(allocator, key_value);
            errdefer allocator.free(key);
            try appendSpecCommand(&commands, allocator, .expect_no_session_storage, emptyLocator(), null, null, null, line_num);
            commands.items[commands.items.len - 1].task_name = key;
        } else if (std.mem.startsWith(u8, trimmed, "expect_metric_delta_at_most ")) {
            const split = try splitTrailingToken(trimmed["expect_metric_delta_at_most ".len..]);
            const metric_name = allocator.dupe(u8, split.head) catch return ParseError.OutOfMemory;
            const expected_delta = std.fmt.parseInt(i64, split.token, 10) catch return ParseError.InvalidFormat;
            try appendSpecCommand(&commands, allocator, .expect_metric_delta_at_most, emptyLocator(), metric_name, null, null, line_num);
            commands.items[commands.items.len - 1].expected_metric_delta = expected_delta;
        } else if (std.mem.startsWith(u8, trimmed, "expect_metric_delta ")) {
            const split = try splitTrailingToken(trimmed[20..]);
            const metric_name = allocator.dupe(u8, split.head) catch return ParseError.OutOfMemory;
            const expected_delta = std.fmt.parseInt(i64, split.token, 10) catch return ParseError.InvalidFormat;
            try appendSpecCommand(&commands, allocator, .expect_metric_delta, emptyLocator(), metric_name, null, null, line_num);
            commands.items[commands.items.len - 1].expected_metric_delta = expected_delta;
        } else {
            return ParseError.InvalidFormat;
        }
    }

    return commands.toOwnedSlice(allocator) catch ParseError.OutOfMemory;
}

/// Provides the `parseSExprTestSpec` operation.
pub fn parseSExprTestSpec(allocator: std.mem.Allocator, content: []const u8) ParseError!ParsedTestSpec {
    var reader = sexpr.Reader.init(allocator, content);
    const root = reader.readOne() catch |err| switch (err) {
        error.InvalidSyntax => return ParseError.InvalidFormat,
        error.OutOfMemory => return ParseError.OutOfMemory,
    };
    defer root.deinit(allocator);

    const root_items = exprList(root) orelse return ParseError.InvalidFormat;
    if (root_items.len < 3 or !exprSymbolEql(root_items[0], "test")) return ParseError.InvalidFormat;
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

fn appendDecodedForm(
    allocator: std.mem.Allocator,
    commands: *std.ArrayListUnmanaged(SpecCommand),
    form: sexpr.Expr,
    is_setup: bool,
) ParseError!void {
    const items = exprList(form) orelse return ParseError.InvalidFormat;
    if (items.len == 0) return ParseError.InvalidFormat;
    const head = exprSymbol(items[0]) orelse return ParseError.InvalidFormat;

    var line: std.Io.Writer.Allocating = .init(allocator);
    defer line.deinit();
    const writer = &line.writer;

    if (is_setup) {
        const legacy_head = if (std.mem.eql(u8, head, "initial-location"))
            "set_initial_location"
        else if (std.mem.eql(u8, head, "initial-visibility"))
            "set_initial_visibility"
        else if (std.mem.eql(u8, head, "initial-online"))
            "set_initial_online"
        else if (std.mem.eql(u8, head, "local-storage"))
            "seed_local_storage"
        else if (std.mem.eql(u8, head, "session-storage"))
            "seed_session_storage"
        else
            return ParseError.InvalidFormat;
        writer.writeAll(legacy_head) catch return ParseError.OutOfMemory;
    } else {
        if (std.mem.startsWith(u8, head, "initial-") or
            std.mem.eql(u8, head, "local-storage") or
            std.mem.eql(u8, head, "session-storage")) return ParseError.InvalidFormat;
        try writeLegacyHead(writer, head);
    }

    for (items[1..]) |arg| {
        writer.writeByte(' ') catch return ParseError.OutOfMemory;
        try writeLegacyArg(writer, arg);
    }

    const parsed = try parseTestSpec(allocator, line.written());
    if (parsed.len != 1) {
        freeSpecCommands(allocator, parsed);
        return ParseError.InvalidFormat;
    }
    var command = parsed[0];
    command.line_num = form.span.line;
    allocator.free(parsed);
    commands.append(allocator, command) catch {
        freeOneCommand(allocator, command);
        return ParseError.OutOfMemory;
    };
}

fn writeLegacyHead(writer: anytype, head: []const u8) ParseError!void {
    if (std.mem.eql(u8, head, "assert-current-location")) {
        writer.writeAll("expect_current_location") catch return ParseError.OutOfMemory;
        return;
    }
    for (head) |byte| {
        writer.writeByte(if (byte == '-') '_' else byte) catch return ParseError.OutOfMemory;
    }
}

fn writeLegacyArg(writer: anytype, expr: sexpr.Expr) ParseError!void {
    switch (expr.value) {
        .list => try writeLegacyLocator(writer, expr),
        .atom => |atom| switch (atom) {
            .symbol => |value| writer.writeAll(value) catch return ParseError.OutOfMemory,
            .string => |value| try writeLegacyQuoted(writer, value),
            .integer => |value| writer.print("{d}", .{value}) catch return ParseError.OutOfMemory,
            .boolean => |value| writer.writeAll(if (value) "true" else "false") catch return ParseError.OutOfMemory,
        },
    }
}

fn writeLegacyLocator(writer: anytype, expr: sexpr.Expr) ParseError!void {
    const items = exprList(expr) orelse return ParseError.InvalidFormat;
    if (items.len == 0) return ParseError.InvalidFormat;
    const kind = exprSymbol(items[0]) orelse return ParseError.InvalidFormat;
    if (std.mem.eql(u8, kind, "role")) {
        if (items.len != 4 or !exprSymbolEql(items[2], ":name")) return ParseError.InvalidFormat;
        const role = exprSymbol(items[1]) orelse exprString(items[1]) orelse return ParseError.InvalidFormat;
        const name = exprString(items[3]) orelse return ParseError.InvalidFormat;
        writer.writeAll("role:") catch return ParseError.OutOfMemory;
        writer.writeAll(role) catch return ParseError.OutOfMemory;
        writer.writeAll(" name:") catch return ParseError.OutOfMemory;
        try writeLegacyQuoted(writer, name);
        return;
    }
    if (items.len != 2) return ParseError.InvalidFormat;
    const value = exprString(items[1]) orelse return ParseError.InvalidFormat;
    if (std.mem.eql(u8, kind, "label")) {
        writer.writeAll("label:") catch return ParseError.OutOfMemory;
    } else if (std.mem.eql(u8, kind, "text")) {
        writer.writeAll("text:") catch return ParseError.OutOfMemory;
    } else if (std.mem.eql(u8, kind, "test-id")) {
        writer.writeAll("test_id:") catch return ParseError.OutOfMemory;
    } else {
        return ParseError.InvalidFormat;
    }
    try writeLegacyQuoted(writer, value);
}

fn writeLegacyQuoted(writer: anytype, value: []const u8) ParseError!void {
    writer.writeByte('"') catch return ParseError.OutOfMemory;
    for (value) |byte| {
        switch (byte) {
            '\n' => writer.writeAll("\\n") catch return ParseError.OutOfMemory,
            '\r' => writer.writeAll("\\r") catch return ParseError.OutOfMemory,
            '\t' => writer.writeAll("\\t") catch return ParseError.OutOfMemory,
            '\\' => writer.writeAll("\\\\") catch return ParseError.OutOfMemory,
            '"' => writer.writeAll("\\\"") catch return ParseError.OutOfMemory,
            else => writer.writeByte(byte) catch return ParseError.OutOfMemory,
        }
    }
    writer.writeByte('"') catch return ParseError.OutOfMemory;
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

test "all checked-in S-expression specs parse" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const examples = try std.Io.Dir.cwd().openDir(io, "examples", .{ .iterate = true });
    defer examples.close(io);
    var walker = try examples.walk(std.testing.allocator);
    defer walker.deinit();

    var count: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".scm")) continue;
        const path = try std.fs.path.join(std.testing.allocator, &.{ "examples", entry.path });
        defer std.testing.allocator.free(path);
        var parsed = parseTestSpecFile(std.testing.allocator, path) catch |err| {
            std.debug.print("failed to parse {s}: {s}\n", .{ path, @errorName(err) });
            return err;
        };
        parsed.deinit(std.testing.allocator);
        count += 1;
    }
    try std.testing.expect(count > 100);
}

test "spec parser parses actions and assertions" {
    const content =
        \\click role:button name:"Save"
        \\real_click role:button name:"Save"
        \\fill label:"Email" "a@example.com"
        \\focus label:"Email"
        \\blur label:"Email"
        \\change label:"Email" "changed@example.com"
        \\select_option label:"Plan" "growth"
        \\composition_start label:"Email"
        \\composition_end label:"Email"
        \\custom_event test_id:"chart" "chart-select" "now | 1,200 rpm"
        \\expect_attr test_id:"status" data-state "ready"
        \\expect_no_attr label:"Email" aria-invalid
        \\tick_interval 250
        \\tick_interval_if_active 250
        \\expect_interval 250 1
        \\set_initial_location "/services/api?tab=logs#tail"
        \\set_initial_visibility hidden
        \\set_initial_online offline
        \\seed_local_storage "checkout:draft" "saved"
        \\seed_session_storage "checkout:flash" "shown"
        \\navigate "/services/web?tab=deploys#events"
        \\set_visibility visible
        \\set_online online
        \\history_back
        \\history_forward
        \\expect_current_location "/services/web?tab=deploys#events"
        \\assert_current_location "/services/web?tab=deploys#events"
        \\expect_document_title "Service Ops Center"
        \\expect_local_storage "checkout:draft" "saved"
        \\expect_session_storage "checkout:flash" "shown"
        \\expect_no_local_storage "checkout:missing"
        \\expect_no_session_storage "checkout:missing"
    ;
    const commands = try parseTestSpec(std.testing.allocator, content);
    defer freeSpecCommands(std.testing.allocator, commands);

    try std.testing.expectEqual(@as(usize, 32), commands.len);
    try std.testing.expectEqual(SpecCommandType.click, commands[0].cmd_type);
    try std.testing.expectEqual(LocatorKind.role_name, commands[0].locator.kind);
    try std.testing.expectEqualStrings("button", commands[0].locator.role.?);
    try std.testing.expectEqualStrings("Save", commands[0].locator.name.?);
    try std.testing.expectEqual(SpecCommandType.real_click, commands[1].cmd_type);
    try std.testing.expectEqualStrings("a@example.com", commands[2].expected_text.?);
    try std.testing.expectEqual(SpecCommandType.focus, commands[3].cmd_type);
    try std.testing.expectEqual(SpecCommandType.blur, commands[4].cmd_type);
    try std.testing.expectEqual(SpecCommandType.change, commands[5].cmd_type);
    try std.testing.expectEqualStrings("changed@example.com", commands[5].expected_text.?);
    try std.testing.expectEqual(SpecCommandType.select_option, commands[6].cmd_type);
    try std.testing.expectEqualStrings("growth", commands[6].expected_text.?);
    try std.testing.expectEqual(SpecCommandType.composition_start, commands[7].cmd_type);
    try std.testing.expectEqual(SpecCommandType.composition_end, commands[8].cmd_type);
    try std.testing.expectEqual(SpecCommandType.custom_event, commands[9].cmd_type);
    try std.testing.expectEqual(LocatorKind.test_id, commands[9].locator.kind);
    try std.testing.expectEqualStrings("chart", commands[9].locator.test_id.?);
    try std.testing.expectEqualStrings("chart-select", commands[9].task_name.?);
    try std.testing.expectEqualStrings("now | 1,200 rpm", commands[9].expected_text.?);
    try std.testing.expectEqualStrings("data-state", commands[10].expected_attr.?);
    try std.testing.expectEqualStrings("ready", commands[10].expected_text.?);
    try std.testing.expectEqualStrings("aria-invalid", commands[11].expected_attr.?);
    try std.testing.expectEqual(@as(?u64, 250), commands[12].interval_ms);
    try std.testing.expectEqual(SpecCommandType.tick_interval_if_active, commands[13].cmd_type);
    try std.testing.expectEqual(@as(?u64, 250), commands[13].interval_ms);
    try std.testing.expectEqual(@as(?u64, 1), commands[14].expected_count);
    try std.testing.expectEqual(SpecCommandType.set_initial_location, commands[15].cmd_type);
    try std.testing.expectEqualStrings("/services/api?tab=logs#tail", commands[15].expected_text.?);
    try std.testing.expectEqual(SpecCommandType.set_initial_visibility, commands[16].cmd_type);
    try std.testing.expectEqualStrings("hidden", commands[16].expected_text.?);
    try std.testing.expectEqual(SpecCommandType.set_initial_online, commands[17].cmd_type);
    try std.testing.expectEqualStrings("offline", commands[17].expected_text.?);
    try std.testing.expectEqual(SpecCommandType.seed_local_storage, commands[18].cmd_type);
    try std.testing.expectEqualStrings("checkout:draft", commands[18].task_name.?);
    try std.testing.expectEqualStrings("saved", commands[18].expected_text.?);
    try std.testing.expectEqual(SpecCommandType.seed_session_storage, commands[19].cmd_type);
    try std.testing.expectEqualStrings("checkout:flash", commands[19].task_name.?);
    try std.testing.expectEqualStrings("shown", commands[19].expected_text.?);
    try std.testing.expectEqual(SpecCommandType.navigate, commands[20].cmd_type);
    try std.testing.expectEqualStrings("/services/web?tab=deploys#events", commands[20].expected_text.?);
    try std.testing.expectEqual(SpecCommandType.set_visibility, commands[21].cmd_type);
    try std.testing.expectEqualStrings("visible", commands[21].expected_text.?);
    try std.testing.expectEqual(SpecCommandType.set_online, commands[22].cmd_type);
    try std.testing.expectEqualStrings("online", commands[22].expected_text.?);
    try std.testing.expectEqual(SpecCommandType.history_back, commands[23].cmd_type);
    try std.testing.expectEqual(SpecCommandType.history_forward, commands[24].cmd_type);
    try std.testing.expectEqual(SpecCommandType.expect_current_location, commands[25].cmd_type);
    try std.testing.expectEqualStrings("/services/web?tab=deploys#events", commands[25].expected_text.?);
    try std.testing.expectEqual(SpecCommandType.assert_current_location, commands[26].cmd_type);
    try std.testing.expectEqualStrings("/services/web?tab=deploys#events", commands[26].expected_text.?);
    try std.testing.expectEqual(SpecCommandType.expect_document_title, commands[27].cmd_type);
    try std.testing.expectEqualStrings("Service Ops Center", commands[27].expected_text.?);
    try std.testing.expectEqual(SpecCommandType.expect_local_storage, commands[28].cmd_type);
    try std.testing.expectEqualStrings("checkout:draft", commands[28].task_name.?);
    try std.testing.expectEqualStrings("saved", commands[28].expected_text.?);
    try std.testing.expectEqual(SpecCommandType.expect_session_storage, commands[29].cmd_type);
    try std.testing.expectEqualStrings("checkout:flash", commands[29].task_name.?);
    try std.testing.expectEqualStrings("shown", commands[29].expected_text.?);
    try std.testing.expectEqual(SpecCommandType.expect_no_local_storage, commands[30].cmd_type);
    try std.testing.expectEqualStrings("checkout:missing", commands[30].task_name.?);
    try std.testing.expectEqual(SpecCommandType.expect_no_session_storage, commands[31].cmd_type);
    try std.testing.expectEqualStrings("checkout:missing", commands[31].task_name.?);
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
    const content =
        \\# parser fixtures should keep native specs honest
        \\key_down role:textbox name:"Search" "Enter" true
        \\expect_checked label:"Enabled" false
        \\expect_disabled test_id:"submit" true
        \\resolve_task "fetch user" "hello\n\"world\"\\"
        \\resolve_stale_task "fetch user" "late"
        \\reject_task "fetch user" "bad\trequest"
        \\expect_cleanup "fetch user" 2
        \\expect_pending_task "fetch user" 1
        \\expect_canceled_task "fetch user" 1
        \\mark_metrics
        \\expect_metric_delta closure_releases -1
        \\expect_metric_delta_at_most host_retained_alloc_delta 0
    ;
    const commands = try parseTestSpec(std.testing.allocator, content);
    defer freeSpecCommands(std.testing.allocator, commands);

    try std.testing.expectEqual(@as(usize, 12), commands.len);

    try std.testing.expectEqual(SpecCommandType.key_down, commands[0].cmd_type);
    try std.testing.expectEqual(@as(usize, 2), commands[0].line_num);
    try std.testing.expectEqual(LocatorKind.role_name, commands[0].locator.kind);
    try std.testing.expectEqualStrings("textbox", commands[0].locator.role.?);
    try std.testing.expectEqualStrings("Search", commands[0].locator.name.?);
    try std.testing.expectEqualStrings("Enter", commands[0].expected_text.?);
    try std.testing.expectEqual(@as(?bool, true), commands[0].expected_bool);

    try std.testing.expectEqual(SpecCommandType.expect_checked, commands[1].cmd_type);
    try std.testing.expectEqual(LocatorKind.label, commands[1].locator.kind);
    try std.testing.expectEqualStrings("Enabled", commands[1].locator.label.?);
    try std.testing.expectEqual(@as(?bool, false), commands[1].expected_bool);

    try std.testing.expectEqual(SpecCommandType.expect_disabled, commands[2].cmd_type);
    try std.testing.expectEqual(LocatorKind.test_id, commands[2].locator.kind);
    try std.testing.expectEqualStrings("submit", commands[2].locator.test_id.?);
    try std.testing.expectEqual(@as(?bool, true), commands[2].expected_bool);

    try std.testing.expectEqual(SpecCommandType.resolve_task, commands[3].cmd_type);
    try std.testing.expectEqualStrings("fetch user", commands[3].task_name.?);
    try std.testing.expectEqualStrings("hello\n\"world\"\\", commands[3].expected_text.?);

    try std.testing.expectEqual(SpecCommandType.resolve_stale_task, commands[4].cmd_type);
    try std.testing.expectEqualStrings("fetch user", commands[4].task_name.?);
    try std.testing.expectEqualStrings("late", commands[4].expected_text.?);

    try std.testing.expectEqual(SpecCommandType.reject_task, commands[5].cmd_type);
    try std.testing.expectEqualStrings("fetch user", commands[5].task_name.?);
    try std.testing.expectEqualStrings("bad\trequest", commands[5].expected_text.?);

    try std.testing.expectEqual(SpecCommandType.expect_cleanup, commands[6].cmd_type);
    try std.testing.expectEqualStrings("fetch user", commands[6].task_name.?);
    try std.testing.expectEqual(@as(?u64, 2), commands[6].expected_count);

    try std.testing.expectEqual(SpecCommandType.expect_pending_task, commands[7].cmd_type);
    try std.testing.expectEqualStrings("fetch user", commands[7].task_name.?);
    try std.testing.expectEqual(@as(?u64, 1), commands[7].expected_count);

    try std.testing.expectEqual(SpecCommandType.expect_canceled_task, commands[8].cmd_type);
    try std.testing.expectEqualStrings("fetch user", commands[8].task_name.?);
    try std.testing.expectEqual(@as(?u64, 1), commands[8].expected_count);

    try std.testing.expectEqual(SpecCommandType.mark_metrics, commands[9].cmd_type);
    try std.testing.expectEqual(SpecCommandType.expect_metric_delta, commands[10].cmd_type);
    try std.testing.expectEqualStrings("closure_releases", commands[10].expected_text.?);
    try std.testing.expectEqual(@as(?i64, -1), commands[10].expected_metric_delta);
    try std.testing.expectEqual(SpecCommandType.expect_metric_delta_at_most, commands[11].cmd_type);
    try std.testing.expectEqualStrings("host_retained_alloc_delta", commands[11].expected_text.?);
    try std.testing.expectEqual(@as(?i64, 0), commands[11].expected_metric_delta);
}

test "spec parser parses pointer form and visibility commands" {
    const content =
        \\pointer_down test_id:"drag-handle"
        \\pointer_up test_id:"drag-handle"
        \\pointer_enter text:"Drop zone"
        \\pointer_leave text:"Drop zone"
        \\submit role:button name:"Save"
        \\check label:"Enabled"
        \\uncheck label:"Enabled"
        \\expect_text test_id:"status" "Ready"
        \\expect_visible role:button name:"Save"
        \\expect_absent text:"Loading"
        \\expect_value label:"Email" "a@example.com"
        \\expect_updates test_id:"status" 3
    ;
    const commands = try parseTestSpec(std.testing.allocator, content);
    defer freeSpecCommands(std.testing.allocator, commands);

    try std.testing.expectEqual(@as(usize, 12), commands.len);
    try std.testing.expectEqual(SpecCommandType.pointer_down, commands[0].cmd_type);
    try std.testing.expectEqualStrings("drag-handle", commands[0].locator.test_id.?);
    try std.testing.expectEqual(SpecCommandType.pointer_up, commands[1].cmd_type);
    try std.testing.expectEqualStrings("drag-handle", commands[1].locator.test_id.?);
    try std.testing.expectEqual(SpecCommandType.pointer_enter, commands[2].cmd_type);
    try std.testing.expectEqualStrings("Drop zone", commands[2].locator.text.?);
    try std.testing.expectEqual(SpecCommandType.pointer_leave, commands[3].cmd_type);
    try std.testing.expectEqualStrings("Drop zone", commands[3].locator.text.?);
    try std.testing.expectEqual(SpecCommandType.submit, commands[4].cmd_type);
    try std.testing.expectEqualStrings("button", commands[4].locator.role.?);
    try std.testing.expectEqualStrings("Save", commands[4].locator.name.?);
    try std.testing.expectEqual(SpecCommandType.check, commands[5].cmd_type);
    try std.testing.expectEqualStrings("Enabled", commands[5].locator.label.?);
    try std.testing.expectEqual(SpecCommandType.uncheck, commands[6].cmd_type);
    try std.testing.expectEqualStrings("Enabled", commands[6].locator.label.?);
    try std.testing.expectEqual(SpecCommandType.expect_text, commands[7].cmd_type);
    try std.testing.expectEqualStrings("status", commands[7].locator.test_id.?);
    try std.testing.expectEqualStrings("Ready", commands[7].expected_text.?);
    try std.testing.expectEqual(SpecCommandType.expect_visible, commands[8].cmd_type);
    try std.testing.expectEqualStrings("button", commands[8].locator.role.?);
    try std.testing.expectEqualStrings("Save", commands[8].locator.name.?);
    try std.testing.expectEqual(SpecCommandType.expect_absent, commands[9].cmd_type);
    try std.testing.expectEqualStrings("Loading", commands[9].locator.text.?);
    try std.testing.expectEqual(SpecCommandType.expect_value, commands[10].cmd_type);
    try std.testing.expectEqualStrings("Email", commands[10].locator.label.?);
    try std.testing.expectEqualStrings("a@example.com", commands[10].expected_text.?);
    try std.testing.expectEqual(SpecCommandType.expect_updates, commands[11].cmd_type);
    try std.testing.expectEqualStrings("status", commands[11].locator.test_id.?);
    try std.testing.expectEqual(@as(?u64, 3), commands[11].expected_count);
}

test "spec parser rejects malformed commands" {
    try std.testing.expectError(ParseError.InvalidFormat, parseBoolToken("maybe"));
    try std.testing.expectError(ParseError.InvalidFormat, locationSnapshotFromSpecText("services/api"));
    try std.testing.expectError(ParseError.InvalidFormat, visibilitySnapshotFromSpecText("maybe"));
    try std.testing.expectError(ParseError.InvalidFormat, onlineSnapshotFromSpecText("maybe"));
    try std.testing.expectError(ParseError.InvalidFormat, parseTestSpec(std.testing.allocator, "click missing_locator"));
    try std.testing.expectError(ParseError.InvalidFormat, parseTestSpec(std.testing.allocator, "custom_event test_id:\"chart\" \"chart-select\""));
    try std.testing.expectError(ParseError.InvalidFormat, parseTestSpec(std.testing.allocator, "custom_event test_id:\"chart\" chart-select \"detail\""));
    try std.testing.expectError(ParseError.InvalidFormat, parseTestSpec(std.testing.allocator, "resolve_stale_task \"fetch user\""));
    try std.testing.expectError(ParseError.InvalidFormat, parseTestSpec(std.testing.allocator, "expect_canceled_task \"fetch user\" nope"));
    try std.testing.expectError(ParseError.InvalidFormat, parseTestSpec(std.testing.allocator, "expect_canceled_task fetch 1"));
}

test "splitTrailingQuoted skips escaped quotes" {
    const split = try splitTrailingQuoted("test_id:\"greeting\" \"he said \\\"hi\\\"\"");
    try std.testing.expectEqualStrings("test_id:\"greeting\"", split.head);
    try std.testing.expectEqualStrings("he said \\\"hi\\\"", split.quoted);

    const unescaped = try dupeUnescapedQuoted(std.testing.allocator, split.quoted);
    defer std.testing.allocator.free(unescaped);
    try std.testing.expectEqualStrings("he said \"hi\"", unescaped);
}
