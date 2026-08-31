//! Owned signal records and cache slots retained in the active graph.

const std = @import("std");
const abi = @import("roc_platform_abi.zig");
const boundary = @import("boundary.zig");
const retained = @import("retained_values.zig");
const row_handles = @import("row_handles.zig");
const roles = @import("callable_roles.zig");

pub const HostValue = retained.HostValue;
pub const HostValueCell = retained.HostValueCell;
pub const HostValueCapability = retained.HostValueCapability;
pub const HostSignalToken = retained.HostSignalToken;
pub const HostTextRead = retained.HostTextRead;

const releaseHostValueCapability = retained.releaseHostValueCapability;
const releaseHostTextRead = retained.releaseHostTextRead;

fn u64SliceContains(items: []const u64, target: u64) bool {
    for (items) |item| {
        if (item == target) return true;
    }
    return false;
}

/// Memoized output of a signal record: absent until first evaluated, then a
/// retained cell holding the last computed value plus its capability.
pub const CacheSlot = union(enum) {
    absent,
    present: HostValueCell,

    /// Releases every resource owned by this value and leaves no retained host or Roc ownership behind.
    pub fn deinit(self: *CacheSlot, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype) void {
        switch (self.*) {
            .absent => {},
            .present => |*cached| cached.deinit(ctx, roc_host, metrics),
        }
        self.* = .absent;
    }

    /// Replaces  while releasing displaced ownership exactly once.
    pub fn replace(self: *CacheSlot, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype, value: HostValue, cap: HostValueCapability) void {
        self.deinit(ctx, roc_host, metrics);
        self.* = .{ .present = HostValueCell.initRetained(value, cap, metrics) };
    }

    /// Atomically replaces the retained cell and releases the displaced value.
    pub fn replaceValue(self: *CacheSlot, ctx: anytype, roc_host: *abi.RocHost, value: HostValue) void {
        switch (self.*) {
            .absent => @panic("dirty signal expression was evaluated before its initial value was cached"),
            .present => |*cached| cached.replaceValue(ctx, roc_host, value),
        }
    }

    /// Creates an independently owned retained value using its attached capability.
    pub fn cloneRetained(self: CacheSlot, ctx: anytype, metrics: anytype) CacheSlot {
        return switch (self) {
            .absent => .absent,
            .present => |cached| .{ .present = cached.cloneRetained(ctx, metrics) },
        };
    }
};

/// One source or derived-cache replacement whose incoming value remains
/// private until the enclosing engine transaction publishes. The incoming
/// value is already owned by the caller; this journal retains its capability,
/// transfers both into the live slot without allocation, and defers releasing
/// the displaced live cell until publication has completed.
pub const PreparedCacheUpdate = struct {
    live: *CacheSlot,
    ownership: Ownership,

    const Ownership = union(enum) {
        prepared: CacheSlot,
        committed: CacheSlot,
    };

    /// Adopts an incoming value and retains the capability needed to own it.
    pub fn init(live: *CacheSlot, value: HostValue, cap: HostValueCapability, metrics: anytype) PreparedCacheUpdate {
        return .{
            .live = live,
            .ownership = .{ .prepared = .{ .present = HostValueCell.initRetained(value, cap, metrics) } },
        };
    }

    /// Adopts an already-retained cell without adding another capability edge.
    pub fn initOwned(live: *CacheSlot, cell: HostValueCell) PreparedCacheUpdate {
        return .{ .live = live, .ownership = .{ .prepared = .{ .present = cell } } };
    }

    /// Swaps the prepared value into the live cache without allocating.
    pub fn commit(self: *PreparedCacheUpdate) void {
        const incoming = switch (self.ownership) {
            .prepared => |slot| slot,
            .committed => @panic("prepared cache update committed twice"),
        };
        const displaced = self.live.*;
        self.live.* = incoming;
        self.ownership = .{ .committed = displaced };
    }

    /// Releases either the uncommitted incoming value or the displaced live
    /// value after the enclosing transaction has published.
    pub fn deinit(self: *PreparedCacheUpdate, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype) void {
        switch (self.ownership) {
            inline else => |*owned| owned.deinit(ctx, roc_host, metrics),
        }
        self.* = undefined;
    }

    /// Returns the transaction-private incoming slot before publication.
    pub fn preparedSlot(self: *const PreparedCacheUpdate) *const CacheSlot {
        return switch (self.ownership) {
            .prepared => |*slot| slot,
            .committed => @panic("committed cache update has no provisional slot"),
        };
    }
};

/// Nominal transaction-local identity for one signal record evaluation.
///
/// The pointer representation is deliberately hidden behind a constructor
/// accepting only `HostSignalRecord`, so cache slots, state cells, and unrelated
/// pointers cannot be used as memoization keys accidentally.
pub const EvaluationKey = enum(usize) {
    _,

    /// Derives the stable identity of a record that outlives the overlay.
    pub fn fromRecord(signal_record: anytype) EvaluationKey {
        if (@TypeOf(signal_record) != *Record) @compileError("evaluation keys can only identify signal records");
        return @enumFromInt(@intFromPtr(signal_record));
    }

    /// Returns the record identified by this transaction-local key.
    pub fn record(self: EvaluationKey) *Record {
        return @ptrFromInt(@intFromEnum(self));
    }
};

/// Pre-reserved cache overlay shared by all roots and derived records in one
/// source transaction. Lookup is O(1), staging performs no allocation after
/// `init`, and commit only swaps ownership into persistent cache slots.
pub const PreparedCacheUpdates = struct {
    const Phase = enum { preparing, committed };
    pub const Result = struct {
        key: EvaluationKey,
        dirty_generation: u64,
        changed: bool,
    };

    allocator: std.mem.Allocator,
    updates: std.ArrayListUnmanaged(PreparedCacheUpdate) = .empty,
    indexes: std.AutoHashMapUnmanaged(*CacheSlot, usize) = .empty,
    results: std.ArrayListUnmanaged(Result) = .empty,
    result_indexes: std.AutoHashMapUnmanaged(EvaluationKey, usize) = .empty,
    provisional_values: std.AutoHashMapUnmanaged(EvaluationKey, *const HostValueCell) = .empty,
    derived_calls: u64 = 0,
    propagation_prunes: u64 = 0,
    selector_members_dirtied: u64 = 0,
    phase: Phase = .preparing,

    /// Reserves the exact upper bound before any callback result is adopted.
    pub fn init(allocator: std.mem.Allocator, expected: usize) std.mem.Allocator.Error!PreparedCacheUpdates {
        var self = PreparedCacheUpdates{ .allocator = allocator };
        errdefer self.deinitStorage();
        try self.updates.ensureTotalCapacity(allocator, expected);
        try self.indexes.ensureTotalCapacity(allocator, std.math.cast(u32, expected) orelse return error.OutOfMemory);
        try self.results.ensureTotalCapacity(allocator, expected);
        try self.result_indexes.ensureTotalCapacity(allocator, std.math.cast(u32, expected) orelse return error.OutOfMemory);
        try self.provisional_values.ensureTotalCapacity(allocator, std.math.cast(u32, expected) orelse return error.OutOfMemory);
        return self;
    }

    /// Adopts one unique incoming value using already-reserved storage.
    pub fn stageAssumeCapacity(self: *PreparedCacheUpdates, live: *CacheSlot, value: HostValue, cap: HostValueCapability, metrics: anytype) void {
        if (self.phase == .committed or self.indexes.contains(live)) @panic("duplicate or late prepared cache update");
        const index = self.updates.items.len;
        self.updates.appendAssumeCapacity(PreparedCacheUpdate.init(live, value, cap, metrics));
        self.indexes.putAssumeCapacity(live, index);
    }

    /// Adopts an already-retained source cell using pre-reserved overlay storage.
    pub fn stageOwnedAssumeCapacity(self: *PreparedCacheUpdates, live: *CacheSlot, cell: HostValueCell) void {
        if (self.phase == .committed or self.indexes.contains(live)) @panic("duplicate or late prepared cache update");
        const index = self.updates.items.len;
        self.updates.appendAssumeCapacity(PreparedCacheUpdate.initOwned(live, cell));
        self.indexes.putAssumeCapacity(live, index);
    }

    /// Returns the provisional slot when staged, otherwise the persistent slot.
    pub fn readSlot(self: *const PreparedCacheUpdates, live: *CacheSlot) *const CacheSlot {
        const index = self.indexes.get(live) orelse return live;
        return self.updates.items[index].preparedSlot();
    }

    /// Memoizes one evaluated record without touching its persistent dirty-generation fields.
    pub fn rememberResultAssumeCapacity(self: *PreparedCacheUpdates, key: EvaluationKey, dirty_generation: u64, changed: bool) void {
        if (self.result_indexes.contains(key)) @panic("prepared signal result memoized twice");
        const index = self.results.items.len;
        self.results.appendAssumeCapacity(.{ .key = key, .dirty_generation = dirty_generation, .changed = changed });
        self.result_indexes.putAssumeCapacity(key, index);
    }

    /// Returns a previously memoized provisional dirty result.
    pub fn rememberedResult(self: *const PreparedCacheUpdates, key: EvaluationKey) ?bool {
        const index = self.result_indexes.get(key) orelse return null;
        return self.results.items[index].changed;
    }

    /// Discards a provisional evaluation so a later source wave in the same
    /// transaction can recompute that record from its newly staged inputs.
    /// Any cache value produced by the superseded evaluation is released, and
    /// the persistent cache remains untouched. The caller must invalidate the
    /// complete downstream dirty set, never an isolated derived record.
    pub fn forgetEvaluation(self: *PreparedCacheUpdates, record: *Record, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype) void {
        if (self.phase == .committed) @panic("cannot forget a committed signal evaluation");
        const key = EvaluationKey.fromRecord(record);
        if (self.result_indexes.fetchRemove(key)) |removed| {
            const removed_index = removed.value;
            _ = self.results.swapRemove(removed_index);
            if (removed_index < self.results.items.len) {
                self.result_indexes.getPtr(self.results.items[removed_index].key).?.* = removed_index;
            }
        }
        const slot = record.cachedSlot() orelse return;
        self.forgetCacheSlot(slot, ctx, roc_host, metrics);
    }

    /// Releases one provisional sink-cache replacement so its owning route can
    /// be recomputed after a later source wave invalidates the earlier value.
    pub fn forgetCacheSlot(self: *PreparedCacheUpdates, slot: *CacheSlot, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype) void {
        if (self.phase == .committed) @panic("cannot forget a committed cache update");
        if (self.indexes.fetchRemove(slot)) |removed| {
            const removed_index = removed.value;
            self.updates.items[removed_index].deinit(ctx, roc_host, metrics);
            _ = self.updates.swapRemove(removed_index);
            if (removed_index < self.updates.items.len) {
                self.indexes.getPtr(self.updates.items[removed_index].live).?.* = removed_index;
            }
        }
    }

    /// Associates a memoized record without a persistent cache slot, such as
    /// a state reference, with its transaction-private value.
    pub fn bindProvisionalValueAssumeCapacity(self: *PreparedCacheUpdates, key: EvaluationKey, cell: *const HostValueCell) void {
        if (self.provisional_values.contains(key)) @panic("prepared provisional value bound twice");
        self.provisional_values.putAssumeCapacity(key, cell);
    }

    /// Returns the transaction-private value for a slotless memoized record.
    pub fn provisionalValue(self: *const PreparedCacheUpdates, key: EvaluationKey) ?*const HostValueCell {
        return self.provisional_values.get(key);
    }

    /// Clears preparation-only borrowed value bindings before their owner is
    /// moved into the durable transaction plan.
    pub fn clearProvisionalValues(self: *PreparedCacheUpdates) void {
        self.provisional_values.clearRetainingCapacity();
    }

    /// Rebinds journal entries whose live cache is embedded in a descriptor
    /// vector that moved during structural-publication preflight. The old
    /// address is used only as an identity; its storage is never dereferenced.
    pub fn rebaseDescriptorCacheSlotsAssumeCapacity(
        self: *PreparedCacheUpdates,
        comptime Descriptor: type,
        old_base: usize,
        old_len: usize,
        new_items: []Descriptor,
    ) void {
        if (self.phase == .committed) @panic("cannot rebase a committed cache overlay");
        if (old_len == 0 or old_base == @intFromPtr(new_items.ptr)) return;
        const field_offset = @offsetOf(Descriptor, "cached_value");
        const stride = @sizeOf(Descriptor);
        const first_slot = std.math.add(usize, old_base, field_offset) catch @panic("descriptor cache address overflow");
        for (self.updates.items) |*update| {
            const address = @intFromPtr(update.live);
            if (address < first_slot) continue;
            const delta = address - first_slot;
            if (delta % stride != 0) continue;
            const index = delta / stride;
            if (index >= old_len) continue;
            update.live = &new_items[index].cached_value;
        }
        self.indexes.clearRetainingCapacity();
        for (self.updates.items, 0..) |*update, index| {
            if (self.indexes.contains(update.live)) @panic("rebased cache overlay contains duplicate live slots");
            self.indexes.putAssumeCapacity(update.live, index);
        }
    }

    /// Publishes every staged cache replacement without allocation.
    pub fn commit(self: *PreparedCacheUpdates) void {
        if (self.phase == .committed) @panic("prepared cache overlay committed twice");
        for (self.updates.items) |*update| update.commit();
        self.phase = .committed;
    }
    /// Releases provisional or displaced values and all overlay storage.
    pub fn deinit(self: *PreparedCacheUpdates, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype) void {
        for (self.updates.items) |*update| update.deinit(ctx, roc_host, metrics);
        self.deinitStorage();
        self.* = undefined;
    }

    fn deinitStorage(self: *PreparedCacheUpdates) void {
        self.updates.deinit(self.allocator);
        self.indexes.deinit(self.allocator);
        self.results.deinit(self.allocator);
        self.result_indexes.deinit(self.allocator);
        self.provisional_values.deinit(self.allocator);
    }
};

/// Owns the complete set of incoming roots for one multi-source transaction.
/// Storage is fully reserved before the first opaque value is adopted, so a
/// caller can materialize values while its app-compiled capability frame is
/// active without exposing partial live mutation. Duplicate records are
/// rejected before ownership changes hands. Destruction releases every value
/// that has not been transferred into a prepared cache overlay.
pub const OwnedSourceUpdates = struct {
    pub const Entry = struct {
        record: *Record,
        cell: ?HostValueCell,
    };

    pub const AdoptError = error{ DuplicateSource, TooManySources };

    allocator: std.mem.Allocator,
    expected: usize,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    indexes: std.AutoHashMapUnmanaged(*Record, void) = .empty,

    /// Reserves storage for exactly the declared number of source roots before
    /// any incoming Roc value is adopted.
    pub fn init(allocator: std.mem.Allocator, expected: usize) std.mem.Allocator.Error!OwnedSourceUpdates {
        var self = OwnedSourceUpdates{ .allocator = allocator, .expected = expected };
        errdefer self.deinitStorage();
        try self.entries.ensureTotalCapacityPrecise(allocator, expected);
        try self.indexes.ensureTotalCapacity(allocator, std.math.cast(u32, expected) orelse return error.OutOfMemory);
        return self;
    }

    /// Adopts one unique record/value/capability tuple using only pre-reserved
    /// storage. On rejection the caller retains ownership of `value`.
    pub fn adoptAssumeCapacity(self: *OwnedSourceUpdates, record: *Record, value: HostValue, cap: HostValueCapability, metrics: anytype) AdoptError!void {
        if (self.entries.items.len == self.expected) return error.TooManySources;
        if (self.indexes.contains(record)) return error.DuplicateSource;
        const cell = HostValueCell.initRetained(value, cap, metrics);
        self.entries.appendAssumeCapacity(.{ .record = record, .cell = cell });
        self.indexes.putAssumeCapacity(record, {});
    }

    /// Transfers one adopted cell to the next preparation stage without
    /// cloning it. The returned entry owns the cell and must be committed or
    /// released by that stage.
    pub fn take(self: *OwnedSourceUpdates, index: usize) Entry {
        const entry = &self.entries.items[index];
        const cell = entry.cell orelse @panic("source update ownership transferred twice");
        entry.cell = null;
        return .{ .record = entry.record, .cell = cell };
    }

    /// Releases all values still owned after partial construction or aborted
    /// downstream preflight, then frees the reservation storage.
    pub fn deinit(self: *OwnedSourceUpdates, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype) void {
        for (self.entries.items) |*entry| if (entry.cell) |*cell| cell.deinit(ctx, roc_host, metrics);
        self.deinitStorage();
        self.* = undefined;
    }

    fn deinitStorage(self: *OwnedSourceUpdates) void {
        self.entries.deinit(self.allocator);
        self.indexes.deinit(self.allocator);
    }
};

pub const EvalResult = struct {
    value: HostValue,
    changed: bool,
};

pub const ConstRecord = struct {
    init: roles.Initializer,
    cap: HostValueCapability,
    cached_value: CacheSlot = .absent,
};

pub const MapRecord = struct {
    input: *Record,
    transform: roles.Transform,
    cap: HostValueCapability,
    cached_value: CacheSlot = .absent,
};

pub const Map2Record = struct {
    left: *Record,
    right: *Record,
    transform: roles.Transform,
    cap: HostValueCapability,
    cached_value: CacheSlot = .absent,
};

pub const CombineRecord = struct {
    children: []*Record,
    transform: roles.Transform,
    cap: HostValueCapability,
    cached_value: CacheSlot = .absent,
};

pub const SelectRecord = struct {
    input: *Record,
    key: []const u8,
    input_read: HostTextRead,
    false_init: roles.Initializer,
    true_init: roles.Initializer,
    cap: HostValueCapability,
    false_value: CacheSlot = .absent,
    true_value: CacheSlot = .absent,
    cached_value: CacheSlot = .absent,
};

pub const TaskSourceRecord = struct {
    name: []const u8,
    payload_cap: HostValueCapability,
    initial: roles.Initializer,
    done: roles.Transform,
    failed: roles.Transform,
    cap: HostValueCapability,
    reset_on_start: bool,
    cached_value: CacheSlot = .absent,
};

pub const IntervalSourceRecord = struct {
    period_ms: u64,
    initial: roles.Initializer,
    tick: roles.Transform,
    cap: HostValueCapability,
    cached_value: CacheSlot = .absent,
};

pub const LocationSourceRecord = struct {
    payload_cap: HostValueCapability,
    from_payload: roles.Transform,
    cap: HostValueCapability,
    cached_value: CacheSlot = .absent,
};

pub const EntropySeedSourceRecord = LocationSourceRecord;

pub const VisibilitySourceRecord = struct {
    payload_cap: HostValueCapability,
    from_payload: roles.Transform,
    cap: HostValueCapability,
    cached_value: CacheSlot = .absent,
};

pub const OnlineSourceRecord = struct {
    payload_cap: HostValueCapability,
    from_payload: roles.Transform,
    cap: HostValueCapability,
    cached_value: CacheSlot = .absent,
};

pub const StorageSourceRecord = struct {
    area: boundary.StorageArea,
    key: []const u8,
    payload_cap: HostValueCapability,
    from_payload: roles.Transform,
    cap: HostValueCapability,
    cached_value: CacheSlot = .absent,
};

/// Stable keyed-row source resolved by the engine through its row handle.
///
/// The identity callable is never evaluated. It is the app-compiled allocation
/// shared by repeated `Row.signal` descriptors, preserving the same aliasing
/// rule as every other non-ref signal record. The cache owns an ordinary item
/// value only after the engine resolves the row through an active generation.
pub const RowSourceRecord = struct {
    row_handle: row_handles.RowHandleId,
    identity: roles.Initializer,
    cap: HostValueCapability,
    cached_value: CacheSlot = .absent,
};

pub const Payload = union(enum) {
    ref: u64,
    const_value: ConstRecord,
    map: MapRecord,
    map2: Map2Record,
    select: SelectRecord,
    combine: CombineRecord,
    task_source: TaskSourceRecord,
    interval_source: IntervalSourceRecord,
    entropy_seed_source: EntropySeedSourceRecord,
    location_source: LocationSourceRecord,
    online_source: OnlineSourceRecord,
    visibility_source: VisibilitySourceRecord,
    storage_source: StorageSourceRecord,
    row_source: RowSourceRecord,
};

pub const EffectSourceRef = union(enum) {
    task: *TaskSourceRecord,
    interval: *IntervalSourceRecord,
    entropy_seed: *EntropySeedSourceRecord,
    location: *LocationSourceRecord,
    online: *OnlineSourceRecord,
    visibility: *VisibilitySourceRecord,
    storage: *StorageSourceRecord,
    row: *RowSourceRecord,

    /// Returns the retained cache slot owned by this signal record kind.
    pub fn cachedSlot(self: EffectSourceRef) *CacheSlot {
        return switch (self) {
            .task => |payload| &payload.cached_value,
            .interval => |payload| &payload.cached_value,
            .entropy_seed => |payload| &payload.cached_value,
            .location => |payload| &payload.cached_value,
            .online => |payload| &payload.cached_value,
            .visibility => |payload| &payload.cached_value,
            .storage => |payload| &payload.cached_value,
            .row => |payload| &payload.cached_value,
        };
    }

    /// Returns the app-compiled capability that owns values crossing this edge.
    pub fn capability(self: EffectSourceRef) HostValueCapability {
        return switch (self) {
            .task => |payload| payload.cap,
            .interval => |payload| payload.cap,
            .entropy_seed => |payload| payload.cap,
            .location => |payload| payload.cap,
            .online => |payload| payload.cap,
            .visibility => |payload| payload.cap,
            .storage => |payload| payload.cap,
            .row => |payload| payload.cap,
        };
    }
};

/// Releases the record payload and every callable or value ownership edge it contains.
pub fn deinitOwnedPayload(allocator: std.mem.Allocator, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype, payload_value: Payload) void {
    switch (payload_value) {
        .ref => {},
        .const_value => |payload| {
            var cached = payload.cached_value;
            cached.deinit(ctx, roc_host, metrics);
            abi.decrefErasedCallable(payload.init.toAbi(), roc_host);
            releaseHostValueCapability(payload.cap, roc_host, metrics);
            metrics.bump(.closure_releases, 1);
        },
        .map => |payload| {
            payload.input.release(allocator, ctx, roc_host, metrics);
            var cached = payload.cached_value;
            cached.deinit(ctx, roc_host, metrics);
            abi.decrefErasedCallable(payload.transform.toAbi(), roc_host);
            releaseHostValueCapability(payload.cap, roc_host, metrics);
            metrics.bump(.closure_releases, 1);
        },
        .map2 => |payload| {
            payload.left.release(allocator, ctx, roc_host, metrics);
            payload.right.release(allocator, ctx, roc_host, metrics);
            var cached = payload.cached_value;
            cached.deinit(ctx, roc_host, metrics);
            abi.decrefErasedCallable(payload.transform.toAbi(), roc_host);
            releaseHostValueCapability(payload.cap, roc_host, metrics);
            metrics.bump(.closure_releases, 1);
        },
        .select => |payload| {
            payload.input.release(allocator, ctx, roc_host, metrics);
            allocator.free(payload.key);
            var false_value = payload.false_value;
            false_value.deinit(ctx, roc_host, metrics);
            var true_value = payload.true_value;
            true_value.deinit(ctx, roc_host, metrics);
            var cached = payload.cached_value;
            cached.deinit(ctx, roc_host, metrics);
            releaseHostTextRead(payload.input_read, roc_host, metrics);
            abi.decrefErasedCallable(payload.false_init.toAbi(), roc_host);
            abi.decrefErasedCallable(payload.true_init.toAbi(), roc_host);
            releaseHostValueCapability(payload.cap, roc_host, metrics);
            metrics.bump(.closure_releases, 2);
        },
        .combine => |payload| {
            for (payload.children) |child| child.release(allocator, ctx, roc_host, metrics);
            allocator.free(payload.children);
            var cached = payload.cached_value;
            cached.deinit(ctx, roc_host, metrics);
            abi.decrefErasedCallable(payload.transform.toAbi(), roc_host);
            releaseHostValueCapability(payload.cap, roc_host, metrics);
            metrics.bump(.closure_releases, 1);
        },
        .task_source => |payload| {
            var cached = payload.cached_value;
            cached.deinit(ctx, roc_host, metrics);
            allocator.free(payload.name);
            releaseHostValueCapability(payload.payload_cap, roc_host, metrics);
            abi.decrefErasedCallable(payload.initial.toAbi(), roc_host);
            abi.decrefErasedCallable(payload.done.toAbi(), roc_host);
            abi.decrefErasedCallable(payload.failed.toAbi(), roc_host);
            releaseHostValueCapability(payload.cap, roc_host, metrics);
            metrics.bump(.closure_releases, 3);
        },
        .interval_source => |payload| {
            var cached = payload.cached_value;
            cached.deinit(ctx, roc_host, metrics);
            abi.decrefErasedCallable(payload.initial.toAbi(), roc_host);
            abi.decrefErasedCallable(payload.tick.toAbi(), roc_host);
            releaseHostValueCapability(payload.cap, roc_host, metrics);
            metrics.bump(.closure_releases, 2);
        },
        .entropy_seed_source => |payload| {
            var cached = payload.cached_value;
            cached.deinit(ctx, roc_host, metrics);
            releaseHostValueCapability(payload.payload_cap, roc_host, metrics);
            abi.decrefErasedCallable(payload.from_payload.toAbi(), roc_host);
            releaseHostValueCapability(payload.cap, roc_host, metrics);
            metrics.bump(.closure_releases, 1);
        },
        .location_source => |payload| {
            var cached = payload.cached_value;
            cached.deinit(ctx, roc_host, metrics);
            releaseHostValueCapability(payload.payload_cap, roc_host, metrics);
            abi.decrefErasedCallable(payload.from_payload.toAbi(), roc_host);
            releaseHostValueCapability(payload.cap, roc_host, metrics);
            metrics.bump(.closure_releases, 1);
        },
        .online_source => |payload| {
            var cached = payload.cached_value;
            cached.deinit(ctx, roc_host, metrics);
            releaseHostValueCapability(payload.payload_cap, roc_host, metrics);
            abi.decrefErasedCallable(payload.from_payload.toAbi(), roc_host);
            releaseHostValueCapability(payload.cap, roc_host, metrics);
            metrics.bump(.closure_releases, 1);
        },
        .visibility_source => |payload| {
            var cached = payload.cached_value;
            cached.deinit(ctx, roc_host, metrics);
            releaseHostValueCapability(payload.payload_cap, roc_host, metrics);
            abi.decrefErasedCallable(payload.from_payload.toAbi(), roc_host);
            releaseHostValueCapability(payload.cap, roc_host, metrics);
            metrics.bump(.closure_releases, 1);
        },
        .storage_source => |payload| {
            var cached = payload.cached_value;
            cached.deinit(ctx, roc_host, metrics);
            allocator.free(payload.key);
            releaseHostValueCapability(payload.payload_cap, roc_host, metrics);
            abi.decrefErasedCallable(payload.from_payload.toAbi(), roc_host);
            releaseHostValueCapability(payload.cap, roc_host, metrics);
            metrics.bump(.closure_releases, 1);
        },
        .row_source => |payload| {
            var cached = payload.cached_value;
            cached.deinit(ctx, roc_host, metrics);
            abi.decrefErasedCallable(payload.identity.toAbi(), roc_host);
            releaseHostValueCapability(payload.cap, roc_host, metrics);
            metrics.bump(.closure_releases, 1);
        },
    }
}

/// A refcounted, shareable node in the signal graph. Owns its transform/eq/drop
/// thunks plus a memoized cached value; the active graph holds one reference
/// while a record is mounted.
pub const Record = struct {
    ref_count: usize,
    payload: Payload,
    active_graph_id: ?u64 = null,
    active_use_count: usize = 0,
    last_dirty_generation: u64 = 0,
    last_dirty_changed: bool = false,

    /// Creates an initialized value with the ownership and capacity invariants required by this module.
    pub fn init(allocator: std.mem.Allocator, payload: Payload) *Record {
        return tryInit(allocator, payload) catch @panic("out of memory");
    }

    /// Fallible constructor for transactional collection. The payload remains
    /// owned by the caller when allocation fails.
    pub fn tryInit(allocator: std.mem.Allocator, payload: Payload) std.mem.Allocator.Error!*Record {
        const record = try allocator.create(Record);
        record.* = .{
            .ref_count = 1,
            .payload = payload,
        };
        return record;
    }

    /// Constructs a record from an already-owned payload. Allocation failure
    /// destroys every retained callable, capability, child edge, and copied
    /// string held by that payload before returning to the caller.
    pub fn tryInitOwned(allocator: std.mem.Allocator, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype, payload: Payload) std.mem.Allocator.Error!*Record {
        return tryInit(allocator, payload) catch |err| {
            deinitOwnedPayload(allocator, ctx, roc_host, metrics, payload);
            return err;
        };
    }

    /// Returns the opaque identity token carried by this borrowed descriptor.
    pub fn token(self: *const Record) ?HostSignalToken {
        return switch (self.payload) {
            .ref => null,
            .const_value => |payload| retained.hostSignalTokenFromCallable(payload.init.toAbi()),
            .map => |payload| retained.hostSignalTokenFromCallable(payload.transform.toAbi()),
            .map2 => |payload| retained.hostSignalTokenFromCallable(payload.transform.toAbi()),
            .select => |payload| retained.hostSignalTokenFromCallable(payload.false_init.toAbi()),
            .combine => |payload| retained.hostSignalTokenFromCallable(payload.transform.toAbi()),
            .task_source => |payload| retained.hostSignalTokenFromCallable(payload.initial.toAbi()),
            .interval_source => |payload| retained.hostSignalTokenFromCallable(payload.initial.toAbi()),
            .entropy_seed_source => |payload| retained.hostSignalTokenFromCallable(payload.from_payload.toAbi()),
            .location_source => |payload| retained.hostSignalTokenFromCallable(payload.from_payload.toAbi()),
            .online_source => |payload| retained.hostSignalTokenFromCallable(payload.from_payload.toAbi()),
            .visibility_source => |payload| retained.hostSignalTokenFromCallable(payload.from_payload.toAbi()),
            .storage_source => |payload| retained.hostSignalTokenFromCallable(payload.from_payload.toAbi()),
            .row_source => |payload| retained.hostSignalTokenFromCallable(payload.identity.toAbi()),
        };
    }

    /// Returns the retained cache slot owned by this signal record kind.
    pub fn cachedSlot(self: *Record) ?*CacheSlot {
        return switch (self.payload) {
            .ref => null,
            .const_value => |*payload| &payload.cached_value,
            .map => |*payload| &payload.cached_value,
            .map2 => |*payload| &payload.cached_value,
            .select => |*payload| &payload.cached_value,
            .combine => |*payload| &payload.cached_value,
            .task_source => |*payload| &payload.cached_value,
            .interval_source => |*payload| &payload.cached_value,
            .entropy_seed_source => |*payload| &payload.cached_value,
            .location_source => |*payload| &payload.cached_value,
            .online_source => |*payload| &payload.cached_value,
            .visibility_source => |*payload| &payload.cached_value,
            .storage_source => |*payload| &payload.cached_value,
            .row_source => |*payload| &payload.cached_value,
        };
    }

    /// Returns the app-compiled capability that owns values crossing this edge.
    pub fn capability(self: *const Record, comptime Ctx: type, ctx: Ctx.Handle) HostValueCapability {
        return switch (self.payload) {
            .ref => |node_id| Ctx.stateCapability(ctx, node_id),
            .const_value => |payload| payload.cap,
            .map => |payload| payload.cap,
            .map2 => |payload| payload.cap,
            .select => |payload| payload.cap,
            .combine => |payload| payload.cap,
            .task_source => |payload| payload.cap,
            .interval_source => |payload| payload.cap,
            .entropy_seed_source => |payload| payload.cap,
            .location_source => |payload| payload.cap,
            .online_source => |payload| payload.cap,
            .visibility_source => |payload| payload.cap,
            .storage_source => |payload| payload.cap,
            .row_source => |payload| payload.cap,
        };
    }

    /// Returns the task source payload when this record has that exact kind.
    pub fn taskSource(self: *Record) ?*TaskSourceRecord {
        return switch (self.payload) {
            .task_source => |*payload| payload,
            .ref, .const_value, .map, .map2, .select, .combine, .interval_source, .entropy_seed_source, .location_source, .online_source, .visibility_source, .storage_source, .row_source => null,
        };
    }

    /// Returns the required task source payload or rejects an internal kind mismatch.
    pub fn requireTaskSource(self: *Record) *TaskSourceRecord {
        return self.taskSource() orelse @panic("signal record was not a task source");
    }

    /// Returns the interval source payload when this record has that exact kind.
    pub fn intervalSource(self: *Record) ?*IntervalSourceRecord {
        return switch (self.payload) {
            .interval_source => |*payload| payload,
            .ref, .const_value, .map, .map2, .select, .combine, .task_source, .entropy_seed_source, .location_source, .online_source, .visibility_source, .storage_source, .row_source => null,
        };
    }

    /// Returns the required interval source payload or rejects an internal kind mismatch.
    pub fn requireIntervalSource(self: *Record) *IntervalSourceRecord {
        return self.intervalSource() orelse @panic("signal record was not an interval source");
    }

    /// Returns the location source payload when this record has that exact kind.
    pub fn locationSource(self: *Record) ?*LocationSourceRecord {
        return switch (self.payload) {
            .location_source => |*payload| payload,
            .ref, .const_value, .map, .map2, .select, .combine, .task_source, .interval_source, .entropy_seed_source, .online_source, .visibility_source, .storage_source, .row_source => null,
        };
    }

    /// Returns the required location source payload or rejects an internal kind mismatch.
    pub fn requireLocationSource(self: *Record) *LocationSourceRecord {
        return self.locationSource() orelse @panic("signal record was not a location source");
    }

    /// Returns the online source payload when this record has that exact kind.
    pub fn onlineSource(self: *Record) ?*OnlineSourceRecord {
        return switch (self.payload) {
            .online_source => |*payload| payload,
            .ref, .const_value, .map, .map2, .select, .combine, .task_source, .interval_source, .entropy_seed_source, .location_source, .visibility_source, .storage_source, .row_source => null,
        };
    }

    /// Returns the required online source payload or rejects an internal kind mismatch.
    pub fn requireOnlineSource(self: *Record) *OnlineSourceRecord {
        return self.onlineSource() orelse @panic("signal record was not an online source");
    }

    /// Returns the visibility source payload when this record has that exact kind.
    pub fn visibilitySource(self: *Record) ?*VisibilitySourceRecord {
        return switch (self.payload) {
            .visibility_source => |*payload| payload,
            .ref, .const_value, .map, .map2, .select, .combine, .task_source, .interval_source, .entropy_seed_source, .location_source, .online_source, .storage_source, .row_source => null,
        };
    }

    /// Returns the required visibility source payload or rejects an internal kind mismatch.
    pub fn requireVisibilitySource(self: *Record) *VisibilitySourceRecord {
        return self.visibilitySource() orelse @panic("signal record was not a visibility source");
    }

    /// Returns the storage source payload when this record has that exact kind.
    pub fn storageSource(self: *Record) ?*StorageSourceRecord {
        return switch (self.payload) {
            .storage_source => |*payload| payload,
            .ref, .const_value, .map, .map2, .select, .combine, .task_source, .interval_source, .entropy_seed_source, .location_source, .online_source, .visibility_source, .row_source => null,
        };
    }

    /// Returns the required storage source payload or rejects an internal kind mismatch.
    pub fn requireStorageSource(self: *Record) *StorageSourceRecord {
        return self.storageSource() orelse @panic("signal record was not a storage source");
    }

    /// Returns the effect source payload when this record has that exact kind.
    pub fn effectSource(self: *Record) ?EffectSourceRef {
        return switch (self.payload) {
            .task_source => |*payload| .{ .task = payload },
            .interval_source => |*payload| .{ .interval = payload },
            .entropy_seed_source => |*payload| .{ .entropy_seed = payload },
            .location_source => |*payload| .{ .location = payload },
            .online_source => |*payload| .{ .online = payload },
            .visibility_source => |*payload| .{ .visibility = payload },
            .storage_source => |*payload| .{ .storage = payload },
            .row_source => |*payload| .{ .row = payload },
            .ref, .const_value, .map, .map2, .select, .combine => null,
        };
    }

    /// Acquires an independent retained reference that the caller must eventually release.
    pub fn retain(self: *Record) *Record {
        self.ref_count += 1;
        return self;
    }

    /// Releases this retained resource through its owning capability or allocator.
    pub fn release(self: *Record, allocator: std.mem.Allocator, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype) void {
        if (self.ref_count == 0) @panic("host signal record release underflow");
        if (self.ref_count == 1 and self.active_graph_id != null) @panic("active signal graph held the last signal record reference");
        self.ref_count -= 1;
        if (self.ref_count != 0) return;

        deinitOwnedPayload(allocator, ctx, roc_host, metrics, self.payload);
        allocator.destroy(self);
    }
};

/// A reference to a shared signal record plus the source state-node ids that
/// feed it; the unit a descriptor edge owns.
pub const Binding = struct {
    record: *Record,
    source_node_ids: []u64,

    /// Creates an independently owned retained value using its attached capability.
    pub fn cloneRetained(self: Binding, allocator: std.mem.Allocator, metrics: anytype) Binding {
        _ = metrics;
        return .{
            .record = self.record.retain(),
            .source_node_ids = allocator.dupe(u64, self.source_node_ids) catch @panic("out of memory"),
        };
    }

    /// Releases every resource owned by this value and leaves no retained host or Roc ownership behind.
    pub fn deinit(self: *Binding, allocator: std.mem.Allocator, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype) void {
        self.record.release(allocator, ctx, roc_host, metrics);
        allocator.free(self.source_node_ids);
    }
};

/// Walks the descriptor tree once during ingestion to build explicit records and edges.
pub fn walkTree(comptime Context: type, context: Context, record: *Record, comptime visit: fn (Context, *Record) void) void {
    visit(context, record);
    switch (record.payload) {
        .ref, .const_value, .task_source, .interval_source, .entropy_seed_source, .location_source, .online_source, .visibility_source, .storage_source, .row_source => {},
        .map => |payload| walkTree(Context, context, payload.input, visit),
        .select => |payload| walkTree(Context, context, payload.input, visit),
        .map2 => |payload| {
            walkTree(Context, context, payload.left, visit);
            walkTree(Context, context, payload.right, visit);
        },
        .combine => |payload| {
            for (payload.children) |child| {
                walkTree(Context, context, child, visit);
            }
        },
    }
}

/// Checks that an aliased descriptor agrees with the already-ingested signal record.
pub fn validateExistingSignalRecord(record: *Record, expected_tag: std.meta.Tag(Payload)) void {
    if (std.meta.activeTag(record.payload) != expected_tag) {
        @panic("signal token was reused for a different signal expression kind");
    }
}

/// Appends signal record source node ids using capacity that must already satisfy the caller's transaction contract.
pub fn appendSignalRecordSourceNodeIds(allocator: std.mem.Allocator, source_node_ids: *std.ArrayListUnmanaged(u64), record: *Record) void {
    appendSignalRecordSourceNodeIdsFallible(allocator, source_node_ids, record) catch @panic("out of memory");
}

/// Appends signal record source node ids fallible using capacity that must already satisfy the caller's transaction contract.
pub fn appendSignalRecordSourceNodeIdsFallible(allocator: std.mem.Allocator, source_node_ids: *std.ArrayListUnmanaged(u64), record: *Record) std.mem.Allocator.Error!void {
    switch (record.payload) {
        .ref => |node_id| {
            if (!u64SliceContains(source_node_ids.items, node_id)) {
                try source_node_ids.append(allocator, node_id);
            }
        },
        .const_value => {},
        .map => |payload| try appendSignalRecordSourceNodeIdsFallible(allocator, source_node_ids, payload.input),
        .select => |payload| try appendSignalRecordSourceNodeIdsFallible(allocator, source_node_ids, payload.input),
        .map2 => |payload| {
            try appendSignalRecordSourceNodeIdsFallible(allocator, source_node_ids, payload.left);
            try appendSignalRecordSourceNodeIdsFallible(allocator, source_node_ids, payload.right);
        },
        .combine => |payload| {
            for (payload.children) |child| {
                try appendSignalRecordSourceNodeIdsFallible(allocator, source_node_ids, child);
            }
        },
        .task_source, .interval_source, .entropy_seed_source, .location_source, .online_source, .visibility_source, .storage_source, .row_source => {},
    }
}

test "fallible signal record construction preserves payload ownership on OOM" {
    var storage: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    try std.testing.expectError(error.OutOfMemory, Record.tryInit(fixed.allocator(), .{ .ref = 7 }));

    const record = try Record.tryInit(std.testing.allocator, .{ .ref = 7 });
    try std.testing.expectEqual(@as(Payload, .{ .ref = 7 }), record.payload);
    const evaluation_key = EvaluationKey.fromRecord(record);
    try std.testing.expectEqual(record, evaluation_key.record());
    try std.testing.expect(EvaluationKey != *Record);
    std.testing.allocator.destroy(record);
}

test "row source records expose stable identity locator cache and capability" {
    const CapabilityCtx = struct {
        pub const Handle = void;
        /// This fixture never resolves state capabilities.
        pub fn stateCapability(_: Handle, _: u64) HostValueCapability {
            unreachable;
        }
    };
    var env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&env);
    const identity = abi.rocErasedCallableAllocate(&roc_host, ownedSourceTestCallable, null, 0).?;
    defer abi.decrefErasedCallable(identity, &roc_host);
    const cap = HostValueCapability{ .clone = identity, .drop = identity, .eq = identity };
    const handle = row_handles.RowHandleId.fromRaw(0x0000_0007_0000_0003);
    var record = Record{
        .ref_count = 1,
        .payload = .{ .row_source = .{
            .row_handle = handle,
            .identity = .fromAbi(identity),
            .cap = cap,
        } },
    };

    try std.testing.expectEqual(identity, record.token().?);
    try std.testing.expectEqual(handle, record.payload.row_source.row_handle);
    try std.testing.expectEqual(cap, record.capability(CapabilityCtx, {}));
    try std.testing.expect(record.cachedSlot().?.* == .absent);
    try std.testing.expect(record.effectSource().? == .row);
}

test "owned combine payload releases nested children and capabilities on record OOM" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    const TestCtx = struct {
        /// Produces an independently owned copy through the value's app-compiled capability.
        pub fn cloneHostValue(_: *@This(), value: HostValue) HostValue {
            return value;
        }
        /// Opens a checked capability frame for an app-compiled erased call.
        pub fn pushHostValueCapabilities(_: *@This(), _: []const HostValueCapability) void {}
        /// Closes the current capability frame after an app-compiled erased call.
        pub fn popHostValueCapabilities(_: *@This()) void {}
    };
    const TestMetrics = struct {
        closure_releases: u64 = 0,
        /// Increments  for exact structural-work accounting.
        pub fn bump(self: *@This(), comptime field: anytype, count: u64) void {
            if (field == .closure_releases) self.closure_releases += count;
        }
    };
    var env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&env);
    var ctx = TestCtx{};
    var metrics = TestMetrics{};
    const left = try Record.tryInit(std.testing.allocator, .{ .ref = 1 });
    const right = try Record.tryInit(std.testing.allocator, .{ .ref = 2 });
    const children = try std.testing.allocator.dupe(*Record, &.{ left, right });

    var fault = FaultAllocator.init(std.testing.allocator);
    fault.configure(1);
    const empty_capability = HostValueCapability{ .clone = null, .drop = null, .eq = null };
    try std.testing.expectError(error.OutOfMemory, Record.tryInitOwned(fault.allocator(), &ctx, &roc_host, &metrics, .{ .combine = .{
        .children = children,
        .transform = .fromAbi(null),
        .cap = empty_capability,
    } }));
    try std.testing.expectEqual(@as(u64, 4), metrics.closure_releases);
}

test "appendSignalRecordSourceNodeIds deduplicates source refs" {
    const allocator = std.testing.allocator;
    var left = Record{ .ref_count = 1, .payload = .{ .ref = 10 } };
    var duplicate = Record{ .ref_count = 1, .payload = .{ .ref = 10 } };
    var right = Record{ .ref_count = 1, .payload = .{ .ref = 20 } };
    const children = [_]*Record{ &left, &duplicate, &right };
    var combine = Record{
        .ref_count = 1,
        .payload = .{ .combine = .{
            .children = @constCast(children[0..]),
            .transform = undefined,
            .cap = undefined,
        } },
    };

    var source_node_ids: std.ArrayListUnmanaged(u64) = .empty;
    defer source_node_ids.deinit(allocator);

    appendSignalRecordSourceNodeIds(allocator, &source_node_ids, &combine);
    try std.testing.expectEqualSlices(u64, &.{ 10, 20 }, source_node_ids.items);
}

var owned_source_test_drop_count: usize = 0;

fn ownedSourceTestCallable(_: *abi.RocHost, _: ?[*]u8, _: ?[*]const u8, _: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {}

fn ownedSourceTestDrop(_: *abi.RocHost, _: ?[*]u8, _: ?[*]const u8, _: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    owned_source_test_drop_count += 1;
}

const OwnedSourceTestCtx = struct {
    /// Returns the same scalar test carrier because these tests model ownership through counters.
    pub fn cloneHostValue(_: *@This(), value: HostValue) HostValue {
        return value;
    }

    /// Opens the no-op capability frame used by the test host.
    pub fn pushHostValueCapabilities(_: *@This(), _: []const HostValueCapability) void {}

    /// Closes the no-op capability frame used by the test host.
    pub fn popHostValueCapabilities(_: *@This()) void {}
};

const OwnedSourceTestMetrics = struct {
    closure_retains: u64 = 0,
    closure_releases: u64 = 0,

    /// Records capability retain and release edges so aborted owners must balance exactly.
    pub fn bump(self: *@This(), comptime field: anytype, count: u64) void {
        if (field == .closure_retains) self.closure_retains += count;
        if (field == .closure_releases) self.closure_releases += count;
    }
};

test "owned source updates sweep exact reservation failures and retry on the same allocator" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    const Runner = struct {
        fn reserve(fault: *FaultAllocator, fail_at: ?usize) !usize {
            fault.configure(fail_at);
            var updates = OwnedSourceUpdates.init(fault.allocator(), 3) catch |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                return fault.attempts;
            };
            const attempts = fault.attempts;
            updates.deinitStorage();
            return attempts;
        }
    };

    var counter = FaultAllocator.init(std.testing.allocator);
    const attempts = try Runner.reserve(&counter, null);
    try std.testing.expect(attempts >= 2);
    for (1..attempts + 1) |fail_at| {
        var fault = FaultAllocator.init(std.testing.allocator);
        _ = try Runner.reserve(&fault, fail_at);
        try std.testing.expectEqual(@as(usize, 1), fault.induced_failures);

        // Cleanup after failed reservation leaves the same owner allocator
        // reusable for a complete retry.
        _ = try Runner.reserve(&fault, null);
    }
}

test "owned source updates release every partial adoption and remain ref neutral" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&env);
    const ordinary = abi.rocErasedCallableAllocate(&roc_host, ownedSourceTestCallable, null, 0).?;
    defer abi.decrefErasedCallable(ordinary, &roc_host);
    const drop = abi.rocErasedCallableAllocate(&roc_host, ownedSourceTestDrop, null, 0).?;
    defer abi.decrefErasedCallable(drop, &roc_host);
    const cap = HostValueCapability{ .clone = ordinary, .drop = drop, .eq = ordinary };
    var records = [_]Record{
        .{ .ref_count = 1, .payload = .{ .ref = 1 } },
        .{ .ref_count = 1, .payload = .{ .ref = 2 } },
        .{ .ref_count = 1, .payload = .{ .ref = 3 } },
    };

    for (0..records.len + 1) |constructed| {
        owned_source_test_drop_count = 0;
        var fault = FaultAllocator.init(std.testing.allocator);
        var ctx = OwnedSourceTestCtx{};
        var metrics = OwnedSourceTestMetrics{};
        var updates = try OwnedSourceUpdates.init(fault.allocator(), records.len);
        fault.configure(1);
        for (records[0..constructed], 0..) |*record, index| {
            try updates.adoptAssumeCapacity(record, HostValue.fromRaw(@intCast(index + 10)), cap, &metrics);
        }
        try std.testing.expectEqual(@as(usize, 0), fault.attempts);
        updates.deinit(&ctx, &roc_host, &metrics);
        try std.testing.expectEqual(constructed, owned_source_test_drop_count);
        try std.testing.expectEqual(metrics.closure_retains, metrics.closure_releases);
    }
}

test "owned source updates reject duplicates before ownership mutation" {
    var env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&env);
    const ordinary = abi.rocErasedCallableAllocate(&roc_host, ownedSourceTestCallable, null, 0).?;
    defer abi.decrefErasedCallable(ordinary, &roc_host);
    const drop = abi.rocErasedCallableAllocate(&roc_host, ownedSourceTestDrop, null, 0).?;
    defer abi.decrefErasedCallable(drop, &roc_host);
    const cap = HostValueCapability{ .clone = ordinary, .drop = drop, .eq = ordinary };
    var record = Record{ .ref_count = 1, .payload = .{ .ref = 1 } };
    var ctx = OwnedSourceTestCtx{};
    var metrics = OwnedSourceTestMetrics{};
    var updates = try OwnedSourceUpdates.init(std.testing.allocator, 2);

    try updates.adoptAssumeCapacity(&record, HostValue.fromRaw(10), cap, &metrics);
    const retains_before = metrics.closure_retains;
    try std.testing.expectError(error.DuplicateSource, updates.adoptAssumeCapacity(&record, HostValue.fromRaw(20), cap, &metrics));
    try std.testing.expectEqual(@as(usize, 1), updates.entries.items.len);
    try std.testing.expectEqual(retains_before, metrics.closure_retains);
    var second = Record{ .ref_count = 1, .payload = .{ .ref = 2 } };
    try updates.adoptAssumeCapacity(&second, HostValue.fromRaw(30), cap, &metrics);
    var third = Record{ .ref_count = 1, .payload = .{ .ref = 3 } };
    try std.testing.expectError(error.TooManySources, updates.adoptAssumeCapacity(&third, HostValue.fromRaw(40), cap, &metrics));
    try std.testing.expectEqual(@as(usize, 2), updates.entries.items.len);
    try std.testing.expectEqual(retains_before + 3, metrics.closure_retains);

    owned_source_test_drop_count = 0;
    updates.deinit(&ctx, &roc_host, &metrics);
    try std.testing.expectEqual(@as(usize, 2), owned_source_test_drop_count);
    try std.testing.expectEqual(metrics.closure_retains, metrics.closure_releases);
}
