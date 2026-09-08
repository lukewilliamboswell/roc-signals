//! Stable lexical positions for dynamic structure, including empty branches.
//! Markers are engine data with zero render roots, never placeholder elements.
//! Parent-local order aggregates skip arbitrary runs of empty markers in
//! logarithmic expected time. Preparation changes only touched index paths.
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

/// Owns lexical order indexes. A parent's empty structural markers remain live
/// even when it has no rendered children; scope disposal removes those markers.
pub const Positions = struct {
    allocator: std.mem.Allocator,
    parents: std.AutoHashMapUnmanaged(ids.ElemId, *Index) = .empty,
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
        while (iterator.next()) |index| {
            index.*.deinit();
            self.allocator.destroy(index.*);
        }
        self.parents.deinit(self.allocator);
        self.memberships.deinit(self.allocator);
        self.scopes.deinit(self.allocator);
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
        const index = self.parents.get(parent) orelse return error.InvalidRow;
        const result = try index.firstRootAtOrAfter(marker);
        return if (result) |root| ids.ElemId.fromRaw(root.root_id) else null;
    }

    /// Returns the immediate lexical successor, including zero-root markers.
    /// Use this as the insertion boundary for replacement contents; a visible
    /// root alone would place them after adjacent empty construction sites.
    pub fn nextPosition(self: *const Positions, parent: ids.ElemId, marker: PositionId) error{ InvalidRow, InvalidRange }!?PositionId {
        const index = self.parents.get(parent) orelse return error.InvalidRow;
        const rank = try index.rank(marker);
        return if (rank + 1 < index.len()) try index.rowAt(rank + 1) else null;
    }

    /// Starts a path-copy candidate with no committed mutation.
    pub fn prepare(self: *Positions) Prepared {
        return .{ .positions = self };
    }
};

/// Owns changed paths and fresh parent indexes until atomic publication.
pub const Prepared = struct {
    const Parent = struct { index: *Index, edits: Index.PreparedEdits, owned: bool };
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
        const existing = self.positions.parents.get(id);
        const index = existing orelse try self.positions.allocator.create(Index);
        if (existing == null) index.* = Index.init(self.positions.allocator);
        const slot = self.parents.getOrPutAssumeCapacity(id);
        slot.value_ptr.* = .{ .index = index, .edits = index.prepare(), .owned = existing == null };
        return slot.value_ptr;
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
            _ = try value.edits.moveRange(entry.position, 1, before);
        } else {
            try value.edits.insertBefore(entry.position, before, entry.position.span());
            try self.addOwnership(entry);
        }
    }

    /// Retires exactly one scope-owned unit. Missing identity is an error.
    pub fn remove(self: *Prepared, parent_id: ids.ElemId, position: PositionId) Error!void {
        const value = try self.parent(parent_id);
        const old = self.membership(position) orelse return error.InvalidRow;
        if (old.entry.parent != parent_id) return error.InvalidRow;
        _ = try value.edits.removeRange(position, 1);
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
        const first_rank = try value.edits.rank(first);
        const last_rank = try value.edits.rank(last);
        if (last_rank < first_rank) return error.InvalidRange;
        _ = try value.edits.moveRange(first, last_rank - first_rank + 1, before);
    }

    /// Retires a lexical interval, including markers owned by nested scopes.
    /// Other parents belonging to those scopes are retired by retireScope.
    pub fn retireRange(self: *Prepared, parent_id: ids.ElemId, first: PositionId, last: PositionId) Error!void {
        const value = try self.parent(parent_id);
        const first_rank = try value.edits.rank(first);
        const last_rank = try value.edits.rank(last);
        if (last_rank < first_rank) return error.InvalidRange;
        for (0..last_rank - first_rank + 1) |_| {
            const position = try value.edits.rowAt(first_rank);
            try self.remove(parent_id, position);
        }
    }

    /// Returns one position's candidate rank for ordering a changed set of
    /// neighboring construction sites, without inspecting unrelated siblings.
    pub fn positionRank(self: *const Prepared, parent_id: ids.ElemId, position: PositionId) error{InvalidRow}!usize {
        if (self.parents.get(parent_id)) |value| return value.edits.rank(position);
        const index = self.positions.parents.get(parent_id) orelse return error.InvalidRow;
        return index.rank(position);
    }

    /// Summarizes visible roots inside retained lexical boundaries. Empty
    /// nested sites contribute zero, so callers never scan unrelated rows.
    pub fn rootsInRange(self: *Prepared, parent_id: ids.ElemId, first: PositionId, last: PositionId) Error!struct { first: ?ids.ElemId, last: ?ids.ElemId, count: usize } {
        const value = try self.parent(parent_id);
        const first_rank = try value.edits.rank(first);
        const last_rank = try value.edits.rank(last);
        if (last_rank < first_rank) return error.InvalidRange;
        const roots = try value.edits.rootsInRange(first, last_rank - first_rank + 1);
        return .{ .first = if (roots.first) |id| ids.ElemId.fromRaw(id) else null, .last = if (roots.last) |id| ids.ElemId.fromRaw(id) else null, .count = roots.count };
    }

    /// Queries the final candidate after preceding removals and insertions.
    /// Adjacent empty sites do not require per-neighbor anchor rewrites.
    pub fn anchor(self: *const Prepared, parent_id: ids.ElemId, marker: PositionId) error{InvalidRow}!?ids.ElemId {
        if (self.parents.get(parent_id)) |value| {
            const result = try value.edits.firstRootAtOrAfter(marker);
            return if (result) |root| ids.ElemId.fromRaw(root.root_id) else null;
        }
        return self.positions.anchor(parent_id, marker);
    }

    /// Resolves the lexical insertion boundary in the candidate after retired
    /// units have been removed, preserving the order of neighboring empty sites.
    pub fn nextPosition(self: *const Prepared, parent_id: ids.ElemId, marker: PositionId) error{ InvalidRow, InvalidRange }!?PositionId {
        if (self.parents.get(parent_id)) |value| {
            const rank = try value.edits.rank(marker);
            return if (rank + 1 < value.edits.len()) try value.edits.rowAt(rank + 1) else null;
        }
        return self.positions.nextPosition(parent_id, marker);
    }

    /// Reserves every persistent table growth after the last candidate edit.
    pub fn preflight(self: *Prepared) Error!void {
        var fresh: u32 = 0;
        var iterator = self.parents.valueIterator();
        while (iterator.next()) |value| {
            try value.edits.preflightCommit();
            if (value.owned and value.edits.len() != 0) fresh = std.math.add(u32, fresh, 1) catch return error.ResourceLimit;
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
            value.edits.commitAssumePreflighted();
            if (value.edits.len() == 0) {
                if (!value.owned) _ = self.positions.parents.remove(slot.key_ptr.*);
                value.owned = true;
            } else if (value.owned) {
                self.positions.parents.putAssumeCapacity(slot.key_ptr.*, value.index);
                value.owned = false;
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
        while (iterator.next()) |value| {
            value.edits.deinit();
            if (value.owned) {
                value.index.deinit();
                self.positions.allocator.destroy(value.index);
            }
        }
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
    try std.testing.expect(edit.parents.get(parent_id).?.edits.stats().nodes_touched < 100);
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
