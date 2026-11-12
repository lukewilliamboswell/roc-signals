//! Host-owned resources that Roc holds through its own reference counts
//! (design.md, "The Thin Wasm Host" and "Files").
//!
//! A handle is a Roc value whose allocation is a slot of a fixed table in the
//! host's static storage, not an allocation of the host's allocator. Roc
//! increments and decrements the slot's refcount like any other, and when the
//! last reference goes it calls `roc_dealloc` with the slot's address. The
//! host's `roc_dealloc` offers every address to its heaps first (two compares
//! per heap, no scan), and a heap that owns the address retires the slot
//! instead of freeing it. The scheme follows roc-ray's `HostResourceHeap`.
//!
//! The handles here are **blobs** (`BlobHeap`): file handles, Roc
//! `Box(U64)` values whose payload is a token naming a browser `Blob` the
//! JavaScript runtime holds. The host holds only the token. A slot whose last
//! reference went is *retired*: it stays reserved, and its token is listed for
//! the runtime, until the runtime has performed the batch's effects and
//! drained the list. So a token named by a command in the same batch still
//! resolves, and a drop during a Roc call never reaches JavaScript.
//!
//! A slot is `{ pad, rc, token }`, the token at offset 8 and the refcount in
//! the `usize` just before it, which is where Roc keeps the refcount of a
//! `Box(U64)` on both wasm32 and x86_64. Roc frees a `Box(U64)` at its
//! payload minus 8 (the payload's alignment). The layout is pinned by the
//! tests below and by the ownership probes the specs run in both hosts.
const std = @import("std");

const token_index_bits: u6 = 16;
const token_kind_bits: u6 = 8;
const token_generation_shift: u6 = token_index_bits + token_kind_bits;
const token_index_mask: u64 = (@as(u64, 1) << token_index_bits) - 1;
const token_kind_mask: u64 = (@as(u64, 1) << token_kind_bits) - 1;
const max_generation: u64 = std.math.maxInt(u64) >> token_generation_shift;

/// The kinds of handle, and the byte their tokens carry, so a token of one
/// kind never resolves in a heap of another. Zero is reserved: it is never a
/// token.
pub const Kind = enum(u8) { blob = 1 };

/// What a heap made of an address `roc_dealloc` offered it.
pub const Route = enum { not_owned, retired, corrupt };

/// One slot as Roc sees it: the refcount in the `usize` before the token.
pub const Slot = extern struct {
    pad: [8 - @sizeOf(usize)]u8,
    rc: isize,
    token: u64,

    comptime {
        if (@offsetOf(Slot, "token") != 8) @compileError("a slot's token must sit at offset 8");
        if (@offsetOf(Slot, "rc") + @sizeOf(isize) != 8) @compileError("a slot's refcount must sit just before its token");
    }
};

/// Where Roc frees each kind of handle, as an offset into its slot.
pub fn deallocOffset(comptime kind: Kind) usize {
    return switch (kind) {
        // A `Box(U64)`: its payload minus the payload's alignment.
        .blob => 0,
    };
}

/// A fixed table of `capacity` slots of one kind, each carrying a `T`.
pub fn Heap(comptime kind: Kind, comptime capacity: usize, comptime T: type) type {
    comptime {
        if (capacity == 0 or capacity > token_index_mask) @compileError("bad heap capacity");
    }
    return struct {
        const Self = @This();

        slots: [capacity]Slot align(8) = undefined,
        values: [capacity]T = undefined,
        generations: [capacity]u64 = @splat(0),
        /// Reserved: minted and not yet released (retired slots included).
        live: [capacity]bool = @splat(false),
        /// The last Roc reference went; waiting for `release`.
        retired: [capacity]bool = @splat(false),
        live_count: usize = 0,
        retired_count: usize = 0,

        /// Mint a handle with refcount 1 owning `value`: the pointer Roc
        /// holds (the token's address), or null when every slot is taken.
        pub fn mint(self: *Self, value: T) ?*u64 {
            for (&self.live, 0..) |*is_live, index| {
                if (is_live.*) continue;
                const generation = self.generations[index] +| 1;
                if (generation > max_generation) continue;
                self.generations[index] = generation;
                self.slots[index] = .{ .pad = @splat(0), .rc = 1, .token = encode(index, generation) };
                self.values[index] = value;
                is_live.* = true;
                self.live_count += 1;
                return &self.slots[index].token;
            }
            return null;
        }

        /// Whether `ptr` falls inside this heap's table.
        pub fn contains(self: *const Self, ptr: *const anyopaque) bool {
            const address = @intFromPtr(ptr);
            const start = @intFromPtr(&self.slots[0]);
            return address >= start and address < start + @sizeOf(Slot) * capacity;
        }

        /// Offer an address Roc is freeing. A live slot whose refcount is
        /// spent is retired; an address inside the table that is not such a
        /// slot is corrupt; anything else is not this heap's.
        pub fn route(self: *Self, ptr: *anyopaque) Route {
            if (!self.contains(ptr)) return .not_owned;
            const offset = @intFromPtr(ptr) - @intFromPtr(&self.slots[0]);
            if (offset % @sizeOf(Slot) != comptime deallocOffset(kind)) return .corrupt;
            const index = offset / @sizeOf(Slot);
            if (!self.live[index] or self.retired[index]) return .corrupt;
            if (decode(self.slots[index].token) != index) return .corrupt;
            self.retired[index] = true;
            self.retired_count += 1;
            return .retired;
        }

        /// The value of a live slot named by `token`, or null.
        pub fn get(self: *Self, token: u64) ?*T {
            const index = decode(token) orelse return null;
            if (!self.live[index] or self.slots[index].token != token) return null;
            return &self.values[index];
        }

        /// Free one retired slot for reuse, handing its value to `done`.
        /// Returns whether there was one, and fills `token` with its token.
        pub fn releaseOne(self: *Self, token: *u64, done: anytype) bool {
            if (self.retired_count == 0) return false;
            for (&self.retired, 0..) |*is_retired, index| {
                if (!is_retired.*) continue;
                token.* = self.slots[index].token;
                done(&self.values[index]);
                is_retired.* = false;
                self.live[index] = false;
                self.retired_count -= 1;
                self.live_count -= 1;
                return true;
            }
            return false;
        }

        /// Forget every slot, live or retired, handing each value to `done`:
        /// the instance is gone and no Roc value can reach them.
        pub fn abandon(self: *Self, done: anytype) void {
            for (&self.live, 0..) |*is_live, index| {
                if (!is_live.*) continue;
                done(&self.values[index]);
                is_live.* = false;
                self.retired[index] = false;
            }
            self.live_count = 0;
            self.retired_count = 0;
        }

        fn encode(index: usize, generation: u64) u64 {
            return (generation << token_generation_shift) | (@as(u64, @intFromEnum(kind)) << token_index_bits) | @as(u64, @intCast(index + 1));
        }

        /// The slot index a token of this heap names, or null.
        fn decode(token: u64) ?usize {
            const encoded = token & token_index_mask;
            if (encoded == 0 or encoded > capacity) return null;
            if ((token >> token_index_bits) & token_kind_mask != @intFromEnum(kind)) return null;
            if (token >> token_generation_shift == 0) return null;
            return @intCast(encoded - 1);
        }
    };
}

fn nothing(_: anytype) void {}

/// Roc's layout of a box's refcount relative to its payload.
fn boxBase(payload: *u64) *anyopaque {
    return @ptrFromInt(@intFromPtr(payload) - 8);
}

test "a minted blob has refcount 1 just before its token and routes at payload minus 8" {
    var heap: Heap(.blob, 2, u8) = .{};
    const payload = heap.mint(7).?;
    const rc: *isize = @ptrFromInt(@intFromPtr(payload) - @sizeOf(usize));
    try std.testing.expectEqual(@as(isize, 1), rc.*);
    try std.testing.expect(payload.* != 0);
    try std.testing.expectEqual(@as(u8, 7), heap.get(payload.*).?.*);
    rc.* = 0;
    try std.testing.expectEqual(Route.retired, heap.route(boxBase(payload)));
    // Retired, not yet released: the token still resolves for the batch's
    // effects, and the slot is not handed out again.
    try std.testing.expectEqual(@as(u8, 7), heap.get(payload.*).?.*);
    try std.testing.expect(heap.mint(8) != null);
    try std.testing.expect(heap.mint(9) == null);
}

test "releasing a retired blob frees its slot under a new generation" {
    var heap: Heap(.blob, 1, u8) = .{};
    const payload = heap.mint(1).?;
    const first = payload.*;
    try std.testing.expectEqual(Route.retired, heap.route(boxBase(payload)));
    var token: u64 = 0;
    try std.testing.expect(heap.releaseOne(&token, nothing));
    try std.testing.expectEqual(first, token);
    try std.testing.expect(heap.get(first) == null);
    const again = heap.mint(2).?;
    try std.testing.expect(again.* != first);
    try std.testing.expectEqual(@intFromPtr(payload), @intFromPtr(again));
    try std.testing.expect(!heap.releaseOne(&token, nothing));
}

test "routing refuses foreign, misaligned, double and stale addresses" {
    var heap: Heap(.blob, 2, u8) = .{};
    var foreign: u64 = 0;
    try std.testing.expectEqual(Route.not_owned, heap.route(&foreign));
    const payload = heap.mint(1).?;
    try std.testing.expectEqual(Route.corrupt, heap.route(payload));
    try std.testing.expectEqual(Route.retired, heap.route(boxBase(payload)));
    try std.testing.expectEqual(Route.corrupt, heap.route(boxBase(payload)));
    const never: *u64 = &heap.slots[1].token;
    try std.testing.expectEqual(Route.corrupt, heap.route(boxBase(never)));
}

test "a token that does not carry its heap's kind does not resolve" {
    var blobs: Heap(.blob, 1, u8) = .{};
    const b = blobs.mint(1).?;
    const kind_byte: u64 = @as(u64, token_kind_mask) << token_index_bits;
    // The same index and generation under another kind byte.
    const other = (b.* & ~kind_byte) | (@as(u64, 2) << token_index_bits);
    try std.testing.expect(blobs.get(b.*) != null);
    try std.testing.expect(blobs.get(other) == null);
    try std.testing.expect(blobs.get(0) == null);
}

test "abandoning a heap forgets live and retired slots" {
    var heap: Heap(.blob, 2, u8) = .{};
    const a = heap.mint(1).?;
    _ = heap.mint(2).?;
    _ = heap.route(boxBase(a));
    heap.abandon(nothing);
    try std.testing.expectEqual(@as(usize, 0), heap.live_count);
    try std.testing.expect(heap.mint(3) != null);
}
