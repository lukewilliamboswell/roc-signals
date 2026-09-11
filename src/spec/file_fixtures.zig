//! Human-readable native Files settlements for semantic specs. The fixtures use
//! the production files1 codec while retaining an explicit task-kind admission
//! mask, so a convenient fixture cannot accidentally call another task decoder.
const std = @import("std");
const boundary = @import("signals").boundary;
const sexpr = @import("sexpr.zig");

pub const ParseError = error{ InvalidFormat, OutOfMemory };
pub const Fixture = struct {
    task_name: []const u8,
    payload: []const u8,
    kinds: u64,
    failed: bool,
};

const protocol = @import("signals").native_protocol;

/// Recognizes only the structured file-settlement vocabulary the manifest
/// declares; raw task commands remain available for deliberate
/// malformed-payload and stale-result tests.
pub fn recognizes(head: []const u8) bool {
    if (std.mem.eql(u8, head, protocol.task_error_fixture)) return true;
    for (protocol.task_schemas) |schema| {
        if (schema.fixture) |fixture| if (std.mem.eql(u8, head, fixture)) return true;
    }
    return false;
}

fn bit(kind: boundary.TaskKind) u64 {
    return @as(u64, 1) << @intCast(@intFromEnum(kind));
}

/// Tests the declared route without inferring a task service from its label.
pub fn admits(kinds: u64, kind: boundary.TaskKind) bool {
    return kinds & bit(kind) != 0;
}

fn fileKinds() u64 {
    var kinds: u64 = 0;
    for ([_]boundary.TaskKind{ .choose_file, .choose_directory, .choose_save_path, .read_text, .write_text, .scan_directory, .list_directory, .open_path, .read_preview, .read_log, .verify_assets }) |kind| {
        kinds |= bit(kind);
    }
    return kinds;
}

fn string(expr: sexpr.Expr) ParseError![]const u8 {
    return switch (expr.value) {
        .atom => |atom| switch (atom) {
            .string => |value| value,
            else => error.InvalidFormat,
        },
        else => error.InvalidFormat,
    };
}
fn symbol(expr: sexpr.Expr) ParseError![]const u8 {
    return switch (expr.value) {
        .atom => |atom| switch (atom) {
            .symbol => |value| value,
            else => error.InvalidFormat,
        },
        else => error.InvalidFormat,
    };
}
fn validText(text: []const u8, limit: usize) bool {
    return text.len <= limit and std.unicode.utf8ValidateSlice(text);
}
fn driveLetter(byte: u8) bool {
    return (byte >= 'A' and byte <= 'Z') or (byte >= 'a' and byte <= 'z');
}
/// Recognizes the absolute-path spellings a native worker can actually return,
/// so a typed fixture can express a Windows result without dropping to a raw
/// task frame. A path is absolute when it is POSIX-rooted (`/`), drive-rooted
/// (`C:\` or `C:/`), or a UNC prefix (`\\server\share`). Backslashes are only
/// separators inside the Windows spellings; a POSIX path may contain them as
/// ordinary file-name bytes, which is why nothing here rewrites a byte.
fn absolutePath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/') return true;
    if (path.len >= 2 and path[0] == '\\' and path[1] == '\\') return true;
    return path.len >= 3 and driveLetter(path[0]) and path[1] == ':' and (path[2] == '\\' or path[2] == '/');
}
fn validPath(path: []const u8) bool {
    return validText(path, 4096) and absolutePath(path) and std.mem.indexOfScalar(u8, path, 0) == null;
}
fn field(items: []const sexpr.Expr, name: []const u8) ParseError!sexpr.Expr {
    if (items.len == 0 or items.len % 2 != 0) return error.InvalidFormat;
    var result: ?sexpr.Expr = null;
    var index: usize = 0;
    while (index < items.len) : (index += 2) {
        const key = try symbol(items[index]);
        var previous: usize = 0;
        while (previous < index) : (previous += 2) {
            if (std.mem.eql(u8, key, try symbol(items[previous]))) return error.InvalidFormat;
        }
        if (std.mem.eql(u8, key, name)) result = items[index + 1];
    }
    return result orelse error.InvalidFormat;
}
fn unsigned(expr: sexpr.Expr) ParseError!u64 {
    const text = expr.spelling orelse return error.InvalidFormat;
    if (text.len == 0 or (text.len > 1 and text[0] == '0')) return error.InvalidFormat;
    for (text) |byte| if (byte < '0' or byte > '9') return error.InvalidFormat;
    return std.fmt.parseInt(u64, text, 10) catch error.InvalidFormat;
}
fn numberFrame(writer: *std.Io.Writer, value: u64) ParseError!void {
    var buffer: [20]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable;
    try frame(writer, text);
}
fn oneOf(value: []const u8, options: []const []const u8) bool {
    for (options) |option| if (std.mem.eql(u8, value, option)) return true;
    return false;
}
fn frame(writer: *std.Io.Writer, value: []const u8) ParseError!void {
    writer.print("{d}:{s}", .{ value.len, value }) catch return error.OutOfMemory;
}

/// Parses and encodes a complete fixture before transferring its two owned
/// strings to the spec command. Failure releases every provisional allocation.
///
/// The fixture's shape is the manifest's result shape for its task kind: each
/// field is a `:name value` pair, a list is a list of positional elements in
/// the field's spelling order, and a tagged field is a single positional form
/// such as `(chosen "/p")`. The bytes written are the production frames, in
/// wire order, so a fixture and a real worker settle a task identically.
pub fn parse(allocator: std.mem.Allocator, head: []const u8, args: []const sexpr.Expr) ParseError!Fixture {
    if (args.len < 1) return error.InvalidFormat;
    const task = try string(args[0]);
    if (task.len == 0 or !validText(task, 4096)) return error.InvalidFormat;
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();
    try frame(&buffer.writer, "files1");
    const failed = std.mem.eql(u8, head, protocol.task_error_fixture);
    var kinds: u64 = 0;
    if (failed) {
        try encodeFields(&buffer.writer, &protocol.task_error_fields, args[1..], &protocol.task_error_rules);
        kinds = fileKinds();
    } else {
        var found = false;
        for (protocol.task_schemas) |schema| {
            const fixture = schema.fixture orelse continue;
            if (!std.mem.eql(u8, head, fixture)) continue;
            if (!found) try encodeFields(&buffer.writer, schema.result, args[1..], schema.rules);
            found = true;
            kinds |= bit(schema.kind);
        }
        if (!found) return error.InvalidFormat;
    }
    const name = try allocator.dupe(u8, task);
    errdefer allocator.free(name);
    const payload = try allocator.dupe(u8, buffer.written());
    return .{ .task_name = name, .payload = payload, .kinds = kinds, .failed = failed };
}

/// Encodes one field list from the form's arguments. A single tagged field is
/// spelled positionally; everything else is keyword pairs, every field
/// required and none repeated.
fn encodeFields(writer: *std.Io.Writer, fields: []const protocol.TaskField, args: []const sexpr.Expr, rules: []const []const u8) ParseError!void {
    var budget: Budget = .{};
    if (fields.len == 1 and fields[0].kind == .tagged) {
        if (args.len != 1) return error.InvalidFormat;
        try encodeValue(writer, fields[0], args[0], &budget);
    } else {
        if (args.len != fields.len * 2) return error.InvalidFormat;
        for (fields) |field_spec| {
            var keyword_buffer: [64]u8 = undefined;
            const keyword = std.fmt.bufPrint(&keyword_buffer, ":{s}", .{field_spec.name}) catch return error.InvalidFormat;
            try encodeValue(writer, field_spec, try field(args, keyword), &budget);
        }
    }
    for (rules) |rule| try applyRule(rule, &budget);
}

/// What the hand-written rules observe as fields are encoded: the values
/// they relate, which no per-field type can express.
const Budget = struct {
    path_bytes: usize = 0,
    code: ?[]const u8 = null,
    detail_len: usize = 0,
};

/// The cross-field rules the manifest names. A rule the manifest names but
/// this switch does not know is a build error, not a silently skipped check.
fn applyRule(rule: []const u8, budget: *Budget) ParseError!void {
    if (std.mem.eql(u8, rule, "directory_path_budget")) {
        // A listing's paths together stay under the aggregate-path bound.
        if (budget.path_bytes > 4194304) return error.InvalidFormat;
    } else if (std.mem.eql(u8, rule, "canceled_empty_detail")) {
        if (budget.code) |code| if (std.mem.eql(u8, code, "canceled") and budget.detail_len != 0) return error.InvalidFormat;
    } else {
        @panic("unknown fixture rule named in the protocol manifest");
    }
}

fn encodeValue(writer: *std.Io.Writer, spec: protocol.TaskField, expr: sexpr.Expr, budget: *Budget) ParseError!void {
    switch (spec.kind) {
        .path => {
            const path = try string(expr);
            if (!validPath(path)) return error.InvalidFormat;
            budget.path_bytes += path.len;
            try frame(writer, path);
        },
        .text => |text_spec| {
            const text = try string(expr);
            if (!validText(text, text_spec.max_bytes) or (text_spec.non_empty and text.len == 0)) return error.InvalidFormat;
            if (std.mem.eql(u8, spec.name, "detail")) budget.detail_len = text.len;
            try frame(writer, text);
        },
        .unsigned => |number_spec| {
            const value = try unsigned(expr);
            if (number_spec.max_value) |max| if (value > max) return error.InvalidFormat;
            try numberFrame(writer, value);
        },
        .boolean => {
            const value = switch (expr.value) {
                .atom => |atom| switch (atom) {
                    .boolean => |value| value,
                    else => return error.InvalidFormat,
                },
                else => return error.InvalidFormat,
            };
            try frame(writer, if (value) "true" else "false");
        },
        .symbol => |options| {
            const value = try symbol(expr);
            if (!oneOf(value, options)) return error.InvalidFormat;
            if (std.mem.eql(u8, spec.name, "kind")) budget.code = value;
            try frame(writer, value);
        },
        .hex_sha256 => {
            const digest = try string(expr);
            if (digest.len != 64) return error.InvalidFormat;
            for (digest) |byte| if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) return error.InvalidFormat;
            try frame(writer, digest);
        },
        .list => |list_spec| {
            const items = switch (expr.value) {
                .list => |items| items,
                else => return error.InvalidFormat,
            };
            if (items.len < list_spec.min_items or items.len > list_spec.max_items) return error.InvalidFormat;
            try numberFrame(writer, items.len);
            for (items) |item| {
                const parts = switch (item.value) {
                    .list => |parts| parts,
                    else => return error.InvalidFormat,
                };
                if (parts.len != list_spec.of.len) return error.InvalidFormat;
                // Elements are spelled in the fixture's order but framed in wire order.
                for (list_spec.of) |element_spec| {
                    const position = spelledPosition(list_spec, element_spec.name);
                    try encodeValue(writer, element_spec, parts[position], budget);
                }
            }
        },
        .tagged => |variants| {
            const parts = switch (expr.value) {
                .list => |parts| parts,
                else => return error.InvalidFormat,
            };
            if (parts.len == 0) return error.InvalidFormat;
            const tag = try symbol(parts[0]);
            for (variants) |variant| {
                if (!std.mem.eql(u8, tag, variant.tag)) continue;
                if (parts.len != 1 + variant.fields.len) return error.InvalidFormat;
                try frame(writer, tag);
                for (variant.fields, parts[1..]) |variant_field, part| try encodeValue(writer, variant_field, part, budget);
                return;
            }
            return error.InvalidFormat;
        },
    }
}

/// Where an element field appears in the fixture spelling: the manifest's
/// `spelling` order when it declares one, wire order otherwise.
fn spelledPosition(list_spec: anytype, name: []const u8) usize {
    const order = list_spec.spelling orelse {
        for (list_spec.of, 0..) |element, index| if (std.mem.eql(u8, element.name, name)) return index;
        unreachable;
    };
    for (order, 0..) |spelled, index| if (std.mem.eql(u8, spelled, name)) return index;
    unreachable;
}

test "asset fixtures frame ordered name and status pairs" {
    var reader = sexpr.Reader.init(std.testing.allocator, "(resolve-file-assets \"asset-verify\" :entries ((ok \"avatars/maya.png\") (missing \"glyphs/λ.png\")))");
    const expr = try reader.readOne();
    defer expr.deinit(std.testing.allocator);
    const items = expr.value.list;
    const fixture = try parse(std.testing.allocator, try symbol(items[0]), items[1..]);
    defer std.testing.allocator.free(fixture.task_name);
    defer std.testing.allocator.free(fixture.payload);
    try std.testing.expectEqualStrings("6:files11:216:avatars/maya.png2:ok13:glyphs/λ.png7:missing", fixture.payload);
    try std.testing.expect(admits(fixture.kinds, .verify_assets));
    try std.testing.expect(!admits(fixture.kinds, .read_text));
}

test "file fixtures frame exact UTF-8 bytes and preserve separators" {
    var reader = sexpr.Reader.init(std.testing.allocator, "(resolve-file-read \"notes-read\" :text \"a\\nλ:\\\"\" :path \"/tmp/λ.txt\")");
    const expr = try reader.readOne();
    defer expr.deinit(std.testing.allocator);
    const items = expr.value.list;
    const fixture = try parse(std.testing.allocator, try symbol(items[0]), items[1..]);
    defer std.testing.allocator.free(fixture.task_name);
    defer std.testing.allocator.free(fixture.payload);
    try std.testing.expectEqualStrings("6:files111:/tmp/λ.txt6:a\nλ:\"", fixture.payload);
    try std.testing.expect(admits(fixture.kinds, .read_text));
    try std.testing.expect(!admits(fixture.kinds, .write_text));
    try std.testing.expect(!admits(fixture.kinds, .external));
}

test "path fixtures admit every absolute spelling a native worker returns" {
    try std.testing.expect(validPath("/tmp/note.txt"));
    try std.testing.expect(validPath("/tmp/a\\b.txt"));
    try std.testing.expect(validPath("C:\\Users\\Lee\\Ideas.txt"));
    try std.testing.expect(validPath("c:/Users/Lee"));
    try std.testing.expect(validPath("\\\\server\\share\\docs"));
    try std.testing.expect(!validPath(""));
    try std.testing.expect(!validPath("docs/notes.txt"));
    try std.testing.expect(!validPath("C:notes.txt"));
    try std.testing.expect(!validPath("\\single\\backslash"));
}

test "file choice fixtures carry Windows paths byte for byte" {
    var reader = sexpr.Reader.init(std.testing.allocator, "(resolve-file-choice \"notes-open\" (chosen \"C:\\\\Users\\\\Lee\\\\Ideas.txt\"))");
    const expr = try reader.readOne();
    defer expr.deinit(std.testing.allocator);
    const items = expr.value.list;
    const fixture = try parse(std.testing.allocator, try symbol(items[0]), items[1..]);
    defer std.testing.allocator.free(fixture.task_name);
    defer std.testing.allocator.free(fixture.payload);
    try std.testing.expectEqualStrings("6:files16:chosen22:C:\\Users\\Lee\\Ideas.txt", fixture.payload);
    try std.testing.expect(admits(fixture.kinds, .choose_file));
}

/// Names the expected typed service for an actionable mismatch diagnostic:
/// the one kind a mask names, the chooser family, or the whole Files service.
pub fn expectedService(kinds: u64) []const u8 {
    if (kinds == bit(.choose_file) | bit(.choose_directory) | bit(.choose_save_path)) return "file/directory/save chooser";
    for (protocol.task_schemas) |schema| if (kinds == bit(schema.kind)) return @tagName(schema.kind);
    return "a native Files task";
}
