//! Stable identities used by the Roc-native `Rows` runtime.
//!
//! Both site and row identities use a one-based 32-bit slot index and a
//! nonzero 32-bit generation. Slots advance their generation before reuse and
//! retire permanently at saturation, so a stale identity can never name a
//! later lifetime.

const std = @import("std");

const index_bits = 32;
const max_slot_count: usize = std.math.maxInt(u32);

fn Identity(comptime name: []const u8) type {
    return enum(u64) {
        _,

        /// Returns the packed representation used by engine-owned tables.
        pub fn raw(self: @This()) u64 {
            return @intFromEnum(self);
        }

        /// Reconstructs an identity from a representation validated by its
        /// owning registry.
        pub fn fromRaw(value: u64) @This() {
            return @enumFromInt(value);
        }

        /// Packs validated registry fields into a stable identity.
        pub fn init(slot_index: usize, slot_generation: u32) @This() {
            if (slot_generation == 0 or slot_index >= max_slot_count) {
                @panic("invalid " ++ name ++ " identity fields");
            }
            const one_based_index: u32 = @intCast(slot_index + 1);
            return @enumFromInt((@as(u64, slot_generation) << index_bits) | one_based_index);
        }

        /// Returns the generation checked by the owning slot registry.
        pub fn generation(self: @This()) u32 {
            return @truncate(self.raw() >> index_bits);
        }

        /// Decodes the zero-based slot index, rejecting zero identity fields.
        pub fn slotIndex(self: @This()) ?usize {
            const one_based_index: u32 = @truncate(self.raw());
            if (one_based_index == 0 or self.generation() == 0) return null;
            return @as(usize, one_based_index - 1);
        }
    };
}

/// Identity of one live `Ui.each` Rows site.
pub const SiteId = Identity("Rows site");

/// Identity of one live row and its row-local scope.
pub const RowId = Identity("Rows row");

/// Opaque generation identity supplied by the app-compiled Rows owner.
pub const OwnerToken = enum(u64) {
    _,

    /// Creates a token from a nonzero authenticated host representation.
    pub fn fromRaw(value: u64) error{InvalidOwnerToken}!OwnerToken {
        if (value == 0) return error.InvalidOwnerToken;
        return @enumFromInt(value);
    }

    /// Returns the host representation without interpreting collection data.
    pub fn raw(self: OwnerToken) u64 {
        return @intFromEnum(self);
    }
};

test "Rows identities encode independent nominal kinds" {
    const site = SiteId.init(0, 1);
    const row = RowId.init(0, 1);
    try std.testing.expectEqual(@as(u64, 0x0000_0001_0000_0001), site.raw());
    try std.testing.expectEqual(@as(u64, 0x0000_0001_0000_0001), row.raw());
    try std.testing.expect(@TypeOf(site) != @TypeOf(row));
}

test "Rows identities reject zero fields during registry decoding" {
    try std.testing.expect(SiteId.fromRaw(0).slotIndex() == null);
    try std.testing.expect(RowId.fromRaw(1).slotIndex() == null);
    try std.testing.expect(RowId.fromRaw(@as(u64, 1) << 32).slotIndex() == null);
    try std.testing.expectError(error.InvalidOwnerToken, OwnerToken.fromRaw(0));
}
