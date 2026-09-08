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

/// Recognizes only the structured file-settlement vocabulary; raw task commands
/// remain available for deliberate malformed-payload and stale-result tests.
pub fn recognizes(head: []const u8) bool {
    return std.mem.eql(u8, head, "resolve-file-choice") or
        std.mem.eql(u8, head, "resolve-file-read") or
        std.mem.eql(u8, head, "resolve-file-write") or
        std.mem.eql(u8, head, "reject-file");
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
    inline for (.{ "choose_file", "choose_directory", "choose_save_path", "read_text", "write_text", "scan_directory", "list_directory", "open_path", "read_preview", "read_log" }) |name| {
        if (@hasField(boundary.TaskKind, name)) kinds |= bit(@field(boundary.TaskKind, name));
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
fn validPath(path: []const u8) bool {
    return validText(path, 4096) and path.len != 0 and path[0] == '/' and std.mem.indexOfScalar(u8, path, 0) == null;
}
fn field(items: []const sexpr.Expr, name: []const u8) ParseError!sexpr.Expr {
    if (items.len != 4) return error.InvalidFormat;
    const first = try symbol(items[0]);
    const second = try symbol(items[2]);
    if (std.mem.eql(u8, first, second)) return error.InvalidFormat;
    if (std.mem.eql(u8, first, name)) return items[1];
    if (std.mem.eql(u8, second, name)) return items[3];
    return error.InvalidFormat;
}
fn frame(writer: *std.Io.Writer, value: []const u8) ParseError!void {
    writer.print("{d}:{s}", .{ value.len, value }) catch return error.OutOfMemory;
}

/// Parses and encodes a complete fixture before transferring its two owned
/// strings to the spec command. Failure releases every provisional allocation.
pub fn parse(allocator: std.mem.Allocator, head: []const u8, args: []const sexpr.Expr) ParseError!Fixture {
    if (args.len < 2) return error.InvalidFormat;
    const task = try string(args[0]);
    if (task.len == 0 or !validText(task, 4096)) return error.InvalidFormat;
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();
    try frame(&buffer.writer, "files1");
    var kinds: u64 = 0;
    const failed = std.mem.eql(u8, head, "reject-file");
    if (std.mem.eql(u8, head, "resolve-file-choice")) {
        if (args.len != 2) return error.InvalidFormat;
        const choice = switch (args[1].value) {
            .list => |items| items,
            else => return error.InvalidFormat,
        };
        if (choice.len == 0) return error.InvalidFormat;
        const tag = try symbol(choice[0]);
        if (std.mem.eql(u8, tag, "chosen")) {
            if (choice.len != 2) return error.InvalidFormat;
            const path = try string(choice[1]);
            if (!validPath(path)) return error.InvalidFormat;
            try frame(&buffer.writer, "chosen");
            try frame(&buffer.writer, path);
        } else if (std.mem.eql(u8, tag, "canceled") and choice.len == 1) {
            try frame(&buffer.writer, "canceled");
        } else return error.InvalidFormat;
        kinds = bit(.choose_file) | bit(.choose_directory) | bit(.choose_save_path);
    } else if (std.mem.eql(u8, head, "resolve-file-read")) {
        const path = try string(try field(args[1..], ":path"));
        const text = try string(try field(args[1..], ":text"));
        if (!validPath(path) or !validText(text, 1048576)) return error.InvalidFormat;
        try frame(&buffer.writer, path);
        try frame(&buffer.writer, text);
        kinds = bit(.read_text);
    } else if (std.mem.eql(u8, head, "resolve-file-write")) {
        const path = try string(try field(args[1..], ":path"));
        const size = switch ((try field(args[1..], ":bytes")).value) {
            .atom => |atom| switch (atom) {
                .integer => |value| value,
                else => return error.InvalidFormat,
            },
            else => return error.InvalidFormat,
        };
        if (!validPath(path) or size < 0 or size > 1048576) return error.InvalidFormat;
        var number: [20]u8 = undefined;
        const text = std.fmt.bufPrint(&number, "{d}", .{size}) catch unreachable;
        try frame(&buffer.writer, path);
        try frame(&buffer.writer, text);
        kinds = bit(.write_text);
    } else if (failed) {
        const kind = try symbol(try field(args[1..], ":kind"));
        const detail = try string(try field(args[1..], ":detail"));
        if (!validText(detail, 4096)) return error.InvalidFormat;
        var known = false;
        for ([_][]const u8{ "canceled", "not-found", "permission-denied", "invalid-utf8", "invalid-path", "resource-limit", "io", "unavailable" }) |candidate| {
            known = known or std.mem.eql(u8, candidate, kind);
        }
        if (!known or (std.mem.eql(u8, kind, "canceled") and detail.len != 0)) return error.InvalidFormat;
        try frame(&buffer.writer, kind);
        try frame(&buffer.writer, detail);
        kinds = fileKinds();
    } else return error.InvalidFormat;
    const name = try allocator.dupe(u8, task);
    errdefer allocator.free(name);
    const payload = try allocator.dupe(u8, buffer.written());
    return .{ .task_name = name, .payload = payload, .kinds = kinds, .failed = failed };
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

/// Names the expected typed service for an actionable mismatch diagnostic.
pub fn expectedService(kinds: u64) []const u8 {
    if (kinds == bit(.read_text)) return "read_text";
    if (kinds == bit(.write_text)) return "write_text";
    if (kinds == bit(.choose_file) | bit(.choose_directory) | bit(.choose_save_path)) return "file/directory/save chooser";
    return "a native Files task";
}
