//! Scope forest primitives for component, branch, and keyed row lifetimes.

const std = @import("std");
const shared_buffer = @import("shared_buffer.zig");
const semantic_ids = @import("ids.zig");

pub const Generation = semantic_ids.Generation;
pub const ScopeId = semantic_ids.ScopeId;
pub const SiteOrdinal = semantic_ids.SiteOrdinal;

pub const Lifecycle = union(enum) {
    active,
    retired: Generation,

    /// Reports whether this scope remains live and routable.
    /// Reports whether the scope currently belongs to the active forest.
    pub fn isActive(self: Lifecycle) bool {
        return self == .active;
    }

    /// Reports whether this lifecycle prevents slot reuse at the supplied barrier.
    /// Reports whether this state prevents reuse in the supplied generation.
    pub fn blocksReuse(self: Lifecycle, barrier: Generation) bool {
        return switch (self) {
            .active => true,
            .retired => |generation| generation == barrier,
        };
    }

    /// Returns the retirement generation, or null while the scope is active.
    pub fn retiredGeneration(self: Lifecycle) ?Generation {
        return switch (self) {
            .active => null,
            .retired => |generation| generation,
        };
    }
};

pub const Error = error{
    UnknownScope,
    InactiveScope,
    InvalidRoot,
    OutOfMemory,
};

pub const Branch = enum(u8) {
    false_branch,
    true_branch,

    /// Returns the sibling branch identity for an explicit conditional scope.
    pub fn opposite(self: Branch) Branch {
        return switch (self) {
            .false_branch => .true_branch,
            .true_branch => .false_branch,
        };
    }
};

pub const ComponentStep = struct {
    site_ordinal: SiteOrdinal,
};

pub const WhenBranchStep = struct {
    site_ordinal: SiteOrdinal,
    branch: Branch,
};

/// Defines one allocation-free action in scope-subtree disposal.
pub fn Step(comptime Row: type) type {
    return union(enum) {
        root,
        component: ComponentStep,
        when_branch: WhenBranchStep,
        each_row: Row,
    };
}

/// Defines explicit lifetime ownership for nodes, DOM structure, effects, and child scopes.
pub fn Scope(comptime Row: type) type {
    return struct {
        scope_id: ScopeId,
        parent_scope_id: ?ScopeId,
        /// First active child in construction order. Child topology is kept
        /// explicitly so subtree lifecycle work never searches the dense
        /// scope table for descendants.
        first_child_scope_id: ?ScopeId = null,
        /// Last active child in construction order, used for allocation-free
        /// append when a new child scope is published.
        last_child_scope_id: ?ScopeId = null,
        /// Previous active child owned by the same parent.
        previous_sibling_scope_id: ?ScopeId = null,
        /// Next active child owned by the same parent.
        next_sibling_scope_id: ?ScopeId = null,
        /// Reusable-slot ring links. A retired scope is linked between the
        /// slot retired just before it and the one retired just after it, so
        /// claiming a reusable slot reads the ring head instead of scanning
        /// the dense table. The root slot doubles as the ring sentinel: its
        /// `next` link is the oldest retired slot and its `previous` link the
        /// newest. Both links are null on an active scope and on a sentinel
        /// whose ring is empty. See `linkReusable` for the maintenance rule.
        previous_reusable_scope_id: ?ScopeId = null,
        next_reusable_scope_id: ?ScopeId = null,
        step: Step(Row),
        lifecycle: Lifecycle = .active,
    };
}

pub const InternResult = struct {
    scope_id: ScopeId,
    created: bool,
};

/// Rejects malformed boundary data before it can enter committed engine state.
pub fn validate(comptime Row: type, scopes: []const Scope(Row), scope_id: ScopeId) Error!void {
    if (scope_id.index() >= scopes.len) return Error.UnknownScope;
    const scope = scopes[scope_id.index()];
    if (scope.scope_id != scope_id) return Error.UnknownScope;
    if (!scope.lifecycle.isActive()) return Error.InactiveScope;
}

/// Creates or reuses root scope identity beneath its explicit owner.
pub fn internRoot(comptime Row: type, allocator: std.mem.Allocator, scopes: *shared_buffer.List(Scope(Row))) Error!InternResult {
    if (scopes.items.len == 0) {
        scopes.append(allocator, .{
            .scope_id = semantic_ids.root_scope,
            .parent_scope_id = null,
            .step = .root,
        }) catch return Error.OutOfMemory;
        return .{ .scope_id = semantic_ids.root_scope, .created = true };
    }

    const root = scopes.items[0];
    if (root.scope_id != semantic_ids.root_scope or root.parent_scope_id != null or root.step != .root or !root.lifecycle.isActive()) {
        return Error.InvalidRoot;
    }
    return .{ .scope_id = semantic_ids.root_scope, .created = false };
}

/// Creates or reuses component scope identity beneath its explicit owner.
pub fn internComponent(comptime Row: type, allocator: std.mem.Allocator, scopes: *shared_buffer.List(Scope(Row)), parent_scope_id: ScopeId, site_ordinal: SiteOrdinal, reuse_barrier: Generation) Error!InternResult {
    try validate(Row, scopes.items, parent_scope_id);

    var child_scope_id = scopes.items[parent_scope_id.index()].first_child_scope_id;
    while (child_scope_id) |id| {
        const scope = scopes.items[id.index()];
        if (!scope.lifecycle.isActive()) {
            child_scope_id = scope.next_sibling_scope_id;
            continue;
        }
        switch (scope.step) {
            .component => |step| {
                if (step.site_ordinal == site_ordinal) {
                    return .{ .scope_id = scope.scope_id, .created = false };
                }
            },
            .root, .when_branch, .each_row => {},
        }
        child_scope_id = scope.next_sibling_scope_id;
    }

    for (scopes.items) |*scope| {
        if (scope.lifecycle.isActive()) continue;
        if (scope.lifecycle.blocksReuse(reuse_barrier)) continue;
        const scope_id = scope.scope_id;
        publishScopeAssumeCapacity(Row, scopes, scopes.items.len, .{
            .scope_id = scope_id,
            .parent_scope_id = parent_scope_id,
            .step = .{ .component = .{ .site_ordinal = site_ordinal } },
        });
        return .{ .scope_id = scope_id, .created = true };
    }

    const scope_id = ScopeId.fromIndex(scopes.items.len);
    scopes.ensureUnusedCapacity(allocator, 1) catch return Error.OutOfMemory;
    publishScopeAssumeCapacity(Row, scopes, scopes.items.len, .{
        .scope_id = scope_id,
        .parent_scope_id = parent_scope_id,
        .step = .{ .component = .{ .site_ordinal = site_ordinal } },
    });
    return .{ .scope_id = scope_id, .created = true };
}

/// Creates or reuses when branch scope identity beneath its explicit owner.
pub fn internWhenBranch(comptime Row: type, allocator: std.mem.Allocator, scopes: *shared_buffer.List(Scope(Row)), parent_scope_id: ScopeId, site_ordinal: SiteOrdinal, branch: Branch, reuse_barrier: Generation) Error!InternResult {
    try validate(Row, scopes.items, parent_scope_id);

    var child_scope_id = scopes.items[parent_scope_id.index()].first_child_scope_id;
    while (child_scope_id) |id| {
        const scope = scopes.items[id.index()];
        if (!scope.lifecycle.isActive()) {
            child_scope_id = scope.next_sibling_scope_id;
            continue;
        }
        switch (scope.step) {
            .when_branch => |step| {
                if (step.site_ordinal == site_ordinal and step.branch == branch) {
                    return .{ .scope_id = scope.scope_id, .created = false };
                }
            },
            .root, .component, .each_row => {},
        }
        child_scope_id = scope.next_sibling_scope_id;
    }

    for (scopes.items) |*scope| {
        if (scope.lifecycle.isActive()) continue;
        if (scope.lifecycle.blocksReuse(reuse_barrier)) continue;
        const scope_id = scope.scope_id;
        publishScopeAssumeCapacity(Row, scopes, scopes.items.len, .{
            .scope_id = scope_id,
            .parent_scope_id = parent_scope_id,
            .step = .{ .when_branch = .{ .site_ordinal = site_ordinal, .branch = branch } },
        });
        return .{ .scope_id = scope_id, .created = true };
    }

    const scope_id = ScopeId.fromIndex(scopes.items.len);
    scopes.ensureUnusedCapacity(allocator, 1) catch return Error.OutOfMemory;
    publishScopeAssumeCapacity(Row, scopes, scopes.items.len, .{
        .scope_id = scope_id,
        .parent_scope_id = parent_scope_id,
        .step = .{ .when_branch = .{ .site_ordinal = site_ordinal, .branch = branch } },
    });
    return .{ .scope_id = scope_id, .created = true };
}

/// Appends each row using capacity that must already satisfy the caller's transaction contract.
pub fn appendEachRow(comptime Row: type, allocator: std.mem.Allocator, scopes: *shared_buffer.List(Scope(Row)), parent_scope_id: ScopeId, row: Row, reuse_barrier: Generation) Error!InternResult {
    try validate(Row, scopes.items, parent_scope_id);

    for (scopes.items) |*scope| {
        if (scope.lifecycle.isActive()) continue;
        if (scope.lifecycle.blocksReuse(reuse_barrier)) continue;
        const scope_id = scope.scope_id;
        publishScopeAssumeCapacity(Row, scopes, scopes.items.len, .{
            .scope_id = scope_id,
            .parent_scope_id = parent_scope_id,
            .step = .{ .each_row = row },
        });
        return .{ .scope_id = scope_id, .created = true };
    }

    return appendFreshEachRow(Row, allocator, scopes, parent_scope_id, row);
}

/// Appends fresh each row using capacity that must already satisfy the caller's transaction contract.
pub fn appendFreshEachRow(comptime Row: type, allocator: std.mem.Allocator, scopes: *shared_buffer.List(Scope(Row)), parent_scope_id: ScopeId, row: Row) Error!InternResult {
    try validate(Row, scopes.items, parent_scope_id);
    const scope_id = ScopeId.fromIndex(scopes.items.len);
    scopes.ensureUnusedCapacity(allocator, 1) catch return Error.OutOfMemory;
    publishScopeAssumeCapacity(Row, scopes, scopes.items.len, .{
        .scope_id = scope_id,
        .parent_scope_id = parent_scope_id,
        .step = .{ .each_row = row },
    });
    return .{ .scope_id = scope_id, .created = true };
}

/// Returns active when branch from the maintained active-runtime indexes.
pub fn activeWhenBranch(comptime Row: type, scopes: []const Scope(Row), parent_scope_id: ScopeId, site_ordinal: SiteOrdinal, branch: Branch) Error!?ScopeId {
    try validate(Row, scopes, parent_scope_id);

    var child_scope_id = scopes[parent_scope_id.index()].first_child_scope_id;
    while (child_scope_id) |id| {
        const scope = scopes[id.index()];
        if (!scope.lifecycle.isActive()) {
            child_scope_id = scope.next_sibling_scope_id;
            continue;
        }
        switch (scope.step) {
            .when_branch => |step| {
                if (step.site_ordinal == site_ordinal and step.branch == branch) return scope.scope_id;
            },
            .root, .component, .each_row => {},
        }
        child_scope_id = scope.next_sibling_scope_id;
    }
    return null;
}

/// Returns active each rows from the maintained active-runtime indexes.
pub fn activeEachRows(comptime Row: type, allocator: std.mem.Allocator, scopes: []const Scope(Row), parent_scope_id: ScopeId, site_ordinal: SiteOrdinal) Error![]ScopeId {
    var scope_ids: shared_buffer.List(ScopeId) = .empty;
    errdefer scope_ids.deinit(allocator);

    try validate(Row, scopes, parent_scope_id);
    var child_scope_id = scopes[parent_scope_id.index()].first_child_scope_id;
    while (child_scope_id) |id| {
        const scope = scopes[id.index()];
        if (!scope.lifecycle.isActive()) {
            child_scope_id = scope.next_sibling_scope_id;
            continue;
        }
        switch (scope.step) {
            .each_row => |row| {
                if (row.site_ordinal == site_ordinal) {
                    scope_ids.append(allocator, scope.scope_id) catch return Error.OutOfMemory;
                }
            },
            .root, .component, .when_branch => {},
        }
        child_scope_id = scope.next_sibling_scope_id;
    }

    return scope_ids.toOwnedSlice(allocator) catch return Error.OutOfMemory;
}

/// Publishes a prepared active scope and attaches it to its parent's intrusive
/// child list without allocating. `original_scope_len` separates initialized
/// reusable slots from the fresh suffix whose capacity the caller reserved.
pub fn publishScopeAssumeCapacity(comptime Row: type, scopes: *shared_buffer.List(Scope(Row)), original_scope_len: usize, prepared: Scope(Row)) void {
    const index = prepared.scope_id.index();
    if (index < original_scope_len) {
        const previous = &scopes.items[index];
        if (previous.lifecycle.isActive()) @panic("prepared scope reused an active slot");
        if (previous.first_child_scope_id != null or previous.last_child_scope_id != null) @panic("retired scope retained child topology");
        if (prepared.previous_reusable_scope_id != null or prepared.next_reusable_scope_id != null) @panic("prepared scope carried reusable-slot links");
        detachFromParent(Row, scopes.items, prepared.scope_id);
        unlinkReusable(Row, scopes.items, prepared.scope_id);
        scopes.items[index] = prepared;
    } else {
        if (index != scopes.items.len) @panic("prepared scope suffix was not contiguous");
        scopes.appendAssumeCapacity(prepared);
    }
    attachToParent(Row, scopes.items, prepared.scope_id);
}

/// Retires one childless scope and unlinks it from its active parent. Subtree
/// retirement calls this in post-order, making the operation allocation-free.
pub fn retireScopeAssumeValid(comptime Row: type, scopes: []Scope(Row), scope_id: ScopeId, retirement_generation: Generation) void {
    const scope = &scopes[scope_id.index()];
    if (scope.scope_id != scope_id or !scope.lifecycle.isActive()) @panic("scope retirement no longer matched live state");
    if (scope.first_child_scope_id != null or scope.last_child_scope_id != null) @panic("scope retired before its active children");
    detachFromParent(Row, scopes, scope_id);
    scope.lifecycle = .{ .retired = retirement_generation };
    linkReusable(Row, scopes, scope_id);
}

/// Returns the oldest retired slot in the reusable ring, or null when every
/// slot in the table is active. Slots are ordered by retirement, so a caller
/// that finds the head blocked by its reuse barrier knows every later slot
/// was retired in the same or a later generation and can stop immediately.
pub fn firstReusableScope(comptime Row: type, scopes: []const Scope(Row)) ?ScopeId {
    if (scopes.len == 0) return null;
    return scopes[semantic_ids.root_scope.index()].next_reusable_scope_id;
}

/// Returns the slot retired after `scope_id`, or null when `scope_id` is the
/// newest retired slot. `scope_id` must currently be linked in the ring.
pub fn nextReusableScope(comptime Row: type, scopes: []const Scope(Row), scope_id: ScopeId) ?ScopeId {
    const next = scopes[scope_id.index()].next_reusable_scope_id orelse @panic("scope is not a linked reusable slot");
    return if (next == semantic_ids.root_scope) null else next;
}

/// Reports whether `scope_id` is currently linked in the reusable ring.
pub fn isLinkedReusable(comptime Row: type, scopes: []const Scope(Row), scope_id: ScopeId) bool {
    return scope_id != semantic_ids.root_scope and scopes[scope_id.index()].next_reusable_scope_id != null;
}

/// Appends a freshly retired slot at the ring tail. Retirement is the only
/// way a slot enters the ring and publication (`publishScopeAssumeCapacity`)
/// the only way it leaves, so ring membership tracks the retired lifecycle
/// exactly and the ring is ordered by retirement generation. The root slot is
/// the sentinel and is never linked as a member: a retired root cannot be
/// re-interned, so the table is finished once that happens.
fn linkReusable(comptime Row: type, scopes: []Scope(Row), scope_id: ScopeId) void {
    if (scope_id == semantic_ids.root_scope) return;
    const scope = &scopes[scope_id.index()];
    if (scope.previous_reusable_scope_id != null or scope.next_reusable_scope_id != null) @panic("retired scope was already a reusable slot");
    const sentinel = &scopes[semantic_ids.root_scope.index()];
    const tail_id = sentinel.previous_reusable_scope_id orelse semantic_ids.root_scope;
    scope.previous_reusable_scope_id = tail_id;
    scope.next_reusable_scope_id = semantic_ids.root_scope;
    if (tail_id == semantic_ids.root_scope) sentinel.next_reusable_scope_id = scope_id else scopes[tail_id.index()].next_reusable_scope_id = scope_id;
    sentinel.previous_reusable_scope_id = scope_id;
}

/// Removes a slot from the ring before it is republished as an active scope.
/// A slot whose lifecycle was retired without `retireScopeAssumeValid` (test
/// fixtures do this) is not linked and is left alone.
fn unlinkReusable(comptime Row: type, scopes: []Scope(Row), scope_id: ScopeId) void {
    const scope = &scopes[scope_id.index()];
    const next_id = scope.next_reusable_scope_id orelse return;
    const previous_id = scope.previous_reusable_scope_id orelse @panic("reusable slot ring link was half initialized");
    const sentinel = &scopes[semantic_ids.root_scope.index()];
    if (previous_id == semantic_ids.root_scope) {
        sentinel.next_reusable_scope_id = if (next_id == semantic_ids.root_scope) null else next_id;
    } else {
        scopes[previous_id.index()].next_reusable_scope_id = next_id;
    }
    if (next_id == semantic_ids.root_scope) {
        sentinel.previous_reusable_scope_id = if (previous_id == semantic_ids.root_scope) null else previous_id;
    } else {
        scopes[next_id.index()].previous_reusable_scope_id = previous_id;
    }
    scope.previous_reusable_scope_id = null;
    scope.next_reusable_scope_id = null;
}

fn attachToParent(comptime Row: type, scopes: []Scope(Row), scope_id: ScopeId) void {
    const scope = &scopes[scope_id.index()];
    const parent_scope_id = scope.parent_scope_id orelse return;
    const parent = &scopes[parent_scope_id.index()];
    if (!parent.lifecycle.isActive()) @panic("active scope attached beneath an inactive parent");
    if (scope.previous_sibling_scope_id != null or scope.next_sibling_scope_id != null) @panic("scope attached twice");

    scope.previous_sibling_scope_id = parent.last_child_scope_id;
    if (parent.last_child_scope_id) |last_scope_id| {
        scopes[last_scope_id.index()].next_sibling_scope_id = scope_id;
    } else {
        parent.first_child_scope_id = scope_id;
    }
    parent.last_child_scope_id = scope_id;
}

fn detachFromParent(comptime Row: type, scopes: []Scope(Row), scope_id: ScopeId) void {
    const scope = &scopes[scope_id.index()];
    const parent_scope_id = scope.parent_scope_id orelse {
        scope.previous_sibling_scope_id = null;
        scope.next_sibling_scope_id = null;
        return;
    };
    const parent = &scopes[parent_scope_id.index()];
    const previous = scope.previous_sibling_scope_id;
    const next = scope.next_sibling_scope_id;
    if (previous) |previous_scope_id| {
        scopes[previous_scope_id.index()].next_sibling_scope_id = next;
    } else if (parent.first_child_scope_id == scope_id) {
        parent.first_child_scope_id = next;
    }
    if (next) |next_scope_id| {
        scopes[next_scope_id.index()].previous_sibling_scope_id = previous;
    } else if (parent.last_child_scope_id == scope_id) {
        parent.last_child_scope_id = previous;
    }
    scope.previous_sibling_scope_id = null;
    scope.next_sibling_scope_id = null;
}

/// Tests explicit scope ancestry without consulting rendered DOM structure.
pub fn eachSiteRowAncestor(comptime Row: type, scopes: []const Scope(Row), scope_id: ScopeId, parent_scope_id: ScopeId, site_ordinal: SiteOrdinal) Error!?ScopeId {
    var current: ?ScopeId = scope_id;
    while (current) |id| {
        if (id.index() >= scopes.len) return Error.UnknownScope;
        const scope = scopes[id.index()];
        switch (scope.step) {
            .each_row => |row| {
                if (scope.parent_scope_id == parent_scope_id and row.site_ordinal == site_ordinal) return id;
            },
            .root, .component, .when_branch => {},
        }
        current = scope.parent_scope_id;
    }
    return null;
}

/// Tests explicit scope ancestry without consulting rendered DOM structure.
pub fn descendantOrSelf(comptime Row: type, scopes: []const Scope(Row), scope_id: ScopeId, root_scope_id: ScopeId) Error!bool {
    var current: ?ScopeId = scope_id;
    while (current) |id| {
        if (id == root_scope_id) return true;
        if (id.index() >= scopes.len) return Error.UnknownScope;
        current = scopes[id.index()].parent_scope_id;
    }
    return false;
}

/// Tests whether a scope is the selected keyed row or one of its explicitly owned descendants.
pub fn eachSiteRowDescendantOrSelf(comptime Row: type, scopes: []const Scope(Row), scope_id: ScopeId, parent_scope_id: ScopeId, site_ordinal: SiteOrdinal) Error!bool {
    return (try eachSiteRowAncestor(Row, scopes, scope_id, parent_scope_id, site_ordinal)) != null;
}

const TestRow = struct {
    site_ordinal: SiteOrdinal,
    value: u64,
};

test "scope tree interns root component and branch scopes" {
    var scopes: shared_buffer.List(Scope(TestRow)) = .empty;
    defer scopes.deinit(std.testing.allocator);

    const root = try internRoot(TestRow, std.testing.allocator, &scopes);
    try std.testing.expectEqual(semantic_ids.root_scope, root.scope_id);
    try std.testing.expect(root.created);

    const same_root = try internRoot(TestRow, std.testing.allocator, &scopes);
    try std.testing.expectEqual(semantic_ids.root_scope, same_root.scope_id);
    try std.testing.expect(!same_root.created);

    const component = try internComponent(TestRow, std.testing.allocator, &scopes, root.scope_id, SiteOrdinal.fromRaw(4), semantic_ids.initial_generation);
    try std.testing.expect(component.created);
    const same_component = try internComponent(TestRow, std.testing.allocator, &scopes, root.scope_id, SiteOrdinal.fromRaw(4), semantic_ids.initial_generation);
    try std.testing.expectEqual(component.scope_id, same_component.scope_id);
    try std.testing.expect(!same_component.created);

    const false_branch = try internWhenBranch(TestRow, std.testing.allocator, &scopes, root.scope_id, SiteOrdinal.fromRaw(5), .false_branch, semantic_ids.initial_generation);
    const true_branch = try internWhenBranch(TestRow, std.testing.allocator, &scopes, root.scope_id, SiteOrdinal.fromRaw(5), .true_branch, semantic_ids.initial_generation);
    try std.testing.expect(false_branch.scope_id != true_branch.scope_id);
    try std.testing.expectEqual(false_branch.scope_id, (try activeWhenBranch(TestRow, scopes.items, root.scope_id, SiteOrdinal.fromRaw(5), .false_branch)).?);
    try std.testing.expectEqual(true_branch.scope_id, (try activeWhenBranch(TestRow, scopes.items, root.scope_id, SiteOrdinal.fromRaw(5), .true_branch)).?);
    try std.testing.expectEqual(Branch.true_branch, Branch.false_branch.opposite());
}

test "scope tree finds each rows and ancestry" {
    var scopes: shared_buffer.List(Scope(TestRow)) = .empty;
    defer scopes.deinit(std.testing.allocator);

    const root = (try internRoot(TestRow, std.testing.allocator, &scopes)).scope_id;
    const row_a = (try appendEachRow(TestRow, std.testing.allocator, &scopes, root, .{ .site_ordinal = SiteOrdinal.fromRaw(8), .value = 10 }, semantic_ids.initial_generation)).scope_id;
    const row_b = (try appendEachRow(TestRow, std.testing.allocator, &scopes, root, .{ .site_ordinal = SiteOrdinal.fromRaw(8), .value = 20 }, semantic_ids.initial_generation)).scope_id;
    const nested_component = (try internComponent(TestRow, std.testing.allocator, &scopes, row_b, SiteOrdinal.fromRaw(1), semantic_ids.initial_generation)).scope_id;
    _ = try appendEachRow(TestRow, std.testing.allocator, &scopes, root, .{ .site_ordinal = SiteOrdinal.fromRaw(9), .value = 30 }, semantic_ids.initial_generation);

    const rows = try activeEachRows(TestRow, std.testing.allocator, scopes.items, root, SiteOrdinal.fromRaw(8));
    defer std.testing.allocator.free(rows);
    try std.testing.expectEqualSlices(ScopeId, &.{ row_a, row_b }, rows);
    try std.testing.expectEqual(row_b, (try eachSiteRowAncestor(TestRow, scopes.items, nested_component, root, SiteOrdinal.fromRaw(8))).?);
    try std.testing.expect(try descendantOrSelf(TestRow, scopes.items, nested_component, row_b));
    try std.testing.expect(!try descendantOrSelf(TestRow, scopes.items, row_a, row_b));
    try std.testing.expect(try eachSiteRowDescendantOrSelf(TestRow, scopes.items, nested_component, root, SiteOrdinal.fromRaw(8)));
}

test "scope tree reuses inactive each row slots" {
    var scopes: shared_buffer.List(Scope(TestRow)) = .empty;
    defer scopes.deinit(std.testing.allocator);

    const root = (try internRoot(TestRow, std.testing.allocator, &scopes)).scope_id;
    const first = (try appendEachRow(TestRow, std.testing.allocator, &scopes, root, .{ .site_ordinal = SiteOrdinal.fromRaw(8), .value = 10 }, semantic_ids.initial_generation)).scope_id;
    scopes.items[first.index()].lifecycle = .{ .retired = Generation.fromRaw(1) };

    const reused = try appendEachRow(TestRow, std.testing.allocator, &scopes, root, .{ .site_ordinal = SiteOrdinal.fromRaw(8), .value = 20 }, semantic_ids.initial_generation);
    try std.testing.expect(reused.created);
    try std.testing.expectEqual(first, reused.scope_id);
    try std.testing.expectEqual(@as(usize, 2), scopes.items.len);
}

test "scope tree appends a fresh each row without searching inactive slots" {
    var scopes: shared_buffer.List(Scope(TestRow)) = .empty;
    defer scopes.deinit(std.testing.allocator);

    const root = (try internRoot(TestRow, std.testing.allocator, &scopes)).scope_id;
    const first = (try appendEachRow(TestRow, std.testing.allocator, &scopes, root, .{ .site_ordinal = SiteOrdinal.fromRaw(8), .value = 10 }, semantic_ids.initial_generation)).scope_id;
    scopes.items[first.index()].lifecycle = .{ .retired = Generation.fromRaw(1) };

    const fresh = try appendFreshEachRow(TestRow, std.testing.allocator, &scopes, root, .{ .site_ordinal = SiteOrdinal.fromRaw(8), .value = 20 });
    try std.testing.expectEqual(ScopeId.fromRaw(2), fresh.scope_id);
    try std.testing.expectEqual(@as(usize, 3), scopes.items.len);
}

test "scope tree reuses inactive component and branch slots" {
    var scopes: shared_buffer.List(Scope(TestRow)) = .empty;
    defer scopes.deinit(std.testing.allocator);

    const root = (try internRoot(TestRow, std.testing.allocator, &scopes)).scope_id;
    const component = (try internComponent(TestRow, std.testing.allocator, &scopes, root, SiteOrdinal.fromRaw(1), semantic_ids.initial_generation)).scope_id;
    const branch = (try internWhenBranch(TestRow, std.testing.allocator, &scopes, root, SiteOrdinal.fromRaw(2), .true_branch, semantic_ids.initial_generation)).scope_id;

    scopes.items[component.index()].lifecycle = .{ .retired = Generation.fromRaw(1) };
    const reused_component = try internComponent(TestRow, std.testing.allocator, &scopes, root, SiteOrdinal.fromRaw(3), semantic_ids.initial_generation);
    try std.testing.expect(reused_component.created);
    try std.testing.expectEqual(component, reused_component.scope_id);

    scopes.items[branch.index()].lifecycle = .{ .retired = Generation.fromRaw(1) };
    const reused_branch = try internWhenBranch(TestRow, std.testing.allocator, &scopes, root, SiteOrdinal.fromRaw(4), .false_branch, semantic_ids.initial_generation);
    try std.testing.expect(reused_branch.created);
    try std.testing.expectEqual(branch, reused_branch.scope_id);
    try std.testing.expectEqual(@as(usize, 3), scopes.items.len);
}

test "scope ids retired in a dirty generation are not reused until the next one" {
    var scopes: shared_buffer.List(Scope(TestRow)) = .empty;
    defer scopes.deinit(std.testing.allocator);

    const root = (try internRoot(TestRow, std.testing.allocator, &scopes)).scope_id;
    const first = (try internComponent(TestRow, std.testing.allocator, &scopes, root, SiteOrdinal.fromRaw(1), semantic_ids.initial_generation)).scope_id;

    scopes.items[first.index()].lifecycle = .{ .retired = Generation.fromRaw(5) };

    const during_flush = try internComponent(TestRow, std.testing.allocator, &scopes, root, SiteOrdinal.fromRaw(2), Generation.fromRaw(5));
    try std.testing.expect(during_flush.scope_id != first);

    scopes.items[during_flush.scope_id.index()].lifecycle = .{ .retired = Generation.fromRaw(5) };
    const next_flush = try internComponent(TestRow, std.testing.allocator, &scopes, root, SiteOrdinal.fromRaw(3), Generation.fromRaw(6));
    try std.testing.expectEqual(first, next_flush.scope_id);
}

test "retirement links slots into the reusable ring and republication unlinks them" {
    var scopes: shared_buffer.List(Scope(TestRow)) = .empty;
    defer scopes.deinit(std.testing.allocator);

    const root = (try internRoot(TestRow, std.testing.allocator, &scopes)).scope_id;
    try std.testing.expectEqual(@as(?ScopeId, null), firstReusableScope(TestRow, scopes.items));
    const a = (try internComponent(TestRow, std.testing.allocator, &scopes, root, SiteOrdinal.fromRaw(1), semantic_ids.initial_generation)).scope_id;
    const b = (try internComponent(TestRow, std.testing.allocator, &scopes, root, SiteOrdinal.fromRaw(2), semantic_ids.initial_generation)).scope_id;
    const c = (try internComponent(TestRow, std.testing.allocator, &scopes, root, SiteOrdinal.fromRaw(3), semantic_ids.initial_generation)).scope_id;

    retireScopeAssumeValid(TestRow, scopes.items, b, Generation.fromRaw(1));
    retireScopeAssumeValid(TestRow, scopes.items, c, Generation.fromRaw(1));
    retireScopeAssumeValid(TestRow, scopes.items, a, Generation.fromRaw(1));
    try std.testing.expectEqual(@as(?ScopeId, b), firstReusableScope(TestRow, scopes.items));
    try std.testing.expectEqual(@as(?ScopeId, c), nextReusableScope(TestRow, scopes.items, b));
    try std.testing.expectEqual(@as(?ScopeId, a), nextReusableScope(TestRow, scopes.items, c));
    try std.testing.expectEqual(@as(?ScopeId, null), nextReusableScope(TestRow, scopes.items, a));

    // A scan-selected reuse (lowest index first) unlinks from the tail of the ring.
    const reused = try internComponent(TestRow, std.testing.allocator, &scopes, root, SiteOrdinal.fromRaw(4), Generation.fromRaw(2));
    try std.testing.expectEqual(a, reused.scope_id);
    try std.testing.expect(!isLinkedReusable(TestRow, scopes.items, a));
    try std.testing.expectEqual(@as(?ScopeId, b), firstReusableScope(TestRow, scopes.items));
    try std.testing.expectEqual(@as(?ScopeId, c), nextReusableScope(TestRow, scopes.items, b));
    try std.testing.expectEqual(@as(?ScopeId, null), nextReusableScope(TestRow, scopes.items, c));

    // Head removals keep the sentinel consistent, and a re-retired slot re-enters exactly once.
    _ = try internComponent(TestRow, std.testing.allocator, &scopes, root, SiteOrdinal.fromRaw(5), Generation.fromRaw(2));
    try std.testing.expectEqual(@as(?ScopeId, c), firstReusableScope(TestRow, scopes.items));
    _ = try internComponent(TestRow, std.testing.allocator, &scopes, root, SiteOrdinal.fromRaw(6), Generation.fromRaw(2));
    try std.testing.expectEqual(@as(?ScopeId, null), firstReusableScope(TestRow, scopes.items));
    try std.testing.expectEqual(@as(?ScopeId, null), scopes.items[root.index()].previous_reusable_scope_id);
    retireScopeAssumeValid(TestRow, scopes.items, a, Generation.fromRaw(2));
    try std.testing.expectEqual(@as(?ScopeId, a), firstReusableScope(TestRow, scopes.items));
    try std.testing.expectEqual(@as(?ScopeId, null), nextReusableScope(TestRow, scopes.items, a));

    // A slot retired by direct lifecycle assignment is not linked and may still be republished.
    scopes.items[b.index()].lifecycle = .{ .retired = Generation.fromRaw(2) };
    try std.testing.expect(!isLinkedReusable(TestRow, scopes.items, b));
    const direct = try internComponent(TestRow, std.testing.allocator, &scopes, root, SiteOrdinal.fromRaw(7), Generation.fromRaw(3));
    try std.testing.expectEqual(a, direct.scope_id);
    try std.testing.expectEqual(@as(?ScopeId, null), firstReusableScope(TestRow, scopes.items));
}
