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

    /// Inserts or moves one explicitly collected unit before another retained
    /// position. Cross-parent moves must first remove their old membership.
    pub fn place(self: *Prepared, entry: Entry, before: ?PositionId) Error!void {
        const value = try self.parent(entry.parent);
        if (value.edits.span(entry.position)) |_| {
            _ = try value.edits.moveRange(entry.position, 1, before);
        } else |err| switch (err) {
            error.InvalidRow => try value.edits.insertBefore(entry.position, before, entry.position.span()),
        }
    }

    /// Retires exactly one scope-owned unit. Missing identity is an error.
    pub fn remove(self: *Prepared, parent_id: ids.ElemId, position: PositionId) Error!void {
        const value = try self.parent(parent_id);
        _ = try value.edits.removeRange(position, 1);
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
        fault.configure(null);
        var retry = positions.prepare();
        defer retry.deinit();
        try prepareRefusalPositions(&retry);
        fault.configure(1);
        retry.commit();
        try std.testing.expectEqual(@as(usize, 0), fault.attempts);
        try std.testing.expectEqual(null, try positions.anchor(ids.root_elem, marker));
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
