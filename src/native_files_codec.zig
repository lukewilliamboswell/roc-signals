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
