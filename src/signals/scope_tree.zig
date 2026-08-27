//! Scope forest primitives for component, branch, and keyed row lifetimes.

const std = @import("std");

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
    site_ordinal: u64,
};

pub const WhenBranchStep = struct {
    site_ordinal: u64,
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
        scope_id: u64,
        parent_scope_id: ?u64,
        step: Step(Row),
        active: bool,
        retired_at: u64 = 0,
    };
}

pub const InternResult = struct {
    scope_id: u64,
    created: bool,
};

/// Rejects malformed boundary data before it can enter committed engine state.
pub fn validate(comptime Row: type, scopes: []const Scope(Row), scope_id: u64) Error!void {
    if (scope_id >= scopes.len) return Error.UnknownScope;
    const scope = scopes[@intCast(scope_id)];
    if (scope.scope_id != scope_id) return Error.UnknownScope;
    if (!scope.active) return Error.InactiveScope;
}

/// Creates or reuses root scope identity beneath its explicit owner.
pub fn internRoot(comptime Row: type, allocator: std.mem.Allocator, scopes: *std.ArrayListUnmanaged(Scope(Row))) Error!InternResult {
    if (scopes.items.len == 0) {
        scopes.append(allocator, .{
            .scope_id = 0,
            .parent_scope_id = null,
            .step = .root,
            .active = true,
        }) catch return Error.OutOfMemory;
        return .{ .scope_id = 0, .created = true };
    }

    const root = scopes.items[0];
    if (root.scope_id != 0 or root.parent_scope_id != null or root.step != .root or !root.active) {
        return Error.InvalidRoot;
    }
    return .{ .scope_id = 0, .created = false };
}

/// Creates or reuses component scope identity beneath its explicit owner.
pub fn internComponent(comptime Row: type, allocator: std.mem.Allocator, scopes: *std.ArrayListUnmanaged(Scope(Row)), parent_scope_id: u64, site_ordinal: u64, reuse_barrier: u64) Error!InternResult {
    try validate(Row, scopes.items, parent_scope_id);

    for (scopes.items) |scope| {
        if (!scope.active) continue;
        if (scope.parent_scope_id != parent_scope_id) continue;
        switch (scope.step) {
            .component => |step| {
                if (step.site_ordinal == site_ordinal) {
                    return .{ .scope_id = scope.scope_id, .created = false };
                }
            },
            .root, .when_branch, .each_row => {},
        }
    }

    for (scopes.items) |*scope| {
        if (scope.active) continue;
        if (scope.retired_at != 0 and scope.retired_at == reuse_barrier) continue;
        scope.parent_scope_id = parent_scope_id;
        scope.step = .{ .component = .{ .site_ordinal = site_ordinal } };
        scope.active = true;
        return .{ .scope_id = scope.scope_id, .created = true };
    }

    const scope_id: u64 = @intCast(scopes.items.len);
    scopes.append(allocator, .{
        .scope_id = scope_id,
        .parent_scope_id = parent_scope_id,
        .step = .{ .component = .{ .site_ordinal = site_ordinal } },
        .active = true,
    }) catch return Error.OutOfMemory;
    return .{ .scope_id = scope_id, .created = true };
}

/// Creates or reuses when branch scope identity beneath its explicit owner.
pub fn internWhenBranch(comptime Row: type, allocator: std.mem.Allocator, scopes: *std.ArrayListUnmanaged(Scope(Row)), parent_scope_id: u64, site_ordinal: u64, branch: Branch, reuse_barrier: u64) Error!InternResult {
    try validate(Row, scopes.items, parent_scope_id);

    for (scopes.items) |scope| {
        if (!scope.active) continue;
        if (scope.parent_scope_id != parent_scope_id) continue;
        switch (scope.step) {
            .when_branch => |step| {
                if (step.site_ordinal == site_ordinal and step.branch == branch) {
                    return .{ .scope_id = scope.scope_id, .created = false };
                }
            },
            .root, .component, .each_row => {},
        }
    }

    for (scopes.items) |*scope| {
        if (scope.active) continue;
        if (scope.retired_at != 0 and scope.retired_at == reuse_barrier) continue;
        scope.parent_scope_id = parent_scope_id;
        scope.step = .{ .when_branch = .{ .site_ordinal = site_ordinal, .branch = branch } };
        scope.active = true;
        return .{ .scope_id = scope.scope_id, .created = true };
    }

    const scope_id: u64 = @intCast(scopes.items.len);
    scopes.append(allocator, .{
        .scope_id = scope_id,
        .parent_scope_id = parent_scope_id,
        .step = .{ .when_branch = .{ .site_ordinal = site_ordinal, .branch = branch } },
        .active = true,
    }) catch return Error.OutOfMemory;
    return .{ .scope_id = scope_id, .created = true };
}

/// Appends each row using capacity that must already satisfy the caller's transaction contract.
pub fn appendEachRow(comptime Row: type, allocator: std.mem.Allocator, scopes: *std.ArrayListUnmanaged(Scope(Row)), parent_scope_id: u64, row: Row, reuse_barrier: u64) Error!InternResult {
    try validate(Row, scopes.items, parent_scope_id);

    for (scopes.items) |*scope| {
        if (scope.active) continue;
        if (scope.retired_at != 0 and scope.retired_at == reuse_barrier) continue;
        scope.parent_scope_id = parent_scope_id;
        scope.step = .{ .each_row = row };
        scope.active = true;
        return .{ .scope_id = scope.scope_id, .created = true };
    }

    return appendFreshEachRow(Row, allocator, scopes, parent_scope_id, row);
}

/// Appends fresh each row using capacity that must already satisfy the caller's transaction contract.
pub fn appendFreshEachRow(comptime Row: type, allocator: std.mem.Allocator, scopes: *std.ArrayListUnmanaged(Scope(Row)), parent_scope_id: u64, row: Row) Error!InternResult {
    try validate(Row, scopes.items, parent_scope_id);
    const scope_id: u64 = @intCast(scopes.items.len);
    scopes.append(allocator, .{
        .scope_id = scope_id,
        .parent_scope_id = parent_scope_id,
        .step = .{ .each_row = row },
        .active = true,
    }) catch return Error.OutOfMemory;
    return .{ .scope_id = scope_id, .created = true };
}

/// Returns active when branch from the maintained active-runtime indexes.
pub fn activeWhenBranch(comptime Row: type, scopes: []const Scope(Row), parent_scope_id: u64, site_ordinal: u64, branch: Branch) Error!?u64 {
    try validate(Row, scopes, parent_scope_id);

    for (scopes) |scope| {
        if (!scope.active) continue;
        if (scope.parent_scope_id != parent_scope_id) continue;
        switch (scope.step) {
            .when_branch => |step| {
                if (step.site_ordinal == site_ordinal and step.branch == branch) return scope.scope_id;
            },
            .root, .component, .each_row => {},
        }
    }
    return null;
}

/// Returns active each rows from the maintained active-runtime indexes.
pub fn activeEachRows(comptime Row: type, allocator: std.mem.Allocator, scopes: []const Scope(Row), parent_scope_id: u64, site_ordinal: u64) Error![]u64 {
    var ids: std.ArrayListUnmanaged(u64) = .empty;
    errdefer ids.deinit(allocator);

    for (scopes) |scope| {
        if (!scope.active) continue;
        if (scope.parent_scope_id != parent_scope_id) continue;
        switch (scope.step) {
            .each_row => |row| {
                if (row.site_ordinal == site_ordinal) {
                    ids.append(allocator, scope.scope_id) catch return Error.OutOfMemory;
                }
            },
            .root, .component, .when_branch => {},
        }
    }

    return ids.toOwnedSlice(allocator) catch return Error.OutOfMemory;
}

/// Tests explicit scope ancestry without consulting rendered DOM structure.
pub fn eachSiteRowAncestor(comptime Row: type, scopes: []const Scope(Row), scope_id: u64, parent_scope_id: u64, site_ordinal: u64) Error!?u64 {
    var current: ?u64 = scope_id;
    while (current) |id| {
        if (id >= scopes.len) return Error.UnknownScope;
        const scope = scopes[@intCast(id)];
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
pub fn descendantOrSelf(comptime Row: type, scopes: []const Scope(Row), scope_id: u64, root_scope_id: u64) Error!bool {
    var current: ?u64 = scope_id;
    while (current) |id| {
        if (id == root_scope_id) return true;
        if (id >= scopes.len) return Error.UnknownScope;
        current = scopes[@intCast(id)].parent_scope_id;
    }
    return false;
}

/// Tests whether a scope is the selected keyed row or one of its explicitly owned descendants.
pub fn eachSiteRowDescendantOrSelf(comptime Row: type, scopes: []const Scope(Row), scope_id: u64, parent_scope_id: u64, site_ordinal: u64) Error!bool {
    return (try eachSiteRowAncestor(Row, scopes, scope_id, parent_scope_id, site_ordinal)) != null;
}

const TestRow = struct {
    site_ordinal: u64,
    value: u64,
};

test "scope tree interns root component and branch scopes" {
    var scopes: std.ArrayListUnmanaged(Scope(TestRow)) = .empty;
    defer scopes.deinit(std.testing.allocator);

    const root = try internRoot(TestRow, std.testing.allocator, &scopes);
    try std.testing.expectEqual(@as(u64, 0), root.scope_id);
    try std.testing.expect(root.created);

    const same_root = try internRoot(TestRow, std.testing.allocator, &scopes);
    try std.testing.expectEqual(@as(u64, 0), same_root.scope_id);
    try std.testing.expect(!same_root.created);

    const component = try internComponent(TestRow, std.testing.allocator, &scopes, root.scope_id, 4, 0);
    try std.testing.expect(component.created);
    const same_component = try internComponent(TestRow, std.testing.allocator, &scopes, root.scope_id, 4, 0);
    try std.testing.expectEqual(component.scope_id, same_component.scope_id);
    try std.testing.expect(!same_component.created);

    const false_branch = try internWhenBranch(TestRow, std.testing.allocator, &scopes, root.scope_id, 5, .false_branch, 0);
    const true_branch = try internWhenBranch(TestRow, std.testing.allocator, &scopes, root.scope_id, 5, .true_branch, 0);
    try std.testing.expect(false_branch.scope_id != true_branch.scope_id);
    try std.testing.expectEqual(false_branch.scope_id, (try activeWhenBranch(TestRow, scopes.items, root.scope_id, 5, .false_branch)).?);
    try std.testing.expectEqual(true_branch.scope_id, (try activeWhenBranch(TestRow, scopes.items, root.scope_id, 5, .true_branch)).?);
    try std.testing.expectEqual(Branch.true_branch, Branch.false_branch.opposite());
}

test "scope tree finds each rows and ancestry" {
    var scopes: std.ArrayListUnmanaged(Scope(TestRow)) = .empty;
    defer scopes.deinit(std.testing.allocator);

    const root = (try internRoot(TestRow, std.testing.allocator, &scopes)).scope_id;
    const row_a = (try appendEachRow(TestRow, std.testing.allocator, &scopes, root, .{ .site_ordinal = 8, .value = 10 }, 0)).scope_id;
    const row_b = (try appendEachRow(TestRow, std.testing.allocator, &scopes, root, .{ .site_ordinal = 8, .value = 20 }, 0)).scope_id;
    const nested_component = (try internComponent(TestRow, std.testing.allocator, &scopes, row_b, 1, 0)).scope_id;
    _ = try appendEachRow(TestRow, std.testing.allocator, &scopes, root, .{ .site_ordinal = 9, .value = 30 }, 0);

    const rows = try activeEachRows(TestRow, std.testing.allocator, scopes.items, root, 8);
    defer std.testing.allocator.free(rows);
    try std.testing.expectEqualSlices(u64, &.{ row_a, row_b }, rows);
    try std.testing.expectEqual(row_b, (try eachSiteRowAncestor(TestRow, scopes.items, nested_component, root, 8)).?);
    try std.testing.expect(try descendantOrSelf(TestRow, scopes.items, nested_component, row_b));
    try std.testing.expect(!try descendantOrSelf(TestRow, scopes.items, row_a, row_b));
    try std.testing.expect(try eachSiteRowDescendantOrSelf(TestRow, scopes.items, nested_component, root, 8));
}

test "scope tree reuses inactive each row slots" {
    var scopes: std.ArrayListUnmanaged(Scope(TestRow)) = .empty;
    defer scopes.deinit(std.testing.allocator);

    const root = (try internRoot(TestRow, std.testing.allocator, &scopes)).scope_id;
    const first = (try appendEachRow(TestRow, std.testing.allocator, &scopes, root, .{ .site_ordinal = 8, .value = 10 }, 0)).scope_id;
    scopes.items[@intCast(first)].active = false;

    const reused = try appendEachRow(TestRow, std.testing.allocator, &scopes, root, .{ .site_ordinal = 8, .value = 20 }, 0);
    try std.testing.expect(reused.created);
    try std.testing.expectEqual(first, reused.scope_id);
    try std.testing.expectEqual(@as(usize, 2), scopes.items.len);
}

test "scope tree appends a fresh each row without searching inactive slots" {
    var scopes: std.ArrayListUnmanaged(Scope(TestRow)) = .empty;
    defer scopes.deinit(std.testing.allocator);

    const root = (try internRoot(TestRow, std.testing.allocator, &scopes)).scope_id;
    const first = (try appendEachRow(TestRow, std.testing.allocator, &scopes, root, .{ .site_ordinal = 8, .value = 10 }, 0)).scope_id;
    scopes.items[@intCast(first)].active = false;

    const fresh = try appendFreshEachRow(TestRow, std.testing.allocator, &scopes, root, .{ .site_ordinal = 8, .value = 20 });
    try std.testing.expectEqual(@as(u64, 2), fresh.scope_id);
    try std.testing.expectEqual(@as(usize, 3), scopes.items.len);
}

test "scope tree reuses inactive component and branch slots" {
    var scopes: std.ArrayListUnmanaged(Scope(TestRow)) = .empty;
    defer scopes.deinit(std.testing.allocator);

    const root = (try internRoot(TestRow, std.testing.allocator, &scopes)).scope_id;
    const component = (try internComponent(TestRow, std.testing.allocator, &scopes, root, 1, 0)).scope_id;
    const branch = (try internWhenBranch(TestRow, std.testing.allocator, &scopes, root, 2, .true_branch, 0)).scope_id;

    scopes.items[@intCast(component)].active = false;
    const reused_component = try internComponent(TestRow, std.testing.allocator, &scopes, root, 3, 0);
    try std.testing.expect(reused_component.created);
    try std.testing.expectEqual(component, reused_component.scope_id);

    scopes.items[@intCast(branch)].active = false;
    const reused_branch = try internWhenBranch(TestRow, std.testing.allocator, &scopes, root, 4, .false_branch, 0);
    try std.testing.expect(reused_branch.created);
    try std.testing.expectEqual(branch, reused_branch.scope_id);
    try std.testing.expectEqual(@as(usize, 3), scopes.items.len);
}

test "scope ids retired in a dirty generation are not reused until the next one" {
    var scopes: std.ArrayListUnmanaged(Scope(TestRow)) = .empty;
    defer scopes.deinit(std.testing.allocator);

    const root = (try internRoot(TestRow, std.testing.allocator, &scopes)).scope_id;
    const first = (try internComponent(TestRow, std.testing.allocator, &scopes, root, 1, 0)).scope_id;

    scopes.items[@intCast(first)].active = false;
    scopes.items[@intCast(first)].retired_at = 5;

    const during_flush = try internComponent(TestRow, std.testing.allocator, &scopes, root, 2, 5);
    try std.testing.expect(during_flush.scope_id != first);

    scopes.items[@intCast(during_flush.scope_id)].active = false;
    const next_flush = try internComponent(TestRow, std.testing.allocator, &scopes, root, 3, 6);
    try std.testing.expectEqual(first, next_flush.scope_id);
}
