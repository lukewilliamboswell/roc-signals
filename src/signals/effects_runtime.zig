//! Runtime tables for pending tasks, intervals, and cleanup effects.

const std = @import("std");
const abi = @import("roc_platform_abi.zig");
const retained_values = @import("retained_values.zig");
const signal_records = @import("signal_records.zig");
const ids = @import("ids.zig");

pub const HostSignalToken = retained_values.HostSignalToken;
pub const HostSignalRecord = signal_records.Record;

/// One live task registration. Completion and cancellation remove the record,
/// so this type cannot represent an inactive task that still owns its token or
/// request buffers.
pub const PendingTask = struct {
    request_id: ids.TaskRequestId,
    owner_scope_id: ids.ScopeId,
    task_token: HostSignalToken,
    task_name: []const u8,
    request: []const u8,
};

pub const ActiveInterval = struct {
    token: ids.IntervalToken,
    source_token: HostSignalToken,
    period_ms: u64,
    reconciliation: enum { pending, confirmed } = .confirmed,
};

pub const CleanupEvents = std.ArrayListUnmanaged([]const u8);

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

/// Returns active task record by token from the maintained active-runtime indexes.
pub fn activeTaskRecordByToken(active_signal_graph: anytype, token: HostSignalToken) ?*HostSignalRecord {
    for (active_signal_graph) |node| {
        if (node.record.taskSource() != null) {
            if (node.record.token().? == token) return node.record;
        }
    }
    return null;
}

/// Returns active task record by name from the maintained active-runtime indexes.
pub fn activeTaskRecordByName(active_signal_graph: anytype, name: []const u8) ?*HostSignalRecord {
    var found: ?*HostSignalRecord = null;
    for (active_signal_graph) |node| {
        const payload = node.record.taskSource() orelse continue;
        if (!std.mem.eql(u8, payload.name, name)) continue;
        if (found != null) @panic("fake task result matched more than one active task source");
        found = node.record;
    }
    return found;
}

/// Returns active interval record count by period from the maintained active-runtime indexes.
pub fn activeIntervalRecordCountByPeriod(active_signal_graph: anytype, period_ms: u64) u64 {
    var count: u64 = 0;
    for (active_signal_graph) |node| {
        if (node.record.intervalSource()) |payload| {
            if (payload.period_ms == period_ms) count += 1;
        }
    }
    return count;
}

/// Returns active interval record by token from the maintained active-runtime indexes.
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

/// Returns active interval record by period from the maintained active-runtime indexes.
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

/// Owns an unpublished task registration. Preparation copies both payloads and
/// reserves registry capacity without consuming a request id or retaining a
/// token until all allocations succeed. The caller must prepare host publication
/// and source propagation before canceling an existing request and committing.
pub const PreparedPendingTask = struct {
    task: ?PendingTask,

    /// Borrows the inputs and reserves one additional registry slot. Refusal
    /// leaves task membership and the request-id sequence unchanged; successful
    /// preparation owns independent buffers and one token reference.
    pub fn prepare(
        allocator: std.mem.Allocator,
        tasks: *std.ArrayListUnmanaged(PendingTask),
        next_task_request_id: u64,
        owner_scope_id: ids.ScopeId,
        task_token: HostSignalToken,
        task_name: []const u8,
        request: []const u8,
    ) std.mem.Allocator.Error!PreparedPendingTask {
        if (next_task_request_id == std.math.maxInt(u64)) @panic("host task request id overflowed");
        const task_name_copy = try allocator.dupe(u8, task_name);
        errdefer allocator.free(task_name_copy);
        const request_copy = try allocator.dupe(u8, request);
        errdefer allocator.free(request_copy);
        try tasks.ensureUnusedCapacity(allocator, 1);
        return .{ .task = .{
            .request_id = ids.TaskRequestId.fromRaw(next_task_request_id),
            .owner_scope_id = owner_scope_id,
            .task_token = retained_values.retainHostSignalToken(task_token),
            .task_name = task_name_copy,
            .request = request_copy,
        } };
    }

    /// Transfers the complete registration into the reserved slot without
    /// allocation. No intervening task start may consume the prepared id.
    pub fn commit(self: *PreparedPendingTask, tasks: *std.ArrayListUnmanaged(PendingTask), next_task_request_id: *u64) ids.TaskRequestId {
        const task = self.task orelse @panic("prepared task committed twice");
        if (task.request_id.raw() != next_task_request_id.*) @panic("prepared task request id changed before commit");
        tasks.appendAssumeCapacity(task);
        next_task_request_id.* += 1;
        self.task = null;
        return task.request_id;
    }

    /// Consumes the occurrence id without inserting a live registration when
    /// the prepared transition also disposes its owner. The caller owns the
    /// returned task until its start/cancel publication and must deinitialize it.
    pub fn commitRetired(self: *PreparedPendingTask, next_task_request_id: *u64) PendingTask {
        const task = self.task orelse @panic("prepared task committed twice");
        if (task.request_id.raw() != next_task_request_id.*) @panic("prepared task request id changed before commit");
        next_task_request_id.* += 1;
        self.task = null;
        return task;
    }

    /// Aborts an unpublished registration, or does nothing after its ownership
    /// has transferred to the live registry. It never cancels a host task.
    pub fn deinit(self: *PreparedPendingTask, allocator: std.mem.Allocator, roc_host: *abi.RocHost) void {
        if (self.task) |*task| deinitPendingTask(allocator, roc_host, task);
        self.task = null;
    }
};

/// Prepares and commits a registry entry. This convenience boundary treats
/// allocation refusal as fatal; transactional callers must keep the prepared
/// registration unpublished until their other fallible preparation succeeds.
pub fn appendPendingTask(
    allocator: std.mem.Allocator,
    tasks: *std.ArrayListUnmanaged(PendingTask),
    next_task_request_id: *u64,
    roc_host: *abi.RocHost,
    owner_scope_id: ids.ScopeId,
    task_token: HostSignalToken,
    task_name: []const u8,
    request: []const u8,
) u64 {
    var prepared = PreparedPendingTask.prepare(allocator, tasks, next_task_request_id.*, owner_scope_id, task_token, task_name, request) catch @panic("out of memory");
    defer prepared.deinit(allocator, roc_host);
    return prepared.commit(tasks, next_task_request_id).raw();
}

/// Appends and start pending task using capacity that must already satisfy the caller's transaction contract.
pub fn appendAndStartPendingTask(
    comptime Ctx: type,
    ctx: Ctx.Handle,
    allocator: std.mem.Allocator,
    tasks: *std.ArrayListUnmanaged(PendingTask),
    next_task_request_id: *u64,
    roc_host: *abi.RocHost,
    owner_scope_id: ids.ScopeId,
    task_token: HostSignalToken,
    task_name: []const u8,
    request: []const u8,
) u64 {
    const request_id = appendPendingTask(allocator, tasks, next_task_request_id, roc_host, owner_scope_id, task_token, task_name, request);
    Ctx.sink(ctx).startTask(ids.TaskRequestId.fromRaw(request_id), task_name, request);
    return request_id;
}

/// Releases pending task and all host registrations or retained values it owns.
pub fn deinitPendingTask(allocator: std.mem.Allocator, roc_host: *abi.RocHost, task: *PendingTask) void {
    retained_values.releaseHostSignalToken(task.task_token, roc_host);
    allocator.free(task.task_name);
    allocator.free(task.request);
    task.* = undefined;
}

/// Cancels pending task and releases its bounded host-retained work.
pub fn cancelPendingTask(comptime Ctx: type, ctx: Ctx.Handle, allocator: std.mem.Allocator, roc_host: *abi.RocHost, task: *PendingTask) void {
    Ctx.sink(ctx).cancelTask(task.request_id);
    deinitPendingTask(allocator, roc_host, task);
}

/// Clears pending tasks while retaining bounded storage where the type promises reuse.
pub fn clearPendingTasks(comptime Ctx: type, ctx: Ctx.Handle, allocator: std.mem.Allocator, tasks: *std.ArrayListUnmanaged(PendingTask), roc_host: ?*abi.RocHost) void {
    const host = roc_host orelse {
        if (tasks.items.len != 0) @panic("pending tasks cannot release tokens without a Roc host");
        return;
    };
    for (tasks.items) |*task| {
        cancelPendingTask(Ctx, ctx, allocator, host, task);
    }
    tasks.items.len = 0;
}

/// Resolves pending task index by name from the bounded task registry without scanning unrelated work.
pub fn pendingTaskIndexByName(tasks: []const PendingTask, name: []const u8) ?usize {
    var found: ?usize = null;
    for (tasks, 0..) |task, index| {
        if (!std.mem.eql(u8, task.task_name, name)) continue;
        if (found != null) @panic("fake task result matched more than one pending request");
        found = index;
    }
    return found;
}

/// Resolves pending task count by name from the bounded task registry without scanning unrelated work.
pub fn pendingTaskCountByName(tasks: []const PendingTask, name: []const u8) u64 {
    var count: u64 = 0;
    for (tasks) |task| {
        if (std.mem.eql(u8, task.task_name, name)) count += 1;
    }
    return count;
}

/// Resolves pending task index by request id from the bounded task registry without scanning unrelated work.
pub fn pendingTaskIndexByRequestId(tasks: []const PendingTask, request_id: ids.TaskRequestId) ?usize {
    var found: ?usize = null;
    for (tasks, 0..) |task, index| {
        if (task.request_id != request_id) continue;
        if (found != null) @panic("task request id matched more than one pending request");
        found = index;
    }
    return found;
}

/// Removes pending task at and releases the ownership attached to that live entry.
pub fn removePendingTaskAt(tasks: *std.ArrayListUnmanaged(PendingTask), index: usize) PendingTask {
    if (index >= tasks.items.len) @panic("pending task index is out of bounds");
    const task = tasks.items[index];
    const last_index = tasks.items.len - 1;
    if (index != last_index) {
        tasks.items[index] = tasks.items[last_index];
    }
    tasks.items.len = last_index;
    return task;
}

/// Cancels pending tasks by task token and releases its bounded host-retained work.
pub fn cancelPendingTasksByTaskToken(comptime Ctx: type, ctx: Ctx.Handle, allocator: std.mem.Allocator, tasks: *std.ArrayListUnmanaged(PendingTask), roc_host: ?*abi.RocHost, task_token: HostSignalToken) void {
    const host = roc_host orelse {
        for (tasks.items) |task| {
            if (task.task_token == task_token) @panic("pending task cannot release token without a Roc host");
        }
        return;
    };

    var index: usize = 0;
    while (index < tasks.items.len) {
        if (tasks.items[index].task_token != task_token) {
            index += 1;
            continue;
        }

        var task = removePendingTaskAt(tasks, index);
        cancelPendingTask(Ctx, ctx, allocator, host, &task);
    }
}

/// Cancels pending tasks in scope subtree and releases its bounded host-retained work.
pub fn cancelPendingTasksInScopeSubtree(comptime Ctx: type, ctx: Ctx.Handle, allocator: std.mem.Allocator, tasks: *std.ArrayListUnmanaged(PendingTask), roc_host: ?*abi.RocHost, scope_id: ids.ScopeId, scope_lookup: anytype) void {
    const host = roc_host orelse {
        for (tasks.items) |task| {
            if (scope_lookup.descendantOrSelf(task.owner_scope_id, scope_id)) @panic("pending task cannot release token without a Roc host");
        }
        return;
    };

    var write_index: usize = 0;
    for (tasks.items) |*task| {
        if (scope_lookup.descendantOrSelf(task.owner_scope_id, scope_id)) {
            cancelPendingTask(Ctx, ctx, allocator, host, task);
            continue;
        }
        tasks.items[write_index] = task.*;
        write_index += 1;
    }
    tasks.items.len = write_index;
}

/// Returns active interval source token by runtime token from the maintained active-runtime indexes.
pub fn activeIntervalSourceTokenByRuntimeToken(intervals: []const ActiveInterval, token: ids.IntervalToken) ?HostSignalToken {
    var found: ?HostSignalToken = null;
    for (intervals) |interval| {
        if (interval.token != token) continue;
        if (found != null) @panic("runtime interval token matched more than one active interval");
        found = interval.source_token;
    }
    return found;
}

/// Returns active interval by source token from the maintained active-runtime indexes.
pub fn activeIntervalBySourceToken(intervals: []ActiveInterval, source_token: HostSignalToken) ?*ActiveInterval {
    var found: ?*ActiveInterval = null;
    for (intervals) |*interval| {
        if (interval.source_token != source_token) continue;
        if (found != null) @panic("interval source token matched more than one runtime interval");
        found = interval;
    }
    return found;
}

/// Returns active interval index by source token from the maintained active-runtime indexes.
pub fn activeIntervalIndexBySourceToken(intervals: []const ActiveInterval, source_token: HostSignalToken) ?usize {
    var found_index: ?usize = null;
    for (intervals, 0..) |interval, index| {
        if (interval.source_token != source_token) continue;
        if (found_index != null) @panic("interval source token matched more than one runtime interval");
        found_index = index;
    }
    return found_index;
}

/// Marks existing intervals unseen before reconciling declarations from the active graph.
pub fn markActiveIntervalsInactive(intervals: []ActiveInterval) void {
    for (intervals) |*interval| {
        interval.reconciliation = .pending;
    }
}

/// Removes active interval at and releases the ownership attached to that live entry.
pub fn removeActiveIntervalAt(intervals: *std.ArrayListUnmanaged(ActiveInterval), index: usize) ActiveInterval {
    if (index >= intervals.items.len) @panic("active interval index is out of bounds");
    const interval = intervals.items[index];
    const last_index = intervals.items.len - 1;
    if (index != last_index) {
        intervals.items[index] = intervals.items[last_index];
    }
    intervals.items.len = last_index;
    return interval;
}

/// Clears active intervals while retaining bounded storage where the type promises reuse.
pub fn clearActiveIntervals(comptime Ctx: type, ctx: Ctx.Handle, intervals: *std.ArrayListUnmanaged(ActiveInterval), roc_host: ?*abi.RocHost) void {
    const host = roc_host orelse {
        if (intervals.items.len != 0) @panic("active intervals cannot release tokens without a Roc host");
        intervals.items.len = 0;
        return;
    };
    for (intervals.items) |interval| {
        Ctx.sink(ctx).cancelInterval(interval.token);
        retained_values.releaseHostSignalToken(interval.source_token, host);
    }
    intervals.clearRetainingCapacity();
}

/// Ensures active interval capacity or state before publication can begin.
pub fn ensureActiveInterval(comptime Ctx: type, ctx: Ctx.Handle, allocator: std.mem.Allocator, intervals: *std.ArrayListUnmanaged(ActiveInterval), next_interval_token: *u64, roc_host: *abi.RocHost, source_token: HostSignalToken, period_ms: u64) void {
    if (activeIntervalBySourceToken(intervals.items, source_token)) |interval| {
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
pub fn reserveActiveIntervals(allocator: std.mem.Allocator, intervals: *std.ArrayListUnmanaged(ActiveInterval), additional: usize) error{OutOfMemory}!void {
    intervals.ensureUnusedCapacity(allocator, additional) catch return error.OutOfMemory;
}

/// Registers an interval source during publication using capacity that
/// `reserveActiveIntervals` already secured. A source token that is already
/// registered is confirmed rather than duplicated, exactly as
/// `ensureActiveInterval` does on the preparation path.
pub fn ensureActiveIntervalAssumeCapacity(comptime Ctx: type, ctx: Ctx.Handle, intervals: *std.ArrayListUnmanaged(ActiveInterval), next_interval_token: *u64, source_token: HostSignalToken, period_ms: u64) void {
    if (activeIntervalBySourceToken(intervals.items, source_token)) |interval| {
        if (interval.period_ms != period_ms) @panic("interval source token changed period");
        interval.reconciliation = .confirmed;
        return;
    }

    if (next_interval_token.* == std.math.maxInt(u64)) @panic("host interval token overflowed");
    if (intervals.items.len == intervals.capacity) @panic("interval registration exceeded its reserved capacity");
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
pub fn removeActiveIntervalBySourceToken(comptime Ctx: type, ctx: Ctx.Handle, intervals: *std.ArrayListUnmanaged(ActiveInterval), roc_host: *abi.RocHost, source_token: HostSignalToken) void {
    const index = activeIntervalIndexBySourceToken(intervals.items, source_token) orelse @panic("active interval removal missed its source token");
    const interval = removeActiveIntervalAt(intervals, index);
    Ctx.sink(ctx).cancelInterval(interval.token);
    retained_values.releaseHostSignalToken(interval.source_token, roc_host);
}

/// Cancels intervals not rediscovered and commits the current bounded registration set.
pub fn finishActiveIntervalSync(comptime Ctx: type, ctx: Ctx.Handle, intervals: *std.ArrayListUnmanaged(ActiveInterval), roc_host: ?*abi.RocHost) void {
    const host = roc_host orelse {
        for (intervals.items) |interval| {
            if (interval.reconciliation == .pending) @panic("unconfirmed interval cannot release token without a Roc host");
        }
        return;
    };

    var write_index: usize = 0;
    for (intervals.items) |interval| {
        if (interval.reconciliation == .pending) {
            Ctx.sink(ctx).cancelInterval(interval.token);
            retained_values.releaseHostSignalToken(interval.source_token, host);
            continue;
        }
        intervals.items[write_index] = interval;
        write_index += 1;
    }
    intervals.items.len = write_index;
}

/// Reconciles interval registrations from active graph declarations after propagation.
pub fn syncActiveIntervalsFromGraph(
    comptime Ctx: type,
    ctx: Ctx.Handle,
    allocator: std.mem.Allocator,
    intervals: *std.ArrayListUnmanaged(ActiveInterval),
    next_interval_token: *u64,
    roc_host: ?*abi.RocHost,
    active_signal_graph: anytype,
    metrics: anytype,
) void {
    markActiveIntervalsInactive(intervals.items);
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
    start_task_count: u64 = 0,
    cancel_task_count: u64 = 0,
    last_started_task: ?u64 = null,
    last_canceled_task: ?u64 = null,
    start_interval_count: u64 = 0,
    cancel_interval_count: u64 = 0,
};

const TestIntervalSink = struct {
    host: *TestIntervalHost,

    /// Starts bounded asynchronous host work for an engine-issued task request.
    pub fn startTask(self: @This(), request_id: ids.TaskRequestId, _: []const u8, _: []const u8) void {
        self.host.start_task_count += 1;
        self.host.last_started_task = request_id.raw();
    }

    /// Cancels host work for a task request retired by engine lifecycle policy.
    pub fn cancelTask(self: @This(), request_id: ids.TaskRequestId) void {
        self.host.cancel_task_count += 1;
        self.host.last_canceled_task = request_id.raw();
    }

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

const TestScopeLookup = struct {
    root_scope_id: ids.ScopeId,
    child_scope_id: ids.ScopeId,

    /// Tests explicit scope ancestry without consulting rendered DOM structure.
    pub fn descendantOrSelf(self: @This(), owner_scope_id: ids.ScopeId, scope_id: ids.ScopeId) bool {
        return owner_scope_id == scope_id or (scope_id == self.root_scope_id and owner_scope_id == self.child_scope_id);
    }
};

fn testTaskRecord(token: HostSignalToken, name: []const u8) HostSignalRecord {
    return .{
        .ref_count = 1,
        .payload = .{ .task_source = .{
            .name = name,
            .payload_cap = undefined,
            .initial = .fromAbi(token),
            .done = undefined,
            .failed = undefined,
            .cap = undefined,
            .reset_on_start = false,
        } },
    };
}

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

test "pending tasks and active intervals retain callable tokens for their full lifecycle" {
    test_signal_token_drop_count = 0;
    var env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&env);
    var host = TestIntervalHost{};

    var tasks: std.ArrayListUnmanaged(PendingTask) = .empty;
    defer tasks.deinit(std.testing.allocator);
    var next_request_id: u64 = 1;
    const task_token = testSignalToken(&roc_host, 1);
    _ = appendPendingTask(std.testing.allocator, &tasks, &next_request_id, &roc_host, ids.root_scope, task_token, "load", "request");
    retained_values.releaseHostSignalToken(task_token, &roc_host);
    try std.testing.expectEqual(@as(u64, 0), test_signal_token_drop_count);
    clearPendingTasks(TestIntervalCtx, &host, std.testing.allocator, &tasks, &roc_host);
    try std.testing.expectEqual(@as(u64, 1), test_signal_token_drop_count);

    var intervals: std.ArrayListUnmanaged(ActiveInterval) = .empty;
    defer intervals.deinit(std.testing.allocator);
    var next_interval_token: u64 = 1;
    const interval_token = testSignalToken(&roc_host, 2);
    ensureActiveInterval(TestIntervalCtx, &host, std.testing.allocator, &intervals, &next_interval_token, &roc_host, interval_token, 250);
    retained_values.releaseHostSignalToken(interval_token, &roc_host);
    try std.testing.expectEqual(@as(u64, 1), test_signal_token_drop_count);
    clearActiveIntervals(TestIntervalCtx, &host, &intervals, &roc_host);
    try std.testing.expectEqual(@as(u64, 2), test_signal_token_drop_count);
}

test "effects runtime finds and removes pending tasks" {
    var first_token_storage = [_]u8{0};
    var second_token_storage = [_]u8{0};
    const first_token = first_token_storage[0..].ptr;
    const second_token = second_token_storage[0..].ptr;
    var tasks: std.ArrayListUnmanaged(PendingTask) = .empty;
    defer tasks.deinit(std.testing.allocator);

    tasks.append(std.testing.allocator, .{
        .request_id = ids.TaskRequestId.fromRaw(1),
        .owner_scope_id = ids.ScopeId.fromRaw(10),
        .task_token = first_token,
        .task_name = "load",
        .request = "a",
    }) catch @panic("out of memory");
    tasks.append(std.testing.allocator, .{
        .request_id = ids.TaskRequestId.fromRaw(2),
        .owner_scope_id = ids.ScopeId.fromRaw(11),
        .task_token = second_token,
        .task_name = "save",
        .request = "b",
    }) catch @panic("out of memory");

    try std.testing.expectEqual(@as(?usize, 1), pendingTaskIndexByName(tasks.items, "save"));
    const removed = removePendingTaskAt(&tasks, 0);
    try std.testing.expectEqual(@as(u64, 1), removed.request_id.raw());
    try std.testing.expectEqual(@as(usize, 1), tasks.items.len);
    try std.testing.expectEqual(@as(u64, 2), tasks.items[0].request_id.raw());
}

test "effects runtime finds active effect source records" {
    var task_token_storage = [_]u8{0};
    var first_interval_token_storage = [_]u8{0};
    var second_interval_token_storage = [_]u8{0};
    const task_token = task_token_storage[0..].ptr;
    const first_interval_token = first_interval_token_storage[0..].ptr;
    const second_interval_token = second_interval_token_storage[0..].ptr;
    var task_record = testTaskRecord(task_token, "load");
    var first_interval_record = testIntervalRecord(first_interval_token, 250);
    var second_interval_record = testIntervalRecord(second_interval_token, 500);
    var ref_record = HostSignalRecord{
        .ref_count = 1,
        .payload = .{ .ref = 42 },
    };
    const active_nodes = [_]TestActiveNode{
        .{ .record = &ref_record },
        .{ .record = &task_record },
        .{ .record = &first_interval_record },
        .{ .record = &second_interval_record },
    };

    try std.testing.expectEqual(@as(?*HostSignalRecord, &task_record), activeTaskRecordByToken(active_nodes[0..], task_token));
    try std.testing.expectEqual(@as(?*HostSignalRecord, &task_record), activeTaskRecordByName(active_nodes[0..], "load"));
    try std.testing.expectEqual(@as(u64, 1), activeIntervalRecordCountByPeriod(active_nodes[0..], 250));
    try std.testing.expectEqual(@as(?*HostSignalRecord, &first_interval_record), activeIntervalRecordByToken(active_nodes[0..], first_interval_token));
    try std.testing.expectEqual(@as(?*HostSignalRecord, &second_interval_record), activeIntervalRecordByPeriod(active_nodes[0..], 500));
    try std.testing.expectEqual(@as(?*HostSignalRecord, null), activeTaskRecordByName(active_nodes[0..], "missing"));
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

test "pending task membership is the active lifecycle state" {
    var first_token_storage = [_]u8{0};
    var second_token_storage = [_]u8{0};
    const first_token = first_token_storage[0..].ptr;
    const second_token = second_token_storage[0..].ptr;
    var tasks: std.ArrayListUnmanaged(PendingTask) = .empty;
    defer tasks.deinit(std.testing.allocator);

    tasks.append(std.testing.allocator, .{
        .request_id = ids.TaskRequestId.fromRaw(10),
        .owner_scope_id = ids.ScopeId.fromRaw(1),
        .task_token = first_token,
        .task_name = "load",
        .request = "a",
    }) catch @panic("out of memory");
    tasks.append(std.testing.allocator, .{
        .request_id = ids.TaskRequestId.fromRaw(11),
        .owner_scope_id = ids.ScopeId.fromRaw(2),
        .task_token = second_token,
        .task_name = "load",
        .request = "b",
    }) catch @panic("out of memory");

    try std.testing.expectEqual(@as(u64, 2), pendingTaskCountByName(tasks.items, "load"));
    try std.testing.expectEqual(@as(?usize, 0), pendingTaskIndexByRequestId(tasks.items, ids.TaskRequestId.fromRaw(10)));
    try std.testing.expectEqual(@as(?usize, 1), pendingTaskIndexByRequestId(tasks.items, ids.TaskRequestId.fromRaw(11)));
}

test "pending task preparation refusal preserves membership and request ids" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&env);
    const token = testSignalToken(&roc_host, 1);
    defer retained_values.releaseHostSignalToken(token, &roc_host);

    // Empty-registry preparation has three allocations: name, request, and
    // registry storage. Cross every refusal with retry and unpublished abort.
    for (1..4) |failure_number| {
        var fault = FaultAllocator.init(std.testing.allocator);
        const allocator = fault.allocator();
        var tasks: std.ArrayListUnmanaged(PendingTask) = .empty;
        defer tasks.deinit(allocator);
        defer for (tasks.items) |*task| deinitPendingTask(allocator, &roc_host, task);
        var next_request_id: u64 = 100;
        fault.configure(failure_number);
        try std.testing.expectError(error.OutOfMemory, PreparedPendingTask.prepare(allocator, &tasks, next_request_id, ids.ScopeId.fromRaw(10), token, "load", "payload"));
        try std.testing.expectEqual(@as(usize, 1), fault.induced_failures);
        try std.testing.expectEqual(@as(usize, 0), tasks.items.len);
        try std.testing.expectEqual(@as(u64, 100), next_request_id);

        fault.configure(null);
        var aborted = try PreparedPendingTask.prepare(allocator, &tasks, next_request_id, ids.ScopeId.fromRaw(10), token, "load", "payload");
        fault.configure(1);
        aborted.deinit(allocator, &roc_host);
        try std.testing.expectEqual(@as(usize, 0), fault.attempts);
        try std.testing.expectEqual(@as(usize, 0), tasks.items.len);
        try std.testing.expectEqual(@as(u64, 100), next_request_id);

        fault.configure(null);
        var retry = try PreparedPendingTask.prepare(allocator, &tasks, next_request_id, ids.ScopeId.fromRaw(10), token, "load", "payload");
        fault.configure(1);
        try std.testing.expectEqual(ids.TaskRequestId.fromRaw(100), retry.commit(&tasks, &next_request_id));
        retry.deinit(allocator, &roc_host);
        try std.testing.expectEqual(@as(usize, 0), fault.attempts);
        try std.testing.expectEqual(@as(u64, 101), next_request_id);
        try std.testing.expectEqualStrings("payload", tasks.items[0].request);
    }
}

test "aborting a replacement task leaves the old request live" {
    var env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&env);
    const token = testSignalToken(&roc_host, 1);
    defer retained_values.releaseHostSignalToken(token, &roc_host);
    const allocator = std.testing.allocator;
    var tasks: std.ArrayListUnmanaged(PendingTask) = .empty;
    defer tasks.deinit(allocator);
    var next_request_id: u64 = 100;
    _ = appendPendingTask(allocator, &tasks, &next_request_id, &roc_host, ids.ScopeId.fromRaw(10), token, "load", "old");
    defer deinitPendingTask(allocator, &roc_host, &tasks.items[0]);
    var replacement = try PreparedPendingTask.prepare(allocator, &tasks, next_request_id, ids.ScopeId.fromRaw(10), token, "load", "new");
    try std.testing.expectEqual(@as(usize, 1), tasks.items.len);
    try std.testing.expectEqualStrings("old", tasks.items[0].request);
    replacement.deinit(allocator, &roc_host);
    try std.testing.expectEqual(@as(usize, 1), tasks.items.len);
    try std.testing.expectEqual(ids.TaskRequestId.fromRaw(100), tasks.items[0].request_id);
    try std.testing.expectEqualStrings("old", tasks.items[0].request);
    try std.testing.expectEqual(@as(u64, 101), next_request_id);
}

test "effects runtime starts clears and cancels pending tasks by token" {
    var env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&env);
    const first_token = testSignalToken(&roc_host, 1);
    defer retained_values.releaseHostSignalToken(first_token, &roc_host);
    const second_token = testSignalToken(&roc_host, 2);
    defer retained_values.releaseHostSignalToken(second_token, &roc_host);
    const missing_token = testSignalToken(&roc_host, 3);
    defer retained_values.releaseHostSignalToken(missing_token, &roc_host);

    var host = TestIntervalHost{};
    var tasks: std.ArrayListUnmanaged(PendingTask) = .empty;
    defer tasks.deinit(std.testing.allocator);
    var next_request_id: u64 = 100;

    const started_id = appendAndStartPendingTask(TestIntervalCtx, &host, std.testing.allocator, &tasks, &next_request_id, &roc_host, ids.ScopeId.fromRaw(10), first_token, "load", "a");
    try std.testing.expectEqual(@as(u64, 100), started_id);
    try std.testing.expectEqual(@as(u64, 1), host.start_task_count);
    try std.testing.expectEqual(@as(?u64, 100), host.last_started_task);

    _ = appendPendingTask(std.testing.allocator, &tasks, &next_request_id, &roc_host, ids.ScopeId.fromRaw(11), second_token, "save", "b");
    _ = appendPendingTask(std.testing.allocator, &tasks, &next_request_id, &roc_host, ids.ScopeId.fromRaw(12), first_token, "load", "c");

    cancelPendingTasksByTaskToken(TestIntervalCtx, &host, std.testing.allocator, &tasks, null, missing_token);
    try std.testing.expectEqual(@as(usize, 3), tasks.items.len);

    cancelPendingTasksByTaskToken(TestIntervalCtx, &host, std.testing.allocator, &tasks, &roc_host, first_token);
    try std.testing.expectEqual(@as(usize, 1), tasks.items.len);
    try std.testing.expectEqual(second_token, tasks.items[0].task_token);
    try std.testing.expectEqual(@as(u64, 2), host.cancel_task_count);

    clearPendingTasks(TestIntervalCtx, &host, std.testing.allocator, &tasks, &roc_host);
    try std.testing.expectEqual(@as(usize, 0), tasks.items.len);
    try std.testing.expectEqual(@as(u64, 3), host.cancel_task_count);
}

test "effects runtime cancels pending tasks in a scope subtree" {
    var env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&env);
    const root_token = testSignalToken(&roc_host, 10);
    defer retained_values.releaseHostSignalToken(root_token, &roc_host);
    const child_token = testSignalToken(&roc_host, 11);
    defer retained_values.releaseHostSignalToken(child_token, &roc_host);
    const outside_token = testSignalToken(&roc_host, 20);
    defer retained_values.releaseHostSignalToken(outside_token, &roc_host);

    var host = TestIntervalHost{};
    var tasks: std.ArrayListUnmanaged(PendingTask) = .empty;
    defer tasks.deinit(std.testing.allocator);
    var next_request_id: u64 = 200;

    _ = appendPendingTask(std.testing.allocator, &tasks, &next_request_id, &roc_host, ids.ScopeId.fromRaw(10), root_token, "root", "r");
    _ = appendPendingTask(std.testing.allocator, &tasks, &next_request_id, &roc_host, ids.ScopeId.fromRaw(11), child_token, "child", "c");
    _ = appendPendingTask(std.testing.allocator, &tasks, &next_request_id, &roc_host, ids.ScopeId.fromRaw(20), outside_token, "outside", "o");

    const lookup = TestScopeLookup{ .root_scope_id = ids.ScopeId.fromRaw(10), .child_scope_id = ids.ScopeId.fromRaw(11) };
    cancelPendingTasksInScopeSubtree(TestIntervalCtx, &host, std.testing.allocator, &tasks, null, ids.ScopeId.fromRaw(99), lookup);
    try std.testing.expectEqual(@as(usize, 3), tasks.items.len);

    cancelPendingTasksInScopeSubtree(TestIntervalCtx, &host, std.testing.allocator, &tasks, &roc_host, ids.ScopeId.fromRaw(10), lookup);
    try std.testing.expectEqual(@as(usize, 1), tasks.items.len);
    try std.testing.expectEqual(outside_token, tasks.items[0].task_token);
    try std.testing.expectEqual(@as(u64, 2), host.cancel_task_count);

    clearPendingTasks(TestIntervalCtx, &host, std.testing.allocator, &tasks, &roc_host);
    try std.testing.expectEqual(@as(u64, 3), host.cancel_task_count);
}

test "effects runtime updates active interval table" {
    var first_token_storage = [_]u8{0};
    var second_token_storage = [_]u8{0};
    const first_token = first_token_storage[0..].ptr;
    const second_token = second_token_storage[0..].ptr;
    var intervals: std.ArrayListUnmanaged(ActiveInterval) = .empty;
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

    try std.testing.expectEqual(@as(?HostSignalToken, first_token), activeIntervalSourceTokenByRuntimeToken(intervals.items, ids.IntervalToken.fromRaw(10)));
    markActiveIntervalsInactive(intervals.items);
    try std.testing.expectEqual(.pending, intervals.items[0].reconciliation);
    try std.testing.expectEqual(@as(?*ActiveInterval, &intervals.items[1]), activeIntervalBySourceToken(intervals.items, second_token));
    const removed = removeActiveIntervalAt(&intervals, 0);
    try std.testing.expectEqual(@as(u64, 10), removed.token.raw());
    try std.testing.expectEqual(@as(usize, 1), intervals.items.len);
    try std.testing.expectEqual(@as(u64, 11), intervals.items[0].token.raw());
}

test "effects runtime manages interval lifecycle transitions" {
    var env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.default() };
    var roc_host = abi.makeRocHost(&env);
    const first_token = testSignalToken(&roc_host, 100);
    defer retained_values.releaseHostSignalToken(first_token, &roc_host);
    const second_token = testSignalToken(&roc_host, 200);
    defer retained_values.releaseHostSignalToken(second_token, &roc_host);

    var host = TestIntervalHost{};
    var intervals: std.ArrayListUnmanaged(ActiveInterval) = .empty;
    defer intervals.deinit(std.testing.allocator);
    var next_interval_token: u64 = 10;

    ensureActiveInterval(TestIntervalCtx, &host, std.testing.allocator, &intervals, &next_interval_token, &roc_host, first_token, 250);
    ensureActiveInterval(TestIntervalCtx, &host, std.testing.allocator, &intervals, &next_interval_token, &roc_host, second_token, 500);
    try std.testing.expectEqual(@as(usize, 2), intervals.items.len);
    try std.testing.expectEqual(@as(u64, 12), next_interval_token);
    try std.testing.expectEqual(@as(u64, 2), host.start_interval_count);
    try std.testing.expectEqual(@as(?usize, 1), activeIntervalIndexBySourceToken(intervals.items, second_token));

    clearActiveIntervals(TestIntervalCtx, &host, &intervals, &roc_host);
    try std.testing.expectEqual(@as(usize, 0), intervals.items.len);
    try std.testing.expectEqual(@as(u64, 2), host.cancel_interval_count);

    ensureActiveInterval(TestIntervalCtx, &host, std.testing.allocator, &intervals, &next_interval_token, &roc_host, first_token, 250);
    ensureActiveInterval(TestIntervalCtx, &host, std.testing.allocator, &intervals, &next_interval_token, &roc_host, second_token, 500);
    try std.testing.expectEqual(@as(u64, 4), host.start_interval_count);

    removeActiveIntervalBySourceToken(TestIntervalCtx, &host, &intervals, &roc_host, second_token);
    try std.testing.expectEqual(@as(usize, 1), intervals.items.len);
    try std.testing.expectEqual(@as(u64, 3), host.cancel_interval_count);

    markActiveIntervalsInactive(intervals.items);
    finishActiveIntervalSync(TestIntervalCtx, &host, &intervals, &roc_host);
    try std.testing.expectEqual(@as(usize, 0), intervals.items.len);
    try std.testing.expectEqual(@as(u64, 4), host.cancel_interval_count);

    const no_host_token = testSignalToken(&roc_host, 300);
    intervals.append(std.testing.allocator, .{
        .token = ids.IntervalToken.fromRaw(99),
        .source_token = no_host_token,
        .period_ms = 1000,
        .reconciliation = .confirmed,
    }) catch @panic("out of memory");
    finishActiveIntervalSync(TestIntervalCtx, &host, &intervals, null);
    try std.testing.expectEqual(@as(usize, 1), intervals.items.len);
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

    var intervals: std.ArrayListUnmanaged(ActiveInterval) = .empty;
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

    try std.testing.expectEqual(@as(usize, 1), intervals.items.len);
    try std.testing.expectEqual(.confirmed, intervals.items[0].reconciliation);
    try std.testing.expectEqual(@as(u64, 10), intervals.items[0].token.raw());
    try std.testing.expectEqual(@as(u64, 11), next_interval_token);
    try std.testing.expectEqual(@as(u64, 1), metrics.active_intervals_synced);
    try std.testing.expectEqual(@as(u64, 0), host.start_interval_count);
    try std.testing.expectEqual(@as(u64, 0), host.cancel_interval_count);
}
