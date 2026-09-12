//! Model-based fuzzing for selector memberships, keyed selects, and `when`
//! conditions driven by selected values under structural change.
//!
//! # Why this target exists
//!
//! `structural` mounts and edits real element trees, but every `when` it
//! generates reads the root list, and nothing it generates is a selector. The
//! selector registry (`selector_runtime.zig`), the fused keyed-row selector
//! path, the staged-membership commit that PR #120 rewrote for locality, and
//! the adjacency and route edits a structural change makes around surviving
//! selectors were reached only by hand-written specs and unit tests. Those are
//! exhaustive over fault position but fixed in structure; this target
//! generates the structure.
//!
//! # What is generated
//!
//! A program is two state cells - a `List I64` of row keys and a `Str` holding
//! the current selection - wrapping a tree of elements, plus a sequence of
//! edits that publish a new list, a new selection, or both in one transaction.
//!
//! The tree is a `div` whose children are drawn from one grammar at every
//! level: static text, a text node showing the selection itself, a *reader*, a
//! *when*, a wrapper element, or an `each` site. A reader is a `Signal.select`
//! member over the selection cell - true while the selection equals its key -
//! shown either as a `when` between two text nodes or as a `checked` attribute
//! on an element. A when's condition is either a predicate over the list or a
//! select member of its own, and each branch is empty or a wrapper holding more
//! of the same grammar. Rows of an `each` site hold the same grammar again, one
//! level down, where two more choices open up: a key may be the row's own key
//! or a per-row unique key, and a select may be *fused* - a keyed selector
//! whose engine identity is `(site, row handle)` rather than a callable of its
//! own. Sites are shared (rows follow the list cell, re-diffed by every list
//! edit) or constant (a frozen key list), and constant sites nest one level
//! inside rows, so a retiring outer row retires selectors two scopes deep.
//!
//! Keys come from four families so memberships share buckets and split them:
//! four shared names, the numeric row keys, per-instance unique names, and the
//! empty string that selects nothing. A selection edit draws from the same
//! families, so an edit sometimes moves the selection between two populated
//! buckets, sometimes into an empty one, and sometimes nowhere.
//!
//! # Reference model
//!
//! `Model.of(program, state)` walks the tree against one `(list, selection)`
//! pair and derives, from scratch: every text node in document order with the
//! `checked` flag of its parent element; the multiset of live selector
//! *instances* - one per reader or select-conditioned when the current
//! branches and rows show, identified by its spec, its enclosing row keys, its
//! key string and whether it is fused; and the counts of `each` sites, `when`
//! sites, rows and state cells. Two consecutive models give the exact
//! transaction the engine must perform: instances present in both survive,
//! the rest are retired or registered.
//!
//! # Oracles
//!
//!  - **The document reads exactly as the model says.** Text order, parent
//!    `checked` flags, sibling links, child counts, and the absence of
//!    duplicate children, after the mount and every edit.
//!  - **The registry holds exactly the live readers.** Every group input and
//!    every member is a live graph record whose payload names that group and
//!    key; no member appears twice; every select record in the graph is
//!    registered under its key; and the per-key member counts, split by fused
//!    and plain, equal the model's instance multiset. A membership left behind
//!    by a retired row or branch, or staged twice, fails here.
//!  - **Selector work is the changed set.** After every committed edit,
//!    `selector_registrations` and `selector_key_bytes_copied` equal the model's
//!    new instances and their key bytes, `selector_memberships_released` equals
//!    the retired instances, `selector_members_dirtied` equals the members in
//!    the old and new selection buckets when the selection changed, and
//!    `selector_registry_visits` equals the retired instances plus the graph
//!    records the edit appended. That last count is derived from the model:
//!    every appended structure contributes a known number of records. A
//!    restored scan of the surviving registry fails the equality on any input
//!    with survivors.
//!  - **The active signal graph is consistent.** Every record's
//!    `active_graph_id` is its index; every input edge has a back edge in the
//!    slot the dependent recorded, with a lower rank; every dependent edge has
//!    a forward edge; forward and back edge counts agree; every text, bool,
//!    change, and structural route names a descriptor that binds the routed
//!    record; and every structural descriptor's binding is a live record.
//!  - **Every scope site's insertion index is current** (the engine's own
//!    validator).
//!  - **A refused edit publishes nothing**, including staged selector
//!    memberships: the registry, the document, the state cells, the selector
//!    metrics, the closure retain/release balance and the Roc allocation
//!    ledger are all where they were, and the same edit retried on the same
//!    host publishes the model.
//!  - **Nothing leaks; refusals are `OutOfMemory` only.**
//!
//! # Fault placement
//!
//! As in `structural`: every input first runs unfaulted to record the mount's
//! and each edit's allocation-attempt counts, then each count is swept - fully
//! when small, at one input-chosen position otherwise. A swept edit re-mounts
//! and replays the earlier edits unfaulted so the fault lands on the committed
//! topology the model predicts.
//!
//! # Not yet covered
//!
//!  - Selectors over a derived string signal rather than the state cell
//!    itself; the input is always a bare `Ref`.
//!  - Two keyed sites sharing one row (the Roc fixture's `selected` and
//!    `hovered`); every fused select here is its own site.
//!  - In-place row re-collection under a surviving key. Items are keys, so a
//!    surviving row is never rebuilt; `structural` owns that path.
//!
//! To replay a crash:
//!   python3 scripts/fuzz.py repro selectors <crash-file> --verbose

const std = @import("std");
const signals = @import("signals");
const native_host = @import("native_host");
const FuzzReader = @import("FuzzReader.zig");

const fixtures = native_host.fuzz_fixtures;
const abi = signals.abi;
const HostValue = signals.host_values.HostValue;
const FaultAllocator = signals.fault_allocator.FaultAllocator;
const Host = fixtures.Host;
const ValueCapability = fixtures.ValueCapability;
const BinderToken = fixtures.BinderToken;
const Record = signals.signal_records.Record;
const active_graph = signals.active_signal_graph;

const max_children = 10;
const max_row_children = 4;
const max_rows = 5;
const max_site_depth = 2;
const max_wrapper_depth = 2;
const max_edits = 3;
const max_shared_sites = 3;
const shared_key_base: i64 = 100;
const shared_key_limit: i64 = shared_key_base + 3 * max_rows;
const max_full_sweep_attempts = 40;
const shared_keys = [_][]const u8{ "k0", "k1", "k2", "k3" };
const separator_text = "sep";
const hidden_text = "hidden";
/// Graph records one appended structure contributes, as the engine ingests
/// the generated descriptors. A `select` binds its input `Ref` as a record of
/// its own, so a reader is two records; a list predicate `when` is its `map`
/// plus a `Ref`; a selection text node is one `Ref`; a shared `each` site
/// binds the list `Ref` once; a constant `each` - a frozen site or an empty
/// branch - binds one `const_value` record for its items.
const records_per_select = 2;
const records_per_list_when = 2;
const records_per_selected_text = 1;
const records_per_shared_site = 1;
const records_per_constant_site = 1;

/// A predicate over the root list that a generated `when` may ask.
const ListCondition = struct {
    predicate: fixtures.ListPredicate,
    operand: i64,

    fn holds(self: ListCondition, items: []const i64) bool {
        return self.predicate.holds(items, self.operand);
    }
};

/// Where an instance sits: the site and row key of the innermost row, and
/// the key of the outer row when that row is nested. Top-level content has
/// neither.
const Ctx = struct {
    site: u16 = 0,
    row_key: ?i64 = null,
    outer_key: ?i64 = null,
    row_handle: u64 = 0,
};

const KeyKind = enum(u8) { shared, row, unique };

/// Which key a select member registers under, and whether it is a fused
/// keyed-row selector. `row` and `unique` need a row; outside one they fall
/// back to the shared name. A fused select always uses the row key, as the
/// engine requires.
const KeySpec = struct {
    kind: KeyKind,
    shared_index: u8,
    keyed: bool,

    fn string(self: KeySpec, id: u16, ctx: Ctx, buffer: []u8) []const u8 {
        const row_key = ctx.row_key orelse return shared_keys[self.shared_index];
        return switch (self.kind) {
            .shared => shared_keys[self.shared_index],
            .row => std.fmt.bufPrint(buffer, "{d}", .{row_key}) catch unreachable,
            .unique => std.fmt.bufPrint(buffer, "u{d}-{d}", .{ id, row_key }) catch unreachable,
        };
    }

    fn fused(self: KeySpec, ctx: Ctx) bool {
        return self.keyed and ctx.row_key != null;
    }
};

const ReaderForm = enum(u8) { when_text, checked };

const Reader = struct {
    id: u16,
    key: KeySpec,
    form: ReaderForm,
};

const Condition = union(enum) {
    list: ListCondition,
    select: KeySpec,
};

const Branch = union(enum) {
    empty,
    children: []const Child,
};

const WhenSpec = struct {
    id: u16,
    condition: Condition,
    when_true: Branch,
    when_false: Branch,
};

const SiteSpec = struct {
    id: u16,
    row_count: u8,
    depth: u8,
    shared: bool,
    children: []const Child,
};

const Child = union(enum) {
    text,
    /// A text node showing the selection, carrying a generator id so the
    /// model can tell one from another across branch flips.
    selected_text: u16,
    reader: *const Reader,
    when: *const WhenSpec,
    wrapper: []const Child,
    site: *const SiteSpec,
};

const State = struct {
    items: []const i64,
    selected: []const u8,
};

const Edit = struct {
    items: ?[]const i64,
    selected: ?[]const u8,

    fn apply(self: Edit, previous: State) State {
        return .{ .items = self.items orelse previous.items, .selected = self.selected orelse previous.selected };
    }
};

const Program = struct {
    children: []const Child,
    initial: State,
    edits: []const Edit,
    sites: []const *const SiteSpec,
    /// Readers and select-conditioned whens, for unique-key generation.
    select_count: u16,
};

/// One text node the model expects, with the `checked` flag of its parent.
const TextItem = struct {
    text: []const u8,
    checked: bool,
};

const InstanceKind = enum(u8) { select, list_when, selected_text, shared_site, constant_site, empty_branch };

/// One live record-bearing structure the model expects: a selector
/// membership, or a non-selector structure whose graph records an edit
/// appends and retires with it. Identity is the spec, the enclosing row keys
/// and, for selectors, the key and fusion; two consecutive models match
/// instances by identity to derive what an edit created and retired.
const Instance = struct {
    kind: InstanceKind,
    id: u16,
    site: u16,
    row_key: ?i64,
    outer_key: ?i64,
    key: []const u8 = "",
    fused: bool = false,
    records: u8,

    fn same(self: Instance, other: Instance) bool {
        return self.kind == other.kind and self.id == other.id and self.site == other.site and std.meta.eql(self.row_key, other.row_key) and std.meta.eql(self.outer_key, other.outer_key) and self.fused == other.fused and std.mem.eql(u8, self.key, other.key);
    }
};

const Model = struct {
    arena: std.mem.Allocator,
    texts: std.ArrayListUnmanaged(TextItem) = .empty,
    instances: std.ArrayListUnmanaged(Instance) = .empty,
    sites: usize = 0,
    whens: usize = 0,
    rows: usize = 0,
    /// The list and selection cells always exist.
    states: usize = 2,
    /// Selector instances alone, for the registry oracle.
    selectors: usize = 0,

    fn of(arena: std.mem.Allocator, program: Program, state: State) Model {
        var model = Model{ .arena = arena };
        model.children(program.children, state, .{}) catch fail("model arena exhausted", .{});
        return model;
    }

    fn text(self: *Model, comptime fmt: []const u8, args: anytype, checked: bool) !void {
        try self.texts.append(self.arena, .{ .text = try std.fmt.allocPrint(self.arena, fmt, args), .checked = checked });
    }

    fn select(self: *Model, id: u16, spec: KeySpec, state: State, ctx: Ctx) !bool {
        var buffer: [32]u8 = undefined;
        const key = try self.arena.dupe(u8, spec.string(id, ctx, &buffer));
        try self.instances.append(self.arena, .{ .kind = .select, .id = id, .site = ctx.site, .row_key = ctx.row_key, .outer_key = ctx.outer_key, .key = key, .fused = spec.fused(ctx), .records = records_per_select });
        self.selectors += 1;
        return std.mem.eql(u8, key, state.selected);
    }

    fn structure(self: *Model, kind: InstanceKind, id: u16, ctx: Ctx, records: u8) !void {
        try self.instances.append(self.arena, .{ .kind = kind, .id = id, .site = ctx.site, .row_key = ctx.row_key, .outer_key = ctx.outer_key, .records = records });
    }

    fn children(self: *Model, list: []const Child, state: State, ctx: Ctx) error{OutOfMemory}!void {
        for (list) |child| switch (child) {
            .text => try self.text(separator_text, .{}, false),
            .selected_text => |id| {
                try self.structure(.selected_text, id, ctx, records_per_selected_text);
                try self.text("sel-", .{}, false);
                try self.text("{s}", .{state.selected}, false);
            },
            .reader => |reader| {
                var buffer: [32]u8 = undefined;
                const key = reader.key.string(reader.id, ctx, &buffer);
                const on = try self.select(reader.id, reader.key, state, ctx);
                switch (reader.form) {
                    .when_text => {
                        self.whens += 1;
                        try self.text("{s}-{d}-{s}", .{ if (on) "on" else "off", reader.id, key }, false);
                    },
                    .checked => try self.text("chk-{d}-{s}", .{ reader.id, key }, on),
                }
            },
            .when => |when| {
                self.whens += 1;
                const holds = switch (when.condition) {
                    .list => |condition| condition.holds(state.items),
                    .select => |spec| try self.select(when.id, spec, state, ctx),
                };
                if (when.condition == .list) try self.structure(.list_when, when.id, ctx, records_per_list_when);
                switch (if (holds) when.when_true else when.when_false) {
                    .empty => {
                        self.sites += 1;
                        // Both branches of one when may be empty; the id's low
                        // bit tells them apart so a flip between them counts.
                        try self.structure(.empty_branch, when.id * 2 + @intFromBool(holds), ctx, records_per_constant_site);
                    },
                    .children => |nested| try self.children(nested, state, ctx),
                }
            },
            .wrapper => |nested| try self.children(nested, state, ctx),
            .site => |spec| try self.site(spec, state, ctx),
        };
    }

    fn site(self: *Model, spec: *const SiteSpec, state: State, ctx: Ctx) !void {
        self.sites += 1;
        try self.structure(if (spec.shared) .shared_site else .constant_site, spec.id, ctx, if (spec.shared) records_per_shared_site else records_per_constant_site);
        for (0..rowCount(spec, state.items)) |index| {
            const key = rowKey(spec, state.items, index);
            self.rows += 1;
            try self.text("row-{d}-{d}", .{ spec.id, key }, false);
            try self.children(spec.children, state, .{ .site = spec.id, .row_key = key, .outer_key = ctx.row_key });
        }
    }
};

fn rowCount(spec: *const SiteSpec, items: []const i64) usize {
    return if (spec.shared) items.len else spec.row_count;
}

fn rowKey(spec: *const SiteSpec, items: []const i64, index: usize) i64 {
    return if (spec.shared) items[index] else @intCast(index);
}

/// What one edit must do, derived from the models before and after it:
/// instances present in both survive in place, everything else is retired or
/// registered, and the records of the created instances are what the edit
/// appends to the graph.
const Transition = struct {
    registered: u64 = 0,
    key_bytes: u64 = 0,
    released: u64 = 0,
    dirtied: u64 = 0,
    appended_records: u64 = 0,

    fn of(arena: std.mem.Allocator, before: *const Model, after: *const Model, before_state: State, after_state: State) Transition {
        var transition = Transition{};
        const matched = arena.alloc(bool, after.instances.items.len) catch fail("model arena exhausted", .{});
        @memset(matched, false);
        for (before.instances.items) |old| {
            const found = for (after.instances.items, 0..) |new, index| {
                if (!matched[index] and old.same(new)) break index;
            } else null;
            if (found) |index| {
                matched[index] = true;
            } else if (old.kind == .select) {
                transition.released += 1;
            }
        }
        for (after.instances.items, matched) |new, was_matched| {
            if (was_matched) continue;
            transition.appended_records += new.records;
            if (new.kind != .select) continue;
            transition.registered += 1;
            transition.key_bytes += new.key.len;
        }
        if (!std.mem.eql(u8, before_state.selected, after_state.selected)) {
            for (before.instances.items) |old| {
                if (old.kind != .select) continue;
                if (std.mem.eql(u8, old.key, before_state.selected) or std.mem.eql(u8, old.key, after_state.selected)) transition.dirtied += 1;
            }
        }
        return transition;
    }
};

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

    const mount_attempts = run(program, .{ .edit_attempts = edit_attempts, .debug = debug });
    if (debug) {
        std.debug.print("mount attempts: {d}\n", .{mount_attempts});
        for (edit_attempts, 0..) |attempts, index| std.debug.print("edit {d} attempts: {d}\n", .{ index, attempts });
    }

    if (mount_attempts != 0) {
        if (chooseFullSweep(&reader, mount_attempts)) {
            if (debug) std.debug.print("sweeping every mount attempt\n", .{});
            for (1..mount_attempts + 1) |failure_number| _ = run(program, .{ .mount_failure = failure_number });
        } else {
            const failure_number = 1 + reader.intRangeAtMost(usize, 0, mount_attempts - 1);
            if (debug) std.debug.print("injecting mount failure at attempt {d}\n", .{failure_number});
            _ = run(program, .{ .mount_failure = failure_number });
        }
    }

    for (edit_attempts, 0..) |attempts, edit_index| {
        if (attempts == 0) continue;
        if (chooseFullSweep(&reader, attempts)) {
            if (debug) std.debug.print("sweeping every attempt of edit {d}\n", .{edit_index});
            for (1..attempts + 1) |failure_number| {
                _ = run(program, .{ .faulted_edit = edit_index, .edit_failure = failure_number });
            }
        } else {
            const failure_number = 1 + reader.intRangeAtMost(usize, 0, attempts - 1);
            if (debug) std.debug.print("injecting edit {d} failure at attempt {d}\n", .{ edit_index, failure_number });
            _ = run(program, .{ .faulted_edit = edit_index, .edit_failure = failure_number });
        }
    }
}

fn chooseFullSweep(reader: *FuzzReader, attempts: usize) bool {
    return attempts <= max_full_sweep_attempts and reader.boolean();
}

const Generator = struct {
    reader: *FuzzReader,
    arena: std.mem.Allocator,
    shared_budget: usize = max_shared_sites,
    sites: std.ArrayListUnmanaged(*const SiteSpec) = .empty,
    next_select_id: u16 = 0,
    /// Whether the site whose rows are being generated may still take a
    /// fused select. A fused select's identity is `(site, row handle)`, so a
    /// second one in the same row would alias the first; the platform emits
    /// one per `Row.select` site and so does this generator.
    fused_available: bool = false,
};

/// Generation context: whether a row key is available, and how deep sites
/// already nest.
const GenCtx = struct {
    in_row: bool = false,
    site_depth: u8 = 0,
};

fn generate(reader: *FuzzReader, arena: std.mem.Allocator) !Program {
    var generator = Generator{ .reader = reader, .arena = arena };
    const children = try generateChildren(&generator, 0, .{});

    const initial = State{
        .items = try generateList(reader, arena, reader.intRangeAtMost(usize, 0, max_rows)),
        .selected = try generateSelection(&generator),
    };
    const edit_count = reader.intRangeAtMost(u8, 0, max_edits);
    const edits = try arena.alloc(Edit, edit_count);
    for (edits) |*edit| {
        const kind = reader.intRangeAtMost(u8, 0, 2);
        edit.* = .{
            .items = if (kind != 1) try generateList(reader, arena, reader.intRangeAtMost(usize, 0, max_rows)) else null,
            .selected = if (kind != 0) try generateSelection(&generator) else null,
        };
    }
    return .{ .children = children, .initial = initial, .edits = edits, .sites = generator.sites.items, .select_count = generator.next_select_id };
}

/// Builds one strictly increasing key list, then rotates it, so successive
/// lists reorder, replace, grow and shrink without ever repeating a key.
fn generateList(reader: *FuzzReader, arena: std.mem.Allocator, length: usize) ![]const i64 {
    const items = try arena.alloc(i64, length);
    var next: i64 = shared_key_base;
    for (items) |*item| {
        next += 1 + reader.intRangeAtMost(i64, 0, 2);
        item.* = next;
    }
    if (length > 1) {
        const rotation = reader.intRangeAtMost(usize, 0, length - 1);
        if (rotation != 0) std.mem.rotate(i64, items, rotation);
    }
    return items;
}

/// Draws a selection from the same families the keys come from, so it lands
/// on populated buckets about as often as on empty ones.
fn generateSelection(generator: *Generator) ![]const u8 {
    const reader = generator.reader;
    return switch (reader.intRangeAtMost(u8, 0, 4)) {
        0 => "",
        1 => shared_keys[reader.intRangeAtMost(u8, 0, shared_keys.len - 1)],
        2 => try std.fmt.allocPrint(generator.arena, "{d}", .{reader.intRangeAtMost(i64, shared_key_base + 1, shared_key_limit)}),
        3 => try std.fmt.allocPrint(generator.arena, "{d}", .{reader.intRangeAtMost(i64, 0, max_rows - 1)}),
        else => blk: {
            const id = reader.intRangeAtMost(u16, 0, generator.next_select_id);
            const key = if (reader.boolean()) reader.intRangeAtMost(i64, shared_key_base + 1, shared_key_limit) else reader.intRangeAtMost(i64, 0, max_rows - 1);
            break :blk try std.fmt.allocPrint(generator.arena, "u{d}-{d}", .{ id, key });
        },
    };
}

fn generateChildren(generator: *Generator, wrapper_depth: u8, ctx: GenCtx) error{OutOfMemory}![]const Child {
    const reader = generator.reader;
    const limit: u8 = if (wrapper_depth == 0 and !ctx.in_row) max_children else max_row_children;
    const child_count = reader.intRangeAtMost(u8, 0, limit);
    const children = try generator.arena.alloc(Child, child_count);
    for (children) |*child| {
        const choice = reader.intRangeAtMost(u8, 0, 9);
        child.* = switch (choice) {
            0 => .text,
            1 => .{ .selected_text = nextId(generator) },
            2 => if (wrapper_depth + 1 < max_wrapper_depth) .{ .wrapper = try generateChildren(generator, wrapper_depth + 1, ctx) } else .text,
            3, 4 => if (wrapper_depth + 1 < max_wrapper_depth) .{ .when = try generateWhen(generator, wrapper_depth + 1, ctx) } else .{ .reader = try generateReader(generator, ctx) },
            5, 6 => if (ctx.site_depth < max_site_depth) .{ .site = try generateSite(generator, ctx) } else .{ .reader = try generateReader(generator, ctx) },
            else => .{ .reader = try generateReader(generator, ctx) },
        };
    }
    return children;
}

fn nextId(generator: *Generator) u16 {
    const id = generator.next_select_id;
    generator.next_select_id += 1;
    return id;
}

fn generateKeySpec(generator: *Generator, ctx: GenCtx) KeySpec {
    const reader = generator.reader;
    const keyed = ctx.in_row and generator.fused_available and reader.boolean();
    if (keyed) generator.fused_available = false;
    const kind: KeyKind = if (keyed) .row else @enumFromInt(reader.intRangeAtMost(u8, 0, 2));
    return .{ .kind = kind, .shared_index = reader.intRangeAtMost(u8, 0, shared_keys.len - 1), .keyed = keyed };
}

fn generateReader(generator: *Generator, ctx: GenCtx) !*const Reader {
    const spec = try generator.arena.create(Reader);
    spec.* = .{
        .id = generator.next_select_id,
        .key = generateKeySpec(generator, ctx),
        .form = @enumFromInt(generator.reader.intRangeAtMost(u8, 0, 1)),
    };
    generator.next_select_id += 1;
    return spec;
}

fn generateWhen(generator: *Generator, wrapper_depth: u8, ctx: GenCtx) error{OutOfMemory}!*const WhenSpec {
    const reader = generator.reader;
    const spec = try generator.arena.create(WhenSpec);
    const id = generator.next_select_id;
    generator.next_select_id += 1;
    spec.* = .{
        .id = id,
        .condition = if (reader.boolean())
            .{ .select = generateKeySpec(generator, ctx) }
        else
            .{ .list = generateListCondition(reader) },
        .when_true = try generateBranch(generator, wrapper_depth, ctx),
        .when_false = try generateBranch(generator, wrapper_depth, ctx),
    };
    return spec;
}

fn generateBranch(generator: *Generator, wrapper_depth: u8, ctx: GenCtx) error{OutOfMemory}!Branch {
    if (generator.reader.intRangeAtMost(u8, 0, 2) == 0) return .empty;
    return .{ .children = try generateChildren(generator, wrapper_depth, ctx) };
}

fn generateListCondition(reader: *FuzzReader) ListCondition {
    return if (reader.boolean())
        .{ .predicate = .length_at_least, .operand = reader.intRangeAtMost(i64, 0, max_rows + 1) }
    else
        .{ .predicate = .contains, .operand = reader.intRangeAtMost(i64, shared_key_base + 1, shared_key_limit) };
}

fn generateSite(generator: *Generator, ctx: GenCtx) error{OutOfMemory}!*const SiteSpec {
    const reader = generator.reader;
    const spec = try generator.arena.create(SiteSpec);
    const shared = !ctx.in_row and generator.shared_budget != 0 and reader.boolean();
    if (shared) generator.shared_budget -= 1;
    spec.* = .{
        .id = std.math.cast(u16, generator.sites.items.len) orelse return error.OutOfMemory,
        .row_count = reader.intRangeAtMost(u8, 0, max_rows),
        .depth = ctx.site_depth,
        .shared = shared,
        .children = &.{},
    };
    try generator.sites.append(generator.arena, spec);
    const outer_fused_available = generator.fused_available;
    generator.fused_available = true;
    spec.children = try generateChildren(generator, 1, .{ .in_row = true, .site_depth = ctx.site_depth + 1 });
    generator.fused_available = outer_fused_available;
    return spec;
}

fn printProgram(program: Program) void {
    std.debug.print("program: {d} top-level children, {d} sites, {d} selects, {d} edits\n", .{ program.children.len, program.sites.len, program.select_count, program.edits.len });
    printState("initial", program.initial);
    var state = program.initial;
    for (program.edits, 0..) |edit, index| {
        state = edit.apply(state);
        std.debug.print("  edit[{d}]{s}{s}: ", .{ index, if (edit.items != null) " list" else "", if (edit.selected != null) " selection" else "" });
        printState("", state);
    }
    printChildren(program.children, 1);
}

fn printState(name: []const u8, state: State) void {
    std.debug.print("  {s} selected='{s}' items=", .{ name, state.selected });
    for (state.items) |item| std.debug.print(" {d}", .{item});
    std.debug.print("\n", .{});
}

fn printKey(spec: KeySpec) void {
    std.debug.print("{t}", .{spec.kind});
    if (spec.kind == .shared) std.debug.print("({s})", .{shared_keys[spec.shared_index]});
    if (spec.keyed) std.debug.print(" fused", .{});
}

fn printChildren(children: []const Child, indent: usize) void {
    for (children, 0..) |child, index| {
        for (0..indent) |_| std.debug.print("  ", .{});
        switch (child) {
            .text => std.debug.print("[{d}] text\n", .{index}),
            .selected_text => |id| std.debug.print("[{d}] selected text#{d}\n", .{ index, id }),
            .reader => |reader| {
                std.debug.print("[{d}] reader#{d} {t} key=", .{ index, reader.id, reader.form });
                printKey(reader.key);
                std.debug.print("\n", .{});
            },
            .wrapper => |nested| {
                std.debug.print("[{d}] wrapper\n", .{index});
                printChildren(nested, indent + 1);
            },
            .when => |when| {
                std.debug.print("[{d}] when#{d} ", .{ index, when.id });
                switch (when.condition) {
                    .list => |condition| switch (condition.predicate) {
                        .length_at_least => std.debug.print("length>={d}", .{condition.operand}),
                        .contains => std.debug.print("contains {d}", .{condition.operand}),
                    },
                    .select => |spec| {
                        std.debug.print("select key=", .{});
                        printKey(spec);
                    },
                }
                std.debug.print("\n", .{});
                printBranch("true", when.when_true, indent + 1);
                printBranch("false", when.when_false, indent + 1);
            },
            .site => |spec| {
                std.debug.print("[{d}] each#{d} shared={} rows={d}\n", .{ index, spec.id, spec.shared, spec.row_count });
                printChildren(spec.children, indent + 1);
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

const Plan = struct {
    mount_failure: ?usize = null,
    faulted_edit: ?usize = null,
    edit_failure: ?usize = null,
    edit_attempts: ?[]usize = null,
    debug: bool = false,
};

/// Everything a row builder needs that lives for one host: the two state
/// cells' tokens and capabilities, and one identity callable per site for
/// fused selects.
const RunEnv = struct {
    list_token: BinderToken,
    list_cap: ValueCapability,
    selected_token: BinderToken,
    selected_cap: ValueCapability,
    keyed_sites: []abi.RocErasedCallable,
};

const RowCapture = extern struct {
    spec: *const SiteSpec,
    env: *const RunEnv,
};

/// Mounts the program on a fresh host and replays its edits under `plan`,
/// returning the mount's preparation attempt count.
fn run(program: Program, plan: Plan) usize {
    var host = fixtures.createHost();
    var roc_host = fixtures.bindHost(&host);
    host.engine.roc_host = &roc_host;
    defer if (fixtures.destroyHost(&host)) fail("host allocator leaked", .{});

    var keyed_sites: [64]abi.RocErasedCallable = undefined;
    if (program.sites.len > keyed_sites.len) fail("program generated more sites than the run can hold", .{});
    for (keyed_sites[0..program.sites.len]) |*site| site.* = fixtures.keyedSelectSite(&roc_host);
    defer for (keyed_sites[0..program.sites.len]) |site| fixtures.decrefCallable(site, &roc_host);

    const env = RunEnv{
        .list_token = fixtures.newBinderToken(&roc_host),
        .list_cap = fixtures.valueCapability(&roc_host),
        .selected_token = fixtures.newBinderToken(&roc_host),
        .selected_cap = fixtures.valueCapability(&roc_host),
        .keyed_sites = keyed_sites[0..program.sites.len],
    };
    const root = buildRoot(program, &roc_host, &env);
    defer root.decref(&roc_host);
    const refs_before = host.roc_allocations.snapshot();

    var fault = FaultAllocator.init(host.gpa.allocator());
    host.engine_allocator_override = fault.allocator();

    fault.configure(plan.mount_failure);
    phase = if (plan.mount_failure != null) "faulted mount" else "unfaulted mount";
    const result = fixtures.renderInitialRootWithArmedPublication(&host, &roc_host, root, &fault);
    const attempts = fault.attempts;

    if (plan.mount_failure) |number| {
        expectRefusal(result, "mount", number);
        expectUnpublished(&host, number);
        if (host.engine.pending_roc_metrics.closure_retains != host.engine.pending_roc_metrics.closure_releases) {
            fail("refusal at attempt {d} left closure retains unbalanced", .{number});
        }
        if (host.roc_allocations.liveCountSince(refs_before) != 0 or host.roc_allocations.snapshot().live_bytes != refs_before.live_bytes) {
            fail("refusal at attempt {d} leaked Roc allocations", .{number});
        }

        fault.configure(null);
        phase = "mount retried after a refusal";
        _ = fixtures.renderInitialRootWithArmedPublication(&host, &roc_host, root, &fault) catch |err| {
            fail("retry after refusal at attempt {d} failed: {t}", .{ number, err });
        };
        expectPublished(&host, program, program.initial);
        return attempts;
    }

    _ = result catch |err| fail("unfaulted mount failed: {t}", .{err});
    expectPublished(&host, program, program.initial);
    runEdits(&host, &roc_host, program, plan, &fault, &env);
    return attempts;
}

const SelectorMetrics = struct {
    visits: u64,
    registrations: u64,
    key_bytes: u64,
    released: u64,
    dirtied: u64,

    fn read(host: *const Host) SelectorMetrics {
        const metrics = fixtures.runtimeMetrics(host);
        return .{
            .visits = metrics.selector_registry_visits,
            .registrations = metrics.selector_registrations,
            .key_bytes = metrics.selector_key_bytes_copied,
            .released = metrics.selector_memberships_released,
            .dirtied = metrics.selector_members_dirtied,
        };
    }

    fn since(self: SelectorMetrics, before: SelectorMetrics) SelectorMetrics {
        return .{
            .visits = self.visits - before.visits,
            .registrations = self.registrations - before.registrations,
            .key_bytes = self.key_bytes - before.key_bytes,
            .released = self.released - before.released,
            .dirtied = self.dirtied - before.dirtied,
        };
    }
};

fn runEdits(host: *Host, roc_host: *abi.RocHost, program: Program, plan: Plan, fault: *FaultAllocator, env: *const RunEnv) void {
    if (program.edits.len == 0) return;
    const cells = stateNodeIds(host);

    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var state = program.initial;
    for (program.edits, 0..) |edit, edit_index| {
        const previous = state;
        state = edit.apply(previous);
        const faulted = plan.edit_failure != null and plan.faulted_edit != null and plan.faulted_edit.? == edit_index;

        const allocations_before = host.roc_allocations.snapshot();
        const retains_before = host.engine.pending_roc_metrics.closure_retains;
        const releases_before = host.engine.pending_roc_metrics.closure_releases;
        const list_before = fixtures.stateValue(host, cells.list);
        const selected_before = fixtures.stateValue(host, cells.selected);
        const members_before = host.engine.selectors.memberCount();
        const metrics_before = SelectorMetrics.read(host);

        fault.configure(if (faulted) plan.edit_failure else null);
        phase = if (faulted) "faulted edit" else "unfaulted edit";
        const dispatch = dispatchEdit(host, roc_host, cells, edit, env);
        if (plan.edit_attempts) |slots| slots[edit_index] = fault.attempts;

        if (faulted) {
            const number = plan.edit_failure.?;
            expectRefusal(dispatch, "edit", number);
            expectPublished(host, program, previous);
            if (host.engine.selectors.memberCount() != members_before) {
                fail("edit {d} refused at attempt {d} but changed the selector registry from {d} to {d} members", .{ edit_index, number, members_before, host.engine.selectors.memberCount() });
            }
            const metrics = SelectorMetrics.read(host).since(metrics_before);
            if (metrics.visits != 0 or metrics.registrations != 0 or metrics.key_bytes != 0 or metrics.released != 0 or metrics.dirtied != 0) {
                fail("edit {d} refused at attempt {d} but reported selector work: {any}", .{ edit_index, number, metrics });
            }
            if (fixtures.stateValue(host, cells.list) != list_before or fixtures.stateValue(host, cells.selected) != selected_before) {
                fail("edit {d} refused at attempt {d} but replaced a state cell value", .{ edit_index, number });
            }
            const retains = host.engine.pending_roc_metrics.closure_retains - retains_before;
            const releases = host.engine.pending_roc_metrics.closure_releases - releases_before;
            if (retains != releases) {
                fail("edit {d} refused at attempt {d} left {d} retains against {d} releases", .{ edit_index, number, retains, releases });
            }
            if (host.roc_allocations.liveCountSince(allocations_before) != 0 or host.roc_allocations.snapshot().live_bytes != allocations_before.live_bytes) {
                fail("edit {d} refused at attempt {d} leaked Roc allocations", .{ edit_index, number });
            }

            fault.configure(null);
            phase = "edit retried after a refusal";
            _ = dispatchEdit(host, roc_host, cells, edit, env) catch |err| {
                fail("retry of edit {d} after refusal at attempt {d} failed: {t}", .{ edit_index, number, err });
            };
        } else {
            _ = dispatch catch |err| fail("unfaulted edit {d} failed: {t}", .{ edit_index, err });
        }

        expectPublished(host, program, state);
        const before_model = Model.of(arena, program, previous);
        const after_model = Model.of(arena, program, state);
        const expected = Transition.of(arena, &before_model, &after_model, previous, state);
        const actual = SelectorMetrics.read(host).since(metrics_before);
        if (plan.debug) std.debug.print("edit {d}: expected {any}, actual {any}\n", .{ edit_index, expected, actual });
        if (actual.registrations != expected.registered) fail("edit {d} registered {d} selector memberships, model expects {d}", .{ edit_index, actual.registrations, expected.registered });
        if (actual.key_bytes != expected.key_bytes) fail("edit {d} copied {d} selector key bytes, model expects {d}", .{ edit_index, actual.key_bytes, expected.key_bytes });
        if (actual.released != expected.released) fail("edit {d} released {d} selector memberships, model expects {d}", .{ edit_index, actual.released, expected.released });
        if (actual.dirtied != expected.dirtied) fail("edit {d} dirtied {d} selector members, model expects {d}", .{ edit_index, actual.dirtied, expected.dirtied });
        if (actual.visits != expected.released + expected.appended_records) fail("edit {d} visited {d} registry records, model expects {d} released plus {d} appended", .{ edit_index, actual.visits, expected.released, expected.appended_records });
    }
}

const Cells = struct { list: u64, selected: u64 };

/// The node ids of the two state cells. Collection walks the root first, so
/// the list cell is the first scope site and the selection cell the second;
/// asserting their kinds keeps a change in collection order from silently
/// retargeting the edits.
fn stateNodeIds(host: *const Host) Cells {
    const sites = host.engine.active_stream.scope_sites.items;
    if (sites.len < 2) fail("mount published {d} scope sites, so the state cells are missing", .{sites.len});
    if (sites[0].kind != .state or sites[1].kind != .state) fail("the first two published scope sites are not the state cells", .{});
    return .{ .list = sites[0].node_id.raw(), .selected = sites[1].node_id.raw() };
}

fn dispatchEdit(host: *Host, roc_host: *abi.RocHost, cells: Cells, edit: Edit, env: *const RunEnv) fixtures.NativeEngine.CollectionError!fixtures.RenderCounts {
    if (edit.items != null and edit.selected != null) {
        const writes = [_]fixtures.StateWrite{
            .{ .state_id = cells.list, .value = listValue(roc_host, edit.items.?), .cap = env.list_cap },
            .{ .state_id = cells.selected, .value = fixtures.strValue(roc_host, edit.selected.?), .cap = env.selected_cap },
        };
        return fixtures.dispatchStateWrites(host, roc_host, &writes);
    }
    if (edit.items) |items| return fixtures.dispatchStateValue(host, roc_host, cells.list, listValue(roc_host, items), env.list_cap);
    return fixtures.dispatchStateValue(host, roc_host, cells.selected, fixtures.strValue(roc_host, edit.selected.?), env.selected_cap);
}

fn expectRefusal(result: anytype, comptime what: []const u8, failure_number: usize) void {
    if (result) |_| {
        fail(what ++ " with failure at attempt {d} did not refuse", .{failure_number});
    } else |err| if (err != error.OutOfMemory) {
        fail(what ++ " with failure at attempt {d} was refused as {t}, not an allocation failure", .{ failure_number, err });
    }
}

fn listValue(roc_host: *abi.RocHost, items: []const i64) HostValue {
    var values: [max_rows]HostValue = undefined;
    for (items, 0..) |item, index| values[index] = fixtures.i64Value(item);
    return fixtures.i64ListValue(roc_host, values[0..items.len]);
}

fn buildRoot(program: Program, roc_host: *abi.RocHost, env: *const RunEnv) abi.Elem {
    const body = buildChildren(program.children, roc_host, env, .{});
    const selected = fixtures.stateWithTokenInitialAndCapability(roc_host, env.selected_token, fixtures.strValue(roc_host, program.initial.selected), body, env.selected_cap);
    return fixtures.stateWithTokenInitialAndCapability(roc_host, env.list_token, listValue(roc_host, program.initial.items), selected, env.list_cap);
}

fn selectExpr(spec: KeySpec, id: u16, roc_host: *abi.RocHost, env: *const RunEnv, ctx: Ctx) abi.NodeSignalExpr {
    var buffer: [32]u8 = undefined;
    const key = spec.string(id, ctx, &buffer);
    const input = fixtures.refExpr(env.selected_token);
    if (spec.fused(ctx)) return fixtures.keyedSelectExpr(roc_host, env.keyed_sites[ctx.site], ctx.row_handle, input, env.selected_cap, key);
    return fixtures.selectExpr(roc_host, input, env.selected_cap, key);
}

fn buildChildren(children: []const Child, roc_host: *abi.RocHost, env: *const RunEnv, ctx: Ctx) abi.Elem {
    var built: [max_children]abi.Elem = undefined;
    for (children, 0..) |child, index| {
        built[index] = switch (child) {
            .text => fixtures.text(roc_host, separator_text),
            .selected_text => blk: {
                const shown = fixtures.textSignalWithCapability(roc_host, fixtures.refExpr(env.selected_token), env.selected_cap);
                break :blk fixtures.elementWith(roc_host, "span", &.{}, &.{ fixtures.text(roc_host, "sel-"), shown });
            },
            .reader => |reader| buildReader(reader, roc_host, env, ctx),
            .when => |when| blk: {
                const condition = switch (when.condition) {
                    .list => |condition| fixtures.listPredicateExpr(roc_host, fixtures.refExpr(env.list_token), condition.predicate, condition.operand),
                    .select => |spec| selectExpr(spec, when.id, roc_host, env, ctx),
                };
                break :blk fixtures.whenWithSignal(roc_host, condition, buildBranch(when.when_true, roc_host, env, ctx), buildBranch(when.when_false, roc_host, env, ctx));
            },
            .wrapper => |nested| buildChildren(nested, roc_host, env, ctx),
            .site => |spec| buildSite(spec, roc_host, env),
        };
    }
    return fixtures.elementWith(roc_host, "div", &.{}, built[0..children.len]);
}

fn buildReader(reader: *const Reader, roc_host: *abi.RocHost, env: *const RunEnv, ctx: Ctx) abi.Elem {
    var key_buffer: [32]u8 = undefined;
    const key = reader.key.string(reader.id, ctx, &key_buffer);
    const select = selectExpr(reader.key, reader.id, roc_host, env, ctx);
    var buffer: [64]u8 = undefined;
    switch (reader.form) {
        .when_text => {
            var other: [64]u8 = undefined;
            const on = std.fmt.bufPrint(&buffer, "on-{d}-{s}", .{ reader.id, key }) catch unreachable;
            const off = std.fmt.bufPrint(&other, "off-{d}-{s}", .{ reader.id, key }) catch unreachable;
            return fixtures.whenWithSignal(roc_host, select, fixtures.text(roc_host, on), fixtures.text(roc_host, off));
        },
        .checked => {
            const label = std.fmt.bufPrint(&buffer, "chk-{d}-{s}", .{ reader.id, key }) catch unreachable;
            const attrs = [_]abi.NodeAttr{fixtures.signalBoolAttr(roc_host, .checked, select)};
            return fixtures.elementWith(roc_host, "span", &attrs, &.{fixtures.text(roc_host, label)});
        },
    }
}

fn buildBranch(branch: Branch, roc_host: *abi.RocHost, env: *const RunEnv, ctx: Ctx) abi.Elem {
    return switch (branch) {
        .empty => fixtures.emptyEach(roc_host),
        .children => |nested| buildChildren(nested, roc_host, env, ctx),
    };
}

fn buildSite(spec: *const SiteSpec, roc_host: *abi.RocHost, env: *const RunEnv) abi.Elem {
    const capture = RowCapture{ .spec = spec, .env = env };
    if (spec.shared) {
        return fixtures.eachOverStateListKeyOfRowAndCapture(RowCapture, roc_host, env.list_token, env.list_cap, &fixtures.bucketKeyCallable, .{ .amount = 1 }, &rowCallable, capture);
    }
    var items: [max_rows]HostValue = undefined;
    for (items[0..spec.row_count], 0..) |*item, index| item.* = fixtures.i64Value(@intCast(index));
    return fixtures.eachWithItemsRowAndCapture(RowCapture, roc_host, items[0..spec.row_count], &rowCallable, capture);
}

/// Builds one row: its label, then the site's generated children with the
/// row's key and handle in scope. The outer key is not needed to build, only
/// to model, so the build context carries the innermost row alone.
fn rowCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const capture = fixtures.captureAs(RowCapture, capture_ptr);
    const spec = capture.spec;
    const row_handle = fixtures.eachRowHandle(args);
    const key = fixtures.eachRowKeyI64(roc_host, args);
    const ctx = Ctx{ .site = spec.id, .row_key = key, .row_handle = row_handle };
    var buffer: [32]u8 = undefined;
    const label = std.fmt.bufPrint(&buffer, "row-{d}-{d}", .{ spec.id, key }) catch unreachable;
    const body = buildChildren(spec.children, roc_host, capture.env, ctx);
    const children = [_]abi.Elem{ fixtures.text(roc_host, label), body };
    fixtures.writeResult(abi.Elem, ret, fixtures.elementWith(roc_host, "div", &.{}, &children));
}

fn expectUnpublished(host: *const Host, failure_number: usize) void {
    const engine = &host.engine;
    const counts = [_]struct { name: []const u8, len: usize }{
        .{ .name = "scopes", .len = engine.scopes.items.len },
        .{ .name = "node identities", .len = engine.node_identities.items.len },
        .{ .name = "dom identities", .len = engine.dom_identities.items.len },
        .{ .name = "states", .len = engine.states.items.len },
        .{ .name = "each row sites", .len = engine.each_row_sites.items.len },
        .{ .name = "active render nodes", .len = engine.active_stream.render_nodes.items.len },
        .{ .name = "active eaches", .len = engine.active_stream.eaches.items.len },
        .{ .name = "active whens", .len = engine.active_stream.whens.items.len },
        .{ .name = "active signal graph", .len = engine.active_signal_graph.items.len },
        .{ .name = "selector memberships", .len = engine.selectors.memberCount() },
        .{ .name = "selector groups", .len = engine.selectors.groups.count() },
        .{ .name = "dom elements", .len = host.dom_elements.items.len },
    };
    for (counts) |count| {
        if (count.len != 0) fail("refusal at attempt {d} published {d} {s}", .{ failure_number, count.len, count.name });
    }
    if (engine.render_cache.hasRoot()) fail("refusal at attempt {d} published a render root", .{failure_number});
}

fn expectPublished(host: *const Host, program: Program, state: State) void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = Model.of(arena, program, state);

    const engine = &host.engine;
    if (!engine.render_cache.hasRoot()) fail("no render root is committed", .{});
    if (engine.each_row_sites.items.len != model.sites) fail("engine owns {d} each sites, model expects {d}", .{ engine.each_row_sites.items.len, model.sites });
    if (engine.active_stream.eaches.items.len != model.sites) fail("active stream holds {d} each descriptors, model expects {d}", .{ engine.active_stream.eaches.items.len, model.sites });
    if (engine.active_stream.whens.items.len != model.whens) fail("active stream holds {d} when descriptors, model expects {d}", .{ engine.active_stream.whens.items.len, model.whens });
    var rows: usize = 0;
    for (engine.each_row_sites.items) |site| rows += site.scope_ids.items.len;
    if (rows != model.rows) fail("engine owns {d} each rows, model expects {d}", .{ rows, model.rows });
    if (engine.states.items.len != model.states) fail("engine owns {d} states, model expects {d}", .{ engine.states.items.len, model.states });

    expectDocument(host, arena, &model);
    expectRegistry(host, arena, &model);
    expectGraphConsistent(host);
    host.engine.validateActiveScopeSiteInsertIndexes();
}

/// Asserts the committed render tree reads exactly as the model does, text by
/// text and parent `checked` flag by flag, with consistent sibling links and
/// no parent holding a child twice.
fn expectDocument(host: *const Host, arena: std.mem.Allocator, model: *const Model) void {
    var actual: std.ArrayListUnmanaged(TextItem) = .empty;
    if (host.engine.render_cache.nodes.items[fixtures.render_root.index()].parent_id != null) fail("committed render root has a parent", .{});
    collectRenderTexts(host, arena, &actual, fixtures.render_root) catch fail("oracle arena exhausted", .{});
    const expected = model.texts.items;
    const mismatch = for (0..@min(expected.len, actual.items.len)) |index| {
        if (!std.mem.eql(u8, expected[index].text, actual.items[index].text) or expected[index].checked != actual.items[index].checked) break index;
    } else if (expected.len != actual.items.len) @min(expected.len, actual.items.len) else return;
    std.debug.print("expected document:", .{});
    for (expected) |item| std.debug.print(" {s}{s}", .{ item.text, if (item.checked) "*" else "" });
    std.debug.print("\nactual document:  ", .{});
    for (actual.items) |item| std.debug.print(" {s}{s}", .{ item.text, if (item.checked) "*" else "" });
    std.debug.print("\n", .{});
    fail("render tree diverges from the model at text {d}", .{mismatch});
}

fn collectRenderTexts(host: *const Host, arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(TextItem), parent: signals.ids.ElemId) error{OutOfMemory}!void {
    const children = fixtures.publishedChildren(host, parent);
    const cache = &host.engine.render_cache;
    if (cache.childCount(parent) != children.len) fail("published parent {d} child count differs from committed topology", .{parent.raw()});
    var sibling = cache.firstChild(parent);
    var previous: ?signals.ids.ElemId = null;
    for (children, 0..) |child_raw, index| {
        const child = signals.ids.ElemId.fromRaw(child_raw);
        if (sibling != child) fail("published parent {d} child {d} differs from committed sibling order at {d}", .{ parent.raw(), child_raw, index });
        if (cache.previousSibling(child) != previous) fail("child {d} has an inconsistent previous sibling", .{child_raw});
        if (cache.nodes.items[child.index()].parent_id != parent) fail("child {d} has an inconsistent render parent", .{child_raw});
        if (host.dom_elements.items[child.index()].parent_id != parent.raw()) fail("child {d} has an inconsistent published parent", .{child_raw});
        for (children[index + 1 ..]) |other| {
            if (child_raw == other) fail("render parent {d} holds child {d} more than once", .{ parent.raw(), child_raw });
        }
        if (fixtures.renderText(host, child)) |text| {
            try out.append(arena, .{ .text = text, .checked = host.dom_elements.items[parent.index()].checked });
        }
        try collectRenderTexts(host, arena, out, child);
        previous = child;
        sibling = cache.nextSibling(child);
    }
    if (sibling != null) fail("parent {d} has committed siblings beyond its published child list", .{parent.raw()});
    if (cache.nodes.items[parent.index()].last_child != previous) fail("parent {d} has an inconsistent final sibling", .{parent.raw()});
}

/// The registry oracle: every group, bucket and member is live and
/// self-consistent, every select record in the graph is registered, and the
/// per-key counts equal the model's instance multiset.
fn expectRegistry(host: *const Host, arena: std.mem.Allocator, model: *const Model) void {
    const registry = &host.engine.selectors;
    const nodes = host.engine.active_signal_graph.items;
    const Count = struct { plain: usize = 0, fused: usize = 0 };
    var actual: std.StringHashMapUnmanaged(Count) = .empty;
    var total: usize = 0;

    var groups = registry.groups.iterator();
    while (groups.next()) |group| {
        const input = group.key_ptr.*;
        expectLiveRecord(nodes, input, "selector group input");
        var buckets = group.value_ptr.members_by_key.iterator();
        while (buckets.next()) |bucket| {
            const key = bucket.key_ptr.*;
            const members = bucket.value_ptr.items;
            if (members.len == 0) fail("selector registry holds an empty bucket for key '{s}'", .{key});
            const count = actual.getOrPut(arena, key) catch fail("oracle arena exhausted", .{});
            if (!count.found_existing) count.value_ptr.* = .{};
            for (members, 0..) |member, index| {
                expectLiveRecord(nodes, member, "selector member");
                for (members[index + 1 ..]) |other| if (other == member) fail("selector member is registered twice under key '{s}'", .{key});
                const payload = switch (member.payload) {
                    .select => |payload| blk: {
                        count.value_ptr.plain += 1;
                        break :blk payload;
                    },
                    .keyed_select => |payload| blk: {
                        count.value_ptr.fused += 1;
                        break :blk payload;
                    },
                    else => fail("selector member under key '{s}' is not a select record", .{key}),
                };
                if (payload.input != input) fail("selector member under key '{s}' reads a different input than its group", .{key});
                if (!std.mem.eql(u8, payload.key, key)) fail("selector member registered under key '{s}' carries key '{s}'", .{ key, payload.key });
                total += 1;
            }
        }
    }
    if (total != registry.memberCount()) fail("selector registry counts {d} members but holds {d}", .{ registry.memberCount(), total });

    for (nodes) |node| switch (node.record.payload) {
        .select, .keyed_select => |payload| {
            const members = registry.membersForKey(payload.input, payload.key);
            const registered = for (members) |member| {
                if (member == node.record) break true;
            } else false;
            if (!registered) fail("live select record with key '{s}' is not registered", .{payload.key});
        },
        else => {},
    };

    var expected: std.StringHashMapUnmanaged(Count) = .empty;
    for (model.instances.items) |instance| {
        if (instance.kind != .select) continue;
        const count = expected.getOrPut(arena, instance.key) catch fail("oracle arena exhausted", .{});
        if (!count.found_existing) count.value_ptr.* = .{};
        if (instance.fused) count.value_ptr.fused += 1 else count.value_ptr.plain += 1;
    }
    if (total != model.selectors) fail("selector registry holds {d} members, model expects {d}", .{ total, model.selectors });
    var expected_entries = expected.iterator();
    while (expected_entries.next()) |entry| {
        const found = actual.get(entry.key_ptr.*) orelse fail("selector key '{s}' has no members, model expects {d} plain and {d} fused", .{ entry.key_ptr.*, entry.value_ptr.plain, entry.value_ptr.fused });
        if (found.plain != entry.value_ptr.plain or found.fused != entry.value_ptr.fused) {
            fail("selector key '{s}' has {d} plain and {d} fused members, model expects {d} and {d}", .{ entry.key_ptr.*, found.plain, found.fused, entry.value_ptr.plain, entry.value_ptr.fused });
        }
    }
    var actual_entries = actual.iterator();
    while (actual_entries.next()) |entry| {
        if (!expected.contains(entry.key_ptr.*)) fail("selector key '{s}' has {d} members the model does not expect", .{ entry.key_ptr.*, entry.value_ptr.plain + entry.value_ptr.fused });
    }
}

fn expectLiveRecord(nodes: []const active_graph.Node(Record), record: *const Record, comptime what: []const u8) void {
    const id = record.active_graph_id orelse fail(what ++ " is not in the active signal graph", .{});
    if (id >= nodes.len or nodes[@intCast(id)].record != record) fail(what ++ " names graph id {d}, which holds a different record", .{id});
}

/// The adjacency and route oracle described at the top of the file.
fn expectGraphConsistent(host: *const Host) void {
    const engine = &host.engine;
    const nodes = engine.active_signal_graph.items;
    var forward: usize = 0;
    var backward: usize = 0;
    for (nodes, 0..) |node, id| {
        if (node.record.active_graph_id != id) fail("graph node {d} holds a record that names id {?d}", .{ id, node.record.active_graph_id });
        var inputs = active_graph.DistinctInputIterator(Record).init(node.record);
        while (inputs.next()) |input| {
            const input_id = input.record.active_graph_id orelse fail("graph node {d} reads a record outside the graph", .{id});
            if (input_id >= nodes.len) fail("graph node {d} reads graph id {d} beyond the graph", .{ id, input_id });
            if (nodes[@intCast(input_id)].rank >= node.rank) fail("graph node {d} at rank {d} reads node {d} at rank {d}", .{ id, node.rank, input_id, nodes[@intCast(input_id)].rank });
            const slot = node.input_slots.get(input.position);
            const dependents = nodes[@intCast(input_id)].dependents.slice();
            if (slot >= dependents.len or dependents[slot] != id) fail("graph node {d} recorded slot {d} on input {d}, which does not hold it", .{ id, slot, input_id });
            backward += 1;
        }
        for (node.dependents.slice()) |dependent_id| {
            if (dependent_id >= nodes.len) fail("graph node {d} lists dependent {d} beyond the graph", .{ id, dependent_id });
            var reads = active_graph.DistinctInputIterator(Record).init(nodes[@intCast(dependent_id)].record);
            const found = while (reads.next()) |input| {
                if (input.record == node.record) break true;
            } else false;
            if (!found) fail("graph node {d} lists dependent {d}, which does not read it", .{ id, dependent_id });
            forward += 1;
        }
    }
    if (forward != backward) fail("graph holds {d} dependent edges against {d} input edges", .{ forward, backward });

    const stream = &engine.active_stream;
    expectRouteTable(active_graph.TextSink, engine.active_text_signal_routes.items, nodes, stream, "text");
    expectRouteTable(active_graph.BoolSink, engine.active_bool_signal_routes.items, nodes, stream, "bool");
    expectRouteTable(active_graph.ChangeSink, engine.active_change_signal_routes.items, nodes, stream, "change");
    expectRouteTable(active_graph.StructuralSink, engine.active_structural_signal_routes.items, nodes, stream, "structural");
    for (stream.whens.items, 0..) |when, index| expectRouted(nodes, engine.active_structural_signal_routes.items, when.condition.record, .{ .structural = .{ .kind = .when, .index = index } });
    for (stream.eaches.items, 0..) |each, index| expectRouted(nodes, engine.active_structural_signal_routes.items, each.items.record, .{ .structural = .{ .kind = .each, .index = index } });
    for (stream.signal_bool_attrs.items, 0..) |attr, index| expectRouted(nodes, engine.active_bool_signal_routes.items, attr.signal.record, .{ .bool_attr = .{ .kind = .bool_attr, .index = index } });
    for (stream.signal_text_nodes.items, 0..) |node, index| expectRouted(nodes, engine.active_text_signal_routes.items, node.signal.record, .{ .text = .{ .kind = .text_node, .index = index } });
}

const RouteRef = union(enum) {
    structural: active_graph.StructuralSink,
    bool_attr: active_graph.BoolSink,
    text: active_graph.TextSink,
};

/// Asserts the descriptor binding `record` is routed back to it: the record is
/// live and its route list holds exactly one entry naming that descriptor.
fn expectRouted(nodes: []const active_graph.Node(Record), routes: anytype, record: *const Record, expected: RouteRef) void {
    expectLiveRecord(nodes, record, "structural or sink descriptor binding");
    const id: usize = @intCast(record.active_graph_id.?);
    if (id >= routes.len) fail("record {d} binds a descriptor but has no route list", .{id});
    var matches: usize = 0;
    for (routes[id].slice()) |route| {
        const same = switch (expected) {
            inline else => |sink| @TypeOf(route) == @TypeOf(sink) and route.kind == sink.kind and route.index == sink.index,
        };
        matches += @intFromBool(same);
    }
    if (matches != 1) fail("record {d} has {d} routes to its descriptor, expected exactly one", .{ id, matches });
}

fn expectRouteTable(comptime Route: type, routes: []const active_graph.SmallRouteList(Route), nodes: []const active_graph.Node(Record), stream: anytype, comptime what: []const u8) void {
    if (routes.len > nodes.len) fail(what ++ " route table has {d} entries for {d} graph nodes", .{ routes.len, nodes.len });
    for (routes, 0..) |list, record_id| {
        for (list.slice()) |route| {
            const bound: *const Record = switch (Route) {
                active_graph.StructuralSink => switch (route.kind) {
                    .when => (indexed(stream.whens.items, route.index, what) orelse continue).condition.record,
                    .each => (indexed(stream.eaches.items, route.index, what) orelse continue).items.record,
                },
                active_graph.BoolSink => switch (route.kind) {
                    .bool_attr => (indexed(stream.signal_bool_attrs.items, route.index, what) orelse continue).signal.record,
                    .custom_bool_attr => (indexed(stream.signal_custom_bool_attrs.items, route.index, what) orelse continue).signal.record,
                },
                active_graph.TextSink => switch (route.kind) {
                    .text_node => (indexed(stream.signal_text_nodes.items, route.index, what) orelse continue).signal.record,
                    .text_attr => (indexed(stream.signal_text_attrs.items, route.index, what) orelse continue).signal.record,
                    .custom_text_attr => (indexed(stream.signal_custom_text_attrs.items, route.index, what) orelse continue).signal.record,
                    .custom_text_optional_attr => (indexed(stream.signal_optional_custom_text_attrs.items, route.index, what) orelse continue).signal.record,
                },
                active_graph.ChangeSink => (indexed(stream.on_changes.items, route.index, what) orelse continue).signal.record,
                else => @compileError("unknown route type"),
            };
            if (bound != nodes[record_id].record) fail(what ++ " route from record {d} names a descriptor bound to another record", .{record_id});
        }
    }
}

/// Bounds-checks a route index; a route past its descriptor array is a
/// failure rather than a skipped entry.
fn indexed(items: anytype, index: usize, comptime what: []const u8) ?@TypeOf(&items[0]) {
    if (index >= items.len) fail(what ++ " route names descriptor {d} of {d}", .{ index, items.len });
    return &items[index];
}

var phase: []const u8 = "before the mount";

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("selectors fuzz oracle failed ({s}): " ++ fmt ++ "\n", .{phase} ++ args);
    @panic("selectors fuzz oracle failed");
}
