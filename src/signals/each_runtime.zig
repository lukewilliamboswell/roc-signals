//! Keyed-list reconciliation storage and diff helpers for `Ui.each_str`.

const std = @import("std");
const ids = @import("ids.zig");

pub const missing_row_index = std.math.maxInt(usize);

pub const SiteKey = struct {
    parent_scope_id: ids.ScopeId,
    site_ordinal: ids.SiteOrdinal,
};

pub const SiteKeyContext = struct {
    /// Reports whether h is present in maintained state.
    pub fn hash(_: @This(), key: SiteKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        const parent_scope_id = key.parent_scope_id.raw();
        const site_ordinal = key.site_ordinal.raw();
        hasher.update(std.mem.asBytes(&parent_scope_id));
        hasher.update(std.mem.asBytes(&site_ordinal));
        return hasher.final();
    }

    /// Compares values through their owning capability rather than inspecting erased bytes.
    pub fn eql(_: @This(), left: SiteKey, right: SiteKey) bool {
        return left.parent_scope_id == right.parent_scope_id and left.site_ordinal == right.site_ordinal;
    }
};

pub const SiteIndexMap = std.HashMapUnmanaged(SiteKey, usize, SiteKeyContext, std.hash_map.default_max_load_percentage);

pub const Membership = struct {
    site_index: usize,
    row_index: usize,
};

pub const RowRemoval = struct {
    scope_id: ids.ScopeId,
    key_hash: u64,
};

/// Owns validated keyed-row removals until the structural publication boundary.
pub const PreparedRowRemovals = struct {
    rows: []RowRemoval,

    /// Releases preparation storage without changing live row indexes.
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.rows);
        self.* = undefined;
    }

    /// Removes every prepared row and repairs moved dense/hash indexes without allocation.
    pub fn apply(self: *const @This(), allocator: std.mem.Allocator, sites: *std.ArrayListUnmanaged(Site), site_indexes: *SiteIndexMap, memberships: *std.ArrayListUnmanaged(?Membership), row_keys: anytype) void {
        for (self.rows) |row| removeRowFromSiteIndex(sites, memberships, row.scope_id, row.key_hash, row_keys);
        var index = sites.items.len;
        while (index != 0) {
            index -= 1;
            if (sites.items[index].scope_ids.items.len != 0) continue;
            if (row_keys.siteRemainsActive(sites.items[index].key)) continue;
            const removed = sites.swapRemove(index);
            if (!site_indexes.remove(removed.key)) @panic("empty each site was missing its maintained index");
            var retired = removed;
            retired.deinit(allocator);
            if (index < sites.items.len) {
                const moved = &sites.items[index];
                const mapped = site_indexes.getPtr(moved.key) orelse @panic("moved each site was missing its maintained index");
                mapped.* = index;
                for (moved.scope_ids.items) |scope_id| {
                    const membership = &memberships.items[scope_id.index()];
                    if (membership.*) |*entry| entry.site_index = index else @panic("moved each site row was missing membership");
                }
            }
        }
    }
};

/// Copies and validates exact row removals without mutating maintained indexes.
pub fn prepareRowRemovals(allocator: std.mem.Allocator, sites: []const Site, memberships: []const ?Membership, rows: []const RowRemoval) (std.mem.Allocator.Error || error{InvalidScope})!PreparedRowRemovals {
    const owned = try allocator.dupe(RowRemoval, rows);
    errdefer allocator.free(owned);
    for (owned) |row| {
        if (row.scope_id.index() >= memberships.len) return error.InvalidScope;
        const membership = memberships[row.scope_id.index()] orelse return error.InvalidScope;
        if (membership.site_index >= sites.len or membership.row_index >= sites[membership.site_index].scope_ids.items.len) return error.InvalidScope;
        if (sites[membership.site_index].scope_ids.items[membership.row_index] != row.scope_id) return error.InvalidScope;
    }
    return .{ .rows = owned };
}

pub const Site = struct {
    key: SiteKey,
    scope_ids: std.ArrayListUnmanaged(ids.ScopeId) = .empty,
    hash_heads: std.AutoHashMapUnmanaged(u64, usize) = .empty,
    hash_links: std.ArrayListUnmanaged(usize) = .empty,

    /// Releases every resource owned by this value and leaves no retained host or Roc ownership behind.
    pub fn deinit(self: *Site, allocator: std.mem.Allocator) void {
        self.scope_ids.deinit(allocator);
        self.hash_heads.deinit(allocator);
        self.hash_links.deinit(allocator);
        self.* = undefined;
    }
};

pub const DiffResult = struct {
    scope_ids: []ids.ScopeId,
    row_items_changed: []bool,
    scope_created: []bool,
    removed_scope_ids: []ids.ScopeId,
    rows_reused: u64,
    rows_created: u64,
    rows_removed: u64,
    row_items_unchanged: u64,
    row_items_updated: u64,

    /// Releases every resource owned by this value and leaves no retained host or Roc ownership behind.
    pub fn deinit(self: DiffResult, allocator: std.mem.Allocator) void {
        allocator.free(self.scope_ids);
        allocator.free(self.row_items_changed);
        allocator.free(self.scope_created);
        allocator.free(self.removed_scope_ids);
    }
};

pub const RenderSegment = struct {
    scope_id: ids.ScopeId,
    start: usize,
    len: usize,
};

pub const RenderMove = struct {
    old_start: usize,
    new_start: usize,
    len: usize,
};

const NextKeyIndexError = error{
    OutOfMemory,
};

pub const DuplicateKeyInfo = struct {
    first_index: usize,
    second_index: usize,
};

/// Clears sites while retaining bounded storage where the type promises reuse.
pub fn clearSites(allocator: std.mem.Allocator, sites: *std.ArrayListUnmanaged(Site), site_indexes: *SiteIndexMap, memberships: *std.ArrayListUnmanaged(?Membership)) void {
    for (sites.items) |*site| {
        site.deinit(allocator);
    }
    sites.deinit(allocator);
    site_indexes.deinit(allocator);
    memberships.deinit(allocator);
    sites.* = .empty;
    site_indexes.* = .empty;
    memberships.* = .empty;
}

/// Ensures membership slot capacity or state before publication can begin.
pub fn ensureMembershipSlot(allocator: std.mem.Allocator, memberships: *std.ArrayListUnmanaged(?Membership), scope_id: ids.ScopeId) *?Membership {
    const index = scope_id.index();
    while (memberships.items.len <= index) {
        memberships.append(allocator, null) catch @panic("out of memory");
    }
    return &memberships.items[index];
}

/// Ensures site index capacity or state before publication can begin.
pub fn ensureSiteIndex(allocator: std.mem.Allocator, sites: *std.ArrayListUnmanaged(Site), site_indexes: *SiteIndexMap, parent_scope_id: ids.ScopeId, site_ordinal: ids.SiteOrdinal) usize {
    const key: SiteKey = .{
        .parent_scope_id = parent_scope_id,
        .site_ordinal = site_ordinal,
    };
    const entry = site_indexes.getOrPut(allocator, key) catch @panic("out of memory");
    if (entry.found_existing) return entry.value_ptr.*;

    const site_index = sites.items.len;
    sites.append(allocator, .{ .key = key }) catch @panic("out of memory");
    entry.value_ptr.* = site_index;
    return site_index;
}

/// Returns active site index from the maintained active-runtime indexes.
pub fn activeSiteIndex(site_indexes: *const SiteIndexMap, parent_scope_id: ids.ScopeId, site_ordinal: ids.SiteOrdinal) ?usize {
    return site_indexes.get(.{
        .parent_scope_id = parent_scope_id,
        .site_ordinal = site_ordinal,
    });
}

fn scopeSliceContains(items: []const ids.ScopeId, target: ids.ScopeId) bool {
    for (items) |item| {
        if (item == target) return true;
    }
    return false;
}

/// Reports whether keyed survivors already appear in the requested render order.
pub fn diffPreservesSurvivorRenderOrder(old_render_rows: []const ids.ScopeId, next_scope_ids: []const ids.ScopeId) bool {
    var old_index: usize = 0;
    for (next_scope_ids) |next_scope_id| {
        if (!scopeSliceContains(old_render_rows, next_scope_id)) continue;
        while (old_index < old_render_rows.len and !scopeSliceContains(next_scope_ids, old_render_rows[old_index])) {
            old_index += 1;
        }
        if (old_index >= old_render_rows.len) return false;
        if (old_render_rows[old_index] != next_scope_id) return false;
        old_index += 1;
    }
    return true;
}

/// Returns scope ids for the local render segment owned by an each site.
pub fn renderSegmentScopeIds(allocator: std.mem.Allocator, segments: []const RenderSegment) []ids.ScopeId {
    const scope_ids = allocator.alloc(ids.ScopeId, segments.len) catch @panic("out of memory");
    for (segments, scope_ids) |segment, *id| {
        id.* = segment.scope_id;
    }
    return scope_ids;
}

/// Computes the local insertion point from maintained keyed-row render ranges.
pub fn renderInsertIndexForRowRanges(site_render_insert_index: usize, row_ranges: *const std.AutoHashMapUnmanaged(ids.ScopeId, RenderSegment), next_scope_ids: []const ids.ScopeId, row_index: usize) usize {
    if (row_index >= next_scope_ids.len) @panic("each row insertion index was requested outside the next row order");

    if (row_ranges.get(next_scope_ids[row_index])) |existing| {
        return existing.start;
    }

    var next_index = row_index + 1;
    while (next_index < next_scope_ids.len) : (next_index += 1) {
        if (row_ranges.get(next_scope_ids[next_index])) |next| {
            return next.start;
        }
    }

    var previous_index = row_index;
    while (previous_index > 0) {
        previous_index -= 1;
        if (row_ranges.get(next_scope_ids[previous_index])) |previous| {
            return previous.start + previous.len;
        }
    }

    return site_render_insert_index;
}

fn adjustedRenderInsertIndex(old_index: usize, replace_index: usize, removed_count: usize, replacement_count: usize) usize {
    if (removed_count == 0) {
        if (old_index < replace_index) return old_index;
        return old_index + replacement_count;
    }
    if (old_index <= replace_index) return old_index;
    if (old_index < replace_index + removed_count) @panic("scope site inside replaced scope was not removed");
    return old_index - removed_count + replacement_count;
}

/// Shifts only row render ranges affected by an insertion or removal.
pub fn adjustRenderRanges(row_ranges: *std.AutoHashMapUnmanaged(ids.ScopeId, RenderSegment), replace_index: usize, removed_count: usize, replacement_count: usize) void {
    var range_iterator = row_ranges.iterator();
    while (range_iterator.next()) |entry| {
        entry.value_ptr.start = adjustedRenderInsertIndex(entry.value_ptr.start, replace_index, removed_count, replacement_count);
    }
}

/// Updates one surviving row's render range after local reconciliation.
pub fn updateRenderRange(row_ranges: *std.AutoHashMapUnmanaged(ids.ScopeId, RenderSegment), allocator: std.mem.Allocator, scope_id: ids.ScopeId, render_insert_index: usize, removed_count: usize, replacement_count: usize) void {
    const removed_range = row_ranges.fetchRemove(scope_id);
    const old_len = if (removed_range) |entry| entry.value.len else 0;
    if (old_len != removed_count) @panic("each row render range length did not match splice removal count");
    adjustRenderRanges(row_ranges, render_insert_index, old_len, replacement_count);
    if (replacement_count != 0) {
        row_ranges.put(allocator, scope_id, .{
            .scope_id = scope_id,
            .start = render_insert_index,
            .len = replacement_count,
        }) catch @panic("out of memory");
    }
}

/// Appends row to site index using capacity that must already satisfy the caller's transaction contract.
pub fn appendRowToSiteIndex(allocator: std.mem.Allocator, sites: *std.ArrayListUnmanaged(Site), memberships: *std.ArrayListUnmanaged(?Membership), site_index: usize, scope_id: ids.ScopeId, key_hash: u64) void {
    if (site_index >= sites.items.len) @panic("each row site index exceeded site table");
    const site = &sites.items[site_index];
    const row_index = site.scope_ids.items.len;

    site.scope_ids.append(allocator, scope_id) catch @panic("out of memory");
    site.hash_links.append(allocator, missing_row_index) catch @panic("out of memory");
    const hash_entry = site.hash_heads.getOrPut(allocator, key_hash) catch @panic("out of memory");
    if (hash_entry.found_existing) {
        site.hash_links.items[row_index] = hash_entry.value_ptr.*;
    }
    hash_entry.value_ptr.* = row_index;

    const membership = ensureMembershipSlot(allocator, memberships, scope_id);
    if (membership.* != null) @panic("each row scope already had an active row index");
    membership.* = .{
        .site_index = site_index,
        .row_index = row_index,
    };
}

/// Removes row from site index and releases the ownership attached to that live entry.
pub fn removeRowFromSiteIndex(sites: *std.ArrayListUnmanaged(Site), memberships: *std.ArrayListUnmanaged(?Membership), scope_id: ids.ScopeId, key_hash: u64, row_keys: anytype) void {
    if (scope_id.index() >= memberships.items.len) @panic("each row scope was missing its row index");
    const membership = memberships.items[scope_id.index()] orelse @panic("each row scope was missing its row index");
    if (membership.site_index >= sites.items.len) @panic("each row membership pointed past site table");
    const site = &sites.items[membership.site_index];
    if (membership.row_index >= site.scope_ids.items.len) @panic("each row membership pointed past row table");
    if (site.scope_ids.items[membership.row_index] != scope_id) @panic("each row membership pointed at the wrong scope");

    const last_index = site.scope_ids.items.len - 1;
    const moved_scope_id = site.scope_ids.items[last_index];
    unlinkHashIndex(site, key_hash, membership.row_index);

    memberships.items[scope_id.index()] = null;

    if (membership.row_index != last_index) {
        const moved_hash = rowKeysHash(row_keys, moved_scope_id);
        replaceHashIndex(site, moved_hash, last_index, membership.row_index);
        site.scope_ids.items[membership.row_index] = moved_scope_id;
        site.hash_links.items[membership.row_index] = site.hash_links.items[last_index];

        const moved_membership = &memberships.items[moved_scope_id.index()];
        if (moved_membership.*) |*entry| {
            entry.row_index = membership.row_index;
        } else {
            @panic("moved each row scope was missing its row index");
        }
    }

    _ = site.scope_ids.pop();
    _ = site.hash_links.pop();
}

/// Replaces site rows while releasing displaced ownership exactly once.
pub fn replaceSiteRows(allocator: std.mem.Allocator, sites: *std.ArrayListUnmanaged(Site), memberships: *std.ArrayListUnmanaged(?Membership), site_index: usize, scope_ids: []const ids.ScopeId, row_keys: anytype) void {
    if (site_index >= sites.items.len) @panic("each row site index exceeded site table");
    const site = &sites.items[site_index];

    for (site.scope_ids.items) |scope_id| {
        if (scope_id.index() < memberships.items.len) {
            memberships.items[scope_id.index()] = null;
        }
    }

    site.scope_ids.clearRetainingCapacity();
    site.scope_ids.appendSlice(allocator, scope_ids) catch @panic("out of memory");
    site.hash_links.resize(allocator, scope_ids.len) catch @panic("out of memory");
    @memset(site.hash_links.items, missing_row_index);
    site.hash_heads.clearRetainingCapacity();

    for (scope_ids, 0..) |scope_id, row_index| {
        const key_hash = rowKeysHash(row_keys, scope_id);

        const hash_entry = site.hash_heads.getOrPut(allocator, key_hash) catch @panic("out of memory");
        if (hash_entry.found_existing) {
            site.hash_links.items[row_index] = hash_entry.value_ptr.*;
        }
        hash_entry.value_ptr.* = row_index;

        const membership = ensureMembershipSlot(allocator, memberships, scope_id);
        if (membership.* != null) @panic("each row scope already had an active row index");
        membership.* = .{
            .site_index = site_index,
            .row_index = row_index,
        };
    }
}

/// Prepared reconciliation for an each site whose next keys all reuse existing rows.
/// Incoming key/item ownership remains provisional until `commit`.
pub const PreparedExistingRows = struct {
    const Phase = enum {
        prepared,
        committed,

        fn isCommitted(self: Phase) bool {
            return switch (self) {
                .prepared => false,
                .committed => true,
            };
        }

        fn markCommitted(self: *Phase) void {
            switch (self.*) {
                .prepared => self.* = .committed,
                .committed => @panic("prepared each rows committed twice"),
            }
        }
    };

    allocator: std.mem.Allocator,
    site_index: usize,
    next_scope_ids: []ids.ScopeId,
    /// One hash per incoming key, computed once during preparation. Commit
    /// republishes a changed row's key under this hash instead of hashing
    /// again, because hashing calls the Roc key function and publication
    /// never calls Roc.
    key_hashes: []u64,
    row_items_changed: []bool,
    scope_created: []bool,
    removed_scope_ids: []ids.ScopeId,
    created_count: usize = 0,
    highest_scope_id: ids.ScopeId = ids.root_scope,
    phase: Phase = .prepared,

    /// Computes matching and reserves every site/index destination without mutation.
    pub fn prepare(allocator: std.mem.Allocator, sites: *std.ArrayListUnmanaged(Site), memberships: *std.ArrayListUnmanaged(?Membership), site_index: usize, parent_scope_id: ids.ScopeId, site_ordinal: ids.SiteOrdinal, keys: anytype, items: anytype, hooks: anytype) (std.mem.Allocator.Error || error{ResourceLimit})!PreparedExistingRows {
        if (keys.len != items.len or site_index >= sites.items.len) @panic("invalid prepared each reconciliation input");
        const site = &sites.items[site_index];
        const existing_len = site.scope_ids.items.len;
        const key_hashes = try allocator.alloc(u64, keys.len);
        errdefer allocator.free(key_hashes);
        for (keys, 0..) |key, index| key_hashes[index] = hooks.hashKey(key);
        var next_hash_heads: std.AutoHashMapUnmanaged(u64, usize) = .empty;
        defer next_hash_heads.deinit(allocator);
        const next_hash_links = try allocator.alloc(usize, keys.len);
        defer allocator.free(next_hash_links);
        if (try indexNextKeys(allocator, &next_hash_heads, next_hash_links, key_hashes, keys, hooks)) |duplicate| {
            hooks.failDuplicateEachKey(parent_scope_id, site_ordinal, duplicate.first_index, duplicate.second_index, keys[duplicate.second_index]);
        }
        const matched = try allocator.alloc(bool, existing_len);
        defer allocator.free(matched);
        @memset(matched, false);
        const next_scope_ids = try allocator.alloc(ids.ScopeId, keys.len);
        errdefer allocator.free(next_scope_ids);
        const changed = try allocator.alloc(bool, keys.len);
        errdefer allocator.free(changed);
        const created = try allocator.alloc(bool, keys.len);
        errdefer allocator.free(created);
        @memset(created, false);

        var created_count: usize = 0;
        var highest_scope_id = ids.root_scope;
        errdefer hooks.abortPreparedRows();
        for (key_hashes, keys, items, 0..) |hash, key, item, next_index| {
            var found: ?ids.ScopeId = null;
            if (site.hash_heads.get(hash)) |head| {
                var existing_index = head;
                while (existing_index != missing_row_index) {
                    if (existing_index < existing_len and !matched[existing_index]) {
                        const scope_id = site.scope_ids.items[existing_index];
                        if (hooks.existingKeyEquals(scope_id, key)) {
                            matched[existing_index] = true;
                            found = scope_id;
                            break;
                        }
                    }
                    existing_index = site.hash_links.items[existing_index];
                }
            }
            if (found) |scope_id| {
                next_scope_ids[next_index] = scope_id;
                changed[next_index] = !hooks.rowItemEquals(scope_id, item);
            } else {
                const scope_id = try hooks.prepareCreatedRow(allocator, parent_scope_id, site_ordinal, next_index, hash, key, item);
                next_scope_ids[next_index] = scope_id;
                changed[next_index] = true;
                created[next_index] = true;
                created_count += 1;
            }
            if (next_scope_ids[next_index].raw() > highest_scope_id.raw()) highest_scope_id = next_scope_ids[next_index];
        }

        var removed_count: usize = 0;
        for (matched) |is_matched| if (!is_matched) {
            removed_count += 1;
        };
        const removed = try allocator.alloc(ids.ScopeId, removed_count);
        errdefer allocator.free(removed);
        var removed_index: usize = 0;
        for (site.scope_ids.items, matched) |scope_id, is_matched| if (!is_matched) {
            removed[removed_index] = scope_id;
            removed_index += 1;
        };

        try site.scope_ids.ensureTotalCapacity(allocator, keys.len);
        try site.hash_links.ensureTotalCapacity(allocator, keys.len);
        try site.hash_heads.ensureTotalCapacity(allocator, std.math.cast(u32, keys.len) orelse return error.ResourceLimit);
        // Reserved unconditionally, because `commit` grows `memberships` to cover
        // `highest_scope_id` whatever the incoming list holds. Skipping the
        // reservation for an empty list left `commit`'s `appendAssumeCapacity`
        // running against zero capacity the first time a keyed site reconciled
        // an empty list before any row had created a membership - a safety panic
        // in a checked build and an out-of-bounds write in ReleaseFast.
        try memberships.ensureTotalCapacity(allocator, std.math.add(usize, highest_scope_id.index(), 1) catch return error.ResourceLimit);
        try hooks.prepareExistingRowsCommit(allocator, removed.len);
        return .{
            .allocator = allocator,
            .site_index = site_index,
            .next_scope_ids = next_scope_ids,
            .key_hashes = key_hashes,
            .row_items_changed = changed,
            .scope_created = created,
            .removed_scope_ids = removed,
            .created_count = created_count,
            .highest_scope_id = highest_scope_id,
        };
    }

    /// Transfers provisional row values and publishes the prepared order without allocation.
    pub fn commit(self: *PreparedExistingRows, sites: *std.ArrayListUnmanaged(Site), memberships: *std.ArrayListUnmanaged(?Membership), keys: anytype, items: anytype, hooks: anytype) DiffResult {
        if (self.phase.isCommitted()) @panic("prepared each rows committed twice");
        const site = &sites.items[self.site_index];
        var unchanged_count: u64 = 0;
        var updated_count: u64 = 0;
        for (self.next_scope_ids, self.key_hashes, self.row_items_changed, self.scope_created, keys, items) |scope_id, key_hash, changed, created, key, item| {
            if (created) {
                hooks.commitCreatedRow(scope_id);
                continue;
            }
            if (changed) {
                hooks.replaceRowKey(scope_id, key_hash, key);
                hooks.replaceRowItem(scope_id, item);
                updated_count += 1;
            } else {
                hooks.dropIncomingKey(key);
                hooks.dropIncomingItem(item);
                unchanged_count += 1;
            }
        }
        for (self.removed_scope_ids) |scope_id| hooks.disposeScope(scope_id);
        hooks.finishPreparedRowsCommit();
        while (memberships.items.len <= self.highest_scope_id.index()) memberships.appendAssumeCapacity(null);
        for (site.scope_ids.items) |scope_id| memberships.items[scope_id.index()] = null;
        site.scope_ids.clearRetainingCapacity();
        site.scope_ids.appendSliceAssumeCapacity(self.next_scope_ids);
        site.hash_links.items.len = self.next_scope_ids.len;
        @memset(site.hash_links.items, missing_row_index);
        site.hash_heads.clearRetainingCapacity();
        for (self.next_scope_ids, 0..) |scope_id, row_index| {
            const entry = site.hash_heads.getOrPutAssumeCapacity(hooks.rowKeyHash(scope_id));
            if (entry.found_existing) site.hash_links.items[row_index] = entry.value_ptr.*;
            entry.value_ptr.* = row_index;
            memberships.items[scope_id.index()] = .{ .site_index = self.site_index, .row_index = row_index };
        }
        self.phase.markCommitted();
        const result = DiffResult{
            .scope_ids = self.next_scope_ids,
            .row_items_changed = self.row_items_changed,
            .scope_created = self.scope_created,
            .removed_scope_ids = self.removed_scope_ids,
            .rows_reused = self.next_scope_ids.len - self.created_count,
            .rows_created = @intCast(self.created_count),
            .rows_removed = @intCast(self.removed_scope_ids.len),
            .row_items_unchanged = unchanged_count,
            .row_items_updated = updated_count,
        };
        self.next_scope_ids = &.{};
        self.row_items_changed = &.{};
        self.scope_created = &.{};
        self.removed_scope_ids = &.{};
        return result;
    }

    /// Releases preparation storage without touching active rows or incoming values.
    pub fn deinit(self: *PreparedExistingRows) void {
        self.allocator.free(self.next_scope_ids);
        self.allocator.free(self.key_hashes);
        self.allocator.free(self.row_items_changed);
        self.allocator.free(self.scope_created);
        self.allocator.free(self.removed_scope_ids);
        self.* = undefined;
    }

    /// Releases provisional created rows while leaving persistent row state unchanged.
    pub fn abort(self: *PreparedExistingRows, hooks: anytype) void {
        if (!self.phase.isCommitted()) hooks.abortPreparedRows();
    }
};

/// Full prepared keyed-row synchronization, including provisional created rows.
pub const PreparedRowSync = PreparedExistingRows;

/// Reconciles one keyed each site by exact key identity, preserving surviving row scopes and disposing removed rows.
pub fn syncRows(
    allocator: std.mem.Allocator,
    sites: *std.ArrayListUnmanaged(Site),
    memberships: *std.ArrayListUnmanaged(?Membership),
    site_index: usize,
    parent_scope_id: ids.ScopeId,
    site_ordinal: ids.SiteOrdinal,
    keys: anytype,
    items: anytype,
    hooks: anytype,
) DiffResult {
    if (keys.len != items.len) @panic("Ui.each_str keyed scope received mismatched key and item lists");
    if (site_index >= sites.items.len) @panic("each row site index exceeded site table");

    const existing_len = sites.items[site_index].scope_ids.items.len;
    hooks.recordEachSync(keys.len, existing_len);

    const key_hashes = allocator.alloc(u64, keys.len) catch @panic("out of memory");
    defer allocator.free(key_hashes);
    for (keys, 0..) |key, key_index| {
        key_hashes[key_index] = hooks.hashKey(key);
    }

    var next_hash_heads: std.AutoHashMapUnmanaged(u64, usize) = .{};
    defer next_hash_heads.deinit(allocator);

    const next_hash_links = allocator.alloc(usize, keys.len) catch @panic("out of memory");
    defer allocator.free(next_hash_links);
    const duplicate = indexNextKeys(allocator, &next_hash_heads, next_hash_links, key_hashes, keys, hooks) catch |err| switch (err) {
        error.OutOfMemory => @panic("out of memory"),
    };
    if (duplicate) |info| {
        hooks.failDuplicateEachKey(parent_scope_id, site_ordinal, info.first_index, info.second_index, keys[info.second_index]);
    }

    const matched_existing = allocator.alloc(bool, existing_len) catch @panic("out of memory");
    defer allocator.free(matched_existing);
    @memset(matched_existing, false);

    var next_scope_ids = allocator.alloc(ids.ScopeId, keys.len) catch @panic("out of memory");
    errdefer allocator.free(next_scope_ids);
    var row_items_changed = allocator.alloc(bool, keys.len) catch @panic("out of memory");
    errdefer allocator.free(row_items_changed);
    var scope_created = allocator.alloc(bool, keys.len) catch @panic("out of memory");
    errdefer allocator.free(scope_created);
    var removed_scope_ids: std.ArrayListUnmanaged(ids.ScopeId) = .empty;
    errdefer removed_scope_ids.deinit(allocator);

    var rows_reused: u64 = 0;
    var rows_created: u64 = 0;
    var row_items_unchanged: u64 = 0;
    var row_items_updated: u64 = 0;

    for (key_hashes, keys, items, 0..) |hash, key, item, key_index| {
        var matched_scope_id: ?ids.ScopeId = null;
        const site = &sites.items[site_index];
        if (site.hash_heads.get(hash)) |head| {
            var existing_index = head;
            while (existing_index != missing_row_index) {
                if (existing_index < existing_len and !matched_existing[existing_index]) {
                    const scope_id = site.scope_ids.items[existing_index];
                    if (hooks.existingKeyEquals(scope_id, key)) {
                        matched_existing[existing_index] = true;
                        matched_scope_id = scope_id;
                        break;
                    }
                }
                existing_index = site.hash_links.items[existing_index];
            }
        }

        if (matched_scope_id) |scope_id| {
            next_scope_ids[key_index] = scope_id;
            scope_created[key_index] = false;
            rows_reused += 1;

            const row_item_equal = hooks.rowItemEquals(scope_id, item);
            if (row_item_equal) {
                hooks.dropIncomingKey(key);
                hooks.dropIncomingItem(item);
                row_items_changed[key_index] = false;
                row_items_unchanged += 1;
            } else {
                hooks.replaceRowKey(scope_id, hash, key);
                hooks.replaceRowItem(scope_id, item);
                row_items_changed[key_index] = true;
                row_items_updated += 1;
            }
        } else {
            next_scope_ids[key_index] = ids.ScopeId.fromRaw(std.math.maxInt(u64));
            row_items_changed[key_index] = true;
            scope_created[key_index] = true;
            rows_created += 1;
        }
    }

    {
        const site = &sites.items[site_index];
        for (site.scope_ids.items[0..existing_len], 0..) |scope_id, existing_index| {
            if (matched_existing[existing_index]) continue;
            removed_scope_ids.append(allocator, scope_id) catch @panic("out of memory");
        }
    }

    for (scope_created, key_hashes, keys, items, 0..) |created, hash, key, item, key_index| {
        if (!created) continue;
        next_scope_ids[key_index] = hooks.createRow(parent_scope_id, site_ordinal, hash, key, item);
    }

    for (removed_scope_ids.items) |scope_id| {
        hooks.disposeScope(scope_id);
    }

    replaceSiteRows(allocator, sites, memberships, site_index, next_scope_ids, hooks);
    const removed = removed_scope_ids.toOwnedSlice(allocator) catch @panic("out of memory");
    errdefer allocator.free(removed);

    hooks.recordRows(rows_reused, rows_created, @intCast(removed.len));

    return .{
        .scope_ids = next_scope_ids,
        .row_items_changed = row_items_changed,
        .scope_created = scope_created,
        .removed_scope_ids = removed,
        .rows_reused = rows_reused,
        .rows_created = rows_created,
        .rows_removed = @intCast(removed.len),
        .row_items_unchanged = row_items_unchanged,
        .row_items_updated = row_items_updated,
    };
}

fn indexNextKeys(
    allocator: std.mem.Allocator,
    next_hash_heads: *std.AutoHashMapUnmanaged(u64, usize),
    next_hash_links: []usize,
    key_hashes: []const u64,
    keys: anytype,
    hooks: anytype,
) NextKeyIndexError!?DuplicateKeyInfo {
    @memset(next_hash_links, missing_row_index);

    for (key_hashes, 0..) |hash, key_index| {
        if (next_hash_heads.get(hash)) |head| {
            var previous_index = head;
            while (previous_index != missing_row_index) {
                if (hooks.nextKeysEqual(keys[previous_index], keys[key_index])) {
                    return .{
                        .first_index = previous_index,
                        .second_index = key_index,
                    };
                }
                previous_index = next_hash_links[previous_index];
            }
        }

        const entry = next_hash_heads.getOrPut(allocator, hash) catch return error.OutOfMemory;
        if (entry.found_existing) {
            next_hash_links[key_index] = entry.value_ptr.*;
        }
        entry.value_ptr.* = key_index;
    }
    return null;
}

fn rowKeysHash(row_keys: anytype, scope_id: ids.ScopeId) u64 {
    return row_keys.rowKeyHash(scope_id);
}

fn unlinkHashIndex(site: *Site, hash: u64, row_index: usize) void {
    const head = site.hash_heads.getPtr(hash) orelse @panic("each row hash bucket was missing");
    if (head.* == row_index) {
        const next = site.hash_links.items[row_index];
        if (next == missing_row_index) {
            _ = site.hash_heads.remove(hash);
        } else {
            head.* = next;
        }
        return;
    }

    var current = head.*;
    while (current != missing_row_index) {
        const next = &site.hash_links.items[current];
        if (next.* == row_index) {
            next.* = site.hash_links.items[row_index];
            return;
        }
        current = next.*;
    }
    @panic("each row hash bucket did not contain row index");
}

fn replaceHashIndex(site: *Site, hash: u64, old_index: usize, new_index: usize) void {
    if (old_index == new_index) return;

    const head = site.hash_heads.getPtr(hash) orelse @panic("each row hash bucket was missing");
    if (head.* == old_index) {
        head.* = new_index;
        return;
    }

    var current = head.*;
    while (current != missing_row_index) {
        const next = &site.hash_links.items[current];
        if (next.* == old_index) {
            next.* = new_index;
            return;
        }
        current = next.*;
    }
    @panic("each row hash bucket did not contain moved row index");
}

const TestRowKeys = struct {
    hashes: []const u64,

    /// Performs row key hash through the keyed-row capabilities that own key and item values.
    pub fn rowKeyHash(self: *const TestRowKeys, scope_id: ids.ScopeId) u64 {
        if (scope_id.index() >= self.hashes.len) @panic("test scope id exceeded row key table");
        return self.hashes[scope_id.index()];
    }

    /// Test fixtures using this lookup model no live descriptor ownership.
    pub fn siteRemainsActive(_: *const TestRowKeys, _: SiteKey) bool {
        return false;
    }
};

const test_parent_scope = ids.ScopeId.fromRaw(1);
const test_site_ordinal = ids.SiteOrdinal.fromRaw(2);
fn testScope(raw: u64) ids.ScopeId {
    return ids.ScopeId.fromRaw(raw);
}

const TestSyncHooks = struct {
    const PreparedCreated = struct { scope_id: ids.ScopeId, key: u64, item: u64 };
    keys_by_scope: []u64,
    items_by_scope: []u64,
    next_scope_id: ids.ScopeId,
    forced_hash: ?u64 = null,
    disposed_scopes: std.ArrayListUnmanaged(ids.ScopeId) = .empty,
    sync_next_len: usize = 0,
    sync_existing_len: usize = 0,
    rows_reused: u64 = 0,
    rows_created: u64 = 0,
    rows_removed: u64 = 0,
    fault_attempts: ?*const usize = null,
    first_mutation_attempt: ?usize = null,
    prepared_created: std.ArrayListUnmanaged(PreparedCreated) = .empty,
    hash_calls: usize = 0,

    fn recordMutation(self: *@This()) void {
        if (self.first_mutation_attempt == null) {
            if (self.fault_attempts) |attempts| self.first_mutation_attempt = attempts.*;
        }
    }

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.disposed_scopes.deinit(allocator);
        self.prepared_created.deinit(allocator);
    }

    /// Reserves disposal journal capacity before prepared row publication.
    pub fn prepareExistingRowsCommit(self: *@This(), allocator: std.mem.Allocator, removed_count: usize) std.mem.Allocator.Error!void {
        try self.disposed_scopes.ensureUnusedCapacity(allocator, removed_count);
    }

    /// Owns a provisional created row without publishing key/item tables.
    pub fn prepareCreatedRow(self: *@This(), allocator: std.mem.Allocator, parent_scope_id: ids.ScopeId, site_ordinal: ids.SiteOrdinal, input_index: usize, hash: u64, key: u64, item: u64) std.mem.Allocator.Error!ids.ScopeId {
        _ = input_index;
        if (parent_scope_id.raw() != 1 or site_ordinal.raw() != 2) @panic("test row was prepared for the wrong site");
        self.expectHash(hash, key);
        const scope_id = ids.ScopeId.fromIndex(self.next_scope_id.index() + self.prepared_created.items.len);
        try self.prepared_created.append(allocator, .{ .scope_id = scope_id, .key = key, .item = item });
        return scope_id;
    }

    /// Publishes one previously prepared created row without allocation.
    pub fn commitCreatedRow(self: *@This(), scope_id: ids.ScopeId) void {
        for (self.prepared_created.items) |prepared| if (prepared.scope_id == scope_id) {
            self.keys_by_scope[scope_id.index()] = prepared.key;
            self.items_by_scope[scope_id.index()] = prepared.item;
            if (scope_id.index() >= self.next_scope_id.index()) self.next_scope_id = ids.ScopeId.fromIndex(scope_id.index() + 1);
            return;
        };
        @panic("prepared created row was missing");
    }

    /// Drops all provisional created rows without changing persistent key/item tables.
    pub fn abortPreparedRows(self: *@This()) void {
        self.prepared_created.items.len = 0;
    }

    /// Clears provisional bookkeeping after ownership transfers to persistent rows.
    pub fn finishPreparedRowsCommit(self: *@This()) void {
        self.prepared_created.items.len = 0;
    }

    /// Records each sync in the metrics or lifecycle state owned by this operation.
    pub fn recordEachSync(self: *@This(), next_len: usize, existing_len: usize) void {
        self.sync_next_len = next_len;
        self.sync_existing_len = existing_len;
    }

    fn hashForKey(self: *@This(), key: u64) u64 {
        return self.forced_hash orelse key;
    }

    fn expectHash(self: *@This(), hash: u64, key: u64) void {
        if (hash != self.hashForKey(key)) @panic("test key hash must match key");
    }

    /// Reports whether h key is present in maintained state.
    pub fn hashKey(self: *@This(), key: u64) u64 {
        self.hash_calls += 1;
        return self.hashForKey(key);
    }

    /// Compares candidate row keys exactly after hash lookup, preserving collision correctness.
    pub fn nextKeysEqual(_: *@This(), left: u64, right: u64) bool {
        return left == right;
    }

    /// Confirms an indexed key match through the key capability to handle hash collisions exactly.
    pub fn existingKeyEquals(self: *@This(), scope_id: ids.ScopeId, key: u64) bool {
        return self.keys_by_scope[scope_id.index()] == key;
    }

    /// Performs row item equals through the keyed-row capabilities that own key and item values.
    pub fn rowItemEquals(self: *@This(), scope_id: ids.ScopeId, item: u64) bool {
        return self.items_by_scope[scope_id.index()] == item;
    }

    /// Replaces row key while releasing displaced ownership exactly once.
    pub fn replaceRowKey(self: *@This(), scope_id: ids.ScopeId, hash: u64, key: u64) void {
        self.recordMutation();
        self.expectHash(hash, key);
        self.keys_by_scope[scope_id.index()] = key;
    }

    /// Replaces row item while releasing displaced ownership exactly once.
    pub fn replaceRowItem(self: *@This(), scope_id: ids.ScopeId, item: u64) void {
        self.recordMutation();
        self.items_by_scope[scope_id.index()] = item;
    }

    /// Drops the provisional incoming key through its owning capability.
    pub fn dropIncomingKey(self: *@This(), _: u64) void {
        self.recordMutation();
    }

    /// Drops the provisional incoming item through its owning capability.
    pub fn dropIncomingItem(self: *@This(), _: u64) void {
        self.recordMutation();
    }

    /// Creates a new keyed row scope and transfers the incoming key and item into its ownership.
    pub fn createRow(self: *@This(), parent_scope_id: ids.ScopeId, site_ordinal: ids.SiteOrdinal, hash: u64, key: u64, item: u64) ids.ScopeId {
        self.recordMutation();
        if (parent_scope_id.raw() != 1 or site_ordinal.raw() != 2) @panic("test row was created for the wrong site");
        self.expectHash(hash, key);
        const scope_id = self.next_scope_id;
        self.next_scope_id = ids.ScopeId.fromIndex(scope_id.index() + 1);
        self.keys_by_scope[scope_id.index()] = key;
        self.items_by_scope[scope_id.index()] = item;
        return scope_id;
    }

    /// Disposes a removed row scope and every render, effect, callable, and value it owns.
    pub fn disposeScope(self: *@This(), scope_id: ids.ScopeId) void {
        self.recordMutation();
        self.disposed_scopes.append(std.testing.allocator, scope_id) catch @panic("out of memory");
    }

    /// Performs row key hash through the keyed-row capabilities that own key and item values.
    pub fn rowKeyHash(self: *@This(), scope_id: ids.ScopeId) u64 {
        return self.hashForKey(self.keys_by_scope[scope_id.index()]);
    }

    /// Records rows in the metrics or lifecycle state owned by this operation.
    pub fn recordRows(self: *@This(), rows_reused: u64, rows_created: u64, rows_removed: u64) void {
        self.rows_reused = rows_reused;
        self.rows_created = rows_created;
        self.rows_removed = rows_removed;
    }

    /// Rejects a duplicate keyed row at the narrow reconciliation boundary with a bounded diagnostic.
    pub fn failDuplicateEachKey(_: *@This(), parent_scope_id: ids.ScopeId, site_ordinal: ids.SiteOrdinal, first_index: usize, second_index: usize, key: u64) noreturn {
        _ = parent_scope_id;
        _ = site_ordinal;
        _ = first_index;
        _ = second_index;
        _ = key;
        @panic("test duplicate each key");
    }
};

test "each runtime detects duplicate next keys through typed equality" {
    var next_hash_heads: std.AutoHashMapUnmanaged(u64, usize) = .{};
    defer next_hash_heads.deinit(std.testing.allocator);

    var next_hash_links = [_]usize{missing_row_index} ** 2;
    const key_hashes = [_]u64{ 7, 7 };
    const keys = [_]u64{ 1, 1 };

    var keys_by_scope = [_]u64{};
    var items_by_scope = [_]u64{};
    var hooks = TestSyncHooks{
        .keys_by_scope = &keys_by_scope,
        .items_by_scope = &items_by_scope,
        .next_scope_id = ids.root_scope,
        .forced_hash = 7,
    };
    defer hooks.deinit(std.testing.allocator);

    const duplicate = try indexNextKeys(std.testing.allocator, &next_hash_heads, &next_hash_links, &key_hashes, &keys, &hooks);
    try std.testing.expectEqual(@as(?DuplicateKeyInfo, .{
        .first_index = 0,
        .second_index = 1,
    }), duplicate);
}

test "each runtime appends rows and tracks memberships" {
    var sites: std.ArrayListUnmanaged(Site) = .empty;
    var indexes: SiteIndexMap = .empty;
    var memberships: std.ArrayListUnmanaged(?Membership) = .empty;
    defer clearSites(std.testing.allocator, &sites, &indexes, &memberships);

    const site_index = ensureSiteIndex(std.testing.allocator, &sites, &indexes, test_parent_scope, test_site_ordinal);
    try std.testing.expectEqual(site_index, activeSiteIndex(&indexes, test_parent_scope, test_site_ordinal).?);

    appendRowToSiteIndex(std.testing.allocator, &sites, &memberships, site_index, testScope(10), 5);
    appendRowToSiteIndex(std.testing.allocator, &sites, &memberships, site_index, testScope(11), 5);

    try std.testing.expectEqualSlices(ids.ScopeId, &.{ testScope(10), testScope(11) }, sites.items[site_index].scope_ids.items);
    try std.testing.expectEqual(Membership{ .site_index = site_index, .row_index = 0 }, memberships.items[10].?);
    try std.testing.expectEqual(Membership{ .site_index = site_index, .row_index = 1 }, memberships.items[11].?);
    try std.testing.expectEqual(@as(usize, 1), sites.items[site_index].hash_heads.get(5).?);
    try std.testing.expectEqual(@as(usize, 0), sites.items[site_index].hash_links.items[1]);
}

test "each runtime sync reuses creates removes and rebuilds rows" {
    var sites: std.ArrayListUnmanaged(Site) = .empty;
    var indexes: SiteIndexMap = .empty;
    var memberships: std.ArrayListUnmanaged(?Membership) = .empty;
    defer clearSites(std.testing.allocator, &sites, &indexes, &memberships);

    const site_index = ensureSiteIndex(std.testing.allocator, &sites, &indexes, test_parent_scope, test_site_ordinal);
    appendRowToSiteIndex(std.testing.allocator, &sites, &memberships, site_index, testScope(10), 1);
    appendRowToSiteIndex(std.testing.allocator, &sites, &memberships, site_index, testScope(11), 2);

    var keys_by_scope = [_]u64{0} ** 16;
    var items_by_scope = [_]u64{0} ** 16;
    keys_by_scope[10] = 1;
    items_by_scope[10] = 100;
    keys_by_scope[11] = 2;
    items_by_scope[11] = 200;

    var hooks = TestSyncHooks{
        .keys_by_scope = &keys_by_scope,
        .items_by_scope = &items_by_scope,
        .next_scope_id = testScope(12),
    };
    defer hooks.deinit(std.testing.allocator);

    const keys = [_]u64{ 2, 3 };
    const items = [_]u64{ 200, 300 };
    const diff = syncRows(std.testing.allocator, &sites, &memberships, site_index, test_parent_scope, test_site_ordinal, &keys, &items, &hooks);
    defer diff.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(ids.ScopeId, &.{ testScope(11), testScope(12) }, diff.scope_ids);
    try std.testing.expectEqualSlices(bool, &.{ false, true }, diff.row_items_changed);
    try std.testing.expectEqualSlices(bool, &.{ false, true }, diff.scope_created);
    try std.testing.expectEqualSlices(ids.ScopeId, &.{testScope(10)}, diff.removed_scope_ids);
    try std.testing.expectEqualSlices(ids.ScopeId, &.{testScope(10)}, hooks.disposed_scopes.items);
    try std.testing.expectEqual(@as(u64, 1), diff.rows_reused);
    try std.testing.expectEqual(@as(u64, 1), diff.rows_created);
    try std.testing.expectEqual(@as(u64, 1), diff.rows_removed);
    try std.testing.expectEqual(@as(u64, 1), diff.row_items_unchanged);
    try std.testing.expectEqual(@as(u64, 0), diff.row_items_updated);
    try std.testing.expectEqual(@as(usize, 2), hooks.sync_next_len);
    try std.testing.expectEqual(@as(usize, 2), hooks.sync_existing_len);
    try std.testing.expectEqualSlices(ids.ScopeId, &.{ testScope(11), testScope(12) }, sites.items[site_index].scope_ids.items);
    try std.testing.expectEqual(Membership{ .site_index = site_index, .row_index = 0 }, memberships.items[11].?);
    try std.testing.expectEqual(Membership{ .site_index = site_index, .row_index = 1 }, memberships.items[12].?);
    try std.testing.expectEqual(@as(?Membership, null), memberships.items[10]);
    try std.testing.expectEqual(@as(u64, 1), hooks.rows_reused);
    try std.testing.expectEqual(@as(u64, 1), hooks.rows_created);
    try std.testing.expectEqual(@as(u64, 1), hooks.rows_removed);
}

test "each sync characterization detects allocation attempts after mutation begins" {
    const CharacterizationFaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var fault = CharacterizationFaultAllocator.init(std.testing.allocator);
    const allocator = fault.allocator();
    var sites: std.ArrayListUnmanaged(Site) = .empty;
    var indexes: SiteIndexMap = .empty;
    var memberships: std.ArrayListUnmanaged(?Membership) = .empty;
    defer {
        fault.configure(null);
        clearSites(allocator, &sites, &indexes, &memberships);
    }

    const site_index = ensureSiteIndex(allocator, &sites, &indexes, test_parent_scope, test_site_ordinal);
    appendRowToSiteIndex(allocator, &sites, &memberships, site_index, testScope(10), 1);
    appendRowToSiteIndex(allocator, &sites, &memberships, site_index, testScope(11), 2);
    var keys_by_scope = [_]u64{0} ** 16;
    var items_by_scope = [_]u64{0} ** 16;
    keys_by_scope[10] = 1;
    items_by_scope[10] = 100;
    keys_by_scope[11] = 2;
    items_by_scope[11] = 200;
    var hooks = TestSyncHooks{
        .keys_by_scope = &keys_by_scope,
        .items_by_scope = &items_by_scope,
        .next_scope_id = testScope(12),
        .fault_attempts = &fault.attempts,
    };
    defer hooks.deinit(std.testing.allocator);

    fault.configure(null);
    const keys = [_]u64{2};
    const items = [_]u64{201};
    const diff = syncRows(allocator, &sites, &memberships, site_index, test_parent_scope, test_site_ordinal, &keys, &items, &hooks);
    defer diff.deinit(allocator);
    const first_mutation = hooks.first_mutation_attempt orelse return error.TestUnexpectedResult;
    try std.testing.expect(first_mutation < fault.attempts);
}

test "prepared existing each rows sweep failures and commit without allocation" {
    const PreparedFaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    const Runner = struct {
        fn run(failure_number: ?usize) !usize {
            var fault = PreparedFaultAllocator.init(std.testing.allocator);
            const allocator = fault.allocator();
            var sites: std.ArrayListUnmanaged(Site) = .empty;
            var indexes: SiteIndexMap = .empty;
            var memberships: std.ArrayListUnmanaged(?Membership) = .empty;
            defer {
                fault.configure(null);
                clearSites(allocator, &sites, &indexes, &memberships);
            }
            const site_index = ensureSiteIndex(allocator, &sites, &indexes, test_parent_scope, test_site_ordinal);
            appendRowToSiteIndex(allocator, &sites, &memberships, site_index, testScope(10), 1);
            appendRowToSiteIndex(allocator, &sites, &memberships, site_index, testScope(11), 2);
            var keys_by_scope = [_]u64{0} ** 16;
            var items_by_scope = [_]u64{0} ** 16;
            keys_by_scope[10] = 1;
            items_by_scope[10] = 100;
            keys_by_scope[11] = 2;
            items_by_scope[11] = 200;
            var hooks = TestSyncHooks{ .keys_by_scope = &keys_by_scope, .items_by_scope = &items_by_scope, .next_scope_id = testScope(12) };
            defer hooks.deinit(allocator);
            const keys = [_]u64{ 2, 3 };
            const items = [_]u64{ 201, 300 };
            const old_scope_ids = [_]ids.ScopeId{ testScope(10), testScope(11) };

            fault.configure(failure_number);
            var prepared = PreparedExistingRows.prepare(allocator, &sites, &memberships, site_index, test_parent_scope, test_site_ordinal, &keys, &items, &hooks) catch |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expectEqualSlices(ids.ScopeId, &old_scope_ids, sites.items[site_index].scope_ids.items);
                try std.testing.expectEqual(@as(u64, 200), items_by_scope[11]);
                try std.testing.expectEqual(@as(usize, 0), hooks.disposed_scopes.items.len);
                const attempts = fault.attempts;
                fault.configure(null);
                var retry = try PreparedExistingRows.prepare(allocator, &sites, &memberships, site_index, test_parent_scope, test_site_ordinal, &keys, &items, &hooks);
                defer retry.deinit();
                fault.configure(1);
                var diff = retry.commit(&sites, &memberships, &keys, &items, &hooks);
                defer diff.deinit(allocator);
                try std.testing.expectEqual(@as(usize, 0), fault.attempts);
                try std.testing.expectEqual(@as(u64, 0), diff.row_items_unchanged);
                try std.testing.expectEqual(@as(u64, 1), diff.row_items_updated);
                try verify(site_index, &sites, &memberships, &hooks, &items_by_scope);
                return attempts;
            };
            defer prepared.deinit();
            const attempts = fault.attempts;
            fault.configure(1);
            var diff = prepared.commit(&sites, &memberships, &keys, &items, &hooks);
            defer diff.deinit(allocator);
            try std.testing.expectEqual(@as(usize, 0), fault.attempts);
            try std.testing.expectEqual(@as(u64, 0), diff.row_items_unchanged);
            try std.testing.expectEqual(@as(u64, 1), diff.row_items_updated);
            try verify(site_index, &sites, &memberships, &hooks, &items_by_scope);
            return attempts;
        }

        fn verify(site_index: usize, sites: *std.ArrayListUnmanaged(Site), memberships: *std.ArrayListUnmanaged(?Membership), hooks: *TestSyncHooks, items_by_scope: []const u64) !void {
            try std.testing.expectEqualSlices(ids.ScopeId, &.{ testScope(11), testScope(12) }, sites.items[site_index].scope_ids.items);
            try std.testing.expectEqual(@as(u64, 201), items_by_scope[11]);
            try std.testing.expectEqual(@as(u64, 3), hooks.keys_by_scope[12]);
            try std.testing.expectEqual(@as(u64, 300), items_by_scope[12]);
            try std.testing.expectEqualSlices(ids.ScopeId, &.{testScope(10)}, hooks.disposed_scopes.items);
            try std.testing.expect(memberships.items[10] == null);
            try std.testing.expectEqual(Membership{ .site_index = site_index, .row_index = 0 }, memberships.items[11].?);
            try std.testing.expectEqual(Membership{ .site_index = site_index, .row_index = 1 }, memberships.items[12].?);
        }
    };
    const attempts = try Runner.run(null);
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| _ = try Runner.run(failure_number);
}

test "prepared existing each rows hash every key once, during preparation" {
    // Commit republished a changed row's key under `hooks.hashKey(key)`,
    // hashing it a second time. Hashing calls the Roc key function, which
    // publication must never do, and it inflated each_key_hashes by one per
    // updated row (large-each `Update middle row`: 9 hashes for 8 keys).
    var sites: std.ArrayListUnmanaged(Site) = .empty;
    var indexes: SiteIndexMap = .empty;
    var memberships: std.ArrayListUnmanaged(?Membership) = .empty;
    defer clearSites(std.testing.allocator, &sites, &indexes, &memberships);
    const site_index = ensureSiteIndex(std.testing.allocator, &sites, &indexes, test_parent_scope, test_site_ordinal);
    appendRowToSiteIndex(std.testing.allocator, &sites, &memberships, site_index, testScope(10), 1);
    appendRowToSiteIndex(std.testing.allocator, &sites, &memberships, site_index, testScope(11), 2);
    var keys_by_scope = [_]u64{0} ** 16;
    var items_by_scope = [_]u64{0} ** 16;
    keys_by_scope[10] = 1;
    items_by_scope[10] = 100;
    keys_by_scope[11] = 2;
    items_by_scope[11] = 200;
    var hooks = TestSyncHooks{ .keys_by_scope = &keys_by_scope, .items_by_scope = &items_by_scope, .next_scope_id = testScope(12) };
    defer hooks.deinit(std.testing.allocator);
    const keys = [_]u64{ 1, 2 };
    const items = [_]u64{ 100, 201 };

    var prepared = try PreparedExistingRows.prepare(std.testing.allocator, &sites, &memberships, site_index, test_parent_scope, test_site_ordinal, &keys, &items, &hooks);
    defer prepared.deinit();
    try std.testing.expectEqual(@as(usize, 2), hooks.hash_calls);
    var diff = prepared.commit(&sites, &memberships, &keys, &items, &hooks);
    defer diff.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), hooks.hash_calls);
    try std.testing.expectEqual(@as(u64, 1), diff.row_items_updated);
    try std.testing.expectEqual(@as(u64, 201), items_by_scope[11]);
    try std.testing.expectEqual(@as(usize, 1), sites.items[site_index].hash_heads.get(2).?);
}

test "each runtime sync resolves hash collisions with typed equality" {
    var sites: std.ArrayListUnmanaged(Site) = .empty;
    var indexes: SiteIndexMap = .empty;
    var memberships: std.ArrayListUnmanaged(?Membership) = .empty;
    defer clearSites(std.testing.allocator, &sites, &indexes, &memberships);

    const site_index = ensureSiteIndex(std.testing.allocator, &sites, &indexes, test_parent_scope, test_site_ordinal);
    appendRowToSiteIndex(std.testing.allocator, &sites, &memberships, site_index, testScope(10), 0);
    appendRowToSiteIndex(std.testing.allocator, &sites, &memberships, site_index, testScope(11), 0);

    var keys_by_scope = [_]u64{0} ** 16;
    var items_by_scope = [_]u64{0} ** 16;
    keys_by_scope[10] = 1;
    items_by_scope[10] = 100;
    keys_by_scope[11] = 2;
    items_by_scope[11] = 200;

    var hooks = TestSyncHooks{
        .keys_by_scope = &keys_by_scope,
        .items_by_scope = &items_by_scope,
        .next_scope_id = testScope(12),
        .forced_hash = 0,
    };
    defer hooks.deinit(std.testing.allocator);

    const keys = [_]u64{ 2, 1 };
    const items = [_]u64{ 200, 100 };
    const diff = syncRows(std.testing.allocator, &sites, &memberships, site_index, test_parent_scope, test_site_ordinal, &keys, &items, &hooks);
    defer diff.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(ids.ScopeId, &.{ testScope(11), testScope(10) }, diff.scope_ids);
    try std.testing.expectEqualSlices(bool, &.{ false, false }, diff.row_items_changed);
    try std.testing.expectEqualSlices(bool, &.{ false, false }, diff.scope_created);
    try std.testing.expectEqualSlices(ids.ScopeId, &.{}, diff.removed_scope_ids);
    try std.testing.expectEqual(@as(u64, 2), diff.rows_reused);
    try std.testing.expectEqual(@as(u64, 0), diff.rows_created);
    try std.testing.expectEqual(@as(u64, 0), diff.rows_removed);
    try std.testing.expectEqualSlices(ids.ScopeId, &.{ testScope(11), testScope(10) }, sites.items[site_index].scope_ids.items);
    try std.testing.expectEqual(Membership{ .site_index = site_index, .row_index = 0 }, memberships.items[11].?);
    try std.testing.expectEqual(Membership{ .site_index = site_index, .row_index = 1 }, memberships.items[10].?);
    try std.testing.expectEqual(@as(usize, 1), sites.items[site_index].hash_heads.get(0).?);
    try std.testing.expectEqual(@as(usize, 0), sites.items[site_index].hash_links.items[1]);
}

test "each runtime removes rows and rewrites moved memberships" {
    var sites: std.ArrayListUnmanaged(Site) = .empty;
    var indexes: SiteIndexMap = .empty;
    var memberships: std.ArrayListUnmanaged(?Membership) = .empty;
    defer clearSites(std.testing.allocator, &sites, &indexes, &memberships);

    const site_index = ensureSiteIndex(std.testing.allocator, &sites, &indexes, test_parent_scope, test_site_ordinal);
    appendRowToSiteIndex(std.testing.allocator, &sites, &memberships, site_index, testScope(10), 5);
    appendRowToSiteIndex(std.testing.allocator, &sites, &memberships, site_index, testScope(11), 6);
    appendRowToSiteIndex(std.testing.allocator, &sites, &memberships, site_index, testScope(12), 7);

    const hashes = [_]u64{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5, 6, 7 };
    const row_keys = TestRowKeys{ .hashes = &hashes };
    removeRowFromSiteIndex(&sites, &memberships, testScope(10), 5, &row_keys);

    try std.testing.expectEqualSlices(ids.ScopeId, &.{ testScope(12), testScope(11) }, sites.items[site_index].scope_ids.items);
    try std.testing.expectEqual(@as(?Membership, null), memberships.items[10]);
    try std.testing.expectEqual(Membership{ .site_index = site_index, .row_index = 0 }, memberships.items[12].?);
    try std.testing.expectEqual(@as(usize, 0), sites.items[site_index].hash_heads.get(7).?);
    try std.testing.expectEqual(@as(?usize, null), sites.items[site_index].hash_heads.get(5));
}

test "prepared row removals fail without mutation and apply without allocation" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var sites: std.ArrayListUnmanaged(Site) = .empty;
    var indexes: SiteIndexMap = .empty;
    var memberships: std.ArrayListUnmanaged(?Membership) = .empty;
    defer clearSites(std.testing.allocator, &sites, &indexes, &memberships);
    const site_index = ensureSiteIndex(std.testing.allocator, &sites, &indexes, test_parent_scope, test_site_ordinal);
    appendRowToSiteIndex(std.testing.allocator, &sites, &memberships, site_index, testScope(10), 5);
    appendRowToSiteIndex(std.testing.allocator, &sites, &memberships, site_index, testScope(11), 6);
    appendRowToSiteIndex(std.testing.allocator, &sites, &memberships, site_index, testScope(12), 7);
    const hashes = [_]u64{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5, 6, 7 };
    const row_keys = TestRowKeys{ .hashes = &hashes };

    var failing = FaultAllocator.init(std.testing.allocator);
    failing.configure(1);
    try std.testing.expectError(error.OutOfMemory, prepareRowRemovals(failing.allocator(), sites.items, memberships.items, &.{.{ .scope_id = testScope(10), .key_hash = 5 }}));
    try std.testing.expectEqualSlices(ids.ScopeId, &.{ testScope(10), testScope(11), testScope(12) }, sites.items[site_index].scope_ids.items);
    try std.testing.expectEqual(Membership{ .site_index = site_index, .row_index = 0 }, memberships.items[10].?);

    var fault = FaultAllocator.init(std.testing.allocator);
    var prepared = try prepareRowRemovals(fault.allocator(), sites.items, memberships.items, &.{.{ .scope_id = testScope(10), .key_hash = 5 }});
    defer prepared.deinit(fault.allocator());
    fault.configure(1);
    prepared.apply(std.testing.allocator, &sites, &indexes, &memberships, &row_keys);
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqualSlices(ids.ScopeId, &.{ testScope(12), testScope(11) }, sites.items[site_index].scope_ids.items);
    try std.testing.expectEqual(@as(?Membership, null), memberships.items[10]);
    try std.testing.expectEqual(Membership{ .site_index = site_index, .row_index = 0 }, memberships.items[12].?);
}

test "prepared row removals retire empty site and maintained index" {
    var sites: std.ArrayListUnmanaged(Site) = .empty;
    var indexes: SiteIndexMap = .empty;
    var memberships: std.ArrayListUnmanaged(?Membership) = .empty;
    defer clearSites(std.testing.allocator, &sites, &indexes, &memberships);
    const site_index = ensureSiteIndex(std.testing.allocator, &sites, &indexes, test_parent_scope, test_site_ordinal);
    appendRowToSiteIndex(std.testing.allocator, &sites, &memberships, site_index, testScope(10), 5);
    const hashes = [_]u64{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5 };
    const row_keys = TestRowKeys{ .hashes = &hashes };
    var prepared = try prepareRowRemovals(std.testing.allocator, sites.items, memberships.items, &.{.{ .scope_id = testScope(10), .key_hash = 5 }});
    defer prepared.deinit(std.testing.allocator);
    prepared.apply(std.testing.allocator, &sites, &indexes, &memberships, &row_keys);
    try std.testing.expectEqual(@as(usize, 0), sites.items.len);
    try std.testing.expectEqual(@as(?usize, null), indexes.get(.{ .parent_scope_id = test_parent_scope, .site_ordinal = test_site_ordinal }));
    try std.testing.expectEqual(@as(?Membership, null), memberships.items[10]);
}

test "prepared row removals retain empty site for an active descriptor without allocation" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var sites: std.ArrayListUnmanaged(Site) = .empty;
    var indexes: SiteIndexMap = .empty;
    var memberships: std.ArrayListUnmanaged(?Membership) = .empty;
    defer clearSites(std.testing.allocator, &sites, &indexes, &memberships);
    const site_index = ensureSiteIndex(std.testing.allocator, &sites, &indexes, test_parent_scope, test_site_ordinal);
    appendRowToSiteIndex(std.testing.allocator, &sites, &memberships, site_index, testScope(10), 5);
    const ActiveRowKeys = struct {
        /// Returns the retained test row's stable key hash.
        pub fn rowKeyHash(_: *@This(), scope_id: ids.ScopeId) u64 {
            std.debug.assert(scope_id == testScope(10));
            return 5;
        }
        /// Models an active descriptor owning the otherwise-empty test site.
        pub fn siteRemainsActive(_: *@This(), key: SiteKey) bool {
            return key.parent_scope_id == test_parent_scope and key.site_ordinal == test_site_ordinal;
        }
    };
    var row_keys = ActiveRowKeys{};
    var fault = FaultAllocator.init(std.testing.allocator);
    var prepared = try prepareRowRemovals(fault.allocator(), sites.items, memberships.items, &.{.{ .scope_id = testScope(10), .key_hash = 5 }});
    defer prepared.deinit(fault.allocator());
    fault.configure(1);
    prepared.apply(std.testing.allocator, &sites, &indexes, &memberships, &row_keys);
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqual(@as(usize, 1), sites.items.len);
    try std.testing.expectEqual(@as(usize, 0), sites.items[0].scope_ids.items.len);
    try std.testing.expectEqual(@as(?usize, 0), indexes.get(.{ .parent_scope_id = test_parent_scope, .site_ordinal = test_site_ordinal }));
    try std.testing.expectEqual(@as(?Membership, null), memberships.items[10]);
}

test "each runtime replaces row order and rebuilds indexes" {
    var sites: std.ArrayListUnmanaged(Site) = .empty;
    var indexes: SiteIndexMap = .empty;
    var memberships: std.ArrayListUnmanaged(?Membership) = .empty;
    defer clearSites(std.testing.allocator, &sites, &indexes, &memberships);

    const site_index = ensureSiteIndex(std.testing.allocator, &sites, &indexes, test_parent_scope, test_site_ordinal);
    appendRowToSiteIndex(std.testing.allocator, &sites, &memberships, site_index, testScope(10), 5);
    appendRowToSiteIndex(std.testing.allocator, &sites, &memberships, site_index, testScope(11), 6);

    const hashes = [_]u64{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5, 6, 5 };
    const row_keys = TestRowKeys{ .hashes = &hashes };
    replaceSiteRows(std.testing.allocator, &sites, &memberships, site_index, &.{ testScope(12), testScope(10) }, &row_keys);

    try std.testing.expectEqualSlices(ids.ScopeId, &.{ testScope(12), testScope(10) }, sites.items[site_index].scope_ids.items);
    try std.testing.expectEqual(@as(?Membership, null), memberships.items[11]);
    try std.testing.expectEqual(Membership{ .site_index = site_index, .row_index = 0 }, memberships.items[12].?);
    try std.testing.expectEqual(Membership{ .site_index = site_index, .row_index = 1 }, memberships.items[10].?);
    try std.testing.expectEqual(@as(usize, 1), sites.items[site_index].hash_heads.get(5).?);
    try std.testing.expectEqual(@as(usize, 0), sites.items[site_index].hash_links.items[1]);
}

test "each runtime render segments expose scope order" {
    const segments = [_]RenderSegment{
        .{ .scope_id = testScope(10), .start = 2, .len = 3 },
        .{ .scope_id = testScope(11), .start = 5, .len = 1 },
    };
    const scope_ids = renderSegmentScopeIds(std.testing.allocator, &segments);
    defer std.testing.allocator.free(scope_ids);

    try std.testing.expectEqualSlices(ids.ScopeId, &.{ testScope(10), testScope(11) }, scope_ids);
    try std.testing.expect(diffPreservesSurvivorRenderOrder(&.{ testScope(10), testScope(11), testScope(12) }, &.{ testScope(10), testScope(12) }));
    try std.testing.expect(!diffPreservesSurvivorRenderOrder(&.{ testScope(10), testScope(11), testScope(12) }, &.{ testScope(12), testScope(10) }));
}

test "each runtime render range helpers choose insertion points and adjust ranges" {
    var ranges: std.AutoHashMapUnmanaged(ids.ScopeId, RenderSegment) = .{};
    defer ranges.deinit(std.testing.allocator);

    ranges.put(std.testing.allocator, testScope(10), .{ .scope_id = testScope(10), .start = 4, .len = 2 }) catch @panic("out of memory");
    ranges.put(std.testing.allocator, testScope(12), .{ .scope_id = testScope(12), .start = 9, .len = 1 }) catch @panic("out of memory");

    try std.testing.expectEqual(@as(usize, 4), renderInsertIndexForRowRanges(3, &ranges, &.{ testScope(10), testScope(11), testScope(12) }, 0));
    try std.testing.expectEqual(@as(usize, 9), renderInsertIndexForRowRanges(3, &ranges, &.{ testScope(10), testScope(11), testScope(12) }, 1));
    try std.testing.expectEqual(@as(usize, 10), renderInsertIndexForRowRanges(3, &ranges, &.{ testScope(10), testScope(12), testScope(11) }, 2));
    try std.testing.expectEqual(@as(usize, 4), renderInsertIndexForRowRanges(3, &ranges, &.{ testScope(11), testScope(10), testScope(12) }, 0));
    try std.testing.expectEqual(@as(usize, 3), renderInsertIndexForRowRanges(3, &ranges, &.{testScope(11)}, 0));

    updateRenderRange(&ranges, std.testing.allocator, testScope(10), 4, 2, 3);
    try std.testing.expectEqual(RenderSegment{ .scope_id = testScope(10), .start = 4, .len = 3 }, ranges.get(testScope(10)).?);
    try std.testing.expectEqual(RenderSegment{ .scope_id = testScope(12), .start = 10, .len = 1 }, ranges.get(testScope(12)).?);

    updateRenderRange(&ranges, std.testing.allocator, testScope(10), 4, 3, 0);
    try std.testing.expectEqual(@as(?RenderSegment, null), ranges.get(testScope(10)));
    try std.testing.expectEqual(RenderSegment{ .scope_id = testScope(12), .start = 7, .len = 1 }, ranges.get(testScope(12)).?);
}
