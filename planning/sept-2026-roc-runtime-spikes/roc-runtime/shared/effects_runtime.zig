//! Runtime tables for scope-owned intervals and cleanup observations.

const std = @import("std");
const shared_buffer = @import("shared_buffer.zig");
const abi = @import("roc_platform_abi.zig");
const retained_values = @import("retained_values.zig");
const signal_records = @import("signal_records.zig");
const ids = @import("ids.zig");

pub const HostSignalToken = retained_values.HostSignalToken;
pub const HostSignalRecord = signal_records.Record;

pub const ActiveInterval = struct {
    token: ids.IntervalToken,
    source_token: HostSignalToken,
    period_ms: u64,
    reconciliation: enum { pending, confirmed } = .confirmed,
};

/// Owns the dense interval lane and both identity indexes. Registration growth
/// is reserved before publication; retirement updates a displaced slot in O(1).
pub const IntervalRegistry = struct {
    entries: shared_buffer.List(ActiveInterval) = .empty,
    by_runtime: std.AutoHashMapUnmanaged(ids.IntervalToken, usize) = .empty,
    by_source: std.AutoHashMapUnmanaged(HostSignalToken, usize) = .empty,
    pub const empty: IntervalRegistry = .{};

    /// Reserves lane and index growth without publishing a registration.
    pub fn ensureUnusedCapacity(self: *IntervalRegistry, allocator: std.mem.Allocator, additional: usize) error{OutOfMemory}!void {
        const count = std.math.cast(u32, additional) orelse return error.OutOfMemory;
        try self.entries.ensureUnusedCapacity(allocator, additional);
        try self.by_runtime.ensureUnusedCapacity(allocator, count);
        try self.by_source.ensureUnusedCapacity(allocator, count);
    }

    /// Inserts an owned registration after all three stores were preflighted.
    pub fn appendAssumeCapacity(self: *IntervalRegistry, value: ActiveInterval) void {
        if (self.by_runtime.contains(value.token) or self.by_source.contains(value.source_token)) @panic("duplicate interval identity");
        const index = self.entries.items.len;
        self.entries.appendAssumeCapacity(value);
        self.by_runtime.putAssumeCapacity(value.token, index);
        self.by_source.putAssumeCapacity(value.source_token, index);
    }

    /// Reserves and transfers one registration; refusal leaves ownership with
    /// the caller and does not expose a partially indexed interval.
    pub fn append(self: *IntervalRegistry, allocator: std.mem.Allocator, value: ActiveInterval) error{OutOfMemory}!void {
        try self.ensureUnusedCapacity(allocator, 1);
        self.appendAssumeCapacity(value);
    }

    /// Clears indexes after the caller has canceled and released every token.
    pub fn clearRetainingCapacity(self: *IntervalRegistry) void {
        self.entries.clearRetainingCapacity();
        self.by_runtime.clearRetainingCapacity();
        self.by_source.clearRetainingCapacity();
    }

    /// Frees empty registry storage after interval ownership has been released.
    pub fn deinit(self: *IntervalRegistry, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
        self.by_runtime.deinit(allocator);
        self.by_source.deinit(allocator);
    }
};

pub const CleanupEvents = shared_buffer.List([]const u8);

/// Appends cleanup event using capacity that must already satisfy the caller's transaction contract.
pub fn appendCleanupEvent(allocator: std.mem.Allocator, events: *CleanupEvents, name: []const u8) void {
    const copy = allocator.dupe(u8, name) catch @panic("out of memory");
    events.append(allocator, copy) catch {
        allocator.free(copy);
        @panic("out of memory");
    };
}

/// Counts cleanup callbacks for the selected name in native lifecycle observations.
pub fn cleanupEventCount(events: []const []const u8, name: []const u8) u64 {
    var count: u64 = 0;
    for (events) |event_name| {
        if (std.mem.eql(u8, event_name, name)) count += 1;
    }
    return count;
}

/// Releases cleanup events and all host registrations or retained values it owns.
pub fn deinitCleanupEvents(allocator: std.mem.Allocator, events: *CleanupEvents) void {
    for (events.items) |name| {
        allocator.free(name);
    }
    events.deinit(allocator);
    events.* = .empty;
}

/// Counts matching interval declarations for native semantic-spec queries.
/// Production timer delivery uses the runtime identity index.
pub fn activeIntervalRecordCountByPeriod(active_signal_graph: anytype, period_ms: u64) u64 {
    var count: u64 = 0;
    for (active_signal_graph) |node| {
        if (node.record.intervalSource()) |payload| {
            if (payload.period_ms == period_ms) count += 1;
        }
    }
    return count;
}

/// Searches a supplied graph snapshot for focused lifecycle tests.
/// Live engine delivery uses the published descriptor token index.
pub fn activeIntervalRecordByToken(active_signal_graph: anytype, source_token: HostSignalToken) ?*HostSignalRecord {
    var found: ?*HostSignalRecord = null;
    for (active_signal_graph) |node| {
        if (node.record.intervalSource() == null) continue;
        if (node.record.token().? != source_token) continue;
        if (found != null) @panic("interval token matched more than one active interval source");
        found = node.record;
    }
    return found;
}

/// Resolves an unambiguous period for native semantic-spec tick commands.
/// Runtime callbacks use token identity and never scan this graph.
pub fn activeIntervalRecordByPeriod(active_signal_graph: anytype, period_ms: u64) ?*HostSignalRecord {
    var found: ?*HostSignalRecord = null;
    for (active_signal_graph) |node| {
        const payload = node.record.intervalSource() orelse continue;
        if (payload.period_ms != period_ms) continue;
        if (found != null) @panic("tick_interval matched more than one active interval source");
        found = node.record;
    }
    return found;
}

/// Resolves a timer callback by its runtime identity without visiting other intervals.
pub fn activeIntervalSourceTokenByRuntimeToken(intervals: *const IntervalRegistry, token: ids.IntervalToken) ?HostSignalToken {
    const index = intervals.by_runtime.get(token) orelse return null;
    return intervals.entries.items[index].source_token;
}

/// Finds a live registration by the capability-owned source identity.
pub fn activeIntervalBySourceToken(intervals: *IntervalRegistry, source_token: HostSignalToken) ?*ActiveInterval {
    const index = intervals.by_source.get(source_token) orelse return null;
    return &intervals.entries.items[index];
}

/// Locates the exact slot that scope retirement must remove.
pub fn activeIntervalIndexBySourceToken(intervals: *const IntervalRegistry, source_token: HostSignalToken) ?usize {
    return intervals.by_source.get(source_token);
}

/// Marks existing intervals unseen before reconciling declarations from the active graph.
pub fn markActiveIntervalsInactive(intervals: []ActiveInterval) void {
    for (intervals) |*interval| {
        interval.reconciliation = .pending;
    }
}

/// Removes one indexed registration and returns its ownership to the caller.
/// The caller must cancel its host timer and release the source token.
pub fn removeActiveIntervalAt(intervals: *IntervalRegistry, index: usize) ActiveInterval {
    if (index >= intervals.entries.items.len) @panic("active interval index is out of bounds");
    const interval = intervals.entries.items[index];
    const last_index = intervals.entries.items.len - 1;
    if (!intervals.by_runtime.remove(interval.token) or !intervals.by_source.remove(interval.source_token)) @panic("interval identity index was missing during retirement");
    if (index != last_index) {
        const moved = intervals.entries.items[last_index];
        intervals.entries.items[index] = moved;
        intervals.by_runtime.getPtr(moved.token).?.* = index;
        intervals.by_source.getPtr(moved.source_token).?.* = index;
    }
    intervals.entries.items.len = last_index;
    return interval;
}

/// Clears active intervals while retaining bounded storage where the type promises reuse.
pub fn clearActiveIntervals(comptime Ctx: type, ctx: Ctx.Handle, intervals: *IntervalRegistry, roc_host: ?*abi.RocHost) void {
    const host = roc_host orelse {
        if (intervals.entries.items.len != 0) @panic("active intervals cannot release tokens without a Roc host");
        intervals.entries.items.len = 0;
        return;
    };
    for (intervals.entries.items) |interval| {
        Ctx.sink(ctx).cancelInterval(interval.token);
        retained_values.releaseHostSignalToken(interval.source_token, host);
    }
    intervals.clearRetainingCapacity();
}

/// Ensures active interval capacity or state before publication can begin.
pub fn ensureActiveInterval(comptime Ctx: type, ctx: Ctx.Handle, allocator: std.mem.Allocator, intervals: *IntervalRegistry, next_interval_token: *u64, roc_host: *abi.RocHost, source_token: HostSignalToken, period_ms: u64) void {
    if (activeIntervalBySourceToken(intervals, source_token)) |interval| {
        if (interval.period_ms != period_ms) @panic("interval source token changed period");
        interval.reconciliation = .confirmed;
        return;
    }

    if (next_interval_token.* == std.math.maxInt(u64)) @panic("host interval token overflowed");
    const token = next_interval_token.*;
    next_interval_token.* += 1;
    intervals.append(allocator, .{
        .token = ids.IntervalToken.fromRaw(token),
        .source_token = retained_values.retainHostSignalToken(source_token),
        .period_ms = period_ms,
        .reconciliation = .confirmed,
    }) catch {
        retained_values.releaseHostSignalToken(source_token, roc_host);
        @panic("out of memory");
    };
    Ctx.sink(ctx).startInterval(ids.IntervalToken.fromRaw(token), period_ms);
}

/// Reserves registry room for `additional` interval registrations before a
/// transaction publishes, so `ensureActiveIntervalAssumeCapacity` never grows
/// the registry on the commit path.
pub fn reserveActiveIntervals(allocator: std.mem.Allocator, intervals: *IntervalRegistry, additional: usize) error{OutOfMemory}!void {
    intervals.ensureUnusedCapacity(allocator, additional) catch return error.OutOfMemory;
}

/// Registers an interval source during publication using capacity that
/// `reserveActiveIntervals` already secured. A source token that is already
/// registered is confirmed rather than duplicated, exactly as
/// `ensureActiveInterval` does on the preparation path.
pub fn ensureActiveIntervalAssumeCapacity(comptime Ctx: type, ctx: Ctx.Handle, intervals: *IntervalRegistry, next_interval_token: *u64, source_token: HostSignalToken, period_ms: u64) void {
    if (activeIntervalBySourceToken(intervals, source_token)) |interval| {
        if (interval.period_ms != period_ms) @panic("interval source token changed period");
        interval.reconciliation = .confirmed;
        return;
    }

    if (next_interval_token.* == std.math.maxInt(u64)) @panic("host interval token overflowed");
    if (intervals.entries.items.len == intervals.entries.capacity) @panic("interval registration exceeded its reserved capacity");
    const token = next_interval_token.*;
    next_interval_token.* += 1;
    intervals.appendAssumeCapacity(.{
        .token = ids.IntervalToken.fromRaw(token),
        .source_token = retained_values.retainHostSignalToken(source_token),
        .period_ms = period_ms,
        .reconciliation = .confirmed,
    });
    Ctx.sink(ctx).startInterval(ids.IntervalToken.fromRaw(token), period_ms);
}

/// Removes active interval by source token and releases the ownership attached to that live entry.
pub fn removeActiveIntervalBySourceToken(comptime Ctx: type, ctx: Ctx.Handle, intervals: *IntervalRegistry, roc_host: *abi.RocHost, source_token: HostSignalToken) void {
    const index = activeIntervalIndexBySourceToken(intervals, source_token) orelse @panic("active interval removal missed its source token");
    const interval = removeActiveIntervalAt(intervals, index);
    Ctx.sink(ctx).cancelInterval(interval.token);
    retained_values.releaseHostSignalToken(interval.source_token, roc_host);
}

/// Cancels intervals not rediscovered and commits the current bounded registration set.
pub fn finishActiveIntervalSync(comptime Ctx: type, ctx: Ctx.Handle, intervals: *IntervalRegistry, roc_host: ?*abi.RocHost) void {
    const host = roc_host orelse {
        for (intervals.entries.items) |interval| {
            if (interval.reconciliation == .pending) @panic("unconfirmed interval cannot release token without a Roc host");
        }
        return;
    };

    var index = intervals.entries.items.len;
    while (index > 0) {
        index -= 1;
        if (intervals.entries.items[index].reconciliation != .pending) continue;
        const interval = removeActiveIntervalAt(intervals, index);
        Ctx.sink(ctx).cancelInterval(interval.token);
        retained_values.releaseHostSignalToken(interval.source_token, host);
    }
}

/// Reconciles interval registrations from active graph declarations after propagation.
pub fn syncActiveIntervalsFromGraph(
    comptime Ctx: type,
    ctx: Ctx.Handle,
    allocator: std.mem.Allocator,
    intervals: *IntervalRegistry,
    next_interval_token: *u64,
    roc_host: ?*abi.RocHost,
    active_signal_graph: anytype,
    metrics: anytype,
) void {
    markActiveIntervalsInactive(intervals.entries.items);
    metrics.bump(.active_intervals_synced, @intCast(active_signal_graph.len));

    for (active_signal_graph) |node| {
        const payload = node.record.intervalSource() orelse continue;
        const host = roc_host orelse @panic("active interval cannot retain token without a Roc host");
        ensureActiveInterval(Ctx, ctx, allocator, intervals, next_interval_token, host, node.record.token().?, payload.period_ms);
    }

    finishActiveIntervalSync(Ctx, ctx, intervals, roc_host);
}

const TestActiveNode = struct {
    record: *HostSignalRecord,
};

const TestMetrics = struct {
    active_intervals_synced: u64 = 0,

    /// Increments  for exact structural-work accounting.
    pub fn bump(self: *@This(), comptime field: enum { active_intervals_synced }, n: u64) void {
        @field(self, @tagName(field)) += n;
    }
};

const TestIntervalHost = struct {
    start_interval_count: u64 = 0,
    cancel_interval_count: u64 = 0,
};

const TestIntervalSink = struct {
    host: *TestIntervalHost,

    /// Starts the bounded host registration for an engine-owned interval source.
    pub fn startInterval(self: @This(), _: ids.IntervalToken, _: u64) void {
        self.host.start_interval_count += 1;
    }

    /// Cancels the host registration for an interval whose owning scope is no longer active.
    pub fn cancelInterval(self: @This(), _: ids.IntervalToken) void {
        self.host.cancel_interval_count += 1;
    }
};

const TestIntervalCtx = struct {
    pub const Handle = *TestIntervalHost;
    pub const Sink = TestIntervalSink;

    /// Returns the thin render-command sink used by the shared engine.
    pub fn sink(ctx: Handle) Sink {
        return .{ .host = ctx };
    }
};

fn testIntervalRecord(token: HostSignalToken, period_ms: u64) HostSignalRecord {
    return .{
        .ref_count = 1,
        .payload = .{ .interval_source = .{
            .period_ms = period_ms,
            .initial = .fromAbi(token),
            .tick = undefined,
            .cap = undefined,
        } },
    };
}

var test_signal_token_drop_count: u64 = 0;

fn testSignalTokenCallable(_: *abi.RocHost, _: ?[*]u8, _: ?[*]const u8, _: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {}

fn testSignalTokenOnDrop(_: ?[*]u8, _: *abi.RocHost) callconv(.c) void {
    test_signal_token_drop_count += 1;
}

fn testSignalToken(roc_host: *abi.RocHost, _: u64) HostSignalToken {
    return abi.rocErasedCallableAllocate(roc_host, &testSignalTokenCallable, &testSignalTokenOnDrop, 0) orelse unreachable;
}

test "active intervals retain callable tokens for their full lifecycle" {
    test_signal_token_drop_count = 0;
    var env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&env);
    var host = TestIntervalHost{};

    var intervals: IntervalRegistry = .empty;
    defer intervals.deinit(std.testing.allocator);
    var next_interval_token: u64 = 1;
    const interval_token = testSignalToken(&roc_host, 2);
    ensureActiveInterval(TestIntervalCtx, &host, std.testing.allocator, &intervals, &next_interval_token, &roc_host, interval_token, 250);
    retained_values.releaseHostSignalToken(interval_token, &roc_host);
    try std.testing.expectEqual(@as(u64, 0), test_signal_token_drop_count);
    clearActiveIntervals(TestIntervalCtx, &host, &intervals, &roc_host);
    try std.testing.expectEqual(@as(u64, 1), test_signal_token_drop_count);
}

test "effects runtime finds active effect source records" {
    var first_interval_token_storage = [_]u8{0};
    var second_interval_token_storage = [_]u8{0};
    const first_interval_token = first_interval_token_storage[0..].ptr;
    const second_interval_token = second_interval_token_storage[0..].ptr;
    var first_interval_record = testIntervalRecord(first_interval_token, 250);
    var second_interval_record = testIntervalRecord(second_interval_token, 500);
    var ref_record = HostSignalRecord{
        .ref_count = 1,
        .payload = .{ .ref = 42 },
    };
    const active_nodes = [_]TestActiveNode{
        .{ .record = &ref_record },
        .{ .record = &first_interval_record },
        .{ .record = &second_interval_record },
    };

    try std.testing.expectEqual(@as(u64, 1), activeIntervalRecordCountByPeriod(active_nodes[0..], 250));
    try std.testing.expectEqual(@as(?*HostSignalRecord, &first_interval_record), activeIntervalRecordByToken(active_nodes[0..], first_interval_token));
    try std.testing.expectEqual(@as(?*HostSignalRecord, &second_interval_record), activeIntervalRecordByPeriod(active_nodes[0..], 500));
}

test "effects runtime owns cleanup event storage" {
    var events: CleanupEvents = .empty;
    defer deinitCleanupEvents(std.testing.allocator, &events);

    appendCleanupEvent(std.testing.allocator, &events, "close");
    appendCleanupEvent(std.testing.allocator, &events, "close");
    appendCleanupEvent(std.testing.allocator, &events, "flush");

    try std.testing.expectEqual(@as(u64, 2), cleanupEventCount(events.items, "close"));
    try std.testing.expectEqual(@as(u64, 1), cleanupEventCount(events.items, "flush"));
    try std.testing.expectEqual(@as(u64, 0), cleanupEventCount(events.items, "missing"));
}

test "effects runtime updates active interval table" {
    var first_token_storage = [_]u8{0};
    var second_token_storage = [_]u8{0};
    const first_token = first_token_storage[0..].ptr;
    const second_token = second_token_storage[0..].ptr;
    var intervals: IntervalRegistry = .empty;
    defer intervals.deinit(std.testing.allocator);

    intervals.append(std.testing.allocator, .{
        .token = ids.IntervalToken.fromRaw(10),
        .source_token = first_token,
        .period_ms = 100,
        .reconciliation = .confirmed,
    }) catch @panic("out of memory");
    intervals.append(std.testing.allocator, .{
        .token = ids.IntervalToken.fromRaw(11),
        .source_token = second_token,
        .period_ms = 200,
        .reconciliation = .confirmed,
    }) catch @panic("out of memory");

    try std.testing.expectEqual(@as(?HostSignalToken, first_token), activeIntervalSourceTokenByRuntimeToken(&intervals, ids.IntervalToken.fromRaw(10)));
    markActiveIntervalsInactive(intervals.entries.items);
    try std.testing.expectEqual(.pending, intervals.entries.items[0].reconciliation);
    try std.testing.expectEqual(@as(?*ActiveInterval, &intervals.entries.items[1]), activeIntervalBySourceToken(&intervals, second_token));
    const removed = removeActiveIntervalAt(&intervals, 0);
    try std.testing.expectEqual(@as(u64, 10), removed.token.raw());
    try std.testing.expectEqual(@as(usize, 1), intervals.entries.items.len);
    try std.testing.expectEqual(@as(u64, 11), intervals.entries.items[0].token.raw());
}

test "effects runtime manages interval lifecycle transitions" {
    var env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&env);
    const first_token = testSignalToken(&roc_host, 100);
    defer retained_values.releaseHostSignalToken(first_token, &roc_host);
    const second_token = testSignalToken(&roc_host, 200);
    defer retained_values.releaseHostSignalToken(second_token, &roc_host);

    var host = TestIntervalHost{};
    var intervals: IntervalRegistry = .empty;
    defer intervals.deinit(std.testing.allocator);
    var next_interval_token: u64 = 10;

    ensureActiveInterval(TestIntervalCtx, &host, std.testing.allocator, &intervals, &next_interval_token, &roc_host, first_token, 250);
    ensureActiveInterval(TestIntervalCtx, &host, std.testing.allocator, &intervals, &next_interval_token, &roc_host, second_token, 500);
    try std.testing.expectEqual(@as(usize, 2), intervals.entries.items.len);
    try std.testing.expectEqual(@as(u64, 12), next_interval_token);
    try std.testing.expectEqual(@as(u64, 2), host.start_interval_count);
    try std.testing.expectEqual(@as(?usize, 1), activeIntervalIndexBySourceToken(&intervals, second_token));

    clearActiveIntervals(TestIntervalCtx, &host, &intervals, &roc_host);
    try std.testing.expectEqual(@as(usize, 0), intervals.entries.items.len);
    try std.testing.expectEqual(@as(u64, 2), host.cancel_interval_count);

    ensureActiveInterval(TestIntervalCtx, &host, std.testing.allocator, &intervals, &next_interval_token, &roc_host, first_token, 250);
    ensureActiveInterval(TestIntervalCtx, &host, std.testing.allocator, &intervals, &next_interval_token, &roc_host, second_token, 500);
    try std.testing.expectEqual(@as(u64, 4), host.start_interval_count);

    removeActiveIntervalBySourceToken(TestIntervalCtx, &host, &intervals, &roc_host, second_token);
    try std.testing.expectEqual(@as(usize, 1), intervals.entries.items.len);
    try std.testing.expectEqual(@as(u64, 3), host.cancel_interval_count);

    markActiveIntervalsInactive(intervals.entries.items);
    finishActiveIntervalSync(TestIntervalCtx, &host, &intervals, &roc_host);
    try std.testing.expectEqual(@as(usize, 0), intervals.entries.items.len);
    try std.testing.expectEqual(@as(u64, 4), host.cancel_interval_count);

    const no_host_token = testSignalToken(&roc_host, 300);
    intervals.append(std.testing.allocator, .{
        .token = ids.IntervalToken.fromRaw(99),
        .source_token = no_host_token,
        .period_ms = 1000,
        .reconciliation = .confirmed,
    }) catch @panic("out of memory");
    finishActiveIntervalSync(TestIntervalCtx, &host, &intervals, null);
    try std.testing.expectEqual(@as(usize, 1), intervals.entries.items.len);
    var removed = removeActiveIntervalAt(&intervals, 0);
    retained_values.releaseHostSignalToken(removed.source_token, &roc_host);
    removed = undefined;
}

test "effects runtime syncs existing active intervals from graph" {
    var source_token_storage = [_]u8{0};
    const source_token = source_token_storage[0..].ptr;
    var interval_record = testIntervalRecord(source_token, 250);
    const active_nodes = [_]TestActiveNode{
        .{ .record = &interval_record },
    };

    var intervals: IntervalRegistry = .empty;
    defer intervals.deinit(std.testing.allocator);
    intervals.append(std.testing.allocator, .{
        .token = ids.IntervalToken.fromRaw(10),
        .source_token = source_token,
        .period_ms = 250,
        .reconciliation = .confirmed,
    }) catch @panic("out of memory");

    var host = TestIntervalHost{};
    var metrics = TestMetrics{};
    var next_interval_token: u64 = 11;
    var roc_host: abi.RocHost = undefined;

    syncActiveIntervalsFromGraph(TestIntervalCtx, &host, std.testing.allocator, &intervals, &next_interval_token, &roc_host, active_nodes[0..], &metrics);

    try std.testing.expectEqual(@as(usize, 1), intervals.entries.items.len);
    try std.testing.expectEqual(.confirmed, intervals.entries.items[0].reconciliation);
    try std.testing.expectEqual(@as(u64, 10), intervals.entries.items[0].token.raw());
    try std.testing.expectEqual(@as(u64, 11), next_interval_token);
    try std.testing.expectEqual(@as(u64, 1), metrics.active_intervals_synced);
    try std.testing.expectEqual(@as(u64, 0), host.start_interval_count);
    try std.testing.expectEqual(@as(u64, 0), host.cancel_interval_count);
}

test "interval identity indexes survive wide-table retirement and source reuse without allocation" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var fault = FaultAllocator.init(std.testing.allocator);
    var intervals: IntervalRegistry = .empty;
    defer intervals.deinit(fault.allocator());
    const tokens = try std.testing.allocator.alloc(u8, 10000);
    defer std.testing.allocator.free(tokens);
    try intervals.ensureUnusedCapacity(fault.allocator(), tokens.len);
    fault.configure(1);
    for (tokens, 0..) |_, index| intervals.appendAssumeCapacity(.{
        .token = ids.IntervalToken.fromRaw(index + 1),
        .source_token = tokens[index..].ptr,
        .period_ms = 500,
    });
    const removed = removeActiveIntervalAt(&intervals, 0);
    try std.testing.expectEqual(null, activeIntervalSourceTokenByRuntimeToken(&intervals, removed.token));
    try std.testing.expectEqual(null, activeIntervalBySourceToken(&intervals, removed.source_token));
    try std.testing.expectEqual(@as(?usize, 0), activeIntervalIndexBySourceToken(&intervals, tokens[9999..].ptr));
    intervals.appendAssumeCapacity(.{ .token = ids.IntervalToken.fromRaw(10001), .source_token = removed.source_token, .period_ms = 250 });
    try std.testing.expectEqual(@as(?HostSignalToken, removed.source_token), activeIntervalSourceTokenByRuntimeToken(&intervals, ids.IntervalToken.fromRaw(10001)));
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    intervals.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 0), intervals.by_runtime.count());
    try std.testing.expectEqual(@as(usize, 0), intervals.by_source.count());
    fault.configure(null);
}

fn checkIntervalReservationRefusal(allocator: std.mem.Allocator) !void {
    var intervals: IntervalRegistry = .empty;
    defer intervals.deinit(allocator);
    var token: [1]u8 = undefined;
    try intervals.append(allocator, .{ .token = ids.IntervalToken.fromRaw(1), .source_token = &token, .period_ms = 500 });
    intervals.ensureUnusedCapacity(allocator, 100) catch |err| {
        try std.testing.expectEqual(@as(?HostSignalToken, &token), activeIntervalSourceTokenByRuntimeToken(&intervals, ids.IntervalToken.fromRaw(1)));
        try std.testing.expectEqual(@as(?usize, 0), activeIntervalIndexBySourceToken(&intervals, &token));
        return err;
    };
}

test "interval registry preflight refusal preserves committed identity indexes" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkIntervalReservationRefusal, .{});
}
