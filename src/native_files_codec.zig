//! Strict framing at the native Files publication boundary. Service routing is
//! an explicit TaskKind; this codec never interprets diagnostic task names.
const std = @import("std");

pub const max_payload_bytes = 8 * 1024 * 1024;

/// Validates one complete files1 request before its host reservation is
/// published. The task kind supplies the exact number of argument frames;
/// filesystem path validity and I/O failures remain typed operation results.
pub fn validateRequest(payload: []const u8, argument_count: usize) error{InvalidFilesRequest}!void {
    if (payload.len > max_payload_bytes) return error.InvalidFilesRequest;
    var rest = payload;
    if (!std.mem.eql(u8, try frame(&rest), "files1")) return error.InvalidFilesRequest;
    for (0..argument_count) |_| _ = try frame(&rest);
    if (rest.len != 0) return error.InvalidFilesRequest;
}

/// Validates the read-log position discriminant and canonical cursor fields
/// before publication. Start/End carry a zero cursor; After carries caller-owned
/// device, inode and byte offset. Filesystem validity remains a typed result.
pub fn validateLogRequest(payload: []const u8) error{InvalidFilesRequest}!void {
    try validateRequest(payload, 5);
    var rest = payload;
    _ = try frame(&rest);
    _ = try frame(&rest);
    const position = try frame(&rest);
    var cursor: [3]u64 = undefined;
    for (&cursor) |*value| {
        const text = try frame(&rest);
        if (text.len == 0 or (text.len > 1 and text[0] == '0')) return error.InvalidFilesRequest;
        for (text) |byte| if (byte < '0' or byte > '9') return error.InvalidFilesRequest;
        value.* = std.fmt.parseInt(u64, text, 10) catch return error.InvalidFilesRequest;
    }
    if (std.mem.eql(u8, position, "after")) return;
    if (!std.mem.eql(u8, position, "start") and !std.mem.eql(u8, position, "end")) return error.InvalidFilesRequest;
    for (cursor) |value| if (value != 0) return error.InvalidFilesRequest;
}

pub const max_manifest_assets = 256;
pub const max_asset_name_bytes = 1024;

/// Validates one complete asset-verification request before publication: a
/// canonical asset count, then per-asset relative name and lowercase hex
/// sha256 frames. Path containment and hashing remain typed operation results.
pub fn validateAssetsRequest(payload: []const u8) error{InvalidFilesRequest}!void {
    if (payload.len > max_payload_bytes) return error.InvalidFilesRequest;
    var rest = payload;
    if (!std.mem.eql(u8, try frame(&rest), "files1")) return error.InvalidFilesRequest;
    const count_text = try frame(&rest);
    if (count_text.len == 0 or (count_text.len > 1 and count_text[0] == '0')) return error.InvalidFilesRequest;
    for (count_text) |byte| if (byte < '0' or byte > '9') return error.InvalidFilesRequest;
    const count = std.fmt.parseInt(usize, count_text, 10) catch return error.InvalidFilesRequest;
    if (count == 0 or count > max_manifest_assets) return error.InvalidFilesRequest;
    for (0..count) |_| {
        const name = try frame(&rest);
        if (name.len == 0 or name.len > max_asset_name_bytes) return error.InvalidFilesRequest;
        const digest = try frame(&rest);
        if (digest.len != 64) return error.InvalidFilesRequest;
        for (digest) |byte| {
            const hex = (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f');
            if (!hex) return error.InvalidFilesRequest;
        }
    }
    if (rest.len != 0) return error.InvalidFilesRequest;
}

fn frame(rest: *[]const u8) error{InvalidFilesRequest}![]const u8 {
    const end = std.mem.indexOfScalar(u8, rest.*, ':') orelse return error.InvalidFilesRequest;
    const length = rest.*[0..end];
    if (length.len == 0 or (length.len > 1 and length[0] == '0')) return error.InvalidFilesRequest;
    for (length) |byte| if (byte < '0' or byte > '9') return error.InvalidFilesRequest;
    const count = std.fmt.parseInt(usize, length, 10) catch return error.InvalidFilesRequest;
    const tail = rest.*[end + 1 ..];
    if (count > tail.len) return error.InvalidFilesRequest;
    const value = tail[0..count];
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidFilesRequest;
    rest.* = tail[count..];
    return value;
}

test "native asset verification requests are strictly framed and bounded" {
    const digest = "a" ** 64;
    try validateAssetsRequest("6:files11:115:avatars/one.png64:" ++ digest);
    for ([_][]const u8{
        "6:files11:0", // zero assets
        "6:files12:011:x64:" ++ digest, // noncanonical count
        "6:files11:11:x63:" ++ digest[0..63], // short digest
        "6:files11:11:x64:" ++ ("A" ** 64), // uppercase hex
        "6:files11:21:x64:" ++ digest, // truncated entry list
        "6:files11:11:x64:" ++ digest ++ "1:y", // trailing frame
    }) |payload| try std.testing.expectError(error.InvalidFilesRequest, validateAssetsRequest(payload));
}

test "native Files requests preserve UTF-8 and arbitrary file text" {
    try validateRequest("6:files1", 0);
    try validateRequest("6:files17:/tmp/λ5:a:\n\x00b", 2);
    try validateRequest("6:files10:", 1);
}

test "native Files publication rejects malformed or extra frames" {
    for ([_][]const u8{ "", "06:files1", "6:files1", "6:files1+1:x", "6:files11:λ", "6:files11:x0:", "6:files118446744073709551616:x", "6:files11:\xff" }) |payload| {
        try std.testing.expectError(error.InvalidFilesRequest, validateRequest(payload, 1));
    }
}

test "native log cursor requests reject invalid positions before publication" {
    try validateLogRequest("6:files18:/tmp/log5:start1:01:01:0");
    try validateLogRequest("6:files18:/tmp/log5:after1:11:220:18446744073709551615");
    for ([_][]const u8{
        "6:files18:/tmp/log5:start1:11:01:0",
        "6:files18:/tmp/log3:end1:01:01:1",
        "6:files18:/tmp/log5:after2:011:01:0",
        "6:files18:/tmp/log5:after1:01:020:18446744073709551616",
        "6:files18:/tmp/log6:middle1:01:01:0",
    }) |payload| try std.testing.expectError(error.InvalidFilesRequest, validateLogRequest(payload));
}
