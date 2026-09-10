//! `stub-http` forms declare answers for the hosted `Http` function in the
//! spec host. Each parses into the `http1` packet the Roc decoder expects.
const std = @import("std");
const sexpr = @import("sexpr.zig");

pub const ParseError = error{ InvalidFormat, OutOfMemory };

pub const Fixture = struct {
    /// The request URI the stub answers; empty for an error stub, which answers any request.
    uri: []const u8,
    payload: []const u8,
    failed: bool,
};

const max_body_bytes = 8 * 1024 * 1024;

/// Reports whether `head` is an `Http` stub form.
pub fn recognizes(head: []const u8) bool {
    return std.mem.eql(u8, head, "stub-http") or std.mem.eql(u8, head, "stub-http-reject");
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
fn field(items: []const sexpr.Expr, name: []const u8) ParseError!?sexpr.Expr {
    if (items.len % 2 != 0) return error.InvalidFormat;
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
    return result;
}
fn required(items: []const sexpr.Expr, name: []const u8) ParseError!sexpr.Expr {
    return (try field(items, name)) orelse error.InvalidFormat;
}
fn unsigned(expr: sexpr.Expr) ParseError!u64 {
    const text = expr.spelling orelse return error.InvalidFormat;
    if (text.len == 0 or (text.len > 1 and text[0] == '0')) return error.InvalidFormat;
    for (text) |byte| if (byte < '0' or byte > '9') return error.InvalidFormat;
    return std.fmt.parseInt(u64, text, 10) catch error.InvalidFormat;
}
fn frame(writer: *std.Io.Writer, value: []const u8) ParseError!void {
    writer.print("{d}:{s}", .{ value.len, value }) catch return error.OutOfMemory;
}
fn numberFrame(writer: *std.Io.Writer, value: u64) ParseError!void {
    var buffer: [20]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable;
    try frame(writer, text);
}

/// Parses `(stub-http "label" :url "..." :status N :body "..." [:headers ((name value) ...)])`
/// or `(stub-http-reject "label" :kind K :detail "...")` into the packet the
/// Roc decoder expects. Every allowed field is checked before any allocation
/// the caller must own.
pub fn parse(allocator: std.mem.Allocator, head: []const u8, args: []const sexpr.Expr) ParseError!Fixture {
    if (args.len < 1) return error.InvalidFormat;
    const label = try string(args[0]);
    if (label.len == 0 or label.len > 4096) return error.InvalidFormat;
    const fields = args[1..];
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();
    try frame(&buffer.writer, "http1");
    var uri: []const u8 = "";
    const failed = std.mem.eql(u8, head, "stub-http-reject");
    if (failed) {
        if (fields.len != 4) return error.InvalidFormat;
        const kind = try symbol(try required(fields, ":kind"));
        const detail = try string(try required(fields, ":detail"));
        const kinds = [_][]const u8{ "invalid-request", "network", "timeout", "too-large", "unavailable" };
        var known = false;
        for (kinds) |option| known = known or std.mem.eql(u8, kind, option);
        if (!known) return error.InvalidFormat;
        if (std.mem.eql(u8, kind, "timeout") and detail.len != 0) return error.InvalidFormat;
        if (detail.len > 4096 or !std.unicode.utf8ValidateSlice(detail)) return error.InvalidFormat;
        try frame(&buffer.writer, kind);
        try frame(&buffer.writer, detail);
    } else {
        uri = try string(try required(fields, ":url"));
        if (uri.len == 0 or uri.len > 8192 or !std.unicode.utf8ValidateSlice(uri)) return error.InvalidFormat;
        const status = try unsigned(try required(fields, ":status"));
        if (status < 100 or status > 999) return error.InvalidFormat;
        const body = try string(try required(fields, ":body"));
        if (body.len > max_body_bytes) return error.InvalidFormat;
        const headers = try field(fields, ":headers");
        const expected_fields: usize = if (headers == null) 6 else 8;
        if (fields.len != expected_fields) return error.InvalidFormat;
        try numberFrame(&buffer.writer, status);
        var count: u64 = 0;
        if (headers) |list| {
            const entries = switch (list.value) {
                .list => |entries| entries,
                else => return error.InvalidFormat,
            };
            count = entries.len;
            try numberFrame(&buffer.writer, count);
            for (entries) |entry| {
                const pair = switch (entry.value) {
                    .list => |pair| pair,
                    else => return error.InvalidFormat,
                };
                if (pair.len != 2) return error.InvalidFormat;
                const name = try string(pair[0]);
                const value = try string(pair[1]);
                if (name.len == 0 or name.len > 4096 or value.len > 65536) return error.InvalidFormat;
                try frame(&buffer.writer, name);
                try frame(&buffer.writer, value);
            }
        } else {
            try numberFrame(&buffer.writer, 0);
        }
        try frame(&buffer.writer, body);
    }
    const uri_copy = try allocator.dupe(u8, uri);
    errdefer allocator.free(uri_copy);
    const payload = try allocator.dupe(u8, buffer.written());
    return .{ .uri = uri_copy, .payload = payload, .failed = failed };
}

test "http stubs frame status headers and body" {
    var reader = sexpr.Reader.init(std.testing.allocator, "(stub-http \"feed\" :url \"https://example.test/a\" :status 200 :headers ((\"content-type\" \"text/plain\")) :body \"hi λ\")");
    const expr = try reader.readOne();
    defer expr.deinit(std.testing.allocator);
    const items = expr.value.list;
    const fixture = try parse(std.testing.allocator, try symbol(items[0]), items[1..]);
    defer std.testing.allocator.free(fixture.uri);
    defer std.testing.allocator.free(fixture.payload);
    try std.testing.expectEqualStrings("https://example.test/a", fixture.uri);
    try std.testing.expectEqualStrings("5:http13:2001:112:content-type10:text/plain5:hi λ", fixture.payload);
    try std.testing.expect(!fixture.failed);
}

test "http reject stubs frame a typed error and refuse unknown kinds" {
    var reader = sexpr.Reader.init(std.testing.allocator, "(stub-http-reject \"feed\" :kind timeout :detail \"\")");
    const expr = try reader.readOne();
    defer expr.deinit(std.testing.allocator);
    const items = expr.value.list;
    const fixture = try parse(std.testing.allocator, try symbol(items[0]), items[1..]);
    defer std.testing.allocator.free(fixture.uri);
    defer std.testing.allocator.free(fixture.payload);
    try std.testing.expectEqualStrings("5:http17:timeout0:", fixture.payload);
    try std.testing.expect(fixture.failed);
    var bad = sexpr.Reader.init(std.testing.allocator, "(stub-http-reject \"feed\" :kind invented :detail \"x\")");
    const bad_expr = try bad.readOne();
    defer bad_expr.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidFormat, parse(std.testing.allocator, try symbol(bad_expr.value.list[0]), bad_expr.value.list[1..]));
}
