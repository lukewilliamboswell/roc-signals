//! Runtime-owned scope payloads for state binders and keyed rows.

const std = @import("std");
const semantic_ids = @import("ids.zig");
const row_handles = @import("row_handles.zig");
const scope_tree = @import("scope_tree.zig");

/// Per-row scope metadata. Item and key values belong to the site's immutable
/// collection generation; the scope retains only the stable row handle needed
/// to resolve that generation for its complete lifetime.
pub const EachRowScopeStep = struct {
    site_ordinal: semantic_ids.SiteOrdinal,
    key_hash: u64,
    row_handle: row_handles.RowHandleId,
};

pub const ScopeStep = scope_tree.Step(EachRowScopeStep);
pub const Scope = scope_tree.Scope(EachRowScopeStep);

pub const EachSite = struct {
    parent_scope_id: semantic_ids.ScopeId,
    site_ordinal: semantic_ids.SiteOrdinal,
};

const ClaimsPhase = enum {
    preparing,
    committed,

    fn isCommitted(self: ClaimsPhase) bool {
        return self == .committed;
    }
};

/// Provisional each-row scopes whose stable handles remain private until an
/// enclosing structural transaction publishes them.
pub const PreparedScopeClaims = struct {
    allocator: std.mem.Allocator,
    original_scope_len: usize,
    rows: std.ArrayListUnmanaged(Scope) = .empty,
    inactive_scope_ids: std.ArrayListUnmanaged(semantic_ids.ScopeId) = .empty,
    inactive_cursor: usize = 0,
    candidates_prepared: bool = false,
    new_scope_count: usize = 0,
    phase: ClaimsPhase = .preparing,

    /// Starts an empty overlay over the current persistent scope table.
    pub fn init(allocator: std.mem.Allocator, scopes: []const Scope) PreparedScopeClaims {
        return .{ .allocator = allocator, .original_scope_len = scopes.len };
    }

    /// Claims one provisional row and cumulatively reserves its final scope slot.
    pub fn prepareRow(self: *PreparedEachRowScopes, scopes: *std.ArrayListUnmanaged(Scope), parent_scope_id: semantic_ids.ScopeId, site_ordinal: semantic_ids.SiteOrdinal, key_hash: u64, row_handle: row_handles.RowHandleId) (std.mem.Allocator.Error || error{ResourceLimit})!semantic_ids.ScopeId {
        if (self.phase.isCommitted() or scopes.items.len != self.original_scope_len) @panic("invalid provisional each-row scope state");
        scope_tree.validate(EachRowScopeStep, scopes.items, parent_scope_id) catch @panic("scope id has no host scope descriptor");
        if (!self.candidates_prepared) {
            try self.inactive_scope_ids.ensureTotalCapacity(self.allocator, scopes.items.len);
            for (scopes.items) |scope| if (!scope.lifecycle.isActive()) self.inactive_scope_ids.appendAssumeCapacity(scope.scope_id);
            self.candidates_prepared = true;
        }
        const reuses_inactive = self.inactive_cursor < self.inactive_scope_ids.items.len;
        const scope_id: semantic_ids.ScopeId = if (reuses_inactive)
            self.inactive_scope_ids.items[self.inactive_cursor]
        else
            semantic_ids.ScopeId.fromIndex(std.math.add(usize, self.original_scope_len, self.new_scope_count) catch return error.ResourceLimit);
        if (!reuses_inactive) {
            const next_len = std.math.add(usize, scope_id.index(), 1) catch return error.ResourceLimit;
            try scopes.ensureTotalCapacity(self.allocator, next_len);
        }
        try self.rows.ensureUnusedCapacity(self.allocator, 1);

        self.rows.appendAssumeCapacity(.{
            .scope_id = scope_id,
            .parent_scope_id = parent_scope_id,
            .step = .{ .each_row = .{
                .site_ordinal = site_ordinal,
                .key_hash = key_hash,
                .row_handle = row_handle,
            } },
            .lifecycle = .active,
        });
        if (reuses_inactive) self.inactive_cursor += 1 else self.new_scope_count += 1;
        return scope_id;
    }

    /// Publishes all provisional rows without allocation.
    pub fn commit(self: *PreparedEachRowScopes, scopes: *std.ArrayListUnmanaged(Scope)) void {
        if (self.phase.isCommitted() or scopes.items.len != self.original_scope_len) @panic("invalid provisional each-row scope commit");
        for (self.rows.items) |scope| {
            const index = scope.scope_id.index();
            if (index < self.original_scope_len) {
                if (scopes.items[index].lifecycle.isActive()) @panic("provisional each-row scope reused an active slot");
                scopes.items[index] = scope;
            } else {
                if (index != scopes.items.len) @panic("provisional each-row scope suffix was not contiguous");
                scopes.appendAssumeCapacity(scope);
            }
        }
        self.rows.clearRetainingCapacity();
        self.inactive_cursor = 0;
        self.new_scope_count = 0;
        self.phase = .committed;
    }

    /// Abandons provisional scope claims without retiring their row handles.
    /// The enclosing generation plan remains the handle owner until commit.
    pub fn abort(self: *PreparedEachRowScopes) void {
        if (self.phase.isCommitted()) return;
        self.rows.clearRetainingCapacity();
        self.inactive_cursor = 0;
        self.new_scope_count = 0;
    }

    /// Releases overlay storage; callers must abort or commit first.
    pub fn deinit(self: *PreparedEachRowScopes) void {
        if (self.rows.items.len != 0) @panic("provisional each-row scope claims were not resolved");
        self.rows.deinit(self.allocator);
        self.inactive_scope_ids.deinit(self.allocator);
        self.* = undefined;
    }
};

/// Compatibility name for callers that only claim keyed-row scopes.
pub const PreparedEachRowScopes = PreparedScopeClaims;

/// Scope steps own no Roc values. Row-handle retirement belongs to the scope
/// disposal hook so the generation and row-source registries update together.
pub fn deinitScopeStep(step: *ScopeStep) void {
    _ = step;
}

/// Appends each row using capacity that must already satisfy the caller's transaction contract.
pub fn appendEachRow(allocator: std.mem.Allocator, scopes: *std.ArrayListUnmanaged(Scope), parent_scope_id: semantic_ids.ScopeId, site_ordinal: semantic_ids.SiteOrdinal, key_hash: u64, row_handle: row_handles.RowHandleId, reuse_barrier: scope_tree.Generation) scope_tree.Error!scope_tree.InternResult {
    try scope_tree.validate(EachRowScopeStep, scopes.items, parent_scope_id);

    return scope_tree.appendEachRow(EachRowScopeStep, allocator, scopes, parent_scope_id, .{
        .site_ordinal = site_ordinal,
        .key_hash = key_hash,
        .row_handle = row_handle,
    }, reuse_barrier);
}

/// Appends fresh each row using capacity that must already satisfy the caller's transaction contract.
pub fn appendFreshEachRow(allocator: std.mem.Allocator, scopes: *std.ArrayListUnmanaged(Scope), parent_scope_id: semantic_ids.ScopeId, site_ordinal: semantic_ids.SiteOrdinal, key_hash: u64, row_handle: row_handles.RowHandleId) scope_tree.Error!scope_tree.InternResult {
    try scope_tree.validate(EachRowScopeStep, scopes.items, parent_scope_id);

    return scope_tree.appendFreshEachRow(EachRowScopeStep, allocator, scopes, parent_scope_id, .{
        .site_ordinal = site_ordinal,
        .key_hash = key_hash,
        .row_handle = row_handle,
    });
}

/// Returns  from the keyed row selected by dense scope identity.
pub fn eachRow(scopes: []Scope, scope_id: semantic_ids.ScopeId) *EachRowScopeStep {
    scope_tree.validate(EachRowScopeStep, scopes, scope_id) catch @panic("scope id has no host scope descriptor");
    const scope = &scopes[scope_id.index()];
    return switch (scope.step) {
        .each_row => |*row| row,
        .root, .component, .when_branch => @panic("scope id does not reference an each-row scope"),
    };
}

/// Returns const from the keyed row selected by dense scope identity.
pub fn eachRowConst(scopes: []const Scope, scope_id: semantic_ids.ScopeId) *const EachRowScopeStep {
    scope_tree.validate(EachRowScopeStep, scopes, scope_id) catch @panic("scope id has no host scope descriptor");
    const scope = &scopes[scope_id.index()];
    return switch (scope.step) {
        .each_row => |*row| row,
        .root, .component, .when_branch => @panic("scope id does not reference an each-row scope"),
    };
}

/// Returns key hash from the keyed row selected by dense scope identity.
pub fn eachRowKeyHash(scopes: []const Scope, scope_id: semantic_ids.ScopeId) u64 {
    return eachRowConst(scopes, scope_id).key_hash;
}

/// Returns the stable handle retained for the keyed row scope lifetime.
pub fn eachRowHandle(scopes: []const Scope, scope_id: semantic_ids.ScopeId) row_handles.RowHandleId {
    return eachRowConst(scopes, scope_id).row_handle;
}

test "shared prepared scope claims assign distinct ids and retry after every OOM" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    const Runner = struct {
        fn run(failure_number: ?usize) !usize {
            var fault = FaultAllocator.init(std.testing.allocator);
            var scopes: std.ArrayListUnmanaged(Scope) = .empty;
            defer scopes.deinit(std.testing.allocator);
            _ = try scope_tree.internRoot(EachRowScopeStep, std.testing.allocator, &scopes);
            var claims = PreparedScopeClaims.init(fault.allocator(), scopes.items);
            defer {
                claims.abort();
                claims.deinit();
            }

            fault.configure(failure_number);
            const first_handle = row_handles.RowHandleId.fromRaw(0x0000_0001_0000_0001);
            const second_handle = row_handles.RowHandleId.fromRaw(0x0000_0001_0000_0002);
            const first = claims.prepareRow(&scopes, semantic_ids.root_scope, semantic_ids.SiteOrdinal.fromRaw(10), 101, first_handle) catch |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                claims.abort();
                fault.configure(null);
                const retry_first = try claims.prepareRow(&scopes, semantic_ids.root_scope, semantic_ids.SiteOrdinal.fromRaw(10), 101, first_handle);
                const retry_second = try claims.prepareRow(&scopes, semantic_ids.root_scope, semantic_ids.SiteOrdinal.fromRaw(20), 202, second_handle);
                try std.testing.expectEqual(semantic_ids.ScopeId.fromRaw(1), retry_first);
                try std.testing.expectEqual(semantic_ids.ScopeId.fromRaw(2), retry_second);
                try std.testing.expectEqual(@as(usize, 1), scopes.items.len);
                return fault.attempts;
            };
            const second = claims.prepareRow(&scopes, semantic_ids.root_scope, semantic_ids.SiteOrdinal.fromRaw(20), 202, second_handle) catch |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                claims.abort();
                fault.configure(null);
                const retry_first = try claims.prepareRow(&scopes, semantic_ids.root_scope, semantic_ids.SiteOrdinal.fromRaw(10), 101, first_handle);
                const retry_second = try claims.prepareRow(&scopes, semantic_ids.root_scope, semantic_ids.SiteOrdinal.fromRaw(20), 202, second_handle);
                try std.testing.expectEqual(semantic_ids.ScopeId.fromRaw(1), retry_first);
                try std.testing.expectEqual(semantic_ids.ScopeId.fromRaw(2), retry_second);
                try std.testing.expectEqual(@as(usize, 1), scopes.items.len);
                return fault.attempts;
            };
            try std.testing.expect(failure_number == null);
            try std.testing.expectEqual(semantic_ids.ScopeId.fromRaw(1), first);
            try std.testing.expectEqual(semantic_ids.ScopeId.fromRaw(2), second);
            try std.testing.expectEqual(@as(usize, 1), scopes.items.len);
            return fault.attempts;
        }
    };

    const attempts = try Runner.run(null);
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| _ = try Runner.run(failure_number);
}

/// Disposes a scope subtree in post-order, releasing all values, effects, identities, and render ownership.
pub fn disposeSubtree(comptime Row: type, scopes: []scope_tree.Scope(Row), scope_id: semantic_ids.ScopeId, retirement_generation: scope_tree.Generation, hooks: anytype) void {
    if (scope_id.index() >= scopes.len) @panic("scope disposal referenced an unknown scope");
    if (scopes[scope_id.index()].scope_id != scope_id or !scopes[scope_id.index()].lifecycle.isActive()) @panic("scope id has no host scope descriptor");

    var child_index: usize = 0;
    while (child_index < scopes.len) : (child_index += 1) {
        const child = scopes[child_index];
        if (!child.lifecycle.isActive()) continue;
        if (child.parent_scope_id == scope_id) {
            disposeSubtree(Row, scopes, child.scope_id, retirement_generation, hooks);
        }
    }

    hooks.deactivateNodeIdentities(scope_id);
    hooks.appendCleanupEvents(scope_id);
    hooks.cancelPendingTasks(scope_id);
    hooks.deactivateDomIdentities(scope_id);

    const scope = &scopes[scope_id.index()];
    switch (scope.step) {
        .each_row => |row| hooks.removeEachRow(scope.scope_id, row.key_hash, row.row_handle),
        .root, .component, .when_branch => {},
    }
    hooks.deinitScopeStep(&scope.step);
    scope.lifecycle = .{ .retired = retirement_generation };
    hooks.recordScopeDisposed();
}

/// Owns the exact post-order scope ids selected for deferred subtree retirement.
/// Preparation is fallible and read-only; applying metadata is allocation-free
/// and intentionally does not release step-owned resources.
pub const PreparedSubtreeRetirement = struct {
    scope_ids: []semantic_ids.ScopeId,

    /// Releases preparation storage without changing live scopes.
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.scope_ids);
        self.* = undefined;
    }

    /// Marks the prepared subtree inactive after replacement publication.
    pub fn applyMetadata(self: *const @This(), comptime Row: type, scopes: []scope_tree.Scope(Row), retirement_generation: scope_tree.Generation) void {
        for (self.scope_ids) |scope_id| {
            const scope = &scopes[scope_id.index()];
            if (!scope.lifecycle.isActive() or scope.scope_id != scope_id) @panic("prepared scope retirement no longer matched live state");
            scope.lifecycle = .{ .retired = retirement_generation };
        }
    }
};

/// Prepares a stable post-order scope-subtree snapshot without mutating scopes.
pub fn prepareSubtreeRetirement(comptime Row: type, allocator: std.mem.Allocator, scopes: []const scope_tree.Scope(Row), root_scope_id: semantic_ids.ScopeId) std.mem.Allocator.Error!PreparedSubtreeRetirement {
    if (root_scope_id.index() >= scopes.len or scopes[root_scope_id.index()].scope_id != root_scope_id or !scopes[root_scope_id.index()].lifecycle.isActive()) return error.OutOfMemory;
    var ids: std.ArrayListUnmanaged(semantic_ids.ScopeId) = .empty;
    errdefer ids.deinit(allocator);
    try ids.ensureTotalCapacity(allocator, scopes.len);
    try appendSubtreePostOrder(Row, scopes, root_scope_id, &ids);
    return .{ .scope_ids = try ids.toOwnedSlice(allocator) };
}

/// Prepares disjoint scope subtrees as one stable post-order retirement journal.
pub fn prepareSubtreesRetirement(comptime Row: type, allocator: std.mem.Allocator, scopes: []const scope_tree.Scope(Row), root_scope_ids: []const semantic_ids.ScopeId) (std.mem.Allocator.Error || error{OverlappingSubtrees})!PreparedSubtreeRetirement {
    const selected = try allocator.alloc(bool, scopes.len);
    defer allocator.free(selected);
    @memset(selected, false);
    var ids: std.ArrayListUnmanaged(semantic_ids.ScopeId) = .empty;
    errdefer ids.deinit(allocator);
    try ids.ensureTotalCapacity(allocator, scopes.len);
    for (root_scope_ids) |root_scope_id| {
        if (root_scope_id.index() >= scopes.len or scopes[root_scope_id.index()].scope_id != root_scope_id or !scopes[root_scope_id.index()].lifecycle.isActive()) return error.OverlappingSubtrees;
        try appendDisjointSubtreePostOrder(Row, scopes, root_scope_id, selected, &ids);
    }
    return .{ .scope_ids = try ids.toOwnedSlice(allocator) };
}

fn appendDisjointSubtreePostOrder(comptime Row: type, scopes: []const scope_tree.Scope(Row), scope_id: semantic_ids.ScopeId, selected: []bool, ids: *std.ArrayListUnmanaged(semantic_ids.ScopeId)) error{OverlappingSubtrees}!void {
    if (selected[scope_id.index()]) return error.OverlappingSubtrees;
    selected[scope_id.index()] = true;
    for (scopes) |child| {
        if (child.lifecycle.isActive() and child.parent_scope_id != null and child.parent_scope_id.? == scope_id) try appendDisjointSubtreePostOrder(Row, scopes, child.scope_id, selected, ids);
    }
    ids.appendAssumeCapacity(scope_id);
}

fn appendSubtreePostOrder(comptime Row: type, scopes: []const scope_tree.Scope(Row), scope_id: semantic_ids.ScopeId, ids: *std.ArrayListUnmanaged(semantic_ids.ScopeId)) std.mem.Allocator.Error!void {
    for (scopes) |child| {
        if (child.lifecycle.isActive() and child.parent_scope_id != null and child.parent_scope_id.? == scope_id) try appendSubtreePostOrder(Row, scopes, child.scope_id, ids);
    }
    ids.appendAssumeCapacity(scope_id);
}

const TestRow = struct {
    site_ordinal: semantic_ids.SiteOrdinal,
    key_hash: u64,
    row_handle: row_handles.RowHandleId,
};

const TestDisposeHooks = struct {
    node_deactivations: std.ArrayListUnmanaged(semantic_ids.ScopeId) = .empty,
    cleanup_events: std.ArrayListUnmanaged(semantic_ids.ScopeId) = .empty,
    task_cancellations: std.ArrayListUnmanaged(semantic_ids.ScopeId) = .empty,
    dom_deactivations: std.ArrayListUnmanaged(semantic_ids.ScopeId) = .empty,
    removed_rows: std.ArrayListUnmanaged(u64) = .empty,
    removed_handles: std.ArrayListUnmanaged(row_handles.RowHandleId) = .empty,
    deinit_steps: u64 = 0,
    disposed_scopes: u64 = 0,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.node_deactivations.deinit(allocator);
        self.cleanup_events.deinit(allocator);
        self.task_cancellations.deinit(allocator);
        self.dom_deactivations.deinit(allocator);
        self.removed_rows.deinit(allocator);
        self.removed_handles.deinit(allocator);
    }

    /// Retires node identities so disposed scope identity cannot be routed again.
    pub fn deactivateNodeIdentities(self: *@This(), scope_id: semantic_ids.ScopeId) void {
        self.node_deactivations.append(std.testing.allocator, scope_id) catch @panic("out of memory");
    }

    /// Appends cleanup events using capacity that must already satisfy the caller's transaction contract.
    pub fn appendCleanupEvents(self: *@This(), scope_id: semantic_ids.ScopeId) void {
        self.cleanup_events.append(std.testing.allocator, scope_id) catch @panic("out of memory");
    }

    /// Cancels pending tasks and releases its bounded host-retained work.
    pub fn cancelPendingTasks(self: *@This(), scope_id: semantic_ids.ScopeId) void {
        self.task_cancellations.append(std.testing.allocator, scope_id) catch @panic("out of memory");
    }

    /// Retires dom identities so disposed scope identity cannot be routed again.
    pub fn deactivateDomIdentities(self: *@This(), scope_id: semantic_ids.ScopeId) void {
        self.dom_deactivations.append(std.testing.allocator, scope_id) catch @panic("out of memory");
    }

    /// Removes each row and releases the ownership attached to that live entry.
    pub fn removeEachRow(self: *@This(), scope_id: semantic_ids.ScopeId, key_hash: u64, row_handle: row_handles.RowHandleId) void {
        _ = scope_id;
        self.removed_rows.append(std.testing.allocator, key_hash) catch @panic("out of memory");
        self.removed_handles.append(std.testing.allocator, row_handle) catch @panic("out of memory");
    }

    /// Releases scope step and all host registrations or retained values it owns.
    pub fn deinitScopeStep(self: *@This(), step: *scope_tree.Step(TestRow)) void {
        switch (step.*) {
            .each_row, .root, .component, .when_branch => {},
        }
        self.deinit_steps += 1;
    }

    /// Records scope disposed in the metrics or lifecycle state owned by this operation.
    pub fn recordScopeDisposed(self: *@This()) void {
        self.disposed_scopes += 1;
    }
};

test "scope runtime disposes active subtrees through explicit hooks" {
    var scopes: std.ArrayListUnmanaged(scope_tree.Scope(TestRow)) = .empty;
    defer scopes.deinit(std.testing.allocator);

    _ = try scope_tree.internRoot(TestRow, std.testing.allocator, &scopes);
    _ = try scope_tree.internComponent(TestRow, std.testing.allocator, &scopes, semantic_ids.root_scope, semantic_ids.SiteOrdinal.fromRaw(1), semantic_ids.initial_generation);
    const row_handle = row_handles.RowHandleId.fromRaw(0x0000_0001_0000_0001);
    _ = try scope_tree.appendEachRow(TestRow, std.testing.allocator, &scopes, semantic_ids.ScopeId.fromRaw(1), .{ .site_ordinal = semantic_ids.SiteOrdinal.fromRaw(4), .key_hash = 40, .row_handle = row_handle }, semantic_ids.initial_generation);
    _ = try scope_tree.internComponent(TestRow, std.testing.allocator, &scopes, semantic_ids.ScopeId.fromRaw(2), semantic_ids.SiteOrdinal.fromRaw(1), semantic_ids.initial_generation);
    _ = try scope_tree.internComponent(TestRow, std.testing.allocator, &scopes, semantic_ids.root_scope, semantic_ids.SiteOrdinal.fromRaw(2), semantic_ids.initial_generation);

    var hooks = TestDisposeHooks{};
    defer hooks.deinit(std.testing.allocator);
    disposeSubtree(TestRow, scopes.items, semantic_ids.ScopeId.fromRaw(1), semantic_ids.Generation.fromRaw(5), &hooks);

    try std.testing.expect(scopes.items[0].lifecycle.isActive());
    try std.testing.expect(!scopes.items[1].lifecycle.isActive());
    try std.testing.expect(!scopes.items[2].lifecycle.isActive());
    try std.testing.expect(!scopes.items[3].lifecycle.isActive());
    try std.testing.expect(scopes.items[4].lifecycle.isActive());
    try std.testing.expectEqual(semantic_ids.Generation.fromRaw(5), scopes.items[1].lifecycle.retiredGeneration().?);
    try std.testing.expectEqual(semantic_ids.Generation.fromRaw(5), scopes.items[2].lifecycle.retiredGeneration().?);
    try std.testing.expectEqual(semantic_ids.Generation.fromRaw(5), scopes.items[3].lifecycle.retiredGeneration().?);
    try std.testing.expectEqualSlices(semantic_ids.ScopeId, &.{ semantic_ids.ScopeId.fromRaw(3), semantic_ids.ScopeId.fromRaw(2), semantic_ids.ScopeId.fromRaw(1) }, hooks.node_deactivations.items);
    try std.testing.expectEqualSlices(u64, &.{40}, hooks.removed_rows.items);
    try std.testing.expectEqualSlices(row_handles.RowHandleId, &.{row_handle}, hooks.removed_handles.items);
    try std.testing.expectEqual(@as(u64, 3), hooks.deinit_steps);
    try std.testing.expectEqual(@as(u64, 3), hooks.disposed_scopes);
}

test "prepared scope retirement sweeps allocation failures and applies without allocation" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var scopes: std.ArrayListUnmanaged(scope_tree.Scope(TestRow)) = .empty;
    defer scopes.deinit(std.testing.allocator);
    _ = try scope_tree.internRoot(TestRow, std.testing.allocator, &scopes);
    _ = try scope_tree.internComponent(TestRow, std.testing.allocator, &scopes, semantic_ids.root_scope, semantic_ids.SiteOrdinal.fromRaw(1), semantic_ids.initial_generation);
    _ = try scope_tree.appendEachRow(TestRow, std.testing.allocator, &scopes, semantic_ids.ScopeId.fromRaw(1), .{ .site_ordinal = semantic_ids.SiteOrdinal.fromRaw(4), .key_hash = 40, .row_handle = row_handles.RowHandleId.fromRaw(0x0000_0001_0000_0001) }, semantic_ids.initial_generation);
    _ = try scope_tree.internComponent(TestRow, std.testing.allocator, &scopes, semantic_ids.ScopeId.fromRaw(2), semantic_ids.SiteOrdinal.fromRaw(1), semantic_ids.initial_generation);
    _ = try scope_tree.internComponent(TestRow, std.testing.allocator, &scopes, semantic_ids.root_scope, semantic_ids.SiteOrdinal.fromRaw(2), semantic_ids.initial_generation);

    var baseline_fault = FaultAllocator.init(std.testing.allocator);
    var baseline = try prepareSubtreeRetirement(TestRow, baseline_fault.allocator(), scopes.items, semantic_ids.ScopeId.fromRaw(1));
    const attempts = baseline_fault.attempts;
    baseline.deinit(baseline_fault.allocator());
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| {
        var fault = FaultAllocator.init(std.testing.allocator);
        fault.configure(failure_number);
        try std.testing.expectError(error.OutOfMemory, prepareSubtreeRetirement(TestRow, fault.allocator(), scopes.items, semantic_ids.ScopeId.fromRaw(1)));
        for (scopes.items) |scope| try std.testing.expect(scope.lifecycle.isActive());
    }

    var fault = FaultAllocator.init(std.testing.allocator);
    var prepared = try prepareSubtreeRetirement(TestRow, fault.allocator(), scopes.items, semantic_ids.ScopeId.fromRaw(1));
    defer prepared.deinit(fault.allocator());
    try std.testing.expectEqualSlices(semantic_ids.ScopeId, &.{ semantic_ids.ScopeId.fromRaw(3), semantic_ids.ScopeId.fromRaw(2), semantic_ids.ScopeId.fromRaw(1) }, prepared.scope_ids);
    fault.configure(1);
    prepared.applyMetadata(TestRow, scopes.items, semantic_ids.Generation.fromRaw(9));
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expect(!scopes.items[1].lifecycle.isActive());
    try std.testing.expect(!scopes.items[2].lifecycle.isActive());
    try std.testing.expect(!scopes.items[3].lifecycle.isActive());
    try std.testing.expect(scopes.items[0].lifecycle.isActive());
    try std.testing.expect(scopes.items[4].lifecycle.isActive());
}

test "prepared disjoint scope retirement unions roots and rejects overlap" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var scopes: std.ArrayListUnmanaged(scope_tree.Scope(TestRow)) = .empty;
    defer scopes.deinit(std.testing.allocator);
    _ = try scope_tree.internRoot(TestRow, std.testing.allocator, &scopes);
    _ = try scope_tree.internComponent(TestRow, std.testing.allocator, &scopes, semantic_ids.root_scope, semantic_ids.SiteOrdinal.fromRaw(1), semantic_ids.initial_generation);
    _ = try scope_tree.appendEachRow(TestRow, std.testing.allocator, &scopes, semantic_ids.ScopeId.fromRaw(1), .{ .site_ordinal = semantic_ids.SiteOrdinal.fromRaw(4), .key_hash = 40, .row_handle = row_handles.RowHandleId.fromRaw(0x0000_0001_0000_0001) }, semantic_ids.initial_generation);
    _ = try scope_tree.internComponent(TestRow, std.testing.allocator, &scopes, semantic_ids.ScopeId.fromRaw(2), semantic_ids.SiteOrdinal.fromRaw(1), semantic_ids.initial_generation);
    _ = try scope_tree.internComponent(TestRow, std.testing.allocator, &scopes, semantic_ids.root_scope, semantic_ids.SiteOrdinal.fromRaw(2), semantic_ids.initial_generation);

    var counter = FaultAllocator.init(std.testing.allocator);
    var successful = try prepareSubtreesRetirement(TestRow, counter.allocator(), scopes.items, &.{ semantic_ids.ScopeId.fromRaw(1), semantic_ids.ScopeId.fromRaw(4) });
    const attempts = counter.attempts;
    try std.testing.expect(attempts != 0);
    try std.testing.expectEqualSlices(semantic_ids.ScopeId, &.{ semantic_ids.ScopeId.fromRaw(3), semantic_ids.ScopeId.fromRaw(2), semantic_ids.ScopeId.fromRaw(1), semantic_ids.ScopeId.fromRaw(4) }, successful.scope_ids);
    successful.deinit(counter.allocator());

    for (1..attempts + 1) |failure_number| {
        var fault = FaultAllocator.init(std.testing.allocator);
        fault.configure(failure_number);
        try std.testing.expectError(error.OutOfMemory, prepareSubtreesRetirement(TestRow, fault.allocator(), scopes.items, &.{ semantic_ids.ScopeId.fromRaw(1), semantic_ids.ScopeId.fromRaw(4) }));
        for (scopes.items) |scope| try std.testing.expect(scope.lifecycle.isActive());
        fault.configure(null);
        var retry = try prepareSubtreesRetirement(TestRow, fault.allocator(), scopes.items, &.{ semantic_ids.ScopeId.fromRaw(1), semantic_ids.ScopeId.fromRaw(4) });
        retry.deinit(fault.allocator());
    }

    try std.testing.expectError(error.OverlappingSubtrees, prepareSubtreesRetirement(TestRow, std.testing.allocator, scopes.items, &.{ semantic_ids.ScopeId.fromRaw(1), semantic_ids.ScopeId.fromRaw(2) }));
    for (scopes.items) |scope| try std.testing.expect(scope.lifecycle.isActive());
}

test "scope runtime owns stable each-row handle and key hash" {
    var scopes: std.ArrayListUnmanaged(Scope) = .empty;
    defer scopes.deinit(std.testing.allocator);

    _ = try scope_tree.internRoot(EachRowScopeStep, std.testing.allocator, &scopes);

    const handle = row_handles.RowHandleId.fromRaw(0x0000_0005_0000_0009);
    const row = try appendEachRow(std.testing.allocator, &scopes, semantic_ids.root_scope, semantic_ids.SiteOrdinal.fromRaw(7), 42, handle, semantic_ids.initial_generation);

    try std.testing.expectEqual(semantic_ids.ScopeId.fromRaw(1), row.scope_id);
    try std.testing.expectEqual(@as(u64, 42), eachRowKeyHash(scopes.items, row.scope_id));
    try std.testing.expectEqual(handle, eachRowHandle(scopes.items, row.scope_id));
}
