//! Immutable collection generations and transaction-local keyed-row bindings.
//!
//! A generation owns exactly one opaque Roc collection cell. Stable keys and
//! order belong to the engine's committed Rows site, while row handles resolve through generation IDs,
//! never pointers, so moving generation storage cannot create dangling row
//! bindings. A candidate binding overlay owns only its hash table; the
//! generation transaction remains responsible for keeping every referenced
//! old and candidate generation alive until commit or abort completes.

const std = @import("std");
const abi = @import("roc_platform_abi.zig");
const each_collection = @import("each_collection.zig");
const retained = @import("retained_values.zig");
const row_handles = @import("row_handles.zig");

pub const HostValue = retained.HostValue;
pub const HostValueCapability = retained.HostValueCapability;
pub const HostValueCell = retained.HostValueCell;
pub const HostEachOps = retained.HostEachOps;
pub const KeyStorage = each_collection.KeyStorage;
pub const SnapshotStorage = each_collection.SnapshotStorage;
pub const RowHandleId = row_handles.RowHandleId;

/// Nonzero, non-wrapping identity of one immutable list generation.
pub const GenerationId = enum(u64) {
    _,

    /// Constructs an identity at a validated internal boundary.
    pub fn fromRaw(raw_value: u64) GenerationId {
        return @enumFromInt(raw_value);
    }

    /// Returns the integer representation used by engine indexes.
    pub fn raw(self: GenerationId) u64 {
        return @intFromEnum(self);
    }

    /// Reports whether this value is a valid minted generation identity.
    pub fn isValid(self: GenerationId) bool {
        return self.raw() != 0;
    }
};

/// Monotonic source of list-generation identities.
pub const GenerationClock = struct {
    next: u64 = 1,
    exhausted: bool = false,

    /// Mints the next identity without ever returning zero or wrapping.
    pub fn mint(self: *GenerationClock) error{ResourceLimit}!GenerationId {
        if (self.exhausted or self.next == 0) return error.ResourceLimit;
        const id = GenerationId.fromRaw(self.next);
        if (self.next == std.math.maxInt(u64)) {
            self.exhausted = true;
        } else {
            self.next += 1;
        }
        return id;
    }
};

/// One site-owned immutable collection generation.
pub const Generation = struct {
    id: GenerationId,
    rows_generation: u64,
    collection: HostValueCell,
    ops: HostEachOps,
    item_count: usize,
    live: bool = true,

    /// Adopts one independently owned collection value and retains the typed
    /// operations needed to read stable item slots from this generation later.
    /// The function retains the operations' collection capability as the
    /// cell's ownership edge and retains every typed operation separately.
    pub fn initOwned(id: GenerationId, rows_generation: u64, collection: HostValue, ops: HostEachOps, item_count: usize, metrics: anytype) error{InvalidGeneration}!Generation {
        if (!id.isValid() or rows_generation == 0) return error.InvalidGeneration;
        return .{
            .id = id,
            .rows_generation = rows_generation,
            .collection = HostValueCell.initRetained(collection, ops.rows_capability, metrics),
            .ops = retained.retainHostEachOps(ops, metrics),
            .item_count = item_count,
        };
    }

    /// Releases the opaque Roc collection and retained typed operations exactly once.
    pub fn deinit(self: *Generation, allocator: std.mem.Allocator, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype) void {
        _ = allocator;
        if (!self.live) @panic("each generation deinitialized twice");
        self.collection.deinit(ctx, roc_host, metrics);
        retained.releaseHostEachOps(self.ops, roc_host, metrics);
        self.live = false;
    }
};

/// Current immutable collection location for one stable row handle.
pub const RowBinding = struct {
    generation_id: GenerationId,
    item_slot: u64,

    /// Validates the binding's nonzero generation identity.
    pub fn validate(self: RowBinding) error{InvalidGeneration}!void {
        if (!self.generation_id.isValid()) return error.InvalidGeneration;
    }
};

/// Transaction-local location of a key in one prepared collection's
/// host-owned key arenas. It is meaningful only while the matching candidate
/// generation and its prepared inputs are active.
pub const CandidateKeyLocator = union(enum) {
    snapshot: usize,
    delta: usize,
};

pub const CandidateEntry = struct {
    binding: ?RowBinding,
    key_locator: ?CandidateKeyLocator,
};

pub const BindingTable = struct {
    entries: std.AutoHashMapUnmanaged(RowHandleId, RowBinding) = .empty,
    reserved_entries: usize = 0,

    /// Releases host-owned index storage; bindings own no generations.
    pub fn deinit(self: *BindingTable, allocator: std.mem.Allocator) void {
        std.debug.assert(self.reserved_entries == 0);
        self.entries.deinit(allocator);
        self.* = .{};
    }

    /// Returns the committed binding for an exact live handle.
    pub fn get(self: *const BindingTable, row_handle: RowHandleId) ?RowBinding {
        return self.entries.get(row_handle);
    }
};

const OverlayPhase = enum { preparing, committed };

/// Candidate row-binding edits for one structural transaction.
///
/// A staged null binding is an explicit removal, so candidate lookup never
/// falls through to stale committed state for a retired row. Commit applies
/// preflighted edits without allocation; abort simply destroys the edit table.
/// Neither path releases a generation, because the enclosing transaction owns
/// generation lifetimes.
pub const CandidateBindings = struct {
    allocator: std.mem.Allocator,
    candidate: std.AutoHashMapUnmanaged(RowHandleId, CandidateEntry) = .empty,
    phase: OverlayPhase = .preparing,
    commit_preflighted: bool = false,
    reservation_table: ?*BindingTable = null,
    reserved_entries: usize = 0,

    /// Starts an empty candidate edit table.
    pub fn init(allocator: std.mem.Allocator) CandidateBindings {
        return .{ .allocator = allocator };
    }

    /// Reserves the maximum edit count before bindings are staged.
    pub fn reserve(self: *CandidateBindings, row_count: usize) (std.mem.Allocator.Error || error{ResourceLimit})!void {
        if (self.phase != .preparing) @panic("committed each binding overlay cannot reserve");
        try self.candidate.ensureTotalCapacity(self.allocator, std.math.cast(u32, row_count) orelse return error.ResourceLimit);
    }

    /// Stages one exact row binding using already-reserved capacity.
    pub fn putAssumeCapacity(self: *CandidateBindings, row_handle: RowHandleId, binding: RowBinding, key_locator: CandidateKeyLocator) error{ InvalidGeneration, DuplicateRowHandle }!void {
        if (self.phase != .preparing) @panic("committed each binding overlay cannot stage");
        try binding.validate();
        const entry = self.candidate.getOrPutAssumeCapacity(row_handle);
        if (entry.found_existing) return error.DuplicateRowHandle;
        entry.value_ptr.* = .{ .binding = binding, .key_locator = key_locator };
    }

    /// Stages explicit row retirement so preparation cannot fall back to the
    /// row's committed generation.
    pub fn removeAssumeCapacity(self: *CandidateBindings, row_handle: RowHandleId) error{DuplicateRowHandle}!void {
        if (self.phase != .preparing) @panic("committed each binding overlay cannot stage");
        const entry = self.candidate.getOrPutAssumeCapacity(row_handle);
        if (entry.found_existing) return error.DuplicateRowHandle;
        entry.value_ptr.* = .{ .binding = null, .key_locator = null };
    }

    /// Resolves candidate state first, then committed state. This is the lookup
    /// law used by delayed structural builders during transaction preparation.
    pub fn resolve(self: *const CandidateBindings, committed: *const BindingTable, row_handle: RowHandleId) ?RowBinding {
        if (self.candidate.get(row_handle)) |candidate| return candidate.binding;
        return committed.get(row_handle);
    }

    /// Returns the locator for a staged live binding without exposing key bytes.
    pub fn keyLocator(self: *const CandidateBindings, row_handle: RowHandleId) ?CandidateKeyLocator {
        const entry = self.candidate.get(row_handle) orelse return null;
        if (entry.binding == null) return null;
        return entry.key_locator orelse @panic("candidate row binding lacked its key locator");
    }

    /// Reserves every possible inserted edit alongside all sibling overlays.
    /// The table must remain at a stable address until this overlay commits or
    /// is destroyed. Repeated preflight replaces this overlay's reservation.
    pub fn preflightCommit(self: *CandidateBindings, committed: *BindingTable) (std.mem.Allocator.Error || error{ResourceLimit})!void {
        if (self.phase != .preparing) @panic("committed each binding overlay cannot preflight");
        if (self.reservation_table) |table| std.debug.assert(table == committed);
        const siblings = committed.reserved_entries - self.reserved_entries;
        const reserved = std.math.add(usize, siblings, self.candidate.count()) catch return error.ResourceLimit;
        const maximum = std.math.add(usize, committed.entries.count(), reserved) catch return error.ResourceLimit;
        try committed.entries.ensureTotalCapacity(self.allocator, std.math.cast(u32, maximum) orelse return error.ResourceLimit);
        committed.reserved_entries = reserved;
        self.reserved_entries = self.candidate.count();
        self.reservation_table = committed;
        self.commit_preflighted = true;
    }

    /// Publishes every prepared edit without allocation.
    pub fn commit(self: *CandidateBindings, committed: *BindingTable) void {
        if (self.phase != .preparing) @panic("each binding overlay committed twice");
        if (!self.commit_preflighted) @panic("each binding overlay committed before preflight");
        std.debug.assert(self.reservation_table == committed);
        std.debug.assert(self.candidate.count() <= self.reserved_entries);
        // Retire old handles before publishing replacements. Besides matching
        // the generation transition, this keeps the allocation-free commit
        // within the preflighted final binding bound when one batch removes
        // and creates rows together.
        var removals = self.candidate.iterator();
        while (removals.next()) |entry| if (entry.value_ptr.binding == null) {
            _ = committed.entries.remove(entry.key_ptr.*);
        };
        var insertions = self.candidate.iterator();
        while (insertions.next()) |entry| if (entry.value_ptr.binding) |binding| {
            committed.entries.putAssumeCapacity(entry.key_ptr.*, binding);
        };
        self.phase = .committed;
        self.releaseReservation();
    }

    fn releaseReservation(self: *CandidateBindings) void {
        if (self.reservation_table) |table| {
            table.reserved_entries -= self.reserved_entries;
            self.reservation_table = null;
            self.reserved_entries = 0;
        }
    }

    /// Releases candidate edit storage after commit or abort.
    pub fn deinit(self: *CandidateBindings) void {
        self.releaseReservation();
        self.candidate.deinit(self.allocator);
        self.* = undefined;
    }
};

var test_drop_count: usize = 0;

fn testCallable(_: *abi.RocHost, _: ?[*]u8, _: ?[*]const u8, _: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {}

fn testDrop(_: *abi.RocHost, _: ?[*]u8, _: ?[*]const u8, _: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    test_drop_count += 1;
}

const TestCtx = struct {
    /// Accepts a capability frame for ownership-focused tests.
    pub fn pushHostValueCapabilities(_: *@This(), _: []const HostValueCapability) void {}
    /// Closes the capability frame opened by the test fixture.
    pub fn popHostValueCapabilities(_: *@This()) void {}
};

const TestMetrics = struct {
    retains: u64 = 0,
    releases: u64 = 0,
    /// Records retained and released test callables.
    pub fn bump(self: *@This(), comptime field: anytype, count: u64) void {
        if (field == .closure_retains) self.retains += count;
        if (field == .closure_releases) self.releases += count;
    }
};

fn completedKeys(allocator: std.mem.Allocator, values: []const []const u8) !KeyStorage {
    var keys = KeyStorage{};
    errdefer keys.deinit(allocator);
    var sink = try keys.prepare(allocator, values.len, 1024);
    var active = each_collection.ActiveSinks{};
    const token = try active.activateKey(&sink);
    for (values, 0..) |value, index| try active.pushKeyBorrowed(token, index, value);
    active.finishKey(token) catch |err| switch (err) {
        error.RetryRequired => {
            var retry = try keys.beginRetry(allocator);
            const retry_token = try active.activateKey(&retry);
            for (values, 0..) |value, index| try active.pushKeyBorrowed(retry_token, index, value);
            try active.finishKey(retry_token);
        },
        else => return err,
    };
    return keys;
}

test "generation owns one collection cell and exact host keys" {
    var env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&env);
    const ordinary = abi.rocErasedCallableAllocate(&roc_host, testCallable, null, 0).?;
    defer abi.decrefErasedCallable(ordinary, &roc_host);
    const drop = abi.rocErasedCallableAllocate(&roc_host, testDrop, null, 0).?;
    defer abi.decrefErasedCallable(drop, &roc_host);
    const cap = HostValueCapability{ .clone = ordinary, .drop = drop, .eq = ordinary };
    const ops = std.mem.zeroInit(HostEachOps, .{
        .clone_item = ordinary,
        .compare_slots = ordinary,
        .copy_delta = ordinary,
        .copy_snapshot = ordinary,
        .describe = ordinary,
        .item_capability = cap,
        .rows_capability = cap,
        .row = ordinary,
    });
    var metrics = TestMetrics{};
    var ctx = TestCtx{};
    var snapshot: SnapshotStorage = .{};
    defer snapshot.deinit(std.testing.allocator);
    var snapshot_sink = try snapshot.prepare(std.testing.allocator, 2, 9);
    try snapshot_sink.pushBorrowed(0, 101, "alpha");
    try snapshot_sink.pushBorrowed(1, 202, "beta");
    try snapshot_sink.finish();
    test_drop_count = 0;
    var generation = try Generation.initOwned(GenerationId.fromRaw(9), 900, HostValue.fromRaw(77), ops, 2, &metrics);
    try std.testing.expectEqualStrings("alpha", snapshot.keys.key(0).?);
    try std.testing.expectEqual(@as(u64, 202), snapshot.rows.items[1].slot);
    generation.deinit(std.testing.allocator, &ctx, &roc_host, &metrics);
    try std.testing.expectEqual(@as(usize, 1), test_drop_count);
    try std.testing.expectEqual(@as(u64, 15), metrics.retains);
    try std.testing.expectEqual(metrics.retains, metrics.releases);
}

test "candidate bindings override committed rows for delayed reads" {
    const row = RowHandleId.fromRaw(0x0000_0001_0000_0001);
    const old = RowBinding{ .generation_id = GenerationId.fromRaw(4), .item_slot = 2 };
    const next = RowBinding{ .generation_id = GenerationId.fromRaw(5), .item_slot = 7 };
    var committed = BindingTable{};
    defer committed.deinit(std.testing.allocator);
    try committed.entries.put(std.testing.allocator, row, old);
    var overlay = CandidateBindings.init(std.testing.allocator);
    defer overlay.deinit();
    try overlay.reserve(1);
    try overlay.putAssumeCapacity(row, next, .{ .snapshot = 0 });

    try std.testing.expectEqual(next, overlay.resolve(&committed, row).?);
    try overlay.preflightCommit(&committed);
    overlay.commit(&committed);
    try std.testing.expectEqual(next, committed.get(row).?);
}

test "sibling candidate bindings reserve cumulative commit capacity" {
    const allocator = std.testing.allocator;
    var committed = BindingTable{};
    defer committed.deinit(allocator);
    var overlays: [16]CandidateBindings = undefined;
    for (&overlays) |*overlay| overlay.* = CandidateBindings.init(allocator);
    defer for (&overlays) |*overlay| overlay.deinit();
    for (&overlays, 0..) |*overlay, index| {
        try overlay.reserve(1);
        try overlay.putAssumeCapacity(RowHandleId.fromRaw(index + 1), .{
            .generation_id = GenerationId.fromRaw(index + 1),
            .item_slot = 0,
        }, .{ .snapshot = 0 });
        try overlay.preflightCommit(&committed);
    }
    for (&overlays) |*overlay| overlay.commit(&committed);
    try std.testing.expectEqual(@as(usize, overlays.len), committed.entries.count());
    try std.testing.expectEqual(@as(usize, 0), committed.reserved_entries);
}

test "candidate binding reservation survives refusal and releases on abort" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    var committed = BindingTable{};
    defer committed.deinit(allocator);
    var first = CandidateBindings.init(allocator);
    defer first.deinit();
    try first.reserve(1);
    try first.putAssumeCapacity(RowHandleId.fromRaw(1), .{
        .generation_id = GenerationId.fromRaw(1),
        .item_slot = 0,
    }, .{ .snapshot = 0 });
    try first.preflightCommit(&committed);
    try first.preflightCommit(&committed);
    try std.testing.expectEqual(@as(usize, 1), committed.reserved_entries);

    var sibling = CandidateBindings.init(allocator);
    try sibling.reserve(64);
    for (0..64) |index| try sibling.putAssumeCapacity(RowHandleId.fromRaw(index + 2), .{
        .generation_id = GenerationId.fromRaw(2),
        .item_slot = index,
    }, .{ .snapshot = index });
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, sibling.preflightCommit(&committed));
    try std.testing.expectEqual(@as(usize, 1), committed.reserved_entries);
    failing.fail_index = std.math.maxInt(usize);
    try sibling.preflightCommit(&committed);
    try std.testing.expectEqual(@as(usize, 65), committed.reserved_entries);
    sibling.deinit();
    try std.testing.expectEqual(@as(usize, 1), committed.reserved_entries);
    failing.fail_index = failing.alloc_index;
    first.commit(&committed);
    try std.testing.expectEqual(@as(usize, 0), committed.reserved_entries);
    try std.testing.expectEqual(@as(usize, 1), committed.entries.count());
}

test "candidate key locators remain transaction local across commit and abort" {
    const row = RowHandleId.fromRaw(0x0000_0001_0000_0001);
    var committed = BindingTable{};
    defer committed.deinit(std.testing.allocator);

    var committed_overlay = CandidateBindings.init(std.testing.allocator);
    defer committed_overlay.deinit();
    try committed_overlay.reserve(1);
    try committed_overlay.putAssumeCapacity(row, .{ .generation_id = GenerationId.fromRaw(2), .item_slot = 7 }, .{ .delta = 3 });
    try std.testing.expectEqual(CandidateKeyLocator{ .delta = 3 }, committed_overlay.keyLocator(row).?);
    try committed_overlay.preflightCommit(&committed);
    committed_overlay.commit(&committed);
    try std.testing.expectEqual(@as(u64, 7), committed.get(row).?.item_slot);

    var aborted = CandidateBindings.init(std.testing.allocator);
    try aborted.reserve(1);
    const other = RowHandleId.fromRaw(0x0000_0001_0000_0002);
    try aborted.putAssumeCapacity(other, .{ .generation_id = GenerationId.fromRaw(3), .item_slot = 9 }, .{ .snapshot = 4 });
    try std.testing.expectEqual(CandidateKeyLocator{ .snapshot = 4 }, aborted.keyLocator(other).?);
    aborted.deinit();
    try std.testing.expect(committed.get(other) == null);
}

test "aborted candidate bindings leave committed rows readable" {
    const row = RowHandleId.fromRaw(0x0000_0001_0000_0001);
    const old = RowBinding{ .generation_id = GenerationId.fromRaw(10), .item_slot = 1 };
    var committed = BindingTable{};
    defer committed.deinit(std.testing.allocator);
    try committed.entries.put(std.testing.allocator, row, old);
    var overlay = CandidateBindings.init(std.testing.allocator);
    try overlay.reserve(1);
    try overlay.putAssumeCapacity(row, .{ .generation_id = GenerationId.fromRaw(11), .item_slot = 9 }, .{ .snapshot = 0 });
    overlay.deinit();

    try std.testing.expectEqual(old, committed.get(row).?);
}

test "candidate bindings reject duplicates and invalid generations" {
    const row = RowHandleId.fromRaw(0x0000_0001_0000_0001);
    var overlay = CandidateBindings.init(std.testing.allocator);
    defer overlay.deinit();
    try overlay.reserve(2);
    try std.testing.expectError(error.InvalidGeneration, overlay.putAssumeCapacity(row, .{ .generation_id = GenerationId.fromRaw(0), .item_slot = 1 }, .{ .snapshot = 0 }));
    try overlay.putAssumeCapacity(row, .{ .generation_id = GenerationId.fromRaw(1), .item_slot = 1 }, .{ .snapshot = 0 });
    try std.testing.expectError(error.DuplicateRowHandle, overlay.putAssumeCapacity(row, .{ .generation_id = GenerationId.fromRaw(1), .item_slot = 2 }, .{ .snapshot = 1 }));
}

test "candidate removal masks committed binding before and after commit" {
    const row = RowHandleId.fromRaw(0x0000_0001_0000_0001);
    var committed = BindingTable{};
    defer committed.deinit(std.testing.allocator);
    try committed.entries.put(std.testing.allocator, row, .{ .generation_id = GenerationId.fromRaw(3), .item_slot = 4 });
    var overlay = CandidateBindings.init(std.testing.allocator);
    defer overlay.deinit();
    try overlay.reserve(1);
    try overlay.removeAssumeCapacity(row);
    try std.testing.expect(overlay.resolve(&committed, row) == null);
    try overlay.preflightCommit(&committed);
    overlay.commit(&committed);
    try std.testing.expect(committed.get(row) == null);
}

test "generation identity mints maximum once and never wraps" {
    var clock = GenerationClock{ .next = std.math.maxInt(u64) - 1 };
    try std.testing.expectEqual(std.math.maxInt(u64) - 1, (try clock.mint()).raw());
    try std.testing.expectEqual(std.math.maxInt(u64), (try clock.mint()).raw());
    try std.testing.expectError(error.ResourceLimit, clock.mint());
}

test "shared immutable Rows token keeps distinct engine publication identities" {
    var clock = GenerationClock{};
    const first = try clock.mint();
    const second = try clock.mint();
    const shared_rows_generation: u64 = 0xCAFE;
    try std.testing.expect(first != second);
    try std.testing.expectEqual(shared_rows_generation, shared_rows_generation);
    var registry: std.AutoHashMapUnmanaged(GenerationId, u64) = .empty;
    defer registry.deinit(std.testing.allocator);
    try registry.put(std.testing.allocator, first, shared_rows_generation);
    try registry.put(std.testing.allocator, second, shared_rows_generation);
    try std.testing.expectEqual(@as(usize, 2), registry.count());
    try std.testing.expectEqual(shared_rows_generation, registry.get(first).?);
    try std.testing.expectEqual(shared_rows_generation, registry.get(second).?);
}
