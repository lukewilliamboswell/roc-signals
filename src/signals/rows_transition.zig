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
    KeyMismatch,
    MissingSlot,
    DuplicateSlot,
};

fn renderOrderError(err: rows_store.RenderOrder.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ResourceLimit => error.ResourceLimit,
        error.DuplicateRow => error.DuplicateSlot,
        error.InvalidRow, error.InvalidRange, error.AnchorInsideRange => error.MissingSlot,
        error.InvalidSpan => error.InvalidOwnerToken,
    };
}

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

/// Canonical ABI operations addressed only by stable Roc item slots. Zero in a
/// `before_slot` field denotes the end of the site.
pub const StableEdit = union(enum) {
    insert: struct { slot: u64, before_slot: u64, key: []const u8, metadata: RowMetadata },
    remove: struct { first_slot: u64, count: u64 },
    move: struct { first_slot: u64, count: u64, before_slot: u64 },
    update: struct { slot: u64, key: []const u8, metadata: RowMetadata },
    clear,
};

/// Render-order portion of one validated stable-slot edit. The prepared
/// transition owns this journal so downstream structure never retains raw
/// callback scratch from `Rows.copy_delta`.
pub const OrderEdit = union(enum) {
    insert: struct { slot: u64, before_slot: u64 },
    remove: struct { first_slot: u64, count: u64 },
    move: struct { first_slot: u64, count: u64, before_slot: u64 },
    clear: struct { count: usize },
};

/// Provisional row identity available to a row builder before publication.
pub const CreatedRow = struct {
    row_id: RowId,
    key: []const u8,
    metadata: RowMetadata,
};

/// One row visible in the prepared candidate order before publication.
pub const CandidateRow = struct {
    row_id: ?RowId,
    key: []const u8,
    metadata: RowMetadata,
    created: bool,
    item_changed: bool,
};

// Engine publication mapping (kept here beside the ownership boundary):
//
//   Store SiteId     -> one `(parent_scope_id, site_ordinal)` structural site
//   Store RowId      -> stable host row identity; never exposed to Roc
//   RowMetadata.slot -> Roc's stable item slot used by clone/compare callbacks
//   RowMetadata.scope_id -> the row scope that owns graph/render/lifecycle state
//   CreatedRow       -> a preclaimed RowId paired with a preclaimed row scope
//   removedRows()    -> committed RowIds whose metadata identifies retirement roots
//
// Preparation must claim row scopes/handles and build render journal entries
// before `commit`; publication first commits those prepared owners and then this
// transition without allocating. Abort releases provisional scopes/handles and
// this transition together, leaving both the committed Store and DOM unchanged.

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
    item_changed: bool,
    order_touched: bool,
};

const Fresh = struct {
    key: []u8,
    metadata: RowMetadata,
    claim: ?RowId = null,
};

const Phase = enum { preparing, prepared, committed };

/// Allocation-free traversal over the overlay's final intrusive order.
pub const CandidateIterator = struct {
    transition: *const PreparedTransition,
    next_ref: ?NodeRef,

    /// Advances without materializing untouched committed rows into scratch.
    pub fn next(self: *CandidateIterator) ?CandidateRow {
        const ref = self.next_ref orelse return null;
        if (self.transition.shadows.get(ref)) |shadow| {
            if (!shadow.live) @panic("candidate order referenced a removed row");
            self.next_ref = shadow.next;
            const row_id = if (isFresh(ref)) self.transition.fresh.items[freshIndex(ref)].claim else existingId(ref);
            return .{
                .row_id = row_id,
                .key = shadow.key,
                .metadata = shadow.metadata,
                .created = isFresh(ref),
                .item_changed = shadow.item_changed,
            };
        }
        if (isFresh(ref)) @panic("candidate order omitted a provisional shadow");
        const row = self.transition.store.getRowConst(self.transition.site_id, existingId(ref)) catch @panic("candidate order referenced a stale committed row");
        self.next_ref = if (row.next) |next_row| existingRef(next_row) else null;
        return .{
            .row_id = existingId(ref),
            .key = row.key,
            .metadata = row.metadata,
            .created = false,
            .item_changed = false,
        };
    }
};

/// Allocation-free traversal over changed surviving rows in the overlay.
///
/// The iterator examines only transition shadows, whose count is bounded by
/// the normalized edit operands and the intrusive-order neighbors they touch.
/// Created rows are excluded because they have no committed row source to
/// dirty; removed rows are excluded because their scopes retire at commit.
pub const ChangedCandidateIterator = struct {
    transition: *const PreparedTransition,
    touched_index: usize = 0,

    /// Advances to the next changed row that survives the transition.
    pub fn next(self: *ChangedCandidateIterator) ?CandidateRow {
        while (self.touched_index < self.transition.touched.items.len) {
            const ref = self.transition.touched.items[self.touched_index];
            self.touched_index += 1;
            const shadow = self.transition.shadows.get(ref) orelse @panic("Rows touched list omitted its shadow");
            if (!shadow.live or !shadow.was_live or !shadow.item_changed) continue;
            return .{
                .row_id = existingId(ref),
                .key = shadow.key,
                .metadata = shadow.metadata,
                .created = false,
                .item_changed = true,
            };
        }
        return null;
    }
};

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
    slot_states: std.AutoHashMapUnmanaged(u64, KeyState) = .empty,
    fresh: std.ArrayListUnmanaged(Fresh) = .empty,
    order_edits: std.ArrayListUnmanaged(OrderEdit) = .empty,
    render_order: rows_store.RenderOrder.PreparedEdits,
    render_spans: std.AutoHashMapUnmanaged(u64, rows_store.RowRenderSpan) = .empty,
    order_link_touches: usize = 0,
    removed_rows: []RowId = &.{},
    created_rows: []CreatedRow = &.{},
    row_claims_prepared: bool = false,
    removals_committed: bool = false,
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
            .render_order = committed.render_order.prepare(),
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

    /// Prepares the stable-slot delta emitted by `Rows.copy_delta`. All range
    /// walks are bounded by the advertised changed count; no committed-site
    /// scan is used to discover operands.
    pub fn prepareStable(allocator: std.mem.Allocator, store: *Store, site_id: SiteId, parent_owner: OwnerToken, next_owner: OwnerToken, edits: []const StableEdit) Error!PreparedTransition {
        const committed = store.getSiteConst(site_id) catch return error.InvalidSite;
        if (committed.owner_token != parent_owner) return error.ParentMismatch;
        if (next_owner.raw() == 0 or next_owner == parent_owner) return error.InvalidOwnerToken;
        var self = PreparedTransition{ .allocator = allocator, .store = store, .site_id = site_id, .next_owner = next_owner, .head = if (committed.head) |row| existingRef(row) else null, .tail = if (committed.tail) |row| existingRef(row) else null, .len = committed.len, .render_order = committed.render_order.prepare() };
        errdefer self.deinit();
        for (edits) |edit| switch (edit) {
            .insert => |value| try self.applyStableInsert(value.slot, value.before_slot, value.key, value.metadata),
            .remove => |value| try self.applyStableRemove(value.first_slot, value.count),
            .move => |value| try self.applyStableMove(value.first_slot, value.count, value.before_slot),
            .update => |value| try self.applyStableUpdate(value.slot, value.key, value.metadata),
            .clear => try self.applyClear(),
        };
        try self.finishPreparation();
        return self;
    }

    /// Prepares the first exact snapshot for a newly claimed empty site. The
    /// site's owner is already the snapshot generation, so this path does not
    /// invent a synthetic parent token merely to reuse delta authentication.
    pub fn prepareInitial(allocator: std.mem.Allocator, store: *Store, site_id: SiteId, owner: OwnerToken, edits: []const StableEdit) Error!PreparedTransition {
        const committed = store.getSiteConst(site_id) catch return error.InvalidSite;
        if (committed.owner_token != owner or committed.len != 0) return error.ParentMismatch;
        var self = PreparedTransition{ .allocator = allocator, .store = store, .site_id = site_id, .next_owner = owner, .head = null, .tail = null, .len = 0, .render_order = committed.render_order.prepare() };
        errdefer self.deinit();
        for (edits) |edit| switch (edit) {
            .insert => |value| try self.applyStableInsert(value.slot, value.before_slot, value.key, value.metadata),
            else => return error.ParentMismatch,
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

    /// Starts allocation-free traversal of the fully prepared candidate order.
    pub fn iterateCandidate(self: *const PreparedTransition) CandidateIterator {
        if (self.phase == .preparing) @panic("Rows candidate iterated before preparation completed");
        return .{ .transition = self, .next_ref = self.head };
    }

    /// Returns the exact final row count without building a positional array.
    pub fn candidateLen(self: *const PreparedTransition) usize {
        if (self.phase == .preparing) @panic("Rows candidate length read before preparation completed");
        return self.len;
    }

    /// Bounds changed-row iteration by transition-local work rather than the
    /// total candidate length. Callers may use this to reserve proportional
    /// scratch before walking `iterateChangedCandidates`.
    pub fn changedCandidateUpperBound(self: *const PreparedTransition) usize {
        if (self.phase == .preparing) @panic("Rows changed-row bound read before preparation completed");
        return self.touched.items.len;
    }

    /// Starts allocation-free traversal of changed surviving candidate rows.
    pub fn iterateChangedCandidates(self: *const PreparedTransition) ChangedCandidateIterator {
        if (self.phase == .preparing) @panic("Rows changed candidates iterated before preparation completed");
        return .{ .transition = self };
    }

    /// Returns the validated render-order journal for this transition. Entries
    /// contain stable slots only; keys and callback sinks retain their narrower
    /// reconciliation ownership.
    pub fn orderEdits(self: *const PreparedTransition) []const OrderEdit {
        if (self.phase == .preparing) @panic("Rows order journal read before preparation completed");
        return self.order_edits.items;
    }

    /// Counts distinct candidate row records whose predecessor or successor
    /// was touched while applying the validated order batch. Item-only updates
    /// and normalized no-op moves contribute zero.
    pub fn orderLinksTouched(self: *const PreparedTransition) usize {
        if (self.phase == .preparing) @panic("Rows order-link count read before preparation completed");
        return self.order_link_touches;
    }

    /// Returns candidate render-order work without walking untouched rows.
    /// Root moves count direct roots in effective moved row ranges; created
    /// and removed roots are reported separately by structural journals.
    pub fn renderOrderStats(self: *const PreparedTransition) rows_store.RenderOrder.Stats {
        if (self.phase == .preparing) @panic("Rows render-order stats read before preparation completed");
        return self.render_order.stats();
    }

    /// Resolves the first direct render root owned by `slot` or a later
    /// candidate row. The aggregate index skips arbitrarily long runs of rows
    /// that render no direct root.
    pub fn firstRenderRootAtOrAfterSlot(self: *const PreparedTransition, slot: u64) Error!?rows_store.RenderOrder.RootAnchor {
        if (self.phase == .preparing) @panic("Rows render anchor read before preparation completed");
        const row_id = try self.resolveOrderSlot(slot);
        return self.render_order.firstRootAtOrAfter(row_id) catch |err| return renderOrderError(err);
    }

    /// Resolves one live candidate row by its adapter-private stable item slot
    /// without traversing candidate order.
    pub fn candidateBySlot(self: *const PreparedTransition, slot: u64) ?CandidateRow {
        if (self.phase == .preparing) @panic("Rows candidate slot read before preparation completed");
        const state: KeyState = self.slot_states.get(slot) orelse blk: {
            const row_id = self.store.findItemSlot(self.site_id, slot) catch return null;
            break :blk KeyState{ .node = existingRef(row_id orelse return null), .live = true };
        };
        if (!state.live) return null;
        var candidate = self.candidateForRef(state.node);
        if (self.render_spans.get(slot)) |span| candidate.metadata.render_span = span;
        return candidate;
    }

    /// Reserves provisional render-span entries before materializing collected
    /// descriptors. Publication can then install every anchor without
    /// allocating, including for a structurally re-collected untouched row.
    pub fn prepareRenderSpanUpdates(self: *PreparedTransition, additional: usize) Error!void {
        if (self.phase != .prepared) return error.InvalidOwnerToken;
        self.render_spans.ensureUnusedCapacity(self.allocator, std.math.cast(u32, additional) orelse return error.ResourceLimit) catch return error.OutOfMemory;
    }

    /// Installs validated render anchors into preflighted transition storage.
    /// The candidate and committed store remain unchanged until commit.
    pub fn setCandidateRenderSpanAssumeCapacity(self: *PreparedTransition, slot: u64, span: rows_store.RowRenderSpan) Error!void {
        if (self.phase != .prepared or !span.valid() or self.candidateBySlot(slot) == null) return error.InvalidOwnerToken;
        self.render_spans.putAssumeCapacity(slot, span);
        const row_id = try self.resolveOrderSlot(slot);
        _ = self.render_order.updateSpan(row_id, span) catch |err| return renderOrderError(err);
    }

    /// Publishes the candidate generation without allocation. Any scope/value
    /// preparation associated with `createdRows` and `removedRows` must already
    /// have succeeded before entering this irreversible boundary.
    pub fn commit(self: *PreparedTransition) void {
        if (self.phase != .prepared) @panic("Rows transition committed outside its prepared phase");
        self.render_order.commitAssumePreflighted();
        self.commitRemovalsEarly();

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

        var render_spans = self.render_spans.iterator();
        while (render_spans.next()) |entry| {
            const row_id = (self.store.findItemSlot(self.site_id, entry.key_ptr.*) catch @panic("prepared render span lost its Rows site")) orelse @panic("prepared render span lost its candidate row");
            const row = self.store.getRow(self.site_id, row_id) catch @panic("prepared render span referenced a stale candidate row");
            row.metadata.render_span = entry.value_ptr.*;
        }

        const site = self.store.getSite(self.site_id) catch @panic("prepared Rows site became stale before commit");
        site.head = self.resolveOptional(self.head);
        site.tail = self.resolveOptional(self.tail);
        site.len = self.len;
        site.owner_token = self.next_owner;
        self.phase = .committed;
    }

    /// Retires rows before another transition publishes reused scope ids while
    /// leaving fresh-row claims untouched and therefore in their globally
    /// preflighted commit order. This is an irreversible commit-phase step.
    pub fn commitRemovalsEarly(self: *PreparedTransition) void {
        if (self.phase != .prepared) @panic("Rows removals committed outside the prepared phase");
        if (self.removals_committed) return;
        for (self.removed_rows) |row_id| {
            const key = self.store.removePreparedRow(self.site_id, row_id);
            self.store.allocator.free(key);
        }
        self.removals_committed = true;
    }

    /// Releases candidate keys and scratch state. Before commit this is an
    /// abort; after commit transferred key allocations remain site-owned.
    pub fn deinit(self: *PreparedTransition) void {
        if (self.phase != .committed and self.row_claims_prepared) {
            for (self.created_rows) |created| self.store.releaseRowClaims(&.{created.row_id});
        }
        for (self.fresh.items) |fresh| if (fresh.key.len != 0) self.store.allocator.free(fresh.key);
        self.shadows.deinit(self.allocator);
        self.touched.deinit(self.allocator);
        self.key_states.deinit(self.allocator);
        self.slot_states.deinit(self.allocator);
        self.fresh.deinit(self.allocator);
        self.order_edits.deinit(self.allocator);
        self.render_order.deinit();
        self.render_spans.deinit(self.allocator);
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
            error.InvalidSite, error.SiteNotEmpty, error.InvalidRow, error.WrongSite, error.DuplicateKey, error.DuplicateItemSlot, error.MissingKey => error.InvalidSite,
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
        self.row_claims_prepared = true;
        var order_link_touches: usize = 0;
        var shadows = self.shadows.valueIterator();
        while (shadows.next()) |shadow| if (shadow.order_touched) {
            order_link_touches = std.math.add(usize, order_link_touches, 1) catch return error.ResourceLimit;
        };
        self.order_link_touches = order_link_touches;
        try self.prepareRenderOrder();
        self.phase = .prepared;
    }

    fn prepareRenderOrder(self: *PreparedTransition) Error!void {
        for (self.order_edits.items) |edit| switch (edit) {
            .insert => |value| {
                const row_id = try self.resolveOrderSlot(value.slot);
                const before = if (value.before_slot == 0) null else try self.resolveOrderSlot(value.before_slot);
                const span = try self.renderSpanForSlot(value.slot);
                self.render_order.insertBefore(row_id, before, span) catch |err| return renderOrderError(err);
            },
            .remove => |value| {
                const row_id = try self.resolveOrderSlot(value.first_slot);
                _ = self.render_order.removeRange(row_id, std.math.cast(usize, value.count) orelse return error.ResourceLimit) catch |err| return renderOrderError(err);
            },
            .move => |value| {
                const row_id = try self.resolveOrderSlot(value.first_slot);
                const before = if (value.before_slot == 0) null else try self.resolveOrderSlot(value.before_slot);
                _ = self.render_order.moveRange(row_id, std.math.cast(usize, value.count) orelse return error.ResourceLimit, before) catch |err| return renderOrderError(err);
            },
            .clear => |value| {
                if (value.count != self.render_order.len()) return error.InvalidOwnerToken;
                if (value.count != 0) {
                    const first = self.render_order.rowAt(0) catch return error.InvalidOwnerToken;
                    _ = self.render_order.removeRange(first, value.count) catch |err| return renderOrderError(err);
                }
            },
        };
        if (self.render_order.len() != self.len) return error.InvalidOwnerToken;
        self.render_order.preflightCommit() catch |err| return renderOrderError(err);
    }

    fn resolveOrderSlot(self: *const PreparedTransition, slot: u64) Error!RowId {
        const state = self.slot_states.get(slot) orelse blk: {
            const row_id = (self.store.findItemSlot(self.site_id, slot) catch return error.InvalidSite) orelse return error.MissingSlot;
            break :blk KeyState{ .node = existingRef(row_id), .live = true };
        };
        if (!isFresh(state.node)) return existingId(state.node);
        return self.fresh.items[freshIndex(state.node)].claim orelse error.InvalidOwnerToken;
    }

    fn renderSpanForSlot(self: *const PreparedTransition, slot: u64) Error!rows_store.RowRenderSpan {
        const state = self.slot_states.get(slot) orelse blk: {
            const row_id = (self.store.findItemSlot(self.site_id, slot) catch return error.InvalidSite) orelse return error.MissingSlot;
            break :blk KeyState{ .node = existingRef(row_id), .live = true };
        };
        if (self.shadows.get(state.node)) |shadow| return shadow.metadata.render_span;
        if (isFresh(state.node)) return error.InvalidOwnerToken;
        return (self.store.getRowConst(self.site_id, existingId(state.node)) catch return error.InvalidSite).metadata.render_span;
    }

    fn applyInsert(self: *PreparedTransition, insert: Insert) Error!void {
        if (insert.metadata.item_slot == 0) return error.DuplicateSlot;
        if (try self.lookupSlot(insert.metadata.item_slot)) |state| if (state.live) return error.DuplicateSlot;
        const before = if (insert.before) |key| try self.requireLiveKey(key) else null;
        const before_slot = if (before) |before_ref| (try self.getShadow(before_ref)).metadata.item_slot else 0;
        if (try self.lookupKey(insert.key)) |state| {
            if (state.live) return error.DuplicateKey;
            const shadow = try self.getShadow(state.node);
            if (shadow.metadata.item_slot != insert.metadata.item_slot) {
                if (try self.lookupSlot(insert.metadata.item_slot)) |slot_state| if (slot_state.live) return error.DuplicateSlot;
                try self.putSlotState(shadow.metadata.item_slot, .{ .node = state.node, .live = false });
            }
            shadow.metadata = insert.metadata;
            shadow.item_changed = true;
            const stable_key = shadow.key;
            try self.attachBefore(state.node, before);
            try self.putKeyState(stable_key, .{ .node = state.node, .live = true });
            try self.putSlotState(insert.metadata.item_slot, .{ .node = state.node, .live = true });
            try self.order_edits.append(self.allocator, .{ .insert = .{
                .slot = insert.metadata.item_slot,
                .before_slot = before_slot,
            } });
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
            .item_changed = true,
            .order_touched = false,
        });
        try self.attachBefore(ref, before);
        try self.putKeyState(owned_key, .{ .node = ref, .live = true });
        try self.putSlotState(insert.metadata.item_slot, .{ .node = ref, .live = true });
        try self.order_edits.append(self.allocator, .{ .insert = .{
            .slot = insert.metadata.item_slot,
            .before_slot = before_slot,
        } });
    }

    fn applyRemove(self: *PreparedTransition, key: []const u8) Error!void {
        const ref = try self.requireLiveKey(key);
        const current = (try self.getShadow(ref)).*;
        const stable_key = current.key;
        try self.detach(ref);
        try self.putKeyState(stable_key, .{ .node = ref, .live = false });
        try self.putSlotState(current.metadata.item_slot, .{ .node = ref, .live = false });
        try self.order_edits.append(self.allocator, .{ .remove = .{ .first_slot = current.metadata.item_slot, .count = 1 } });
    }

    fn applyMove(self: *PreparedTransition, move: Move) Error!void {
        const ref = try self.requireLiveKey(move.key);
        const before = if (move.before) |key| try self.requireLiveKey(key) else null;
        if (before != null and before.? == ref) return;
        const current = (try self.getShadow(ref)).*;
        if (current.next == before) return;
        const before_slot = if (before) |before_ref| (try self.getShadow(before_ref)).metadata.item_slot else 0;
        try self.detach(ref);
        try self.attachBefore(ref, before);
        try self.order_edits.append(self.allocator, .{ .move = .{
            .first_slot = current.metadata.item_slot,
            .count = 1,
            .before_slot = before_slot,
        } });
    }

    fn applySet(self: *PreparedTransition, set: Set) Error!void {
        const ref = try self.requireLiveKey(set.key);
        const shadow = try self.getShadow(ref);
        if (shadow.metadata.item_slot != set.metadata.item_slot) return error.DuplicateSlot;
        shadow.metadata = set.metadata;
        shadow.item_changed = true;
    }

    fn applyClear(self: *PreparedTransition) Error!void {
        const count = self.len;
        while (self.head) |ref| {
            const key = (try self.getShadow(ref)).key;
            const slot = (try self.getShadow(ref)).metadata.item_slot;
            try self.detach(ref);
            try self.putKeyState(key, .{ .node = ref, .live = false });
            try self.putSlotState(slot, .{ .node = ref, .live = false });
        }
        if (count != 0) try self.order_edits.append(self.allocator, .{ .clear = .{ .count = count } });
    }

    fn applyStableInsert(self: *PreparedTransition, slot: u64, before_slot: u64, key: []const u8, metadata: RowMetadata) Error!void {
        if (slot == 0 or metadata.item_slot != slot) return error.DuplicateSlot;
        const before = if (before_slot == 0) null else try self.requireLiveSlot(before_slot);
        if (try self.lookupSlot(slot)) |state| if (state.live) return error.DuplicateSlot;
        if (try self.lookupKey(key)) |state| if (state.live) return error.DuplicateKey;

        const owned_key = try self.store.allocator.dupe(u8, key);
        errdefer self.store.allocator.free(owned_key);
        const index = self.fresh.items.len;
        try self.fresh.append(self.allocator, .{ .key = owned_key, .metadata = metadata });
        errdefer _ = self.fresh.pop();
        const ref = freshRef(index);
        try self.insertShadow(ref, .{ .key = owned_key, .metadata = metadata, .previous = null, .next = null, .live = false, .was_live = false, .item_changed = true, .order_touched = false });
        try self.attachBefore(ref, before);
        try self.putKeyState(owned_key, .{ .node = ref, .live = true });
        try self.putSlotState(slot, .{ .node = ref, .live = true });
        try self.order_edits.append(self.allocator, .{ .insert = .{ .slot = slot, .before_slot = before_slot } });
    }

    fn applyStableRemove(self: *PreparedTransition, first_slot: u64, count: u64) Error!void {
        if (count == 0) return error.MissingSlot;
        var current = try self.requireLiveSlot(first_slot);
        var remaining = count;
        while (remaining != 0) : (remaining -= 1) {
            const shadow = (try self.getShadow(current)).*;
            const next = shadow.next;
            try self.detach(current);
            try self.putKeyState(shadow.key, .{ .node = current, .live = false });
            try self.putSlotState(shadow.metadata.item_slot, .{ .node = current, .live = false });
            if (remaining != 1) current = next orelse return error.MissingSlot;
        }
        try self.order_edits.append(self.allocator, .{ .remove = .{ .first_slot = first_slot, .count = count } });
    }

    fn applyStableMove(self: *PreparedTransition, first_slot: u64, count: u64, before_slot: u64) Error!void {
        if (count == 0) return error.MissingSlot;
        const refs = try self.allocator.alloc(NodeRef, std.math.cast(usize, count) orelse return error.ResourceLimit);
        defer self.allocator.free(refs);
        var current = try self.requireLiveSlot(first_slot);
        for (refs, 0..) |*out, index| {
            out.* = current;
            if (index + 1 != refs.len) current = (try self.getShadow(current)).next orelse return error.MissingSlot;
        }
        const before = if (before_slot == 0) null else try self.requireLiveSlot(before_slot);
        for (refs) |ref| if (before != null and ref == before.?) return;
        const after = (try self.getShadow(refs[refs.len - 1])).next;
        if (after == before) return;
        for (refs) |ref| try self.detach(ref);
        for (refs) |ref| try self.attachBefore(ref, before);
        try self.order_edits.append(self.allocator, .{ .move = .{ .first_slot = first_slot, .count = count, .before_slot = before_slot } });
    }

    fn applyStableUpdate(self: *PreparedTransition, slot: u64, key: []const u8, metadata: RowMetadata) Error!void {
        if (slot == 0 or metadata.item_slot != slot) return error.MissingSlot;
        const ref = try self.requireLiveSlot(slot);
        const shadow = try self.getShadow(ref);
        if (!std.mem.eql(u8, shadow.key, key)) return error.KeyMismatch;
        if (shadow.metadata.scope_id != metadata.scope_id or shadow.metadata.row_handle != metadata.row_handle) return error.InvalidOwnerToken;
        shadow.metadata = metadata;
        shadow.item_changed = true;
    }

    fn lookupSlot(self: *PreparedTransition, slot: u64) Error!?KeyState {
        if (slot == 0) return null;
        if (self.slot_states.get(slot)) |state| return state;
        const row_id = self.store.findItemSlot(self.site_id, slot) catch return error.InvalidSite;
        return if (row_id) |row| .{ .node = existingRef(row), .live = true } else null;
    }

    fn requireLiveSlot(self: *PreparedTransition, slot: u64) Error!NodeRef {
        const state = (try self.lookupSlot(slot)) orelse return error.MissingSlot;
        if (!state.live) return error.MissingSlot;
        return state.node;
    }

    fn putSlotState(self: *PreparedTransition, slot: u64, state: KeyState) Error!void {
        if (slot == 0) return error.DuplicateSlot;
        self.slot_states.put(self.allocator, slot, state) catch return error.OutOfMemory;
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
            .item_changed = false,
            .order_touched = false,
        });
        return self.shadows.getPtr(ref).?;
    }

    fn markOrderTouched(self: *PreparedTransition, ref: NodeRef) Error!void {
        (try self.getShadow(ref)).order_touched = true;
    }

    fn detach(self: *PreparedTransition, ref: NodeRef) Error!void {
        const current = (try self.getShadow(ref)).*;
        if (!current.live) @panic("Rows candidate detached an absent row");
        try self.markOrderTouched(ref);
        if (current.previous) |previous| try self.markOrderTouched(previous);
        if (current.next) |next| try self.markOrderTouched(next);
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
        try self.markOrderTouched(ref);
        if (before) |next| {
            const next_shadow = (try self.getShadow(next)).*;
            if (!next_shadow.live) return error.MissingKey;
            try self.markOrderTouched(next);
            if (next_shadow.previous) |previous| {
                try self.markOrderTouched(previous);
                (try self.getShadow(previous)).next = ref;
            } else self.head = ref;
            const row = try self.getShadow(ref);
            row.previous = next_shadow.previous;
            row.next = next;
            row.live = true;
            (try self.getShadow(next)).previous = ref;
        } else {
            const previous = self.tail;
            if (previous) |row| {
                try self.markOrderTouched(row);
                (try self.getShadow(row)).next = ref;
            } else self.head = ref;
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

    fn candidateForRef(self: *const PreparedTransition, ref: NodeRef) CandidateRow {
        if (self.shadows.get(ref)) |shadow| {
            if (!shadow.live) @panic("removed Rows reference resolved as a candidate");
            return .{
                .row_id = if (isFresh(ref)) self.fresh.items[freshIndex(ref)].claim else existingId(ref),
                .key = shadow.key,
                .metadata = shadow.metadata,
                .created = isFresh(ref),
                .item_changed = shadow.item_changed,
            };
        }
        if (isFresh(ref)) @panic("provisional Rows reference had no candidate shadow");
        const row = self.store.getRowConst(self.site_id, existingId(ref)) catch @panic("candidate slot referenced a stale committed row");
        return .{
            .row_id = existingId(ref),
            .key = row.key,
            .metadata = row.metadata,
            .created = false,
            .item_changed = false,
        };
    }
};

fn expectOrder(store: *const Store, site_id: SiteId, expected: []const []const u8) !void {
    const site = try store.getSiteConst(site_id);
    try std.testing.expectEqual(expected.len, site.len);
    var current = site.head;
    var previous: ?RowId = null;
    for (expected, 0..) |key, index| {
        const row_id = current orelse return error.TestExpectedEqual;
        const row = try store.getRowConst(site_id, row_id);
        try std.testing.expectEqualStrings(key, row.key);
        try std.testing.expectEqual(previous, row.previous);
        try std.testing.expectEqual(row_id, try site.render_order.rowAt(index));
        previous = row_id;
        current = row.next;
    }
    try std.testing.expect(current == null);
    try std.testing.expectEqual(previous, site.tail);
    try std.testing.expectEqual(expected.len, site.render_order.len());
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
        .{ .set = .{ .key = "b", .metadata = .{ .item_slot = 2, .scope_id = 22, .render_span = .{ .first_node = 99, .last_node = 99, .first_root = 99, .last_root = 99, .root_count = 1 } } } },
    };
    var next = try PreparedTransition.prepare(std.testing.allocator, &store, site, try OwnerToken.fromRaw(2), try OwnerToken.fromRaw(3), &edits);
    defer next.deinit();
    try std.testing.expectEqual(@as(usize, 1), next.createdRows().len);
    try std.testing.expectEqual(@as(usize, 1), next.removedRows().len);
    next.commit();

    try expectOrder(&store, site, &.{ "c", "d", "b" });
    const b = (try store.findKey(site, "b")).?;
    try std.testing.expectEqual(@as(u64, 2), (try store.getRowConst(site, b)).metadata.item_slot);
    try std.testing.expectEqual(@as(?u64, 99), (try store.getRowConst(site, b)).metadata.render_span.first_root);
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

test "canonical stable-slot delta resolves ranges without positional scans" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const site = try store.createSite(try OwnerToken.fromRaw(70));
    var initial = try PreparedTransition.prepareStable(std.testing.allocator, &store, site, try OwnerToken.fromRaw(70), try OwnerToken.fromRaw(71), &.{
        .{ .insert = .{ .slot = 11, .before_slot = 0, .key = "a", .metadata = .{ .item_slot = 11, .scope_id = 1 } } },
        .{ .insert = .{ .slot = 22, .before_slot = 0, .key = "b", .metadata = .{ .item_slot = 22, .scope_id = 2 } } },
        .{ .insert = .{ .slot = 33, .before_slot = 0, .key = "c", .metadata = .{ .item_slot = 33, .scope_id = 3 } } },
    });
    defer initial.deinit();
    initial.commit();

    var next = try PreparedTransition.prepareStable(std.testing.allocator, &store, site, try OwnerToken.fromRaw(71), try OwnerToken.fromRaw(72), &.{
        .{ .move = .{ .first_slot = 22, .count = 2, .before_slot = 11 } },
        .{ .update = .{ .slot = 22, .key = "b", .metadata = .{ .item_slot = 22, .scope_id = 2 } } },
    });
    defer next.deinit();
    var candidate = next.iterateCandidate();
    const changed_b = candidate.next().?;
    try std.testing.expectEqualStrings("b", changed_b.key);
    try std.testing.expect(!changed_b.created);
    try std.testing.expect(changed_b.item_changed);
    const moved_c = candidate.next().?;
    try std.testing.expectEqualStrings("c", moved_c.key);
    try std.testing.expect(!moved_c.created);
    try std.testing.expect(!moved_c.item_changed);
    const moved_a = candidate.next().?;
    try std.testing.expectEqualStrings("a", moved_a.key);
    try std.testing.expect(!moved_a.created);
    try std.testing.expect(!moved_a.item_changed);
    try std.testing.expect(candidate.next() == null);
    next.commit();
    try expectOrder(&store, site, &.{ "b", "c", "a" });
    const row = (try store.findItemSlot(site, 22)).?;
    try std.testing.expectEqual(@as(u64, 2), (try store.getRowConst(site, row)).metadata.scope_id);
    try std.testing.expectEqual(row, store.findScope(2).?.row_id);
    try std.testing.expectError(error.KeyMismatch, PreparedTransition.prepareStable(std.testing.allocator, &store, site, try OwnerToken.fromRaw(72), try OwnerToken.fromRaw(73), &.{.{ .update = .{
        .slot = 22,
        .key = "rekeyed",
        .metadata = .{ .item_slot = 22, .scope_id = 2 },
    } }}));
    try expectOrder(&store, site, &.{ "b", "c", "a" });
}

test "stable transition journals only effective order edits and exact touched links" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const site = try store.createSite(try OwnerToken.fromRaw(73));
    var seed = try PreparedTransition.prepareStable(std.testing.allocator, &store, site, try OwnerToken.fromRaw(73), try OwnerToken.fromRaw(74), &.{
        .{ .insert = .{ .slot = 1, .before_slot = 0, .key = "a", .metadata = .{ .item_slot = 1, .scope_id = 1 } } },
        .{ .insert = .{ .slot = 2, .before_slot = 0, .key = "b", .metadata = .{ .item_slot = 2, .scope_id = 2 } } },
        .{ .insert = .{ .slot = 3, .before_slot = 0, .key = "c", .metadata = .{ .item_slot = 3, .scope_id = 3 } } },
        .{ .insert = .{ .slot = 4, .before_slot = 0, .key = "d", .metadata = .{ .item_slot = 4, .scope_id = 4 } } },
    });
    defer seed.deinit();
    seed.commit();

    var moved = try PreparedTransition.prepareStable(std.testing.allocator, &store, site, try OwnerToken.fromRaw(74), try OwnerToken.fromRaw(75), &.{
        .{ .move = .{ .first_slot = 2, .count = 1, .before_slot = 4 } },
        .{ .update = .{ .slot = 2, .key = "b", .metadata = .{ .item_slot = 2, .scope_id = 2 } } },
    });
    defer moved.deinit();
    try std.testing.expectEqual(@as(usize, 1), moved.orderEdits().len);
    try std.testing.expectEqual(OrderEdit{ .move = .{ .first_slot = 2, .count = 1, .before_slot = 4 } }, moved.orderEdits()[0]);
    try std.testing.expectEqual(@as(usize, 4), moved.orderLinksTouched());
    moved.commit();
    try expectOrder(&store, site, &.{ "a", "c", "b", "d" });

    var no_op = try PreparedTransition.prepareStable(std.testing.allocator, &store, site, try OwnerToken.fromRaw(75), try OwnerToken.fromRaw(76), &.{
        .{ .move = .{ .first_slot = 2, .count = 1, .before_slot = 4 } },
        .{ .update = .{ .slot = 2, .key = "b", .metadata = .{ .item_slot = 2, .scope_id = 2 } } },
    });
    defer no_op.deinit();
    try std.testing.expectEqual(@as(usize, 0), no_op.orderEdits().len);
    try std.testing.expectEqual(@as(usize, 0), no_op.orderLinksTouched());
}

test "row render spans preserve empty and multi-root anchors through commit" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const site = try store.createSite(try OwnerToken.fromRaw(76));
    var seed = try PreparedTransition.prepareStable(std.testing.allocator, &store, site, try OwnerToken.fromRaw(76), try OwnerToken.fromRaw(77), &.{.{ .insert = .{
        .slot = 9,
        .before_slot = 0,
        .key = "row",
        .metadata = .{ .item_slot = 9, .scope_id = 9 },
    } }});
    defer seed.deinit();
    try seed.prepareRenderSpanUpdates(1);
    try seed.setCandidateRenderSpanAssumeCapacity(9, .{});
    try std.testing.expectEqual(rows_store.RowRenderSpan{}, seed.candidateBySlot(9).?.metadata.render_span);
    try std.testing.expect((try seed.firstRenderRootAtOrAfterSlot(9)) == null);
    seed.commit();
    const row_id = (try store.findItemSlot(site, 9)).?;
    try std.testing.expectEqual(rows_store.RowRenderSpan{}, (try store.getRowConst(site, row_id)).metadata.render_span);
    try std.testing.expectEqual(rows_store.RowRenderSpan{}, try (try store.getSiteConst(site)).render_order.span(row_id));

    var next = try PreparedTransition.prepareStable(std.testing.allocator, &store, site, try OwnerToken.fromRaw(77), try OwnerToken.fromRaw(78), &.{});
    defer next.deinit();
    const multi = rows_store.RowRenderSpan{
        .first_node = 101,
        .last_node = 109,
        .first_root = 101,
        .last_root = 107,
        .root_count = 3,
    };
    try next.prepareRenderSpanUpdates(1);
    try next.setCandidateRenderSpanAssumeCapacity(9, multi);
    try std.testing.expectEqual(multi, next.candidateBySlot(9).?.metadata.render_span);
    try std.testing.expectEqual(@as(u64, 101), (try next.firstRenderRootAtOrAfterSlot(9)).?.root_id);
    next.commit();
    try std.testing.expectEqual(multi, (try store.getRowConst(site, row_id)).metadata.render_span);
    try std.testing.expectEqual(multi, try (try store.getSiteConst(site)).render_order.span(row_id));
}

test "changed candidate traversal and commit stay bounded by a one-row delta" {
    const fault_allocator = @import("fault_allocator.zig");
    const row_count = 512;
    const changed_index = 317;

    var fault = fault_allocator.FaultAllocator.init(std.testing.allocator);
    var store = Store.init(fault.allocator());
    defer {
        fault.configure(null);
        store.deinit();
    }
    const first_owner = try OwnerToken.fromRaw(80);
    const site = try store.createSite(first_owner);

    var key_buffers: [row_count][16]u8 = undefined;
    var seed_edits: [row_count]StableEdit = undefined;
    for (&key_buffers, &seed_edits, 0..) |*key_buffer, *edit, index| {
        const key = try std.fmt.bufPrint(key_buffer, "row-{d}", .{index});
        const slot: u64 = @intCast(index + 1);
        edit.* = .{ .insert = .{
            .slot = slot,
            .before_slot = 0,
            .key = key,
            .metadata = .{ .item_slot = slot, .scope_id = slot, .row_handle = slot },
        } };
    }
    var seed = try PreparedTransition.prepareStable(fault.allocator(), &store, site, first_owner, try OwnerToken.fromRaw(81), &seed_edits);
    defer seed.deinit();
    seed.commit();

    const changed_slot: u64 = changed_index + 1;
    const changed_key = try std.fmt.bufPrint(&key_buffers[changed_index], "row-{d}", .{changed_index});
    var update = try PreparedTransition.prepareStable(fault.allocator(), &store, site, try OwnerToken.fromRaw(81), try OwnerToken.fromRaw(82), &.{.{ .update = .{
        .slot = changed_slot,
        .key = changed_key,
        .metadata = .{ .item_slot = changed_slot, .scope_id = changed_slot, .row_handle = changed_slot, .render_span = .{ .first_node = 99, .last_node = 99, .first_root = 99, .last_root = 99, .root_count = 1 } },
    } }});
    defer update.deinit();

    try std.testing.expectEqual(@as(usize, row_count), update.candidateLen());
    try std.testing.expectEqual(@as(usize, 1), update.changedCandidateUpperBound());
    var changed = update.iterateChangedCandidates();
    const row = changed.next().?;
    try std.testing.expectEqual(changed_slot, row.metadata.item_slot);
    try std.testing.expect(!row.created);
    try std.testing.expect(row.item_changed);
    try std.testing.expect(changed.next() == null);
    try std.testing.expectEqual(@as(usize, 1), changed.touched_index);

    fault.configure(1);
    update.commit();
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    const committed = (try store.findItemSlot(site, changed_slot)).?;
    try std.testing.expectEqual(@as(?u64, 99), (try store.getRowConst(site, committed)).metadata.render_span.first_root);
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
