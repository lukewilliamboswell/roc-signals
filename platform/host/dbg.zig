//! The bounded text of the `dbg`s one call into Roc ran (design.md, "The
//! Thin Wasm Host"). It lives in static storage and never allocates. The
//! newest entries are kept: when one does not fit, the oldest whole entries
//! are dropped until the new one leaves half the buffer free, and counted, so what survives
//! is the text nearest the end of the call, which is the text nearest a trap.
const std = @import("std");

/// A buffer of at most `capacity` bytes of entries, each keeping at most
/// `entry_max` bytes of its text.
pub fn Buffer(comptime capacity: usize, comptime entry_max: usize) type {
    if (2 * (8 + entry_max) > capacity) @compileError("dbg capacity must hold two maximum-size entries");
    return struct {
        const Self = @This();

        /// What the runtime reads: `dropped:u32`, then the kept entries,
        /// oldest first, each `len:u32 kept:u32 text:kept`, where `len` is
        /// the text's full length.
        region: [4 + capacity]u8 align(4) = undefined,

        /// The bytes of entries held after the `dropped` word.
        used: usize = 0,

        /// The entries dropped since clear, saturating at U32 max rather than
        /// wrapping. Consumers report the saturated value as a lower bound.
        dropped: u32 = 0,

        /// Forget everything: the host calls this before each call into Roc.
        pub fn clear(self: *Self) void {
            self.used = 0;
            self.dropped = 0;
        }

        /// Keep one `dbg`'s text. It never fails: text beyond the bounds is
        /// dropped and counted, and an entry is cut at a code point.
        pub fn append(self: *Self, bytes: []const u8) void {
            const kept = cut(bytes, entry_max);
            const need = 8 + kept;
            const entries = self.region[4..];
            if (self.used + need > capacity) {
                var from: usize = 0;
                while (self.used - from + need > capacity / 2 and from < self.used) {
                    from += 8 + std.mem.readInt(u32, entries[from + 4 ..][0..4], .little);
                    self.dropped +|= 1;
                }
                std.mem.copyForwards(u8, entries[0 .. self.used - from], entries[from..self.used]);
                self.used -= from;
            }
            std.mem.writeInt(u32, entries[self.used..][0..4], @truncate(bytes.len), .little);
            std.mem.writeInt(u32, entries[self.used + 4 ..][0..4], @intCast(kept), .little);
            @memcpy(entries[self.used + 8 ..][0..kept], bytes[0..kept]);
            self.used += need;
            std.mem.writeInt(u32, self.region[0..4], self.dropped, .little);
        }

        /// The length of `region` that holds text: 0 when nothing was kept.
        pub fn len(self: *const Self) usize {
            return if (self.used == 0) 0 else 4 + self.used;
        }
    };
}

/// The longest prefix of `bytes`, at most `max` bytes, that does not end
/// inside a code point.
fn cut(bytes: []const u8, max: usize) usize {
    if (bytes.len <= max) return bytes.len;
    var n = max;
    while (n > 0 and (bytes[n] & 0xC0) == 0x80) n -= 1;
    return n;
}

const Small = Buffer(64, 16);

fn entryAt(b: *const Small, at: usize) struct { len: u32, text: []const u8, next: usize } {
    const e = b.region[4..];
    const kept = std.mem.readInt(u32, e[at + 4 ..][0..4], .little);
    return .{ .len = std.mem.readInt(u32, e[at..][0..4], .little), .text = e[at + 8 ..][0..kept], .next = at + 8 + kept };
}

test "entries are kept in order with their lengths, and an empty buffer has length 0" {
    var b: Small = .{};
    try std.testing.expectEqual(@as(usize, 0), b.len());
    b.append("one");
    b.append("three");
    try std.testing.expectEqual(@as(usize, 4 + 8 + 3 + 8 + 5), b.len());
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, b.region[0..4], .little));
    const first = entryAt(&b, 0);
    try std.testing.expectEqualStrings("one", first.text);
    try std.testing.expectEqual(@as(u32, 3), first.len);
    try std.testing.expectEqualStrings("three", entryAt(&b, first.next).text);
}

test "an entry that does not fit drops the oldest whole entries until half is free, and counts them" {
    var b: Small = .{};
    // Five entries of 12 bytes fill 60 of 64; the sixth does not fit.
    for ([_][]const u8{ "aaaa", "bbbb", "cccc", "dddd", "eeee" }) |t| b.append(t);
    try std.testing.expectEqual(@as(usize, 60), b.used);
    b.append("ffff");
    // Dropped until the new entry leaves half the buffer free: one stays.
    try std.testing.expectEqual(@as(u32, 4), b.dropped);
    try std.testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, b.region[0..4], .little));
    try std.testing.expectEqual(@as(usize, 24), b.used);
    const first = entryAt(&b, 0);
    try std.testing.expectEqualStrings("eeee", first.text);
    try std.testing.expectEqualStrings("ffff", entryAt(&b, first.next).text);
    // The next two fit without a drop.
    b.append("gggg");
    b.append("hhhh");
    try std.testing.expectEqual(@as(u32, 4), b.dropped);
    try std.testing.expectEqual(@as(usize, 48), b.used);
}

test "a long entry keeps its full length and is cut at a code point" {
    var b: Small = .{};
    // 'a', then two-byte code points: byte 16 is a continuation byte.
    b.append("a\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9");
    const e = entryAt(&b, 0);
    try std.testing.expectEqual(@as(u32, 19), e.len);
    try std.testing.expectEqual(@as(usize, 15), e.text.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(e.text));
    // A four-byte code point straddling the bound is left out whole.
    b.clear();
    b.append("0123456789abcd\xf0\x9f\x98\x80z");
    try std.testing.expectEqual(@as(usize, 14), entryAt(&b, 0).text.len);
    // ASCII is cut at the bound exactly.
    b.clear();
    b.append("0123456789abcdefXYZ");
    try std.testing.expectEqualStrings("0123456789abcdef", entryAt(&b, 0).text);
}

test "clear forgets the entries and the count" {
    var b: Small = .{};
    for (0..9) |_| b.append("0123456789");
    try std.testing.expect(b.dropped > 0);
    b.clear();
    try std.testing.expectEqual(@as(usize, 0), b.len());
    try std.testing.expectEqual(@as(u32, 0), b.dropped);
    b.append("x");
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, b.region[0..4], .little));
}


test "empty text is an entry and dropped count saturates without wrapping" {
    var b: Small = .{};
    b.append("");
    try std.testing.expectEqual(@as(usize, 12), b.len());
    try std.testing.expectEqual(@as(u32, 0), entryAt(&b, 0).len);
    try std.testing.expectEqualStrings("", entryAt(&b, 0).text);
    b.clear();
    for (0..5) |_| b.append("1234");
    b.dropped = std.math.maxInt(u32) - 1;
    b.append("drop");
    try std.testing.expectEqual(std.math.maxInt(u32), b.dropped);
    try std.testing.expectEqual(std.math.maxInt(u32), std.mem.readInt(u32, b.region[0..4], .little));
}

test "a four-byte scalar ending exactly at the bound remains whole" {
    var b: Small = .{};
    b.append("0123456789ab\xf0\x9f\x98\x80tail");
    const entry = entryAt(&b, 0);
    try std.testing.expectEqual(@as(usize, 16), entry.text.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(entry.text));
}
