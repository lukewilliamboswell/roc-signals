//! Versioned native presentation record carried by the native_style scalar field.
//! This is a boundary codec, independent of Roc value layouts and browser CSS.
const std = @import("std");

pub const version: u32 = 1;
pub const default_color: u32 = 0x1000000;
pub const max_dimension: u32 = 16384;

/// Process-local C layout exported only after the serialized descriptor validates.
/// Numeric enum discriminants are defined by the native presentation protocol.
pub const Style = extern struct {
    direction: u32 = 1,
    gap: u32 = 8,
    padding: u32 = 0,
    width_kind: u32 = 0,
    width: u32 = 0,
    height_kind: u32 = 0,
    height: u32 = 0,
    grow: u32 = 0,
    background: u32 = default_color,
    foreground: u32 = default_color,
    border_color: u32 = default_color,
    border_width: u32 = 0,
    radius: u32 = 0,
    font_size: u32 = 0,
    overflow_x: u32 = 0,
    overflow_y: u32 = 0,
};

pub const DecodeError = error{InvalidNativeStyle};

/// Decodes the exact v1 decimal record without allocation. Noncanonical numbers,
/// unknown enum values, excessive dimensions, and extra fields are rejected.
pub fn decode(bytes: []const u8) DecodeError!Style {
    if (bytes.len > 192) return error.InvalidNativeStyle;
    var fields = std.mem.splitScalar(u8, bytes, ',');
    if (try number(fields.next()) != version) return error.InvalidNativeStyle;
    var style: Style = undefined;
    inline for (std.meta.fields(Style)) |field| @field(style, field.name) = try number(fields.next());
    if (fields.next() != null) return error.InvalidNativeStyle;
    if (style.direction > 1 or style.width_kind > 2 or style.height_kind > 2 or style.grow > 1 or style.overflow_x > 2 or style.overflow_y > 2) return error.InvalidNativeStyle;
    inline for (.{ "gap", "padding", "width", "height", "border_width", "radius", "font_size" }) |field| if (@field(style, field) > max_dimension) return error.InvalidNativeStyle;
    if ((style.width_kind != 2 and style.width != 0) or (style.height_kind != 2 and style.height != 0)) return error.InvalidNativeStyle;
    inline for (.{ "background", "foreground", "border_color" }) |field| if (@field(style, field) > default_color) return error.InvalidNativeStyle;
    return style;
}

fn number(field: ?[]const u8) DecodeError!u32 {
    const bytes = field orelse return error.InvalidNativeStyle;
    if (bytes.len == 0 or (bytes.len > 1 and bytes[0] == '0')) return error.InvalidNativeStyle;
    for (bytes) |byte| if (byte < '0' or byte > '9') return error.InvalidNativeStyle;
    return std.fmt.parseInt(u32, bytes, 10) catch error.InvalidNativeStyle;
}

test "native style decodes the public default and explicit presentation" {
    try std.testing.expectEqualDeep(Style{}, try decode("1,1,8,0,0,0,0,0,0,16777216,16777216,16777216,0,0,0,0,0"));
    const style = try decode("1,0,12,16,1,0,2,120,1,1193046,16777215,0,1,8,18,0,2");
    try std.testing.expectEqual(@as(u32, 0), style.direction);
    try std.testing.expectEqual(@as(u32, 120), style.height);
    try std.testing.expectEqual(@as(u32, 0x123456), style.background);
    try std.testing.expectEqual(@as(u32, 2), style.overflow_y);
}

test "native style refuses unknown versions malformed records and invalid values" {
    for ([_][]const u8{
        "",                                                       "1",                                                          "2,1,8,0,0,0,0,0,0,16777216,16777216,16777216,0,0,0,0,0",
        "1,2,8,0,0,0,0,0,0,16777216,16777216,16777216,0,0,0,0,0", "1,1,08,0,0,0,0,0,0,16777216,16777216,16777216,0,0,0,0,0",    "1,1,8,0,0,1,0,0,0,16777216,16777216,16777216,0,0,0,0,0",
        "1,1,8,0,0,0,0,0,0,16777217,16777216,16777216,0,0,0,0,0", "1,1,8,16385,0,0,0,0,0,16777216,16777216,16777216,0,0,0,0,0", "1,1,8,0,0,0,0,0,0,16777216,16777216,16777216,0,0,0,0,0,0",
    }) |bytes| try std.testing.expectError(error.InvalidNativeStyle, decode(bytes));
}

/// Fixed-height virtual rows. This independent v1 field leaves ordinary style
/// replacement independent of viewport behavior and follow-tail updates.
pub const Viewport = extern struct { row_height: u32 = 0, follow_tail: u32 = 0 };

/// Validates the entire virtual-list record before native publication. A zero
/// row height is reserved for absent viewport metadata in the C node view.
pub fn decodeViewport(bytes: []const u8) DecodeError!Viewport {
    if (bytes.len > 32) return error.InvalidNativeStyle;
    var fields = std.mem.splitScalar(u8, bytes, ',');
    if (try number(fields.next()) != 1) return error.InvalidNativeStyle;
    const value = Viewport{ .row_height = try number(fields.next()), .follow_tail = try number(fields.next()) };
    if (fields.next() != null or value.row_height == 0 or value.row_height > max_dimension or value.follow_tail > 1) return error.InvalidNativeStyle;
    return value;
}

/// Host-enforced embedded font bounds. These are protocol constants shared by
/// every native adapter; a declaration outside them is rejected before any
/// text-system registration.
pub const max_fonts: usize = 8;
pub const max_font_bytes: usize = 8 * 1024 * 1024;
pub const max_font_family_bytes: usize = 128;

/// Validates the complete v1 embedded-font declaration without allocating.
/// The record is newline-delimited: a "1" version line, then one family line
/// and one standard-base64 data line per font. Returns the font count.
pub fn validateFontDeclaration(bytes: []const u8) DecodeError!usize {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const head = lines.next() orelse return error.InvalidNativeStyle;
    if (!std.mem.eql(u8, head, "1")) return error.InvalidNativeStyle;
    var count: usize = 0;
    while (lines.next()) |family| {
        const data = lines.next() orelse return error.InvalidNativeStyle;
        if (family.len == 0 or family.len > max_font_family_bytes) return error.InvalidNativeStyle;
        for (family) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidNativeStyle;
        _ = try fontDataSize(data);
        count += 1;
        if (count > max_fonts) return error.InvalidNativeStyle;
    }
    if (count == 0) return error.InvalidNativeStyle;
    return count;
}

/// Validates one standard-base64 data line and returns its decoded byte size.
pub fn fontDataSize(data: []const u8) DecodeError!usize {
    if (data.len == 0 or data.len % 4 != 0) return error.InvalidNativeStyle;
    var padding: usize = 0;
    if (data[data.len - 1] == '=') padding += 1;
    if (data.len >= 2 and data[data.len - 2] == '=') padding += 1;
    for (data[0 .. data.len - padding]) |byte| {
        const valid = (byte >= 'A' and byte <= 'Z') or (byte >= 'a' and byte <= 'z') or
            (byte >= '0' and byte <= '9') or byte == '+' or byte == '/';
        if (!valid) return error.InvalidNativeStyle;
    }
    const size = data.len / 4 * 3 - padding;
    if (size == 0 or size > max_font_bytes) return error.InvalidNativeStyle;
    return size;
}

test "font declarations validate structure bounds and base64 payloads" {
    try std.testing.expectEqual(@as(usize, 1), try validateFontDeclaration("1\nSource Code Pro\nAAAA"));
    try std.testing.expectEqual(@as(usize, 2), try validateFontDeclaration("1\nMono A\nAAECAw==\nMono B\nBQY="));
    try std.testing.expectEqual(@as(usize, 3), try fontDataSize("AAAA"));
    // Nine fonts exceed the host bound of eight.
    const nine = "1" ++ ("\nf\nAAAA" ** 9);
    try std.testing.expectError(error.InvalidNativeStyle, validateFontDeclaration(nine));
    const eight = "1" ++ ("\nf\nAAAA" ** 8);
    try std.testing.expectEqual(@as(usize, 8), try validateFontDeclaration(eight));
    for ([_][]const u8{
        "", "1", "2\nf\nAAAA", "1\nf", "1\n\nAAAA", "1\nf\n", "1\nf\nAAA", "1\nf\nA?AA", "1\nf\n====", "1\nf\nAAAA\n",
    }) |bytes| try std.testing.expectError(error.InvalidNativeStyle, validateFontDeclaration(bytes));
}

test "font data size enforces the eight-mebibyte decoded bound" {
    const allocator = std.testing.allocator;
    // 8 MiB decodes exactly at the bound; one more block exceeds it.
    const at_bound = try allocator.alloc(u8, max_font_bytes / 3 * 4);
    defer allocator.free(at_bound);
    @memset(at_bound, 'A');
    try std.testing.expectEqual(max_font_bytes - 1, (try fontDataSize(at_bound)) + 1);
    const over = try allocator.alloc(u8, (max_font_bytes / 3 + 1) * 4);
    defer allocator.free(over);
    @memset(over, 'A');
    try std.testing.expectError(error.InvalidNativeStyle, fontDataSize(over));
}

test "native viewport rejects malformed size and follow-tail contracts" {
    try std.testing.expectEqualDeep(Viewport{ .row_height = 48, .follow_tail = 1 }, try decodeViewport("1,48,1"));
    for ([_][]const u8{ "1,0,0", "1,16385,0", "1,48,2", "2,48,1", "1,048,1", "1,48,1,0" }) |bytes| try std.testing.expectError(error.InvalidNativeStyle, decodeViewport(bytes));
}
