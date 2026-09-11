//! `stub-file-*` forms declare typed answers for the hosted `Files` primitives
//! in the spec host. The leading label is diagnostic; matching uses the
//! primitive and its path. Writes, renames, removals, flushes, and launches
//! need no stub to succeed.
const std = @import("std");
const sexpr = @import("sexpr.zig");

pub const ParseError = error{ InvalidFormat, OutOfMemory, FileNotFound, IoError };

pub const Kind = enum { file, directory, symbolic_link, other };
pub const ErrorKind = enum { not_found, permission_denied, invalid_utf8, invalid_path, resource_limit, io, unavailable };

pub const Entry = struct { path: []const u8, kind: Kind, bytes: u64 };

/// One declared answer. Every string and list is owned by the allocator that
/// parsed or duplicated the stub.
pub const Stub = union(enum) {
    /// `null` is a dismissed dialog; otherwise the chosen path.
    choice: ?[]const u8,
    stat: struct { path: []const u8, kind: Kind, bytes: u64, device: u64, inode: u64 },
    /// The bytes a read returns from `offset` (the whole file when null) and
    /// the size the file reports (the bytes' end when null).
    read: struct { path: []const u8, bytes: []const u8, offset: ?u64, size: ?u64 },
    directory: struct { path: []const u8, entries: []Entry },
    open: []const u8,
    /// Answers the next call of any primitive.
    reject: struct { kind: ErrorKind, detail: []const u8 },

    /// The path the stub is keyed on, or null for stubs that answer any request.
    pub fn key(self: Stub) ?[]const u8 {
        return switch (self) {
            .stat => |stub| stub.path,
            .read => |stub| stub.path,
            .directory => |stub| stub.path,
            .open => |path| path,
            .choice, .reject => null,
        };
    }

    /// Releases every string and list the stub owns.
    pub fn deinit(self: Stub, allocator: std.mem.Allocator) void {
        switch (self) {
            .choice => |path| if (path) |value| allocator.free(value),
            .stat => |stub| allocator.free(stub.path),
            .read => |stub| {
                allocator.free(stub.path);
                allocator.free(stub.bytes);
            },
            .directory => |stub| {
                allocator.free(stub.path);
                for (stub.entries) |entry| allocator.free(entry.path);
                allocator.free(stub.entries);
            },
            .open => |path| allocator.free(path),
            .reject => |stub| allocator.free(stub.detail),
        }
    }

    /// Deep-copies the stub so another owner can keep it.
    pub fn dupe(self: Stub, allocator: std.mem.Allocator) std.mem.Allocator.Error!Stub {
        switch (self) {
            .choice => |path| return .{ .choice = if (path) |value| try allocator.dupe(u8, value) else null },
            .stat => |stub| {
                var copy = stub;
                copy.path = try allocator.dupe(u8, stub.path);
                return .{ .stat = copy };
            },
            .read => |stub| {
                const path = try allocator.dupe(u8, stub.path);
                errdefer allocator.free(path);
                var copy = stub;
                copy.path = path;
                copy.bytes = try allocator.dupe(u8, stub.bytes);
                return .{ .read = copy };
            },
            .directory => |stub| {
                const path = try allocator.dupe(u8, stub.path);
                errdefer allocator.free(path);
                const entries = try dupeEntries(allocator, stub.entries);
                return .{ .directory = .{ .path = path, .entries = entries } };
            },
            .open => |path| return .{ .open = try allocator.dupe(u8, path) },
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
        std.mem.eql(u8, head, "stub-file-stat") or
        std.mem.eql(u8, head, "stub-file-read") or
        std.mem.eql(u8, head, "stub-file-directory") or
        std.mem.eql(u8, head, "stub-file-open") or
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
/// Finds a `:name value` pair; every key may appear at most once.
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
fn optionalUnsigned(items: []const sexpr.Expr, name: []const u8) ParseError!?u64 {
    return if (try field(items, name)) |expr| try unsigned(expr) else null;
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
    const path = try string(try required(items, ":path"));
    if (!validPath(path)) return error.InvalidFormat;
    return path;
}

const max_read_bytes = 32 * 1024 * 1024;
const max_entries = 10_000;
const max_entry_path_bytes = 4 * 1024 * 1024;

/// Reads the bytes a `:file` stub refers to, relative to the spec's folder.
fn loadFile(allocator: std.mem.Allocator, base_dir: []const u8, relative: []const u8) ParseError![]u8 {
    const path = if (base_dir.len == 0 or std.fs.path.isAbsolute(relative)) try allocator.dupe(u8, relative) else try std.fs.path.join(allocator, &.{ base_dir, relative });
    defer allocator.free(path);
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_read_bytes)) catch |err| switch (err) {
        error.FileNotFound => error.FileNotFound,
        error.OutOfMemory => error.OutOfMemory,
        else => error.IoError,
    };
}

/// Parses a fixture into an owned typed stub. `base_dir` resolves a read
/// stub's `:file`. Failure releases every provisional allocation.
pub fn parse(allocator: std.mem.Allocator, base_dir: []const u8, head: []const u8, args: []const sexpr.Expr) ParseError!Fixture {
    if (args.len < 2) return error.InvalidFormat;
    const label_text = try string(args[0]);
    if (label_text.len == 0 or !validText(label_text, 4096)) return error.InvalidFormat;
    const stub = try parseStub(allocator, base_dir, head, args[1..]);
    errdefer stub.deinit(allocator);
    const label = try allocator.dupe(u8, label_text);
    return .{ .label = label, .stub = stub };
}

fn parseStub(allocator: std.mem.Allocator, base_dir: []const u8, head: []const u8, fields: []const sexpr.Expr) ParseError!Stub {
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
    if (std.mem.eql(u8, head, "stub-file-stat")) {
        const kind = try enumValue(Kind, try required(fields, ":kind"));
        const bytes = try unsigned(try required(fields, ":bytes"));
        const device = (try optionalUnsigned(fields, ":device")) orelse 0;
        const inode = (try optionalUnsigned(fields, ":inode")) orelse 0;
        const expected: usize = 6 + 2 * @as(usize, @intFromBool((try field(fields, ":device")) != null)) + 2 * @as(usize, @intFromBool((try field(fields, ":inode")) != null));
        if (fields.len != expected) return error.InvalidFormat;
        return .{ .stat = .{ .path = try allocator.dupe(u8, try pathField(fields)), .kind = kind, .bytes = bytes, .device = device, .inode = inode } };
    }
    if (std.mem.eql(u8, head, "stub-file-read")) {
        const text = try field(fields, ":text");
        const file = try field(fields, ":file");
        if ((text == null) == (file == null)) return error.InvalidFormat;
        const offset = try optionalUnsigned(fields, ":offset");
        const size = try optionalUnsigned(fields, ":size");
        const expected: usize = 4 + 2 * @as(usize, @intFromBool(offset != null)) + 2 * @as(usize, @intFromBool(size != null));
        if (fields.len != expected) return error.InvalidFormat;
        const path_text = try pathField(fields);
        const bytes = if (text) |expr| blk: {
            const value = try string(expr);
            if (!validText(value, max_read_bytes)) return error.InvalidFormat;
            break :blk try allocator.dupe(u8, value);
        } else try loadFile(allocator, base_dir, try string(file.?));
        errdefer allocator.free(bytes);
        if (size) |declared| if (declared < (offset orelse 0) + bytes.len) return error.InvalidFormat;
        const path = try allocator.dupe(u8, path_text);
        return .{ .read = .{ .path = path, .bytes = bytes, .offset = offset, .size = size } };
    }
    if (std.mem.eql(u8, head, "stub-file-open")) {
        if (fields.len != 2) return error.InvalidFormat;
        return .{ .open = try allocator.dupe(u8, try pathField(fields)) };
    }
    if (std.mem.eql(u8, head, "stub-file-directory")) {
        if (fields.len != 4) return error.InvalidFormat;
        const path_text = try pathField(fields);
        const items = try list(try required(fields, ":entries"));
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
    if (std.mem.eql(u8, head, "stub-file-reject")) {
        if (fields.len != 4) return error.InvalidFormat;
        const kind = try enumValue(ErrorKind, try required(fields, ":kind"));
        const detail = try string(try required(fields, ":detail"));
        if (!validText(detail, 4096)) return error.InvalidFormat;
        return .{ .reject = .{ .kind = kind, .detail = try allocator.dupe(u8, detail) } };
    }
    return error.InvalidFormat;
}

test "read stubs keep exact UTF-8 text and are keyed by path" {
    var reader = sexpr.Reader.init(std.testing.allocator, "(stub-file-read \"notes-read\" :text \"a\\nλ:\\\"\" :path \"/tmp/λ.txt\" :size 40)");
    const expr = try reader.readOne();
    defer expr.deinit(std.testing.allocator);
    const items = expr.value.list;
    const fixture = try parse(std.testing.allocator, "", try symbol(items[0]), items[1..]);
    defer std.testing.allocator.free(fixture.label);
    defer fixture.stub.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("a\nλ:\"", fixture.stub.read.bytes);
    try std.testing.expectEqual(@as(?u64, 40), fixture.stub.read.size);
    try std.testing.expectEqualStrings("/tmp/λ.txt", fixture.stub.key().?);
    const copy = try fixture.stub.dupe(std.testing.allocator);
    defer copy.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(fixture.stub.read.bytes, copy.read.bytes);
}

test "stat stubs default identity fields and refuse unknown kinds" {
    var reader = sexpr.Reader.init(std.testing.allocator, "(stub-file-stat \"log\" :path \"/tmp/log\" :kind file :bytes 12 :inode 7)");
    const expr = try reader.readOne();
    defer expr.deinit(std.testing.allocator);
    const items = expr.value.list;
    const fixture = try parse(std.testing.allocator, "", try symbol(items[0]), items[1..]);
    defer std.testing.allocator.free(fixture.label);
    defer fixture.stub.deinit(std.testing.allocator);
    try std.testing.expectEqual(Kind.file, fixture.stub.stat.kind);
    try std.testing.expectEqual(@as(u64, 0), fixture.stub.stat.device);
    try std.testing.expectEqual(@as(u64, 7), fixture.stub.stat.inode);
    var bad = sexpr.Reader.init(std.testing.allocator, "(stub-file-stat \"log\" :path \"/tmp/log\" :kind socket :bytes 1)");
    const bad_expr = try bad.readOne();
    defer bad_expr.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidFormat, parse(std.testing.allocator, "", try symbol(bad_expr.value.list[0]), bad_expr.value.list[1..]));
}
