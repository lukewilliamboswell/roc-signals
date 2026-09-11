//! `stub-http` forms declare typed answers for the hosted `Http` function in
//! the spec host.
const std = @import("std");
const sexpr = @import("sexpr.zig");

pub const ParseError = error{ InvalidFormat, OutOfMemory };

pub const ErrorKind = enum { invalid_request, network, timeout, too_large, unavailable };
pub const Header = struct { name: []const u8, value: []const u8 };

/// One declared answer. Every string is owned by the allocator that parsed or
/// duplicated the stub.
pub const Stub = union(enum) {
    response: struct { uri: []const u8, status: u16, headers: []Header, body: []const u8 },
    /// Answers the next request for any URI.
    reject: struct { kind: ErrorKind, detail: []const u8 },

    /// Releases every string and list the stub owns.
    pub fn deinit(self: Stub, allocator: std.mem.Allocator) void {
        switch (self) {
            .response => |stub| {
                allocator.free(stub.uri);
                for (stub.headers) |header| {
                    allocator.free(header.name);
                    allocator.free(header.value);
                }
                allocator.free(stub.headers);
                allocator.free(stub.body);
            },
            .reject => |stub| allocator.free(stub.detail),
        }
    }

    /// Deep-copies the stub so another owner can keep it.
    pub fn dupe(self: Stub, allocator: std.mem.Allocator) std.mem.Allocator.Error!Stub {
        switch (self) {
            .response => |stub| {
                const uri = try allocator.dupe(u8, stub.uri);
                errdefer allocator.free(uri);
                const headers = try allocator.alloc(Header, stub.headers.len);
                var done: usize = 0;
                errdefer {
                    for (headers[0..done]) |header| {
                        allocator.free(header.name);
                        allocator.free(header.value);
                    }
                    allocator.free(headers);
                }
                for (stub.headers, 0..) |header, index| {
                    const name = try allocator.dupe(u8, header.name);
                    errdefer allocator.free(name);
                    headers[index] = .{ .name = name, .value = try allocator.dupe(u8, header.value) };
                    done += 1;
                }
                const body = try allocator.dupe(u8, stub.body);
                return .{ .response = .{ .uri = uri, .status = stub.status, .headers = headers, .body = body } };
            },
            .reject => |stub| return .{ .reject = .{ .kind = stub.kind, .detail = try allocator.dupe(u8, stub.detail) } },
        }
    }
};

pub const Fixture = struct {
    label: []const u8,
    stub: Stub,
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
fn list(expr: sexpr.Expr) ParseError![]sexpr.Expr {
    return switch (expr.value) {
        .list => |items| items,
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
fn validText(text: []const u8, limit: usize) bool {
    return text.len <= limit and std.unicode.utf8ValidateSlice(text);
}

/// Parses `(stub-http "label" :url "..." :status N :body "..." [:headers ((name value) ...)])`
/// or `(stub-http-reject "label" :kind K :detail "...")`. Failure releases
/// every provisional allocation.
pub fn parse(allocator: std.mem.Allocator, head: []const u8, args: []const sexpr.Expr) ParseError!Fixture {
    if (args.len < 1) return error.InvalidFormat;
    const label_text = try string(args[0]);
    if (label_text.len == 0 or !validText(label_text, 4096)) return error.InvalidFormat;
    const stub = try parseStub(allocator, head, args[1..]);
    errdefer stub.deinit(allocator);
    const label = try allocator.dupe(u8, label_text);
    return .{ .label = label, .stub = stub };
}

fn parseStub(allocator: std.mem.Allocator, head: []const u8, fields: []const sexpr.Expr) ParseError!Stub {
    if (std.mem.eql(u8, head, "stub-http-reject")) {
        if (fields.len != 4) return error.InvalidFormat;
        const kind_text = try symbol(try required(fields, ":kind"));
        const detail = try string(try required(fields, ":detail"));
        const kind: ErrorKind = if (std.mem.eql(u8, kind_text, "invalid-request")) .invalid_request else if (std.mem.eql(u8, kind_text, "network")) .network else if (std.mem.eql(u8, kind_text, "timeout")) .timeout else if (std.mem.eql(u8, kind_text, "too-large")) .too_large else if (std.mem.eql(u8, kind_text, "unavailable")) .unavailable else return error.InvalidFormat;
        if (kind == .timeout and detail.len != 0) return error.InvalidFormat;
        if (!validText(detail, 4096)) return error.InvalidFormat;
        return .{ .reject = .{ .kind = kind, .detail = try allocator.dupe(u8, detail) } };
    }
    if (!std.mem.eql(u8, head, "stub-http")) return error.InvalidFormat;
    const uri_text = try string(try required(fields, ":url"));
    if (uri_text.len == 0 or !validText(uri_text, 8192)) return error.InvalidFormat;
    const status = try unsigned(try required(fields, ":status"));
    if (status < 100 or status > 999) return error.InvalidFormat;
    const body_text = try string(try required(fields, ":body"));
    if (body_text.len > max_body_bytes) return error.InvalidFormat;
    const headers_field = try field(fields, ":headers");
    if (fields.len != @as(usize, if (headers_field == null) 6 else 8)) return error.InvalidFormat;
    const header_items: []sexpr.Expr = if (headers_field) |expr| try list(expr) else &.{};
    const headers = try allocator.alloc(Header, header_items.len);
    var done: usize = 0;
    errdefer {
        for (headers[0..done]) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        allocator.free(headers);
    }
    for (header_items, 0..) |item, index| {
        const pair = try list(item);
        if (pair.len != 2) return error.InvalidFormat;
        const name = try string(pair[0]);
        const value = try string(pair[1]);
        if (name.len == 0 or !validText(name, 4096) or !validText(value, 65536)) return error.InvalidFormat;
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        headers[index] = .{ .name = name_copy, .value = try allocator.dupe(u8, value) };
        done += 1;
    }
    const uri = try allocator.dupe(u8, uri_text);
    errdefer allocator.free(uri);
    const body = try allocator.dupe(u8, body_text);
    return .{ .response = .{ .uri = uri, .status = @intCast(status), .headers = headers, .body = body } };
}

test "http stubs keep status headers and body" {
    var reader = sexpr.Reader.init(std.testing.allocator, "(stub-http \"feed\" :url \"https://example.test/a\" :status 200 :headers ((\"content-type\" \"text/plain\")) :body \"hi λ\")");
    const expr = try reader.readOne();
    defer expr.deinit(std.testing.allocator);
    const items = expr.value.list;
    const fixture = try parse(std.testing.allocator, try symbol(items[0]), items[1..]);
    defer std.testing.allocator.free(fixture.label);
    defer fixture.stub.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("https://example.test/a", fixture.stub.response.uri);
    try std.testing.expectEqual(@as(u16, 200), fixture.stub.response.status);
    try std.testing.expectEqualStrings("text/plain", fixture.stub.response.headers[0].value);
    try std.testing.expectEqualStrings("hi λ", fixture.stub.response.body);
}

test "http reject stubs carry a typed error and refuse unknown kinds" {
    var reader = sexpr.Reader.init(std.testing.allocator, "(stub-http-reject \"feed\" :kind timeout :detail \"\")");
    const expr = try reader.readOne();
    defer expr.deinit(std.testing.allocator);
    const items = expr.value.list;
    const fixture = try parse(std.testing.allocator, try symbol(items[0]), items[1..]);
    defer std.testing.allocator.free(fixture.label);
    defer fixture.stub.deinit(std.testing.allocator);
    try std.testing.expectEqual(ErrorKind.timeout, fixture.stub.reject.kind);
    var bad = sexpr.Reader.init(std.testing.allocator, "(stub-http-reject \"feed\" :kind invented :detail \"x\")");
    const bad_expr = try bad.readOne();
    defer bad_expr.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidFormat, parse(std.testing.allocator, try symbol(bad_expr.value.list[0]), bad_expr.value.list[1..]));
}
