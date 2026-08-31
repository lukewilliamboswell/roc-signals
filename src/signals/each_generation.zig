//! Immutable collection generations and transaction-local keyed-row bindings.
//!
//! A generation owns exactly one opaque Roc collection cell plus the copied
//! host key bytes derived from it. Row handles resolve through generation IDs,
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
    collection: HostValueCell,
    ops: HostEachOps,
    keys: KeyStorage,
    item_count: usize,
    live: bool = true,

    /// Adopts one collection value and completed host key storage, and retains
    /// the typed collection operations needed to read this generation later.
    ///
    /// On success `keys_owner` is reset and the returned generation owns its
    /// buffers. The incoming collection value is already independently owned;
    /// this function retains the operations' collection capability as the
    /// cell's ownership edge and retains every typed operation separately.
    pub fn initOwned(id: GenerationId, collection: HostValue, ops: HostEachOps, keys_owner: *KeyStorage, item_count: usize, metrics: anytype) error{ InvalidGeneration, InvalidKeyCount }!Generation {
        if (!id.isValid()) return error.InvalidGeneration;
        if (keys_owner.expected_count != item_count or keys_owner.offsets.items.len != item_count + 1) return error.InvalidKeyCount;
        const keys = keys_owner.*;
        keys_owner.* = .{};
        return .{
            .id = id,
            .collection = HostValueCell.initRetained(collection, ops.items_capability, metrics),
            .ops = retained.retainHostEachOps(ops, metrics),
            .keys = keys,
            .item_count = item_count,
        };
    }

    /// Returns exact host-owned key bytes for one item in this generation.
    pub fn key(self: *const Generation, item_index: usize) ?[]const u8 {
        if (!self.live or item_index >= self.item_count) return null;
        return self.keys.key(item_index);
    }

    /// Releases the opaque Roc collection, retained typed operations, and host
    /// key buffers exactly once.
    pub fn deinit(self: *Generation, allocator: std.mem.Allocator, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype) void {
        if (!self.live) @panic("each generation deinitialized twice");
        self.collection.deinit(ctx, roc_host, metrics);
        retained.releaseHostEachOps(self.ops, roc_host, metrics);
        self.keys.deinit(allocator);
        self.live = false;
    }
};

/// Current immutable collection location for one stable row handle.
pub const RowBinding = struct {
    generation_id: GenerationId,
    item_index: usize,

    /// Validates the binding's nonzero generation identity.
    pub fn validate(self: RowBinding) error{InvalidGeneration}!void {
        if (!self.generation_id.isValid()) return error.InvalidGeneration;
    }
};

pub const BindingTable = struct {
    entries: std.AutoHashMapUnmanaged(RowHandleId, RowBinding) = .empty,

    /// Releases host-owned index storage; bindings own no generations.
    pub fn deinit(self: *BindingTable, allocator: std.mem.Allocator) void {
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
    candidate: std.AutoHashMapUnmanaged(RowHandleId, ?RowBinding) = .empty,
    phase: OverlayPhase = .preparing,
    commit_preflighted: bool = false,

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
    pub fn putAssumeCapacity(self: *CandidateBindings, row_handle: RowHandleId, binding: RowBinding) error{ InvalidGeneration, DuplicateRowHandle }!void {
        if (self.phase != .preparing) @panic("committed each binding overlay cannot stage");
        try binding.validate();
        const entry = self.candidate.getOrPutAssumeCapacity(row_handle);
        if (entry.found_existing) return error.DuplicateRowHandle;
        entry.value_ptr.* = binding;
    }

    /// Stages explicit row retirement so preparation cannot fall back to the
    /// row's committed generation.
    pub fn removeAssumeCapacity(self: *CandidateBindings, row_handle: RowHandleId) error{DuplicateRowHandle}!void {
        if (self.phase != .preparing) @panic("committed each binding overlay cannot stage");
        const entry = self.candidate.getOrPutAssumeCapacity(row_handle);
        if (entry.found_existing) return error.DuplicateRowHandle;
        entry.value_ptr.* = null;
    }

    /// Resolves candidate state first, then committed state. This is the lookup
    /// law used by delayed structural builders during transaction preparation.
    pub fn resolve(self: *const CandidateBindings, committed: *const BindingTable, row_handle: RowHandleId) ?RowBinding {
        if (self.candidate.get(row_handle)) |candidate| return candidate;
        return committed.get(row_handle);
    }

    /// Reserves the persistent table for every possible inserted edit before
    /// the allocation-free commit boundary.
    pub fn preflightCommit(self: *CandidateBindings, committed: *BindingTable) (std.mem.Allocator.Error || error{ResourceLimit})!void {
        if (self.phase != .preparing) @panic("committed each binding overlay cannot preflight");
        const maximum = std.math.add(usize, committed.entries.count(), self.candidate.count()) catch return error.ResourceLimit;
        try committed.entries.ensureTotalCapacity(self.allocator, std.math.cast(u32, maximum) orelse return error.ResourceLimit);
        self.commit_preflighted = true;
    }

    /// Publishes every prepared edit without allocation.
    pub fn commit(self: *CandidateBindings, committed: *BindingTable) void {
        if (self.phase != .preparing) @panic("each binding overlay committed twice");
        if (!self.commit_preflighted) @panic("each binding overlay committed before preflight");
        // Retire old handles before publishing replacements. Besides matching
        // the generation transition, this keeps the allocation-free commit
        // within the preflighted final binding bound when one batch removes
        // and creates rows together.
        var removals = self.candidate.iterator();
        while (removals.next()) |entry| if (entry.value_ptr.* == null) {
            _ = committed.entries.remove(entry.key_ptr.*);
        };
        var insertions = self.candidate.iterator();
        while (insertions.next()) |entry| if (entry.value_ptr.*) |binding| {
            committed.entries.putAssumeCapacity(entry.key_ptr.*, binding);
        };
        self.phase = .committed;
    }

    /// Releases candidate edit storage after commit or abort.
    pub fn deinit(self: *CandidateBindings) void {
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
        .clone_item_at = ordinary,
        .compare_pairs = ordinary,
        .copy_keys = ordinary,
        .item_capability = cap,
        .items_capability = cap,
        .len = ordinary,
        .row = ordinary,
    });
    var metrics = TestMetrics{};
    var ctx = TestCtx{};
    var keys = try completedKeys(std.testing.allocator, &.{ "alpha", "beta" });
    test_drop_count = 0;
    var generation = try Generation.initOwned(GenerationId.fromRaw(9), HostValue.fromRaw(77), ops, &keys, 2, &metrics);
    try std.testing.expectEqualStrings("alpha", generation.key(0).?);
    try std.testing.expectEqualStrings("beta", generation.key(1).?);
    try std.testing.expect(generation.key(2) == null);
    try std.testing.expectEqual(@as(usize, 0), keys.bytes.capacity);
    generation.deinit(std.testing.allocator, &ctx, &roc_host, &metrics);
    try std.testing.expectEqual(@as(usize, 1), test_drop_count);
    try std.testing.expectEqual(@as(u64, 14), metrics.retains);
    try std.testing.expectEqual(metrics.retains, metrics.releases);
}

test "candidate bindings override committed rows for delayed reads" {
    const row = RowHandleId.fromRaw(0x0000_0001_0000_0001);
    const old = RowBinding{ .generation_id = GenerationId.fromRaw(4), .item_index = 2 };
    const next = RowBinding{ .generation_id = GenerationId.fromRaw(5), .item_index = 7 };
    var committed = BindingTable{};
    defer committed.deinit(std.testing.allocator);
    try committed.entries.put(std.testing.allocator, row, old);
    var overlay = CandidateBindings.init(std.testing.allocator);
    defer overlay.deinit();
    try overlay.reserve(1);
    try overlay.putAssumeCapacity(row, next);

    try std.testing.expectEqual(next, overlay.resolve(&committed, row).?);
    try overlay.preflightCommit(&committed);
    overlay.commit(&committed);
    try std.testing.expectEqual(next, committed.get(row).?);
}

test "aborted candidate bindings leave committed rows readable" {
    const row = RowHandleId.fromRaw(0x0000_0001_0000_0001);
    const old = RowBinding{ .generation_id = GenerationId.fromRaw(10), .item_index = 1 };
    var committed = BindingTable{};
    defer committed.deinit(std.testing.allocator);
    try committed.entries.put(std.testing.allocator, row, old);
    var overlay = CandidateBindings.init(std.testing.allocator);
    try overlay.reserve(1);
    try overlay.putAssumeCapacity(row, .{ .generation_id = GenerationId.fromRaw(11), .item_index = 9 });
    overlay.deinit();

    try std.testing.expectEqual(old, committed.get(row).?);
}

test "candidate bindings reject duplicates and invalid generations" {
    const row = RowHandleId.fromRaw(0x0000_0001_0000_0001);
    var overlay = CandidateBindings.init(std.testing.allocator);
    defer overlay.deinit();
    try overlay.reserve(2);
    try std.testing.expectError(error.InvalidGeneration, overlay.putAssumeCapacity(row, .{ .generation_id = GenerationId.fromRaw(0), .item_index = 0 }));
    try overlay.putAssumeCapacity(row, .{ .generation_id = GenerationId.fromRaw(1), .item_index = 0 });
    try std.testing.expectError(error.DuplicateRowHandle, overlay.putAssumeCapacity(row, .{ .generation_id = GenerationId.fromRaw(1), .item_index = 1 }));
}

test "candidate removal masks committed binding before and after commit" {
    const row = RowHandleId.fromRaw(0x0000_0001_0000_0001);
    var committed = BindingTable{};
    defer committed.deinit(std.testing.allocator);
    try committed.entries.put(std.testing.allocator, row, .{ .generation_id = GenerationId.fromRaw(3), .item_index = 4 });
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
