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
