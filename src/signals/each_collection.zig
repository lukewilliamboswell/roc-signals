//! Host-owned key storage and the allocation-free sink used by keyed collections.

const std = @import("std");
const abi = @import("roc_platform_abi.zig");

pub const SinkError = error{
    OutOfMemory,
    ResourceLimit,
    CountMismatch,
    ByteCountMismatch,
    RetryRequired,
    RetryNotRequired,
    RetryAlreadyUsed,
    InactiveSink,
    InvalidSinkToken,
    WrongSinkKind,
    ReentrantSink,
    OutOfOrder,
    InvalidSlot,
    InvalidOperation,
    DuplicateDescription,
};

pub const Description = union(enum) {
    snapshot: struct {
        generation: u64,
        item_count: usize,
        snapshot_key_bytes: usize,
    },
    delta: struct {
        generation: u64,
        parent: u64,
        item_count: usize,
        snapshot_key_bytes: usize,
        op_count: usize,
        delta_key_count: usize,
        delta_key_bytes: usize,
    },
};

pub const DescriptionSink = struct {
    value: ?Description = null,

    /// Records the single exact snapshot description emitted by Roc.
    pub fn pushSnapshot(self: *DescriptionSink, generation: u64, item_count: u64, key_bytes: u64) SinkError!void {
        if (self.value != null) return error.DuplicateDescription;
        if (generation == 0) return error.InvalidOperation;
        self.value = .{ .snapshot = .{
            .generation = generation,
            .item_count = std.math.cast(usize, item_count) orelse return error.ResourceLimit,
            .snapshot_key_bytes = std.math.cast(usize, key_bytes) orelse return error.ResourceLimit,
        } };
    }

    /// Records the single canonical delta description emitted by Roc.
    pub fn pushDelta(self: *DescriptionSink, generation: u64, parent: u64, item_count: u64, snapshot_key_bytes: u64, op_count: u64, delta_key_count: u64, delta_key_bytes: u64) SinkError!void {
        if (self.value != null) return error.DuplicateDescription;
        if (generation == 0 or parent == 0 or generation == parent) return error.InvalidOperation;
        self.value = .{ .delta = .{
            .generation = generation,
            .parent = parent,
            .item_count = std.math.cast(usize, item_count) orelse return error.ResourceLimit,
            .snapshot_key_bytes = std.math.cast(usize, snapshot_key_bytes) orelse return error.ResourceLimit,
            .op_count = std.math.cast(usize, op_count) orelse return error.ResourceLimit,
            .delta_key_count = std.math.cast(usize, delta_key_count) orelse return error.ResourceLimit,
            .delta_key_bytes = std.math.cast(usize, delta_key_bytes) orelse return error.ResourceLimit,
        } };
    }
};

/// One exact row in a counted `Rows` snapshot. Key bytes live in the sibling
/// `KeyStorage`; keeping the fixed-width fields dense avoids one allocation per
/// row while retaining exact UTF-8 identity at the host boundary.
pub const SnapshotRow = struct {
    slot: u64,
};

/// Stable-slot operands copied from one canonical `Rows` delta.
pub const DeltaOp = union(enum) {
    clear,
    insert: struct { slot: u64, before_slot: u64, key_index: usize },
    move: struct { first_slot: u64, count: u64, before_slot: u64 },
    remove: struct { first_slot: u64, count: u64 },
    update: struct { slot: u64, key_index: usize },
};

/// Fully host-owned, exactly counted snapshot scratch. Preparation reserves all
/// fixed-width and byte storage before Roc writes through the sink.
pub const SnapshotStorage = struct {
    rows: std.ArrayListUnmanaged(SnapshotRow) = .empty,
    keys: KeyStorage = .{},
    expected_count: usize = 0,
    complete: bool = false,

    /// Releases all snapshot scratch buffers.
    pub fn deinit(self: *SnapshotStorage, allocator: std.mem.Allocator) void {
        self.rows.deinit(allocator);
        self.keys.deinit(allocator);
        self.* = .{};
    }

    /// Reserves the exact advertised snapshot shape before activating its sink.
    pub fn prepare(self: *SnapshotStorage, allocator: std.mem.Allocator, expected_count: usize, expected_key_bytes: usize) SinkError!PreparedSnapshotSink {
        self.rows.clearRetainingCapacity();
        try self.rows.ensureTotalCapacityPrecise(allocator, expected_count);
        var keys = try self.keys.prepare(allocator, expected_count, expected_key_bytes);
        if (expected_key_bytes != 0) try self.keys.bytes.ensureTotalCapacityPrecise(allocator, expected_key_bytes);
        self.expected_count = expected_count;
        self.complete = false;
        keys.retry = true;
        keys.retry_expected_bytes = expected_key_bytes;
        return .{ .storage = self, .keys = keys };
    }
};

pub const PreparedSnapshotSink = struct {
    storage: *SnapshotStorage,
    keys: PreparedKeySink,

    /// Copies one ordered stable-slot/key record without allocating.
    pub fn pushBorrowed(self: *PreparedSnapshotSink, index: usize, slot: u64, key: []const u8) SinkError!void {
        if (index != self.storage.rows.items.len) return error.OutOfOrder;
        if (slot == 0) return error.InvalidSlot;
        try self.keys.pushBorrowed(key);
        self.storage.rows.appendAssumeCapacity(.{ .slot = slot });
    }

    /// Validates exact counts and seals the snapshot.
    pub fn finish(self: *PreparedSnapshotSink) SinkError!void {
        if (self.storage.rows.items.len != self.storage.expected_count) return error.CountMismatch;
        try self.keys.finish();
        self.storage.complete = true;
    }

    /// Discards an incomplete snapshot while retaining reusable capacity.
    pub fn abort(self: *PreparedSnapshotSink) void {
        self.storage.rows.clearRetainingCapacity();
        self.keys.abort();
        self.storage.complete = false;
    }
};

/// Fully host-owned canonical delta scratch. Key-bearing operations index the
/// compact key arena, so no operation owns a separately allocated string.
pub const DeltaStorage = struct {
    ops: std.ArrayListUnmanaged(DeltaOp) = .empty,
    keys: KeyStorage = .{},
    expected_ops: usize = 0,
    expected_keys: usize = 0,
    complete: bool = false,

    /// Releases all canonical delta scratch buffers.
    pub fn deinit(self: *DeltaStorage, allocator: std.mem.Allocator) void {
        self.ops.deinit(allocator);
        self.keys.deinit(allocator);
        self.* = .{};
    }

    /// Reserves the exact advertised delta shape before activating its sink.
    pub fn prepare(self: *DeltaStorage, allocator: std.mem.Allocator, expected_ops: usize, expected_keys: usize, expected_key_bytes: usize) SinkError!PreparedDeltaSink {
        self.ops.clearRetainingCapacity();
        try self.ops.ensureTotalCapacityPrecise(allocator, expected_ops);
        var keys = try self.keys.prepare(allocator, expected_keys, expected_key_bytes);
        if (expected_key_bytes != 0) try self.keys.bytes.ensureTotalCapacityPrecise(allocator, expected_key_bytes);
        keys.retry = true;
        keys.retry_expected_bytes = expected_key_bytes;
        self.expected_ops = expected_ops;
        self.expected_keys = expected_keys;
        self.complete = false;
        return .{ .storage = self, .keys = keys };
    }
};

pub const PreparedDeltaSink = struct {
    storage: *DeltaStorage,
    keys: PreparedKeySink,

    fn checkIndex(self: *const PreparedDeltaSink, op_index: usize) SinkError!void {
        if (op_index != self.storage.ops.items.len) return error.OutOfOrder;
        if (op_index >= self.storage.expected_ops) return error.CountMismatch;
    }

    /// Appends one canonical clear operation.
    pub fn pushClear(self: *PreparedDeltaSink, op_index: usize) SinkError!void {
        try self.checkIndex(op_index);
        self.storage.ops.appendAssumeCapacity(.clear);
    }

    /// Appends one stable-slot insert and copies its exact key.
    pub fn pushInsert(self: *PreparedDeltaSink, op_index: usize, slot: u64, before_slot: u64, key: []const u8) SinkError!void {
        try self.checkIndex(op_index);
        if (slot == 0) return error.InvalidSlot;
        const key_index = self.keys.emitted_count;
        try self.keys.pushBorrowed(key);
        self.storage.ops.appendAssumeCapacity(.{ .insert = .{ .slot = slot, .before_slot = before_slot, .key_index = key_index } });
    }

    /// Appends one nonempty stable-slot range move.
    pub fn pushMove(self: *PreparedDeltaSink, op_index: usize, first_slot: u64, count: u64, before_slot: u64) SinkError!void {
        try self.checkIndex(op_index);
        if (first_slot == 0 or count == 0) return error.InvalidOperation;
        self.storage.ops.appendAssumeCapacity(.{ .move = .{ .first_slot = first_slot, .count = count, .before_slot = before_slot } });
    }

    /// Appends one nonempty stable-slot range removal.
    pub fn pushRemove(self: *PreparedDeltaSink, op_index: usize, first_slot: u64, count: u64) SinkError!void {
        try self.checkIndex(op_index);
        if (first_slot == 0 or count == 0) return error.InvalidOperation;
        self.storage.ops.appendAssumeCapacity(.{ .remove = .{ .first_slot = first_slot, .count = count } });
    }

    /// Appends one stable-slot item update and copies its authenticated key.
    pub fn pushUpdate(self: *PreparedDeltaSink, op_index: usize, slot: u64, key: []const u8) SinkError!void {
        try self.checkIndex(op_index);
        if (slot == 0) return error.InvalidSlot;
        const key_index = self.keys.emitted_count;
        try self.keys.pushBorrowed(key);
        self.storage.ops.appendAssumeCapacity(.{ .update = .{ .slot = slot, .key_index = key_index } });
    }

    /// Validates exact operation/key counts and seals the delta.
    pub fn finish(self: *PreparedDeltaSink) SinkError!void {
        if (self.storage.ops.items.len != self.storage.expected_ops or self.keys.emitted_count != self.storage.expected_keys) return error.CountMismatch;
        try self.keys.finish();
        self.storage.complete = true;
    }

    /// Discards an incomplete delta while retaining reusable capacity.
    pub fn abort(self: *PreparedDeltaSink) void {
        self.storage.ops.clearRetainingCapacity();
        self.keys.abort();
        self.storage.complete = false;
    }
};

const Phase = union(enum) {
    idle,
    first,
    retry_pending: usize,
    retry,
    complete,
};

pub const KeyStorage = struct {
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    offsets: std.ArrayListUnmanaged(u32) = .empty,
    hashes: std.ArrayListUnmanaged(u64) = .empty,
    expected_count: usize = 0,
    maximum_bytes: usize = 0,
    phase: Phase = .idle,

    /// Releases all host-owned key buffers and resets the storage to an empty state.
    pub fn deinit(self: *KeyStorage, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
        self.offsets.deinit(allocator);
        self.hashes.deinit(allocator);
        self.* = .{};
    }

    /// Pre-reserves fixed-size metadata and starts the first non-allocating key-copy pass.
    pub fn prepare(
        self: *KeyStorage,
        allocator: std.mem.Allocator,
        expected_count: usize,
        maximum_bytes: usize,
    ) SinkError!PreparedKeySink {
        const offset_count = std.math.add(usize, expected_count, 1) catch return error.ResourceLimit;
        if (maximum_bytes > std.math.maxInt(u32)) return error.ResourceLimit;
        if (expected_count > std.math.maxInt(u32)) return error.ResourceLimit;

        self.offsets.clearRetainingCapacity();
        self.hashes.clearRetainingCapacity();
        self.bytes.clearRetainingCapacity();
        try self.offsets.ensureTotalCapacityPrecise(allocator, offset_count);
        try self.hashes.ensureTotalCapacityPrecise(allocator, expected_count);
        self.expected_count = expected_count;
        self.maximum_bytes = maximum_bytes;
        self.phase = .first;
        return PreparedKeySink.init(self, false, null);
    }

    /// Allocates the exact byte capacity measured by the first pass and starts the sole retry.
    pub fn beginRetry(self: *KeyStorage, allocator: std.mem.Allocator) SinkError!PreparedKeySink {
        const required = switch (self.phase) {
            .retry_pending => |value| value,
            .retry, .complete => return error.RetryAlreadyUsed,
            else => return error.RetryNotRequired,
        };
        if (required > self.maximum_bytes or required > std.math.maxInt(u32)) return error.ResourceLimit;
        try self.bytes.ensureTotalCapacityPrecise(allocator, required);
        self.bytes.clearRetainingCapacity();
        self.offsets.clearRetainingCapacity();
        self.hashes.clearRetainingCapacity();
        self.phase = .retry;
        return PreparedKeySink.init(self, true, required);
    }

    /// Returns the exact bytes for one completed key without exposing mutable storage.
    pub fn key(self: *const KeyStorage, index: usize) ?[]const u8 {
        if (self.phase != .complete or index >= self.expected_count) return null;
        const start: usize = self.offsets.items[index];
        const end: usize = self.offsets.items[index + 1];
        return self.bytes.items[start..end];
    }
};

pub const PreparedKeySink = struct {
    storage: *KeyStorage,
    emitted_count: usize,
    required_bytes: usize,
    count_only: bool,
    retry: bool,
    retry_expected_bytes: ?usize,

    fn init(storage: *KeyStorage, retry: bool, retry_expected_bytes: ?usize) PreparedKeySink {
        storage.offsets.appendAssumeCapacity(0);
        return .{
            .storage = storage,
            .emitted_count = 0,
            .required_bytes = 0,
            .count_only = false,
            .retry = retry,
            .retry_expected_bytes = retry_expected_bytes,
        };
    }

    /// Copies one sequential key into reserved host storage and always consumes the owned Roc string.
    pub fn pushOwned(self: *PreparedKeySink, value: abi.RocStr, roc_host: *abi.RocHost) SinkError!void {
        defer abi.RocStrRelease.release(value, roc_host);
        return self.pushBorrowed(value.asSlice());
    }

    fn pushBorrowed(self: *PreparedKeySink, bytes: []const u8) SinkError!void {
        if (self.emitted_count >= self.storage.expected_count) return error.CountMismatch;

        const next_required = std.math.add(usize, self.required_bytes, bytes.len) catch return error.ResourceLimit;
        if (next_required > self.storage.maximum_bytes or next_required > std.math.maxInt(u32)) return error.ResourceLimit;
        self.required_bytes = next_required;

        if (!self.count_only and self.storage.bytes.capacity - self.storage.bytes.items.len >= bytes.len) {
            self.storage.bytes.appendSliceAssumeCapacity(bytes);
            self.storage.hashes.appendAssumeCapacity(std.hash.Wyhash.hash(0, bytes));
            self.storage.offsets.appendAssumeCapacity(@intCast(next_required));
        } else {
            if (self.retry) return error.ByteCountMismatch;
            self.count_only = true;
        }
        self.emitted_count += 1;
    }

    /// Validates the pass and either seals complete storage or records the exact retry capacity.
    pub fn finish(self: *PreparedKeySink) SinkError!void {
        if (self.emitted_count != self.storage.expected_count) return error.CountMismatch;
        if (self.retry) {
            if (self.retry_expected_bytes.? != self.required_bytes) return error.ByteCountMismatch;
            if (self.count_only or self.storage.bytes.items.len != self.required_bytes) return error.ByteCountMismatch;
            self.storage.phase = .complete;
            return;
        }
        if (self.count_only) {
            self.storage.bytes.clearRetainingCapacity();
            self.storage.offsets.clearRetainingCapacity();
            self.storage.hashes.clearRetainingCapacity();
            self.storage.phase = .{ .retry_pending = self.required_bytes };
            return error.RetryRequired;
        }
        self.storage.phase = .complete;
    }

    /// Discards the current pass while retaining all allocated capacity for a later preparation.
    pub fn abort(self: *PreparedKeySink) void {
        self.storage.bytes.clearRetainingCapacity();
        self.storage.offsets.clearRetainingCapacity();
        self.storage.hashes.clearRetainingCapacity();
        self.storage.phase = .idle;
    }
};

pub const BoolStorage = struct {
    values: std.ArrayListUnmanaged(bool) = .empty,
    expected_count: usize = 0,
    complete: bool = false,

    /// Releases the comparison-result buffer and resets the storage to an empty state.
    pub fn deinit(self: *BoolStorage, allocator: std.mem.Allocator) void {
        self.values.deinit(allocator);
        self.* = .{};
    }

    /// Pre-reserves every result slot and returns a sink whose writes cannot allocate.
    pub fn prepare(self: *BoolStorage, allocator: std.mem.Allocator, expected_count: usize) SinkError!PreparedBoolSink {
        self.values.clearRetainingCapacity();
        try self.values.ensureTotalCapacityPrecise(allocator, expected_count);
        self.expected_count = expected_count;
        self.complete = false;
        return .{ .storage = self };
    }
};

pub const PreparedBoolSink = struct {
    storage: *BoolStorage,
    emitted_count: usize = 0,

    /// Writes the next comparison result into preallocated storage in strict index order.
    pub fn push(self: *PreparedBoolSink, item_index: usize, value: bool) SinkError!void {
        if (item_index != self.emitted_count) return error.OutOfOrder;
        if (self.emitted_count >= self.storage.expected_count) return error.CountMismatch;
        self.storage.values.appendAssumeCapacity(value);
        self.emitted_count += 1;
    }

    /// Validates the exact result count and seals the comparison buffer for reading.
    pub fn finish(self: *PreparedBoolSink) SinkError!void {
        if (self.emitted_count != self.storage.expected_count) return error.CountMismatch;
        self.storage.complete = true;
    }

    /// Discards comparison results while retaining their backing capacity for reuse.
    pub fn abort(self: *PreparedBoolSink) void {
        self.storage.values.clearRetainingCapacity();
        self.storage.complete = false;
    }
};

pub const SinkToken = enum(u64) {
    invalid = 0,
    _,
};

const ActiveSink = union(enum) {
    description: struct { token: SinkToken, sink: *DescriptionSink },
    key: struct { token: SinkToken, sink: *PreparedKeySink },
    boolean: struct { token: SinkToken, sink: *PreparedBoolSink },
    snapshot: struct { token: SinkToken, sink: *PreparedSnapshotSink },
    delta: struct { token: SinkToken, sink: *PreparedDeltaSink },
};

pub const ActiveSinks = struct {
    next_token: u64 = 1,
    active: ?ActiveSink = null,

    fn mintToken(self: *ActiveSinks) SinkError!SinkToken {
        if (self.next_token == 0 or self.next_token == std.math.maxInt(u64)) return error.ResourceLimit;
        const token: SinkToken = @enumFromInt(self.next_token);
        self.next_token += 1;
        return token;
    }

    /// Activates the description sink for exactly one describe callback.
    pub fn activateDescription(self: *ActiveSinks, sink: *DescriptionSink) SinkError!SinkToken {
        if (self.active != null) return error.ReentrantSink;
        const token = try self.mintToken();
        sink.value = null;
        self.active = .{ .description = .{ .token = token, .sink = sink } };
        return token;
    }

    fn requireDescription(self: *ActiveSinks, token: SinkToken) SinkError!*DescriptionSink {
        const active = self.active orelse return error.InactiveSink;
        return switch (active) {
            .description => |entry| if (entry.token == token) entry.sink else error.InvalidSinkToken,
            inline else => |entry| if (entry.token == token) error.WrongSinkKind else error.InvalidSinkToken,
        };
    }

    /// Routes an exact snapshot description through the active call token.
    pub fn pushSnapshotDescription(self: *ActiveSinks, token: SinkToken, generation: u64, item_count: u64, key_bytes: u64) SinkError!void {
        try (try self.requireDescription(token)).pushSnapshot(generation, item_count, key_bytes);
    }

    /// Routes a canonical delta description through the active call token.
    pub fn pushDeltaDescription(self: *ActiveSinks, token: SinkToken, generation: u64, parent: u64, item_count: u64, snapshot_key_bytes: u64, op_count: u64, delta_key_count: u64, delta_key_bytes: u64) SinkError!void {
        try (try self.requireDescription(token)).pushDelta(generation, parent, item_count, snapshot_key_bytes, op_count, delta_key_count, delta_key_bytes);
    }

    /// Closes the describe call and returns its single validated result.
    pub fn finishDescription(self: *ActiveSinks, token: SinkToken) SinkError!Description {
        const sink = try self.requireDescription(token);
        self.active = null;
        return sink.value orelse error.CountMismatch;
    }

    /// Activates one prepared key sink and returns its nonzero call-scoped token.
    pub fn activateKey(self: *ActiveSinks, sink: *PreparedKeySink) SinkError!SinkToken {
        if (self.active != null) return error.ReentrantSink;
        const token = try self.mintToken();
        self.active = .{ .key = .{ .token = token, .sink = sink } };
        return token;
    }

    /// Activates one prepared boolean sink and returns its nonzero call-scoped token.
    pub fn activateBool(self: *ActiveSinks, sink: *PreparedBoolSink) SinkError!SinkToken {
        if (self.active != null) return error.ReentrantSink;
        const token = try self.mintToken();
        self.active = .{ .boolean = .{ .token = token, .sink = sink } };
        return token;
    }

    /// Activates an exactly counted snapshot sink for one callback invocation.
    pub fn activateSnapshot(self: *ActiveSinks, sink: *PreparedSnapshotSink) SinkError!SinkToken {
        if (self.active != null) return error.ReentrantSink;
        const token = try self.mintToken();
        self.active = .{ .snapshot = .{ .token = token, .sink = sink } };
        return token;
    }

    /// Activates an exactly counted canonical delta sink for one callback invocation.
    pub fn activateDelta(self: *ActiveSinks, sink: *PreparedDeltaSink) SinkError!SinkToken {
        if (self.active != null) return error.ReentrantSink;
        const token = try self.mintToken();
        self.active = .{ .delta = .{ .token = token, .sink = sink } };
        return token;
    }

    /// Routes one snapshot row into fixed-width and exact-byte storage.
    pub fn pushSnapshot(self: *ActiveSinks, token: SinkToken, index: usize, slot: u64, key: []const u8) SinkError!void {
        const active = self.active orelse return error.InactiveSink;
        switch (active) {
            .snapshot => |entry| {
                if (entry.token != token) return error.InvalidSinkToken;
                return entry.sink.pushBorrowed(index, slot, key);
            },
            inline else => |entry| return if (entry.token == token) error.WrongSinkKind else error.InvalidSinkToken,
        }
    }

    fn requireDelta(self: *ActiveSinks, token: SinkToken) SinkError!*PreparedDeltaSink {
        const active = self.active orelse return error.InactiveSink;
        return switch (active) {
            .delta => |entry| if (entry.token == token) entry.sink else error.InvalidSinkToken,
            inline else => |entry| if (entry.token == token) error.WrongSinkKind else error.InvalidSinkToken,
        };
    }

    /// Routes one clear operation to the active delta sink.
    pub fn pushDeltaClear(self: *ActiveSinks, token: SinkToken, op_index: usize) SinkError!void {
        try (try self.requireDelta(token)).pushClear(op_index);
    }

    /// Routes one insert operation to the active delta sink.
    pub fn pushDeltaInsert(self: *ActiveSinks, token: SinkToken, op_index: usize, slot: u64, before_slot: u64, key: []const u8) SinkError!void {
        try (try self.requireDelta(token)).pushInsert(op_index, slot, before_slot, key);
    }

    /// Routes one range move to the active delta sink.
    pub fn pushDeltaMove(self: *ActiveSinks, token: SinkToken, op_index: usize, first_slot: u64, count: u64, before_slot: u64) SinkError!void {
        try (try self.requireDelta(token)).pushMove(op_index, first_slot, count, before_slot);
    }

    /// Routes one range removal to the active delta sink.
    pub fn pushDeltaRemove(self: *ActiveSinks, token: SinkToken, op_index: usize, first_slot: u64, count: u64) SinkError!void {
        try (try self.requireDelta(token)).pushRemove(op_index, first_slot, count);
    }

    /// Routes one item update to the active delta sink.
    pub fn pushDeltaUpdate(self: *ActiveSinks, token: SinkToken, op_index: usize, slot: u64, key: []const u8) SinkError!void {
        try (try self.requireDelta(token)).pushUpdate(op_index, slot, key);
    }

    /// Routes one indexed owned Roc string to the active key sink and consumes it on every outcome.
    pub fn pushKey(self: *ActiveSinks, token: SinkToken, item_index: usize, value: abi.RocStr, roc_host: *abi.RocHost) SinkError!void {
        defer abi.RocStrRelease.release(value, roc_host);
        return self.pushKeyBorrowed(token, item_index, value.asSlice());
    }

    /// Routes borrowed key bytes after the host boundary has taken responsibility
    /// for releasing the owned Roc string that supplied them.
    pub fn pushKeyBorrowed(self: *ActiveSinks, token: SinkToken, item_index: usize, value: []const u8) SinkError!void {
        const active = self.active orelse return error.InactiveSink;
        switch (active) {
            .key => |entry| {
                if (entry.token != token) return error.InvalidSinkToken;
                if (item_index != entry.sink.emitted_count) return error.OutOfOrder;
                return entry.sink.pushBorrowed(value);
            },
            inline else => |entry| {
                if (entry.token == token) return error.WrongSinkKind;
                return error.InvalidSinkToken;
            },
        }
    }

    /// Routes one indexed primitive comparison result to the active boolean sink.
    pub fn pushBool(self: *ActiveSinks, token: SinkToken, item_index: usize, value: bool) SinkError!void {
        const active = self.active orelse return error.InactiveSink;
        switch (active) {
            .boolean => |entry| {
                if (entry.token != token) return error.InvalidSinkToken;
                return entry.sink.push(item_index, value);
            },
            inline else => |entry| {
                if (entry.token == token) return error.WrongSinkKind;
                return error.InvalidSinkToken;
            },
        }
    }

    /// Finishes the active key sink, invalidating its token even when validation fails.
    pub fn finishKey(self: *ActiveSinks, token: SinkToken) SinkError!void {
        const active = self.active orelse return error.InactiveSink;
        const sink = switch (active) {
            .key => |entry| blk: {
                if (entry.token != token) return error.InvalidSinkToken;
                break :blk entry.sink;
            },
            inline else => |entry| {
                if (entry.token == token) return error.WrongSinkKind;
                return error.InvalidSinkToken;
            },
        };
        self.active = null;
        return sink.finish();
    }

    /// Finishes the active boolean sink, invalidating its token even when validation fails.
    pub fn finishBool(self: *ActiveSinks, token: SinkToken) SinkError!void {
        const active = self.active orelse return error.InactiveSink;
        const sink = switch (active) {
            .boolean => |entry| blk: {
                if (entry.token != token) return error.InvalidSinkToken;
                break :blk entry.sink;
            },
            inline else => |entry| {
                if (entry.token == token) return error.WrongSinkKind;
                return error.InvalidSinkToken;
            },
        };
        self.active = null;
        return sink.finish();
    }

    /// Finishes a snapshot call and invalidates its token on every outcome.
    pub fn finishSnapshot(self: *ActiveSinks, token: SinkToken) SinkError!void {
        const active = self.active orelse return error.InactiveSink;
        const sink = switch (active) {
            .snapshot => |entry| blk: {
                if (entry.token != token) return error.InvalidSinkToken;
                break :blk entry.sink;
            },
            inline else => |entry| {
                if (entry.token == token) return error.WrongSinkKind;
                return error.InvalidSinkToken;
            },
        };
        self.active = null;
        return sink.finish();
    }

    /// Finishes a canonical delta call and invalidates its token on every outcome.
    pub fn finishDelta(self: *ActiveSinks, token: SinkToken) SinkError!void {
        const active = self.active orelse return error.InactiveSink;
        const sink = switch (active) {
            .delta => |entry| blk: {
                if (entry.token != token) return error.InvalidSinkToken;
                break :blk entry.sink;
            },
            inline else => |entry| {
                if (entry.token == token) return error.WrongSinkKind;
                return error.InvalidSinkToken;
            },
        };
        self.active = null;
        return sink.finish();
    }

    /// Aborts the active sink identified by `token` and invalidates the call scope.
    pub fn abort(self: *ActiveSinks, token: SinkToken) SinkError!void {
        const active = self.active orelse return error.InactiveSink;
        switch (active) {
            .key => |entry| {
                if (entry.token != token) return error.InvalidSinkToken;
                entry.sink.abort();
            },
            .boolean => |entry| {
                if (entry.token != token) return error.InvalidSinkToken;
                entry.sink.abort();
            },
            .snapshot => |entry| {
                if (entry.token != token) return error.InvalidSinkToken;
                entry.sink.abort();
            },
            .delta => |entry| {
                if (entry.token != token) return error.InvalidSinkToken;
                entry.sink.abort();
            },
            .description => |entry| {
                if (entry.token != token) return error.InvalidSinkToken;
                entry.sink.value = null;
            },
        }
        self.active = null;
    }
};

const TestHost = struct {
    const arena_alignment = 64;

    allocations: usize = 0,
    deallocations: usize = 0,
    used: usize = 0,
    storage: [64 * 1024]u8 align(arena_alignment) = undefined,

    fn rocAlloc(raw: *abi.RocHost, size: usize, alignment: usize) callconv(.c) ?*anyopaque {
        const self: *TestHost = @ptrCast(@alignCast(raw.env));
        if (alignment == 0 or !std.math.isPowerOfTwo(alignment) or alignment > arena_alignment) return null;
        const start = std.mem.alignForward(usize, self.used, alignment);
        const end = std.math.add(usize, start, size) catch return null;
        if (end > self.storage.len) return null;
        self.used = end;
        self.allocations += 1;
        return @ptrCast(self.storage[start..].ptr);
    }

    fn rocDealloc(raw: *abi.RocHost, _: *anyopaque, _: usize) callconv(.c) void {
        const self: *TestHost = @ptrCast(@alignCast(raw.env));
        self.deallocations += 1;
    }

    fn rocRealloc(_: *abi.RocHost, _: *anyopaque, _: usize, _: usize) callconv(.c) ?*anyopaque {
        return null;
    }
    fn message(_: *abi.RocHost, _: [*]const u8, _: usize) callconv(.c) void {}

    fn host(self: *TestHost) abi.RocHost {
        return .{ .env = self, .roc_alloc = rocAlloc, .roc_dealloc = rocDealloc, .roc_realloc = rocRealloc, .roc_dbg = message, .roc_expect_failed = message, .roc_crashed = message };
    }
};

fn pushText(sink: *PreparedKeySink, text: []const u8, host: *abi.RocHost) !void {
    try sink.pushOwned(abi.RocStr.fromSlice(text, host), host);
}

test "key sink stores empty, small, long, and non-ASCII keys exactly" {
    var storage: KeyStorage = .{};
    defer storage.deinit(std.testing.allocator);
    var test_host = TestHost{};
    var host = test_host.host();
    var sink = try storage.prepare(std.testing.allocator, 4, 4096);
    try pushText(&sink, "", &host);
    try pushText(&sink, "small", &host);
    try pushText(&sink, "this string is deliberately longer than Roc's inline string storage", &host);
    try pushText(&sink, "Roc 🚀", &host);
    try std.testing.expectError(error.RetryRequired, sink.finish());
    var retry = try storage.beginRetry(std.testing.allocator);
    try pushText(&retry, "", &host);
    try pushText(&retry, "small", &host);
    try pushText(&retry, "this string is deliberately longer than Roc's inline string storage", &host);
    try pushText(&retry, "Roc 🚀", &host);
    try retry.finish();
    try std.testing.expectEqualStrings("", storage.key(0).?);
    try std.testing.expectEqualStrings("small", storage.key(1).?);
    try std.testing.expectEqualStrings("this string is deliberately longer than Roc's inline string storage", storage.key(2).?);
    try std.testing.expectEqualStrings("Roc 🚀", storage.key(3).?);
}

test "key sink measures overflow and completes one exact-capacity retry" {
    var storage: KeyStorage = .{};
    defer storage.deinit(std.testing.allocator);
    var test_host = TestHost{};
    var host = test_host.host();
    var first = try storage.prepare(std.testing.allocator, 2, 100);
    try pushText(&first, "abcdefghijklmnop", &host);
    try pushText(&first, "qrstuvwxyz", &host);
    try std.testing.expectError(error.RetryRequired, first.finish());
    var retry = try storage.beginRetry(std.testing.allocator);
    try pushText(&retry, "abcdefghijklmnop", &host);
    try pushText(&retry, "qrstuvwxyz", &host);
    try retry.finish();
    try std.testing.expectEqualStrings("qrstuvwxyz", storage.key(1).?);
    try std.testing.expectError(error.RetryAlreadyUsed, storage.beginRetry(std.testing.allocator));
}

test "key sink rejects count and retry byte mismatches" {
    var storage: KeyStorage = .{};
    defer storage.deinit(std.testing.allocator);
    var test_host = TestHost{};
    var host = test_host.host();
    var first = try storage.prepare(std.testing.allocator, 2, 100);
    try pushText(&first, "012345678901234567890123", &host);
    try std.testing.expectError(error.CountMismatch, first.finish());

    first = try storage.prepare(std.testing.allocator, 1, 100);
    try pushText(&first, "012345678901234567890123456789", &host);
    try std.testing.expectError(error.RetryRequired, first.finish());
    var retry = try storage.beginRetry(std.testing.allocator);
    try pushText(&retry, "short", &host);
    try std.testing.expectError(error.ByteCountMismatch, retry.finish());
}

test "counted Rows snapshot sink validates order slots and exact bytes" {
    var storage: SnapshotStorage = .{};
    defer storage.deinit(std.testing.allocator);
    var sink = try storage.prepare(std.testing.allocator, 2, 3);
    try sink.pushBorrowed(0, 17, "a");
    try sink.pushBorrowed(1, 29, "bc");
    try sink.finish();
    try std.testing.expect(storage.complete);
    try std.testing.expectEqual(@as(u64, 17), storage.rows.items[0].slot);
    try std.testing.expectEqualStrings("bc", storage.keys.key(1).?);
}

test "counted Rows delta sink stores stable operands and rejects malformed ranges" {
    var storage: DeltaStorage = .{};
    defer storage.deinit(std.testing.allocator);
    var sink = try storage.prepare(std.testing.allocator, 3, 2, 2);
    try sink.pushInsert(0, 7, 0, "a");
    try sink.pushMove(1, 7, 1, 9);
    try sink.pushUpdate(2, 7, "b");
    try sink.finish();
    try std.testing.expect(storage.complete);
    try std.testing.expectEqual(@as(usize, 3), storage.ops.items.len);
    try std.testing.expectEqualStrings("a", storage.keys.key(0).?);

    var malformed = try storage.prepare(std.testing.allocator, 1, 0, 0);
    try std.testing.expectError(error.InvalidOperation, malformed.pushRemove(0, 7, 0));
    malformed.abort();
}

test "key sink enforces configured and representational resource limits" {
    var storage: KeyStorage = .{};
    defer storage.deinit(std.testing.allocator);
    var test_host = TestHost{};
    var host = test_host.host();
    try std.testing.expectError(error.ResourceLimit, storage.prepare(std.testing.allocator, 0, @as(usize, std.math.maxInt(u32)) + 1));
    var sink = try storage.prepare(std.testing.allocator, 1, 3);
    try std.testing.expectError(error.ResourceLimit, pushText(&sink, "four", &host));
}

test "boolean sink writes preallocated results sequentially and validates exact count" {
    var storage: BoolStorage = .{};
    defer storage.deinit(std.testing.allocator);
    var sink = try storage.prepare(std.testing.allocator, 3);
    try sink.push(0, true);
    try std.testing.expectError(error.OutOfOrder, sink.push(2, false));
    try sink.push(1, false);
    try std.testing.expectError(error.CountMismatch, sink.finish());
    try sink.push(2, true);
    try sink.finish();
    try std.testing.expect(storage.complete);
    try std.testing.expectEqualSlices(bool, &.{ true, false, true }, storage.values.items);
    try std.testing.expectError(error.CountMismatch, sink.push(3, false));
}

test "boolean sink abort clears values while retaining reusable capacity" {
    var storage: BoolStorage = .{};
    defer storage.deinit(std.testing.allocator);
    var sink = try storage.prepare(std.testing.allocator, 2);
    const capacity = storage.values.capacity;
    try sink.push(0, true);
    sink.abort();
    try std.testing.expectEqual(@as(usize, 0), storage.values.items.len);
    try std.testing.expectEqual(capacity, storage.values.capacity);
    try std.testing.expect(!storage.complete);
}

test "active sinks route sequential key writes and monotonically invalidate call tokens" {
    var key_storage: KeyStorage = .{};
    defer key_storage.deinit(std.testing.allocator);
    var bool_storage: BoolStorage = .{};
    defer bool_storage.deinit(std.testing.allocator);
    var test_host = TestHost{};
    var host = test_host.host();
    var active: ActiveSinks = .{};

    var first_key_sink = try key_storage.prepare(std.testing.allocator, 1, 32);
    try pushText(&first_key_sink, "key", &host);
    try std.testing.expectError(error.RetryRequired, first_key_sink.finish());
    var key_sink = try key_storage.beginRetry(std.testing.allocator);
    const key_token = try active.activateKey(&key_sink);
    try std.testing.expect(@intFromEnum(key_token) != 0);
    try std.testing.expectError(error.ReentrantSink, active.activateKey(&key_sink));
    try std.testing.expectError(error.OutOfOrder, active.pushKey(key_token, 1, abi.RocStr.fromSlice("wrong-index-key-over-inline", &host), &host));
    try active.pushKey(key_token, 0, abi.RocStr.fromSlice("key", &host), &host);
    try active.finishKey(key_token);
    try std.testing.expectError(error.InactiveSink, active.pushBool(key_token, 0, true));

    var bool_sink = try bool_storage.prepare(std.testing.allocator, 1);
    const bool_token = try active.activateBool(&bool_sink);
    try std.testing.expect(@intFromEnum(bool_token) > @intFromEnum(key_token));
    try std.testing.expectError(error.InvalidSinkToken, active.pushBool(key_token, 0, true));
    try std.testing.expectError(error.WrongSinkKind, active.pushKey(bool_token, 0, abi.RocStr.fromSlice("wrong-kind-key-over-inline", &host), &host));
    try active.pushBool(bool_token, 0, true);
    try active.finishBool(bool_token);
    try std.testing.expectEqual(test_host.allocations, test_host.deallocations);
}

test "active sinks distinguish stale, wrong-kind, reentrant, and inactive calls" {
    var key_storage: KeyStorage = .{};
    defer key_storage.deinit(std.testing.allocator);
    var bool_storage: BoolStorage = .{};
    defer bool_storage.deinit(std.testing.allocator);
    var active: ActiveSinks = .{};
    var key_sink = try key_storage.prepare(std.testing.allocator, 0, 0);
    var bool_sink = try bool_storage.prepare(std.testing.allocator, 0);
    const key_token = try active.activateKey(&key_sink);
    try std.testing.expectError(error.WrongSinkKind, active.pushBool(key_token, 0, true));
    try std.testing.expectError(error.ReentrantSink, active.activateBool(&bool_sink));
    try active.abort(key_token);
    try std.testing.expectError(error.InactiveSink, active.finishKey(key_token));

    const bool_token = try active.activateBool(&bool_sink);
    try std.testing.expectError(error.InvalidSinkToken, active.finishBool(key_token));
    try active.abort(bool_token);
    try std.testing.expectError(error.InactiveSink, active.abort(bool_token));
}

test "finish failures close the active call and abort preserves preallocated capacity" {
    var storage: BoolStorage = .{};
    defer storage.deinit(std.testing.allocator);
    var active: ActiveSinks = .{};
    var sink = try storage.prepare(std.testing.allocator, 2);
    const capacity = storage.values.capacity;
    const first_token = try active.activateBool(&sink);
    try active.pushBool(first_token, 0, true);
    try std.testing.expectError(error.CountMismatch, active.finishBool(first_token));
    try std.testing.expectError(error.InactiveSink, active.pushBool(first_token, 1, false));

    sink = try storage.prepare(std.testing.allocator, 2);
    const second_token = try active.activateBool(&sink);
    try active.pushBool(second_token, 0, false);
    try active.abort(second_token);
    try std.testing.expectEqual(@as(usize, 0), storage.values.items.len);
    try std.testing.expectEqual(capacity, storage.values.capacity);
}

test "sink token exhaustion refuses activation without installing a sink" {
    var storage: BoolStorage = .{};
    defer storage.deinit(std.testing.allocator);
    var sink = try storage.prepare(std.testing.allocator, 0);
    var active: ActiveSinks = .{ .next_token = std.math.maxInt(u64) };
    try std.testing.expectError(error.ResourceLimit, active.activateBool(&sink));
    try std.testing.expect(active.active == null);
}
