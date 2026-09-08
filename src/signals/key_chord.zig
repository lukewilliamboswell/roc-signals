//! Bounded native keyboard filters shared by descriptor ingestion and hosts.
//! Key codes are a protocol vocabulary, independent of any OS key enumeration.
const std = @import("std");

pub const max_per_element = 32;
pub const control: u32 = 1;
pub const shift: u32 = 2;
pub const alt: u32 = 4;
pub const meta: u32 = 8;

pub const Chord = extern struct {
    key: u32,
    modifiers: u32,

    /// Compares a complete key filter, including every modifier bit.
    pub fn eql(self: Chord, other: Chord) bool {
        return self.key == other.key and self.modifiers == other.modifiers;
    }
};

const named_keys = [_][]const u8{
    "Enter",     "Escape",    "Tab",  "Space", "ArrowLeft", "ArrowRight",
    "ArrowUp",   "ArrowDown", "Home", "End",   "PageUp",    "PageDown",
    "Backspace", "Delete",    "F1",   "F2",    "F3",        "F4",
    "F5",        "F6",        "F7",   "F8",    "F9",        "F10",
    "F11",       "F12",
};

/// Parses the documented key vocabulary without allocating or retaining text.
/// Letter keys are lowercase; Shift is an independent exact modifier.
pub fn parse(key: []const u8, modifiers: u32) error{InvalidKeyChord}!Chord {
    if (modifiers > 15) return error.InvalidKeyChord;
    if (key.len == 1 and (std.ascii.isLower(key[0]) or std.ascii.isDigit(key[0]))) {
        return .{ .key = key[0], .modifiers = modifiers };
    }
    for (named_keys, 0..) |name, index| {
        if (std.mem.eql(u8, key, name)) return .{ .key = @as(u32, @intCast(index)) + 256, .modifiers = modifiers };
    }
    return error.InvalidKeyChord;
}

/// Compares optional filters; an unfiltered event is a distinct binding key.
pub fn optionalEql(left: ?Chord, right: ?Chord) bool {
    if (left) |value| return if (right) |other| value.eql(other) else false;
    return right == null;
}

test "native key chords require canonical keys and exact modifiers" {
    try std.testing.expectEqual(Chord{ .key = 's', .modifiers = control | shift }, try parse("s", control | shift));
    try std.testing.expect(!(try parse("s", control)).eql(try parse("s", control | shift)));
    try std.testing.expectError(error.InvalidKeyChord, parse("S", control));
    try std.testing.expectError(error.InvalidKeyChord, parse("s", 16));
    try std.testing.expectError(error.InvalidKeyChord, parse("ctrl-s", 0));
    try std.testing.expectError(error.InvalidKeyChord, parse("Unknown", 0));
    try std.testing.expectError(error.InvalidKeyChord, parse("", 0));
    for (named_keys, 0..) |name, index| try std.testing.expectEqual(@as(u32, @intCast(index)) + 256, (try parse(name, 0)).key);
    try std.testing.expect(optionalEql(null, null));
    try std.testing.expect(!optionalEql(null, try parse("s", 0)));
}
