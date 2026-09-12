//! Model-based fuzzing for canonical stable-slot `Rows` transitions.
//!
//! # Why this target exists
//!
//! `rows_transition.PreparedTransition` is the engine's sparse prepare-then-
//! commit seam for a committed `Rows` site: preparation shadows only the edited
//! rows and their neighbours, validates the batch, and preflights every
//! persistent capacity; commit then rewrites the touched records without
//! allocating, and abort leaves the committed site byte for byte unchanged.
//! Those are properties of a *history* - which rows were touched by earlier
//! generations, which slots were retired and reclaimed, which owner token the
//! site is currently authenticated to - so this target generates histories and
//! checks each transition against an ordered-array model.
//!
//! # What is generated
//!
//! A bounded sequence of valid descendants of one site. Each step is one of:
//!
//!  1. **A stable-slot batch** of one to three canonical `insert`, `remove`
//!     range, `move` range, `update`, or `clear` edits, each drawn against the
//!     model as it stands after the previous edit in the same batch, so later
//!     edits address rows earlier ones created or moved. A batch never retires
//!     a row it created: a normalized delta does not emit that pair, and the
//!     transition refuses it (`InvalidOwnerToken` from the order journal, since
//!     a dead fresh row is never claimed) rather than modelling it.
//!  2. **An initial snapshot** through `prepareInitial`, when the site is
//!     empty: the path a newly claimed site takes, which authenticates against
//!     the site's own owner rather than a parent token.
//!  3. **A lineage fork.** A delta from a stale parent token must be refused as
//!     `ParentMismatch` and publish nothing; the site is then rebuilt through the
//!     counted clear-and-insert snapshot path from its real owner.
//!
//! Every step may also abort its prepared transition and prepare it again
//! before committing, and every step decodes a fault plan (below).
//!
//! # Oracles
//!
//!  - **The committed site is the model.** After every commit, and after every
//!    abort, the site's owner, length, intrusive order, keys, metadata, and
//!    key and stable-slot indexes equal the model exactly.
//!  - **The candidate is the model before commit.** A prepared transition's
//!    `iterateCandidate` and `candidateLen` must already describe the model's
//!    next state, because publication stages row scopes from that view.
//!  - **Lineage is authenticated.** A stale parent is refused, and only as
//!    `ParentMismatch`.
//!  - **Complete reclamation.** Teardown leaves the run's debug allocator with
//!    nothing outstanding.
//!
//! # Allocation failure
//!
//! design.md, "Memory management and allocation failure", states the
//! verification principle as *exhaustive fault placement*. `prepareStable` and
//! `prepareInitial` are the fallible seams here - shadowing, key copies, the
//! order journal, render-order preflight, and `Store.prepareRowClaims` all
//! allocate - and `commit` afterwards cannot. The store and every transition
//! therefore allocate through one `FaultAllocator`, and before each step's real
//! transition the same batch is probed with the allocator failing from attempt
//! `N` onwards. Each step decodes its own plan: no probe, one sampled `N`, or an
//! ascending sweep of every `N` until preparation succeeds. `FaultAllocator` is
//! *sticky* - attempt `N` and every later attempt fail - so a preparation that
//! succeeds with `N` armed made fewer than `N` attempts and the sweep is
//! complete without an attempt-counting pass. Every probe, refused or not, is
//! aborted; the transition that publishes is the retry.
//!
//! The oracles that axis adds:
//!
//!  - **A refusal publishes nothing.** The site header, every committed row
//!    (identity, key bytes, links, metadata), the site and store index sizes,
//!    the outstanding claim reservations, the row pool's per-slot state and
//!    generation, and the render-order index are deep-copied before each probe
//!    and compared afterwards. A partial mutation would survive the retry as
//!    silent corruption rather than as a failed transition, and the mutations
//!    worth catching are single-row ones a summary would not distinguish. The
//!    free list's link order is the one thing not compared: aborting relinks
//!    released claims at the head, which permutes it without changing the set.
//!  - **Claims balance.** A refused preparation may not leave a row claim or an
//!    index reservation outstanding, since the next preparation would then
//!    preflight against phantom capacity.
//!  - **The retry lands identically.** A probe that succeeded is aborted, and
//!    its candidate must already have been the model the retry then commits.
//!  - **Commit is allocation-free.** The allocator is armed to fail its very
//!    next attempt before `commit` runs, so a commit that reaches the allocator
//!    at all is a run failure rather than a latent fatal boundary.
//!  - **Refusals are honest.** `OutOfMemory` is the only acceptable answer to an
//!    injected allocation failure.
//!
//! # Not covered
//!
//! Key-addressed `PreparedTransition.prepare` is reached only by unit tests -
//! the engine drives the stable-slot paths - so it is not generated here. Render
//! spans are left at their empty value: exercising `setCandidateRenderSpan`
//! needs the descriptor stream a mounted tree provides, which `structural`
//! owns. Invalid sink framing is tested at the sink unit seam, because this
//! generator promises valid programs.
//!
//! To replay a crash:
//!   python3 scripts/fuzz.py repro rows-transitions <crash-file> --verbose

const std = @import("std");
const signals = @import("signals");
const FuzzReader = @import("FuzzReader.zig");

const rows = signals.rows_transition;
const FaultAllocator = signals.fault_allocator.FaultAllocator;
const OwnerToken = rows.OwnerToken;
const RowId = rows.RowId;
const StableEdit = rows.StableEdit;

const max_rows = 24;
const max_steps = 48;
/// Edits one stable batch may carry. Later edits address rows earlier ones
/// created, which is where a shadow that was attached but not yet indexed
/// would show.
const max_edits_per_step = 3;
/// Highest single fault position a step can sample. A three-edit batch over a
/// two-dozen-row site makes a few dozen attempts, so positions past this mostly
/// succeed and coverage feedback steers away from them.
const max_sampled_fault_attempt = 32;
/// Ceiling on an ascending sweep. A batch still refused with this many attempts
/// armed is allocating far more than a bounded sparse transition should, which
/// is itself a finding.
const max_fault_sweep_attempts = 200;

const ModelRow = struct {
    slot: u64,
    key_id: u64,
    value: u64,
    /// Created by an earlier edit of the batch being generated. A normalized
    /// delta never retires a row it created in the same batch, and the
    /// transition relies on that: a fresh row that is dead by the end of the
    /// batch is never claimed, so an order edit naming it cannot resolve.
    fresh: bool = false,
};

/// How one step probes allocation failure before its real transition.
const Probe = enum { none, single, sweep };

/// Which preparation entry point a step drives. Both take the same stable
/// edits; they differ in how the site's lineage is authenticated.
const Kind = enum { stable, initial };

/// One step's transition, described so it can be prepared again - for a
/// probe, an abort-and-retry, or the real thing.
const Transition = struct {
    kind: Kind,
    parent: OwnerToken,
    next: OwnerToken,
    edits: []const StableEdit,

    fn prepare(self: Transition, allocator: std.mem.Allocator, store: *rows.Store, site: rows.SiteId) rows.Error!rows.PreparedTransition {
        return switch (self.kind) {
            .stable => rows.PreparedTransition.prepareStable(allocator, store, site, self.parent, self.next, self.edits),
            .initial => rows.PreparedTransition.prepareInitial(allocator, store, site, self.next, self.edits),
        };
    }
};

/// Everything one run holds: the store under test, the fault allocator it
/// allocates through, and the counters the verbose replay reports.
const Run = struct {
    backing: std.mem.Allocator,
    fault: *FaultAllocator,
    allocator: std.mem.Allocator,
    store: *rows.Store,
    site: rows.SiteId,
    step: usize = 0,
    probes: usize = 0,
    refusals: usize = 0,
};

/// The generator's running identity counters, shared by every edit family.
const Fresh = struct {
    slot: u64 = 1,
    key: u64 = 1,
    scope: u64 = 1,
};

pub export fn zig_fuzz_init() void {}

pub export fn zig_fuzz_test(buf: [*]u8, len: isize) void {
    zig_fuzz_test_inner(buf, len, false);
}

/// Decodes and checks one bounded transition history.
pub fn zig_fuzz_test_inner(buf: [*]u8, len: isize, debug: bool) void {
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer if (gpa_impl.deinit() == .leak) @panic("Rows transition fuzz target leaked memory");
    const backing = gpa_impl.allocator();
    var fault = FaultAllocator.init(backing);
    const allocator = fault.allocator();

    checkLineageFork(allocator);
    checkSharedGenerationAtTwoSites(allocator);

    var reader = FuzzReader.init(buf[0..@intCast(len)]);
    var store = rows.Store.init(allocator);
    defer store.deinit();

    var owner_raw: u64 = 1;
    const site = store.createSite(OwnerToken.fromRaw(owner_raw) catch unreachable) catch @panic("Rows fuzz site allocation failed");
    var run = Run{ .backing = backing, .fault = &fault, .allocator = allocator, .store = &store, .site = site };

    var model: std.ArrayList(ModelRow) = .empty;
    defer model.deinit(backing);
    var fresh = Fresh{};

    const step_count = reader.intRangeAtMost(usize, 1, max_steps);
    for (0..step_count) |step| {
        run.step = step;
        var key_buffers: [max_edits_per_step][32]u8 = undefined;
        var edits: [max_edits_per_step]StableEdit = undefined;
        var edit_len: usize = 0;
        var candidate: std.ArrayList(ModelRow) = .empty;
        defer candidate.deinit(backing);
        candidate.appendSlice(backing, model.items) catch @panic("Rows fuzz model allocation failed");

        const parent = OwnerToken.fromRaw(owner_raw) catch unreachable;
        const child = OwnerToken.fromRaw(owner_raw + 1) catch unreachable;
        var transition = Transition{ .kind = .stable, .parent = parent, .next = child, .edits = &.{} };

        const shape = reader.readByte();
        if (candidate.items.len == 0 and (shape & 1) == 1) {
            // The site is empty, so the initial-snapshot path authenticates
            // against the site's own owner and keeps it.
            transition = .{ .kind = .initial, .parent = parent, .next = parent, .edits = &.{} };
            const count = reader.intRangeAtMost(usize, 1, max_edits_per_step);
            for (0..count) |_| generateInsert(&reader, &candidate, backing, &edits, &key_buffers, &edit_len, &fresh);
        } else if (shape % 8 == 7 and owner_raw > 1) {
            // A stale sibling: the delta from the previous owner must be
            // refused without publishing, then the site is rebuilt from its
            // real owner through the counted snapshot path.
            const stale = OwnerToken.fromRaw(owner_raw - 1) catch unreachable;
            if (rows.PreparedTransition.prepareStable(allocator, &store, site, stale, child, &.{})) |unexpected| {
                var prepared = unexpected;
                prepared.deinit();
                fail(&run, "stale parent", "a delta from a stale parent token was accepted", .{});
            } else |err| if (err != error.ParentMismatch) fail(&run, "stale parent", "a delta from a stale parent token was refused as {t}", .{err});
            checkState(&run, parent, model.items, "stale parent");
            if (debug) std.debug.print("step {d}: stale parent {d} refused\n", .{ step, owner_raw - 1 });

            edits[0] = .clear;
            edit_len = 1;
            candidate.clearRetainingCapacity();
            const count = reader.intRangeAtMost(usize, 1, max_edits_per_step - 1);
            for (0..count) |_| generateInsert(&reader, &candidate, backing, &edits, &key_buffers, &edit_len, &fresh);
        } else {
            const count = reader.intRangeAtMost(usize, 1, max_edits_per_step);
            for (0..count) |_| generateEdit(&reader, &candidate, backing, &edits, &key_buffers, &edit_len, &fresh);
        }
        transition.edits = edits[0..edit_len];
        if (debug) printStep(step, transition);

        const probe: Probe = switch (reader.readByte() % 3) {
            0 => .none,
            1 => .single,
            else => .sweep,
        };
        const sampled = 1 + reader.intRangeLessThan(usize, 0, max_sampled_fault_attempt);
        switch (probe) {
            .none => {},
            .single => _ = probeFault(&run, transition, sampled, candidate.items),
            .sweep => {
                var attempt: usize = 1;
                while (attempt <= max_fault_sweep_attempts) : (attempt += 1) {
                    if (!probeFault(&run, transition, attempt, candidate.items)) break;
                } else fail(&run, "sweep", "a {d}-edit batch was still refused with attempt {d} armed", .{ transition.edits.len, max_fault_sweep_attempts });
            },
        }

        var prepared = transition.prepare(allocator, &store, site) catch |err| fail(&run, "prepare", "{t}", .{err});
        if (reader.boolean()) {
            prepared.deinit();
            checkState(&run, parent, model.items, "abort");
            if (debug) std.debug.print("step {d}: aborted and retried\n", .{step});
            prepared = transition.prepare(allocator, &store, site) catch |err| fail(&run, "retry", "{t}", .{err});
        }
        checkCandidate(&run, &prepared, candidate.items, "candidate");

        // Commit is the irreversible boundary, so it may not reach the
        // allocator at all: arm the very next attempt and require none.
        fault.configure(1);
        prepared.commit();
        const commit_attempts = fault.attempts;
        fault.configure(null);
        if (commit_attempts != 0) fail(&run, "commit", "committing made {d} allocation attempt(s)", .{commit_attempts});
        prepared.deinit();

        if (transition.kind == .stable) owner_raw += 1;
        model.clearRetainingCapacity();
        model.appendSlice(backing, candidate.items) catch @panic("Rows fuzz model allocation failed");
        for (model.items) |*row| row.fresh = false;
        checkState(&run, transition.next, model.items, "commit");
    }

    if (debug) std.debug.print("fault probes: {d}, refused: {d}\n", .{ run.probes, run.refusals });
}

// ---------------------------------------------------------------------------
// Generation
// ---------------------------------------------------------------------------

/// Draws one insert against `candidate`, applies it to the model, and appends
/// it to the batch. A full site takes no insert.
fn generateInsert(reader: *FuzzReader, candidate: *std.ArrayList(ModelRow), backing: std.mem.Allocator, edits: *[max_edits_per_step]StableEdit, key_buffers: *[max_edits_per_step][32]u8, edit_len: *usize, fresh: *Fresh) void {
    if (candidate.items.len >= max_rows) return;
    const position = reader.intRangeAtMost(usize, 0, candidate.items.len);
    const before_slot = if (position == candidate.items.len) 0 else candidate.items[position].slot;
    const row = ModelRow{ .slot = fresh.slot, .key_id = fresh.key, .value = fresh.scope, .fresh = true };
    edits[edit_len.*] = .{ .insert = .{
        .slot = row.slot,
        .before_slot = before_slot,
        .key = formatKey(&key_buffers[edit_len.*], row.key_id),
        .metadata = .{ .item_slot = row.slot, .scope_id = row.value },
    } };
    candidate.insert(backing, position, row) catch @panic("Rows fuzz model allocation failed");
    fresh.slot += 1;
    fresh.key += 1;
    fresh.scope += 1;
    edit_len.* += 1;
}

/// Draws one canonical stable-slot edit against `candidate`, applies it to the
/// model, and appends it to the batch. An edit the current model cannot
/// express - a move of every row, a removal from an empty site - is skipped
/// rather than forced, so the batch stays a valid program.
fn generateEdit(reader: *FuzzReader, candidate: *std.ArrayList(ModelRow), backing: std.mem.Allocator, edits: *[max_edits_per_step]StableEdit, key_buffers: *[max_edits_per_step][32]u8, edit_len: *usize, fresh: *Fresh) void {
    const operation = if (candidate.items.len == 0) @as(u8, 0) else reader.readByte() % 5;
    switch (operation) {
        0 => generateInsert(reader, candidate, backing, edits, key_buffers, edit_len, fresh),
        1 => {
            const first = reader.intRangeLessThan(usize, 0, candidate.items.len);
            if (candidate.items[first].fresh) return;
            var removable: usize = 0;
            for (candidate.items[first..]) |row| {
                if (row.fresh) break;
                removable += 1;
            }
            const count = reader.intRangeAtMost(usize, 1, removable);
            edits[edit_len.*] = .{ .remove = .{ .first_slot = candidate.items[first].slot, .count = @intCast(count) } };
            candidate.replaceRange(backing, first, count, &.{}) catch unreachable;
            edit_len.* += 1;
        },
        2 => {
            if (candidate.items.len < 2) return;
            const first = reader.intRangeLessThan(usize, 0, candidate.items.len);
            const count = reader.intRangeAtMost(usize, 1, candidate.items.len - first);
            if (count == candidate.items.len) return;
            var moved: [max_rows]ModelRow = undefined;
            @memcpy(moved[0..count], candidate.items[first .. first + count]);
            candidate.replaceRange(backing, first, count, &.{}) catch unreachable;
            const destination = reader.intRangeAtMost(usize, 0, candidate.items.len);
            const before_slot = if (destination == candidate.items.len) 0 else candidate.items[destination].slot;
            edits[edit_len.*] = .{ .move = .{
                .first_slot = moved[0].slot,
                .count = @intCast(count),
                .before_slot = before_slot,
            } };
            candidate.insertSlice(backing, destination, moved[0..count]) catch @panic("Rows fuzz model allocation failed");
            edit_len.* += 1;
        },
        3 => {
            const index = reader.intRangeLessThan(usize, 0, candidate.items.len);
            const row = candidate.items[index];
            edits[edit_len.*] = .{ .update = .{
                .slot = row.slot,
                .key = formatKey(&key_buffers[edit_len.*], row.key_id),
                .metadata = .{ .item_slot = row.slot, .scope_id = row.value },
            } };
            edit_len.* += 1;
        },
        4 => {
            for (candidate.items) |row| if (row.fresh) return;
            edits[edit_len.*] = .clear;
            candidate.clearRetainingCapacity();
            edit_len.* += 1;
        },
        else => unreachable,
    }
}

// ---------------------------------------------------------------------------
// Allocation-failure probing
// ---------------------------------------------------------------------------

/// One committed row, copied so a probe can be held to leaving it alone.
const RowSnapshot = struct {
    id: RowId,
    key: []u8,
    previous: ?RowId,
    next: ?RowId,
    metadata: rows.RowMetadata,
};

/// One row-pool slot's state, minus the free-list link a released claim is
/// free to rewrite.
const PoolSlot = struct {
    tag: u8,
    generation: u32,
};

/// Everything a prepared transition may not change before it commits.
const Snapshot = struct {
    owner: OwnerToken,
    head: ?RowId,
    tail: ?RowId,
    len: usize,
    committed: []RowSnapshot,
    by_key: usize,
    by_item_slot: usize,
    by_scope: usize,
    by_handle: usize,
    reserved_scope: usize,
    reserved_handle: usize,
    free_count: usize,
    reserved_append: usize,
    reserved_free: usize,
    pool: []PoolSlot,
    render_len: usize,
    render_last_root: ?u64,

    fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        for (self.committed) |row| allocator.free(row.key);
        allocator.free(self.committed);
        allocator.free(self.pool);
    }
};

/// Prepares `transition` with the allocator failing from `attempt` onwards,
/// aborts whatever it produced, and asserts nothing was published.
///
/// Returns whether the preparation refused.
fn probeFault(run: *Run, transition: Transition, attempt: usize, candidate: []const ModelRow) bool {
    run.probes += 1;
    var before = snapshot(run);
    defer before.deinit(run.backing);

    run.fault.configure(attempt);
    const result = transition.prepare(run.allocator, run.store, run.site);
    run.fault.configure(null);

    var refused = false;
    if (result) |ok| {
        var prepared = ok;
        checkCandidate(run, &prepared, candidate, "probe candidate");
        prepared.deinit();
    } else |err| {
        // `OutOfMemory` is the only honest answer to an injected allocation
        // failure. `ResourceLimit` would mean a bound rejected a batch the
        // generator built well inside every limit, and any validation error
        // that a refusal path misreported what happened.
        if (err != error.OutOfMemory) fail(run, "probe", "preparation faulted at attempt {d} refused as {t}, not an allocation failure", .{ attempt, err });
        refused = true;
        run.refusals += 1;
    }

    expectUnpublished(run, &before, attempt, refused);
    return refused;
}

/// Copies the committed site, the store's indexes and reservations, and the
/// row pool's slot states.
fn snapshot(run: *Run) Snapshot {
    const store = run.store;
    const site = store.getSiteConst(run.site) catch fail(run, "snapshot", "the site is no longer live", .{});
    const committed = run.backing.alloc(RowSnapshot, site.len) catch @panic("Rows fuzz snapshot allocation failed");
    var current = site.head;
    var index: usize = 0;
    while (current) |row_id| : (index += 1) {
        if (index >= committed.len) fail(run, "snapshot", "the committed order is longer than the site length {d}", .{site.len});
        const row = store.getRowConst(run.site, row_id) catch fail(run, "snapshot", "the committed order references a stale row", .{});
        committed[index] = .{
            .id = row_id,
            .key = run.backing.dupe(u8, row.key) catch @panic("Rows fuzz snapshot allocation failed"),
            .previous = row.previous,
            .next = row.next,
            .metadata = row.metadata,
        };
        current = row.next;
    }
    if (index != committed.len) fail(run, "snapshot", "the committed order holds {d} rows against a site length of {d}", .{ index, committed.len });

    const pool = run.backing.alloc(PoolSlot, store.rows.slots.items.len) catch @panic("Rows fuzz snapshot allocation failed");
    for (store.rows.slots.items, pool) |slot, *out| out.* = .{ .tag = @intFromEnum(std.meta.activeTag(slot.state)), .generation = slot.generation };

    return .{
        .owner = site.owner_token,
        .head = site.head,
        .tail = site.tail,
        .len = site.len,
        .committed = committed,
        .by_key = site.by_key.count(),
        .by_item_slot = site.by_item_slot.count(),
        .by_scope = store.by_scope_id.count(),
        .by_handle = store.by_row_handle.count(),
        .reserved_scope = store.reserved_scope_entries,
        .reserved_handle = store.reserved_handle_entries,
        .free_count = store.rows.free_count,
        .reserved_append = store.rows.reserved_append,
        .reserved_free = store.rows.reserved_free.count(),
        .pool = pool,
        .render_len = site.render_order.len(),
        .render_last_root = site.render_order.lastRoot(),
    };
}

/// Asserts a probed preparation published nothing and released every claim.
///
/// This is the atomicity property: the caller's only recovery from
/// `OutOfMemory` is to present the same batch again, so anything a refusal
/// leaves behind - a relinked row, a rewritten key, an index entry, an
/// outstanding claim - survives the retry as corruption instead of failing as
/// a transition.
fn expectUnpublished(run: *Run, before: *const Snapshot, attempt: usize, refused: bool) void {
    var after = snapshot(run);
    defer after.deinit(run.backing);
    const what: []const u8 = if (refused) "refused" else "abandoned";

    if (after.owner != before.owner or after.head != before.head or after.tail != before.tail or after.len != before.len) {
        fail(run, "probe", "a preparation {s} at attempt {d} changed the site header", .{ what, attempt });
    }
    for (before.committed, after.committed, 0..) |expected, actual, index| {
        if (actual.id != expected.id or actual.previous != expected.previous or actual.next != expected.next) {
            fail(run, "probe", "a preparation {s} at attempt {d} relinked committed row {d}", .{ what, attempt, index });
        }
        if (!std.mem.eql(u8, actual.key, expected.key)) fail(run, "probe", "a preparation {s} at attempt {d} rewrote the key of committed row {d}", .{ what, attempt, index });
        if (!std.meta.eql(actual.metadata, expected.metadata)) fail(run, "probe", "a preparation {s} at attempt {d} rewrote the metadata of committed row {d}", .{ what, attempt, index });
    }
    if (after.by_key != before.by_key or after.by_item_slot != before.by_item_slot or after.by_scope != before.by_scope or after.by_handle != before.by_handle) {
        fail(run, "probe", "a preparation {s} at attempt {d} changed an index's population", .{ what, attempt });
    }
    if (after.reserved_scope != before.reserved_scope or after.reserved_handle != before.reserved_handle or after.reserved_append != before.reserved_append or after.reserved_free != before.reserved_free) {
        fail(run, "probe", "a preparation {s} at attempt {d} left claims outstanding: scope {d}->{d}, handle {d}->{d}, append {d}->{d}, free {d}->{d}", .{
            what,                   attempt,
            before.reserved_scope,  after.reserved_scope,
            before.reserved_handle, after.reserved_handle,
            before.reserved_append, after.reserved_append,
            before.reserved_free,   after.reserved_free,
        });
    }
    if (after.free_count != before.free_count or after.pool.len != before.pool.len) {
        fail(run, "probe", "a preparation {s} at attempt {d} changed the row pool from {d} slots ({d} free) to {d} ({d} free)", .{ what, attempt, before.pool.len, before.free_count, after.pool.len, after.free_count });
    }
    for (before.pool, after.pool, 0..) |expected, actual, index| {
        if (actual.tag != expected.tag or actual.generation != expected.generation) {
            fail(run, "probe", "a preparation {s} at attempt {d} changed row pool slot {d}", .{ what, attempt, index });
        }
    }
    if (after.render_len != before.render_len or after.render_last_root != before.render_last_root) {
        fail(run, "probe", "a preparation {s} at attempt {d} changed the render-order index", .{ what, attempt });
    }
}

// ---------------------------------------------------------------------------
// Fixed lineage fixtures
// ---------------------------------------------------------------------------

/// Exercises the runtime's required direct-delta, stale-sibling snapshot, then
/// resumed-delta lineage shape with concrete generation owners.
fn checkLineageFork(allocator: std.mem.Allocator) void {
    var store = rows.Store.init(allocator);
    defer store.deinit();
    const first = OwnerToken.fromRaw(100) catch unreachable;
    const direct = OwnerToken.fromRaw(101) catch unreachable;
    const sibling = OwnerToken.fromRaw(102) catch unreachable;
    const resumed = OwnerToken.fromRaw(103) catch unreachable;
    const site = store.createSite(first) catch @panic("Rows lineage fixture allocation failed");
    var run = Run{ .backing = allocator, .fault = undefined, .allocator = allocator, .store = &store, .site = site };

    var initial = rows.PreparedTransition.prepareStable(allocator, &store, site, first, direct, &.{
        .{ .insert = .{ .slot = 1, .before_slot = 0, .key = "direct", .metadata = .{ .item_slot = 1, .scope_id = 1 } } },
    }) catch |err| fail(&run, "lineage direct delta", "{t}", .{err});
    initial.commit();
    initial.deinit();

    if (rows.PreparedTransition.prepareStable(allocator, &store, site, first, sibling, &.{})) |unexpected| {
        var prepared = unexpected;
        prepared.deinit();
        fail(&run, "lineage stale sibling", "a stale sibling delta was accepted", .{});
    } else |err| if (err != error.ParentMismatch) fail(&run, "lineage stale sibling", "{t}", .{err});

    // A stale sibling is applied through the counted full-snapshot path. At the
    // transition seam that is represented by an authenticated clear/rebuild
    // from the currently committed owner; it must publish the sibling owner.
    var rebuilt = rows.PreparedTransition.prepareStable(allocator, &store, site, direct, sibling, &.{
        .clear,
        .{ .insert = .{ .slot = 2, .before_slot = 0, .key = "sibling", .metadata = .{ .item_slot = 2, .scope_id = 2 } } },
    }) catch |err| fail(&run, "lineage sibling snapshot", "{t}", .{err});
    rebuilt.commit();
    rebuilt.deinit();

    var next = rows.PreparedTransition.prepareStable(allocator, &store, site, sibling, resumed, &.{
        .{ .update = .{ .slot = 2, .key = "sibling", .metadata = .{ .item_slot = 2, .scope_id = 2 } } },
    }) catch |err| fail(&run, "lineage resumed delta", "{t}", .{err});
    next.commit();
    next.deinit();
    const malformed_owner = OwnerToken.fromRaw(104) catch unreachable;
    if (rows.PreparedTransition.prepareStable(allocator, &store, site, resumed, malformed_owner, &.{
        .{ .update = .{ .slot = 2, .key = "changed-identity", .metadata = .{ .item_slot = 2, .scope_id = 4 } } },
    })) |unexpected| {
        var prepared = unexpected;
        prepared.deinit();
        fail(&run, "lineage malformed rekey", "a rekeying update was accepted", .{});
    } else |err| if (err != error.KeyMismatch) fail(&run, "lineage malformed rekey", "{t}", .{err});
    checkState(&run, resumed, &.{.{ .slot = 2, .key_id = 0, .value = 2 }}, "lineage final");
}

/// The same immutable Rows owner may feed multiple construction sites. Their
/// host identities and row storage must remain site-local.
fn checkSharedGenerationAtTwoSites(allocator: std.mem.Allocator) void {
    var store = rows.Store.init(allocator);
    defer store.deinit();
    const shared = OwnerToken.fromRaw(200) catch unreachable;
    const first_owner = OwnerToken.fromRaw(201) catch unreachable;
    const second_owner = OwnerToken.fromRaw(202) catch unreachable;
    const first_site = store.createSite(shared) catch @panic("Rows shared-generation fixture allocation failed");
    const second_site = store.createSite(shared) catch @panic("Rows shared-generation fixture allocation failed");
    var run = Run{ .backing = allocator, .fault = undefined, .allocator = allocator, .store = &store, .site = first_site };
    const first_edit = StableEdit{ .insert = .{ .slot = 7, .before_slot = 0, .key = "shared", .metadata = .{ .item_slot = 7, .scope_id = 9 } } };
    const second_edit = StableEdit{ .insert = .{ .slot = 7, .before_slot = 0, .key = "shared", .metadata = .{ .item_slot = 7, .scope_id = 10 } } };
    var first = rows.PreparedTransition.prepareStable(allocator, &store, first_site, shared, first_owner, &.{first_edit}) catch |err| fail(&run, "shared first site", "{t}", .{err});
    first.commit();
    first.deinit();
    var second = rows.PreparedTransition.prepareStable(allocator, &store, second_site, shared, second_owner, &.{second_edit}) catch |err| fail(&run, "shared second site", "{t}", .{err});
    second.commit();
    second.deinit();
    const first_row = (store.findItemSlot(first_site, 7) catch fail(&run, "shared first lookup", "invalid site", .{})) orelse fail(&run, "shared first lookup", "slot 7 is missing", .{});
    const second_row = (store.findItemSlot(second_site, 7) catch fail(&run, "shared second lookup", "invalid site", .{})) orelse fail(&run, "shared second lookup", "slot 7 is missing", .{});
    if (first_row == second_row) fail(&run, "shared site identity", "two sites share one row identity", .{});
}

// ---------------------------------------------------------------------------
// Oracles
// ---------------------------------------------------------------------------

fn formatKey(buffer: []u8, key_id: u64) []const u8 {
    return std.fmt.bufPrint(buffer, "key-{d}", .{key_id}) catch unreachable;
}

/// Asserts the committed site is exactly `expected`, owned by `owner`, and
/// that both site indexes resolve every row.
fn checkState(run: *Run, owner: OwnerToken, expected: []const ModelRow, phase: []const u8) void {
    const store = run.store;
    const actual_site = store.getSiteConst(run.site) catch fail(run, phase, "the site is no longer live", .{});
    if (actual_site.owner_token != owner) fail(run, phase, "the site is owned by {d}, model expects {d}", .{ actual_site.owner_token.raw(), owner.raw() });
    if (actual_site.len != expected.len) fail(run, phase, "the site holds {d} rows, model expects {d}", .{ actual_site.len, expected.len });
    var current = actual_site.head;
    for (expected, 0..) |model_row, index| {
        const row_id = current orelse fail(run, phase, "the committed order ends before row {d}", .{index});
        const actual = store.getRowConst(run.site, row_id) catch fail(run, phase, "committed row {d} is stale", .{index});
        var key_buffer: [32]u8 = undefined;
        const expected_key = if (model_row.key_id == 0) "sibling" else formatKey(&key_buffer, model_row.key_id);
        if (!std.mem.eql(u8, actual.key, expected_key)) fail(run, phase, "committed row {d} has key {s}, model expects {s}", .{ index, actual.key, expected_key });
        if (actual.metadata.item_slot != model_row.slot or actual.metadata.scope_id != model_row.value) fail(run, phase, "committed row {d} carries slot {d} scope {d}, model expects slot {d} scope {d}", .{ index, actual.metadata.item_slot, actual.metadata.scope_id, model_row.slot, model_row.value });
        if ((store.findItemSlot(run.site, model_row.slot) catch fail(run, phase, "the site is no longer live", .{})) != row_id) fail(run, phase, "slot {d} does not resolve to committed row {d}", .{ model_row.slot, index });
        if ((store.findKey(run.site, expected_key) catch fail(run, phase, "the site is no longer live", .{})) != row_id) fail(run, phase, "key {s} does not resolve to committed row {d}", .{ expected_key, index });
        current = actual.next;
    }
    if (current != null) fail(run, phase, "the committed order continues past the model's {d} rows", .{expected.len});
}

/// Asserts a prepared transition's candidate view already describes the
/// model's next state, in order.
fn checkCandidate(run: *Run, prepared: *const rows.PreparedTransition, expected: []const ModelRow, phase: []const u8) void {
    if (prepared.candidateLen() != expected.len) fail(run, phase, "the candidate holds {d} rows, model expects {d}", .{ prepared.candidateLen(), expected.len });
    var iterator = prepared.iterateCandidate();
    for (expected, 0..) |model_row, index| {
        const candidate = iterator.next() orelse fail(run, phase, "the candidate order ends before row {d}", .{index});
        var key_buffer: [32]u8 = undefined;
        const expected_key = formatKey(&key_buffer, model_row.key_id);
        if (!std.mem.eql(u8, candidate.key, expected_key)) fail(run, phase, "candidate row {d} has key {s}, model expects {s}", .{ index, candidate.key, expected_key });
        if (candidate.metadata.item_slot != model_row.slot or candidate.metadata.scope_id != model_row.value) fail(run, phase, "candidate row {d} carries slot {d} scope {d}, model expects slot {d} scope {d}", .{ index, candidate.metadata.item_slot, candidate.metadata.scope_id, model_row.slot, model_row.value });
    }
    if (iterator.next() != null) fail(run, phase, "the candidate order continues past the model's {d} rows", .{expected.len});
}

fn printStep(step: usize, transition: Transition) void {
    std.debug.print("step {d}: {t} {d}->{d}:", .{ step, transition.kind, transition.parent.raw(), transition.next.raw() });
    for (transition.edits) |edit| switch (edit) {
        .insert => |value| std.debug.print(" insert(slot {d} before {d} key {s})", .{ value.slot, value.before_slot, value.key }),
        .remove => |value| std.debug.print(" remove(slot {d} x{d})", .{ value.first_slot, value.count }),
        .move => |value| std.debug.print(" move(slot {d} x{d} before {d})", .{ value.first_slot, value.count, value.before_slot }),
        .update => |value| std.debug.print(" update(slot {d})", .{value.slot}),
        .clear => std.debug.print(" clear", .{}),
    };
    std.debug.print("\n", .{});
}

fn fail(run: *const Run, phase: []const u8, comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("Rows transition fuzz oracle failed (step {d}, {s}): " ++ fmt ++ "\n", .{ run.step, phase } ++ args);
    @panic("Rows transition fuzz oracle failed");
}
