//! Runtime-owned scope payloads for state binders and keyed rows.

const std = @import("std");
const shared_buffer = @import("shared_buffer.zig");
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

/// Exact work performed while claiming provisional scope slots. A claim visits
/// at most one reusable slot beyond the ones it hands out, so these counts are
/// independent of the number of unrelated live or retired scopes in the table.
pub const ScopeClaimWork = struct {
    /// Reusable-ring slots examined, including a blocked head that ended the
    /// reuse walk. Never exceeds the number of claims plus one.
    reusable_slots_visited: usize = 0,
    /// Claims that reserved a fresh slot past the committed table length.
    fresh_slots_claimed: usize = 0,
};

/// Provisional each-row scopes whose stable handles remain private until an
/// enclosing structural transaction publishes them.
///
/// Slot selection walks the committed reusable ring (`scope_tree`) from its
/// head, oldest retirement first, without unlinking anything: the claim is a
/// cursor over committed availability, so an aborted transaction leaves the
/// ring untouched and a retry re-derives the same ids. Only `commit` consumes
/// the slots, through `publishScopeAssumeCapacity`. A ring head still blocked
/// by the reuse barrier ends the walk, because every later slot was retired in
/// the same or a later generation; remaining claims then take fresh slots.
pub const PreparedScopeClaims = struct {
    allocator: std.mem.Allocator,
    original_scope_len: usize,
    reuse_barrier: scope_tree.Generation,
    rows: shared_buffer.List(Scope) = .empty,
    /// Newest ring slot handed out by this transaction, or null before the
    /// first reuse. The next candidate is the ring successor of this slot.
    last_reused_scope_id: ?semantic_ids.ScopeId = null,
    /// Set once the ring head or a successor blocked reuse or ran out; later
    /// claims skip the ring entirely.
    reuse_exhausted: bool = false,
    new_scope_count: usize = 0,
    phase: ClaimsPhase = .preparing,
    work: ScopeClaimWork = .{},

    /// Starts an empty overlay over the current persistent scope table. Slots
    /// retired in `reuse_barrier` are not offered to this transaction.
    pub fn init(allocator: std.mem.Allocator, scopes: []const Scope, reuse_barrier: scope_tree.Generation) PreparedScopeClaims {
        return .{ .allocator = allocator, .original_scope_len = scopes.len, .reuse_barrier = reuse_barrier };
    }

    /// Claims one provisional row and cumulatively reserves its final scope slot.
    pub fn prepareRow(self: *PreparedEachRowScopes, scopes: *shared_buffer.List(Scope), parent_scope_id: semantic_ids.ScopeId, site_ordinal: semantic_ids.SiteOrdinal, key_hash: u64, row_handle: row_handles.RowHandleId) (std.mem.Allocator.Error || error{ResourceLimit})!semantic_ids.ScopeId {
        if (self.phase.isCommitted() or scopes.items.len != self.original_scope_len) @panic("invalid provisional each-row scope state");
        scope_tree.validate(EachRowScopeStep, scopes.items, parent_scope_id) catch @panic("scope id has no host scope descriptor");
        const reused: ?semantic_ids.ScopeId = self.nextReusableCandidate(scopes.items);
        const scope_id: semantic_ids.ScopeId = reused orelse
            semantic_ids.ScopeId.fromIndex(std.math.add(usize, self.original_scope_len, self.new_scope_count) catch return error.ResourceLimit);
        if (reused == null) {
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
        if (reused != null) {
            self.last_reused_scope_id = reused;
        } else {
            self.new_scope_count += 1;
            self.work.fresh_slots_claimed += 1;
        }
        return scope_id;
    }

    /// Peeks the next committed reusable slot without consuming it. Returns
    /// null once the ring is exhausted or its next slot is barrier-blocked.
    fn nextReusableCandidate(self: *PreparedEachRowScopes, scopes: []const Scope) ?semantic_ids.ScopeId {
        if (self.reuse_exhausted) return null;
        const candidate = if (self.last_reused_scope_id) |last| candidate: {
            if (scopes[last.index()].lifecycle.isActive() or !scope_tree.isLinkedReusable(EachRowScopeStep, scopes, last)) @panic("provisionally claimed scope slot changed under an open transaction");
            break :candidate scope_tree.nextReusableScope(EachRowScopeStep, scopes, last);
        } else scope_tree.firstReusableScope(EachRowScopeStep, scopes);
        const scope_id = candidate orelse {
            self.reuse_exhausted = true;
            return null;
        };
        self.work.reusable_slots_visited += 1;
        if (scopes[scope_id.index()].lifecycle.blocksReuse(self.reuse_barrier)) {
            self.reuse_exhausted = true;
            return null;
        }
        return scope_id;
    }

    /// Publishes all provisional rows without allocation.
    pub fn commit(self: *PreparedEachRowScopes, scopes: *shared_buffer.List(Scope)) void {
        if (self.phase.isCommitted() or scopes.items.len != self.original_scope_len) @panic("invalid provisional each-row scope commit");
        for (self.rows.items) |scope| {
            scope_tree.publishScopeAssumeCapacity(EachRowScopeStep, scopes, self.original_scope_len, scope);
        }
        self.rows.clearRetainingCapacity();
        self.resetClaims();
        self.phase = .committed;
    }

    /// Abandons provisional scope claims without retiring their row handles.
    /// The enclosing generation plan remains the handle owner until commit.
    /// Nothing was taken from the committed ring, so nothing is returned.
    pub fn abort(self: *PreparedEachRowScopes) void {
        if (self.phase.isCommitted()) return;
        self.rows.clearRetainingCapacity();
        self.resetClaims();
    }

    fn resetClaims(self: *PreparedEachRowScopes) void {
        self.last_reused_scope_id = null;
        self.reuse_exhausted = false;
        self.new_scope_count = 0;
    }

    /// Releases overlay storage; callers must abort or commit first.
    pub fn deinit(self: *PreparedEachRowScopes) void {
        if (self.rows.items.len != 0) @panic("provisional each-row scope claims were not resolved");
        self.rows.deinit(self.allocator);
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
pub fn appendEachRow(allocator: std.mem.Allocator, scopes: *shared_buffer.List(Scope), parent_scope_id: semantic_ids.ScopeId, site_ordinal: semantic_ids.SiteOrdinal, key_hash: u64, row_handle: row_handles.RowHandleId, reuse_barrier: scope_tree.Generation) scope_tree.Error!scope_tree.InternResult {
    try scope_tree.validate(EachRowScopeStep, scopes.items, parent_scope_id);

    return scope_tree.appendEachRow(EachRowScopeStep, allocator, scopes, parent_scope_id, .{
        .site_ordinal = site_ordinal,
        .key_hash = key_hash,
        .row_handle = row_handle,
    }, reuse_barrier);
}

/// Appends fresh each row using capacity that must already satisfy the caller's transaction contract.
pub fn appendFreshEachRow(allocator: std.mem.Allocator, scopes: *shared_buffer.List(Scope), parent_scope_id: semantic_ids.ScopeId, site_ordinal: semantic_ids.SiteOrdinal, key_hash: u64, row_handle: row_handles.RowHandleId) scope_tree.Error!scope_tree.InternResult {
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
            var scopes: shared_buffer.List(Scope) = .empty;
            defer scopes.deinit(std.testing.allocator);
            _ = try scope_tree.internRoot(EachRowScopeStep, std.testing.allocator, &scopes);
            var claims = PreparedScopeClaims.init(fault.allocator(), scopes.items, semantic_ids.initial_generation);
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

test "prepared scope claims publish dense reused rows into child topology" {
    var scopes: shared_buffer.List(Scope) = .empty;
    defer scopes.deinit(std.testing.allocator);
    _ = try scope_tree.internRoot(EachRowScopeStep, std.testing.allocator, &scopes);
    const retired = (try appendFreshEachRow(
        std.testing.allocator,
        &scopes,
        semantic_ids.root_scope,
        semantic_ids.SiteOrdinal.fromRaw(1),
        1,
        row_handles.RowHandleId.fromRaw(0x0000_0001_0000_0001),
    )).scope_id;
    scope_tree.retireScopeAssumeValid(EachRowScopeStep, scopes.items, retired, semantic_ids.Generation.fromRaw(1));

    var claims = PreparedScopeClaims.init(std.testing.allocator, scopes.items, semantic_ids.initial_generation);
    defer claims.deinit();
    const reused = try claims.prepareRow(
        &scopes,
        semantic_ids.root_scope,
        semantic_ids.SiteOrdinal.fromRaw(2),
        2,
        row_handles.RowHandleId.fromRaw(0x0000_0001_0000_0002),
    );
    const fresh = try claims.prepareRow(
        &scopes,
        semantic_ids.root_scope,
        semantic_ids.SiteOrdinal.fromRaw(3),
        3,
        row_handles.RowHandleId.fromRaw(0x0000_0001_0000_0003),
    );
    try std.testing.expectEqual(retired, reused);
    try std.testing.expectEqual(semantic_ids.ScopeId.fromRaw(2), fresh);
    try std.testing.expectEqual(@as(usize, 2), scopes.items.len);

    claims.commit(&scopes);
    try std.testing.expectEqual(@as(usize, 3), scopes.items.len);
    try std.testing.expectEqual(@as(?semantic_ids.ScopeId, reused), scopes.items[semantic_ids.root_scope.index()].first_child_scope_id);
    try std.testing.expectEqual(@as(?semantic_ids.ScopeId, fresh), scopes.items[semantic_ids.root_scope.index()].last_child_scope_id);
    try std.testing.expectEqual(@as(?semantic_ids.ScopeId, fresh), scopes.items[reused.index()].next_sibling_scope_id);
    try std.testing.expectEqual(@as(?semantic_ids.ScopeId, reused), scopes.items[fresh.index()].previous_sibling_scope_id);
}

const ClaimFixture = struct {
    scopes: shared_buffer.List(Scope) = .empty,

    fn init() !ClaimFixture {
        var fixture: ClaimFixture = .{};
        _ = try scope_tree.internRoot(EachRowScopeStep, std.testing.allocator, &fixture.scopes);
        return fixture;
    }

    fn deinit(self: *ClaimFixture) void {
        self.scopes.deinit(std.testing.allocator);
    }

    fn appendRow(self: *ClaimFixture, parent: semantic_ids.ScopeId, key: u64) !semantic_ids.ScopeId {
        return (try appendFreshEachRow(std.testing.allocator, &self.scopes, parent, semantic_ids.SiteOrdinal.fromRaw(1), key, row_handles.RowHandleId.fromRaw(key))).scope_id;
    }

    fn retire(self: *ClaimFixture, scope_id: semantic_ids.ScopeId, generation: u64) void {
        scope_tree.retireScopeAssumeValid(EachRowScopeStep, self.scopes.items, scope_id, semantic_ids.Generation.fromRaw(generation));
    }

    fn claim(self: *ClaimFixture, claims: *PreparedScopeClaims, parent: semantic_ids.ScopeId, key: u64) !semantic_ids.ScopeId {
        return claims.prepareRow(&self.scopes, parent, semantic_ids.SiteOrdinal.fromRaw(2), key, row_handles.RowHandleId.fromRaw(key));
    }

    fn ringLen(self: *const ClaimFixture) usize {
        var count: usize = 0;
        var cursor = scope_tree.firstReusableScope(EachRowScopeStep, self.scopes.items);
        while (cursor) |scope_id| : (cursor = scope_tree.nextReusableScope(EachRowScopeStep, self.scopes.items, scope_id)) count += 1;
        return count;
    }
};

test "one row scope claim visits at most one slot regardless of unrelated live scopes" {
    for ([_]usize{ 1_000, 10_000 }) |live_rows| {
        var fixture = try ClaimFixture.init();
        defer fixture.deinit();
        var retired_row: ?semantic_ids.ScopeId = null;
        for (0..live_rows) |i| {
            const row = try fixture.appendRow(semantic_ids.root_scope, @intCast(i + 1));
            if (i == live_rows / 2) retired_row = row;
        }
        const table_len = fixture.scopes.items.len;

        // No reusable slot anywhere: the claim asks the ring once and takes a fresh slot.
        {
            var claims = PreparedScopeClaims.init(std.testing.allocator, fixture.scopes.items, semantic_ids.Generation.fromRaw(1));
            defer claims.deinit();
            const fresh = try fixture.claim(&claims, semantic_ids.root_scope, 0xF0);
            try std.testing.expectEqual(semantic_ids.ScopeId.fromIndex(table_len), fresh);
            try std.testing.expectEqual(ScopeClaimWork{ .reusable_slots_visited = 0, .fresh_slots_claimed = 1 }, claims.work);
            claims.abort();
        }

        // One retired slot in the middle of a large live table: exactly one slot visited.
        fixture.retire(retired_row.?, 0);
        var claims = PreparedScopeClaims.init(std.testing.allocator, fixture.scopes.items, semantic_ids.Generation.fromRaw(1));
        defer claims.deinit();
        const reused = try fixture.claim(&claims, semantic_ids.root_scope, 0xF1);
        try std.testing.expectEqual(retired_row.?, reused);
        try std.testing.expectEqual(ScopeClaimWork{ .reusable_slots_visited = 1, .fresh_slots_claimed = 0 }, claims.work);
        claims.commit(&fixture.scopes);
        try std.testing.expectEqual(table_len, fixture.scopes.items.len);
        try std.testing.expectEqual(@as(u64, 0xF1), eachRowKeyHash(fixture.scopes.items, reused));
    }
}

test "one row scope claim visits one slot with a large retired reusable table" {
    var fixture = try ClaimFixture.init();
    defer fixture.deinit();
    const retired_rows: usize = 10_000;
    for (0..retired_rows) |i| {
        const row = try fixture.appendRow(semantic_ids.root_scope, @intCast(i + 1));
        fixture.retire(row, 0);
    }
    const live_a = try fixture.appendRow(semantic_ids.root_scope, 0xA);
    const live_b = try fixture.appendRow(semantic_ids.root_scope, 0xB);
    try std.testing.expectEqual(retired_rows, fixture.ringLen());
    try std.testing.expect(!scope_tree.isLinkedReusable(EachRowScopeStep, fixture.scopes.items, live_a));
    try std.testing.expect(!scope_tree.isLinkedReusable(EachRowScopeStep, fixture.scopes.items, live_b));

    var claims = PreparedScopeClaims.init(std.testing.allocator, fixture.scopes.items, semantic_ids.Generation.fromRaw(1));
    defer claims.deinit();
    const reused = try fixture.claim(&claims, live_a, 0xC);
    try std.testing.expectEqual(ScopeClaimWork{ .reusable_slots_visited = 1, .fresh_slots_claimed = 0 }, claims.work);
    try std.testing.expectEqual(semantic_ids.ScopeId.fromRaw(1), reused);
    const second = try fixture.claim(&claims, live_b, 0xD);
    try std.testing.expectEqual(semantic_ids.ScopeId.fromRaw(2), second);
    try std.testing.expectEqual(@as(usize, 2), claims.work.reusable_slots_visited);
    claims.commit(&fixture.scopes);
    try std.testing.expectEqual(retired_rows - 2, fixture.ringLen());
    try std.testing.expectEqual(@as(?semantic_ids.ScopeId, reused), fixture.scopes.items[live_a.index()].first_child_scope_id);
    try std.testing.expectEqual(@as(?semantic_ids.ScopeId, second), fixture.scopes.items[live_b.index()].first_child_scope_id);
}

test "multiple claims per transaction walk the ring in retirement order and abort leaves it untouched" {
    var fixture = try ClaimFixture.init();
    defer fixture.deinit();
    const a = try fixture.appendRow(semantic_ids.root_scope, 1);
    const b = try fixture.appendRow(semantic_ids.root_scope, 2);
    const c = try fixture.appendRow(semantic_ids.root_scope, 3);
    fixture.retire(c, 0);
    fixture.retire(a, 0);
    fixture.retire(b, 0);
    try std.testing.expectEqual(@as(?semantic_ids.ScopeId, c), scope_tree.firstReusableScope(EachRowScopeStep, fixture.scopes.items));

    var claims = PreparedScopeClaims.init(std.testing.allocator, fixture.scopes.items, semantic_ids.Generation.fromRaw(1));
    defer claims.deinit();
    try std.testing.expectEqual(c, try fixture.claim(&claims, semantic_ids.root_scope, 11));
    try std.testing.expectEqual(a, try fixture.claim(&claims, semantic_ids.root_scope, 12));
    // Provisional claims consume nothing committed.
    try std.testing.expectEqual(@as(usize, 3), fixture.ringLen());
    claims.abort();
    try std.testing.expectEqual(@as(usize, 3), fixture.ringLen());
    try std.testing.expectEqual(@as(?semantic_ids.ScopeId, c), scope_tree.firstReusableScope(EachRowScopeStep, fixture.scopes.items));

    // A later transaction re-derives the same slots, then exhausts the ring and goes fresh.
    var retry = PreparedScopeClaims.init(std.testing.allocator, fixture.scopes.items, semantic_ids.Generation.fromRaw(1));
    defer retry.deinit();
    try std.testing.expectEqual(c, try fixture.claim(&retry, semantic_ids.root_scope, 11));
    try std.testing.expectEqual(a, try fixture.claim(&retry, semantic_ids.root_scope, 12));
    try std.testing.expectEqual(b, try fixture.claim(&retry, semantic_ids.root_scope, 13));
    const fresh = try fixture.claim(&retry, semantic_ids.root_scope, 14);
    try std.testing.expectEqual(semantic_ids.ScopeId.fromRaw(4), fresh);
    const fresh_again = try fixture.claim(&retry, semantic_ids.root_scope, 15);
    try std.testing.expectEqual(semantic_ids.ScopeId.fromRaw(5), fresh_again);
    try std.testing.expectEqual(ScopeClaimWork{ .reusable_slots_visited = 3, .fresh_slots_claimed = 2 }, retry.work);
    retry.commit(&fixture.scopes);
    try std.testing.expectEqual(@as(usize, 0), fixture.ringLen());
    try std.testing.expectEqual(@as(usize, 6), fixture.scopes.items.len);
    for (fixture.scopes.items[1..], [_]u64{ 12, 13, 11, 14, 15 }) |scope, key| try std.testing.expectEqual(key, scope.step.each_row.key_hash);
}

test "row scope claims reuse retired component and branch slots and nest under live rows" {
    var fixture = try ClaimFixture.init();
    defer fixture.deinit();
    const component = (try scope_tree.internComponent(EachRowScopeStep, std.testing.allocator, &fixture.scopes, semantic_ids.root_scope, semantic_ids.SiteOrdinal.fromRaw(7), semantic_ids.initial_generation)).scope_id;
    const branch = (try scope_tree.internWhenBranch(EachRowScopeStep, std.testing.allocator, &fixture.scopes, semantic_ids.root_scope, semantic_ids.SiteOrdinal.fromRaw(8), .true_branch, semantic_ids.initial_generation)).scope_id;
    const outer_row = try fixture.appendRow(semantic_ids.root_scope, 1);
    const nested_component = (try scope_tree.internComponent(EachRowScopeStep, std.testing.allocator, &fixture.scopes, outer_row, semantic_ids.SiteOrdinal.fromRaw(0), semantic_ids.initial_generation)).scope_id;
    fixture.retire(branch, 0);
    fixture.retire(nested_component, 0);
    fixture.retire(component, 0);

    var claims = PreparedScopeClaims.init(std.testing.allocator, fixture.scopes.items, semantic_ids.Generation.fromRaw(1));
    defer claims.deinit();
    const nested_row = try fixture.claim(&claims, outer_row, 21);
    const top_row = try fixture.claim(&claims, semantic_ids.root_scope, 22);
    const deeper_row = try fixture.claim(&claims, outer_row, 23);
    try std.testing.expectEqual(branch, nested_row);
    try std.testing.expectEqual(nested_component, top_row);
    try std.testing.expectEqual(component, deeper_row);
    claims.commit(&fixture.scopes);
    try std.testing.expectEqual(@as(usize, 5), fixture.scopes.items.len);
    try std.testing.expectEqual(@as(?semantic_ids.ScopeId, nested_row), fixture.scopes.items[outer_row.index()].first_child_scope_id);
    try std.testing.expectEqual(@as(?semantic_ids.ScopeId, deeper_row), fixture.scopes.items[outer_row.index()].last_child_scope_id);
    try std.testing.expectEqual(@as(?semantic_ids.ScopeId, top_row), fixture.scopes.items[semantic_ids.root_scope.index()].last_child_scope_id);
    try std.testing.expectEqual(@as(u64, 22), eachRowKeyHash(fixture.scopes.items, top_row));
    try std.testing.expectEqual(@as(usize, 0), fixture.ringLen());
}

test "row scope claims honor the reuse barrier and retire-then-reuse across generations" {
    var fixture = try ClaimFixture.init();
    defer fixture.deinit();
    const old = try fixture.appendRow(semantic_ids.root_scope, 1);
    const recent = try fixture.appendRow(semantic_ids.root_scope, 2);
    fixture.retire(old, 4);
    fixture.retire(recent, 5);

    // Stale identity: the retired ids are rejected as parents and as routable scopes.
    try std.testing.expectError(scope_tree.Error.InactiveScope, scope_tree.validate(EachRowScopeStep, fixture.scopes.items, old));
    try std.testing.expectError(scope_tree.Error.UnknownScope, scope_tree.validate(EachRowScopeStep, fixture.scopes.items, semantic_ids.ScopeId.fromRaw(9)));

    // During generation 5 only the older retirement is reusable; the barrier ends the walk after one more visit.
    var during = PreparedScopeClaims.init(std.testing.allocator, fixture.scopes.items, semantic_ids.Generation.fromRaw(5));
    defer during.deinit();
    try std.testing.expectEqual(old, try fixture.claim(&during, semantic_ids.root_scope, 11));
    const fresh = try fixture.claim(&during, semantic_ids.root_scope, 12);
    try std.testing.expectEqual(semantic_ids.ScopeId.fromRaw(3), fresh);
    _ = try fixture.claim(&during, semantic_ids.root_scope, 13);
    try std.testing.expectEqual(ScopeClaimWork{ .reusable_slots_visited = 2, .fresh_slots_claimed = 2 }, during.work);
    during.commit(&fixture.scopes);
    try std.testing.expectEqual(@as(usize, 1), fixture.ringLen());
    try std.testing.expectEqual(@as(u64, 11), eachRowKeyHash(fixture.scopes.items, old));

    // A ring whose head is blocked yields no reuse at all and costs one visit.
    var blocked = PreparedScopeClaims.init(std.testing.allocator, fixture.scopes.items, semantic_ids.Generation.fromRaw(5));
    defer blocked.deinit();
    try std.testing.expectEqual(semantic_ids.ScopeId.fromRaw(5), try fixture.claim(&blocked, semantic_ids.root_scope, 14));
    try std.testing.expectEqual(ScopeClaimWork{ .reusable_slots_visited = 1, .fresh_slots_claimed = 1 }, blocked.work);
    blocked.abort();

    // The next generation reuses it, and slots retired again after reuse re-enter the ring once, in order.
    var next = PreparedScopeClaims.init(std.testing.allocator, fixture.scopes.items, semantic_ids.Generation.fromRaw(6));
    defer next.deinit();
    try std.testing.expectEqual(recent, try fixture.claim(&next, semantic_ids.root_scope, 15));
    next.commit(&fixture.scopes);
    try std.testing.expectEqual(@as(usize, 0), fixture.ringLen());
    fixture.retire(recent, 6);
    fixture.retire(old, 6);
    try std.testing.expectEqual(@as(usize, 2), fixture.ringLen());
    try std.testing.expectEqual(@as(?semantic_ids.ScopeId, recent), scope_tree.firstReusableScope(EachRowScopeStep, fixture.scopes.items));
    try std.testing.expectEqual(@as(usize, 5), fixture.scopes.items.len);
}

test "row scope claim faults leave the reusable ring coherent and commit allocation-free" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    const Runner = struct {
        fn run(failure_number: ?usize) !usize {
            var fault = FaultAllocator.init(std.testing.allocator);
            var fixture = try ClaimFixture.init();
            defer fixture.deinit();
            const retired = try fixture.appendRow(semantic_ids.root_scope, 1);
            fixture.retire(retired, 0);
            var claims = PreparedScopeClaims.init(fault.allocator(), fixture.scopes.items, semantic_ids.Generation.fromRaw(1));
            defer {
                claims.abort();
                claims.deinit();
            }
            fault.configure(failure_number);
            var failed = false;
            for ([_]u64{ 11, 12, 13 }) |key| {
                _ = fixture.claim(&claims, semantic_ids.root_scope, key) catch |err| {
                    try std.testing.expectEqual(error.OutOfMemory, err);
                    failed = true;
                    break;
                };
            }
            try std.testing.expect(failed == (failure_number != null));
            try std.testing.expectEqual(@as(usize, 1), fixture.ringLen());
            try std.testing.expectEqual(@as(usize, 2), fixture.scopes.items.len);
            if (failed) {
                claims.abort();
                fault.configure(null);
                for ([_]u64{ 11, 12, 13 }) |key| _ = try fixture.claim(&claims, semantic_ids.root_scope, key);
            }
            const attempts = fault.attempts;
            fault.configure(1);
            claims.commit(&fixture.scopes);
            try std.testing.expectEqual(@as(usize, 0), fault.attempts);
            try std.testing.expectEqual(@as(usize, 4), fixture.scopes.items.len);
            try std.testing.expectEqual(@as(usize, 0), fixture.ringLen());
            try std.testing.expectEqual(@as(u64, 11), eachRowKeyHash(fixture.scopes.items, retired));
            return attempts;
        }
    };
    const attempts = try Runner.run(null);
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| _ = try Runner.run(failure_number);
}

/// Counts exact intrusive-topology work performed while selecting or disposing
/// scope subtrees. Preparation visits each selected scope twice: once to size
/// exact storage and once to materialize the stable post-order journal.
pub const SubtreeTraversalWork = struct {
    scope_visits: usize = 0,
    child_links_followed: usize = 0,
    validation_roots_checked: usize = 0,
    validation_parent_links_followed: usize = 0,
};

/// Disposes a scope subtree in post-order, releasing all values, effects,
/// identities, and render ownership without searching unrelated scope slots.
pub fn disposeSubtree(comptime Row: type, scopes: []scope_tree.Scope(Row), scope_id: semantic_ids.ScopeId, retirement_generation: scope_tree.Generation, hooks: anytype) void {
    var work: SubtreeTraversalWork = .{};
    disposeSubtreeImpl(Row, scopes, scope_id, retirement_generation, hooks, &work);
}

/// Disposes a scope subtree like `disposeSubtree` and exposes exact topology
/// work for invariant tests and native observability seams.
pub fn disposeSubtreeMeasured(comptime Row: type, scopes: []scope_tree.Scope(Row), scope_id: semantic_ids.ScopeId, retirement_generation: scope_tree.Generation, hooks: anytype, work: *SubtreeTraversalWork) void {
    disposeSubtreeImpl(Row, scopes, scope_id, retirement_generation, hooks, work);
}

fn disposeSubtreeImpl(comptime Row: type, scopes: []scope_tree.Scope(Row), scope_id: semantic_ids.ScopeId, retirement_generation: scope_tree.Generation, hooks: anytype, work: *SubtreeTraversalWork) void {
    if (scope_id.index() >= scopes.len) @panic("scope disposal referenced an unknown scope");
    if (scopes[scope_id.index()].scope_id != scope_id or !scopes[scope_id.index()].lifecycle.isActive()) @panic("scope id has no host scope descriptor");
    work.scope_visits += 1;

    while (scopes[scope_id.index()].first_child_scope_id) |child_scope_id| {
        work.child_links_followed += 1;
        disposeSubtreeImpl(Row, scopes, child_scope_id, retirement_generation, hooks, work);
    }

    hooks.deactivateNodeIdentities(scope_id);
    hooks.appendCleanupEvents(scope_id);
    hooks.deactivateDomIdentities(scope_id);

    const scope = &scopes[scope_id.index()];
    switch (scope.step) {
        .each_row => |row| hooks.removeEachRow(scope.scope_id, row.key_hash, row.row_handle),
        .root, .component, .when_branch => {},
    }
    hooks.deinitScopeStep(&scope.step);
    scope_tree.retireScopeAssumeValid(Row, scopes, scope_id, retirement_generation);
    hooks.recordScopeDisposed();
}

/// Owns the exact post-order scope ids selected for deferred subtree retirement.
/// Preparation is fallible and read-only; applying metadata is allocation-free
/// and intentionally does not release step-owned resources.
pub const PreparedSubtreeRetirement = struct {
    scope_ids: []semantic_ids.ScopeId,
    work: SubtreeTraversalWork,

    /// Releases preparation storage without changing live scopes.
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.scope_ids);
        self.* = undefined;
    }

    /// Marks the prepared subtree inactive after replacement publication.
    pub fn applyMetadata(self: *const @This(), comptime Row: type, scopes: []scope_tree.Scope(Row), retirement_generation: scope_tree.Generation) void {
        for (self.scope_ids) |scope_id| {
            scope_tree.retireScopeAssumeValid(Row, scopes, scope_id, retirement_generation);
        }
    }
};

/// Prepares a stable post-order scope-subtree snapshot without mutating scopes.
pub fn prepareSubtreeRetirement(comptime Row: type, allocator: std.mem.Allocator, scopes: []const scope_tree.Scope(Row), root_scope_id: semantic_ids.ScopeId) std.mem.Allocator.Error!PreparedSubtreeRetirement {
    if (root_scope_id.index() >= scopes.len or scopes[root_scope_id.index()].scope_id != root_scope_id or !scopes[root_scope_id.index()].lifecycle.isActive()) return error.OutOfMemory;
    var work: SubtreeTraversalWork = .{};
    const scope_count = try countSubtree(Row, scopes, root_scope_id, &work);
    const scope_ids = try allocator.alloc(semantic_ids.ScopeId, scope_count);
    var cursor: usize = 0;
    appendSubtreePostOrder(Row, scopes, root_scope_id, scope_ids, &cursor, &work);
    std.debug.assert(cursor == scope_ids.len);
    return .{ .scope_ids = scope_ids, .work = work };
}

/// Prepares disjoint scope subtrees as one stable post-order retirement journal.
pub fn prepareSubtreesRetirement(comptime Row: type, allocator: std.mem.Allocator, scopes: []const scope_tree.Scope(Row), root_scope_ids: []const semantic_ids.ScopeId) (std.mem.Allocator.Error || error{OverlappingSubtrees})!PreparedSubtreeRetirement {
    var work: SubtreeTraversalWork = .{};
    // Root membership is keyed by the retiring roots, not by every scope, so
    // retiring a few subtrees of a large tree reserves by the request size.
    var is_root: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer is_root.deinit(allocator);
    try is_root.ensureTotalCapacity(allocator, std.math.cast(u32, root_scope_ids.len) orelse return error.OutOfMemory);
    for (root_scope_ids) |root_scope_id| {
        work.validation_roots_checked += 1;
        if (root_scope_id.index() >= scopes.len or scopes[root_scope_id.index()].scope_id != root_scope_id or !scopes[root_scope_id.index()].lifecycle.isActive()) return error.OverlappingSubtrees;
        if (is_root.contains(root_scope_id.index())) return error.OverlappingSubtrees;
        is_root.putAssumeCapacityNoClobber(root_scope_id.index(), {});
    }
    for (root_scope_ids) |root_scope_id| {
        var ancestor = scopes[root_scope_id.index()].parent_scope_id;
        while (ancestor) |ancestor_scope_id| {
            work.validation_parent_links_followed += 1;
            if (ancestor_scope_id.index() >= scopes.len or scopes[ancestor_scope_id.index()].scope_id != ancestor_scope_id) return error.OverlappingSubtrees;
            if (is_root.contains(ancestor_scope_id.index())) return error.OverlappingSubtrees;
            ancestor = scopes[ancestor_scope_id.index()].parent_scope_id;
        }
    }

    var scope_count: usize = 0;
    for (root_scope_ids) |root_scope_id| {
        scope_count = std.math.add(usize, scope_count, try countSubtree(Row, scopes, root_scope_id, &work)) catch return error.OutOfMemory;
    }
    const scope_ids = try allocator.alloc(semantic_ids.ScopeId, scope_count);
    var cursor: usize = 0;
    for (root_scope_ids) |root_scope_id| appendSubtreePostOrder(Row, scopes, root_scope_id, scope_ids, &cursor, &work);
    std.debug.assert(cursor == scope_ids.len);
    return .{ .scope_ids = scope_ids, .work = work };
}

fn countSubtree(comptime Row: type, scopes: []const scope_tree.Scope(Row), scope_id: semantic_ids.ScopeId, work: *SubtreeTraversalWork) std.mem.Allocator.Error!usize {
    work.scope_visits += 1;
    var count: usize = 1;
    var child_scope_id = scopes[scope_id.index()].first_child_scope_id;
    while (child_scope_id) |child_id| {
        work.child_links_followed += 1;
        count = std.math.add(usize, count, try countSubtree(Row, scopes, child_id, work)) catch return error.OutOfMemory;
        child_scope_id = scopes[child_id.index()].next_sibling_scope_id;
    }
    return count;
}

fn appendSubtreePostOrder(comptime Row: type, scopes: []const scope_tree.Scope(Row), scope_id: semantic_ids.ScopeId, scope_ids: []semantic_ids.ScopeId, cursor: *usize, work: *SubtreeTraversalWork) void {
    work.scope_visits += 1;
    var child_scope_id = scopes[scope_id.index()].first_child_scope_id;
    while (child_scope_id) |child_id| {
        work.child_links_followed += 1;
        appendSubtreePostOrder(Row, scopes, child_id, scope_ids, cursor, work);
        child_scope_id = scopes[child_id.index()].next_sibling_scope_id;
    }
    scope_ids[cursor.*] = scope_id;
    cursor.* += 1;
}

const TestRow = struct {
    site_ordinal: semantic_ids.SiteOrdinal,
    key_hash: u64,
    row_handle: row_handles.RowHandleId,
};

const TestDisposeHooks = struct {
    node_deactivations: shared_buffer.List(semantic_ids.ScopeId) = .empty,
    cleanup_events: shared_buffer.List(semantic_ids.ScopeId) = .empty,
    dom_deactivations: shared_buffer.List(semantic_ids.ScopeId) = .empty,
    removed_rows: shared_buffer.List(u64) = .empty,
    removed_handles: shared_buffer.List(row_handles.RowHandleId) = .empty,
    deinit_steps: u64 = 0,
    disposed_scopes: u64 = 0,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.node_deactivations.deinit(allocator);
        self.cleanup_events.deinit(allocator);
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
    var scopes: shared_buffer.List(scope_tree.Scope(TestRow)) = .empty;
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
    var scopes: shared_buffer.List(scope_tree.Scope(TestRow)) = .empty;
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
    var scopes: shared_buffer.List(scope_tree.Scope(TestRow)) = .empty;
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
    try std.testing.expectError(error.OverlappingSubtrees, prepareSubtreesRetirement(TestRow, std.testing.allocator, scopes.items, &.{ semantic_ids.ScopeId.fromRaw(4), semantic_ids.ScopeId.fromRaw(4) }));
    for (scopes.items) |scope| try std.testing.expect(scope.lifecycle.isActive());
}

test "scope subtree work ignores ten thousand unrelated scopes and retries after OOM" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var scopes: shared_buffer.List(scope_tree.Scope(TestRow)) = .empty;
    defer scopes.deinit(std.testing.allocator);
    _ = try scope_tree.internRoot(TestRow, std.testing.allocator, &scopes);

    const target = (try scope_tree.appendFreshEachRow(TestRow, std.testing.allocator, &scopes, semantic_ids.root_scope, .{
        .site_ordinal = semantic_ids.SiteOrdinal.fromRaw(1),
        .key_hash = 1,
        .row_handle = row_handles.RowHandleId.fromRaw(0x0000_0001_0000_0001),
    })).scope_id;
    const target_child = (try scope_tree.internComponent(TestRow, std.testing.allocator, &scopes, target, semantic_ids.SiteOrdinal.fromRaw(1), semantic_ids.initial_generation)).scope_id;
    const target_grandchild = (try scope_tree.appendFreshEachRow(TestRow, std.testing.allocator, &scopes, target_child, .{
        .site_ordinal = semantic_ids.SiteOrdinal.fromRaw(2),
        .key_hash = 2,
        .row_handle = row_handles.RowHandleId.fromRaw(0x0000_0001_0000_0002),
    })).scope_id;

    var unrelated_index: usize = 0;
    while (unrelated_index < 10_000) : (unrelated_index += 1) {
        _ = try scope_tree.appendFreshEachRow(TestRow, std.testing.allocator, &scopes, semantic_ids.root_scope, .{
            .site_ordinal = semantic_ids.SiteOrdinal.fromRaw(@intCast(unrelated_index + 10)),
            .key_hash = unrelated_index + 10,
            .row_handle = row_handles.RowHandleId.fromRaw(0x0000_0001_0000_0003),
        });
    }

    var baseline_fault = FaultAllocator.init(std.testing.allocator);
    var baseline = try prepareSubtreeRetirement(TestRow, baseline_fault.allocator(), scopes.items, target);
    try std.testing.expectEqual(@as(usize, 1), baseline_fault.attempts);
    try std.testing.expectEqualSlices(semantic_ids.ScopeId, &.{ target_grandchild, target_child, target }, baseline.scope_ids);
    try std.testing.expectEqual(@as(usize, 6), baseline.work.scope_visits);
    try std.testing.expectEqual(@as(usize, 4), baseline.work.child_links_followed);
    try std.testing.expectEqual(@as(usize, 0), baseline.work.validation_parent_links_followed);
    baseline.deinit(baseline_fault.allocator());

    var fault = FaultAllocator.init(std.testing.allocator);
    fault.configure(1);
    try std.testing.expectError(error.OutOfMemory, prepareSubtreeRetirement(TestRow, fault.allocator(), scopes.items, target));
    for (scopes.items) |scope| try std.testing.expect(scope.lifecycle.isActive());

    fault.configure(null);
    var retry = try prepareSubtreeRetirement(TestRow, fault.allocator(), scopes.items, target);
    defer retry.deinit(fault.allocator());
    retry.applyMetadata(TestRow, scopes.items, semantic_ids.Generation.fromRaw(11));
    try std.testing.expect(!scopes.items[target.index()].lifecycle.isActive());
    try std.testing.expect(!scopes.items[target_child.index()].lifecycle.isActive());
    try std.testing.expect(!scopes.items[target_grandchild.index()].lifecycle.isActive());
    try std.testing.expect(scopes.items[semantic_ids.ScopeId.fromRaw(4).index()].lifecycle.isActive());
    try std.testing.expectEqual(@as(?semantic_ids.ScopeId, semantic_ids.ScopeId.fromRaw(4)), scopes.items[semantic_ids.root_scope.index()].first_child_scope_id);
}

test "ten thousand flat retirement roots validate with linear indexed work and retry after every allocation failure" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var scopes: shared_buffer.List(scope_tree.Scope(TestRow)) = .empty;
    defer scopes.deinit(std.testing.allocator);
    _ = try scope_tree.internRoot(TestRow, std.testing.allocator, &scopes);

    var roots: shared_buffer.List(semantic_ids.ScopeId) = .empty;
    defer roots.deinit(std.testing.allocator);
    try roots.ensureTotalCapacity(std.testing.allocator, 10_000);
    for (0..10_000) |index| {
        const row = try scope_tree.appendFreshEachRow(TestRow, std.testing.allocator, &scopes, semantic_ids.root_scope, .{
            .site_ordinal = semantic_ids.SiteOrdinal.fromRaw(@intCast(index + 1)),
            .key_hash = index,
            .row_handle = row_handles.RowHandleId.fromRaw(@intCast(0x0000_0001_0000_0001 + index)),
        });
        roots.appendAssumeCapacity(row.scope_id);
    }

    var baseline_fault = FaultAllocator.init(std.testing.allocator);
    var baseline = try prepareSubtreesRetirement(TestRow, baseline_fault.allocator(), scopes.items, roots.items);
    const attempts = baseline_fault.attempts;
    try std.testing.expectEqual(@as(usize, 2), attempts);
    try std.testing.expectEqual(@as(usize, 10_000), baseline.scope_ids.len);
    try std.testing.expectEqual(@as(usize, 10_000), baseline.work.validation_roots_checked);
    try std.testing.expectEqual(@as(usize, 10_000), baseline.work.validation_parent_links_followed);
    try std.testing.expectEqual(@as(usize, 20_000), baseline.work.scope_visits);
    try std.testing.expectEqual(@as(usize, 0), baseline.work.child_links_followed);
    baseline.deinit(baseline_fault.allocator());

    for (1..attempts + 1) |fail_at| {
        var fault = FaultAllocator.init(std.testing.allocator);
        fault.configure(fail_at);
        try std.testing.expectError(error.OutOfMemory, prepareSubtreesRetirement(TestRow, fault.allocator(), scopes.items, roots.items));
        for (scopes.items) |scope| try std.testing.expect(scope.lifecycle.isActive());
    }

    var retry_fault = FaultAllocator.init(std.testing.allocator);
    var retry = try prepareSubtreesRetirement(TestRow, retry_fault.allocator(), scopes.items, roots.items);
    defer retry.deinit(retry_fault.allocator());
    try std.testing.expectEqualSlices(semantic_ids.ScopeId, roots.items, retry.scope_ids);
}

test "measured immediate subtree disposal follows only descendant links" {
    var scopes: shared_buffer.List(scope_tree.Scope(TestRow)) = .empty;
    defer scopes.deinit(std.testing.allocator);
    _ = try scope_tree.internRoot(TestRow, std.testing.allocator, &scopes);
    const target = (try scope_tree.appendFreshEachRow(TestRow, std.testing.allocator, &scopes, semantic_ids.root_scope, .{
        .site_ordinal = semantic_ids.SiteOrdinal.fromRaw(1),
        .key_hash = 1,
        .row_handle = row_handles.RowHandleId.fromRaw(0x0000_0001_0000_0001),
    })).scope_id;
    _ = try scope_tree.internComponent(TestRow, std.testing.allocator, &scopes, target, semantic_ids.SiteOrdinal.fromRaw(1), semantic_ids.initial_generation);
    var unrelated_index: usize = 0;
    while (unrelated_index < 10_000) : (unrelated_index += 1) {
        _ = try scope_tree.appendFreshEachRow(TestRow, std.testing.allocator, &scopes, semantic_ids.root_scope, .{
            .site_ordinal = semantic_ids.SiteOrdinal.fromRaw(@intCast(unrelated_index + 10)),
            .key_hash = unrelated_index + 10,
            .row_handle = row_handles.RowHandleId.fromRaw(0x0000_0001_0000_0002),
        });
    }

    var hooks = TestDisposeHooks{};
    defer hooks.deinit(std.testing.allocator);
    var work: SubtreeTraversalWork = .{};
    disposeSubtreeMeasured(TestRow, scopes.items, target, semantic_ids.Generation.fromRaw(12), &hooks, &work);
    try std.testing.expectEqual(@as(usize, 2), work.scope_visits);
    try std.testing.expectEqual(@as(usize, 1), work.child_links_followed);
    try std.testing.expectEqual(@as(u64, 2), hooks.disposed_scopes);
    try std.testing.expect(scopes.items[semantic_ids.ScopeId.fromRaw(3).index()].lifecycle.isActive());
}

test "scope runtime owns stable each-row handle and key hash" {
    var scopes: shared_buffer.List(Scope) = .empty;
    defer scopes.deinit(std.testing.allocator);

    _ = try scope_tree.internRoot(EachRowScopeStep, std.testing.allocator, &scopes);

    const handle = row_handles.RowHandleId.fromRaw(0x0000_0005_0000_0009);
    const row = try appendEachRow(std.testing.allocator, &scopes, semantic_ids.root_scope, semantic_ids.SiteOrdinal.fromRaw(7), 42, handle, semantic_ids.initial_generation);

    try std.testing.expectEqual(semantic_ids.ScopeId.fromRaw(1), row.scope_id);
    try std.testing.expectEqual(@as(u64, 42), eachRowKeyHash(scopes.items, row.scope_id));
    try std.testing.expectEqual(handle, eachRowHandle(scopes.items, row.scope_id));
}
