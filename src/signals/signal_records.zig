//! Owned signal records and cache slots retained in the active graph.

const std = @import("std");
const abi = @import("roc_platform_abi.zig");
const boundary = @import("boundary.zig");
const retained = @import("retained_values.zig");

pub const HostValue = retained.HostValue;
pub const HostValueCell = retained.HostValueCell;
pub const HostValueCapability = retained.HostValueCapability;
pub const HostSignalToken = retained.HostSignalToken;

const releaseHostValueCapability = retained.releaseHostValueCapability;

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
    next: CacheSlot,
    displaced: CacheSlot = .absent,
    committed: bool = false,

    /// Adopts an incoming value and retains the capability needed to own it.
    pub fn init(live: *CacheSlot, value: HostValue, cap: HostValueCapability, metrics: anytype) PreparedCacheUpdate {
        return .{
            .live = live,
            .next = .{ .present = HostValueCell.initRetained(value, cap, metrics) },
        };
    }

    /// Swaps the prepared value into the live cache without allocating.
    pub fn commit(self: *PreparedCacheUpdate) void {
        if (self.committed) @panic("prepared cache update committed twice");
        self.displaced = self.live.*;
        self.live.* = self.next;
        self.next = .absent;
        self.committed = true;
    }

    /// Releases either the uncommitted incoming value or the displaced live
    /// value after the enclosing transaction has published.
    pub fn deinit(self: *PreparedCacheUpdate, ctx: anytype, roc_host: *abi.RocHost, metrics: anytype) void {
        self.next.deinit(ctx, roc_host, metrics);
        self.displaced.deinit(ctx, roc_host, metrics);
        self.* = undefined;
    }
};

/// Pre-reserved cache overlay shared by all roots and derived records in one
/// source transaction. Lookup is O(1), staging performs no allocation after
/// `init`, and commit only swaps ownership into persistent cache slots.
pub const PreparedCacheUpdates = struct {
    allocator: std.mem.Allocator,
    updates: std.ArrayListUnmanaged(PreparedCacheUpdate) = .empty,
    indexes: std.AutoHashMapUnmanaged(*CacheSlot, usize) = .empty,
    committed: bool = false,

    /// Reserves the exact upper bound before any callback result is adopted.
    pub fn init(allocator: std.mem.Allocator, expected: usize) std.mem.Allocator.Error!PreparedCacheUpdates {
        var self = PreparedCacheUpdates{ .allocator = allocator };
        errdefer self.deinitStorage();
        try self.updates.ensureTotalCapacity(allocator, expected);
        try self.indexes.ensureTotalCapacity(allocator, std.math.cast(u32, expected) orelse return error.OutOfMemory);
        return self;
    }

    /// Adopts one unique incoming value using already-reserved storage.
    pub fn stageAssumeCapacity(self: *PreparedCacheUpdates, live: *CacheSlot, value: HostValue, cap: HostValueCapability, metrics: anytype) void {
        if (self.committed or self.indexes.contains(live)) @panic("duplicate or late prepared cache update");
        const index = self.updates.items.len;
        self.updates.appendAssumeCapacity(PreparedCacheUpdate.init(live, value, cap, metrics));
        self.indexes.putAssumeCapacity(live, index);
    }

    /// Returns the provisional slot when staged, otherwise the persistent slot.
    pub fn readSlot(self: *const PreparedCacheUpdates, live: *CacheSlot) *const CacheSlot {
        const index = self.indexes.get(live) orelse return live;
        return &self.updates.items[index].next;
    }

    /// Publishes every staged cache replacement without allocation.
    pub fn commit(self: *PreparedCacheUpdates) void {
        if (self.committed) @panic("prepared cache overlay committed twice");
        for (self.updates.items) |*update| update.commit();
        self.committed = true;
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
    }
};

pub const EvalResult = struct {
    value: HostValue,
    changed: bool,
};

pub const ConstRecord = struct {
    init: abi.RocErasedCallable,
    cap: HostValueCapability,
    cached_value: CacheSlot = .absent,
};

pub const MapRecord = struct {
    input: *Record,
    transform: abi.RocErasedCallable,
    cap: HostValueCapability,
    cached_value: CacheSlot = .absent,
};

pub const Map2Record = struct {
    left: *Record,
    right: *Record,
    transform: abi.RocErasedCallable,
    cap: HostValueCapability,
    cached_value: CacheSlot = .absent,
};

pub const CombineRecord = struct {
    children: []*Record,
    transform: abi.RocErasedCallable,
    cap: HostValueCapability,
    cached_value: CacheSlot = .absent,
};

pub const TaskSourceRecord = struct {
    name: []const u8,
    payload_cap: HostValueCapability,
    initial: abi.RocErasedCallable,
    done: abi.RocErasedCallable,
    failed: abi.RocErasedCallable,
    cap: HostValueCapability,
    reset_on_start: bool,
    cached_value: CacheSlot = .absent,
};

pub const IntervalSourceRecord = struct {
    period_ms: u64,
    initial: abi.RocErasedCallable,
    tick: abi.RocErasedCallable,
    cap: HostValueCapability,
    cached_value: CacheSlot = .absent,
};

pub const LocationSourceRecord = struct {
    payload_cap: HostValueCapability,
    from_payload: abi.RocErasedCallable,
    cap: HostValueCapability,
    cached_value: CacheSlot = .absent,
};

pub const VisibilitySourceRecord = struct {
    payload_cap: HostValueCapability,
    from_payload: abi.RocErasedCallable,
    cap: HostValueCapability,
    cached_value: CacheSlot = .absent,
};

pub const OnlineSourceRecord = struct {
    payload_cap: HostValueCapability,
    from_payload: abi.RocErasedCallable,
    cap: HostValueCapability,
    cached_value: CacheSlot = .absent,
};

pub const StorageSourceRecord = struct {
    area: boundary.StorageArea,
    key: []const u8,
    payload_cap: HostValueCapability,
    from_payload: abi.RocErasedCallable,
    cap: HostValueCapability,
    cached_value: CacheSlot = .absent,
};

pub const Payload = union(enum) {
    ref: u64,
    const_value: ConstRecord,
    map: MapRecord,
    map2: Map2Record,
    combine: CombineRecord,
    task_source: TaskSourceRecord,
    interval_source: IntervalSourceRecord,
    location_source: LocationSourceRecord,
    online_source: OnlineSourceRecord,
    visibility_source: VisibilitySourceRecord,
    storage_source: StorageSourceRecord,
};

pub const EffectSourceRef = union(enum) {
    task: *TaskSourceRecord,
    interval: *IntervalSourceRecord,
    location: *LocationSourceRecord,
    online: *OnlineSourceRecord,
    visibility: *VisibilitySourceRecord,
    storage: *StorageSourceRecord,

    /// Returns the retained cache slot owned by this signal record kind.
    pub fn cachedSlot(self: EffectSourceRef) *CacheSlot {
        return switch (self) {
            .task => |payload| &payload.cached_value,
            .interval => |payload| &payload.cached_value,
            .location => |payload| &payload.cached_value,
            .online => |payload| &payload.cached_value,
            .visibility => |payload| &payload.cached_value,
            .storage => |payload| &payload.cached_value,
        };
    }

    /// Returns the app-compiled capability that owns values crossing this edge.
    pub fn capability(self: EffectSourceRef) HostValueCapability {
        return switch (self) {
            .task => |payload| payload.cap,
            .interval => |payload| payload.cap,
            .location => |payload| payload.cap,
            .online => |payload| payload.cap,
            .visibility => |payload| payload.cap,
            .storage => |payload| payload.cap,
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
            abi.decrefErasedCallable(payload.init, roc_host);
            releaseHostValueCapability(payload.cap, roc_host, metrics);
            metrics.bump(.closure_releases, 1);
        },
        .map => |payload| {
            payload.input.release(allocator, ctx, roc_host, metrics);
            var cached = payload.cached_value;
            cached.deinit(ctx, roc_host, metrics);
            abi.decrefErasedCallable(payload.transform, roc_host);
            releaseHostValueCapability(payload.cap, roc_host, metrics);
            metrics.bump(.closure_releases, 1);
        },
        .map2 => |payload| {
            payload.left.release(allocator, ctx, roc_host, metrics);
            payload.right.release(allocator, ctx, roc_host, metrics);
            var cached = payload.cached_value;
            cached.deinit(ctx, roc_host, metrics);
            abi.decrefErasedCallable(payload.transform, roc_host);
            releaseHostValueCapability(payload.cap, roc_host, metrics);
            metrics.bump(.closure_releases, 1);
        },
        .combine => |payload| {
            for (payload.children) |child| child.release(allocator, ctx, roc_host, metrics);
            allocator.free(payload.children);
            var cached = payload.cached_value;
            cached.deinit(ctx, roc_host, metrics);
            abi.decrefErasedCallable(payload.transform, roc_host);
            releaseHostValueCapability(payload.cap, roc_host, metrics);
            metrics.bump(.closure_releases, 1);
        },
        .task_source => |payload| {
            var cached = payload.cached_value;
            cached.deinit(ctx, roc_host, metrics);
            allocator.free(payload.name);
            releaseHostValueCapability(payload.payload_cap, roc_host, metrics);
            abi.decrefErasedCallable(payload.initial, roc_host);
            abi.decrefErasedCallable(payload.done, roc_host);
            abi.decrefErasedCallable(payload.failed, roc_host);
            releaseHostValueCapability(payload.cap, roc_host, metrics);
            metrics.bump(.closure_releases, 3);
        },
        .interval_source => |payload| {
            var cached = payload.cached_value;
            cached.deinit(ctx, roc_host, metrics);
            abi.decrefErasedCallable(payload.initial, roc_host);
            abi.decrefErasedCallable(payload.tick, roc_host);
            releaseHostValueCapability(payload.cap, roc_host, metrics);
            metrics.bump(.closure_releases, 2);
        },
        .location_source => |payload| {
            var cached = payload.cached_value;
            cached.deinit(ctx, roc_host, metrics);
            releaseHostValueCapability(payload.payload_cap, roc_host, metrics);
            abi.decrefErasedCallable(payload.from_payload, roc_host);
            releaseHostValueCapability(payload.cap, roc_host, metrics);
            metrics.bump(.closure_releases, 1);
        },
        .online_source => |payload| {
            var cached = payload.cached_value;
            cached.deinit(ctx, roc_host, metrics);
            releaseHostValueCapability(payload.payload_cap, roc_host, metrics);
            abi.decrefErasedCallable(payload.from_payload, roc_host);
            releaseHostValueCapability(payload.cap, roc_host, metrics);
            metrics.bump(.closure_releases, 1);
        },
        .visibility_source => |payload| {
            var cached = payload.cached_value;
            cached.deinit(ctx, roc_host, metrics);
            releaseHostValueCapability(payload.payload_cap, roc_host, metrics);
            abi.decrefErasedCallable(payload.from_payload, roc_host);
            releaseHostValueCapability(payload.cap, roc_host, metrics);
            metrics.bump(.closure_releases, 1);
        },
        .storage_source => |payload| {
            var cached = payload.cached_value;
            cached.deinit(ctx, roc_host, metrics);
            allocator.free(payload.key);
            releaseHostValueCapability(payload.payload_cap, roc_host, metrics);
            abi.decrefErasedCallable(payload.from_payload, roc_host);
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
            .const_value => |payload| retained.hostSignalTokenFromCallable(payload.init),
            .map => |payload| retained.hostSignalTokenFromCallable(payload.transform),
            .map2 => |payload| retained.hostSignalTokenFromCallable(payload.transform),
            .combine => |payload| retained.hostSignalTokenFromCallable(payload.transform),
            .task_source => |payload| retained.hostSignalTokenFromCallable(payload.initial),
            .interval_source => |payload| retained.hostSignalTokenFromCallable(payload.initial),
            .location_source => |payload| retained.hostSignalTokenFromCallable(payload.from_payload),
            .online_source => |payload| retained.hostSignalTokenFromCallable(payload.from_payload),
            .visibility_source => |payload| retained.hostSignalTokenFromCallable(payload.from_payload),
            .storage_source => |payload| retained.hostSignalTokenFromCallable(payload.from_payload),
        };
    }

    /// Returns the retained cache slot owned by this signal record kind.
    pub fn cachedSlot(self: *Record) ?*CacheSlot {
        return switch (self.payload) {
            .ref => null,
            .const_value => |*payload| &payload.cached_value,
            .map => |*payload| &payload.cached_value,
            .map2 => |*payload| &payload.cached_value,
            .combine => |*payload| &payload.cached_value,
            .task_source => |*payload| &payload.cached_value,
            .interval_source => |*payload| &payload.cached_value,
            .location_source => |*payload| &payload.cached_value,
            .online_source => |*payload| &payload.cached_value,
            .visibility_source => |*payload| &payload.cached_value,
            .storage_source => |*payload| &payload.cached_value,
        };
    }

    /// Returns the app-compiled capability that owns values crossing this edge.
    pub fn capability(self: *const Record, comptime Ctx: type, ctx: Ctx.Handle) HostValueCapability {
        return switch (self.payload) {
            .ref => |node_id| Ctx.stateCapability(ctx, node_id),
            .const_value => |payload| payload.cap,
            .map => |payload| payload.cap,
            .map2 => |payload| payload.cap,
            .combine => |payload| payload.cap,
            .task_source => |payload| payload.cap,
            .interval_source => |payload| payload.cap,
            .location_source => |payload| payload.cap,
            .online_source => |payload| payload.cap,
            .visibility_source => |payload| payload.cap,
            .storage_source => |payload| payload.cap,
        };
    }

    /// Returns the task source payload when this record has that exact kind.
    pub fn taskSource(self: *Record) ?*TaskSourceRecord {
        return switch (self.payload) {
            .task_source => |*payload| payload,
            .ref, .const_value, .map, .map2, .combine, .interval_source, .location_source, .online_source, .visibility_source, .storage_source => null,
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
            .ref, .const_value, .map, .map2, .combine, .task_source, .location_source, .online_source, .visibility_source, .storage_source => null,
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
            .ref, .const_value, .map, .map2, .combine, .task_source, .interval_source, .online_source, .visibility_source, .storage_source => null,
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
            .ref, .const_value, .map, .map2, .combine, .task_source, .interval_source, .location_source, .visibility_source, .storage_source => null,
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
            .ref, .const_value, .map, .map2, .combine, .task_source, .interval_source, .location_source, .online_source, .storage_source => null,
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
            .ref, .const_value, .map, .map2, .combine, .task_source, .interval_source, .location_source, .online_source, .visibility_source => null,
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
            .location_source => |*payload| .{ .location = payload },
            .online_source => |*payload| .{ .online = payload },
            .visibility_source => |*payload| .{ .visibility = payload },
            .storage_source => |*payload| .{ .storage = payload },
            .ref, .const_value, .map, .map2, .combine => null,
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
        .ref, .const_value, .task_source, .interval_source, .location_source, .online_source, .visibility_source, .storage_source => {},
        .map => |payload| walkTree(Context, context, payload.input, visit),
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
        .map2 => |payload| {
            try appendSignalRecordSourceNodeIdsFallible(allocator, source_node_ids, payload.left);
            try appendSignalRecordSourceNodeIdsFallible(allocator, source_node_ids, payload.right);
        },
        .combine => |payload| {
            for (payload.children) |child| {
                try appendSignalRecordSourceNodeIdsFallible(allocator, source_node_ids, child);
            }
        },
        .task_source, .interval_source, .location_source, .online_source, .visibility_source, .storage_source => {},
    }
}

test "fallible signal record construction preserves payload ownership on OOM" {
    var storage: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    try std.testing.expectError(error.OutOfMemory, Record.tryInit(fixed.allocator(), .{ .ref = 7 }));

    const record = try Record.tryInit(std.testing.allocator, .{ .ref = 7 });
    try std.testing.expectEqual(@as(Payload, .{ .ref = 7 }), record.payload);
    std.testing.allocator.destroy(record);
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
        .transform = null,
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
