//! Transaction journal used while preparing descriptor collection.
//!
//! Actions own every provisional resource until `commit`. Aborting destroys
//! them in reverse construction order. Commit is allocation-free: all action
//! storage and action-specific capacity must be prepared before it begins.

const std = @import("std");
const ids = @import("ids.zig");
const scope_tree = @import("scope_tree.zig");

pub const IdentityKey = u128;

pub const IdentityIntent = struct {
    key: IdentityKey,
    id: u64,
};

const TransactionPhase = enum {
    preparing,
    committed,
};

pub const IdentityOverlay = struct {
    provisional_by_key: std.AutoHashMapUnmanaged(IdentityKey, u64) = .{},
    reserved_ids: std.AutoHashMapUnmanaged(u64, void) = .{},
    intents: std.ArrayListUnmanaged(IdentityIntent) = .empty,
    prepared_remaining: usize = 0,
    phase: TransactionPhase = .preparing,

    /// Releases every resource owned by this value and leaves no retained host or Roc ownership behind.
    pub fn deinit(self: *IdentityOverlay, allocator: std.mem.Allocator) void {
        self.provisional_by_key.deinit(allocator);
        self.reserved_ids.deinit(allocator);
        self.intents.deinit(allocator);
        self.* = .{};
    }

    /// Preflights fallible growth so the later commit phase can remain allocation-free.
    pub fn prepare(self: *IdentityOverlay, allocator: std.mem.Allocator, additional: usize) std.mem.Allocator.Error!void {
        const next_remaining = std.math.add(usize, self.prepared_remaining, additional) catch return error.OutOfMemory;
        const outstanding = std.math.cast(u32, next_remaining) orelse return error.OutOfMemory;
        try self.provisional_by_key.ensureUnusedCapacity(allocator, outstanding);
        try self.reserved_ids.ensureUnusedCapacity(allocator, outstanding);
        try self.intents.ensureUnusedCapacity(allocator, next_remaining);
        self.prepared_remaining = next_remaining;
    }

    /// Resolves the requested identity from the transaction overlay before consulting committed state.
    pub fn lookup(self: *const IdentityOverlay, key: IdentityKey, active_id: ?u64) ?u64 {
        return self.provisional_by_key.get(key) orelse active_id;
    }

    /// Stages `key` using the first candidate not already reserved by this
    /// transaction. Candidate enumeration is supplied by the persistent table;
    /// overlay lookup and reservation membership remain O(1).
    ///
    /// A key the committed table already maps keeps its identity, and that
    /// identity is staged as an intent like a fresh one: the transaction
    /// re-collecting the site retires the committed generation of every
    /// identity whose descriptor it replaces, so publication must activate
    /// the reused identity again with the replacement.
    pub fn reserve(self: *IdentityOverlay, key: IdentityKey, active_id: ?u64, candidates: []const u64) error{ NoCapacity, NoAvailableIdentity }!u64 {
        if (self.phase == .committed) @panic("identity overlay cannot reserve after commit");
        if (self.provisional_by_key.get(key)) |id| return id;
        if (self.prepared_remaining == 0) return error.NoCapacity;
        if (active_id) |id| {
            self.provisional_by_key.putAssumeCapacity(key, id);
            self.reserved_ids.putAssumeCapacity(id, {});
            self.intents.appendAssumeCapacity(.{ .key = key, .id = id });
            self.prepared_remaining -= 1;
            return id;
        }
        for (candidates) |id| {
            if (self.reserved_ids.contains(id)) continue;
            self.provisional_by_key.putAssumeCapacity(key, id);
            self.reserved_ids.putAssumeCapacity(id, {});
            self.intents.appendAssumeCapacity(.{ .key = key, .id = id });
            self.prepared_remaining -= 1;
            return id;
        }
        return error.NoAvailableIdentity;
    }

    /// Drops provisional resources and restores the plan to an unpublished state.
    pub fn abort(self: *IdentityOverlay) void {
        if (self.phase == .committed) @panic("committed identity overlay cannot abort");
        self.provisional_by_key.clearRetainingCapacity();
        self.reserved_ids.clearRetainingCapacity();
        self.intents.clearRetainingCapacity();
        self.prepared_remaining = 0;
    }

    /// Publishes all prepared changes atomically and transfers their provisional ownership.
    pub fn commit(self: *IdentityOverlay, publisher: anytype) void {
        if (self.phase == .committed) @panic("identity overlay committed twice");
        for (self.intents.items) |intent| publisher.publishIdentity(intent.key, intent.id);
        self.phase = .committed;
    }

    /// Completes the ownership transition after a coordinator has published
    /// these intents directly as part of a larger allocation-free commit.
    pub fn finishExternalCommit(self: *IdentityOverlay) void {
        if (self.phase == .committed) @panic("identity overlay committed twice");
        self.phase = .committed;
    }
};

pub const ScopeKey = struct {
    parent_id: ids.ScopeId,
    ordinal: ids.SiteOrdinal,
    kind: Kind,

    pub const Kind = union(enum) {
        root,
        component,
        when_branch: scope_tree.Branch,
    };
};

pub const ScopeIntent = struct {
    key: ScopeKey,
    id: ids.ScopeId,
};

pub const ScopeOverlay = struct {
    provisional_by_key: std.AutoHashMapUnmanaged(ScopeKey, ids.ScopeId) = .{},
    reserved_ids: std.AutoHashMapUnmanaged(ids.ScopeId, void) = .{},
    intents: std.ArrayListUnmanaged(ScopeIntent) = .empty,
    prepared_remaining: usize = 0,
    phase: TransactionPhase = .preparing,

    /// Releases every resource owned by this value and leaves no retained host or Roc ownership behind.
    pub fn deinit(self: *ScopeOverlay, allocator: std.mem.Allocator) void {
        self.provisional_by_key.deinit(allocator);
        self.reserved_ids.deinit(allocator);
        self.intents.deinit(allocator);
        self.* = .{};
    }

    /// Preflights fallible growth so the later commit phase can remain allocation-free.
    pub fn prepare(self: *ScopeOverlay, allocator: std.mem.Allocator, additional: usize) std.mem.Allocator.Error!void {
        const next_remaining = std.math.add(usize, self.prepared_remaining, additional) catch return error.OutOfMemory;
        const outstanding = std.math.cast(u32, next_remaining) orelse return error.OutOfMemory;
        try self.provisional_by_key.ensureUnusedCapacity(allocator, outstanding);
        try self.reserved_ids.ensureUnusedCapacity(allocator, outstanding);
        try self.intents.ensureUnusedCapacity(allocator, next_remaining);
        self.prepared_remaining = next_remaining;
    }

    /// Resolves the requested identity from the transaction overlay before consulting committed state.
    pub fn lookup(self: *const ScopeOverlay, key: ScopeKey, active_id: ?ids.ScopeId) ?ids.ScopeId {
        return self.provisional_by_key.get(key) orelse active_id;
    }

    /// Claims transaction-local identity and capacity without publishing it to the live runtime.
    pub fn reserve(self: *ScopeOverlay, key: ScopeKey, active_id: ?ids.ScopeId, candidates: []const ids.ScopeId) error{ NoCapacity, NoAvailableScope }!ids.ScopeId {
        if (self.phase == .committed) @panic("scope overlay cannot reserve after commit");
        if (self.lookup(key, active_id)) |id| return id;
        if (self.prepared_remaining == 0) return error.NoCapacity;
        for (candidates) |id| {
            if (self.reserved_ids.contains(id)) continue;
            self.provisional_by_key.putAssumeCapacity(key, id);
            self.reserved_ids.putAssumeCapacity(id, {});
            self.intents.appendAssumeCapacity(.{ .key = key, .id = id });
            self.prepared_remaining -= 1;
            return id;
        }
        return error.NoAvailableScope;
    }

    /// Claims an externally owned provisional scope id for validation and
    /// collision avoidance without publishing a structural scope intent.
    pub fn reserveExternal(self: *ScopeOverlay, id: ids.ScopeId) error{ NoCapacity, DuplicateScope }!void {
        if (self.phase == .committed) @panic("scope overlay cannot reserve after commit");
        if (self.reserved_ids.contains(id)) return error.DuplicateScope;
        if (self.prepared_remaining == 0) return error.NoCapacity;
        self.reserved_ids.putAssumeCapacity(id, {});
        self.prepared_remaining -= 1;
    }

    /// Drops provisional resources and restores the plan to an unpublished state.
    pub fn abort(self: *ScopeOverlay) void {
        if (self.phase == .committed) @panic("committed scope overlay cannot abort");
        self.provisional_by_key.clearRetainingCapacity();
        self.reserved_ids.clearRetainingCapacity();
        self.intents.clearRetainingCapacity();
        self.prepared_remaining = 0;
    }

    /// Publishes all prepared changes atomically and transfers their provisional ownership.
    pub fn commit(self: *ScopeOverlay, publisher: anytype) void {
        if (self.phase == .committed) @panic("scope overlay committed twice");
        for (self.intents.items) |intent| publisher.publishScope(intent.key, intent.id);
        self.phase = .committed;
    }

    /// Completes the ownership transition after a coordinator has published
    /// these intents directly as part of a larger allocation-free commit.
    pub fn finishExternalCommit(self: *ScopeOverlay) void {
        if (self.phase == .committed) @panic("scope overlay committed twice");
        self.phase = .committed;
    }
};

/// Defines a preparation-owned value list whose entries are either committed together or dropped on abort.
pub fn OwnedValues(comptime Value: type) type {
    return struct {
        const Self = @This();
        values: std.ArrayListUnmanaged(Value) = .empty,
        phase: TransactionPhase = .preparing,

        /// Releases every resource owned by this value and leaves no retained host or Roc ownership behind.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator, dropper: anytype) void {
            if (self.phase == .preparing) self.abort(dropper);
            self.values.deinit(allocator);
            self.* = .{};
        }

        /// Preflights fallible growth so the later commit phase can remain allocation-free.
        pub fn prepare(self: *Self, allocator: std.mem.Allocator, additional: usize) std.mem.Allocator.Error!void {
            try self.values.ensureUnusedCapacity(allocator, additional);
        }

        /// Appends assume capacity using capacity that must already satisfy the caller's transaction contract.
        pub fn appendAssumeCapacity(self: *Self, value: Value) void {
            if (self.phase == .committed) @panic("owned values cannot append after commit");
            self.values.appendAssumeCapacity(value);
        }

        /// Drops provisional resources and restores the plan to an unpublished state.
        pub fn abort(self: *Self, dropper: anytype) void {
            if (self.phase == .committed) @panic("committed values cannot abort");
            var index = self.values.items.len;
            while (index != 0) {
                index -= 1;
                dropper.dropValue(self.values.items[index]);
            }
            self.values.clearRetainingCapacity();
        }

        /// Publishes all prepared changes atomically and transfers their provisional ownership.
        pub fn commit(self: *Self, publisher: anytype) void {
            if (self.phase == .committed) @panic("owned values committed twice");
            for (self.values.items) |value| publisher.publishValue(value);
            self.phase = .committed;
        }

        /// Reports whether publication has transferred all provisional ownership.
        pub fn isCommitted(self: *const Self) bool {
            return self.phase == .committed;
        }
    };
}

/// Transaction-local signal records keyed by stable callable token. Newly
/// constructed records remain owned here until allocation-free publication;
/// abort releases them in reverse construction order.
pub fn RecordOverlay(comptime Token: type, comptime Record: type) type {
    return struct {
        const Self = @This();
        provisional_by_token: std.AutoHashMapUnmanaged(Token, *Record) = .{},
        owned: std.ArrayListUnmanaged(*Record) = .empty,
        phase: TransactionPhase = .preparing,

        /// Preflights fallible growth so the later commit phase can remain allocation-free.
        pub fn prepare(self: *Self, allocator: std.mem.Allocator, additional: usize) std.mem.Allocator.Error!void {
            try self.provisional_by_token.ensureUnusedCapacity(allocator, @intCast(additional));
            try self.owned.ensureUnusedCapacity(allocator, additional);
        }

        /// Resolves the requested identity from the transaction overlay before consulting committed state.
        pub fn lookup(self: *const Self, token: Token, persistent: ?*Record) ?*Record {
            return self.provisional_by_token.get(token) orelse persistent;
        }

        /// Transfers ownership of assume capacity into the current preparation plan.
        pub fn ownAssumeCapacity(self: *Self, token: Token, record: *Record) void {
            if (self.phase == .committed) @panic("record overlay cannot own after commit");
            self.provisional_by_token.putAssumeCapacity(token, record);
            self.owned.appendAssumeCapacity(record);
        }

        /// Drops provisional resources and restores the plan to an unpublished state.
        pub fn abort(self: *Self, releaser: anytype) void {
            if (self.phase == .committed) @panic("committed record overlay cannot abort");
            var index = self.owned.items.len;
            while (index != 0) {
                index -= 1;
                releaser.releaseRecord(self.owned.items[index]);
            }
            self.provisional_by_token.clearRetainingCapacity();
            self.owned.clearRetainingCapacity();
        }

        /// Publishes all prepared changes atomically and transfers their provisional ownership.
        pub fn commit(self: *Self, publisher: anytype) void {
            if (self.phase == .committed) @panic("record overlay committed twice");
            for (self.owned.items) |record| publisher.publishRecord(record);
            self.phase = .committed;
        }

        /// Releases every resource owned by this value and leaves no retained host or Roc ownership behind.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator, releaser: anytype) void {
            if (self.phase == .preparing) self.abort(releaser);
            self.provisional_by_token.deinit(allocator);
            self.owned.deinit(allocator);
            self.* = .{};
        }
    };
}

/// Signal graph staging separates non-owning token publication from owning
/// descriptor roots. Child records are transitively owned by their parents;
/// releasing every token intent would therefore double-release graph edges.
pub fn SignalRecordPlan(comptime Token: type, comptime Composite: type, comptime Record: type) type {
    return struct {
        const Self = @This();
        const DescriptorRoot = union(enum) {
            owned: *Record,
            transferred: *Record,

            fn record(self: @This()) *Record {
                return switch (self) {
                    inline else => |value| value,
                };
            }
        };
        by_token: std.AutoHashMapUnmanaged(Token, *Record) = .{},
        by_composite: std.AutoHashMapUnmanaged(Composite, *Record) = .{},
        token_intents: std.ArrayListUnmanaged(struct { token: Token, record: *Record }) = .empty,
        composite_intents: std.ArrayListUnmanaged(struct { identity: Composite, record: *Record }) = .empty,
        descriptor_roots: std.ArrayListUnmanaged(DescriptorRoot) = .empty,
        phase: TransactionPhase = .preparing,

        /// Preflights fallible growth so the later commit phase can remain allocation-free.
        pub fn prepare(self: *Self, allocator: std.mem.Allocator, tokens: usize, roots: usize) std.mem.Allocator.Error!void {
            try self.by_token.ensureUnusedCapacity(allocator, @intCast(tokens));
            try self.by_composite.ensureUnusedCapacity(allocator, @intCast(tokens));
            try self.token_intents.ensureUnusedCapacity(allocator, tokens);
            try self.composite_intents.ensureUnusedCapacity(allocator, tokens);
            try self.descriptor_roots.ensureUnusedCapacity(allocator, roots);
        }

        /// Resolves the requested identity from the transaction overlay before consulting committed state.
        pub fn lookup(self: *const Self, token: Token, persistent: ?*Record) ?*Record {
            return self.by_token.get(token) orelse persistent;
        }

        /// Resolves one composite identity from the transaction overlay before committed state.
        pub fn lookupComposite(self: *const Self, identity: Composite, persistent: ?*Record) ?*Record {
            return self.by_composite.get(identity) orelse persistent;
        }

        /// Records a token-to-record association after preparation has guaranteed insertion capacity.
        pub fn rememberTokenAssumeCapacity(self: *Self, token: Token, record: *Record) void {
            if (self.phase == .committed) @panic("signal record plan cannot remember after commit");
            if (self.by_token.contains(token)) return;
            self.by_token.putAssumeCapacity(token, record);
            self.token_intents.appendAssumeCapacity(.{ .token = token, .record = record });
        }

        /// Records a composite identity association after preparation reserved insertion capacity.
        pub fn rememberCompositeAssumeCapacity(self: *Self, identity: Composite, record: *Record) void {
            if (self.phase == .committed) @panic("signal record plan cannot remember after commit");
            if (self.by_composite.contains(identity)) return;
            self.by_composite.putAssumeCapacity(identity, record);
            self.composite_intents.appendAssumeCapacity(.{ .identity = identity, .record = record });
        }

        /// Transfers ownership of descriptor root assume capacity into the current preparation plan.
        pub fn ownDescriptorRootAssumeCapacity(self: *Self, record: *Record) void {
            if (self.phase == .committed) @panic("signal record plan cannot own after commit");
            self.descriptor_roots.appendAssumeCapacity(.{ .owned = record });
        }

        /// Transfers the most recently staged descriptor root to its prepared
        /// descriptor while retaining the non-owning publication intent.
        pub fn transferDescriptorRoot(self: *Self, record: *Record) void {
            if (self.phase == .committed) @panic("signal record plan cannot transfer after commit");
            if (self.descriptor_roots.items.len == 0) @panic("signal record plan transferred a missing descriptor root");
            const root = &self.descriptor_roots.items[self.descriptor_roots.items.len - 1];
            switch (root.*) {
                .owned => |owned| {
                    if (owned != record) @panic("signal record plan transferred an unexpected descriptor root");
                    root.* = .{ .transferred = owned };
                },
                .transferred => @panic("signal record plan transferred an unexpected descriptor root"),
            }
        }

        /// Drops provisional resources and restores the plan to an unpublished state.
        pub fn abort(self: *Self, releaser: anytype) void {
            if (self.phase == .committed) @panic("committed signal record plan cannot abort");
            var index = self.descriptor_roots.items.len;
            while (index != 0) {
                index -= 1;
                const root = self.descriptor_roots.items[index];
                switch (root) {
                    .owned => |record| releaser.releaseRecord(record),
                    .transferred => {},
                }
            }
            self.by_token.clearRetainingCapacity();
            self.by_composite.clearRetainingCapacity();
            self.token_intents.clearRetainingCapacity();
            self.composite_intents.clearRetainingCapacity();
            self.descriptor_roots.clearRetainingCapacity();
        }

        /// Publishes all prepared changes atomically and transfers their provisional ownership.
        pub fn commit(self: *Self, publisher: anytype) void {
            if (self.phase == .committed) @panic("signal record plan committed twice");
            for (self.token_intents.items) |intent| publisher.publishToken(intent.token, intent.record);
            for (self.composite_intents.items) |intent| publisher.publishComposite(intent.identity, intent.record);
            for (self.descriptor_roots.items) |root| publisher.publishDescriptorRoot(root.record());
            self.phase = .committed;
        }

        /// Reports whether publication has transferred all provisional ownership.
        pub fn isCommitted(self: *const Self) bool {
            return self.phase == .committed;
        }

        /// Releases every resource owned by this value and leaves no retained host or Roc ownership behind.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator, releaser: anytype) void {
            if (self.phase == .preparing) self.abort(releaser);
            self.by_token.deinit(allocator);
            self.by_composite.deinit(allocator);
            self.token_intents.deinit(allocator);
            self.composite_intents.deinit(allocator);
            self.descriptor_roots.deinit(allocator);
            self.* = .{};
        }
    };
}

test "signal record plan releases descriptor roots but not token intents" {
    const TestRecord = struct { id: u8 };
    var child = TestRecord{ .id = 1 };
    var root = TestRecord{ .id = 2 };
    var releases: usize = 0;
    const Releaser = struct {
        count: *usize,
        root: *TestRecord,
        child: *TestRecord,
        /// Releases the test or plan's owned signal record exactly once.
        pub fn releaseRecord(self: @This(), record: *TestRecord) void {
            std.debug.assert(record == self.root);
            self.count.* += 1;
            // Models Record.release recursively releasing its child edge.
            _ = self.child;
            self.count.* += 1;
        }
    };
    var plan = SignalRecordPlan(u64, u64, TestRecord){};
    try plan.prepare(std.testing.allocator, 2, 1);
    plan.rememberTokenAssumeCapacity(10, &child);
    plan.rememberCompositeAssumeCapacity(20, &root);
    plan.ownDescriptorRootAssumeCapacity(&root);
    plan.abort(Releaser{ .count = &releases, .root = &root, .child = &child });
    try std.testing.expectEqual(@as(usize, 2), releases);
    plan.deinit(std.testing.allocator, Releaser{ .count = &releases, .root = &root, .child = &child });
}

test "signal record plan transfer prevents abort release and preserves publication" {
    const TestRecord = struct { id: u8 };
    const Releaser = struct {
        count: *usize,
        /// Releases the test or plan's owned signal record exactly once.
        pub fn releaseRecord(self: @This(), _: *TestRecord) void {
            self.count.* += 1;
        }
    };
    const Publisher = struct {
        published: *?*TestRecord,
        /// Publishes token during the allocation-free commit phase.
        pub fn publishToken(_: @This(), _: u64, _: *TestRecord) void {}
        /// Publishes composite identity during the allocation-free commit phase.
        pub fn publishComposite(_: @This(), _: u64, _: *TestRecord) void {}
        /// Publishes descriptor root during the allocation-free commit phase.
        pub fn publishDescriptorRoot(self: @This(), record: *TestRecord) void {
            self.published.* = record;
        }
    };

    var record = TestRecord{ .id = 1 };
    var releases: usize = 0;
    var aborted = SignalRecordPlan(u64, u64, TestRecord){};
    try aborted.prepare(std.testing.allocator, 0, 1);
    aborted.ownDescriptorRootAssumeCapacity(&record);
    aborted.transferDescriptorRoot(&record);
    aborted.abort(Releaser{ .count = &releases });
    try std.testing.expectEqual(@as(usize, 0), releases);
    aborted.deinit(std.testing.allocator, Releaser{ .count = &releases });

    var published: ?*TestRecord = null;
    var committed = SignalRecordPlan(u64, u64, TestRecord){};
    try committed.prepare(std.testing.allocator, 0, 1);
    committed.ownDescriptorRootAssumeCapacity(&record);
    committed.transferDescriptorRoot(&record);
    committed.commit(Publisher{ .published = &published });
    try std.testing.expect(published == &record);
    committed.deinit(std.testing.allocator, Releaser{ .count = &releases });
    try std.testing.expectEqual(@as(usize, 0), releases);
}

test "signal record plan preparation sweeps allocation failures and retries" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    const TestRecord = struct { id: u8 };
    const Releaser = struct {
        count: *usize,
        /// Releases the test or plan's owned signal record exactly once.
        pub fn releaseRecord(self: @This(), _: *TestRecord) void {
            self.count.* += 1;
        }
    };

    var counter = FaultAllocator.init(std.testing.allocator);
    var counted = SignalRecordPlan(u64, u64, TestRecord){};
    try counted.prepare(counter.allocator(), 2, 1);
    const attempts = counter.attempts;
    var ignored: usize = 0;
    counted.deinit(std.testing.allocator, Releaser{ .count = &ignored });

    for (1..attempts + 1) |failure_number| {
        var fault = FaultAllocator.init(std.testing.allocator);
        fault.configure(failure_number);
        var plan = SignalRecordPlan(u64, u64, TestRecord){};
        try std.testing.expectError(error.OutOfMemory, plan.prepare(fault.allocator(), 2, 1));
        try std.testing.expectEqual(@as(usize, 0), plan.token_intents.items.len);
        try std.testing.expectEqual(@as(usize, 0), plan.composite_intents.items.len);
        try std.testing.expectEqual(@as(usize, 0), plan.descriptor_roots.items.len);

        fault.configure(null);
        try plan.prepare(fault.allocator(), 2, 1);
        var record = TestRecord{ .id = 1 };
        plan.rememberTokenAssumeCapacity(10, &record);
        plan.rememberCompositeAssumeCapacity(20, &record);
        plan.ownDescriptorRootAssumeCapacity(&record);
        var releases: usize = 0;
        plan.deinit(std.testing.allocator, Releaser{ .count = &releases });
        try std.testing.expectEqual(@as(usize, 1), releases);
    }
}

test "record overlay aborts in reverse and commits without allocation" {
    const TestRecord = struct { id: u8 };
    var first = TestRecord{ .id = 1 };
    var second = TestRecord{ .id = 2 };
    var released: [2]u8 = undefined;
    var release_len: usize = 0;
    const Releaser = struct {
        values: *[2]u8,
        len: *usize,
        /// Releases the test or plan's owned signal record exactly once.
        pub fn releaseRecord(self: @This(), record: *TestRecord) void {
            self.values[self.len.*] = record.id;
            self.len.* += 1;
        }
    };
    var overlay = RecordOverlay(u64, TestRecord){};
    try overlay.prepare(std.testing.allocator, 2);
    overlay.ownAssumeCapacity(10, &first);
    overlay.ownAssumeCapacity(20, &second);
    try std.testing.expect(overlay.lookup(20, null) == &second);
    overlay.abort(Releaser{ .values = &released, .len = &release_len });
    try std.testing.expectEqualSlices(u8, &.{ 2, 1 }, released[0..release_len]);
    overlay.deinit(std.testing.allocator, Releaser{ .values = &released, .len = &release_len });
}

/// Defines an allocation-preflighted transaction journal whose commit path is allocation-free.
pub fn Plan(comptime Action: type) type {
    return struct {
        const Self = @This();

        actions: std.ArrayListUnmanaged(Action) = .empty,
        phase: TransactionPhase = .preparing,

        /// Releases every resource owned by this value and leaves no retained host or Roc ownership behind.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator, ctx: anytype) void {
            if (self.phase == .preparing) self.abort(ctx);
            self.actions.deinit(allocator);
            self.* = .{};
        }

        /// Ensures unused capacity capacity or state before publication can begin.
        pub fn ensureUnusedCapacity(self: *Self, allocator: std.mem.Allocator, count: usize) std.mem.Allocator.Error!void {
            try self.actions.ensureUnusedCapacity(allocator, count);
        }

        /// Appends assume capacity using capacity that must already satisfy the caller's transaction contract.
        pub fn appendAssumeCapacity(self: *Self, action: Action) void {
            if (self.phase == .committed) @panic("collection plan cannot append after commit");
            self.actions.appendAssumeCapacity(action);
        }

        /// Applies already-prepared actions in construction order. `apply`
        /// cannot fail or allocate; reaching it is the transaction's mutation
        /// boundary.
        pub fn commit(self: *Self, ctx: anytype) void {
            if (self.phase == .committed) @panic("collection plan committed twice");
            for (self.actions.items) |*action| action.apply(ctx);
            self.phase = .committed;
        }

        /// Drops provisional resources and restores the plan to an unpublished state.
        pub fn abort(self: *Self, ctx: anytype) void {
            if (self.phase == .committed) @panic("committed collection plan cannot abort");
            var index = self.actions.items.len;
            while (index != 0) {
                index -= 1;
                self.actions.items[index].abort(ctx);
            }
            self.actions.clearRetainingCapacity();
        }
    };
}

const TestContext = struct {
    applied: std.ArrayListUnmanaged(u8) = .empty,
    aborted: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *@This()) void {
        self.applied.deinit(std.testing.allocator);
        self.aborted.deinit(std.testing.allocator);
    }
};

const TestAction = struct {
    id: u8,

    fn apply(self: *@This(), ctx: *TestContext) void {
        ctx.applied.append(std.testing.allocator, self.id) catch unreachable;
    }

    fn abort(self: *@This(), ctx: *TestContext) void {
        ctx.aborted.append(std.testing.allocator, self.id) catch unreachable;
    }
};

test "collection plan aborts provisional ownership in reverse order" {
    var ctx: TestContext = .{};
    defer ctx.deinit();
    var plan: Plan(TestAction) = .{};
    defer plan.deinit(std.testing.allocator, &ctx);
    try plan.ensureUnusedCapacity(std.testing.allocator, 3);
    plan.appendAssumeCapacity(.{ .id = 1 });
    plan.appendAssumeCapacity(.{ .id = 2 });
    plan.appendAssumeCapacity(.{ .id = 3 });
    plan.abort(&ctx);
    try std.testing.expectEqualSlices(u8, &.{ 3, 2, 1 }, ctx.aborted.items);
    try std.testing.expectEqual(@as(usize, 0), ctx.applied.items.len);
}

test "collection plan commit applies in order and transfers ownership" {
    var ctx: TestContext = .{};
    defer ctx.deinit();
    var plan: Plan(TestAction) = .{};
    defer plan.deinit(std.testing.allocator, &ctx);
    try plan.ensureUnusedCapacity(std.testing.allocator, 2);
    plan.appendAssumeCapacity(.{ .id = 4 });
    plan.appendAssumeCapacity(.{ .id = 5 });
    plan.commit(&ctx);
    try std.testing.expectEqualSlices(u8, &.{ 4, 5 }, ctx.applied.items);
    try std.testing.expectEqual(@as(usize, 0), ctx.aborted.items.len);
}

test "identity overlay reserves distinct ids without persistent mutation" {
    var persistent: std.AutoHashMapUnmanaged(IdentityKey, u64) = .{};
    defer persistent.deinit(std.testing.allocator);
    try persistent.put(std.testing.allocator, 10, 7);

    var overlay: IdentityOverlay = .{};
    defer overlay.deinit(std.testing.allocator);
    try overlay.prepare(std.testing.allocator, 3);
    try std.testing.expectEqual(@as(u64, 7), try overlay.reserve(10, persistent.get(10), &.{ 7, 8 }));
    try std.testing.expectEqual(@as(u64, 8), try overlay.reserve(11, persistent.get(11), &.{ 8, 9 }));
    try std.testing.expectEqual(@as(u64, 9), try overlay.reserve(12, persistent.get(12), &.{ 8, 9 }));
    try std.testing.expectEqual(@as(usize, 1), persistent.count());
    try std.testing.expect(persistent.get(11) == null);
    try std.testing.expectEqual(@as(u64, 8), overlay.lookup(11, null).?);
    // The committed identity is staged again under its own key, so the
    // publication that follows the retirement of its old generation
    // reactivates it; reserving the key twice stages it once.
    try std.testing.expectEqual(@as(u64, 7), try overlay.reserve(10, persistent.get(10), &.{ 7, 8 }));
    try std.testing.expectEqual(@as(usize, 3), overlay.intents.items.len);
    try std.testing.expectEqual(IdentityIntent{ .key = 10, .id = 7 }, overlay.intents.items[0]);
    try std.testing.expectError(error.NoCapacity, overlay.reserve(13, null, &.{10}));
}

test "identity overlay abort permits clean retry" {
    var overlay: IdentityOverlay = .{};
    defer overlay.deinit(std.testing.allocator);
    try overlay.prepare(std.testing.allocator, 1);
    try std.testing.expectEqual(@as(u64, 3), try overlay.reserve(1, null, &.{3}));
    overlay.abort();
    try std.testing.expect(overlay.lookup(1, null) == null);

    try overlay.prepare(std.testing.allocator, 1);
    try std.testing.expectEqual(@as(u64, 3), try overlay.reserve(2, null, &.{3}));
    try std.testing.expectEqual(@as(usize, 1), overlay.intents.items.len);
}

test "identity overlay publishes only during allocation-free commit" {
    const Publisher = struct {
        persistent: *std.AutoHashMapUnmanaged(IdentityKey, u64),

        fn publishIdentity(self: @This(), key: IdentityKey, id: u64) void {
            self.persistent.putAssumeCapacity(key, id);
        }
    };

    var persistent: std.AutoHashMapUnmanaged(IdentityKey, u64) = .{};
    defer persistent.deinit(std.testing.allocator);
    try persistent.ensureUnusedCapacity(std.testing.allocator, 2);
    var overlay: IdentityOverlay = .{};
    defer overlay.deinit(std.testing.allocator);
    try overlay.prepare(std.testing.allocator, 2);
    _ = try overlay.reserve(20, null, &.{ 4, 5 });
    _ = try overlay.reserve(21, null, &.{ 4, 5 });
    try std.testing.expectEqual(@as(usize, 0), persistent.count());
    overlay.commit(Publisher{ .persistent = &persistent });
    try std.testing.expectEqual(@as(u64, 4), persistent.get(20).?);
    try std.testing.expectEqual(@as(u64, 5), persistent.get(21).?);
}

test "identity overlay repeated preflight reserves the full outstanding budget" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    const Publisher = struct {
        published: *usize,
        fn publishIdentity(self: @This(), _: IdentityKey, _: u64) void {
            self.published.* += 1;
        }
    };
    var fault = FaultAllocator.init(std.testing.allocator);
    var overlay: IdentityOverlay = .{};
    defer overlay.deinit(fault.allocator());
    try overlay.prepare(fault.allocator(), 2);
    try overlay.prepare(fault.allocator(), 3);

    fault.configure(1);
    for (0..5) |index| try std.testing.expectEqual(@as(u64, @intCast(index + 1)), try overlay.reserve(index + 10, null, &.{@intCast(index + 1)}));
    var published: usize = 0;
    overlay.commit(Publisher{ .published = &published });
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqual(@as(usize, 5), published);
}

test "identity overlay repeated preflight sweeps allocation failure atomically" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var counter = FaultAllocator.init(std.testing.allocator);
    var counted: IdentityOverlay = .{};
    try counted.prepare(counter.allocator(), 2);
    try counted.prepare(counter.allocator(), 3);
    const attempts = counter.attempts;
    counted.deinit(counter.allocator());

    for (1..attempts + 1) |failure_number| {
        var fault = FaultAllocator.init(std.testing.allocator);
        fault.configure(failure_number);
        var overlay: IdentityOverlay = .{};
        defer overlay.deinit(fault.allocator());
        var failed = false;
        overlay.prepare(fault.allocator(), 2) catch |err| switch (err) {
            error.OutOfMemory => failed = true,
        };
        if (!failed) overlay.prepare(fault.allocator(), 3) catch |err| switch (err) {
            error.OutOfMemory => failed = true,
        };
        try std.testing.expect(failed);
        try std.testing.expect(overlay.prepared_remaining == 0 or overlay.prepared_remaining == 2);
    }
}

test "scope overlay uniquely reserves inactive slots for provisional hierarchy" {
    var overlay: ScopeOverlay = .{};
    defer overlay.deinit(std.testing.allocator);
    try overlay.prepare(std.testing.allocator, 3);
    const root_key: ScopeKey = .{ .parent_id = ids.root_scope, .ordinal = ids.SiteOrdinal.fromRaw(0), .kind = .root };
    const candidates = [_]ids.ScopeId{ ids.ScopeId.fromRaw(4), ids.ScopeId.fromRaw(5), ids.ScopeId.fromRaw(6) };
    const root_id = try overlay.reserve(root_key, null, &candidates);
    const child_a: ScopeKey = .{ .parent_id = root_id, .ordinal = ids.SiteOrdinal.fromRaw(0), .kind = .component };
    const child_b: ScopeKey = .{ .parent_id = root_id, .ordinal = ids.SiteOrdinal.fromRaw(1), .kind = .component };
    const child_a_id = try overlay.reserve(child_a, null, &candidates);
    const child_b_id = try overlay.reserve(child_b, null, &candidates);
    try std.testing.expectEqual(@as(u64, 4), root_id.raw());
    try std.testing.expectEqual(@as(u64, 5), child_a_id.raw());
    try std.testing.expectEqual(@as(u64, 6), child_b_id.raw());
    try std.testing.expectEqual(child_a_id, overlay.lookup(child_a, null).?);
}

test "scope overlay abort leaves persistent scopes unchanged and permits retry" {
    var persistent: std.AutoHashMapUnmanaged(ScopeKey, ids.ScopeId) = .{};
    defer persistent.deinit(std.testing.allocator);
    const key: ScopeKey = .{ .parent_id = ids.ScopeId.fromRaw(1), .ordinal = ids.SiteOrdinal.fromRaw(2), .kind = .{ .when_branch = .true_branch } };
    var overlay: ScopeOverlay = .{};
    defer overlay.deinit(std.testing.allocator);
    try overlay.prepare(std.testing.allocator, 1);
    _ = try overlay.reserve(key, persistent.get(key), &.{ids.ScopeId.fromRaw(9)});
    try std.testing.expectEqual(@as(usize, 0), persistent.count());
    overlay.abort();
    try overlay.prepare(std.testing.allocator, 1);
    try std.testing.expectEqual(ids.ScopeId.fromRaw(9), try overlay.reserve(key, persistent.get(key), &.{ids.ScopeId.fromRaw(9)}));
}

test "scope overlay reserves external ids without publishing intents" {
    var overlay: ScopeOverlay = .{};
    defer overlay.deinit(std.testing.allocator);
    try overlay.prepare(std.testing.allocator, 2);
    try overlay.reserveExternal(ids.ScopeId.fromRaw(7));
    const key: ScopeKey = .{ .parent_id = ids.ScopeId.fromRaw(7), .ordinal = ids.SiteOrdinal.fromRaw(1), .kind = .component };
    const child = try overlay.reserve(key, null, &.{ ids.ScopeId.fromRaw(7), ids.ScopeId.fromRaw(8) });
    try std.testing.expectEqual(ids.ScopeId.fromRaw(8), child);
    try std.testing.expect(overlay.reserved_ids.contains(ids.ScopeId.fromRaw(7)));
    try std.testing.expectEqual(@as(usize, 1), overlay.intents.items.len);
    try std.testing.expectError(error.DuplicateScope, overlay.reserveExternal(ids.ScopeId.fromRaw(7)));
}

test "scope overlay repeated preflight covers external and published reservations" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    const Publisher = struct {
        published: *usize,
        fn publishScope(self: @This(), _: ScopeKey, _: ids.ScopeId) void {
            self.published.* += 1;
        }
    };
    var fault = FaultAllocator.init(std.testing.allocator);
    var overlay: ScopeOverlay = .{};
    defer overlay.deinit(fault.allocator());
    try overlay.prepare(fault.allocator(), 2);
    try overlay.prepare(fault.allocator(), 3);

    fault.configure(1);
    try overlay.reserveExternal(ids.ScopeId.fromRaw(4));
    for (0..4) |index| {
        const key: ScopeKey = .{ .parent_id = ids.ScopeId.fromRaw(4), .ordinal = ids.SiteOrdinal.fromIndex(index), .kind = .component };
        const candidate = ids.ScopeId.fromIndex(index + 5);
        try std.testing.expectEqual(candidate, try overlay.reserve(key, null, &.{candidate}));
    }
    var published: usize = 0;
    overlay.commit(Publisher{ .published = &published });
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqual(@as(usize, 4), published);
}

test "scope overlay repeated preflight sweeps allocation failure atomically" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var counter = FaultAllocator.init(std.testing.allocator);
    var counted: ScopeOverlay = .{};
    try counted.prepare(counter.allocator(), 2);
    try counted.prepare(counter.allocator(), 3);
    const attempts = counter.attempts;
    counted.deinit(counter.allocator());

    for (1..attempts + 1) |failure_number| {
        var fault = FaultAllocator.init(std.testing.allocator);
        fault.configure(failure_number);
        var overlay: ScopeOverlay = .{};
        defer overlay.deinit(fault.allocator());
        var failed = false;
        overlay.prepare(fault.allocator(), 2) catch |err| switch (err) {
            error.OutOfMemory => failed = true,
        };
        if (!failed) overlay.prepare(fault.allocator(), 3) catch |err| switch (err) {
            error.OutOfMemory => failed = true,
        };
        try std.testing.expect(failed);
        try std.testing.expect(overlay.prepared_remaining == 0 or overlay.prepared_remaining == 2);
    }
}

test "provisional value initializer runs once and abort releases ownership" {
    const Tracker = struct {
        initializers: usize = 0,
        drops: usize = 0,
        published: usize = 0,

        fn initialize(self: *@This()) u64 {
            self.initializers += 1;
            return 42;
        }
        fn dropValue(self: *@This(), _: u64) void {
            self.drops += 1;
        }
        fn publishValue(self: *@This(), _: u64) void {
            self.published += 1;
        }
    };

    var tracker: Tracker = .{};
    var values: OwnedValues(u64) = .{};
    defer values.deinit(std.testing.allocator, &tracker);
    try values.prepare(std.testing.allocator, 1);
    values.appendAssumeCapacity(tracker.initialize());
    try std.testing.expectEqual(@as(usize, 1), tracker.initializers);
    try std.testing.expectEqual(@as(usize, 0), tracker.published);
    values.abort(&tracker);
    try std.testing.expectEqual(@as(usize, 1), tracker.drops);
}

test "provisional value commit transfers without rerunning initializer or drop" {
    const Tracker = struct {
        initializers: usize = 0,
        drops: usize = 0,
        published: usize = 0,

        fn initialize(self: *@This()) u64 {
            self.initializers += 1;
            return 7;
        }
        fn dropValue(self: *@This(), _: u64) void {
            self.drops += 1;
        }
        fn publishValue(self: *@This(), _: u64) void {
            self.published += 1;
        }
    };

    var tracker: Tracker = .{};
    var values: OwnedValues(u64) = .{};
    defer values.deinit(std.testing.allocator, &tracker);
    try values.prepare(std.testing.allocator, 1);
    values.appendAssumeCapacity(tracker.initialize());
    values.commit(&tracker);
    try std.testing.expectEqual(@as(usize, 1), tracker.initializers);
    try std.testing.expectEqual(@as(usize, 1), tracker.published);
    try std.testing.expectEqual(@as(usize, 0), tracker.drops);
}
