//! Stable site, row, order, and exact-key storage for `Rows`.
//!
//! Keys are independently allocated for a row lifetime, which keeps the byte
//! slices stored in the site's hash index stable even when dense slot tables
//! grow. Order is an intrusive doubly linked list of generation-checked row
//! identities; lookup and neighbor edits therefore never scan the site.

const std = @import("std");
const rows_ids = @import("rows_ids.zig");

pub const SiteId = rows_ids.SiteId;
pub const RowId = rows_ids.RowId;
pub const OwnerToken = rows_ids.OwnerToken;

pub const Error = std.mem.Allocator.Error || error{
    ResourceLimit,
    InvalidSite,
    SiteNotEmpty,
    InvalidRow,
    WrongSite,
    DuplicateKey,
    DuplicateItemSlot,
    MissingKey,
};

const max_slot_count: usize = std.math.maxInt(u32);

fn SlotPool(comptime Id: type, comptime Payload: type) type {
    return struct {
        const Self = @This();

        const State = union(enum) {
            active: Payload,
            free: ?u32,
            retired,
        };

        const Slot = struct {
            generation: u32 = 1,
            state: State,
        };

        slots: std.ArrayListUnmanaged(Slot) = .empty,
        free_head: ?u32 = null,
        free_count: usize = 0,
        slot_limit: usize = max_slot_count,

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.slots.deinit(allocator);
            self.* = undefined;
        }

        fn get(self: *Self, id: Id) !*Payload {
            const index = id.slotIndex() orelse return error.InvalidIdentity;
            if (index >= self.slots.items.len) return error.InvalidIdentity;
            const slot = &self.slots.items[index];
            if (slot.generation != id.generation()) return error.InvalidIdentity;
            return switch (slot.state) {
                .active => |*payload| payload,
                .free, .retired => error.InvalidIdentity,
            };
        }

        fn getConst(self: *const Self, id: Id) !*const Payload {
            const index = id.slotIndex() orelse return error.InvalidIdentity;
            if (index >= self.slots.items.len) return error.InvalidIdentity;
            const slot = &self.slots.items[index];
            if (slot.generation != id.generation()) return error.InvalidIdentity;
            return switch (slot.state) {
                .active => |*payload| payload,
                .free, .retired => error.InvalidIdentity,
            };
        }

        fn insert(self: *Self, allocator: std.mem.Allocator, payload: Payload) (std.mem.Allocator.Error || error{ResourceLimit})!Id {
            var claim: [1]Id = undefined;
            self.prepareClaims(allocator, &.{}, &claim) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.ResourceLimit => error.ResourceLimit,
                error.InvalidIdentity => unreachable,
            };
            self.insertClaimed(claim[0], payload);
            return claim[0];
        }

        fn remove(self: *Self, id: Id) !Payload {
            const index = id.slotIndex() orelse return error.InvalidIdentity;
            if (index >= self.slots.items.len) return error.InvalidIdentity;
            const slot = &self.slots.items[index];
            if (slot.generation != id.generation()) return error.InvalidIdentity;
            const payload = switch (slot.state) {
                .active => |value| value,
                .free, .retired => return error.InvalidIdentity,
            };

            if (slot.generation == std.math.maxInt(u32)) {
                slot.state = .retired;
            } else {
                slot.generation += 1;
                slot.state = .{ .free = self.free_head };
                self.free_head = @intCast(index);
                self.free_count += 1;
            }
            return payload;
        }

        /// Previews identities available after `removed` is retired in slice
        /// order and reserves every append needed by allocation-free commit.
        fn prepareClaims(self: *Self, allocator: std.mem.Allocator, removed: []const Id, claims: []Id) (std.mem.Allocator.Error || error{ ResourceLimit, InvalidIdentity })!void {
            var reusable_removed: usize = 0;
            for (removed) |id| {
                const index = id.slotIndex() orelse return error.InvalidIdentity;
                if (index >= self.slots.items.len) return error.InvalidIdentity;
                const slot = &self.slots.items[index];
                if (slot.generation != id.generation() or slot.state != .active) return error.InvalidIdentity;
                if (slot.generation != std.math.maxInt(u32)) reusable_removed += 1;
            }

            const reusable = std.math.add(usize, self.free_count, reusable_removed) catch return error.ResourceLimit;
            const append_count = claims.len -| reusable;
            const final_slot_count = std.math.add(usize, self.slots.items.len, append_count) catch return error.ResourceLimit;
            if (final_slot_count > self.slot_limit or final_slot_count > max_slot_count) return error.ResourceLimit;
            try self.slots.ensureUnusedCapacity(allocator, append_count);

            var claim_index: usize = 0;
            var removed_index = removed.len;
            while (removed_index != 0 and claim_index < claims.len) {
                removed_index -= 1;
                const id = removed[removed_index];
                const slot_index = id.slotIndex().?;
                const generation = self.slots.items[slot_index].generation;
                if (generation == std.math.maxInt(u32)) continue;
                claims[claim_index] = Id.init(slot_index, generation + 1);
                claim_index += 1;
            }

            var free = self.free_head;
            while (free) |free_index| {
                if (claim_index == claims.len) break;
                const slot = &self.slots.items[free_index];
                const next = switch (slot.state) {
                    .free => |value| value,
                    .active, .retired => @panic("Rows free list referenced a non-free slot"),
                };
                claims[claim_index] = Id.init(free_index, slot.generation);
                claim_index += 1;
                free = next;
            }

            var append_index = self.slots.items.len;
            while (claim_index < claims.len) : (claim_index += 1) {
                claims[claim_index] = Id.init(append_index, 1);
                append_index += 1;
            }
        }

        fn insertClaimed(self: *Self, expected: Id, payload: Payload) void {
            if (self.free_head) |free_index| {
                const slot = &self.slots.items[free_index];
                const next = switch (slot.state) {
                    .free => |value| value,
                    .active, .retired => @panic("Rows free list referenced a non-free slot"),
                };
                if (expected.slotIndex() != free_index or expected.generation() != slot.generation) {
                    @panic("Rows row claim no longer matched preflighted free-list order");
                }
                self.free_head = next;
                self.free_count -= 1;
                slot.state = .{ .active = payload };
                return;
            }

            if (expected.slotIndex() != self.slots.items.len or expected.generation() != 1) {
                @panic("Rows row claim no longer matched preflighted append order");
            }
            self.slots.appendAssumeCapacity(.{ .state = .{ .active = payload } });
        }
    };
}

/// Engine-owned metadata attached to one stable row source and scope.
pub const RowMetadata = struct {
    item_slot: u64,
    scope_id: u64,
    row_handle: u64 = 0,
    render_root: ?u64 = null,
};

/// Allocation-free intrusive-order iterator over one committed Rows site.
pub const Iterator = struct {
    store: *const Store,
    site_id: SiteId,
    next_id: ?RowId,

    /// Advances to the next generation-checked row identity and metadata.
    pub fn next(self: *Iterator) ?struct { id: RowId, row: *const Row } {
        const id = self.next_id orelse return null;
        const row = self.store.getRowConst(self.site_id, id) catch @panic("committed Rows order referenced a stale row");
        self.next_id = row.next;
        return .{ .id = id, .row = row };
    }
};

/// Mutable row record used only by the shared engine and prepared transition.
pub const Row = struct {
    site_id: SiteId,
    key: []u8,
    previous: ?RowId = null,
    next: ?RowId = null,
    metadata: RowMetadata,
};

/// One committed Rows site with exact-key lookup and intrusive row order.
pub const Site = struct {
    owner_token: OwnerToken,
    head: ?RowId = null,
    tail: ?RowId = null,
    len: usize = 0,
    by_key: std.StringHashMapUnmanaged(RowId) = .empty,
    by_item_slot: std.AutoHashMapUnmanaged(u64, RowId) = .empty,

    fn deinit(self: *Site, allocator: std.mem.Allocator) void {
        self.by_key.deinit(allocator);
        self.by_item_slot.deinit(allocator);
        self.* = undefined;
    }
};

/// Host-owned storage shared by native and Wasm engine instantiations.
pub const Store = struct {
    allocator: std.mem.Allocator,
    sites: SlotPool(SiteId, Site) = .{},
    rows: SlotPool(RowId, Row) = .{},

    /// Creates empty storage with full nonzero 32-bit slot ranges.
    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    /// Creates empty storage with explicit limits used by resource-boundary
    /// tests and constrained hosts.
    pub fn initWithLimits(allocator: std.mem.Allocator, site_limit: usize, row_limit: usize) Store {
        var result = init(allocator);
        result.sites.slot_limit = @min(site_limit, max_slot_count);
        result.rows.slot_limit = @min(row_limit, max_slot_count);
        return result;
    }

    /// Releases every live key and index exactly once. Teardown allocates no
    /// memory and tolerates sites that still contain committed rows.
    pub fn deinit(self: *Store) void {
        for (self.sites.slots.items) |*slot| switch (slot.state) {
            .active => |*site_value| {
                var current = site_value.head;
                while (current) |row_id| {
                    const row = self.rows.get(row_id) catch @panic("live Rows site referenced a stale row");
                    const next = row.next;
                    self.allocator.free(row.key);
                    _ = self.rows.remove(row_id) catch @panic("live Rows row could not be retired during teardown");
                    current = next;
                }
                site_value.deinit(self.allocator);
            },
            .free, .retired => {},
        };
        self.rows.deinit(self.allocator);
        self.sites.deinit(self.allocator);
        self.* = undefined;
    }

    /// Creates an empty committed site for one authenticated Rows generation.
    pub fn createSite(self: *Store, owner_token: OwnerToken) Error!SiteId {
        return self.sites.insert(self.allocator, .{ .owner_token = owner_token }) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.ResourceLimit => error.ResourceLimit,
        };
    }

    /// Retires an empty site. Rows must be removed through a prepared
    /// transition first so their scopes and values retire in the same commit.
    pub fn destroyEmptySite(self: *Store, site_id: SiteId) Error!void {
        const site_value = self.getSiteConst(site_id) catch return error.InvalidSite;
        if (site_value.len != 0) return error.SiteNotEmpty;
        var removed = self.sites.remove(site_id) catch return error.InvalidSite;
        removed.deinit(self.allocator);
    }

    /// Resolves mutable committed site state by exact generation.
    pub fn getSite(self: *Store, site_id: SiteId) error{InvalidSite}!*Site {
        return self.sites.get(site_id) catch error.InvalidSite;
    }

    /// Resolves immutable committed site state by exact generation.
    pub fn getSiteConst(self: *const Store, site_id: SiteId) error{InvalidSite}!*const Site {
        return self.sites.getConst(site_id) catch error.InvalidSite;
    }

    /// Resolves mutable row state and verifies its owning site.
    pub fn getRow(self: *Store, site_id: SiteId, row_id: RowId) error{ InvalidRow, WrongSite }!*Row {
        const value = self.rows.get(row_id) catch return error.InvalidRow;
        if (value.site_id != site_id) return error.WrongSite;
        return value;
    }

    /// Resolves immutable row state and verifies its owning site.
    pub fn getRowConst(self: *const Store, site_id: SiteId, row_id: RowId) error{ InvalidRow, WrongSite }!*const Row {
        const value = self.rows.getConst(row_id) catch return error.InvalidRow;
        if (value.site_id != site_id) return error.WrongSite;
        return value;
    }

    /// Looks up a row by exact UTF-8 bytes without normalizing or decoding it.
    pub fn findKey(self: *const Store, site_id: SiteId, key: []const u8) error{InvalidSite}!?RowId {
        return (try self.getSiteConst(site_id)).by_key.get(key);
    }

    /// Looks up one row by the immutable Roc generation's stable item slot.
    pub fn findItemSlot(self: *const Store, site_id: SiteId, item_slot: u64) error{InvalidSite}!?RowId {
        if (item_slot == 0) return null;
        return (try self.getSiteConst(site_id)).by_item_slot.get(item_slot);
    }

    /// Starts allocation-free traversal in committed row order.
    pub fn iterate(self: *const Store, site_id: SiteId) error{InvalidSite}!Iterator {
        return .{ .store = self, .site_id = site_id, .next_id = (try self.getSiteConst(site_id)).head };
    }

    /// Reserves row identities and dense slot growth for a prepared commit.
    /// `removed` must be retired in the same order before claims are inserted.
    pub fn prepareRowClaims(self: *Store, site_id: SiteId, removed: []const RowId, claims: []RowId) Error!void {
        const site_value = self.getSite(site_id) catch return error.InvalidSite;
        for (removed) |row_id| _ = self.getRowConst(site_id, row_id) catch return error.InvalidRow;
        self.rows.prepareClaims(self.allocator, removed, claims) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.ResourceLimit => error.ResourceLimit,
            error.InvalidIdentity => error.InvalidRow,
        };
        const final_bound = std.math.add(usize, site_value.by_key.count(), claims.len) catch return error.ResourceLimit;
        try site_value.by_key.ensureTotalCapacity(self.allocator, std.math.cast(u32, final_bound) orelse return error.ResourceLimit);
        try site_value.by_item_slot.ensureTotalCapacity(self.allocator, std.math.cast(u32, final_bound) orelse return error.ResourceLimit);
    }

    /// Retires one prevalidated row during allocation-free publication and
    /// returns its owned key buffer to the caller for release.
    pub fn removePreparedRow(self: *Store, site_id: SiteId, row_id: RowId) []u8 {
        const site_value = self.getSite(site_id) catch @panic("prepared Rows site became stale before commit");
        const row_value = self.getRowConst(site_id, row_id) catch @panic("prepared Rows row became stale before commit");
        if (!site_value.by_key.remove(row_value.key)) @panic("prepared Rows removal key was absent from its site index");
        if (!site_value.by_item_slot.remove(row_value.metadata.item_slot)) @panic("prepared Rows removal slot was absent from its site index");
        const removed = self.rows.remove(row_id) catch @panic("prepared Rows row could not be retired");
        return removed.key;
    }

    /// Publishes one preclaimed row and transfers its key allocation into the
    /// exact-key index without allocating.
    pub fn insertPreparedRow(self: *Store, site_id: SiteId, claim: RowId, row_value: Row) void {
        if (row_value.site_id != site_id) @panic("prepared Rows row targeted the wrong site");
        const site_value = self.getSite(site_id) catch @panic("prepared Rows site became stale before commit");
        if (row_value.metadata.item_slot == 0 or site_value.by_item_slot.contains(row_value.metadata.item_slot)) @panic("prepared Rows insertion duplicated a stable item slot");
        self.rows.insertClaimed(claim, row_value);
        const committed = self.getRow(site_id, claim) catch @panic("claimed Rows row did not become live");
        site_value.by_key.putAssumeCapacity(committed.key, claim);
        site_value.by_item_slot.putAssumeCapacity(committed.metadata.item_slot, claim);
    }
};

test "Rows site storage keeps exact keys and rejects stale identities" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const token = try OwnerToken.fromRaw(1);
    const site = try store.createSite(token);
    var claims: [2]RowId = undefined;
    try store.prepareRowClaims(site, &.{}, &claims);

    const first_key = try std.testing.allocator.dupe(u8, "Cafe\xcc\x81");
    const second_key = try std.testing.allocator.dupe(u8, "Caf\xc3\xa9");
    store.insertPreparedRow(site, claims[0], .{ .site_id = site, .key = first_key, .metadata = .{ .item_slot = 1, .scope_id = 10 } });
    store.insertPreparedRow(site, claims[1], .{ .site_id = site, .key = second_key, .metadata = .{ .item_slot = 2, .scope_id = 20 } });
    const site_value = try store.getSite(site);
    site_value.head = claims[0];
    site_value.tail = claims[1];
    site_value.len = 2;
    (try store.getRow(site, claims[0])).next = claims[1];
    (try store.getRow(site, claims[1])).previous = claims[0];

    try std.testing.expectEqual(claims[0], (try store.findKey(site, "Cafe\xcc\x81")).?);
    try std.testing.expectEqual(claims[1], (try store.findKey(site, "Caf\xc3\xa9")).?);
    try std.testing.expect((try store.findKey(site, "cafe")) == null);

    const stale = claims[0];
    const owned_key = store.removePreparedRow(site, stale);
    std.testing.allocator.free(owned_key);
    site_value.head = claims[1];
    site_value.len = 1;
    (try store.getRow(site, claims[1])).previous = null;
    try std.testing.expectError(error.InvalidRow, store.getRow(site, stale));
}

test "Rows row claims reuse retired slots without wrapping generations" {
    var store = Store.initWithLimits(std.testing.allocator, 1, 2);
    defer store.deinit();
    const site = try store.createSite(try OwnerToken.fromRaw(1));

    var first_claim: [1]RowId = undefined;
    try store.prepareRowClaims(site, &.{}, &first_claim);
    store.insertPreparedRow(site, first_claim[0], .{
        .site_id = site,
        .key = try std.testing.allocator.dupe(u8, "old"),
        .metadata = .{ .item_slot = 1, .scope_id = 1 },
    });

    var replacement: [1]RowId = undefined;
    try store.prepareRowClaims(site, &.{first_claim[0]}, &replacement);
    const old_key = store.removePreparedRow(site, first_claim[0]);
    std.testing.allocator.free(old_key);
    store.insertPreparedRow(site, replacement[0], .{
        .site_id = site,
        .key = try std.testing.allocator.dupe(u8, "new"),
        .metadata = .{ .item_slot = 2, .scope_id = 2 },
    });
    const site_value = try store.getSite(site);
    site_value.head = replacement[0];
    site_value.tail = replacement[0];
    site_value.len = 1;

    try std.testing.expectEqual(first_claim[0].slotIndex(), replacement[0].slotIndex());
    try std.testing.expectEqual(first_claim[0].generation() + 1, replacement[0].generation());
    try std.testing.expectError(error.InvalidRow, store.getRow(site, first_claim[0]));
}

test "Rows site identities reject stale generations after constant-time reuse" {
    var store = Store.initWithLimits(std.testing.allocator, 1, 1);
    defer store.deinit();
    const first = try store.createSite(try OwnerToken.fromRaw(1));
    try store.destroyEmptySite(first);

    const reused = try store.createSite(try OwnerToken.fromRaw(2));
    try std.testing.expectEqual(first.slotIndex(), reused.slotIndex());
    try std.testing.expectEqual(first.generation() + 1, reused.generation());
    try std.testing.expectError(error.InvalidSite, store.getSite(first));
    try std.testing.expectEqual(@as(u64, 2), (try store.getSiteConst(reused)).owner_token.raw());
}
