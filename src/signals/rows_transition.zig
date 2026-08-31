//! Sparse prepared transitions for committed `Rows` sites.
//!
//! Preparation shadows only edited rows and their immediate order neighbors.
//! It owns copied keys for provisional rows, validates the edit sequence, and
//! preflights persistent hash/slot capacity. Commit then retires, inserts, and
//! rewrites those touched records without allocation. Abort releases candidate
//! storage and leaves the committed site byte-for-byte unchanged.

const std = @import("std");
const rows_ids = @import("rows_ids.zig");
const rows_store = @import("rows_site_store.zig");

pub const SiteId = rows_ids.SiteId;
pub const RowId = rows_ids.RowId;
pub const OwnerToken = rows_ids.OwnerToken;
pub const RowMetadata = rows_store.RowMetadata;
pub const Store = rows_store.Store;

pub const Error = std.mem.Allocator.Error || error{
    ResourceLimit,
    InvalidSite,
    ParentMismatch,
    InvalidOwnerToken,
    DuplicateKey,
    MissingKey,
};

/// Payload for inserting one new row at a key-addressed position.
pub const Insert = struct {
    key: []const u8,
    before: ?[]const u8 = null,
    metadata: RowMetadata,
};

/// Key-addressed move; null `before` means the end of the site.
pub const Move = struct {
    key: []const u8,
    before: ?[]const u8,
};

/// Same-key value replacement that preserves row identity and local state.
pub const Set = struct {
    key: []const u8,
    metadata: RowMetadata,
};

/// Normalized sparse operations consumed sequentially by the host runtime.
pub const Edit = union(enum) {
    insert: Insert,
    remove_key: []const u8,
    move: Move,
    set: Set,
    clear,
};

/// Provisional row identity available to a row builder before publication.
pub const CreatedRow = struct {
    row_id: RowId,
    key: []const u8,
    metadata: RowMetadata,
};

const NodeRef = u128;
const fresh_bit: u128 = @as(u128, 1) << 64;

fn existingRef(row_id: RowId) NodeRef {
    return row_id.raw();
}

fn freshRef(index: usize) NodeRef {
    return fresh_bit | @as(u64, @intCast(index));
}

fn isFresh(ref: NodeRef) bool {
    return (ref & fresh_bit) != 0;
}

fn freshIndex(ref: NodeRef) usize {
    if (!isFresh(ref)) @panic("existing Rows reference decoded as provisional");
    return @intCast(@as(u64, @truncate(ref)));
}

fn existingId(ref: NodeRef) RowId {
    if (isFresh(ref)) @panic("provisional Rows reference decoded as committed");
    return RowId.fromRaw(@truncate(ref));
}

const KeyState = struct {
    node: NodeRef,
    live: bool,
};

const Shadow = struct {
    key: []const u8,
    metadata: RowMetadata,
    previous: ?NodeRef,
    next: ?NodeRef,
    live: bool,
    was_live: bool,
};

const Fresh = struct {
    key: []u8,
    metadata: RowMetadata,
    claim: ?RowId = null,
};

const Phase = enum { preparing, prepared, committed };

/// Candidate overlay for one authenticated parent-to-child Rows generation.
pub const PreparedTransition = struct {
    allocator: std.mem.Allocator,
    store: *Store,
    site_id: SiteId,
    next_owner: OwnerToken,
    head: ?NodeRef,
    tail: ?NodeRef,
    len: usize,
    shadows: std.AutoHashMapUnmanaged(NodeRef, Shadow) = .empty,
    touched: std.ArrayListUnmanaged(NodeRef) = .empty,
    key_states: std.StringHashMapUnmanaged(KeyState) = .empty,
    fresh: std.ArrayListUnmanaged(Fresh) = .empty,
    removed_rows: []RowId = &.{},
    created_rows: []CreatedRow = &.{},
    phase: Phase = .preparing,

    /// Validates and preflights a normalized sparse edit batch. A parent-token
    /// mismatch is reported explicitly so the caller can choose the counted
    /// exact-snapshot path; it is never repaired or guessed here.
    pub fn prepare(allocator: std.mem.Allocator, store: *Store, site_id: SiteId, parent_owner: OwnerToken, next_owner: OwnerToken, edits: []const Edit) Error!PreparedTransition {
        const committed = store.getSiteConst(site_id) catch return error.InvalidSite;
        if (committed.owner_token != parent_owner) return error.ParentMismatch;
        if (next_owner.raw() == 0 or next_owner == parent_owner) return error.InvalidOwnerToken;

        var self = PreparedTransition{
            .allocator = allocator,
            .store = store,
            .site_id = site_id,
            .next_owner = next_owner,
            .head = if (committed.head) |row| existingRef(row) else null,
            .tail = if (committed.tail) |row| existingRef(row) else null,
            .len = committed.len,
        };
        errdefer self.deinit();

        for (edits) |edit| switch (edit) {
            .insert => |value| try self.applyInsert(value),
            .remove_key => |key| try self.applyRemove(key),
            .move => |value| try self.applyMove(value),
            .set => |value| try self.applySet(value),
            .clear => try self.applyClear(),
        };
        try self.finishPreparation();
        return self;
    }

    /// Returns newly live rows whose builders may be prepared before commit.
    pub fn createdRows(self: *const PreparedTransition) []const CreatedRow {
        if (self.phase == .preparing) @panic("Rows creation list read before preparation completed");
        return self.created_rows;
    }

    /// Returns committed row identities that will retire in this publication.
    pub fn removedRows(self: *const PreparedTransition) []const RowId {
        if (self.phase == .preparing) @panic("Rows removal list read before preparation completed");
        return self.removed_rows;
    }

    /// Publishes the candidate generation without allocation. Any scope/value
    /// preparation associated with `createdRows` and `removedRows` must already
    /// have succeeded before entering this irreversible boundary.
    pub fn commit(self: *PreparedTransition) void {
        if (self.phase != .prepared) @panic("Rows transition committed outside its prepared phase");

        for (self.removed_rows) |row_id| {
            const key = self.store.removePreparedRow(self.site_id, row_id);
            self.store.allocator.free(key);
        }

        for (self.fresh.items, 0..) |*fresh, index| {
            const ref = freshRef(index);
            const shadow = self.shadows.get(ref) orelse @panic("provisional Rows row was missing its shadow");
            if (!shadow.live) continue;
            const claim = fresh.claim orelse @panic("live provisional Rows row had no preflighted claim");
            self.store.insertPreparedRow(self.site_id, claim, .{
                .site_id = self.site_id,
                .key = fresh.key,
                .previous = self.resolveOptional(shadow.previous),
                .next = self.resolveOptional(shadow.next),
                .metadata = shadow.metadata,
            });
            fresh.key = &.{};
        }

        for (self.touched.items) |ref| {
            if (isFresh(ref)) continue;
            const shadow = self.shadows.get(ref).?;
            if (!shadow.live) continue;
            const row = self.store.getRow(self.site_id, existingId(ref)) catch @panic("prepared Rows survivor became stale before commit");
            row.previous = self.resolveOptional(shadow.previous);
            row.next = self.resolveOptional(shadow.next);
            row.metadata = shadow.metadata;
        }

        const site = self.store.getSite(self.site_id) catch @panic("prepared Rows site became stale before commit");
        site.head = self.resolveOptional(self.head);
        site.tail = self.resolveOptional(self.tail);
        site.len = self.len;
        site.owner_token = self.next_owner;
        self.phase = .committed;
    }

    /// Releases candidate keys and scratch state. Before commit this is an
    /// abort; after commit transferred key allocations remain site-owned.
    pub fn deinit(self: *PreparedTransition) void {
        for (self.fresh.items) |fresh| if (fresh.key.len != 0) self.store.allocator.free(fresh.key);
        self.shadows.deinit(self.allocator);
        self.touched.deinit(self.allocator);
        self.key_states.deinit(self.allocator);
        self.fresh.deinit(self.allocator);
        if (self.removed_rows.len != 0) self.allocator.free(self.removed_rows);
        if (self.created_rows.len != 0) self.allocator.free(self.created_rows);
        self.* = undefined;
    }

    fn finishPreparation(self: *PreparedTransition) Error!void {
        var removed_count: usize = 0;
        for (self.touched.items) |ref| {
            const shadow = self.shadows.get(ref).?;
            if (!isFresh(ref) and shadow.was_live and !shadow.live) removed_count += 1;
        }
        var created_count: usize = 0;
        for (self.fresh.items, 0..) |_, index| if (self.shadows.get(freshRef(index)).?.live) {
            created_count += 1;
        };

        if (removed_count != 0) self.removed_rows = try self.allocator.alloc(RowId, removed_count);
        if (created_count != 0) self.created_rows = try self.allocator.alloc(CreatedRow, created_count);
        var claims: []RowId = &.{};
        if (created_count != 0) claims = try self.allocator.alloc(RowId, created_count);
        defer if (claims.len != 0) self.allocator.free(claims);

        var removed_index: usize = 0;
        for (self.touched.items) |ref| {
            const shadow = self.shadows.get(ref).?;
            if (!isFresh(ref) and shadow.was_live and !shadow.live) {
                self.removed_rows[removed_index] = existingId(ref);
                removed_index += 1;
            }
        }
        self.store.prepareRowClaims(self.site_id, self.removed_rows, claims) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.ResourceLimit => error.ResourceLimit,
            error.InvalidSite, error.SiteNotEmpty, error.InvalidRow, error.WrongSite, error.DuplicateKey, error.MissingKey => error.InvalidSite,
        };

        var created_index: usize = 0;
        for (self.fresh.items, 0..) |*fresh, index| {
            const shadow = self.shadows.get(freshRef(index)).?;
            if (!shadow.live) continue;
            fresh.claim = claims[created_index];
            self.created_rows[created_index] = .{
                .row_id = claims[created_index],
                .key = fresh.key,
                .metadata = shadow.metadata,
            };
            created_index += 1;
        }
        self.phase = .prepared;
    }

    fn applyInsert(self: *PreparedTransition, insert: Insert) Error!void {
        const before = if (insert.before) |key| try self.requireLiveKey(key) else null;
        if (try self.lookupKey(insert.key)) |state| {
            if (state.live) return error.DuplicateKey;
            const shadow = try self.getShadow(state.node);
            shadow.metadata = insert.metadata;
            try self.attachBefore(state.node, before);
            try self.putKeyState(shadow.key, .{ .node = state.node, .live = true });
            return;
        }

        const owned_key = try self.store.allocator.dupe(u8, insert.key);
        errdefer self.store.allocator.free(owned_key);
        const index = self.fresh.items.len;
        try self.fresh.append(self.allocator, .{ .key = owned_key, .metadata = insert.metadata });
        errdefer _ = self.fresh.pop();
        const ref = freshRef(index);
        try self.insertShadow(ref, .{
            .key = owned_key,
            .metadata = insert.metadata,
            .previous = null,
            .next = null,
            .live = false,
            .was_live = false,
        });
        try self.attachBefore(ref, before);
        try self.putKeyState(owned_key, .{ .node = ref, .live = true });
    }

    fn applyRemove(self: *PreparedTransition, key: []const u8) Error!void {
        const ref = try self.requireLiveKey(key);
        const stable_key = (try self.getShadow(ref)).key;
        try self.detach(ref);
        try self.putKeyState(stable_key, .{ .node = ref, .live = false });
    }

    fn applyMove(self: *PreparedTransition, move: Move) Error!void {
        const ref = try self.requireLiveKey(move.key);
        const before = if (move.before) |key| try self.requireLiveKey(key) else null;
        if (before != null and before.? == ref) return;
        try self.detach(ref);
        try self.attachBefore(ref, before);
    }

    fn applySet(self: *PreparedTransition, set: Set) Error!void {
        const ref = try self.requireLiveKey(set.key);
        (try self.getShadow(ref)).metadata = set.metadata;
    }

    fn applyClear(self: *PreparedTransition) Error!void {
        while (self.head) |ref| {
            const key = (try self.getShadow(ref)).key;
            try self.detach(ref);
            try self.putKeyState(key, .{ .node = ref, .live = false });
        }
    }

    fn lookupKey(self: *PreparedTransition, key: []const u8) Error!?KeyState {
        if (self.key_states.get(key)) |state| return state;
        const row_id = self.store.findKey(self.site_id, key) catch return error.InvalidSite;
        return if (row_id) |row| .{ .node = existingRef(row), .live = true } else null;
    }

    fn requireLiveKey(self: *PreparedTransition, key: []const u8) Error!NodeRef {
        const state = (try self.lookupKey(key)) orelse return error.MissingKey;
        if (!state.live) return error.MissingKey;
        return state.node;
    }

    fn putKeyState(self: *PreparedTransition, key: []const u8, state: KeyState) Error!void {
        self.key_states.put(self.allocator, key, state) catch return error.OutOfMemory;
    }

    fn insertShadow(self: *PreparedTransition, ref: NodeRef, shadow: Shadow) Error!void {
        const result = self.shadows.getOrPut(self.allocator, ref) catch return error.OutOfMemory;
        if (result.found_existing) @panic("Rows candidate inserted one shadow twice");
        result.value_ptr.* = shadow;
        self.touched.append(self.allocator, ref) catch {
            _ = self.shadows.remove(ref);
            return error.OutOfMemory;
        };
    }

    fn getShadow(self: *PreparedTransition, ref: NodeRef) Error!*Shadow {
        if (self.shadows.getPtr(ref)) |shadow| return shadow;
        if (isFresh(ref)) @panic("provisional Rows reference had no candidate shadow");
        const row = self.store.getRowConst(self.site_id, existingId(ref)) catch return error.InvalidSite;
        try self.insertShadow(ref, .{
            .key = row.key,
            .metadata = row.metadata,
            .previous = if (row.previous) |previous| existingRef(previous) else null,
            .next = if (row.next) |next| existingRef(next) else null,
            .live = true,
            .was_live = true,
        });
        return self.shadows.getPtr(ref).?;
    }

    fn detach(self: *PreparedTransition, ref: NodeRef) Error!void {
        const current = (try self.getShadow(ref)).*;
        if (!current.live) @panic("Rows candidate detached an absent row");
        if (current.previous) |previous| {
            (try self.getShadow(previous)).next = current.next;
        } else {
            self.head = current.next;
        }
        if (current.next) |next| {
            (try self.getShadow(next)).previous = current.previous;
        } else {
            self.tail = current.previous;
        }
        const detached = try self.getShadow(ref);
        detached.previous = null;
        detached.next = null;
        detached.live = false;
        self.len -= 1;
    }

    fn attachBefore(self: *PreparedTransition, ref: NodeRef, before: ?NodeRef) Error!void {
        if ((try self.getShadow(ref)).live) @panic("Rows candidate attached an already-live row");
        if (before) |next| {
            const next_shadow = (try self.getShadow(next)).*;
            if (!next_shadow.live) return error.MissingKey;
            if (next_shadow.previous) |previous| (try self.getShadow(previous)).next = ref else self.head = ref;
            const row = try self.getShadow(ref);
            row.previous = next_shadow.previous;
            row.next = next;
            row.live = true;
            (try self.getShadow(next)).previous = ref;
        } else {
            const previous = self.tail;
            if (previous) |row| (try self.getShadow(row)).next = ref else self.head = ref;
            const inserted = try self.getShadow(ref);
            inserted.previous = previous;
            inserted.next = null;
            inserted.live = true;
            self.tail = ref;
        }
        self.len += 1;
    }

    fn resolve(self: *const PreparedTransition, ref: NodeRef) RowId {
        if (!isFresh(ref)) return existingId(ref);
        return self.fresh.items[freshIndex(ref)].claim orelse @panic("live provisional Rows reference had no claim");
    }

    fn resolveOptional(self: *const PreparedTransition, ref: ?NodeRef) ?RowId {
        return if (ref) |value| self.resolve(value) else null;
    }
};

fn expectOrder(store: *const Store, site_id: SiteId, expected: []const []const u8) !void {
    const site = try store.getSiteConst(site_id);
    try std.testing.expectEqual(expected.len, site.len);
    var current = site.head;
    var previous: ?RowId = null;
    for (expected) |key| {
        const row_id = current orelse return error.TestExpectedEqual;
        const row = try store.getRowConst(site_id, row_id);
        try std.testing.expectEqualStrings(key, row.key);
        try std.testing.expectEqual(previous, row.previous);
        previous = row_id;
        current = row.next;
    }
    try std.testing.expect(current == null);
    try std.testing.expectEqual(previous, site.tail);
}

test "Rows sparse transition inserts moves updates and removes touched rows" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const first_owner = try OwnerToken.fromRaw(1);
    const site = try store.createSite(first_owner);

    const initial_edits = [_]Edit{
        .{ .insert = .{ .key = "a", .metadata = .{ .item_slot = 1, .scope_id = 11 } } },
        .{ .insert = .{ .key = "b", .metadata = .{ .item_slot = 2, .scope_id = 22 } } },
        .{ .insert = .{ .key = "c", .metadata = .{ .item_slot = 3, .scope_id = 33 } } },
    };
    var initial = try PreparedTransition.prepare(std.testing.allocator, &store, site, first_owner, try OwnerToken.fromRaw(2), &initial_edits);
    defer initial.deinit();
    try std.testing.expectEqual(@as(usize, 3), initial.createdRows().len);
    initial.commit();
    try expectOrder(&store, site, &.{ "a", "b", "c" });

    const edits = [_]Edit{
        .{ .move = .{ .key = "c", .before = "a" } },
        .{ .remove_key = "a" },
        .{ .insert = .{ .key = "d", .before = "b", .metadata = .{ .item_slot = 4, .scope_id = 44 } } },
        .{ .set = .{ .key = "b", .metadata = .{ .item_slot = 20, .scope_id = 22, .render_root = 99 } } },
    };
    var next = try PreparedTransition.prepare(std.testing.allocator, &store, site, try OwnerToken.fromRaw(2), try OwnerToken.fromRaw(3), &edits);
    defer next.deinit();
    try std.testing.expectEqual(@as(usize, 1), next.createdRows().len);
    try std.testing.expectEqual(@as(usize, 1), next.removedRows().len);
    next.commit();

    try expectOrder(&store, site, &.{ "c", "d", "b" });
    const b = (try store.findKey(site, "b")).?;
    try std.testing.expectEqual(@as(u64, 20), (try store.getRowConst(site, b)).metadata.item_slot);
    try std.testing.expectEqual(@as(?u64, 99), (try store.getRowConst(site, b)).metadata.render_root);
}

test "Rows remove and reinsert in one unpublished batch preserves identity" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const site = try store.createSite(try OwnerToken.fromRaw(10));
    var seed = try PreparedTransition.prepare(std.testing.allocator, &store, site, try OwnerToken.fromRaw(10), try OwnerToken.fromRaw(11), &.{.{ .insert = .{
        .key = "stable",
        .metadata = .{ .item_slot = 1, .scope_id = 7 },
    } }});
    defer seed.deinit();
    seed.commit();
    const original = (try store.findKey(site, "stable")).?;

    var replacement = try PreparedTransition.prepare(std.testing.allocator, &store, site, try OwnerToken.fromRaw(11), try OwnerToken.fromRaw(12), &.{
        .{ .remove_key = "stable" },
        .{ .insert = .{ .key = "stable", .metadata = .{ .item_slot = 2, .scope_id = 7 } } },
    });
    defer replacement.deinit();
    try std.testing.expectEqual(@as(usize, 0), replacement.createdRows().len);
    try std.testing.expectEqual(@as(usize, 0), replacement.removedRows().len);
    replacement.commit();

    try std.testing.expectEqual(original, (try store.findKey(site, "stable")).?);
    try std.testing.expectEqual(@as(u64, 2), (try store.getRowConst(site, original)).metadata.item_slot);
}

test "Rows preparation rejects stale parents and duplicate exact keys without publication" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const owner = try OwnerToken.fromRaw(20);
    const site = try store.createSite(owner);

    try std.testing.expectError(error.ParentMismatch, PreparedTransition.prepare(std.testing.allocator, &store, site, try OwnerToken.fromRaw(19), try OwnerToken.fromRaw(21), &.{}));
    try std.testing.expectError(error.DuplicateKey, PreparedTransition.prepare(std.testing.allocator, &store, site, owner, try OwnerToken.fromRaw(21), &.{
        .{ .insert = .{ .key = "same", .metadata = .{ .item_slot = 1, .scope_id = 1 } } },
        .{ .insert = .{ .key = "same", .metadata = .{ .item_slot = 2, .scope_id = 2 } } },
    }));
    try expectOrder(&store, site, &.{});
    try std.testing.expectEqual(owner, (try store.getSiteConst(site)).owner_token);
}

test "Rows commit is allocation free after persistent preflight" {
    const fault_allocator = @import("fault_allocator.zig");
    var fault = fault_allocator.FaultAllocator.init(std.testing.allocator);
    var store = Store.init(fault.allocator());
    defer {
        fault.configure(null);
        store.deinit();
    }
    const site = try store.createSite(try OwnerToken.fromRaw(30));
    var prepared = try PreparedTransition.prepare(fault.allocator(), &store, site, try OwnerToken.fromRaw(30), try OwnerToken.fromRaw(31), &.{.{ .insert = .{
        .key = "row",
        .metadata = .{ .item_slot = 1, .scope_id = 1 },
    } }});
    defer prepared.deinit();

    fault.configure(1);
    prepared.commit();
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try expectOrder(&store, site, &.{"row"});
}

test "Rows preparation fault sweep preserves the committed generation" {
    const fault_allocator = @import("fault_allocator.zig");
    const edits = [_]Edit{
        .{ .insert = .{ .key = "alpha", .metadata = .{ .item_slot = 1, .scope_id = 1 } } },
        .{ .insert = .{ .key = "beta", .metadata = .{ .item_slot = 2, .scope_id = 2 } } },
        .{ .move = .{ .key = "beta", .before = "alpha" } },
    };

    var counter = fault_allocator.FaultAllocator.init(std.testing.allocator);
    var counting_store = Store.init(counter.allocator());
    defer counting_store.deinit();
    const counting_site = try counting_store.createSite(try OwnerToken.fromRaw(40));
    counter.configure(null);
    var successful = try PreparedTransition.prepare(counter.allocator(), &counting_store, counting_site, try OwnerToken.fromRaw(40), try OwnerToken.fromRaw(41), &edits);
    const allocation_attempts = counter.attempts;
    successful.deinit();
    try std.testing.expect(allocation_attempts != 0);

    for (1..allocation_attempts + 1) |failure_number| {
        var fault = fault_allocator.FaultAllocator.init(std.testing.allocator);
        var store = Store.init(fault.allocator());
        defer {
            fault.configure(null);
            store.deinit();
        }
        const owner = try OwnerToken.fromRaw(50);
        const site = try store.createSite(owner);
        fault.configure(failure_number);

        try std.testing.expectError(error.OutOfMemory, PreparedTransition.prepare(fault.allocator(), &store, site, owner, try OwnerToken.fromRaw(51), &edits));
        try expectOrder(&store, site, &.{});
        try std.testing.expectEqual(owner, (try store.getSiteConst(site)).owner_token);
        try std.testing.expectEqual(@as(usize, 1), fault.induced_failures);
    }
}
