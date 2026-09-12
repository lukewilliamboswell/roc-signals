//! Stable lexical positions for dynamic structure, including empty branches.
//! Markers are engine data with zero render roots, never placeholder elements.
//! Parent-local order aggregates skip arbitrary runs of empty markers in
//! logarithmic expected time. Preparation changes only touched index paths.
//! A parent with at most `small_capacity` units keeps its order in an inline
//! array inside the parent table, so bulk creation of ordinary elements does
//! not allocate a hash-backed index per parent; a parent that outgrows the
//! array is promoted once to the shared order tree.
const std = @import("std");
const ids = @import("ids.zig");
const ordering = @import("rows_render_order.zig");

pub const MarkerKind = enum(u64) { when = 1, each = 2, each_end = 3 };

/// Keeps render-element and construction-site identity domains disjoint without
/// narrowing either engine handle. The high word is a domain discriminator.
pub const PositionId = enum(u128) {
    _,

    /// Uses the engine-owned element identity as an ordinary rendered position.
    pub fn element(elem: ids.ElemId) PositionId {
        return @enumFromInt(@as(u128, elem.raw()));
    }

    /// Names a persistent construction boundary independently of its contents.
    pub fn marker(node: ids.NodeId, kind: MarkerKind) PositionId {
        return @enumFromInt((@as(u128, @intFromEnum(kind)) << 64) | node.raw());
    }

    /// Bounds a row's lexical contents even when it renders no roots.
    pub fn rowStart(scope: ids.ScopeId) PositionId {
        return @enumFromInt((@as(u128, 4) << 64) | scope.raw());
    }

    /// Ends the row range that must move with its stable scope identity.
    pub fn rowEnd(scope: ids.ScopeId) PositionId {
        return @enumFromInt((@as(u128, 5) << 64) | scope.raw());
    }

    /// Supplies the complete nominal representation to the shared order index.
    pub fn raw(self: PositionId) u128 {
        return @intFromEnum(self);
    }

    fn span(self: PositionId) Span {
        if (self.raw() >> 64 != 0) return .{};
        const root: u64 = @truncate(self.raw());
        return .{ .first_root = root, .last_root = root, .root_count = 1 };
    }
};

/// One construction-ordered unit collected before descriptors are rearranged
/// into storage lanes. Its owner is used by scope-local retirement.
pub const Entry = struct {
    parent: ids.ElemId,
    position: PositionId,
    owner: ids.ScopeId,
};
const Span = struct { first_root: ?u64 = null, last_root: ?u64 = null, root_count: u32 = 0 };
const Index = ordering.StableOrderIndex(PositionId, Span);
pub const Error = Index.Error;

/// Largest parent kept in the inline array representation. Most rendered
/// parents own a handful of children, so their lexical order fits in a fixed
/// inline array whose every operation is bounded by this constant; only a
/// parent that outgrows it pays for a hash-backed order tree.
pub const small_capacity = 8;

/// Inline lexical order of a small parent. Spans are derived from the nominal
/// identity, so the array stores only positions. Every operation touches at
/// most `small_capacity` entries, which keeps candidate copies, ranks, and
/// anchors constant-bounded without any per-parent heap storage.
const Small = struct {
    len: u8 = 0,
    items: [small_capacity]PositionId = undefined,

    fn slice(self: *const Small) []const PositionId {
        return self.items[0..self.len];
    }

    fn rank(self: *const Small, position: PositionId) error{InvalidRow}!usize {
        for (self.slice(), 0..) |item, index| if (item == position) return index;
        return error.InvalidRow;
    }

    fn rowAt(self: *const Small, index: usize) error{InvalidRange}!PositionId {
        if (index >= self.len) return error.InvalidRange;
        return self.items[index];
    }

    fn firstRootAtOrAfter(self: *const Small, position: PositionId) error{InvalidRow}!?u64 {
        const start = try self.rank(position);
        for (self.slice()[start..]) |item| if (item.span().first_root) |root| return root;
        return null;
    }

    fn rootsInRange(self: *const Small, first: PositionId, count: usize) error{ InvalidRow, InvalidRange }!Index.RootRange {
        if (count == 0) return error.InvalidRange;
        const first_rank = try self.rank(first);
        if (count > self.len - first_rank) return error.InvalidRange;
        var result = Index.RootRange{};
        for (self.slice()[first_rank..][0..count]) |item| {
            const item_span = item.span();
            if (item_span.root_count == 0) continue;
            if (result.first == null) result.first = item_span.first_root;
            result.last = item_span.last_root;
            result.count += item_span.root_count;
        }
        return result;
    }

    fn insertAt(self: *Small, index: usize, position: PositionId) void {
        std.debug.assert(self.len < small_capacity and index <= self.len);
        std.mem.copyBackwards(PositionId, self.items[index + 1 .. self.len + 1], self.items[index..self.len]);
        self.items[index] = position;
        self.len += 1;
    }

    fn removeRange(self: *Small, first: PositionId, count: usize) error{ InvalidRow, InvalidRange }!Index.RemoveResult {
        if (count == 0) return error.InvalidRange;
        const first_rank = try self.rank(first);
        if (count > self.len - first_rank) return error.InvalidRange;
        var roots: usize = 0;
        for (self.slice()[first_rank..][0..count]) |item| roots += item.span().root_count;
        std.mem.copyForwards(PositionId, self.items[first_rank .. self.len - count], self.items[first_rank + count .. self.len]);
        self.len -= @intCast(count);
        return .{ .rows_removed = count, .roots_removed = roots };
    }

    fn moveRange(self: *Small, first: PositionId, count: usize, before: ?PositionId) error{ InvalidRow, InvalidRange, AnchorInsideRange }!Index.MoveResult {
        if (count == 0) return error.InvalidRange;
        const source_rank = try self.rank(first);
        if (count > self.len - source_rank) return error.InvalidRange;
        const source_end = source_rank + count;
        const before_rank = if (before) |boundary| try self.rank(boundary) else self.len;
        if (before_rank >= source_rank and before_rank < source_end) return error.AnchorInsideRange;
        const target_rank = if (before_rank >= source_end) before_rank - count else before_rank;
        if (target_rank == source_rank) return .{ .effective = false, .roots_moved = 0 };
        var roots: usize = 0;
        for (self.slice()[source_rank..][0..count]) |item| roots += item.span().root_count;
        if (target_rank < source_rank) {
            std.mem.rotate(PositionId, self.items[target_rank..source_end], source_rank - target_rank);
        } else {
            std.mem.rotate(PositionId, self.items[source_rank .. target_rank + count], count);
        }
        return .{ .effective = true, .roots_moved = roots };
    }
};

/// Committed order of one parent: inline for small parents, a hash-backed
/// order tree once a parent has outgrown `small_capacity`.
const ParentOrder = union(enum) {
    small: Small,
    tree: *Index,

    fn len(self: *const ParentOrder) usize {
        return switch (self.*) {
            .small => |*small| small.len,
            .tree => |index| index.len(),
        };
    }

    fn rank(self: *const ParentOrder, position: PositionId) error{InvalidRow}!usize {
        return switch (self.*) {
            .small => |*small| small.rank(position),
            .tree => |index| index.rank(position),
        };
    }

    fn rowAt(self: *const ParentOrder, index: usize) error{InvalidRange}!PositionId {
        return switch (self.*) {
            .small => |*small| small.rowAt(index),
            .tree => |tree| tree.rowAt(index),
        };
    }

    fn firstRootAtOrAfter(self: *const ParentOrder, position: PositionId) error{InvalidRow}!?u64 {
        return switch (self.*) {
            .small => |*small| small.firstRootAtOrAfter(position),
            .tree => |index| if (try index.firstRootAtOrAfter(position)) |root| root.root_id else null,
        };
    }
};

/// Owns lexical order indexes. A parent's empty structural markers remain live
/// even when it has no rendered children; scope disposal removes those markers.
pub const Positions = struct {
    allocator: std.mem.Allocator,
    parents: std.AutoHashMapUnmanaged(ids.ElemId, ParentOrder) = .empty,
    memberships: std.AutoHashMapUnmanaged(PositionId, Membership) = .empty,
    scopes: std.AutoHashMapUnmanaged(ids.ScopeId, ScopeHead) = .empty,

    const Membership = struct { entry: Entry, previous: ?PositionId = null, next: ?PositionId = null };
    const ScopeHead = struct { first: ?PositionId = null, count: usize = 0 };

    /// Creates an empty engine-owned position registry.
    pub fn init(allocator: std.mem.Allocator) Positions {
        return .{ .allocator = allocator };
    }

    /// Releases indexes after all provisional transactions have been destroyed.
    pub fn deinit(self: *Positions) void {
        var iterator = self.parents.valueIterator();
        while (iterator.next()) |order| switch (order.*) {
            .small => {},
            .tree => |index| {
                index.deinit();
                self.allocator.destroy(index);
            },
        };
        self.parents.deinit(self.allocator);
        self.memberships.deinit(self.allocator);
        self.scopes.deinit(self.allocator);
    }

    /// Counts committed parents that currently use a hash-backed order tree.
    /// Bulk creation of ordinary small parents must not grow this number;
    /// tests use it to keep tree allocation proportional to large parents.
    pub fn treeIndexCount(self: *const Positions) usize {
        var count: usize = 0;
        var iterator = self.parents.valueIterator();
        while (iterator.next()) |order| {
            if (order.* == .tree) count += 1;
        }
        return count;
    }

    /// Counts the exact lexical units owned by one live scope, independently
    /// of unrelated scopes and of the number of rendered descendants.
    pub fn ownedCount(self: *const Positions, scope: ids.ScopeId) usize {
        return if (self.scopes.get(scope)) |head| head.count else 0;
    }

    /// Resolves the owner and render parent of a retained nominal position.
    pub fn entry(self: *const Positions, position: PositionId) ?Entry {
        return if (self.memberships.get(position)) |membership| membership.entry else null;
    }

    /// Resolves the next visible root at a retained empty construction boundary.
    /// A missing marker is a lifecycle error, never permission to append.
    pub fn anchor(self: *const Positions, parent: ids.ElemId, marker: PositionId) error{InvalidRow}!?ids.ElemId {
        const order = self.parents.getPtr(parent) orelse return error.InvalidRow;
        const result = try order.firstRootAtOrAfter(marker);
        return if (result) |root| ids.ElemId.fromRaw(root) else null;
    }

    /// Returns the immediate lexical successor, including zero-root markers.
    /// Use this as the insertion boundary for replacement contents; a visible
    /// root alone would place them after adjacent empty construction sites.
    pub fn nextPosition(self: *const Positions, parent: ids.ElemId, marker: PositionId) error{ InvalidRow, InvalidRange }!?PositionId {
        const order = self.parents.getPtr(parent) orelse return error.InvalidRow;
        const rank = try order.rank(marker);
        return if (rank + 1 < order.len()) try order.rowAt(rank + 1) else null;
    }

    /// Starts a path-copy candidate with no committed mutation.
    pub fn prepare(self: *Positions) Prepared {
        return .{ .positions = self };
    }
};

/// Owns changed paths and fresh parent indexes until atomic publication.
pub const Prepared = struct {
    /// One parent's candidate order. A small parent is a private copy of its
    /// inline array, so preparing it allocates nothing and aborting it drops
    /// nothing. A tree parent is a path-copy overlay over a committed or
    /// provisional index; `owned` marks an index that the committed table
    /// does not reference yet (fresh, or promoted from a small array).
    const Parent = struct {
        order: union(enum) {
            small: Small,
            tree: struct { index: *Index, edits: Index.PreparedEdits },
        },
        owned: bool,
        existing: bool,

        fn len(self: *const Parent) usize {
            return switch (self.order) {
                .small => |*small| small.len,
                .tree => |*tree| tree.edits.len(),
            };
        }

        fn rank(self: *const Parent, position: PositionId) error{InvalidRow}!usize {
            return switch (self.order) {
                .small => |*small| small.rank(position),
                .tree => |*tree| tree.edits.rank(position),
            };
        }

        fn rowAt(self: *const Parent, index: usize) error{InvalidRange}!PositionId {
            return switch (self.order) {
                .small => |*small| small.rowAt(index),
                .tree => |*tree| tree.edits.rowAt(index),
            };
        }

        fn firstRootAtOrAfter(self: *const Parent, position: PositionId) error{InvalidRow}!?u64 {
            return switch (self.order) {
                .small => |*small| small.firstRootAtOrAfter(position),
                .tree => |*tree| if (try tree.edits.firstRootAtOrAfter(position)) |root| root.root_id else null,
            };
        }

        fn rootsInRange(self: *Parent, first: PositionId, count: usize) Error!Index.RootRange {
            return switch (self.order) {
                .small => |*small| small.rootsInRange(first, count),
                .tree => |*tree| tree.edits.rootsInRange(first, count),
            };
        }

        /// Replaces a full inline array with a provisional tree seeded in one
        /// linear pass, so the pending insertion can proceed on the overlay.
        /// The committed table still references the inline array until commit.
        fn promote(self: *Parent, allocator: std.mem.Allocator) Error!void {
            const small = self.order.small;
            const index = try allocator.create(Index);
            errdefer allocator.destroy(index);
            index.* = Index.init(allocator);
            errdefer index.deinit();
            var entries: [small_capacity]Index.Entry = undefined;
            for (small.slice(), entries[0..small.len]) |position, *entry| entry.* = .{ .row_id = position, .span = position.span() };
            _ = try index.seed(entries[0..small.len]);
            self.order = .{ .tree = .{ .index = index, .edits = index.prepare() } };
            self.owned = true;
        }

        fn insertBefore(self: *Parent, allocator: std.mem.Allocator, position: PositionId, before: ?PositionId) Error!void {
            switch (self.order) {
                .small => |*small| {
                    if (small.rank(position) != error.InvalidRow) return error.DuplicateRow;
                    if (small.len < small_capacity) {
                        const index = if (before) |boundary| try small.rank(boundary) else small.len;
                        small.insertAt(index, position);
                        return;
                    }
                    try self.promote(allocator);
                },
                .tree => {},
            }
            try self.order.tree.edits.insertBefore(position, before, position.span());
        }

        fn removeRange(self: *Parent, first: PositionId, count: usize) Error!Index.RemoveResult {
            return switch (self.order) {
                .small => |*small| small.removeRange(first, count),
                .tree => |*tree| tree.edits.removeRange(first, count),
            };
        }

        fn moveRange(self: *Parent, first: PositionId, count: usize, before: ?PositionId) Error!Index.MoveResult {
            return switch (self.order) {
                .small => |*small| small.moveRange(first, count, before),
                .tree => |*tree| tree.edits.moveRange(first, count, before),
            };
        }

        /// Distinct order records this candidate has copied. An inline parent
        /// counts its whole array, which is bounded by `small_capacity`.
        fn nodesTouched(self: *const Parent) usize {
            return switch (self.order) {
                .small => |*small| small.len,
                .tree => |*tree| tree.edits.stats().nodes_touched,
            };
        }
    };

    /// Preparation work summary for regression tests: how many parents were
    /// touched, how many needed a hash-backed tree, and how many tree records
    /// were path-copied. Bulk creation of small parents must keep the tree
    /// numbers proportional to the number of large parents, not to rows.
    pub const Work = struct {
        parents: usize = 0,
        small_parents: usize = 0,
        tree_parents: usize = 0,
        fresh_tree_indexes: usize = 0,
        tree_nodes_touched: usize = 0,
    };

    positions: *Positions,
    parents: std.AutoHashMapUnmanaged(ids.ElemId, Parent) = .empty,
    memberships: std.AutoHashMapUnmanaged(PositionId, ?Positions.Membership) = .empty,
    scopes: std.AutoHashMapUnmanaged(ids.ScopeId, Positions.ScopeHead) = .empty,
    ready: bool = false,
    committed: bool = false,

    fn parent(self: *Prepared, id: ids.ElemId) Error!*Parent {
        if (self.committed) @panic("structural positions edited after commit");
        self.ready = false;
        if (self.parents.getPtr(id)) |value| return value;
        try self.parents.ensureUnusedCapacity(self.positions.allocator, 1);
        const slot = self.parents.getOrPutAssumeCapacity(id);
        if (self.positions.parents.get(id)) |committed| {
            slot.value_ptr.* = switch (committed) {
                .small => |small| .{ .order = .{ .small = small }, .owned = false, .existing = true },
                .tree => |index| .{ .order = .{ .tree = .{ .index = index, .edits = index.prepare() } }, .owned = false, .existing = true },
            };
        } else {
            slot.value_ptr.* = .{ .order = .{ .small = .{} }, .owned = false, .existing = false };
        }
        return slot.value_ptr;
    }

    /// Summarizes the candidate's order work without inspecting committed
    /// parents that this preparation never touched.
    pub fn work(self: *const Prepared) Work {
        var summary = Work{};
        var iterator = self.parents.valueIterator();
        while (iterator.next()) |value| {
            summary.parents += 1;
            switch (value.order) {
                .small => summary.small_parents += 1,
                .tree => |*tree| {
                    summary.tree_parents += 1;
                    if (value.owned) summary.fresh_tree_indexes += 1;
                    summary.tree_nodes_touched += tree.edits.stats().nodes_touched;
                },
            }
        }
        return summary;
    }

    fn membership(self: *const Prepared, position: PositionId) ?Positions.Membership {
        if (self.memberships.getPtr(position)) |changed| return changed.*;
        return self.positions.memberships.get(position);
    }

    fn scopeHead(self: *const Prepared, owner: ids.ScopeId) Positions.ScopeHead {
        return self.scopes.get(owner) orelse self.positions.scopes.get(owner) orelse .{};
    }

    fn addOwnership(self: *Prepared, next_entry: Entry) Error!void {
        var head = self.scopeHead(next_entry.owner);
        const next_count = std.math.add(usize, head.count, 1) catch return error.ResourceLimit;
        try self.memberships.ensureUnusedCapacity(self.positions.allocator, 2);
        try self.scopes.ensureUnusedCapacity(self.positions.allocator, 1);
        if (head.first) |first| {
            var old = self.membership(first) orelse return error.InvalidRow;
            old.previous = next_entry.position;
            self.memberships.putAssumeCapacity(first, old);
        }
        self.memberships.putAssumeCapacity(next_entry.position, .{ .entry = next_entry, .next = head.first });
        head.first = next_entry.position;
        head.count = next_count;
        self.scopes.putAssumeCapacity(next_entry.owner, head);
    }

    fn removeOwnership(self: *Prepared, old: Positions.Membership) Error!void {
        var head = self.scopeHead(old.entry.owner);
        if (head.count == 0) return error.InvalidRow;
        try self.memberships.ensureUnusedCapacity(self.positions.allocator, 3);
        try self.scopes.ensureUnusedCapacity(self.positions.allocator, 1);
        if (old.previous) |previous| {
            var neighbor = self.membership(previous) orelse return error.InvalidRow;
            neighbor.next = old.next;
            self.memberships.putAssumeCapacity(previous, neighbor);
        } else head.first = old.next;
        if (old.next) |next| {
            var neighbor = self.membership(next) orelse return error.InvalidRow;
            neighbor.previous = old.previous;
            self.memberships.putAssumeCapacity(next, neighbor);
        }
        self.memberships.putAssumeCapacity(old.entry.position, null);
        head.count -= 1;
        self.scopes.putAssumeCapacity(old.entry.owner, head);
    }

    /// Inserts or moves one explicitly collected unit before another retained
    /// position. Cross-parent moves must first remove their old membership.
    pub fn place(self: *Prepared, entry: Entry, before: ?PositionId) Error!void {
        const value = try self.parent(entry.parent);
        if (self.membership(entry.position)) |existing| {
            if (existing.entry.parent != entry.parent or existing.entry.owner != entry.owner) return error.InvalidRow;
            _ = try value.moveRange(entry.position, 1, before);
        } else {
            try value.insertBefore(self.positions.allocator, entry.position, before);
            try self.addOwnership(entry);
        }
    }

    /// Retires exactly one scope-owned unit. Missing identity is an error.
    pub fn remove(self: *Prepared, parent_id: ids.ElemId, position: PositionId) Error!void {
        const value = try self.parent(parent_id);
        const old = self.membership(position) orelse return error.InvalidRow;
        if (old.entry.parent != parent_id) return error.InvalidRow;
        _ = try value.removeRange(position, 1);
        try self.removeOwnership(old);
    }

    /// Removes only the units owned by this scope, including invisible site
    /// and row markers. The caller supplies every retiring descendant scope.
    /// On failure the candidate must be discarded; committed ownership and
    /// lexical order remain unchanged.
    pub fn retireScope(self: *Prepared, owner: ids.ScopeId) Error!void {
        while (self.scopeHead(owner).first) |position| {
            const old = self.membership(position) orelse return error.InvalidRow;
            try self.remove(old.entry.parent, position);
        }
    }

    /// Moves a complete lexical range, including empty nested site markers.
    /// Inclusive row-start/end boundaries let sparse row moves preserve empty
    /// structure without enumerating neighboring rows or rendered roots.
    pub fn moveRange(self: *Prepared, parent_id: ids.ElemId, first: PositionId, last: PositionId, before: ?PositionId) Error!void {
        const value = try self.parent(parent_id);
        const first_rank = try value.rank(first);
        const last_rank = try value.rank(last);
        if (last_rank < first_rank) return error.InvalidRange;
        _ = try value.moveRange(first, last_rank - first_rank + 1, before);
    }

    /// Retires a lexical interval, including markers owned by nested scopes.
    /// Other parents belonging to those scopes are retired by retireScope.
    pub fn retireRange(self: *Prepared, parent_id: ids.ElemId, first: PositionId, last: PositionId) Error!void {
        const value = try self.parent(parent_id);
        const first_rank = try value.rank(first);
        const last_rank = try value.rank(last);
        if (last_rank < first_rank) return error.InvalidRange;
        for (0..last_rank - first_rank + 1) |_| {
            const position = try value.rowAt(first_rank);
            try self.remove(parent_id, position);
        }
    }

    /// Returns one position's candidate rank for ordering a changed set of
    /// neighboring construction sites, without inspecting unrelated siblings.
    pub fn positionRank(self: *const Prepared, parent_id: ids.ElemId, position: PositionId) error{InvalidRow}!usize {
        if (self.parents.getPtr(parent_id)) |value| return value.rank(position);
        const order = self.positions.parents.getPtr(parent_id) orelse return error.InvalidRow;
        return order.rank(position);
    }

    /// Summarizes visible roots inside retained lexical boundaries. Empty
    /// nested sites contribute zero, so callers never scan unrelated rows.
    pub fn rootsInRange(self: *Prepared, parent_id: ids.ElemId, first: PositionId, last: PositionId) Error!struct { first: ?ids.ElemId, last: ?ids.ElemId, count: usize } {
        const value = try self.parent(parent_id);
        const first_rank = try value.rank(first);
        const last_rank = try value.rank(last);
        if (last_rank < first_rank) return error.InvalidRange;
        const roots = try value.rootsInRange(first, last_rank - first_rank + 1);
        return .{ .first = if (roots.first) |id| ids.ElemId.fromRaw(id) else null, .last = if (roots.last) |id| ids.ElemId.fromRaw(id) else null, .count = roots.count };
    }

    /// Queries the final candidate after preceding removals and insertions.
    /// Adjacent empty sites do not require per-neighbor anchor rewrites.
    pub fn anchor(self: *const Prepared, parent_id: ids.ElemId, marker: PositionId) error{InvalidRow}!?ids.ElemId {
        if (self.parents.getPtr(parent_id)) |value| {
            const result = try value.firstRootAtOrAfter(marker);
            return if (result) |root| ids.ElemId.fromRaw(root) else null;
        }
        return self.positions.anchor(parent_id, marker);
    }

    /// Resolves the lexical insertion boundary in the candidate after retired
    /// units have been removed, preserving the order of neighboring empty sites.
    pub fn nextPosition(self: *const Prepared, parent_id: ids.ElemId, marker: PositionId) error{ InvalidRow, InvalidRange }!?PositionId {
        if (self.parents.getPtr(parent_id)) |value| {
            const rank = try value.rank(marker);
            return if (rank + 1 < value.len()) try value.rowAt(rank + 1) else null;
        }
        return self.positions.nextPosition(parent_id, marker);
    }

    /// Reserves every persistent table growth after the last candidate edit.
    /// Small parents publish by value, so only tree overlays and new parent
    /// keys need reservation.
    pub fn preflight(self: *Prepared) Error!void {
        var fresh: u32 = 0;
        var iterator = self.parents.valueIterator();
        while (iterator.next()) |value| {
            if (value.order == .tree) try value.order.tree.edits.preflightCommit();
            if (!value.existing and value.len() != 0) fresh = std.math.add(u32, fresh, 1) catch return error.ResourceLimit;
        }
        try self.positions.parents.ensureUnusedCapacity(self.positions.allocator, fresh);
        try self.positions.memberships.ensureUnusedCapacity(self.positions.allocator, self.memberships.count());
        try self.positions.scopes.ensureUnusedCapacity(self.positions.allocator, self.scopes.count());
        self.ready = true;
    }

    /// Publishes all lexical order changes without allocation. Empty parent
    /// indexes retire only when their final marker or element disappears.
    pub fn commit(self: *Prepared) void {
        if (!self.ready or self.committed) @panic("structural positions were not preflighted exactly once");
        var iterator = self.parents.iterator();
        while (iterator.next()) |slot| {
            const value = slot.value_ptr;
            const key = slot.key_ptr.*;
            switch (value.order) {
                .small => |small| {
                    if (small.len == 0) {
                        if (value.existing) _ = self.positions.parents.remove(key);
                    } else {
                        self.positions.parents.putAssumeCapacity(key, .{ .small = small });
                    }
                },
                .tree => |*tree| {
                    tree.edits.commitAssumePreflighted();
                    if (tree.edits.len() == 0) {
                        if (value.existing) _ = self.positions.parents.remove(key);
                        // A retired committed tree is released with the plan.
                        value.owned = true;
                    } else if (value.owned) {
                        self.positions.parents.putAssumeCapacity(key, .{ .tree = tree.index });
                        value.owned = false;
                    }
                },
            }
        }
        var memberships = self.memberships.iterator();
        while (memberships.next()) |slot| {
            if (slot.value_ptr.*) |value|
                self.positions.memberships.putAssumeCapacity(slot.key_ptr.*, value)
            else
                _ = self.positions.memberships.remove(slot.key_ptr.*);
        }
        var scopes = self.scopes.iterator();
        while (scopes.next()) |slot| {
            if (slot.value_ptr.count != 0)
                self.positions.scopes.putAssumeCapacity(slot.key_ptr.*, slot.value_ptr.*)
            else
                _ = self.positions.scopes.remove(slot.key_ptr.*);
        }
        self.committed = true;
    }

    /// Releases aborted candidate paths and indexes retired by a committed plan.
    pub fn deinit(self: *Prepared) void {
        var iterator = self.parents.valueIterator();
        while (iterator.next()) |value| switch (value.order) {
            .small => {},
            .tree => |*tree| {
                tree.edits.deinit();
                if (value.owned) {
                    tree.index.deinit();
                    self.positions.allocator.destroy(tree.index);
                }
            },
        };
        self.parents.deinit(self.positions.allocator);
        self.memberships.deinit(self.positions.allocator);
        self.scopes.deinit(self.positions.allocator);
    }
};

test "empty structural markers survive neighboring edits without visible placeholders" {
    var positions = Positions.init(std.testing.allocator);
    defer positions.deinit();
    const parent_id = ids.root_elem;
    const owner = ids.ScopeId.fromRaw(0);
    const first = PositionId.marker(ids.NodeId.fromRaw(1), .when);
    const second = PositionId.marker(ids.NodeId.fromRaw(2), .when);
    const last = PositionId.element(ids.ElemId.fromRaw(9));
    var initial = positions.prepare();
    defer initial.deinit();
    for ([_]PositionId{ first, second, last }) |position| try initial.place(.{ .parent = parent_id, .position = position, .owner = owner }, null);
    try initial.preflight();
    initial.commit();
    try std.testing.expectEqual(ids.ElemId.fromRaw(9), (try positions.anchor(parent_id, first)).?);
    var next = positions.prepare();
    defer next.deinit();
    try next.remove(parent_id, last);
    try std.testing.expectEqual(null, try next.anchor(parent_id, first));
    const inserted = PositionId.element(ids.ElemId.fromRaw(3));
    try next.place(.{ .parent = parent_id, .position = inserted, .owner = owner }, try next.nextPosition(parent_id, first));
    try std.testing.expectEqual(ids.ElemId.fromRaw(3), (try next.anchor(parent_id, first)).?);
    try std.testing.expectEqual(null, try next.anchor(parent_id, second));
    try std.testing.expectEqual(ids.ElemId.fromRaw(9), (try positions.anchor(parent_id, first)).?);
    try next.preflight();
    next.commit();
    try std.testing.expectEqual(ids.ElemId.fromRaw(3), (try positions.anchor(parent_id, first)).?);
}

test "structural anchors skip thousands of adjacent empty markers with bounded edited paths" {
    var positions = Positions.init(std.testing.allocator);
    defer positions.deinit();
    var initial = positions.prepare();
    defer initial.deinit();
    const parent_id = ids.root_elem;
    const owner = ids.ScopeId.fromRaw(0);
    for (0..10000) |i| try initial.place(.{ .parent = parent_id, .position = PositionId.marker(ids.NodeId.fromIndex(i), .when), .owner = owner }, null);
    try initial.place(.{ .parent = parent_id, .position = PositionId.element(ids.ElemId.fromRaw(1)), .owner = owner }, null);
    try initial.preflight();
    initial.commit();
    const first = PositionId.marker(ids.NodeId.fromRaw(0), .when);
    try std.testing.expectEqual(ids.ElemId.fromRaw(1), (try positions.anchor(parent_id, first)).?);
    var edit = positions.prepare();
    defer edit.deinit();
    try edit.place(.{ .parent = parent_id, .position = PositionId.element(ids.ElemId.fromRaw(2)), .owner = owner }, try edit.nextPosition(parent_id, first));
    try std.testing.expectEqual(ids.ElemId.fromRaw(2), (try edit.anchor(parent_id, first)).?);
    try std.testing.expectEqual(ids.ElemId.fromRaw(1), (try edit.anchor(parent_id, PositionId.marker(ids.NodeId.fromRaw(1), .when))).?);
    try std.testing.expect(edit.work().tree_nodes_touched < 100);
    try std.testing.expectEqual(@as(u32, 2), edit.memberships.count());
    try std.testing.expectEqual(@as(u32, 1), edit.scopes.count());
}

fn seedRefusalPositions(positions: *Positions) !void {
    var plan = positions.prepare();
    defer plan.deinit();
    try plan.place(.{ .parent = ids.root_elem, .position = PositionId.marker(ids.NodeId.fromRaw(1), .when), .owner = ids.ScopeId.fromRaw(0) }, null);
    try plan.place(.{ .parent = ids.root_elem, .position = PositionId.element(ids.ElemId.fromRaw(2)), .owner = ids.ScopeId.fromRaw(0) }, null);
    try plan.preflight();
    plan.commit();
}

fn prepareRefusalPositions(plan: *Prepared) !void {
    try plan.remove(ids.root_elem, PositionId.element(ids.ElemId.fromRaw(2)));
    try plan.place(.{ .parent = ids.ElemId.fromRaw(3), .position = PositionId.marker(ids.NodeId.fromRaw(4), .each), .owner = ids.ScopeId.fromRaw(1) }, null);
    try plan.preflight();
}

test "structural position refusal leaves empty-site anchors retryable" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var counted = FaultAllocator.init(std.testing.allocator);
    var baseline = Positions.init(counted.allocator());
    defer baseline.deinit();
    try seedRefusalPositions(&baseline);
    counted.configure(null);
    var candidate = baseline.prepare();
    defer candidate.deinit();
    try prepareRefusalPositions(&candidate);
    const attempts = counted.attempts;
    try std.testing.expect(attempts > 0);
    for (1..attempts + 1) |position| {
        var fault = FaultAllocator.init(std.testing.allocator);
        var positions = Positions.init(fault.allocator());
        defer positions.deinit();
        try seedRefusalPositions(&positions);
        fault.configure(position);
        var refused = positions.prepare();
        try std.testing.expectError(error.OutOfMemory, prepareRefusalPositions(&refused));
        refused.deinit();
        const marker = PositionId.marker(ids.NodeId.fromRaw(1), .when);
        try std.testing.expectEqual(ids.ElemId.fromRaw(2), (try positions.anchor(ids.root_elem, marker)).?);
        try std.testing.expectEqual(@as(usize, 2), positions.ownedCount(ids.ScopeId.fromRaw(0)));
        try std.testing.expectEqual(@as(usize, 0), positions.ownedCount(ids.ScopeId.fromRaw(1)));
        fault.configure(null);
        var retry = positions.prepare();
        defer retry.deinit();
        try prepareRefusalPositions(&retry);
        fault.configure(1);
        retry.commit();
        try std.testing.expectEqual(@as(usize, 0), fault.attempts);
        try std.testing.expectEqual(null, try positions.anchor(ids.root_elem, marker));
        try std.testing.expectEqual(@as(usize, 1), positions.ownedCount(ids.ScopeId.fromRaw(0)));
        try std.testing.expectEqual(@as(usize, 1), positions.ownedCount(ids.ScopeId.fromRaw(1)));
        try std.testing.expectEqual(null, positions.entry(PositionId.element(ids.ElemId.fromRaw(2))));
        fault.configure(null);
    }
}

test "structural row range moves preserve empty nested sites and identity domains" {
    var positions = Positions.init(std.testing.allocator);
    defer positions.deinit();
    const parent_id = ids.root_elem;
    const scope = ids.ScopeId.fromRaw(7);
    const start = PositionId.rowStart(scope);
    const end = PositionId.rowEnd(scope);
    const empty = PositionId.marker(ids.NodeId.fromRaw(7), .when);
    const root = PositionId.element(ids.ElemId.fromRaw(7));
    var initial = positions.prepare();
    defer initial.deinit();
    for ([_]PositionId{ start, empty, end, root }) |position| {
        try initial.place(.{ .parent = parent_id, .position = position, .owner = scope }, null);
    }
    try initial.preflight();
    initial.commit();
    var moved = positions.prepare();
    defer moved.deinit();
    try moved.moveRange(parent_id, start, end, null);
    try std.testing.expectEqual(null, try moved.anchor(parent_id, empty));
    try std.testing.expectEqual(root, (try positions.nextPosition(parent_id, end)).?);
    try moved.preflight();
    moved.commit();
    try std.testing.expectEqual(start, (try positions.nextPosition(parent_id, root)).?);
    try std.testing.expectEqual(empty, (try positions.nextPosition(parent_id, start)).?);
    var retire = positions.prepare();
    defer retire.deinit();
    for ([_]PositionId{ start, empty, end, root }) |position| try retire.remove(parent_id, position);
    try retire.preflight();
    retire.commit();
    try std.testing.expectEqual(@as(usize, 0), positions.parents.count());
    try std.testing.expectError(error.InvalidRow, positions.anchor(parent_id, empty));
}

test "structural scope retirement releases only its owned lexical units" {
    var positions = Positions.init(std.testing.allocator);
    defer positions.deinit();
    const parent_id = ids.root_elem;
    const outer = ids.ScopeId.fromRaw(1);
    const retiring = ids.ScopeId.fromRaw(2);
    const sibling = ids.ScopeId.fromRaw(3);
    const site = PositionId.marker(ids.NodeId.fromRaw(1), .when);
    const nested = PositionId.marker(ids.NodeId.fromRaw(2), .when);
    const other = PositionId.marker(ids.NodeId.fromRaw(3), .when);
    const content = PositionId.element(ids.ElemId.fromRaw(4));
    const tail = PositionId.element(ids.ElemId.fromRaw(5));
    var initial = positions.prepare();
    defer initial.deinit();
    for ([_]Entry{
        .{ .parent = parent_id, .position = site, .owner = outer },
        .{ .parent = parent_id, .position = nested, .owner = retiring },
        .{ .parent = parent_id, .position = content, .owner = retiring },
        .{ .parent = parent_id, .position = other, .owner = sibling },
        .{ .parent = parent_id, .position = tail, .owner = outer },
    }) |unit| try initial.place(unit, null);
    try initial.preflight();
    initial.commit();
    var removed = positions.prepare();
    defer removed.deinit();
    try removed.retireScope(retiring);
    try std.testing.expectEqual(ids.ElemId.fromRaw(5), (try removed.anchor(parent_id, site)).?);
    try std.testing.expectEqual(ids.ElemId.fromRaw(4), (try positions.anchor(parent_id, site)).?);
    try std.testing.expectEqual(@as(u32, 2), removed.memberships.count());
    try removed.preflight();
    removed.commit();
    try std.testing.expectEqual(@as(usize, 0), positions.ownedCount(retiring));
    try std.testing.expectEqual(@as(usize, 2), positions.ownedCount(outer));
    try std.testing.expectEqual(@as(usize, 1), positions.ownedCount(sibling));
    try std.testing.expectEqual(null, positions.entry(nested));
    try std.testing.expectEqual(other, (try positions.nextPosition(parent_id, site)).?);
    var reused = positions.prepare();
    defer reused.deinit();
    try reused.place(.{ .parent = parent_id, .position = nested, .owner = retiring }, other);
    try reused.preflight();
    reused.commit();
    try std.testing.expectEqual(@as(usize, 1), positions.ownedCount(retiring));
    try std.testing.expectEqual(nested, (try positions.nextPosition(parent_id, site)).?);
}

test "structural ownership rejects scope stealing and cross-parent aliases" {
    var positions = Positions.init(std.testing.allocator);
    defer positions.deinit();
    try seedRefusalPositions(&positions);
    const existing = PositionId.element(ids.ElemId.fromRaw(2));
    var wrong_owner = positions.prepare();
    defer wrong_owner.deinit();
    try std.testing.expectError(error.InvalidRow, wrong_owner.place(.{ .parent = ids.root_elem, .position = existing, .owner = ids.ScopeId.fromRaw(1) }, null));
    var wrong_parent = positions.prepare();
    defer wrong_parent.deinit();
    try std.testing.expectError(error.InvalidRow, wrong_parent.place(.{ .parent = ids.ElemId.fromRaw(9), .position = existing, .owner = ids.ScopeId.fromRaw(0) }, null));
    try std.testing.expectEqual(ids.root_elem, positions.entry(existing).?.parent);
    try std.testing.expectEqual(@as(usize, 2), positions.ownedCount(ids.ScopeId.fromRaw(0)));
}

test "retiring a lexical row interval preserves neighboring empty markers and nested ownership" {
    var positions = Positions.init(std.testing.allocator);
    defer positions.deinit();
    const scope = ids.ScopeId.fromRaw(1);
    const nested = ids.ScopeId.fromRaw(2);
    const parent = ids.root_elem;
    const boundary = PositionId.marker(ids.NodeId.fromRaw(4), .when);
    const start = PositionId.rowStart(scope);
    const end = PositionId.rowEnd(scope);
    const root = PositionId.element(ids.ElemId.fromRaw(8));
    var seed = positions.prepare();
    defer seed.deinit();
    try seed.place(.{ .parent = parent, .position = start, .owner = scope }, null);
    try seed.place(.{ .parent = parent, .position = root, .owner = nested }, null);
    try seed.place(.{ .parent = parent, .position = end, .owner = scope }, null);
    try seed.place(.{ .parent = parent, .position = boundary, .owner = ids.root_scope }, null);
    try seed.place(.{ .parent = ids.ElemId.fromRaw(8), .position = PositionId.element(ids.ElemId.fromRaw(9)), .owner = nested }, null);
    try seed.preflight();
    seed.commit();
    var next = positions.prepare();
    defer next.deinit();
    const roots = try next.rootsInRange(parent, start, end);
    try std.testing.expectEqual(@as(usize, 1), roots.count);
    try std.testing.expectEqual(ids.ElemId.fromRaw(8), roots.first.?);
    try next.retireRange(parent, start, end);
    try next.retireScope(nested);
    try std.testing.expectEqual(@as(usize, 0), try next.positionRank(parent, boundary));
    try std.testing.expectEqual(@as(usize, 2), positions.ownedCount(nested));
    try next.preflight();
    next.commit();
    try std.testing.expectEqual(@as(usize, 0), positions.ownedCount(scope));
    try std.testing.expectEqual(@as(usize, 0), positions.ownedCount(nested));
    try std.testing.expectEqual(null, try positions.anchor(parent, boundary));
}

fn expectParentOrder(positions: *const Positions, parent_id: ids.ElemId, expected: []const PositionId) !void {
    for (expected, 0..) |position, index| {
        const next: ?PositionId = if (index + 1 < expected.len) expected[index + 1] else null;
        try std.testing.expectEqual(next, try positions.nextPosition(parent_id, position));
    }
}

test "small parents promote to a tree at capacity while preserving exact sibling order" {
    var positions = Positions.init(std.testing.allocator);
    defer positions.deinit();
    const parent_id = ids.root_elem;
    const owner = ids.ScopeId.fromRaw(1);
    var expected: [small_capacity + 3]PositionId = undefined;
    for (&expected, 0..) |*position, index| position.* = if (index % 2 == 0) PositionId.element(ids.ElemId.fromRaw(index + 10)) else PositionId.marker(ids.NodeId.fromRaw(index + 10), .when);

    var seed = positions.prepare();
    defer seed.deinit();
    for (expected[0..small_capacity]) |position| try seed.place(.{ .parent = parent_id, .position = position, .owner = owner }, null);
    try std.testing.expectEqual(@as(usize, 0), seed.work().tree_parents);
    try seed.preflight();
    seed.commit();
    try std.testing.expectEqual(@as(usize, 0), positions.treeIndexCount());
    try expectParentOrder(&positions, parent_id, expected[0..small_capacity]);

    // A candidate that overflows promotes privately; abandoning it leaves the
    // committed inline order untouched.
    var abandoned = positions.prepare();
    try abandoned.place(.{ .parent = parent_id, .position = expected[small_capacity], .owner = owner }, expected[0]);
    try std.testing.expectEqual(@as(usize, 1), abandoned.work().fresh_tree_indexes);
    try std.testing.expectEqual(@as(usize, 0), try abandoned.positionRank(parent_id, expected[small_capacity]));
    abandoned.deinit();
    try std.testing.expectEqual(@as(usize, 0), positions.treeIndexCount());
    try expectParentOrder(&positions, parent_id, expected[0..small_capacity]);

    // Promotion in the middle, then further tree insertions, keep exact order.
    var grow = positions.prepare();
    defer grow.deinit();
    try grow.place(.{ .parent = parent_id, .position = expected[small_capacity + 1], .owner = owner }, expected[3]);
    try grow.place(.{ .parent = parent_id, .position = expected[small_capacity], .owner = owner }, expected[small_capacity + 1]);
    try grow.place(.{ .parent = parent_id, .position = expected[small_capacity + 2], .owner = owner }, null);
    try grow.preflight();
    grow.commit();
    try std.testing.expectEqual(@as(usize, 1), positions.treeIndexCount());
    var order: [small_capacity + 3]PositionId = undefined;
    @memcpy(order[0..3], expected[0..3]);
    order[3] = expected[small_capacity];
    order[4] = expected[small_capacity + 1];
    @memcpy(order[5 .. small_capacity + 2], expected[3..small_capacity]);
    order[small_capacity + 2] = expected[small_capacity + 2];
    try expectParentOrder(&positions, parent_id, &order);
    try std.testing.expectEqual(ids.ElemId.fromRaw(small_capacity + 12), (try positions.anchor(parent_id, expected[small_capacity - 1])).?);

    // Retiring everything reclaims the tree index and the parent key.
    var retire = positions.prepare();
    defer retire.deinit();
    try retire.retireScope(owner);
    try retire.preflight();
    retire.commit();
    try std.testing.expectEqual(@as(usize, 0), positions.parents.count());
    try std.testing.expectEqual(@as(usize, 0), positions.ownedCount(owner));
}

test "small parent moves removes and range queries match the tree semantics" {
    var positions = Positions.init(std.testing.allocator);
    defer positions.deinit();
    const parent_id = ids.root_elem;
    const scope = ids.ScopeId.fromRaw(3);
    const outer = ids.ScopeId.fromRaw(1);
    const site = PositionId.marker(ids.NodeId.fromRaw(1), .each);
    const start = PositionId.rowStart(scope);
    const root = PositionId.element(ids.ElemId.fromRaw(5));
    const empty = PositionId.marker(ids.NodeId.fromRaw(6), .when);
    const end = PositionId.rowEnd(scope);
    const tail = PositionId.element(ids.ElemId.fromRaw(7));
    const site_end = PositionId.marker(ids.NodeId.fromRaw(1), .each_end);
    var seed = positions.prepare();
    defer seed.deinit();
    for ([_]Entry{
        .{ .parent = parent_id, .position = site, .owner = outer },
        .{ .parent = parent_id, .position = start, .owner = scope },
        .{ .parent = parent_id, .position = root, .owner = scope },
        .{ .parent = parent_id, .position = empty, .owner = scope },
        .{ .parent = parent_id, .position = end, .owner = scope },
        .{ .parent = parent_id, .position = tail, .owner = outer },
        .{ .parent = parent_id, .position = site_end, .owner = outer },
    }) |unit| try seed.place(unit, null);
    try seed.preflight();
    seed.commit();
    try std.testing.expectEqual(@as(usize, 0), positions.treeIndexCount());

    var plan = positions.prepare();
    defer plan.deinit();
    const roots = try plan.rootsInRange(parent_id, start, end);
    try std.testing.expectEqual(@as(usize, 1), roots.count);
    try std.testing.expectEqual(ids.ElemId.fromRaw(5), roots.first.?);
    try std.testing.expectEqual(ids.ElemId.fromRaw(5), roots.last.?);
    try std.testing.expectError(error.InvalidRange, plan.rootsInRange(parent_id, end, start));
    try std.testing.expectError(error.AnchorInsideRange, plan.moveRange(parent_id, start, end, empty));
    // Move the row after the tail (forward), then back before the tail.
    try plan.moveRange(parent_id, start, end, site_end);
    try std.testing.expectEqual(ids.ElemId.fromRaw(7), (try plan.anchor(parent_id, site)).?);
    try std.testing.expectEqual(null, try plan.anchor(parent_id, empty));
    try plan.moveRange(parent_id, start, end, tail);
    try std.testing.expectEqual(ids.ElemId.fromRaw(5), (try plan.anchor(parent_id, site)).?);
    try plan.moveRange(parent_id, tail, tail, start);
    try std.testing.expectEqual(ids.ElemId.fromRaw(7), (try plan.anchor(parent_id, site)).?);
    try plan.retireRange(parent_id, start, end);
    try std.testing.expectEqual(site_end, (try plan.nextPosition(parent_id, tail)).?);
    try std.testing.expectEqual(@as(usize, 1), try plan.positionRank(parent_id, tail));
    try plan.preflight();
    plan.commit();
    try expectParentOrder(&positions, parent_id, &.{ site, tail, site_end });
    try std.testing.expectEqual(@as(usize, 0), positions.ownedCount(scope));
    try std.testing.expectEqual(@as(usize, 3), positions.ownedCount(outer));
}

fn seedFullSmallParent(positions: *Positions) !void {
    var plan = positions.prepare();
    defer plan.deinit();
    for (0..small_capacity) |index| try plan.place(.{ .parent = ids.root_elem, .position = PositionId.element(ids.ElemId.fromRaw(index + 2)), .owner = ids.ScopeId.fromRaw(0) }, null);
    try plan.preflight();
    plan.commit();
}

fn preparePromotion(plan: *Prepared) !void {
    try plan.place(.{ .parent = ids.root_elem, .position = PositionId.marker(ids.NodeId.fromRaw(1), .when), .owner = ids.ScopeId.fromRaw(1) }, PositionId.element(ids.ElemId.fromRaw(2)));
    try plan.preflight();
}

test "promotion refusal at every allocation leaves the inline parent retryable" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var counted = FaultAllocator.init(std.testing.allocator);
    var baseline = Positions.init(counted.allocator());
    defer baseline.deinit();
    try seedFullSmallParent(&baseline);
    counted.configure(null);
    var candidate = baseline.prepare();
    defer candidate.deinit();
    try preparePromotion(&candidate);
    const attempts = counted.attempts;
    try std.testing.expect(attempts > 0);
    for (1..attempts + 1) |position| {
        var fault = FaultAllocator.init(std.testing.allocator);
        var positions = Positions.init(fault.allocator());
        defer positions.deinit();
        try seedFullSmallParent(&positions);
        fault.configure(position);
        var refused = positions.prepare();
        try std.testing.expectError(error.OutOfMemory, preparePromotion(&refused));
        refused.deinit();
        try std.testing.expectEqual(@as(usize, 0), positions.treeIndexCount());
        try std.testing.expectEqual(ids.ElemId.fromRaw(2), (try positions.anchor(ids.root_elem, PositionId.element(ids.ElemId.fromRaw(2)))).?);
        try std.testing.expectEqual(@as(usize, small_capacity), positions.ownedCount(ids.ScopeId.fromRaw(0)));
        fault.configure(null);
        var retry = positions.prepare();
        defer retry.deinit();
        try preparePromotion(&retry);
        fault.configure(1);
        retry.commit();
        try std.testing.expectEqual(@as(usize, 0), fault.attempts);
        fault.configure(null);
        try std.testing.expectEqual(@as(usize, 1), positions.treeIndexCount());
        const marker = PositionId.marker(ids.NodeId.fromRaw(1), .when);
        try std.testing.expectEqual(ids.ElemId.fromRaw(2), (try positions.anchor(ids.root_elem, marker)).?);
        try std.testing.expectEqual(PositionId.element(ids.ElemId.fromRaw(2)), (try positions.nextPosition(ids.root_elem, marker)).?);
        try std.testing.expectEqual(@as(usize, 1), positions.ownedCount(ids.ScopeId.fromRaw(1)));
    }
}

test "bulk row creation keeps order-index allocation proportional to large parents" {
    // Shape of one keyed-table row: the table body receives a row-start
    // marker, the row element, and a row-end marker; the row itself owns
    // four cells, two of which own a link, and one link owns an icon.
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var counted = FaultAllocator.init(std.testing.allocator);
    var positions = Positions.init(counted.allocator());
    defer positions.deinit();
    const rows = 1000;
    const body = ids.ElemId.fromRaw(1);
    var plan = positions.prepare();
    defer plan.deinit();
    try plan.place(.{ .parent = body, .position = PositionId.marker(ids.NodeId.fromRaw(1), .each), .owner = ids.root_scope }, null);
    try plan.place(.{ .parent = body, .position = PositionId.marker(ids.NodeId.fromRaw(1), .each_end), .owner = ids.root_scope }, null);
    counted.configure(null);
    const end_marker = PositionId.marker(ids.NodeId.fromRaw(1), .each_end);
    var next_elem: u64 = 2;
    for (0..rows) |row| {
        const scope = ids.ScopeId.fromRaw(row + 1);
        var elems: [8]ids.ElemId = undefined;
        for (&elems) |*elem| {
            elem.* = ids.ElemId.fromRaw(next_elem);
            next_elem += 1;
        }
        try plan.place(.{ .parent = body, .position = PositionId.rowStart(scope), .owner = scope }, end_marker);
        try plan.place(.{ .parent = body, .position = PositionId.element(elems[0]), .owner = scope }, end_marker);
        try plan.place(.{ .parent = body, .position = PositionId.rowEnd(scope), .owner = scope }, end_marker);
        for (elems[1..5]) |cell| try plan.place(.{ .parent = elems[0], .position = PositionId.element(cell), .owner = scope }, null);
        try plan.place(.{ .parent = elems[2], .position = PositionId.element(elems[5]), .owner = scope }, null);
        try plan.place(.{ .parent = elems[3], .position = PositionId.element(elems[6]), .owner = scope }, null);
        try plan.place(.{ .parent = elems[6], .position = PositionId.element(elems[7]), .owner = scope }, null);
    }
    try plan.preflight();
    // Allocation attempts scale with hash-table doublings, not with rows:
    // a per-parent heap index would need at least two attempts per parent.
    try std.testing.expect(counted.attempts < 128);
    const work = plan.work();
    try std.testing.expectEqual(@as(usize, 1 + rows * 4), work.parents);
    try std.testing.expectEqual(@as(usize, rows * 4), work.small_parents);
    try std.testing.expectEqual(@as(usize, 1), work.tree_parents);
    try std.testing.expectEqual(@as(usize, 1), work.fresh_tree_indexes);
    plan.commit();
    try std.testing.expectEqual(@as(usize, 1), positions.treeIndexCount());
    try std.testing.expectEqual(@as(usize, 1 + rows * 4), positions.parents.count());
    const last_scope = ids.ScopeId.fromRaw(rows);
    try std.testing.expectEqual(end_marker, (try positions.nextPosition(body, PositionId.rowEnd(last_scope))).?);
    try std.testing.expectEqual(ids.ElemId.fromRaw(next_elem - 8), (try positions.anchor(body, PositionId.rowStart(last_scope))).?);
    try std.testing.expectEqual(ids.ElemId.fromRaw(next_elem - 1), (try positions.anchor(ids.ElemId.fromRaw(next_elem - 2), PositionId.element(ids.ElemId.fromRaw(next_elem - 1)))).?);
}
