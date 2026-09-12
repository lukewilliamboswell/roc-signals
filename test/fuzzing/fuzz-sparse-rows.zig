//! Two-world differential fuzzing for the sparse `Rows` paths.
//!
//! # Why this target exists
//!
//! PR #120 made engine work local to the changed set: a `Rows` value whose
//! description names the site's committed generation as its parent is applied
//! as a *direct delta* - the transition journals its inserted, removed, moved,
//! and updated rows, the site's key index and membership table are patched
//! only for created and removed rows, structural positions and render order
//! are spliced per edit, and the untouched remainder of the site is never
//! visited. Anything else - an explicit snapshot generation, a delta from a
//! stale sibling generation, a rollback to an earlier generation, a site
//! instantiated by a `when` flip - falls back to the counted snapshot path,
//! which re-collects the whole list by key.
//!
//! Those are two implementations of one contract, and the bug class they
//! share is a *sequence* one: a scope id reused across a retirement, a
//! membership left pointing at a swapped-out row, a slot reused after a
//! rollback, a fallback landing on a site whose previous edit was direct.
//! Hand-written specs cover single shapes; this target generates the history
//! and checks the two paths against a pure model and against each other.
//!
//! # What is generated
//!
//! A program is a root state cell holding a **slot table** - an `i64` list
//! whose element `slot - 1` is the item stable slot `slot` names, exactly as
//! the platform's `Rows` hands the engine's `clone_item` and `compare_slots`
//! adapters - wrapping a second cell holding the *selected* key, wrapping a
//! `div` of static text, `each` sites over the slot table, wrapper elements,
//! and `when`s whose condition is a predicate over the slot table. Every site
//! reads the same cell, so one dispatch re-diffs all of them; there are at
//! most `max_shared_sites`. A site's rows render plain text, a state cell, a
//! `when` on a list predicate, a `when` on `Signal.select(selected, key)`, or
//! a nested constant `each` sized by the row key.
//!
//! The rest of the program is an edit history. Each edit is a batch of
//! stable-slot operations - insert, remove range, move range, update, clear -
//! applied to a model of the current order, plus a *description*: **direct**
//! (a delta whose parent is the committed generation), **snapshot** (a fresh
//! generation described as a snapshot), **stale** (a delta whose parent is
//! an earlier generation, which the engine must refuse to trust and
//! reconcile as a snapshot), **rollback** (an earlier generation republished
//! as a snapshot, so its generation id and retired slots come back), or a
//! **select** edit that changes the selected key without touching the list.
//! Inserted rows always take a fresh slot of the current table; after a
//! rollback the table is shorter, so slots retired by later generations are
//! reused for new keys.
//!
//! # Reference model and the two worlds
//!
//! The model is the ordered row list `(slot, key, item)` per generation and
//! the slot table, from which the document's text nodes, the live sites, the
//! branch each `when` shows, and the row/state/site counts are derived.
//!
//! **World A** mounts the program and applies every edit as described, so
//! direct edits take the sparse path. **World B** mounts the same program and
//! applies the same edits every one described as a snapshot. Each world is
//! checked against the model after every edit, and the observation World A
//! recorded for an edit is compared with World B's for the same edit.
//!
//! # Oracles
//!
//!  - **Published topology and document order match the model** in both
//!    worlds: site, row, state, and when counts, every modelled label present,
//!    every hidden label absent, the render tree read in document order with
//!    consistent sibling links, no parent holding a child twice, and every
//!    scope site's insertion index current.
//!  - **Row site tables agree with the model and with each other.** Every
//!    shared site's committed `Rows` store order is exactly the model's
//!    `(slot, key)` sequence; its dense site table holds exactly the store's
//!    row scopes; every membership entry names the site and index that hold
//!    it; every row's stable slot resolves back to its row.
//!  - **Identity is preserved.** Within a world, a key that survives an edit
//!    keeps its scope id, row handle, and slot; a created row's scope id was
//!    not live in that site before the edit; a removed row's scope is retired
//!    from the store and its membership cleared.
//!  - **The worlds agree.** After each edit the two worlds report the same
//!    document text, site/row/state/scope/DOM/selector counts, and the same
//!    `rows_created`, `rows_removed`, `rows_reused`, `scopes_created`, and
//!    `scopes_disposed` deltas.
//!  - **Work is local to the edit.** On a direct edit World A's
//!    `rows_candidate_rows_visited` grows by exactly `(created + updated)`
//!    per surviving shared site - which also proves the direct path was
//!    taken - and `rows_membership_entries_rewritten` by between
//!    `removed + created` and `2 * removed + created` per site (a swap
//!    removal rewrites at most one survivor). On every other edit, and in
//!    World B always, both counters stay still. On an edit that flips no
//!    `when`, `selector_registry_visits` grows by exactly the graph records
//!    the created rows append plus one per removed selector row, in both
//!    worlds.
//!  - **A refused edit changes nothing**, refusals are `OutOfMemory` only,
//!    the same host retries successfully, closure retains balance, the Roc
//!    allocation ledger is back where it started, and nothing leaks at
//!    teardown.
//!
//! # Fault placement
//!
//! Every input first runs both worlds unfaulted, recording the mount's and
//! each World A edit's allocation-attempt count. Each count is then swept as
//! `structural` does: exhaustively when small, otherwise at one position the
//! input chooses. A swept edit re-mounts and replays the earlier edits first,
//! so the fault lands on a direct delta whose starting state is the committed
//! topology the model predicts.
//!
//! # Not yet covered
//!
//!  - `rows_index_keys_hashed` has no bump site in the engine, so it is not
//!    asserted; a bound on it would be vacuous.
//!  - Selector visit bounds are skipped on edits that flip a `when`, because
//!    the records a disposed or instantiated branch releases and appends are
//!    not modelled here.
//!  - Nested each rows are constant; a nested site reading the shared cell
//!    would multiply row counts rather than add a path.
//!
//! To replay a crash:
//!   python3 scripts/fuzz.py repro sparse-rows <crash-file> --verbose

const std = @import("std");
const signals = @import("signals");
const native_host = @import("native_host");
const FuzzReader = @import("FuzzReader.zig");

const fixtures = native_host.fuzz_fixtures;
const abi = signals.abi;
const ids = signals.ids;
const HostValue = signals.host_values.HostValue;
const FaultAllocator = signals.fault_allocator.FaultAllocator;
const Host = fixtures.Host;
const ValueCapability = fixtures.ValueCapability;
const BinderToken = fixtures.BinderToken;

const max_children = 8;
const max_shared_sites = 3;
/// Live rows one site may hold. Small enough for the whole fault sweep, large
/// enough that a restored whole-site scan exceeds every per-edit bound.
const max_rows = 10;
/// Stable slots the table may grow to across the whole history.
const max_slots = 32;
const max_edits = 6;
const max_ops = 3;
const max_inner_rows = 3;
const key_stride: i64 = 4;
const max_full_sweep_attempts = 40;
const separator_text = "separator";
const hidden_text = "hidden";

const RowKind = enum(u8) {
    text,
    stateful,
    when_list,
    when_selected,
    nested_each,
};

/// Graph records a created row of each kind appends, which is what
/// `selector_registry_visits` counts at commit. Measured against the engine;
/// a change here is a change in what a row costs, not a bug in the target.
fn graphRecordsPerCreatedRow(kind: RowKind) u64 {
    return switch (kind) {
        .text, .stateful => 0,
        .nested_each => 1,
        .when_list => 2,
        .when_selected => 2,
    };
}

/// Selector memberships a removed row of each kind releases.
fn selectorsPerRemovedRow(kind: RowKind) u64 {
    return switch (kind) {
        .when_selected => 1,
        else => 0,
    };
}

const WhenCondition = struct {
    predicate: fixtures.ListPredicate,
    operand: i64,

    fn holds(self: WhenCondition, state: State) bool {
        var buffer: [max_slots + 1]i64 = undefined;
        return self.predicate.holds(cellView(state, &buffer), self.operand);
    }
};

/// The value the list cell holds for `state`: the slot table followed by the
/// generation id. The sentinel is what makes a remove, move, or clear - which
/// leave every slot's item in place - a new value, as a fresh `Rows`
/// generation is on the platform; without it the cell's equality cutoff would
/// skip the sites entirely.
fn cellView(state: State, buffer: *[max_slots + 1]i64) []const i64 {
    @memcpy(buffer[0..state.slots.len], state.slots);
    buffer[state.slots.len] = @intCast(state.generation);
    return buffer[0 .. state.slots.len + 1];
}

const InnerSpec = struct {
    id: u16,
    row_count: u8,
};

const SiteSpec = struct {
    id: u16,
    row_kind: RowKind,
    condition: WhenCondition,
    inner: ?*const InnerSpec,
};

const Branch = union(enum) {
    empty,
    children: []const Child,
};

const WhenSpec = struct {
    condition: WhenCondition,
    when_true: Branch,
    when_false: Branch,

    fn selected(self: *const WhenSpec, state: State) Branch {
        return if (self.condition.holds(state)) self.when_true else self.when_false;
    }
};

const Child = union(enum) {
    text,
    site: *const SiteSpec,
    wrapper: []const Child,
    when: *const WhenSpec,
};

const ModelRow = struct {
    slot: u64,
    key: u64,
    item: i64,
};

const Op = union(enum) {
    insert: struct { slot: u64, before_slot: u64, key: u64 },
    remove: struct { first_slot: u64, count: u64 },
    move: struct { first_slot: u64, count: u64, before_slot: u64 },
    update: struct { slot: u64, key: u64 },
    clear,
};

const EditKind = enum(u8) {
    direct,
    snapshot,
    stale,
    rollback,
    select,
};

/// The committed model after the mount or one edit.
const State = struct {
    rows: []const ModelRow,
    slots: []const i64,
    generation: u64,
    selected: u64,
};

const Edit = struct {
    kind: EditKind,
    ops: []const Op,
    /// Generation the description announces.
    generation: u64,
    /// Parent generation the description announces; zero for a snapshot.
    parent: u64,
    result: State,
    /// Rows the batch creates, updates in place while surviving, and removes,
    /// per site.
    created: u64,
    updated: u64,
    removed: u64,
};

const Program = struct {
    children: []const Child,
    initial: State,
    edits: []const Edit,
    sites: []const *const SiteSpec,
    inners: []const *const InnerSpec,
};

/// Everything a generated row or Rows adapter needs to reach back into the
/// running host: the tokens of the two state cells and the description the
/// next dispatch must announce. `run` owns one per host.
const Runtime = struct {
    list_token: BinderToken,
    list_cap: ValueCapability,
    selected_token: BinderToken,
    selected_cap: ValueCapability,
    /// Rows the next description copies as a snapshot, in order.
    rows: []const ModelRow = &.{},
    ops: []const Op = &.{},
    generation: u64 = 0,
    parent: u64 = 0,
};

const RowCapture = extern struct {
    spec: *const SiteSpec,
    runtime: *const Runtime,
};

const InnerCapture = extern struct {
    spec: *const InnerSpec,
};

// -- Model ------------------------------------------------------------------

const Expected = struct {
    sites: usize = 0,
    whens: usize = 0,
    rows: usize = 0,
    /// The list cell and the selected cell always exist.
    states: usize = 2,
    /// Shared sites the current branch selection shows.
    shared_live: usize = 0,
    /// Empty-branch eaches the current branch selection shows.
    empty_live: usize = 0,

    fn of(program: Program, state: State) Expected {
        var expected = Expected{};
        expected.addChildren(program.children, state);
        return expected;
    }

    fn addChildren(self: *Expected, children: []const Child, state: State) void {
        for (children) |child| switch (child) {
            .text => {},
            .site => |spec| self.addSite(spec, state),
            .wrapper => |nested| self.addChildren(nested, state),
            .when => |when| {
                self.whens += 1;
                switch (when.selected(state)) {
                    .empty => {
                        self.sites += 1;
                        self.empty_live += 1;
                    },
                    .children => |nested| self.addChildren(nested, state),
                }
            },
        };
    }

    fn addSite(self: *Expected, spec: *const SiteSpec, state: State) void {
        self.sites += 1;
        self.shared_live += 1;
        for (state.rows) |row| {
            self.rows += 1;
            switch (spec.row_kind) {
                .text => {},
                .stateful => self.states += 1,
                .when_list, .when_selected => self.whens += 1,
                .nested_each => {
                    self.sites += 1;
                    self.rows += innerRowCount(spec.inner.?, row.key);
                },
            }
        }
    }
};

/// Rows the constant inner site renders under an outer row with `key`: its
/// own count plus one when the key is odd, so re-inserted and rolled-back
/// keys carry nested rows of a shape the model can predict.
fn innerRowCount(inner: *const InnerSpec, key: u64) usize {
    return @min(inner.row_count + @as(usize, @intCast(key % 2)), max_inner_rows);
}

fn modelTexts(out: *std.ArrayListUnmanaged([]const u8), arena: std.mem.Allocator, children: []const Child, state: State) error{OutOfMemory}!void {
    for (children) |child| switch (child) {
        .text => try out.append(arena, separator_text),
        .site => |spec| try modelSiteTexts(out, arena, spec, state),
        .wrapper => |nested| try modelTexts(out, arena, nested, state),
        .when => |when| switch (when.selected(state)) {
            .empty => {},
            .children => |nested| try modelTexts(out, arena, nested, state),
        },
    };
}

fn modelSiteTexts(out: *std.ArrayListUnmanaged([]const u8), arena: std.mem.Allocator, spec: *const SiteSpec, state: State) error{OutOfMemory}!void {
    for (state.rows) |row| {
        const label = try ownedLabel(arena, spec.id, row.key);
        switch (spec.row_kind) {
            .text, .stateful => try out.append(arena, label),
            .when_list => try out.append(arena, if (spec.condition.holds(state)) label else hidden_text),
            .when_selected => try out.append(arena, if (state.selected == row.key) label else hidden_text),
            .nested_each => {
                try out.append(arena, label);
                const inner = spec.inner.?;
                for (0..innerRowCount(inner, row.key)) |index| try out.append(arena, try ownedLabel(arena, inner.id + inner_label_base, index));
            },
        }
    }
}

/// Shared sites live under a branch selection that did not change across
/// the edit, so they take whichever path the description selects; a site in
/// a branch that flipped in is a fresh mount and goes through the snapshot
/// path whatever the description said.
fn survivingSharedSites(children: []const Child, before: State, after: State) usize {
    var count: usize = 0;
    for (children) |child| switch (child) {
        .text => {},
        .site => count += 1,
        .wrapper => |nested| count += survivingSharedSites(nested, before, after),
        .when => |when| {
            const was = when.condition.holds(before);
            const now = when.condition.holds(after);
            if (was != now) continue;
            switch (when.selected(after)) {
                .empty => {},
                .children => |nested| count += survivingSharedSites(nested, before, after),
            }
        },
    };
    return count;
}

/// Whether any structural signal other than the sites' items changes across
/// the edit: a top-level `when`, or the `when` inside a live row of a
/// `when_list` site.
fn anyFlip(program: Program, before: State, after: State) bool {
    if (anyWhenFlipped(program.children, before, after)) return true;
    if (before.rows.len == 0) return false;
    for (program.sites) |spec| {
        if (spec.row_kind == .when_list and spec.condition.holds(before) != spec.condition.holds(after)) return true;
    }
    return false;
}

fn anyWhenFlipped(children: []const Child, before: State, after: State) bool {
    for (children) |child| switch (child) {
        .text, .site => {},
        .wrapper => |nested| if (anyWhenFlipped(nested, before, after)) return true,
        .when => |when| {
            if (when.condition.holds(before) != when.condition.holds(after)) return true;
            switch (when.selected(after)) {
                .empty => {},
                .children => |nested| if (anyWhenFlipped(nested, before, after)) return true,
            }
        },
    };
    return false;
}

/// Graph records the live shared sites' created rows append and selector
/// memberships their removed rows release across one edit with no flip.
fn expectedSelectorVisits(children: []const Child, edit: Edit, before: State) u64 {
    var total: u64 = 0;
    for (children) |child| switch (child) {
        .text => {},
        .site => |spec| total += edit.created * graphRecordsPerCreatedRow(spec.row_kind) + edit.removed * selectorsPerRemovedRow(spec.row_kind),
        .wrapper => |nested| total += expectedSelectorVisits(nested, edit, before),
        .when => |when| switch (when.selected(before)) {
            .empty => {},
            .children => |nested| total += expectedSelectorVisits(nested, edit, before),
        },
    };
    return total;
}

// -- Entry ------------------------------------------------------------------

/// AFL++ persistent-mode initialization hook.
pub export fn zig_fuzz_init() void {}

/// AFL++ persistent-mode entry point.
pub export fn zig_fuzz_test(buf: [*]u8, len: isize) void {
    zig_fuzz_test_inner(buf, len, false);
}

/// Runs one fuzz input.
pub fn zig_fuzz_test_inner(buf: [*]u8, len: isize, debug: bool) void {
    var reader = FuzzReader.init(buf[0..@intCast(len)]);

    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const program = generate(&reader, arena) catch fail("program arena exhausted", .{});
    if (debug) printProgram(program);

    const edit_attempts = arena.alloc(usize, program.edits.len) catch fail("program arena exhausted", .{});
    @memset(edit_attempts, 0);
    const observations = arena.alloc(Observation, program.edits.len) catch fail("program arena exhausted", .{});

    phase = "world A";
    const mount_attempts = run(program, arena, .{ .edit_attempts = edit_attempts, .record = observations });
    phase = "world B";
    _ = run(program, arena, .{ .snapshot_only = true, .compare = observations });
    if (debug) {
        std.debug.print("mount attempts: {d}\n", .{mount_attempts});
        for (edit_attempts, 0..) |attempts, index| std.debug.print("edit {d} attempts: {d}\n", .{ index, attempts });
    }

    if (mount_attempts != 0) {
        if (chooseFullSweep(&reader, mount_attempts)) {
            if (debug) std.debug.print("sweeping every mount attempt\n", .{});
            for (1..mount_attempts + 1) |number| _ = run(program, arena, .{ .mount_failure = number });
        } else {
            const number = 1 + reader.intRangeAtMost(usize, 0, mount_attempts - 1);
            if (debug) std.debug.print("injecting mount failure at attempt {d}\n", .{number});
            _ = run(program, arena, .{ .mount_failure = number });
        }
    }

    for (edit_attempts, 0..) |attempts, edit_index| {
        if (attempts == 0) continue;
        if (chooseFullSweep(&reader, attempts)) {
            if (debug) std.debug.print("sweeping every attempt of edit {d}\n", .{edit_index});
            for (1..attempts + 1) |number| _ = run(program, arena, .{ .faulted_edit = edit_index, .edit_failure = number });
        } else {
            const number = 1 + reader.intRangeAtMost(usize, 0, attempts - 1);
            if (debug) std.debug.print("injecting edit {d} failure at attempt {d}\n", .{ edit_index, number });
            _ = run(program, arena, .{ .faulted_edit = edit_index, .edit_failure = number });
        }
    }
}

fn chooseFullSweep(reader: *FuzzReader, attempts: usize) bool {
    return attempts <= max_full_sweep_attempts and reader.boolean();
}

// -- Generator --------------------------------------------------------------

const Generator = struct {
    reader: *FuzzReader,
    arena: std.mem.Allocator,
    shared_budget: usize = max_shared_sites,
    sites: std.ArrayListUnmanaged(*const SiteSpec) = .empty,
    inners: std.ArrayListUnmanaged(*const InnerSpec) = .empty,
};

fn generate(reader: *FuzzReader, arena: std.mem.Allocator) !Program {
    var generator = Generator{ .reader = reader, .arena = arena };
    const children = try generateChildren(&generator, 0);
    if (generator.sites.items.len == 0) {
        // A program with no shared site edits nothing observable; give it one.
        const with_site = try arena.alloc(Child, children.len + 1);
        @memcpy(with_site[0..children.len], children);
        with_site[children.len] = .{ .site = try generateSite(&generator) };
        return generateHistory(&generator, with_site);
    }
    return generateHistory(&generator, children);
}

fn generateChildren(generator: *Generator, wrapper_depth: u8) error{OutOfMemory}![]const Child {
    const reader = generator.reader;
    const limit: u8 = if (wrapper_depth == 0) max_children else 3;
    const count = reader.intRangeAtMost(u8, 0, limit);
    const children = try generator.arena.alloc(Child, count);
    for (children) |*child| {
        const choice = reader.intRangeAtMost(u8, 0, 4);
        child.* = if (choice == 0)
            .text
        else if (choice == 1 and wrapper_depth == 0)
            .{ .wrapper = try generateChildren(generator, 1) }
        else if (choice == 2 and wrapper_depth == 0)
            .{ .when = try generateWhen(generator) }
        else if (generator.shared_budget != 0)
            .{ .site = try generateSite(generator) }
        else
            .text;
    }
    return children;
}

fn generateWhen(generator: *Generator) error{OutOfMemory}!*const WhenSpec {
    const spec = try generator.arena.create(WhenSpec);
    spec.* = .{
        .condition = generateCondition(generator.reader),
        .when_true = try generateBranch(generator),
        .when_false = try generateBranch(generator),
    };
    return spec;
}

fn generateBranch(generator: *Generator) error{OutOfMemory}!Branch {
    if (generator.reader.intRangeAtMost(u8, 0, 2) == 0) return .empty;
    return .{ .children = try generateChildren(generator, 1) };
}

/// A predicate whose truth moves with the history: a bound on the slot table
/// length, which only inserts grow and only rollbacks shrink, or an item value
/// that updates and inserts produce.
fn generateCondition(reader: *FuzzReader) WhenCondition {
    return if (reader.boolean())
        .{ .predicate = .length_at_least, .operand = reader.intRangeAtMost(i64, 0, max_slots / 2) }
    else
        .{ .predicate = .contains, .operand = reader.intRangeAtMost(i64, 1, 12) * key_stride + reader.intRangeAtMost(i64, 0, key_stride - 1) };
}

fn generateSite(generator: *Generator) error{OutOfMemory}!*const SiteSpec {
    const reader = generator.reader;
    const spec = try generator.arena.create(SiteSpec);
    const kind: RowKind = @enumFromInt(reader.intRangeAtMost(u8, 0, 4));
    spec.* = .{
        .id = std.math.cast(u16, generator.sites.items.len) orelse return error.OutOfMemory,
        .row_kind = kind,
        .condition = generateCondition(reader),
        .inner = null,
    };
    if (kind == .nested_each) {
        const inner = try generator.arena.create(InnerSpec);
        inner.* = .{ .id = std.math.cast(u16, generator.inners.items.len) orelse return error.OutOfMemory, .row_count = reader.intRangeAtMost(u8, 0, max_inner_rows - 1) };
        try generator.inners.append(generator.arena, inner);
        spec.inner = inner;
    }
    try generator.sites.append(generator.arena, spec);
    generator.shared_budget -= 1;
    return spec;
}

/// Mutable model threaded through history generation.
const Draft = struct {
    rows: std.ArrayListUnmanaged(ModelRow) = .empty,
    slots: std.ArrayListUnmanaged(i64) = .empty,
    next_key: u64 = 1,
    next_generation: u64 = 1,

    fn snapshot(self: *const Draft, arena: std.mem.Allocator, generation: u64, selected: u64) !State {
        return .{
            .rows = try arena.dupe(ModelRow, self.rows.items),
            .slots = try arena.dupe(i64, self.slots.items),
            .generation = generation,
            .selected = selected,
        };
    }

    fn restore(self: *Draft, arena: std.mem.Allocator, state: State) !void {
        self.rows.clearRetainingCapacity();
        try self.rows.appendSlice(arena, state.rows);
        self.slots.clearRetainingCapacity();
        try self.slots.appendSlice(arena, state.slots);
    }
};

fn generateHistory(generator: *Generator, children: []const Child) !Program {
    const reader = generator.reader;
    const arena = generator.arena;
    var draft = Draft{};

    // The mount: a snapshot of generation 1 with a few rows.
    const initial_count = reader.intRangeAtMost(usize, 0, max_rows / 2);
    for (0..initial_count) |_| _ = try insertRow(&draft, reader, arena, null);
    var selected = reader.intRangeAtMost(u64, 0, draft.next_key);
    const initial = try draft.snapshot(arena, draft.next_generation, selected);
    var history: std.ArrayListUnmanaged(State) = .empty;
    try history.append(arena, initial);

    const edit_count = reader.intRangeAtMost(usize, 0, max_edits);
    const edits = try arena.alloc(Edit, edit_count);
    var current = initial;
    for (edits) |*edit| {
        var kind: EditKind = switch (reader.intRangeAtMost(u8, 0, 9)) {
            0, 1, 2, 3, 4 => .direct,
            5 => .snapshot,
            6, 7 => .stale,
            8 => .rollback,
            else => .select,
        };
        if (kind == .select) {
            selected = reader.intRangeAtMost(u64, 0, draft.next_key);
            edit.* = .{ .kind = .select, .ops = &.{}, .generation = current.generation, .parent = 0, .result = .{ .rows = current.rows, .slots = current.slots, .generation = current.generation, .selected = selected }, .created = 0, .updated = 0, .removed = 0 };
            current = edit.result;
            continue;
        }
        if (kind == .rollback) {
            if (pickGeneration(reader, history.items, current.generation)) |older| {
                try draft.restore(arena, older);
                edit.* = .{ .kind = .rollback, .ops = &.{}, .generation = older.generation, .parent = 0, .result = try draft.snapshot(arena, older.generation, selected), .created = countCreated(current.rows, older.rows), .updated = 0, .removed = countCreated(older.rows, current.rows) };
                current = edit.result;
                try history.append(arena, current);
                continue;
            }
            kind = .snapshot;
        }

        const before = try arena.dupe(ModelRow, draft.rows.items);
        var touched: std.ArrayListUnmanaged(u64) = .empty;
        const op_count = reader.intRangeAtMost(usize, 1, max_ops);
        for (0..op_count) |_| try drawRawOp(&draft, reader, arena, &touched);
        var ops = try canonicalize(arena, reader, before, draft.rows.items, touched.items);
        if (ops.len == 0) {
            // Every draw cancelled out, which the platform would publish as
            // no new generation at all; make the batch a real transition.
            const inserted = try insertRow(&draft, reader, arena, 0);
            try touched.append(arena, inserted.insert.slot);
            ops = try canonicalize(arena, reader, before, draft.rows.items, touched.items);
        }
        var updated: u64 = 0;
        for (ops) |op| updated += @intFromBool(op == .update);

        var parent: u64 = 0;
        var generation: u64 = 0;
        switch (kind) {
            .direct => {
                draft.next_generation += 1;
                generation = draft.next_generation;
                parent = current.generation;
            },
            .stale => {
                draft.next_generation += 1;
                generation = draft.next_generation;
                if (pickGeneration(reader, history.items, current.generation)) |older| {
                    parent = older.generation;
                } else {
                    kind = .snapshot;
                }
            },
            .snapshot => {
                draft.next_generation += 1;
                generation = draft.next_generation;
            },
            else => unreachable,
        }

        edit.* = .{
            .kind = kind,
            .ops = ops,
            .generation = generation,
            .parent = parent,
            .result = try draft.snapshot(arena, generation, selected),
            .created = countCreated(before, draft.rows.items),
            .updated = updated,
            .removed = countCreated(draft.rows.items, before),
        };
        current = edit.result;
        try history.append(arena, current);
    }

    return .{ .children = children, .initial = initial, .edits = edits, .sites = generator.sites.items, .inners = generator.inners.items };
}

/// Rows of `after` whose slot is not in `before`.
fn countCreated(before: []const ModelRow, after: []const ModelRow) u64 {
    var count: u64 = 0;
    for (after) |row| {
        const present = for (before) |old| {
            if (old.slot == row.slot) break true;
        } else false;
        if (!present) count += 1;
    }
    return count;
}

fn pickGeneration(reader: *FuzzReader, history: []const State, current: u64) ?State {
    var candidates: usize = 0;
    for (history) |state| candidates += @intFromBool(state.generation != current);
    if (candidates == 0) return null;
    var pick = reader.intRangeLessThan(usize, 0, candidates);
    for (history) |state| {
        if (state.generation == current) continue;
        if (pick == 0) return state;
        pick -= 1;
    }
    unreachable;
}

/// Appends a fresh key at a fresh slot of the current table, at `position`
/// (or the end), and returns the stable-slot insert that describes it.
fn insertRow(draft: *Draft, reader: *FuzzReader, arena: std.mem.Allocator, position: ?usize) !Op {
    const key = draft.next_key;
    draft.next_key += 1;
    const item = @as(i64, @intCast(key)) * key_stride + reader.intRangeAtMost(i64, 0, key_stride - 1);
    try draft.slots.append(arena, item);
    const slot: u64 = draft.slots.items.len;
    const at = position orelse draft.rows.items.len;
    const before_slot: u64 = if (at == draft.rows.items.len) 0 else draft.rows.items[at].slot;
    try draft.rows.insert(arena, at, .{ .slot = slot, .key = key, .item = item });
    return .{ .insert = .{ .slot = slot, .before_slot = before_slot, .key = key } };
}

/// Draws one raw edit against the draft, recording every slot it touches.
/// Raw edits are what an application asks `Rows.apply` for; the platform then
/// canonicalizes the batch, which `canonicalize` mirrors.
fn drawRawOp(draft: *Draft, reader: *FuzzReader, arena: std.mem.Allocator, touched: *std.ArrayListUnmanaged(u64)) !void {
    const len = draft.rows.items.len;
    const choice: u8 = if (len == 0) 0 else reader.intRangeAtMost(u8, 0, 5);
    switch (choice) {
        0, 1 => {
            if (len >= max_rows or draft.slots.items.len >= max_slots) return;
            const inserted = try insertRow(draft, reader, arena, reader.intRangeAtMost(usize, 0, len));
            try touched.append(arena, inserted.insert.slot);
        },
        2 => {
            const first = reader.intRangeLessThan(usize, 0, len);
            const count = reader.intRangeAtMost(usize, 1, len - first);
            for (0..count) |_| {
                try touched.append(arena, draft.rows.items[first].slot);
                _ = draft.rows.orderedRemove(first);
            }
        },
        3 => {
            if (len < 2) return;
            const first = reader.intRangeLessThan(usize, 0, len);
            const count = reader.intRangeAtMost(usize, 1, len - first);
            var moved: [max_rows]ModelRow = undefined;
            @memcpy(moved[0..count], draft.rows.items[first .. first + count]);
            var previous: [max_rows]ModelRow = undefined;
            @memcpy(previous[0..len], draft.rows.items);
            for (0..count) |_| _ = draft.rows.orderedRemove(first);
            const destination = reader.intRangeAtMost(usize, 0, draft.rows.items.len);
            try draft.rows.insertSlice(arena, destination, moved[0..count]);
            // A move touches every row whose rank it changed, displaced
            // neighbours included: the canonical form places touched rows by
            // final rank and leaves untouched rows in their relative order,
            // which is only a permutation of the batch when the displaced
            // rows are placed too.
            for (draft.rows.items, 0..) |row, rank| {
                if (previous[rank].slot != row.slot) try touched.append(arena, row.slot);
            }
        },
        4 => {
            const index = reader.intRangeLessThan(usize, 0, len);
            const row = &draft.rows.items[index];
            row.item = @as(i64, @intCast(row.key)) * key_stride + reader.intRangeAtMost(i64, 0, key_stride - 1);
            draft.slots.items[@intCast(row.slot - 1)] = row.item;
            try touched.append(arena, row.slot);
        },
        else => {
            for (draft.rows.items) |row| try touched.append(arena, row.slot);
            draft.rows.clearRetainingCapacity();
        },
    }
}

fn rankOf(order: []const ModelRow, slot: u64) ?usize {
    for (order, 0..) |row, index| if (row.slot == slot) return index;
    return null;
}

/// Derives the canonical stable-slot delta the platform's `Rows` publishes
/// for a batch that touched `touched` and turned `before` into `after`:
/// every touched slot appears at most once, a fresh slot that did not survive
/// the batch is not mentioned, an emptied collection is one `clear`,
/// removals come first, then inserts and moves in final rank order, then
/// updates for surviving touched rows whose item changed. When the input asks
/// for it, order-adjacent removals coalesce into one range, which the engine
/// accepts and the store fuzz target covers at its own seam.
fn canonicalize(arena: std.mem.Allocator, reader: *FuzzReader, before: []const ModelRow, after: []const ModelRow, touched_raw: []const u64) ![]const Op {
    var ops: std.ArrayListUnmanaged(Op) = .empty;
    if (after.len == 0) {
        if (before.len == 0) return ops.items;
        try ops.append(arena, .clear);
        return ops.items;
    }
    var touched: std.ArrayListUnmanaged(u64) = .empty;
    for (touched_raw) |slot| {
        const seen = for (touched.items) |earlier| {
            if (earlier == slot) break true;
        } else false;
        if (!seen) try touched.append(arena, slot);
    }
    var working: std.ArrayListUnmanaged(ModelRow) = .empty;
    try working.appendSlice(arena, before);

    const coalesce = reader.boolean();
    var last_remove_index: ?usize = null;
    for (touched.items) |slot| {
        const at = rankOf(working.items, slot) orelse continue;
        if (rankOf(after, slot) != null) continue;
        _ = working.orderedRemove(at);
        if (coalesce and last_remove_index != null and last_remove_index.? == at and ops.items[ops.items.len - 1] == .remove) {
            ops.items[ops.items.len - 1].remove.count += 1;
        } else {
            try ops.append(arena, .{ .remove = .{ .first_slot = slot, .count = 1 } });
        }
        last_remove_index = at;
    }

    var targets: std.ArrayListUnmanaged(ModelRow) = .empty;
    for (after) |row| {
        const is_touched = for (touched.items) |slot| {
            if (slot == row.slot) break true;
        } else false;
        if (is_touched) try targets.append(arena, row);
    }
    for (targets.items) |target| {
        const rank = rankOf(after, target.slot).?;
        if (rankOf(working.items, target.slot)) |current| {
            if (current == rank) continue;
            _ = working.orderedRemove(current);
            const before_slot: u64 = if (rank < working.items.len) working.items[rank].slot else 0;
            try working.insert(arena, rank, target);
            try ops.append(arena, .{ .move = .{ .first_slot = target.slot, .count = 1, .before_slot = before_slot } });
        } else {
            const before_slot: u64 = if (rank < working.items.len) working.items[rank].slot else 0;
            try working.insert(arena, rank, target);
            try ops.append(arena, .{ .insert = .{ .slot = target.slot, .before_slot = before_slot, .key = target.key } });
        }
    }
    for (targets.items) |target| {
        const old = for (before) |row| {
            if (row.slot == target.slot) break row;
        } else continue;
        if (old.item != target.item) try ops.append(arena, .{ .update = .{ .slot = target.slot, .key = target.key } });
    }
    // The ops handed to the engine must reproduce the model's order exactly,
    // or the oracle would blame the engine for the generator's arithmetic.
    if (working.items.len != after.len) fail("canonical delta length {d} does not reproduce the model's {d} rows", .{ working.items.len, after.len });
    for (working.items, after) |left, right| if (left.slot != right.slot) fail("canonical delta does not reproduce the model's order", .{});
    return ops.items;
}

fn printProgram(program: Program) void {
    std.debug.print("program: {d} children, {d} sites, {d} edits\n", .{ program.children.len, program.sites.len, program.edits.len });
    printChildren(program.children, 1);
    printState("mount", program.initial);
    for (program.edits, 0..) |edit, index| {
        std.debug.print("edit {d}: {t} gen={d} parent={d} created={d} updated={d} removed={d} ops:", .{ index, edit.kind, edit.generation, edit.parent, edit.created, edit.updated, edit.removed });
        for (edit.ops) |op| switch (op) {
            .insert => |v| std.debug.print(" insert(slot={d} before={d} key={d})", .{ v.slot, v.before_slot, v.key }),
            .remove => |v| std.debug.print(" remove(first={d} count={d})", .{ v.first_slot, v.count }),
            .move => |v| std.debug.print(" move(first={d} count={d} before={d})", .{ v.first_slot, v.count, v.before_slot }),
            .update => |v| std.debug.print(" update(slot={d} key={d})", .{ v.slot, v.key }),
            .clear => std.debug.print(" clear", .{}),
        };
        std.debug.print("\n", .{});
        printState("  ->", edit.result);
    }
}

fn printState(name: []const u8, state: State) void {
    std.debug.print("{s} gen={d} selected={d} slots={d} rows:", .{ name, state.generation, state.selected, state.slots.len });
    for (state.rows) |row| std.debug.print(" s{d}k{d}v{d}", .{ row.slot, row.key, @mod(row.item, key_stride) });
    std.debug.print("\n", .{});
}

fn printCondition(condition: WhenCondition) void {
    switch (condition.predicate) {
        .length_at_least => std.debug.print("length>={d}", .{condition.operand}),
        .contains => std.debug.print("contains {d}", .{condition.operand}),
    }
}

fn printChildren(children: []const Child, indent: usize) void {
    for (children, 0..) |child, index| {
        for (0..indent) |_| std.debug.print("  ", .{});
        switch (child) {
            .text => std.debug.print("[{d}] text\n", .{index}),
            .wrapper => |nested| {
                std.debug.print("[{d}] wrapper\n", .{index});
                printChildren(nested, indent + 1);
            },
            .when => |when| {
                std.debug.print("[{d}] when ", .{index});
                printCondition(when.condition);
                std.debug.print("\n", .{});
                printBranch("true", when.when_true, indent + 1);
                printBranch("false", when.when_false, indent + 1);
            },
            .site => |spec| {
                std.debug.print("[{d}] each#{d} kind={t}", .{ index, spec.id, spec.row_kind });
                if (spec.row_kind == .when_list) {
                    std.debug.print(" ", .{});
                    printCondition(spec.condition);
                }
                if (spec.inner) |inner| std.debug.print(" inner#{d} rows={d}", .{ inner.id, inner.row_count });
                std.debug.print("\n", .{});
            },
        }
    }
}

fn printBranch(name: []const u8, branch: Branch, indent: usize) void {
    for (0..indent) |_| std.debug.print("  ", .{});
    switch (branch) {
        .empty => std.debug.print("{s}: empty\n", .{name}),
        .children => |nested| {
            std.debug.print("{s}: wrapper\n", .{name});
            printChildren(nested, indent + 1);
        },
    }
}

// -- Running ----------------------------------------------------------------

/// What one world observed after an edit, compared across worlds.
const Observation = struct {
    texts: []const []const u8,
    sites: usize,
    rows: usize,
    states: usize,
    scopes_active: usize,
    dom_active: usize,
    selector_members: usize,
    rows_created: u64,
    rows_removed: u64,
    rows_reused: u64,
    scopes_created: u64,
    scopes_disposed: u64,
};

const Plan = struct {
    mount_failure: ?usize = null,
    faulted_edit: ?usize = null,
    edit_failure: ?usize = null,
    edit_attempts: ?[]usize = null,
    /// World B: every description is a snapshot.
    snapshot_only: bool = false,
    record: ?[]Observation = null,
    compare: ?[]const Observation = null,
};

/// Row identity one site published after the last edit, keyed by row key.
const RowIdentity = struct {
    scope_id: ids.ScopeId,
    row_handle: u64,
    slot: u64,
};

const SiteIdentities = struct {
    key: signals.each_runtime.SiteKey,
    rows: std.AutoHashMapUnmanaged(u64, RowIdentity) = .empty,
};

const Metrics = signals.engine_metrics.RuntimeMetrics;

fn run(program: Program, arena: std.mem.Allocator, plan: Plan) usize {
    var host = fixtures.createHost();
    var roc_host = fixtures.bindHost(&host);
    host.engine.roc_host = &roc_host;
    defer if (fixtures.destroyHost(&host)) fail("host allocator leaked", .{});

    var runtime = Runtime{
        .list_token = fixtures.newBinderToken(&roc_host),
        .list_cap = fixtures.valueCapability(&roc_host),
        .selected_token = fixtures.newBinderToken(&roc_host),
        .selected_cap = fixtures.valueCapability(&roc_host),
    };
    runtime.rows = program.initial.rows;
    runtime.generation = program.initial.generation;
    runtime.parent = 0;
    const root = buildRoot(program, &roc_host, &runtime);
    defer root.decref(&roc_host);
    const refs_before = host.roc_allocations.snapshot();

    var fault = FaultAllocator.init(host.gpa.allocator());
    host.engine_allocator_override = fault.allocator();

    fault.configure(plan.mount_failure);
    step = if (plan.mount_failure != null) "faulted mount" else "mount";
    const result = fixtures.renderInitialRootWithArmedPublication(&host, &roc_host, root, &fault);
    const attempts = fault.attempts;

    if (plan.mount_failure) |number| {
        expectRefusal(result, "mount", number);
        expectUnpublished(&host, number);
        if (host.engine.pending_roc_metrics.closure_retains != host.engine.pending_roc_metrics.closure_releases) fail("refusal at attempt {d} left closure retains unbalanced", .{number});
        if (host.roc_allocations.liveCountSince(refs_before) != 0 or host.roc_allocations.snapshot().live_bytes != refs_before.live_bytes) fail("refusal at attempt {d} leaked Roc allocations", .{number});
        fault.configure(null);
        step = "mount retried after a refusal";
        _ = fixtures.renderInitialRootWithArmedPublication(&host, &roc_host, root, &fault) catch |err| fail("retry after refusal at attempt {d} failed: {t}", .{ number, err });
        expectPublished(&host, program, program.initial);
        return attempts;
    }

    _ = result catch |err| fail("unfaulted mount failed: {t}", .{err});
    expectPublished(&host, program, program.initial);

    var identities: std.ArrayListUnmanaged(SiteIdentities) = .empty;
    captureIdentities(&host, arena, program.initial, &identities);
    runEdits(&host, &roc_host, program, arena, plan, &fault, &runtime, &identities);
    return attempts;
}

fn runEdits(host: *Host, roc_host: *abi.RocHost, program: Program, arena: std.mem.Allocator, plan: Plan, fault: *FaultAllocator, runtime: *Runtime, identities: *std.ArrayListUnmanaged(SiteIdentities)) void {
    const list_node_id, const selected_node_id = stateNodeIds(host);
    var previous = program.initial;

    for (program.edits, 0..) |edit, edit_index| {
        const faulted = plan.edit_failure != null and plan.faulted_edit != null and plan.faulted_edit.? == edit_index;
        const next = edit.result;

        runtime.rows = next.rows;
        runtime.ops = edit.ops;
        runtime.generation = edit.generation;
        runtime.parent = if (plan.snapshot_only) 0 else edit.parent;

        const allocations_before = host.roc_allocations.snapshot();
        const metrics_before = host.engine.pending_roc_metrics;
        const value_before = fixtures.stateValue(host, list_node_id);

        fault.configure(if (faulted) plan.edit_failure else null);
        step = if (faulted) "faulted edit" else "edit";
        const dispatch = dispatchEdit(host, roc_host, edit, next, list_node_id, selected_node_id, runtime);
        if (plan.edit_attempts) |slots| slots[edit_index] = fault.attempts;

        if (faulted) {
            const number = plan.edit_failure.?;
            expectRefusal(dispatch, "edit", number);
            expectPublished(host, program, previous);
            expectSiteTables(host, program, previous);
            if (fixtures.stateValue(host, list_node_id) != value_before) fail("edit {d} refused at attempt {d} but replaced the list cell value", .{ edit_index, number });
            const retains = host.engine.pending_roc_metrics.closure_retains - metrics_before.closure_retains;
            const releases = host.engine.pending_roc_metrics.closure_releases - metrics_before.closure_releases;
            if (retains != releases) fail("edit {d} refused at attempt {d} left {d} retains against {d} releases", .{ edit_index, number, retains, releases });
            if (host.roc_allocations.liveCountSince(allocations_before) != 0 or host.roc_allocations.snapshot().live_bytes != allocations_before.live_bytes) fail("edit {d} refused at attempt {d} leaked Roc allocations", .{ edit_index, number });

            fault.configure(null);
            step = "edit retried after a refusal";
            _ = dispatchEdit(host, roc_host, edit, next, list_node_id, selected_node_id, runtime) catch |err| fail("retry of edit {d} after refusal at attempt {d} failed: {t}", .{ edit_index, number, err });
        } else {
            _ = dispatch catch |err| fail("unfaulted edit {d} ({t}) failed: {t}", .{ edit_index, edit.kind, err });
        }

        expectPublished(host, program, next);
        expectSiteTables(host, program, next);
        expectIdentities(host, arena, program, edit, previous, next, identities);
        if (!faulted) {
            const metrics_after = host.engine.pending_roc_metrics;
            expectWorkBounds(program, edit, edit_index, previous, next, plan.snapshot_only, metrics_before, metrics_after);
            const observation = observe(host, arena, program, next, metrics_before, metrics_after);
            if (plan.record) |slots| slots[edit_index] = observation;
            if (plan.compare) |recorded| expectSameObservation(recorded[edit_index], observation, edit_index);
        }
        previous = next;
    }
}

fn dispatchEdit(host: *Host, roc_host: *abi.RocHost, edit: Edit, next: State, list_node_id: u64, selected_node_id: u64, runtime: *const Runtime) !fixtures.RenderCounts {
    if (edit.kind == .select) {
        var buffer: [32]u8 = undefined;
        return fixtures.dispatchStateValue(host, roc_host, selected_node_id, fixtures.strValue(roc_host, keyText(&buffer, next.selected)), runtime.selected_cap);
    }
    return fixtures.dispatchStateValue(host, roc_host, list_node_id, cellValue(roc_host, next), runtime.list_cap);
}

/// The list cell is the first published state site and the selected cell the
/// second: collection walks the root first, and the two cells nest in that
/// order ahead of every stateful row.
fn stateNodeIds(host: *const Host) struct { u64, u64 } {
    const sites = host.engine.active_stream.scope_sites.items;
    var found: [2]u64 = undefined;
    var count: usize = 0;
    for (sites) |site| {
        if (site.kind != .state) continue;
        found[count] = site.node_id.raw();
        count += 1;
        if (count == 2) break;
    }
    if (count != 2) fail("mount published {d} state sites, expected the list and selected cells first", .{count});
    return .{ found[0], found[1] };
}

fn expectRefusal(result: anytype, comptime what: []const u8, failure_number: usize) void {
    if (result) |_| {
        fail(what ++ " with failure at attempt {d} did not refuse", .{failure_number});
    } else |err| if (err != error.OutOfMemory) {
        fail(what ++ " with failure at attempt {d} was refused as {t}, not an allocation failure", .{ failure_number, err });
    }
}

fn cellValue(roc_host: *abi.RocHost, state: State) HostValue {
    var buffer: [max_slots + 1]i64 = undefined;
    const view = cellView(state, &buffer);
    var values: [max_slots + 1]HostValue = undefined;
    for (view, 0..) |item, index| values[index] = fixtures.i64Value(item);
    return fixtures.i64ListValue(roc_host, values[0..view.len]);
}

fn keyText(buffer: []u8, key: u64) []const u8 {
    return std.fmt.bufPrint(buffer, "{d}", .{key}) catch unreachable;
}

fn keyBytes(key: u64) u64 {
    var buffer: [32]u8 = undefined;
    return keyText(&buffer, key).len;
}

// -- Building ---------------------------------------------------------------

fn buildRoot(program: Program, roc_host: *abi.RocHost, runtime: *const Runtime) abi.Elem {
    const body = buildChildren(program.children, roc_host, runtime);
    var buffer: [32]u8 = undefined;
    const selected = fixtures.stateWithTokenInitialAndCapability(roc_host, runtime.selected_token, fixtures.strValue(roc_host, keyText(&buffer, program.initial.selected)), body, runtime.selected_cap);
    return fixtures.stateWithTokenInitialAndCapability(roc_host, runtime.list_token, cellValue(roc_host, program.initial), selected, runtime.list_cap);
}

fn buildChildren(children: []const Child, roc_host: *abi.RocHost, runtime: *const Runtime) abi.Elem {
    var built: [max_children]abi.Elem = undefined;
    for (children, 0..) |child, index| {
        built[index] = switch (child) {
            .text => fixtures.text(roc_host, separator_text),
            .site => |spec| buildSite(spec, roc_host, runtime),
            .wrapper => |nested| buildChildren(nested, roc_host, runtime),
            .when => |when| fixtures.whenOnListPredicate(roc_host, runtime.list_token, when.condition.predicate, when.condition.operand, buildBranch(when.when_true, roc_host, runtime), buildBranch(when.when_false, roc_host, runtime)),
        };
    }
    return fixtures.element(roc_host, built[0..children.len]);
}

fn buildBranch(branch: Branch, roc_host: *abi.RocHost, runtime: *const Runtime) abi.Elem {
    return switch (branch) {
        .empty => fixtures.emptyEach(roc_host),
        .children => |nested| buildChildren(nested, roc_host, runtime),
    };
}

fn buildSite(spec: *const SiteSpec, roc_host: *abi.RocHost, runtime: *const Runtime) abi.Elem {
    return fixtures.eachWithRowsAdapters(RowCapture, roc_host, runtime.list_token, runtime.list_cap, &describeCallable, &copySnapshotCallable, &copyDeltaCallable, &rowCallable, .{ .spec = spec, .runtime = runtime });
}

/// `Rows.describe`: announces the pending generation as a snapshot when no
/// parent is set, otherwise as a delta from that parent with the exact op
/// and key shape `copyDeltaCallable` will emit.
fn describeCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const runtime = fixtures.captureAs(RowCapture, capture_ptr).runtime;
    const call_args = fixtures.argsAs(fixtures.HostValueU64Args, args);
    defer fixtures.dropHostValue(roc_host, call_args.arg0);
    const host = fixtures.hostOf(roc_host);
    var snapshot_key_bytes: u64 = 0;
    for (runtime.rows) |row| snapshot_key_bytes += keyBytes(row.key);
    const token = if (runtime.parent == 0)
        host.engine.pushRowsSnapshotDescriptionSink(host, call_args.arg1, runtime.generation, runtime.rows.len, snapshot_key_bytes) catch |err| fail("snapshot description sink refused: {t}", .{err})
    else blk: {
        var delta_keys: u64 = 0;
        var delta_key_bytes: u64 = 0;
        for (runtime.ops) |op| switch (op) {
            .insert => |v| {
                delta_keys += 1;
                delta_key_bytes += keyBytes(v.key);
            },
            .update => |v| {
                delta_keys += 1;
                delta_key_bytes += keyBytes(v.key);
            },
            else => {},
        };
        break :blk host.engine.pushRowsDeltaDescriptionSink(host, call_args.arg1, runtime.generation, runtime.parent, runtime.rows.len, snapshot_key_bytes, runtime.ops.len, delta_keys, delta_key_bytes) catch |err| fail("delta description sink refused: {t}", .{err});
    };
    fixtures.writeResult(u64, ret, token);
}

/// `Rows.copy_snapshot`: the pending generation's full order.
fn copySnapshotCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const runtime = fixtures.captureAs(RowCapture, capture_ptr).runtime;
    const call_args = fixtures.argsAs(fixtures.HostValueU64Args, args);
    defer fixtures.dropHostValue(roc_host, call_args.arg0);
    const host = fixtures.hostOf(roc_host);
    var token = call_args.arg1;
    for (runtime.rows, 0..) |row, index| {
        var buffer: [32]u8 = undefined;
        token = host.engine.pushRowsSnapshotSink(host, token, index, row.slot, keyText(&buffer, row.key)) catch |err| fail("snapshot sink refused row {d}: {t}", .{ index, err });
    }
    fixtures.writeResult(u64, ret, token);
}

/// `Rows.copy_delta`: the pending edit's stable-slot operations in order.
fn copyDeltaCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const runtime = fixtures.captureAs(RowCapture, capture_ptr).runtime;
    const call_args = fixtures.argsAs(fixtures.HostValueU64Args, args);
    defer fixtures.dropHostValue(roc_host, call_args.arg0);
    const host = fixtures.hostOf(roc_host);
    var token = call_args.arg1;
    for (runtime.ops, 0..) |op, index| {
        var buffer: [32]u8 = undefined;
        token = switch (op) {
            .insert => |v| host.engine.pushRowsDeltaInsertSink(host, token, index, v.before_slot, v.slot, keyText(&buffer, v.key)),
            .remove => |v| host.engine.pushRowsDeltaRemoveSink(host, token, index, v.first_slot, v.count),
            .move => |v| host.engine.pushRowsDeltaMoveSink(host, token, index, v.first_slot, v.count, v.before_slot),
            .update => |v| host.engine.pushRowsDeltaUpdateSink(host, token, index, v.slot, keyText(&buffer, v.key)),
            .clear => host.engine.pushRowsDeltaClearSink(host, token, index),
        } catch |err| fail("delta sink refused op {d}: {t}", .{ index, err });
    }
    fixtures.writeResult(u64, ret, token);
}

fn rowCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const capture = fixtures.captureAs(RowCapture, capture_ptr);
    const spec = capture.spec;
    const runtime = capture.runtime;
    const key: u64 = @intCast(fixtures.eachRowKeyI64(roc_host, args));
    var buffer: [32]u8 = undefined;
    const label = rowLabel(&buffer, spec.id, key);
    const elem = switch (spec.row_kind) {
        .text => fixtures.text(roc_host, label),
        .stateful => fixtures.state(roc_host, fixtures.text(roc_host, label)),
        .when_list => fixtures.whenOnListPredicate(roc_host, runtime.list_token, spec.condition.predicate, spec.condition.operand, fixtures.text(roc_host, label), fixtures.text(roc_host, hidden_text)),
        .when_selected => blk: {
            var key_buffer: [32]u8 = undefined;
            const select = fixtures.selectOnState(roc_host, runtime.selected_token, runtime.selected_cap, keyText(&key_buffer, key));
            break :blk fixtures.whenWithSignal(roc_host, select, fixtures.text(roc_host, label), fixtures.text(roc_host, hidden_text));
        },
        .nested_each => blk: {
            const inner = spec.inner.?;
            var items: [max_inner_rows]HostValue = undefined;
            const count = innerRowCount(inner, key);
            for (items[0..count], 0..) |*item, index| item.* = fixtures.i64Value(@intCast(index));
            const children = [_]abi.Elem{ fixtures.text(roc_host, label), fixtures.eachWithItemsRowAndCapture(InnerCapture, roc_host, items[0..count], &innerRowCallable, .{ .spec = inner }) };
            break :blk fixtures.element(roc_host, &children);
        },
    };
    fixtures.writeResult(abi.Elem, ret, elem);
}

fn innerRowCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const capture = fixtures.captureAs(InnerCapture, capture_ptr);
    const key: u64 = @intCast(fixtures.eachRowKeyI64(roc_host, args));
    var buffer: [32]u8 = undefined;
    fixtures.writeResult(abi.Elem, ret, fixtures.text(roc_host, rowLabel(&buffer, capture.spec.id + inner_label_base, key)));
}

/// Inner site labels use ids past every shared site's so a label names one
/// site of one kind.
const inner_label_base: u16 = 1000;

fn rowLabel(buffer: []u8, site_id: u16, key: u64) []const u8 {
    return std.fmt.bufPrint(buffer, "row-{d}-{d}", .{ site_id, key }) catch unreachable;
}

fn ownedLabel(arena: std.mem.Allocator, site_id: u16, key: u64) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(arena, "row-{d}-{d}", .{ site_id, key });
}

// -- Oracles ----------------------------------------------------------------

fn expectUnpublished(host: *const Host, failure_number: usize) void {
    const engine = &host.engine;
    const counts = [_]struct { name: []const u8, len: usize }{
        .{ .name = "scopes", .len = engine.scopes.items.len },
        .{ .name = "states", .len = engine.states.items.len },
        .{ .name = "each row sites", .len = engine.each_row_sites.items.len },
        .{ .name = "active render nodes", .len = engine.active_stream.render_nodes.items.len },
        .{ .name = "active eaches", .len = engine.active_stream.eaches.items.len },
        .{ .name = "active signal graph", .len = engine.active_signal_graph.items.len },
        .{ .name = "dom elements", .len = host.dom_elements.items.len },
        .{ .name = "selector members", .len = engine.selectors.memberCount() },
    };
    for (counts) |count| {
        if (count.len != 0) fail("refusal at attempt {d} published {d} {s}", .{ failure_number, count.len, count.name });
    }
    if (engine.render_cache.hasRoot()) fail("refusal at attempt {d} published a render root", .{failure_number});
}

fn expectPublished(host: *const Host, program: Program, state: State) void {
    const engine = &host.engine;
    const expected = Expected.of(program, state);
    if (!engine.render_cache.hasRoot()) fail("no render root is committed", .{});
    if (engine.each_row_sites.items.len != expected.sites) fail("engine owns {d} each sites, model expects {d}", .{ engine.each_row_sites.items.len, expected.sites });
    if (engine.active_stream.eaches.items.len != expected.sites) fail("active stream holds {d} each descriptors, model expects {d}", .{ engine.active_stream.eaches.items.len, expected.sites });
    if (engine.active_stream.whens.items.len != expected.whens) fail("active stream holds {d} when descriptors, model expects {d}", .{ engine.active_stream.whens.items.len, expected.whens });
    var rows: usize = 0;
    for (engine.each_row_sites.items) |site| rows += site.scope_ids.items.len;
    if (rows != expected.rows) fail("engine owns {d} each rows, model expects {d}", .{ rows, expected.rows });
    if (engine.states.items.len != expected.states) fail("engine owns {d} states, model expects {d}", .{ engine.states.items.len, expected.states });
    expectLabels(host, program, state);
    expectDocumentOrder(host, program, state);
    host.engine.validateActiveScopeSiteInsertIndexes();
}

fn expectLabels(host: *const Host, program: Program, state: State) void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var shown: std.ArrayListUnmanaged([]const u8) = .empty;
    modelTexts(&shown, arena, program.children, state) catch fail("oracle arena exhausted", .{});
    for (shown.items) |label| {
        if (fixtures.findActiveText(host, label) == null) fail("modelled text '{s}' is not an active DOM text node", .{label});
    }
    var buffer: [32]u8 = undefined;
    var key: u64 = 0;
    while (key <= max_slots + max_rows * max_edits) : (key += 1) {
        for (program.sites) |spec| expectLabelHidden(host, shown.items, rowLabel(&buffer, spec.id, key));
    }
    for (program.inners) |inner| {
        for (0..max_inner_rows) |index| expectLabelHidden(host, shown.items, rowLabel(&buffer, inner.id + inner_label_base, index));
    }
}

fn expectLabelHidden(host: *const Host, shown: []const []const u8, label: []const u8) void {
    for (shown) |visible| if (std.mem.eql(u8, visible, label)) return;
    if (fixtures.findActiveText(host, label) != null) fail("hidden row label '{s}' is still an active DOM text node", .{label});
}

fn expectDocumentOrder(host: *const Host, program: Program, state: State) void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var expected: std.ArrayListUnmanaged([]const u8) = .empty;
    modelTexts(&expected, arena, program.children, state) catch fail("oracle arena exhausted", .{});
    var actual: std.ArrayListUnmanaged([]const u8) = .empty;
    if (host.engine.render_cache.nodes.items[fixtures.render_root.index()].parent_id != null) fail("committed render root has a parent", .{});
    collectRenderTexts(host, arena, &actual, fixtures.render_root) catch fail("oracle arena exhausted", .{});
    const mismatch = for (0..@min(expected.items.len, actual.items.len)) |index| {
        if (!std.mem.eql(u8, expected.items[index], actual.items[index])) break index;
    } else if (expected.items.len != actual.items.len) @min(expected.items.len, actual.items.len) else return;
    std.debug.print("expected document text order:", .{});
    for (expected.items) |text| std.debug.print(" {s}", .{text});
    std.debug.print("\nactual document text order:  ", .{});
    for (actual.items) |text| std.debug.print(" {s}", .{text});
    std.debug.print("\n", .{});
    fail("render tree text order diverges from the model at text {d}", .{mismatch});
}

fn collectRenderTexts(host: *const Host, arena: std.mem.Allocator, out: *std.ArrayListUnmanaged([]const u8), parent: ids.ElemId) error{OutOfMemory}!void {
    const children = fixtures.publishedChildren(host, parent);
    const cache = &host.engine.render_cache;
    if (cache.childCount(parent) != children.len) fail("published parent {d} child count differs from committed topology", .{parent.raw()});
    var sibling = cache.firstChild(parent);
    var previous: ?ids.ElemId = null;
    for (children, 0..) |child_raw, index| {
        const child = ids.ElemId.fromRaw(child_raw);
        if (sibling != child) fail("published parent {d} child {d} differs from committed sibling order at {d}", .{ parent.raw(), child_raw, index });
        if (cache.previousSibling(child) != previous) fail("child {d} has an inconsistent previous sibling", .{child_raw});
        if (cache.nodes.items[child.index()].parent_id != parent) fail("child {d} has an inconsistent render parent", .{child_raw});
        if (host.dom_elements.items[child.index()].parent_id != parent.raw()) fail("child {d} has an inconsistent published parent", .{child_raw});
        for (children[index + 1 ..]) |other| {
            if (child_raw == other) fail("render parent {d} holds child {d} more than once", .{ parent.raw(), child_raw });
        }
        if (fixtures.renderText(host, child)) |text| try out.append(arena, text);
        try collectRenderTexts(host, arena, out, child);
        previous = child;
        sibling = cache.nextSibling(child);
    }
    if (sibling != null) fail("parent {d} has committed siblings beyond its published child list", .{parent.raw()});
    if (cache.nodes.items[parent.index()].last_child != previous) fail("parent {d} has an inconsistent final sibling", .{parent.raw()});
}

/// A site's row tables as the store publishes them, with the dense site
/// table index it lives at.
const StoreSite = struct {
    index: usize,
    site_id: signals.rows_site_store.SiteId,
    /// Whether the site's parent scope is itself an each row, which makes it
    /// a nested constant site rather than a shared one.
    nested: bool,
};

fn storeSite(host: *const Host, index: usize) StoreSite {
    const engine = &host.engine;
    const site = engine.each_row_sites.items[index];
    const store = if (engine.rows_store) |*store| store else fail("engine owns each sites but no Rows store", .{});
    const site_id = engine.rows_site_ids.get(site.key) orelse fail("each site {d} has no Rows store site", .{index});
    return .{ .index = index, .site_id = site_id, .nested = store.findScope(site.key.parent_scope_id.raw()) != null };
}

/// Asserts every shared site's store order is the model's, that the dense
/// table, memberships, and slot index all agree with the store, and that the
/// empty-branch eaches are the only rowless sites while the model has rows.
fn expectSiteTables(host: *const Host, program: Program, state: State) void {
    const engine = &host.engine;
    const expected = Expected.of(program, state);
    if (engine.each_row_sites.items.len == 0) return;
    const store = if (engine.rows_store) |*store| store else fail("engine owns each sites but no Rows store", .{});
    var shared_seen: usize = 0;
    var empty_seen: usize = 0;
    for (engine.each_row_sites.items, 0..) |site, index| {
        const located = storeSite(host, index);
        const committed = store.getSiteConst(located.site_id) catch fail("site {d} store entry is invalid", .{index});
        if (committed.len != site.scope_ids.items.len) fail("site {d} store holds {d} rows but its dense table {d}", .{ index, committed.len, site.scope_ids.items.len });
        // Every dense-table scope is a store row of this site at the index
        // its membership names.
        for (site.scope_ids.items, 0..) |scope_id, row_index| {
            const membership = engine.each_row_memberships_by_scope_id.items[scope_id.index()] orelse fail("row scope {d} of site {d} has no membership", .{ scope_id.raw(), index });
            if (membership.site_index != index or membership.row_index != row_index) fail("row scope {d} membership names site {d} row {d}, table holds it at site {d} row {d}", .{ scope_id.raw(), membership.site_index, membership.row_index, index, row_index });
            const location = store.findScope(scope_id.raw()) orelse fail("row scope {d} of site {d} is not in the Rows store", .{ scope_id.raw(), index });
            if (location.site_id != located.site_id) fail("row scope {d} is stored under another site", .{scope_id.raw()});
            if (!engine.scopes.items[scope_id.index()].lifecycle.isActive()) fail("row scope {d} of site {d} is not active", .{ scope_id.raw(), index });
        }
        // Every store row resolves through its slot and, for a shared site,
        // sits where the model puts it.
        var current = committed.head;
        var position: usize = 0;
        while (current) |row_id| : (position += 1) {
            const row = store.getRowConst(located.site_id, row_id) catch fail("site {d} row {d} is invalid", .{ index, position });
            const by_slot = (store.findItemSlot(located.site_id, row.metadata.item_slot) catch unreachable) orelse fail("site {d} slot {d} does not resolve", .{ index, row.metadata.item_slot });
            if (by_slot != row_id) fail("site {d} slot {d} resolves to another row", .{ index, row.metadata.item_slot });
            if (!located.nested and expected.shared_live != 0 and (committed.len != 0 or state.rows.len == 0)) {
                if (position >= state.rows.len) fail("shared site {d} holds more rows than the model", .{index});
                const model = state.rows[position];
                var buffer: [32]u8 = undefined;
                if (!std.mem.eql(u8, row.key, keyText(&buffer, model.key)) or row.metadata.item_slot != model.slot) {
                    fail("shared site {d} row {d} is key {s} slot {d}, model expects key {d} slot {d}", .{ index, position, row.key, row.metadata.item_slot, model.key, model.slot });
                }
            }
            current = row.next;
        }
        if (position != committed.len) fail("site {d} links {d} rows but records {d}", .{ index, position, committed.len });
        if (!located.nested) {
            if (committed.len == 0 and state.rows.len != 0) {
                empty_seen += 1;
            } else {
                shared_seen += 1;
                if (committed.len != state.rows.len) fail("shared site {d} holds {d} rows, model expects {d}", .{ index, committed.len, state.rows.len });
            }
        }
    }
    if (state.rows.len != 0) {
        if (shared_seen != expected.shared_live) fail("{d} shared sites hold rows, model expects {d}", .{ shared_seen, expected.shared_live });
        if (empty_seen != expected.empty_live) fail("{d} rowless top-level sites, model expects {d} empty branches", .{ empty_seen, expected.empty_live });
    } else if (shared_seen != expected.shared_live + expected.empty_live) {
        fail("{d} top-level sites, model expects {d}", .{ shared_seen, expected.shared_live + expected.empty_live });
    }
}

/// Records every shared site's row identities so the next edit can prove
/// survivors kept theirs.
fn captureIdentities(host: *const Host, arena: std.mem.Allocator, state: State, out: *std.ArrayListUnmanaged(SiteIdentities)) void {
    out.clearRetainingCapacity();
    const engine = &host.engine;
    if (engine.each_row_sites.items.len == 0) return;
    const store = &engine.rows_store.?;
    for (engine.each_row_sites.items, 0..) |site, index| {
        const located = storeSite(host, index);
        if (located.nested) continue;
        const committed = store.getSiteConst(located.site_id) catch unreachable;
        if (committed.len != state.rows.len) continue;
        var identities = SiteIdentities{ .key = site.key };
        var current = committed.head;
        while (current) |row_id| {
            const row = store.getRowConst(located.site_id, row_id) catch unreachable;
            const key = std.fmt.parseInt(u64, row.key, 10) catch fail("row key '{s}' is not a generated key", .{row.key});
            identities.rows.put(arena, key, .{ .scope_id = ids.ScopeId.fromRaw(row.metadata.scope_id), .row_handle = row.metadata.row_handle, .slot = row.metadata.item_slot }) catch fail("oracle arena exhausted", .{});
            current = row.next;
        }
        out.append(arena, identities) catch fail("oracle arena exhausted", .{});
    }
}

/// Asserts surviving keys kept their identity, created rows took scopes not
/// live in the site before, and removed rows are gone from the store, then
/// re-captures for the next edit.
fn expectIdentities(host: *const Host, arena: std.mem.Allocator, program: Program, edit: Edit, previous: State, next: State, identities: *std.ArrayListUnmanaged(SiteIdentities)) void {
    const engine = &host.engine;
    if (engine.each_row_sites.items.len != 0 and survivingSharedSites(program.children, previous, next) != 0) {
        const store = &engine.rows_store.?;
        for (engine.each_row_sites.items, 0..) |site, index| {
            const located = storeSite(host, index);
            if (located.nested) continue;
            const before = for (identities.items) |entry| {
                if (entry.key.parent_scope_id == site.key.parent_scope_id and entry.key.site_ordinal == site.key.site_ordinal) break entry;
            } else continue;
            const committed = store.getSiteConst(located.site_id) catch unreachable;
            if (committed.len != next.rows.len) continue;
            var current = committed.head;
            while (current) |row_id| {
                const row = store.getRowConst(located.site_id, row_id) catch unreachable;
                const key = std.fmt.parseInt(u64, row.key, 10) catch unreachable;
                const survived = for (previous.rows) |old| {
                    if (old.key == key and old.slot == row.metadata.item_slot) break true;
                } else false;
                if (before.rows.get(key)) |old| {
                    if (survived) {
                        if (old.scope_id.raw() != row.metadata.scope_id or old.row_handle != row.metadata.row_handle or old.slot != row.metadata.item_slot) {
                            fail("edit ({t}) changed the identity of surviving key {d} in site {d}: scope {d}->{d} handle {d}->{d} slot {d}->{d}", .{ edit.kind, key, index, old.scope_id.raw(), row.metadata.scope_id, old.row_handle, row.metadata.row_handle, old.slot, row.metadata.item_slot });
                        }
                    }
                } else {
                    var it = before.rows.valueIterator();
                    while (it.next()) |old| {
                        if (old.scope_id.raw() == row.metadata.scope_id) fail("edit ({t}) created key {d} in site {d} on scope {d}, which was live for another key", .{ edit.kind, key, index, row.metadata.scope_id });
                    }
                }
                current = row.next;
            }
            var it = before.rows.iterator();
            while (it.next()) |entry| {
                const still = for (next.rows) |row| {
                    if (row.key == entry.key_ptr.*) break true;
                } else false;
                if (still) continue;
                const scope_id = entry.value_ptr.scope_id;
                if (store.findScope(scope_id.raw())) |location| {
                    if (location.site_id == located.site_id) fail("edit ({t}) removed key {d} from site {d} but scope {d} is still stored there", .{ edit.kind, entry.key_ptr.*, index, scope_id.raw() });
                }
                if (scope_id.index() < engine.each_row_memberships_by_scope_id.items.len) {
                    if (engine.each_row_memberships_by_scope_id.items[scope_id.index()]) |membership| {
                        if (membership.site_index == index) fail("edit ({t}) removed key {d} but scope {d} still holds a membership in site {d}", .{ edit.kind, entry.key_ptr.*, scope_id.raw(), index });
                    }
                }
            }
        }
    }
    captureIdentities(host, arena, next, identities);
}

/// Asserts the work counters PR #120 introduced moved by exactly what the
/// edit touched. `rows_candidate_rows_visited` is bumped only on the direct
/// path, so its exact value also proves which path ran.
fn expectWorkBounds(program: Program, edit: Edit, edit_index: usize, previous: State, next: State, snapshot_only: bool, before: Metrics, after: Metrics) void {
    const candidates = after.rows_candidate_rows_visited - before.rows_candidate_rows_visited;
    const memberships = after.rows_membership_entries_rewritten - before.rows_membership_entries_rewritten;
    const direct = edit.kind == .direct and !snapshot_only;
    if (direct) {
        const surviving: u64 = survivingSharedSites(program.children, previous, next);
        const live_before: u64 = Expected.of(program, previous).shared_live;
        const per_site = edit.created + edit.updated;
        // Every site live before the edit is prepared once provisionally;
        // when the transaction has more than one structural change (another
        // site, or a when that flips) the surviving sites are prepared a
        // second time by the composite planner. A single site with no flip
        // is prepared exactly once.
        const low = live_before * per_site;
        const high = if (live_before == 1 and !anyFlip(program, previous, next)) low else (live_before + surviving) * per_site;
        if (candidates < low or candidates > high) fail("direct edit {d} visited {d} candidate rows, expected {d}..{d} ({d} live sites, {d} surviving, {d} created + {d} updated)", .{ edit_index, candidates, low, high, live_before, surviving, edit.created, edit.updated });
        const mem_low = surviving * (edit.removed + edit.created);
        const mem_high = surviving * (2 * edit.removed + edit.created);
        if (memberships < mem_low or memberships > mem_high) fail("direct edit {d} rewrote {d} membership entries, expected {d}..{d} ({d} sites x ({d} removed, {d} created))", .{ edit_index, memberships, mem_low, mem_high, surviving, edit.removed, edit.created });
    } else {
        if (candidates != 0) fail("{t} edit {d} visited {d} candidate rows through the direct path", .{ edit.kind, edit_index, candidates });
        if (memberships != 0) fail("{t} edit {d} rewrote {d} membership entries through the direct path", .{ edit.kind, edit_index, memberships });
    }
    if (!anyWhenFlipped(program.children, previous, next)) {
        const visits = after.selector_registry_visits - before.selector_registry_visits;
        const expected_visits = expectedSelectorVisits(program.children, edit, previous);
        if (visits != expected_visits) fail("{t} edit {d} made {d} selector registry visits, expected exactly {d}", .{ edit.kind, edit_index, visits, expected_visits });
    }
}

fn observe(host: *const Host, arena: std.mem.Allocator, program: Program, state: State, before: Metrics, after: Metrics) Observation {
    var texts: std.ArrayListUnmanaged([]const u8) = .empty;
    modelTexts(&texts, arena, program.children, state) catch fail("oracle arena exhausted", .{});
    const engine = &host.engine;
    var rows: usize = 0;
    for (engine.each_row_sites.items) |site| rows += site.scope_ids.items.len;
    var scopes_active: usize = 0;
    for (engine.scopes.items) |scope| scopes_active += @intFromBool(scope.lifecycle.isActive());
    var dom_active: usize = 0;
    for (host.dom_elements.items) |elem| dom_active += @intFromBool(elem.active);
    return .{
        .texts = texts.items,
        .sites = engine.each_row_sites.items.len,
        .rows = rows,
        .states = engine.states.items.len,
        .scopes_active = scopes_active,
        .dom_active = dom_active,
        .selector_members = engine.selectors.memberCount(),
        .rows_created = after.rows_created - before.rows_created,
        .rows_removed = after.rows_removed - before.rows_removed,
        .rows_reused = after.rows_reused - before.rows_reused,
        .scopes_created = after.scopes_created - before.scopes_created,
        .scopes_disposed = after.scopes_disposed - before.scopes_disposed,
    };
}

fn expectSameObservation(a: Observation, b: Observation, edit_index: usize) void {
    inline for (std.meta.fields(Observation)) |field| {
        if (comptime std.mem.eql(u8, field.name, "texts")) {
            if (a.texts.len != b.texts.len) fail("edit {d}: world A shows {d} texts, world B {d}", .{ edit_index, a.texts.len, b.texts.len });
            for (a.texts, b.texts, 0..) |left, right, index| {
                if (!std.mem.eql(u8, left, right)) fail("edit {d}: worlds disagree on text {d}: '{s}' vs '{s}'", .{ edit_index, index, left, right });
            }
        } else if (@field(a, field.name) != @field(b, field.name)) {
            fail("edit {d}: world A {s}={d}, world B {d}", .{ edit_index, field.name, @field(a, field.name), @field(b, field.name) });
        }
    }
}

var phase: []const u8 = "world A";
var step: []const u8 = "before the mount";

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("sparse-rows fuzz oracle failed ({s}, {s}): " ++ fmt ++ "\n", .{ phase, step } ++ args);
    @panic("sparse-rows fuzz oracle failed");
}
