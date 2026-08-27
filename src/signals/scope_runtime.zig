//! Runtime-owned scope payloads for state binders and keyed rows.

const std = @import("std");
const abi = @import("roc_platform_abi.zig");
const retained_values = @import("retained_values.zig");
const scope_tree = @import("scope_tree.zig");

pub const HostValue = retained_values.HostValue;
pub const HostValueCapability = retained_values.HostValueCapability;
pub const HostValueCell = retained_values.HostValueCell;

/// Per-row payload carried in a `Ui.each_str` scope: the row's key and item
/// cells, keyed by the construction-site ordinal.
pub const EachRowScopeStep = struct {
    site_ordinal: u64,
    key_hash: u64,
    key: HostValueCell,
    item: HostValueCell,
};

pub const ScopeStep = scope_tree.Step(EachRowScopeStep);
pub const Scope = scope_tree.Scope(EachRowScopeStep);

pub const EachSite = struct {
    parent_scope_id: u64,
    site_ordinal: u64,
};

pub const EachRowValues = struct {
    key: HostValue,
    item: HostValue,
};

/// Provisional each-row scopes whose retained key/item cells remain private
/// until an enclosing row transaction publishes them.
pub const PreparedEachRowScopes = struct {
    allocator: std.mem.Allocator,
    original_scope_len: usize,
    rows: std.ArrayListUnmanaged(Scope) = .empty,
    committed: bool = false,

    /// Starts an empty overlay over the current persistent scope table.
    pub fn init(allocator: std.mem.Allocator, scopes: []const Scope) PreparedEachRowScopes {
        return .{ .allocator = allocator, .original_scope_len = scopes.len };
    }

    /// Retains one provisional row and cumulatively reserves its final scope slot.
    pub fn prepareRow(self: *PreparedEachRowScopes, scopes: *std.ArrayListUnmanaged(Scope), ctx: anytype, roc_host: *abi.RocHost, metrics: anytype, parent_scope_id: u64, site_ordinal: u64, key_hash: u64, key: HostValue, item: HostValue, key_cap: HostValueCapability, item_cap: HostValueCapability) std.mem.Allocator.Error!u64 {
        if (self.committed or scopes.items.len != self.original_scope_len) @panic("invalid provisional each-row scope state");
        scope_tree.validate(EachRowScopeStep, scopes.items, parent_scope_id) catch @panic("scope id has no host scope descriptor");
        const next_len = std.math.add(usize, self.original_scope_len, self.rows.items.len + 1) catch return error.OutOfMemory;
        try scopes.ensureTotalCapacity(self.allocator, next_len);
        try self.rows.ensureUnusedCapacity(self.allocator, 1);

        var key_cell = HostValueCell.initRetained(key, key_cap, metrics);
        errdefer key_cell.deinit(ctx, roc_host, metrics);
        var item_cell = HostValueCell.initRetained(item, item_cap, metrics);
        errdefer item_cell.deinit(ctx, roc_host, metrics);
        const scope_id: u64 = @intCast(self.original_scope_len + self.rows.items.len);
        self.rows.appendAssumeCapacity(.{
            .scope_id = scope_id,
            .parent_scope_id = parent_scope_id,
            .step = .{ .each_row = .{
                .site_ordinal = site_ordinal,
                .key_hash = key_hash,
                .key = key_cell,
                .item = item_cell,
            } },
            .active = true,
        });
        return scope_id;
    }

    /// Publishes all provisional rows without allocation and transfers cell ownership.
    pub fn commit(self: *PreparedEachRowScopes, scopes: *std.ArrayListUnmanaged(Scope)) void {
        if (self.committed or scopes.items.len != self.original_scope_len) @panic("invalid provisional each-row scope commit");
        scopes.appendSliceAssumeCapacity(self.rows.items);
        self.rows.clearRetainingCapacity();
        self.committed = true;
    }

    /// Releases provisional key/item cells in reverse construction order.
    pub fn abort(self: *PreparedEachRowScopes, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype) void {
        if (self.committed) return;
        var index = self.rows.items.len;
        while (index != 0) {
            index -= 1;
            deinitScopeStep(&self.rows.items[index].step, ctx, roc_host, metrics);
        }
        self.rows.clearRetainingCapacity();
    }

    /// Releases overlay storage; callers must abort or commit first.
    pub fn deinit(self: *PreparedEachRowScopes) void {
        if (self.rows.items.len != 0) @panic("provisional each-row scopes still own values");
        self.rows.deinit(self.allocator);
        self.* = undefined;
    }
};

/// Drop the retained cells owned by an each-row scope step (no-op for the
/// structural scope kinds, which carry no Roc values).
pub fn deinitScopeStep(step: *ScopeStep, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype) void {
    switch (step.*) {
        .each_row => |*row| {
            row.key.deinit(ctx, roc_host, metrics);
            row.item.deinit(ctx, roc_host, metrics);
        },
        .root, .component, .when_branch => {},
    }
}

/// Appends each row using capacity that must already satisfy the caller's transaction contract.
pub fn appendEachRow(allocator: std.mem.Allocator, scopes: *std.ArrayListUnmanaged(Scope), parent_scope_id: u64, site_ordinal: u64, key_hash: u64, key: HostValue, item: HostValue, key_cap: HostValueCapability, item_cap: HostValueCapability, metrics: anytype, reuse_barrier: u64) scope_tree.Error!scope_tree.InternResult {
    try scope_tree.validate(EachRowScopeStep, scopes.items, parent_scope_id);

    const key_cell = HostValueCell.initRetained(key, key_cap, metrics);
    const item_cell = HostValueCell.initRetained(item, item_cap, metrics);
    return scope_tree.appendEachRow(EachRowScopeStep, allocator, scopes, parent_scope_id, .{
        .site_ordinal = site_ordinal,
        .key_hash = key_hash,
        .key = key_cell,
        .item = item_cell,
    }, reuse_barrier);
}

/// Appends fresh each row using capacity that must already satisfy the caller's transaction contract.
pub fn appendFreshEachRow(allocator: std.mem.Allocator, scopes: *std.ArrayListUnmanaged(Scope), parent_scope_id: u64, site_ordinal: u64, key_hash: u64, key: HostValue, item: HostValue, key_cap: HostValueCapability, item_cap: HostValueCapability, metrics: anytype) scope_tree.Error!scope_tree.InternResult {
    try scope_tree.validate(EachRowScopeStep, scopes.items, parent_scope_id);

    const key_cell = HostValueCell.initRetained(key, key_cap, metrics);
    const item_cell = HostValueCell.initRetained(item, item_cap, metrics);
    return scope_tree.appendFreshEachRow(EachRowScopeStep, allocator, scopes, parent_scope_id, .{
        .site_ordinal = site_ordinal,
        .key_hash = key_hash,
        .key = key_cell,
        .item = item_cell,
    });
}

/// Returns  from the keyed row selected by dense scope identity.
pub fn eachRow(scopes: []Scope, scope_id: u64) *EachRowScopeStep {
    scope_tree.validate(EachRowScopeStep, scopes, scope_id) catch @panic("scope id has no host scope descriptor");
    const scope = &scopes[@intCast(scope_id)];
    return switch (scope.step) {
        .each_row => |*row| row,
        .root, .component, .when_branch => @panic("scope id does not reference an each-row scope"),
    };
}

/// Returns const from the keyed row selected by dense scope identity.
pub fn eachRowConst(scopes: []const Scope, scope_id: u64) *const EachRowScopeStep {
    scope_tree.validate(EachRowScopeStep, scopes, scope_id) catch @panic("scope id has no host scope descriptor");
    const scope = &scopes[@intCast(scope_id)];
    return switch (scope.step) {
        .each_row => |*row| row,
        .root, .component, .when_branch => @panic("scope id does not reference an each-row scope"),
    };
}

/// Returns key equals from the keyed row selected by dense scope identity.
pub fn eachRowKeyEquals(scopes: []const Scope, ctx: anytype, roc_host: *abi.RocHost, scope_id: u64, key: HostValue, key_cap: HostValueCapability) bool {
    return eachRowConst(scopes, scope_id).key.valueEqualsIncoming(ctx, roc_host, key, key_cap);
}

/// Returns item equals from the keyed row selected by dense scope identity.
pub fn eachRowItemEquals(scopes: []const Scope, ctx: anytype, roc_host: *abi.RocHost, scope_id: u64, item: HostValue, item_cap: HostValueCapability) bool {
    return eachRowConst(scopes, scope_id).item.valueEqualsIncoming(ctx, roc_host, item, item_cap);
}

/// Replaces each row key while releasing displaced ownership exactly once.
pub fn replaceEachRowKey(scopes: []Scope, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype, scope_id: u64, key_hash: u64, key: HostValue, key_cap: HostValueCapability) void {
    const row = eachRow(scopes, scope_id);
    row.key_hash = key_hash;
    row.key.replaceRetained(ctx, roc_host, metrics, key, key_cap);
}

/// Replaces each row item while releasing displaced ownership exactly once.
pub fn replaceEachRowItem(scopes: []Scope, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype, scope_id: u64, item: HostValue, item_cap: HostValueCapability) void {
    const row = eachRow(scopes, scope_id);
    row.item.replaceRetained(ctx, roc_host, metrics, item, item_cap);
}

/// Returns values from the keyed row selected by dense scope identity.
pub fn eachRowValues(scopes: []const Scope, scope_id: u64) EachRowValues {
    const row = eachRowConst(scopes, scope_id);
    return .{ .key = row.key.value, .item = row.item.value };
}

/// Returns key value from the keyed row selected by dense scope identity.
pub fn eachRowKeyValue(scopes: []const Scope, scope_id: u64) HostValue {
    return eachRowConst(scopes, scope_id).key.value;
}

/// Returns key hash from the keyed row selected by dense scope identity.
pub fn eachRowKeyHash(scopes: []const Scope, scope_id: u64) u64 {
    return eachRowConst(scopes, scope_id).key_hash;
}

/// Disposes a scope subtree in post-order, releasing all values, effects, identities, and render ownership.
pub fn disposeSubtree(comptime Row: type, scopes: []scope_tree.Scope(Row), scope_id: u64, retired_at: u64, hooks: anytype) void {
    if (scope_id >= scopes.len) @panic("scope disposal referenced an unknown scope");
    if (scopes[@intCast(scope_id)].scope_id != scope_id or !scopes[@intCast(scope_id)].active) @panic("scope id has no host scope descriptor");

    var child_index: usize = 0;
    while (child_index < scopes.len) : (child_index += 1) {
        const child = scopes[child_index];
        if (!child.active) continue;
        if (child.parent_scope_id == scope_id) {
            disposeSubtree(Row, scopes, child.scope_id, retired_at, hooks);
        }
    }

    hooks.deactivateNodeIdentities(scope_id);
    hooks.appendCleanupEvents(scope_id);
    hooks.cancelPendingTasks(scope_id);
    hooks.deactivateDomIdentities(scope_id);

    const scope = &scopes[@intCast(scope_id)];
    switch (scope.step) {
        .each_row => |row| hooks.removeEachRow(scope.scope_id, row.key_hash),
        .root, .component, .when_branch => {},
    }
    hooks.deinitScopeStep(&scope.step);
    scope.active = false;
    scope.retired_at = retired_at;
    hooks.recordScopeDisposed();
}

/// Owns the exact post-order scope ids selected for deferred subtree retirement.
/// Preparation is fallible and read-only; applying metadata is allocation-free
/// and intentionally does not release step-owned resources.
pub const PreparedSubtreeRetirement = struct {
    scope_ids: []u64,

    /// Releases preparation storage without changing live scopes.
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.scope_ids);
        self.* = undefined;
    }

    /// Marks the prepared subtree inactive after replacement publication.
    pub fn applyMetadata(self: *const @This(), comptime Row: type, scopes: []scope_tree.Scope(Row), retired_at: u64) void {
        for (self.scope_ids) |scope_id| {
            const scope = &scopes[@intCast(scope_id)];
            if (!scope.active or scope.scope_id != scope_id) @panic("prepared scope retirement no longer matched live state");
            scope.active = false;
            scope.retired_at = retired_at;
        }
    }
};

/// Prepares a stable post-order scope-subtree snapshot without mutating scopes.
pub fn prepareSubtreeRetirement(comptime Row: type, allocator: std.mem.Allocator, scopes: []const scope_tree.Scope(Row), root_scope_id: u64) std.mem.Allocator.Error!PreparedSubtreeRetirement {
    if (root_scope_id >= scopes.len or scopes[@intCast(root_scope_id)].scope_id != root_scope_id or !scopes[@intCast(root_scope_id)].active) return error.OutOfMemory;
    var ids: std.ArrayListUnmanaged(u64) = .empty;
    errdefer ids.deinit(allocator);
    try ids.ensureTotalCapacity(allocator, scopes.len);
    try appendSubtreePostOrder(Row, scopes, root_scope_id, &ids);
    return .{ .scope_ids = try ids.toOwnedSlice(allocator) };
}

/// Prepares disjoint scope subtrees as one stable post-order retirement journal.
pub fn prepareSubtreesRetirement(comptime Row: type, allocator: std.mem.Allocator, scopes: []const scope_tree.Scope(Row), root_scope_ids: []const u64) (std.mem.Allocator.Error || error{OverlappingSubtrees})!PreparedSubtreeRetirement {
    const selected = try allocator.alloc(bool, scopes.len);
    defer allocator.free(selected);
    @memset(selected, false);
    var ids: std.ArrayListUnmanaged(u64) = .empty;
    errdefer ids.deinit(allocator);
    try ids.ensureTotalCapacity(allocator, scopes.len);
    for (root_scope_ids) |root_scope_id| {
        if (root_scope_id >= scopes.len or scopes[@intCast(root_scope_id)].scope_id != root_scope_id or !scopes[@intCast(root_scope_id)].active) return error.OverlappingSubtrees;
        try appendDisjointSubtreePostOrder(Row, scopes, root_scope_id, selected, &ids);
    }
    return .{ .scope_ids = try ids.toOwnedSlice(allocator) };
}

fn appendDisjointSubtreePostOrder(comptime Row: type, scopes: []const scope_tree.Scope(Row), scope_id: u64, selected: []bool, ids: *std.ArrayListUnmanaged(u64)) error{OverlappingSubtrees}!void {
    if (selected[@intCast(scope_id)]) return error.OverlappingSubtrees;
    selected[@intCast(scope_id)] = true;
    for (scopes) |child| {
        if (child.active and child.parent_scope_id != null and child.parent_scope_id.? == scope_id) try appendDisjointSubtreePostOrder(Row, scopes, child.scope_id, selected, ids);
    }
    ids.appendAssumeCapacity(scope_id);
}

fn appendSubtreePostOrder(comptime Row: type, scopes: []const scope_tree.Scope(Row), scope_id: u64, ids: *std.ArrayListUnmanaged(u64)) std.mem.Allocator.Error!void {
    for (scopes) |child| {
        if (child.active and child.parent_scope_id != null and child.parent_scope_id.? == scope_id) try appendSubtreePostOrder(Row, scopes, child.scope_id, ids);
    }
    ids.appendAssumeCapacity(scope_id);
}

const TestRow = struct {
    site_ordinal: u64,
    key_hash: u64,
};

const TestDisposeHooks = struct {
    node_deactivations: std.ArrayListUnmanaged(u64) = .empty,
    cleanup_events: std.ArrayListUnmanaged(u64) = .empty,
    task_cancellations: std.ArrayListUnmanaged(u64) = .empty,
    dom_deactivations: std.ArrayListUnmanaged(u64) = .empty,
    removed_rows: std.ArrayListUnmanaged(u64) = .empty,
    deinit_steps: u64 = 0,
    disposed_scopes: u64 = 0,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.node_deactivations.deinit(allocator);
        self.cleanup_events.deinit(allocator);
        self.task_cancellations.deinit(allocator);
        self.dom_deactivations.deinit(allocator);
        self.removed_rows.deinit(allocator);
    }

    /// Retires node identities so disposed scope identity cannot be routed again.
    pub fn deactivateNodeIdentities(self: *@This(), scope_id: u64) void {
        self.node_deactivations.append(std.testing.allocator, scope_id) catch @panic("out of memory");
    }

    /// Appends cleanup events using capacity that must already satisfy the caller's transaction contract.
    pub fn appendCleanupEvents(self: *@This(), scope_id: u64) void {
        self.cleanup_events.append(std.testing.allocator, scope_id) catch @panic("out of memory");
    }

    /// Cancels pending tasks and releases its bounded host-retained work.
    pub fn cancelPendingTasks(self: *@This(), scope_id: u64) void {
        self.task_cancellations.append(std.testing.allocator, scope_id) catch @panic("out of memory");
    }

    /// Retires dom identities so disposed scope identity cannot be routed again.
    pub fn deactivateDomIdentities(self: *@This(), scope_id: u64) void {
        self.dom_deactivations.append(std.testing.allocator, scope_id) catch @panic("out of memory");
    }

    /// Removes each row and releases the ownership attached to that live entry.
    pub fn removeEachRow(self: *@This(), scope_id: u64, key_hash: u64) void {
        _ = scope_id;
        self.removed_rows.append(std.testing.allocator, key_hash) catch @panic("out of memory");
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
    _ = try scope_tree.internComponent(TestRow, std.testing.allocator, &scopes, 0, 1, 0);
    _ = try scope_tree.appendEachRow(TestRow, std.testing.allocator, &scopes, 1, .{ .site_ordinal = 4, .key_hash = 40 }, 0);
    _ = try scope_tree.internComponent(TestRow, std.testing.allocator, &scopes, 2, 1, 0);
    _ = try scope_tree.internComponent(TestRow, std.testing.allocator, &scopes, 0, 2, 0);

    var hooks = TestDisposeHooks{};
    defer hooks.deinit(std.testing.allocator);
    disposeSubtree(TestRow, scopes.items, 1, 5, &hooks);

    try std.testing.expect(scopes.items[0].active);
    try std.testing.expect(!scopes.items[1].active);
    try std.testing.expect(!scopes.items[2].active);
    try std.testing.expect(!scopes.items[3].active);
    try std.testing.expect(scopes.items[4].active);
    try std.testing.expectEqual(@as(u64, 5), scopes.items[1].retired_at);
    try std.testing.expectEqual(@as(u64, 5), scopes.items[2].retired_at);
    try std.testing.expectEqual(@as(u64, 5), scopes.items[3].retired_at);
    try std.testing.expectEqualSlices(u64, &.{ 3, 2, 1 }, hooks.node_deactivations.items);
    try std.testing.expectEqualSlices(u64, &.{40}, hooks.removed_rows.items);
    try std.testing.expectEqual(@as(u64, 3), hooks.deinit_steps);
    try std.testing.expectEqual(@as(u64, 3), hooks.disposed_scopes);
}

test "prepared scope retirement sweeps allocation failures and applies without allocation" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var scopes: std.ArrayListUnmanaged(scope_tree.Scope(TestRow)) = .empty;
    defer scopes.deinit(std.testing.allocator);
    _ = try scope_tree.internRoot(TestRow, std.testing.allocator, &scopes);
    _ = try scope_tree.internComponent(TestRow, std.testing.allocator, &scopes, 0, 1, 0);
    _ = try scope_tree.appendEachRow(TestRow, std.testing.allocator, &scopes, 1, .{ .site_ordinal = 4, .key_hash = 40 }, 0);
    _ = try scope_tree.internComponent(TestRow, std.testing.allocator, &scopes, 2, 1, 0);
    _ = try scope_tree.internComponent(TestRow, std.testing.allocator, &scopes, 0, 2, 0);

    var baseline_fault = FaultAllocator.init(std.testing.allocator);
    var baseline = try prepareSubtreeRetirement(TestRow, baseline_fault.allocator(), scopes.items, 1);
    const attempts = baseline_fault.attempts;
    baseline.deinit(baseline_fault.allocator());
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| {
        var fault = FaultAllocator.init(std.testing.allocator);
        fault.configure(failure_number);
        try std.testing.expectError(error.OutOfMemory, prepareSubtreeRetirement(TestRow, fault.allocator(), scopes.items, 1));
        for (scopes.items) |scope| try std.testing.expect(scope.active);
    }

    var fault = FaultAllocator.init(std.testing.allocator);
    var prepared = try prepareSubtreeRetirement(TestRow, fault.allocator(), scopes.items, 1);
    defer prepared.deinit(fault.allocator());
    try std.testing.expectEqualSlices(u64, &.{ 3, 2, 1 }, prepared.scope_ids);
    fault.configure(1);
    prepared.applyMetadata(TestRow, scopes.items, 9);
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expect(!scopes.items[1].active);
    try std.testing.expect(!scopes.items[2].active);
    try std.testing.expect(!scopes.items[3].active);
    try std.testing.expect(scopes.items[0].active);
    try std.testing.expect(scopes.items[4].active);
}

test "prepared disjoint scope retirement unions roots and rejects overlap" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var scopes: std.ArrayListUnmanaged(scope_tree.Scope(TestRow)) = .empty;
    defer scopes.deinit(std.testing.allocator);
    _ = try scope_tree.internRoot(TestRow, std.testing.allocator, &scopes);
    _ = try scope_tree.internComponent(TestRow, std.testing.allocator, &scopes, 0, 1, 0);
    _ = try scope_tree.appendEachRow(TestRow, std.testing.allocator, &scopes, 1, .{ .site_ordinal = 4, .key_hash = 40 }, 0);
    _ = try scope_tree.internComponent(TestRow, std.testing.allocator, &scopes, 2, 1, 0);
    _ = try scope_tree.internComponent(TestRow, std.testing.allocator, &scopes, 0, 2, 0);

    var counter = FaultAllocator.init(std.testing.allocator);
    var successful = try prepareSubtreesRetirement(TestRow, counter.allocator(), scopes.items, &.{ 1, 4 });
    const attempts = counter.attempts;
    try std.testing.expect(attempts != 0);
    try std.testing.expectEqualSlices(u64, &.{ 3, 2, 1, 4 }, successful.scope_ids);
    successful.deinit(counter.allocator());

    for (1..attempts + 1) |failure_number| {
        var fault = FaultAllocator.init(std.testing.allocator);
        fault.configure(failure_number);
        try std.testing.expectError(error.OutOfMemory, prepareSubtreesRetirement(TestRow, fault.allocator(), scopes.items, &.{ 1, 4 }));
        for (scopes.items) |scope| try std.testing.expect(scope.active);
        fault.configure(null);
        var retry = try prepareSubtreesRetirement(TestRow, fault.allocator(), scopes.items, &.{ 1, 4 });
        retry.deinit(fault.allocator());
    }

    try std.testing.expectError(error.OverlappingSubtrees, prepareSubtreesRetirement(TestRow, std.testing.allocator, scopes.items, &.{ 1, 2 }));
    for (scopes.items) |scope| try std.testing.expect(scope.active);
}

test "scope runtime owns each-row scope values and key hash" {
    var scopes: std.ArrayListUnmanaged(Scope) = .empty;
    defer scopes.deinit(std.testing.allocator);

    _ = try scope_tree.internRoot(EachRowScopeStep, std.testing.allocator, &scopes);

    var metrics = struct {
        /// Increments  for exact structural-work accounting.
        pub fn bump(_: *@This(), comptime _: anytype, _: u64) void {}
    }{};
    const key_cap: HostValueCapability = std.mem.zeroes(HostValueCapability);
    const item_cap: HostValueCapability = std.mem.zeroes(HostValueCapability);
    const row = try appendEachRow(std.testing.allocator, &scopes, 0, 7, 42, 100, 200, key_cap, item_cap, &metrics, 0);

    try std.testing.expectEqual(@as(u64, 1), row.scope_id);
    try std.testing.expectEqual(@as(u64, 42), eachRowKeyHash(scopes.items, row.scope_id));
    try std.testing.expectEqual(@as(HostValue, 100), eachRowKeyValue(scopes.items, row.scope_id));

    const values = eachRowValues(scopes.items, row.scope_id);
    try std.testing.expectEqual(@as(HostValue, 100), values.key);
    try std.testing.expectEqual(@as(HostValue, 200), values.item);
}
