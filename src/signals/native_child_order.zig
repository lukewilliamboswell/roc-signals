//! Indexed presentation of an already-decided native child command stream.
//! This owns no reactive meaning: stable element handles and their ordering
//! come from the shared render journals. Prepared overlays keep publication
//! atomic while allowing viewport rank queries without enumerating siblings.
const std = @import("std");
const ids = @import("ids.zig");
const order = @import("rows_render_order.zig");
const ElemId = ids.ElemId;
const Span = struct { first_root: ?u64, last_root: ?u64, root_count: u32 = 1 };
const Index = order.StableOrderIndex(ElemId, Span);

pub const Error = Index.Error;

/// Retains one indexed order per nonempty native container. All element
/// lifetimes remain owned by the engine; this is an executor-side projection.
pub const Tree = struct {
    allocator: std.mem.Allocator,
    orders: std.AutoHashMapUnmanaged(ElemId, *Index) = .empty,

    /// Creates an empty projection; `deinit` releases every owned order.
    pub fn init(allocator: std.mem.Allocator) Tree {
        return .{ .allocator = allocator };
    }

    /// Releases the projection after all borrowed viewport queries have ended.
    pub fn deinit(self: *Tree) void {
        var iterator = self.orders.valueIterator();
        while (iterator.next()) |index| {
            index.*.deinit();
            self.allocator.destroy(index.*);
        }
        self.orders.deinit(self.allocator);
    }

    /// Returns a container's committed child count in constant expected time.
    pub fn count(self: *const Tree, parent: ElemId) usize {
        return if (self.orders.get(parent)) |index| index.len() else 0;
    }

    /// Resolves a visible child by rank without visiting preceding siblings.
    pub fn childAt(self: *const Tree, parent: ElemId, rank: usize) error{InvalidRange}!ElemId {
        const index = self.orders.get(parent) orelse return error.InvalidRange;
        return index.rowAt(rank);
    }

    /// Begins an independently owned candidate. Aborting it leaves all
    /// committed order and identity information unchanged.
    pub fn prepare(self: *Tree) Prepared {
        return .{ .tree = self };
    }
};

/// Holds only changed order paths. Fresh indexes belong to this object until
/// commit transfers them into the tree; existing indexes are borrowed bases.
pub const Prepared = struct {
    const Entry = struct { base: *Index, edits: Index.PreparedEdits, fresh: bool };
    tree: *Tree,
    entries: std.AutoHashMapUnmanaged(ElemId, Entry) = .empty,
    preflighted: bool = false,
    committed: bool = false,

    fn entry(self: *Prepared, parent: ElemId) Error!*Entry {
        if (self.committed) @panic("native child order edited after commit");
        self.preflighted = false;
        if (self.entries.getPtr(parent)) |existing| return existing;
        try self.entries.ensureUnusedCapacity(self.tree.allocator, 1);
        const existing = self.tree.orders.get(parent);
        const index = existing orelse try self.tree.allocator.create(Index);
        if (existing == null) index.* = Index.init(self.tree.allocator);
        const result = self.entries.getOrPutAssumeCapacity(parent);
        result.value_ptr.* = .{ .base = index, .edits = index.prepare(), .fresh = existing == null };
        return result.value_ptr;
    }

    /// Replaces a declared whole child snapshot. This intentionally visits the
    /// replaced set; sparse journals should use `place` and `detach` instead.
    pub fn replace(self: *Prepared, parent: ElemId, children: []const ElemId) Error!void {
        const value = try self.entry(parent);
        if (value.edits.len() != 0) _ = try value.edits.removeRange(try value.edits.rowAt(0), value.edits.len());
        for (children) |child| try value.edits.insertBefore(child, null, .{ .first_root = child.raw(), .last_root = child.raw() });
    }

    /// Applies an engine-decided insertion or move before a stable anchor.
    /// The caller detaches cross-parent moves from their previous order first.
    pub fn place(self: *Prepared, parent: ElemId, child: ElemId, before: ?ElemId) Error!void {
        const value = try self.entry(parent);
        if (value.edits.span(child)) |_| {
            _ = try value.edits.moveRange(child, 1, before);
        } else |err| switch (err) {
            error.InvalidRow => try value.edits.insertBefore(child, before, .{ .first_root = child.raw(), .last_root = child.raw() }),
        }
    }

    /// Removes a child from its declared previous parent. An absent child is a
    /// contract error, so stale or incomplete command streams cannot be repaired.
    pub fn detach(self: *Prepared, parent: ElemId, child: ElemId) Error!void {
        const value = try self.entry(parent);
        _ = try value.edits.removeRange(child, 1);
    }

    /// Reserves every committed map insertion after the final edit. Successful
    /// publication then cannot allocate or partially fail.
    pub fn preflight(self: *Prepared) Error!void {
        var fresh: u32 = 0;
        var iterator = self.entries.valueIterator();
        while (iterator.next()) |value| {
            try value.edits.preflightCommit();
            if (value.fresh and value.edits.len() != 0) fresh = std.math.add(u32, fresh, 1) catch return error.ResourceLimit;
        }
        try self.tree.orders.ensureUnusedCapacity(self.tree.allocator, fresh);
        self.preflighted = true;
    }

    /// Commits the complete projection and retires empty container indexes.
    pub fn commit(self: *Prepared) void {
        if (!self.preflighted or self.committed) @panic("native child order was not preflighted exactly once");
        var iterator = self.entries.iterator();
        while (iterator.next()) |value| {
            const e = value.value_ptr;
            e.edits.commitAssumePreflighted();
            if (e.base.len() == 0) {
                if (!e.fresh) _ = self.tree.orders.remove(value.key_ptr.*);
                // Retired empty bases remain owned by this preparation until
                // its overlay has been released in deinit.
                e.fresh = true;
            } else if (e.fresh) {
                self.tree.orders.putAssumeCapacity(value.key_ptr.*, e.base);
                e.fresh = false;
            }
        }
        self.committed = true;
    }

    /// Releases candidate paths and any aborted or retired empty indexes.
    pub fn deinit(self: *Prepared) void {
        var iterator = self.entries.valueIterator();
        while (iterator.next()) |value| {
            value.edits.deinit();
            if (value.fresh) {
                value.base.deinit();
                self.tree.allocator.destroy(value.base);
            }
        }
        self.entries.deinit(self.tree.allocator);
    }
};

test "native child order retains identities through sparse moves and viewport queries" {
    const allocator = std.testing.allocator;
    for ([_]usize{ 100, 10000 }) |count| {
        var tree = Tree.init(allocator);
        defer tree.deinit();
        const parent = ElemId.fromRaw(0);
        var initial = tree.prepare();
        defer initial.deinit();
        for (0..count) |i| try initial.place(parent, ElemId.fromIndex(i + 1), null);
        try initial.preflight();
        initial.commit();
        var edit = tree.prepare();
        defer edit.deinit();
        try edit.place(parent, ElemId.fromRaw(1), null);
        try edit.detach(parent, ElemId.fromRaw(2));
        try edit.place(ElemId.fromIndex(count + 1), ElemId.fromRaw(2), null);
        try edit.preflight();
        try std.testing.expectEqual(ElemId.fromRaw(1), try tree.childAt(parent, 0));
        edit.commit();
        try std.testing.expectEqual(count - 1, tree.count(parent));
        try std.testing.expectEqual(ElemId.fromRaw(3), try tree.childAt(parent, 0));
        try std.testing.expectEqual(ElemId.fromRaw(1), try tree.childAt(parent, count - 2));
        try std.testing.expectEqual(ElemId.fromRaw(2), try tree.childAt(ElemId.fromIndex(count + 1), 0));
        const stats = edit.entries.get(parent).?.edits.stats();
        try std.testing.expect(stats.nodes_touched < 100);
    }
}

fn seedFailureTree(tree: *Tree) !void {
    var plan = tree.prepare();
    defer plan.deinit();
    for (0..100) |i| try plan.place(ids.root_elem, ElemId.fromIndex(i + 1), null);
    try plan.preflight();
    plan.commit();
}

fn prepareFailureEdit(plan: *Prepared) !void {
    try plan.detach(ids.root_elem, ElemId.fromRaw(1));
    try plan.place(ElemId.fromRaw(101), ElemId.fromRaw(1), null);
    try plan.place(ids.root_elem, ElemId.fromRaw(102), null);
    try plan.preflight();
}

test "native child order refusal preserves prior view and commit cannot allocate" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var counted = FaultAllocator.init(std.testing.allocator);
    var baseline = Tree.init(counted.allocator());
    defer baseline.deinit();
    try seedFailureTree(&baseline);
    counted.configure(null);
    var candidate = baseline.prepare();
    defer candidate.deinit();
    try prepareFailureEdit(&candidate);
    const attempts = counted.attempts;
    try std.testing.expect(attempts > 0);
    for (1..attempts + 1) |position| {
        var fault = FaultAllocator.init(std.testing.allocator);
        var tree = Tree.init(fault.allocator());
        defer tree.deinit();
        try seedFailureTree(&tree);
        fault.configure(position);
        var refused = tree.prepare();
        try std.testing.expectError(error.OutOfMemory, prepareFailureEdit(&refused));
        refused.deinit();
        try std.testing.expectEqual(@as(usize, 100), tree.count(ids.root_elem));
        try std.testing.expectEqual(ElemId.fromRaw(1), try tree.childAt(ids.root_elem, 0));
        try std.testing.expectEqual(@as(usize, 0), tree.count(ElemId.fromRaw(101)));
        fault.configure(null);
        var retry = tree.prepare();
        defer retry.deinit();
        try prepareFailureEdit(&retry);
        fault.configure(1);
        retry.commit();
        try std.testing.expectEqual(@as(usize, 0), fault.attempts);
        try std.testing.expectEqual(ElemId.fromRaw(2), try tree.childAt(ids.root_elem, 0));
        try std.testing.expectEqual(ElemId.fromRaw(102), try tree.childAt(ids.root_elem, 99));
        try std.testing.expectEqual(ElemId.fromRaw(1), try tree.childAt(ElemId.fromRaw(101), 0));
        fault.configure(null);
    }
}
