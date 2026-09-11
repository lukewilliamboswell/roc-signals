//! `stub-file-*` forms declare typed answers for the hosted `Files` functions
//! in the spec host. The leading label is diagnostic; matching uses the
//! operation and its path.
const std = @import("std");
const sexpr = @import("sexpr.zig");

pub const ParseError = error{ InvalidFormat, OutOfMemory };

pub const Kind = enum { file, directory, symbolic_link, other };
pub const LogChange = enum { initial, continued, rotated, truncated };
pub const LogState = enum { more, at_end, partial_utf8 };
pub const AssetStatus = enum { ok, missing, mismatch };
pub const ErrorKind = enum { canceled, not_found, permission_denied, invalid_utf8, invalid_path, resource_limit, io, unavailable };

pub const Entry = struct { path: []const u8, kind: Kind, bytes: u64 };
pub const AssetCheck = struct { name: []const u8, status: AssetStatus };

/// One declared answer. Every string is owned by the allocator that parsed or
/// duplicated the stub.
pub const Stub = union(enum) {
    /// `null` is a dismissed dialog; otherwise the chosen path.
    choice: ?[]const u8,
    read: struct { path: []const u8, text: []const u8 },
    write: struct { path: []const u8, bytes: u64 },
    directory: struct { path: []const u8, entries: []Entry },
    preview: struct { path: []const u8, text: []const u8, truncated: bool },
    open: []const u8,
    log: struct { path: []const u8, text: []const u8, device: u64, inode: u64, offset: u64, change: LogChange, state: LogState },
    assets: []AssetCheck,
    /// Answers the next call of any operation.
    reject: struct { kind: ErrorKind, detail: []const u8 },

    /// The path the stub is keyed on, or null for stubs that answer any request.
    pub fn key(self: Stub) ?[]const u8 {
        return switch (self) {
            .read => |stub| stub.path,
            .write => |stub| stub.path,
            .directory => |stub| stub.path,
            .preview => |stub| stub.path,
            .open => |path| path,
            .log => |stub| stub.path,
            .choice, .assets, .reject => null,
        };
    }

    /// Releases every string and list the stub owns.
    pub fn deinit(self: Stub, allocator: std.mem.Allocator) void {
        switch (self) {
            .choice => |path| if (path) |value| allocator.free(value),
            .read => |stub| {
                allocator.free(stub.path);
                allocator.free(stub.text);
            },
            .write => |stub| allocator.free(stub.path),
            .directory => |stub| {
                allocator.free(stub.path);
                for (stub.entries) |entry| allocator.free(entry.path);
                allocator.free(stub.entries);
            },
            .preview => |stub| {
                allocator.free(stub.path);
                allocator.free(stub.text);
            },
            .open => |path| allocator.free(path),
            .log => |stub| {
                allocator.free(stub.path);
                allocator.free(stub.text);
            },
            .assets => |checks| {
                for (checks) |check| allocator.free(check.name);
                allocator.free(checks);
            },
            .reject => |stub| allocator.free(stub.detail),
        }
    }

    /// Deep-copies the stub so another owner can keep it.
    pub fn dupe(self: Stub, allocator: std.mem.Allocator) std.mem.Allocator.Error!Stub {
        switch (self) {
            .choice => |path| return .{ .choice = if (path) |value| try allocator.dupe(u8, value) else null },
            .read => |stub| {
                const path = try allocator.dupe(u8, stub.path);
                errdefer allocator.free(path);
                return .{ .read = .{ .path = path, .text = try allocator.dupe(u8, stub.text) } };
            },
            .write => |stub| return .{ .write = .{ .path = try allocator.dupe(u8, stub.path), .bytes = stub.bytes } },
            .directory => |stub| {
                const path = try allocator.dupe(u8, stub.path);
                errdefer allocator.free(path);
                const entries = try dupeEntries(allocator, stub.entries);
                return .{ .directory = .{ .path = path, .entries = entries } };
            },
            .preview => |stub| {
                const path = try allocator.dupe(u8, stub.path);
                errdefer allocator.free(path);
                return .{ .preview = .{ .path = path, .text = try allocator.dupe(u8, stub.text), .truncated = stub.truncated } };
            },
            .open => |path| return .{ .open = try allocator.dupe(u8, path) },
            .log => |stub| {
                const path = try allocator.dupe(u8, stub.path);
                errdefer allocator.free(path);
                var copy = stub;
                copy.path = path;
                copy.text = try allocator.dupe(u8, stub.text);
                return .{ .log = copy };
            },
            .assets => |checks| {
                const copy = try allocator.alloc(AssetCheck, checks.len);
                var done: usize = 0;
                errdefer {
                    for (copy[0..done]) |check| allocator.free(check.name);
                    allocator.free(copy);
                }
                for (checks, 0..) |check, index| {
                    copy[index] = .{ .name = try allocator.dupe(u8, check.name), .status = check.status };
                    done += 1;
                }
                return .{ .assets = copy };
            },
            .reject => |stub| return .{ .reject = .{ .kind = stub.kind, .detail = try allocator.dupe(u8, stub.detail) } },
        }
    }
};

fn dupeEntries(allocator: std.mem.Allocator, entries: []const Entry) std.mem.Allocator.Error![]Entry {
    const copy = try allocator.alloc(Entry, entries.len);
    var done: usize = 0;
    errdefer {
        for (copy[0..done]) |entry| allocator.free(entry.path);
        allocator.free(copy);
    }
    for (entries, 0..) |entry, index| {
        copy[index] = .{ .path = try allocator.dupe(u8, entry.path), .kind = entry.kind, .bytes = entry.bytes };
        done += 1;
    }
    return copy;
}

pub const Fixture = struct {
    label: []const u8,
    stub: Stub,
};

/// Reports whether `head` is a `Files` stub form.
pub fn recognizes(head: []const u8) bool {
    return std.mem.eql(u8, head, "stub-file-choice") or
        std.mem.eql(u8, head, "stub-file-read") or
        std.mem.eql(u8, head, "stub-file-write") or
        std.mem.eql(u8, head, "stub-file-log") or
        std.mem.eql(u8, head, "stub-file-directory") or
        std.mem.eql(u8, head, "stub-file-preview") or
        std.mem.eql(u8, head, "stub-file-open") or
        std.mem.eql(u8, head, "stub-file-assets") or
        std.mem.eql(u8, head, "stub-file-reject");
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
fn validText(text: []const u8, limit: usize) bool {
    return text.len <= limit and std.unicode.utf8ValidateSlice(text);
}
fn validPath(path: []const u8) bool {
    return validText(path, 4096) and path.len != 0 and path[0] == '/' and std.mem.indexOfScalar(u8, path, 0) == null;
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
fn boolean(expr: sexpr.Expr) ParseError!bool {
    return switch (expr.value) {
        .atom => |atom| switch (atom) {
            .boolean => |value| value,
            else => error.InvalidFormat,
        },
        else => error.InvalidFormat,
    };
}
fn enumValue(comptime E: type, expr: sexpr.Expr) ParseError!E {
    const text = try symbol(expr);
    inline for (@typeInfo(E).@"enum".fields) |candidate| {
        // Spec spellings use hyphens where Zig names use underscores.
        var spelled: [candidate.name.len]u8 = undefined;
        for (candidate.name, 0..) |byte, index| spelled[index] = if (byte == '_') '-' else byte;
        if (std.mem.eql(u8, text, &spelled)) return @field(E, candidate.name);
    }
    return error.InvalidFormat;
}
fn pathField(items: []const sexpr.Expr) ParseError![]const u8 {
    const path = try string(try field(items, ":path"));
    if (!validPath(path)) return error.InvalidFormat;
    return path;
}
fn textField(items: []const sexpr.Expr, limit: usize) ParseError![]const u8 {
    const text = try string(try field(items, ":text"));
    if (!validText(text, limit)) return error.InvalidFormat;
    return text;
}

const max_text_bytes = 1024 * 1024;
const max_preview_bytes = 64 * 1024;
const max_entries = 10_000;
const max_entry_path_bytes = 4 * 1024 * 1024;
const max_assets = 256;

/// Parses a fixture into an owned typed stub. Failure releases every
/// provisional allocation.
pub fn parse(allocator: std.mem.Allocator, head: []const u8, args: []const sexpr.Expr) ParseError!Fixture {
    if (args.len < 2) return error.InvalidFormat;
    const label_text = try string(args[0]);
    if (label_text.len == 0 or !validText(label_text, 4096)) return error.InvalidFormat;
    const fields = args[1..];
    const stub = try parseStub(allocator, head, fields);
    errdefer stub.deinit(allocator);
    const label = try allocator.dupe(u8, label_text);
    return .{ .label = label, .stub = stub };
}

fn parseStub(allocator: std.mem.Allocator, head: []const u8, fields: []const sexpr.Expr) ParseError!Stub {
    if (std.mem.eql(u8, head, "stub-file-choice")) {
        if (fields.len != 1) return error.InvalidFormat;
        const items = try list(fields[0]);
        if (items.len == 0) return error.InvalidFormat;
        const tag = try symbol(items[0]);
        if (std.mem.eql(u8, tag, "canceled")) {
            if (items.len != 1) return error.InvalidFormat;
            return .{ .choice = null };
        }
        if (!std.mem.eql(u8, tag, "chosen") or items.len != 2) return error.InvalidFormat;
        const path = try string(items[1]);
        if (!validPath(path)) return error.InvalidFormat;
        return .{ .choice = try allocator.dupe(u8, path) };
    }
    if (std.mem.eql(u8, head, "stub-file-read")) {
        if (fields.len != 4) return error.InvalidFormat;
        const path = try allocator.dupe(u8, try pathField(fields));
        errdefer allocator.free(path);
        return .{ .read = .{ .path = path, .text = try allocator.dupe(u8, try textField(fields, max_text_bytes)) } };
    }
    if (std.mem.eql(u8, head, "stub-file-write")) {
        if (fields.len != 4) return error.InvalidFormat;
        const bytes = try unsigned(try field(fields, ":bytes"));
        if (bytes > max_text_bytes) return error.InvalidFormat;
        return .{ .write = .{ .path = try allocator.dupe(u8, try pathField(fields)), .bytes = bytes } };
    }
    if (std.mem.eql(u8, head, "stub-file-open")) {
        if (fields.len != 2) return error.InvalidFormat;
        return .{ .open = try allocator.dupe(u8, try pathField(fields)) };
    }
    if (std.mem.eql(u8, head, "stub-file-preview")) {
        if (fields.len != 6) return error.InvalidFormat;
        const truncated = try boolean(try field(fields, ":truncated"));
        const path = try allocator.dupe(u8, try pathField(fields));
        errdefer allocator.free(path);
        return .{ .preview = .{ .path = path, .text = try allocator.dupe(u8, try textField(fields, max_preview_bytes)), .truncated = truncated } };
    }
    if (std.mem.eql(u8, head, "stub-file-log")) {
        if (fields.len != 14) return error.InvalidFormat;
        const device = try unsigned(try field(fields, ":device"));
        const inode = try unsigned(try field(fields, ":inode"));
        const offset = try unsigned(try field(fields, ":offset"));
        const change = try enumValue(LogChange, try field(fields, ":change"));
        const state = try enumValue(LogState, try field(fields, ":state"));
        const path = try allocator.dupe(u8, try pathField(fields));
        errdefer allocator.free(path);
        const text = try allocator.dupe(u8, try textField(fields, max_preview_bytes));
        return .{ .log = .{ .path = path, .text = text, .device = device, .inode = inode, .offset = offset, .change = change, .state = state } };
    }
    if (std.mem.eql(u8, head, "stub-file-directory")) {
        if (fields.len != 4) return error.InvalidFormat;
        const path_text = try pathField(fields);
        const items = try list(try field(fields, ":entries"));
        if (items.len > max_entries) return error.InvalidFormat;
        var total_path_bytes: usize = path_text.len;
        const entries = try allocator.alloc(Entry, items.len);
        var done: usize = 0;
        errdefer {
            for (entries[0..done]) |entry| allocator.free(entry.path);
            allocator.free(entries);
        }
        for (items, 0..) |item, index| {
            const parts = try list(item);
            if (parts.len != 3) return error.InvalidFormat;
            const kind = try enumValue(Kind, parts[0]);
            const entry_path = try string(parts[1]);
            if (!validPath(entry_path)) return error.InvalidFormat;
            total_path_bytes += entry_path.len;
            if (total_path_bytes > max_entry_path_bytes) return error.InvalidFormat;
            const bytes = try unsigned(parts[2]);
            entries[index] = .{ .path = try allocator.dupe(u8, entry_path), .kind = kind, .bytes = bytes };
            done += 1;
        }
        const path = try allocator.dupe(u8, path_text);
        return .{ .directory = .{ .path = path, .entries = entries } };
    }
    if (std.mem.eql(u8, head, "stub-file-assets")) {
        if (fields.len != 2) return error.InvalidFormat;
        const items = try list(try field(fields, ":entries"));
        if (items.len == 0 or items.len > max_assets) return error.InvalidFormat;
        const checks = try allocator.alloc(AssetCheck, items.len);
        var done: usize = 0;
        errdefer {
            for (checks[0..done]) |check| allocator.free(check.name);
            allocator.free(checks);
        }
        for (items, 0..) |item, index| {
            const parts = try list(item);
            if (parts.len != 2) return error.InvalidFormat;
            const status = try enumValue(AssetStatus, parts[0]);
            const name = try string(parts[1]);
            if (name.len == 0 or !validText(name, 1024)) return error.InvalidFormat;
            checks[index] = .{ .name = try allocator.dupe(u8, name), .status = status };
            done += 1;
        }
        return .{ .assets = checks };
    }
    if (std.mem.eql(u8, head, "stub-file-reject")) {
        if (fields.len != 4) return error.InvalidFormat;
        const kind = try enumValue(ErrorKind, try field(fields, ":kind"));
        const detail = try string(try field(fields, ":detail"));
        if (!validText(detail, 4096)) return error.InvalidFormat;
        if (kind == .canceled and detail.len != 0) return error.InvalidFormat;
        return .{ .reject = .{ .kind = kind, .detail = try allocator.dupe(u8, detail) } };
    }
    return error.InvalidFormat;
}

test "asset stubs keep ordered name and status pairs" {
    var reader = sexpr.Reader.init(std.testing.allocator, "(stub-file-assets \"asset-verify\" :entries ((ok \"avatars/maya.png\") (missing \"glyphs/λ.png\")))");
    const expr = try reader.readOne();
    defer expr.deinit(std.testing.allocator);
    const items = expr.value.list;
    const fixture = try parse(std.testing.allocator, try symbol(items[0]), items[1..]);
    defer std.testing.allocator.free(fixture.label);
    defer fixture.stub.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), fixture.stub.assets.len);
    try std.testing.expectEqualStrings("glyphs/λ.png", fixture.stub.assets[1].name);
    try std.testing.expectEqual(AssetStatus.missing, fixture.stub.assets[1].status);
}

test "read stubs keep exact UTF-8 text and are keyed by path" {
    var reader = sexpr.Reader.init(std.testing.allocator, "(stub-file-read \"notes-read\" :text \"a\\nλ:\\\"\" :path \"/tmp/λ.txt\")");
    const expr = try reader.readOne();
    defer expr.deinit(std.testing.allocator);
    const items = expr.value.list;
    const fixture = try parse(std.testing.allocator, try symbol(items[0]), items[1..]);
    defer std.testing.allocator.free(fixture.label);
    defer fixture.stub.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("a\nλ:\"", fixture.stub.read.text);
    try std.testing.expectEqualStrings("/tmp/λ.txt", fixture.stub.key().?);
    const copy = try fixture.stub.dupe(std.testing.allocator);
    defer copy.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(fixture.stub.read.text, copy.read.text);
}
