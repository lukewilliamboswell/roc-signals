//! Model-based fuzzing for structural transaction atomicity under allocation failure.
//!
//! # Why this target exists
//!
//! design.md, "Memory management and allocation failure", states the
//! verification principle as *exhaustive fault placement*: a representative
//! transaction records its successful allocation-attempt count, then runs with
//! attempt `N` and every later attempt failing, for every `N` from one to that
//! count. Each outcome must match its declared recoverable or fatal boundary and
//! prove no leaks, double release, partial publication, or invalid reuse.
//!
//! The repository already does this well for *hand-written* transactions - there
//! are sweeps in `render_commands.zig`, `render_cache.zig`, `scope_runtime.zig`,
//! `engine.zig`, and `native_host.zig`. This target does not replace them and
//! should not try to. What it adds is the other axis: those sweeps are exhaustive
//! over fault position but fixed in structure, so a fault landing between two
//! particular phases is only ever tested against the structures someone wrote
//! down. Here the structure is generated, and the fault sweep runs over each one.
//! Fault position x generated structure is the product neither approach covers
//! alone.
//!
//! Two bugs shaped the generator. The first (issue #22) was a root with several
//! sibling initial `each` sites trapping at commit, because every site reserved
//! one engine slot against a length that does not move until publication; two
//! sites passed, since `ensureUnusedCapacity(1)` leaves slack, so the trap needed
//! a site count nobody had written down. The second was the first *live*
//! transaction after such a mount: sibling sites sitting under distinct render
//! parents made the composite downstream suppress only one parent, so the
//! structural pass and `prepareFinalRenderTopology` both registered the same
//! parent on one splice and `PreparedRenderSplice.addChildren` rejected the
//! duplicate. Both shapes are ordinary points in this generator's space.
//!
//! Generating `when` flips found three more on its first runs, all in the
//! staging paths only hand-written tests had covered: content collected by a
//! flip or a re-diff read the list the transaction was retiring rather than
//! the one it published, two adjacent when rows flipping together scanned
//! their retired branches as one interval, and two reordered surviving rows
//! that both held a flipping when were each handed the other's region by the
//! render layout.
//!
//! # What is generated
//!
//! A program is a root state cell holding a list of `i64` items, wrapping a tree
//! of elements, plus a sequence of replacement item lists to publish into that
//! cell after the mount.
//!
//! The element tree is a `div` whose children are a mix of static text, `each`
//! sites, `when` sites, and nested wrapper elements holding more of the same.
//! Every wrapper also carries six custom attributes. Nested builders reserve
//! their descriptors before the parent's remaining descriptors are collected,
//! so attributes exercise outstanding reservations across those boundaries.
//! The oracle checks their publication alongside topology and ownership.
//! Wrappers matter: they are what puts sibling sites under *distinct render
//! parents*, which is the shape the multi-parent suppression bug needed.
//!
//! A `when` site's condition is a predicate over the list in the root state
//! cell - `length >= N` or `contains K` - so the edits that re-diff the each
//! sites flip its branch in the same transaction. Each branch is either
//! **empty**, an `each` over a frozen empty list that renders no DOM node yet
//! still registers a scope site at the branch's index, or a wrapper holding
//! more generated children, sites included. That gives every combination the
//! staging paths distinguish: a flip alone, a flip beside each growth, shrink,
//! or reorder under the same or another parent, an empty branch replaced by
//! content and content replaced by nothing, a when nested in a flipping
//! branch (subsumed by the outer flip), and a shared each inside a branch
//! that is disposed or instantiated by the flip that also re-diffs it.
//!
//! An `each` site is either **constant** - its own frozen item list, with its own
//! generated row count - or **shared**, reading the root state cell directly
//! through a bare `Ref` as its items signal. Every shared site therefore
//! re-diffs its rows inside the single transaction one state dispatch opens, so
//! one edit can splice several sites under several parents at once. A program holds at most
//! `max_shared_sites` of them, and any number of those may share one parent;
//! that bound is a generator budget rather than an engine limit.
//!
//! Every site has a row kind that decides what a row renders: plain text, a
//! state cell, a `when` branch, or a nested constant `each` site with its own
//! generated shape. A `when` row's condition is a list predicate like a
//! top-level when's, read through the same root cell from inside the row
//! scope, so one edit flips a when in every row of every site at once -
//! surviving rows of a re-diffed shared site included. Nesting is bounded at
//! two levels, wrappers at two levels.
//!
//! A shared item is `key * key_stride + version`: the row's key is the item's
//! bucket and the version is the part an edit may change under the same key.
//! Generated key lists are strictly increasing before an optional rotation, so
//! no site ever carries a duplicate key: that is a Roc-side diagnostic and
//! terminates the host, not something to fuzz here. Constant sites key rows
//! from a low range and shared sites from a high one, and every site carries
//! a generator-assigned id in its labels, so a label names exactly one row of
//! one site. A surviving key whose version changed is a row the engine
//! re-collects in place, and a `nested_each` row renders its inner site from
//! that version - one row more when it is odd, rotated by it - so such a
//! re-collection carries nested rows that survive, reorder, grow, or shrink
//! under it, which the engine must reconcile by key rather than re-mount.
//!
//! The row callable receives its `SiteSpec` through the erased-callable capture,
//! which is how the engine ends up asking the generated program what to render
//! for each row without the harness knowing when it will be asked.
//!
//! Edits are drawn as fresh strictly-increasing key lists of independently
//! chosen length, each key with a fresh version, with an optional rotation, so
//! successive lists exercise reorder, replacement, growth, shrink, and in-place
//! re-collection - across every shared site at once, since they all read the
//! same cell.
//!
//! # Reference model
//!
//! `Expected.of(program, items)` walks the generated element tree against one
//! item list and derives the committed topology from scratch: which branch
//! every when shows, how many each sites the engine must own (including nested
//! ones instantiated once per outer row, so a shared outer site's site count
//! moves with the list, and the empty each an empty branch registers), how
//! many when sites, how many row scopes they hold in total, and how many state
//! cells exist - one for the root cell plus one per stateful row. The visible
//! label set is derived the same way, every label a site could show but the
//! current list or branch selection omits is modelled as *absent* from the
//! DOM, and the whole document's text nodes are derived in document order.
//!
//! The model is a pure function of the shape and the current list, so one oracle
//! judges the mount, every committed edit, and the state left behind by a refused
//! edit.
//!
//! # Oracles
//!
//!  - **Published topology matches the model, at the mount and after every
//!    edit.** Site count, total row count, state count, and the descriptor
//!    stream's `eaches` and `whens` all equal the derived totals; every
//!    modelled row label is an active DOM text node; every label the model
//!    hides - a retired key, a when row whose predicate fails, a site in the
//!    branch a when no longer shows - is gone.
//!  - **The render tree reads in document order.** The committed render cache
//!    is walked from its root and the text it holds must equal the model's
//!    text sequence exactly, so a branch or row spliced under the right parent
//!    at the wrong index is caught even though every count and label agrees.
//!    That is the shape a when flipping from an empty branch used to produce:
//!    the structural pass anchored new children where the retired branch's
//!    children stood, and a branch with none was appended after its siblings.
//!  - **No render parent holds a child twice.** Every parent the walk visits is
//!    checked for duplicate children, which is where a splice that registered
//!    one parent through two staging passes shows up and where no count-based
//!    oracle would notice.
//!  - **Every scope site's insertion index is current.** After the mount and
//!    every edit, each `each` site's `render_insert_index` must be the render
//!    index of its first row and each `when` site's that of its live branch.
//!    The engine checks this itself at every structural commit; the oracle
//!    repeats it because a stale index is invisible to every other check until
//!    the *next* transaction lays rows out from it and is refused.
//!  - **A refused mount publishes nothing.** After an injected preparation
//!    failure the engine's scopes, identities, states, row sites, active stream,
//!    event table, signal graph, render cache, and simulated DOM are all empty,
//!    the closure retain/release counters balance, and the Roc allocation ledger
//!    holds nothing allocated since the root was built.
//!  - **A refused edit changes nothing.** The full model oracle is re-run against
//!    the *previous* list, the state cell still holds its previous value, the
//!    closure retain/release delta across the refusal is zero, and the Roc
//!    allocation ledger is back where it started - the refused transaction owns
//!    and releases the item list it was handed.
//!  - **The engine is still usable.** Disarming the fault and retrying the same
//!    root, or the same edit, *on the same host* must publish the full model
//!    topology.
//!  - **Publication never allocates.** For the mount, commit and teardown run
//!    with the fault armed on the very next attempt, so an allocation there is a
//!    panic rather than a refusal. For an edit, whose prepare/commit split is
//!    private to the engine, the sweep proves the same thing indirectly: every
//!    attempt in `1..attempts` must produce a *refusal*, and an attempt landing
//!    in commit or teardown could not, because preparation would already have
//!    succeeded.
//!  - **Nothing leaks.** The host's safety-checked debug allocator reports a leak
//!    on teardown as a failure.
//!  - **Refusals are `OutOfMemory` only.** No other `CollectionError` is an
//!    acceptable answer to an injected allocation failure, and each one names a
//!    different contract the generator did not break: `ResourceLimit` means a
//!    configured budget or arithmetic bound rejected a transaction built inside
//!    its limits, `InvalidScope` means a scope or identity was unknown,
//!    inactive, or already claimed, `InvalidDescriptor` means staging assumed a
//!    descriptor, node, state cell, or site the committed stream does not hold,
//!    `OverlappingRemoval` means two removals claimed the same interval or
//!    subtree, `InvalidRenderTopology` means the staged render topology
//!    disagreed with the committed tree, and `InvalidSignalGraphAppend` /
//!    `InvalidSignalGraphRelease` mean a staged graph edit disagreed with the
//!    committed signal graph. All are oracle failures, and `expectRefusal`
//!    rejects them generically so a newly added variant is caught rather than
//!    silently accepted.
//!
//! # Fault placement
//!
//! Every input first runs unfaulted, which records the mount's preparation
//! attempt count and each edit's transaction attempt count. Each of those counts
//! is then swept independently: when the count is small the whole `1..count`
//! sweep runs, otherwise the input selects one attempt and coverage guidance
//! spreads the choice. A swept edit re-mounts and replays the earlier edits
//! unfaulted first, so the fault always lands on a transaction whose starting
//! state is the committed topology the model predicts. Faults are injected
//! through the host's engine allocator override, the same seam the hand-written
//! native sweeps use.
//!
//! # Seams
//!
//! The mount is `PreparedRootCollection.prepare` -> `PreparedRootDownstream.prepare`
//! -> `commit` -> `runLifecycle` -> `deinit`. Each live edit is
//! `HostEngine.tryDispatchStateValue`, the same entry a browser event takes. Both
//! run through `native_host.fuzz_fixtures`, which also supplies the element,
//! state-cell, capability, and keyed-list fixtures and the render-cache and
//! state-cell readers the oracles need.
//!
//! Two properties of `FaultAllocator` shape the model. It is *sticky*: attempt
//! `N` and every later attempt fail until reconfigured, so it cannot express
//! "fail once, then succeed" - and `configure` resets `attempts`. `free` never
//! counts and never fails, which is what makes teardown guaranteed
//! allocation-failure-free.
//!
//! # Not yet covered
//!
//! No shape is withheld because the engine cannot survive it; every gap below
//! is simply unwritten. Shared sites used to read the state cell through a
//! `Signal.map` copy because a bare `Ref` items signal terminated the staged
//! initial mount; that is fixed and the bare `Ref` is now what is generated.
//!
//!  - **`when` conditions on anything but the root list.** Every generated when
//!    reads the one shared cell, so a flip is always caused by the edit that
//!    also re-diffs the shared sites. A when driven by a row's own state cell
//!    would flip without any each re-diffing in the same transaction.
//!  - **`ResourceLimit` rejection through `collection_budget` bounds.** The
//!    generator stays inside every configured bound, so the limit-before-
//!    allocation path is asserted never to fire rather than exercised. Reaching
//!    it needs generated programs that deliberately exceed a lowered budget, and
//!    a model that predicts *which* bound rejects them.
//!  - **Non-state transaction sources.** Events, timers, and task results enter
//!    through the same propagation model but a different entry point, and none of
//!    them is generated here.
//!
//! To replay a crash:
//!   python3 scripts/fuzz.py repro structural <crash-file> --verbose

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

const max_children = 24;
const max_rows = 6;
const max_depth = 2;
const max_wrapper_depth = 2;
const max_edits = 3;
/// Sibling sites one dispatch may re-diff. Two is the smallest count that
/// reaches the multi-parent composite splice this target exists to cover.
const max_shared_sites = 4;
/// Keys a shared site's rows start from. Constant sites key from zero, so a label
/// always says which list produced it and an "absent" assertion about a retired
/// shared key cannot be satisfied by an unrelated constant row.
const shared_key_base: i64 = 100;
/// Full sweeps are quadratic in the attempt count, so past this bound one attempt
/// per input keeps the fuzzer fast and lets coverage pick the position.
const max_full_sweep_attempts = 40;
/// Largest key `generateList` can produce: `max_rows` steps of at most three
/// above `shared_key_base`. A `contains` operand is drawn from this range so it
/// is sometimes present and sometimes not.
const shared_key_limit: i64 = shared_key_base + 3 * max_rows;
/// Versions one shared key can carry: a shared item is `key * key_stride +
/// version`, and shared sites key rows by that bucket, so an edit that keeps a
/// key but changes its version re-collects the row in place.
const key_stride: i64 = 4;

const RowKind = enum(u8) {
    text,
    stateful,
    when,
    nested_each,
};

/// A predicate over the root list that a generated `when` condition asks.
const WhenCondition = struct {
    predicate: fixtures.ListPredicate,
    operand: i64,

    fn holds(self: WhenCondition, items: []const i64) bool {
        return self.predicate.holds(items, self.operand);
    }
};

const SiteSpec = struct {
    /// Generator-assigned identity, part of every row label this site renders.
    id: u16,
    /// Row count for a constant site. Shared sites take their count from the item
    /// list the root state cell currently holds.
    row_count: u8,
    row_kind: RowKind,
    depth: u8,
    /// Rows come from the root state signal rather than a frozen list, so this
    /// site re-diffs inside every live edit.
    shared: bool,
    /// The condition every row's `when` asks when `row_kind` is `when`.
    condition: WhenCondition,
    /// The site every row instantiates when `row_kind` is `nested_each`.
    inner: ?*const SiteSpec,
};

/// What one side of a generated `when` renders.
const Branch = union(enum) {
    /// An `each` over a frozen empty list: a scope site with no DOM node.
    empty,
    /// A wrapper element holding more generated children.
    children: []const Child,
};

const WhenSpec = struct {
    condition: WhenCondition,
    when_true: Branch,
    when_false: Branch,

    fn selected(self: *const WhenSpec, items: []const i64) Branch {
        return if (self.condition.holds(items)) self.when_true else self.when_false;
    }
};

const Child = union(enum) {
    text,
    site: *const SiteSpec,
    /// A generated wrapper element, which gives the sites beneath it a render
    /// parent of their own.
    wrapper: []const Child,
    /// A `when` whose branch follows the root list.
    when: *const WhenSpec,
};

const Program = struct {
    children: []const Child,
    /// Item lists the root state cell holds over time. Index zero is the mount;
    /// each later entry is one live edit.
    lists: []const []const i64,
    /// Every site the program can instantiate, in generation order, so an
    /// oracle can ask about a site whichever branch or row it lives in.
    sites: []const *const SiteSpec,
};

/// The shared state cell a `Ref`-driven site binds to.
const SharedSource = struct {
    token: BinderToken,
    cap: ValueCapability,
};

/// Capture handed to every generated row callable. The shared source is what
/// lets a row's own `when` read the root cell from inside the row scope; it
/// outlives every callable because `run` owns it for the whole host.
const RowCapture = extern struct {
    spec: *const SiteSpec,
    shared: *const SharedSource,
};

const Expected = struct {
    sites: usize = 0,
    whens: usize = 0,
    rows: usize = 0,
    /// The root state cell always exists, so the model starts at one.
    states: usize = 1,

    fn of(program: Program, items: []const i64) Expected {
        var expected = Expected{};
        expected.addChildren(program.children, items);
        return expected;
    }

    fn addChildren(self: *Expected, children: []const Child, items: []const i64) void {
        for (children) |child| switch (child) {
            .text => {},
            .site => |spec| self.addSite(spec, items),
            .wrapper => |nested| self.addChildren(nested, items),
            .when => |when| {
                self.whens += 1;
                switch (when.selected(items)) {
                    .empty => self.sites += 1,
                    .children => |nested| self.addChildren(nested, items),
                }
            },
        };
    }

    fn addSite(self: *Expected, spec: *const SiteSpec, items: []const i64) void {
        self.sites += 1;
        if (spec.shared) {
            for (items) |item| self.addRow(spec, rowVersion(spec, item));
        } else {
            for (0..spec.row_count) |_| self.addRow(spec, 0);
        }
    }

    /// Adds one row of `spec` rendered at `version`, and whatever the row
    /// instantiates: a constant inner site sized and ordered by the version.
    fn addRow(self: *Expected, spec: *const SiteSpec, version: i64) void {
        self.rows += 1;
        switch (spec.row_kind) {
            .text => {},
            .when => self.whens += 1,
            .stateful => self.states += 1,
            .nested_each => {
                const inner = spec.inner.?;
                self.sites += 1;
                for (0..innerRowCount(inner, version)) |_| self.addRow(inner, 0);
            },
        }
    }
};

fn rowCount(spec: *const SiteSpec, items: []const i64) usize {
    return if (spec.shared) items.len else spec.row_count;
}

/// The key of row `index` of `spec` under `items`: shared sites render the
/// list's key buckets in its order, constant sites count from zero.
fn rowKey(spec: *const SiteSpec, items: []const i64, index: usize) i64 {
    return if (spec.shared) @divTrunc(items[index], key_stride) else @intCast(index);
}

/// Stable structural seed for a shared row.
///
/// A keyed row builder runs once for the row identity, so nested structure
/// created directly by that builder may depend on the key but not on later
/// item-only changes. Item-dependent structure belongs behind `Row.signal` in
/// the ordinary reactive graph and is covered by the semantic row tests.
fn rowVersion(spec: *const SiteSpec, item: i64) i64 {
    return if (spec.shared) @divTrunc(item, key_stride) else 0;
}

/// Rows the constant inner site `inner` renders under an outer row at
/// `version`: its own count, plus one when the version is odd.
fn innerRowCount(inner: *const SiteSpec, version: i64) usize {
    const grown: usize = inner.row_count + @as(usize, @intCast(@mod(version, 2)));
    return @min(grown, max_rows);
}

/// The keys of the constant inner site `inner` under an outer row at
/// `version`, in render order: `0..count`, rotated by the version.
fn innerRowKeys(inner: *const SiteSpec, version: i64, buffer: *[max_rows]i64) []const i64 {
    const count = innerRowCount(inner, version);
    for (buffer[0..count], 0..) |*key, index| key.* = @intCast(index);
    if (count > 1) {
        const rotation: usize = @intCast(@mod(version, @as(i64, @intCast(count))));
        if (rotation != 0) std.mem.rotate(i64, buffer[0..count], rotation);
    }
    return buffer[0..count];
}

/// Appends the text every DOM text node under `children` shows, in document
/// order, as the render tree must read after publication.
fn modelTexts(out: *std.ArrayListUnmanaged([]const u8), arena: std.mem.Allocator, children: []const Child, items: []const i64) error{OutOfMemory}!void {
    for (children) |child| switch (child) {
        .text => try out.append(arena, separator_text),
        .site => |spec| try modelSiteTexts(out, arena, spec, items),
        .wrapper => |nested| try modelTexts(out, arena, nested, items),
        .when => |when| switch (when.selected(items)) {
            .empty => {},
            .children => |nested| try modelTexts(out, arena, nested, items),
        },
    };
}

fn modelSiteTexts(out: *std.ArrayListUnmanaged([]const u8), arena: std.mem.Allocator, spec: *const SiteSpec, items: []const i64) error{OutOfMemory}!void {
    for (0..rowCount(spec, items)) |index| {
        const label = try ownedRowLabel(arena, spec, rowKey(spec, items, index));
        switch (spec.row_kind) {
            .text, .stateful => try out.append(arena, label),
            .when => try out.append(arena, if (spec.condition.holds(items)) label else hidden_text),
            .nested_each => {
                try out.append(arena, label);
                const inner = spec.inner.?;
                var keys: [max_rows]i64 = undefined;
                const version = if (spec.shared) rowVersion(spec, items[index]) else 0;
                for (innerRowKeys(inner, version, &keys)) |key| {
                    const inner_label = try ownedRowLabel(arena, inner, key);
                    try out.append(arena, if (inner.row_kind == .when and !inner.condition.holds(items)) hidden_text else inner_label);
                }
            },
        }
    }
}

const separator_text = "separator";
const hidden_text = "hidden";

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

    const edit_attempts = arena.alloc(usize, program.lists.len - 1) catch fail("program arena exhausted", .{});
    @memset(edit_attempts, 0);

    const mount_attempts = run(program, .{ .edit_attempts = edit_attempts });
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

/// Decides whether one transaction gets an exhaustive fault sweep.
///
/// A whole sweep costs one full mount-and-replay per attempt, so it is affordable
/// only for short transactions. Past the bound the input picks a single position
/// instead and AFL++'s coverage feedback is what spreads the choice across runs.
fn chooseFullSweep(reader: *FuzzReader, attempts: usize) bool {
    return attempts <= max_full_sweep_attempts and reader.boolean();
}

/// Generator state threaded through the element tree.
const Generator = struct {
    reader: *FuzzReader,
    arena: std.mem.Allocator,
    shared_budget: usize = max_shared_sites,
    sites: std.ArrayListUnmanaged(*const SiteSpec) = .empty,
};

fn generate(reader: *FuzzReader, arena: std.mem.Allocator) !Program {
    var generator = Generator{ .reader = reader, .arena = arena };
    const children = try generateChildren(&generator, 0);

    const list_count = 1 + @as(usize, reader.intRangeAtMost(u8, 0, max_edits));
    const lists = try arena.alloc([]const i64, list_count);
    for (lists) |*list| list.* = try generateList(reader, arena, reader.intRangeAtMost(usize, 0, max_rows));
    return .{ .children = children, .lists = lists, .sites = generator.sites.items };
}

/// Builds one strictly increasing key list, gives every key a version, then
/// rotates it.
///
/// Increasing keys keep every key in a list distinct, which is a hard contract
/// rather than a fuzzing dimension: duplicate keys are a Roc-side diagnostic that
/// terminates the host. The rotation is what turns an otherwise monotonically
/// ordered list into a genuine reorder for the row differ, and a version drawn
/// afresh per list is what makes a surviving key an in-place re-collection.
fn generateList(reader: *FuzzReader, arena: std.mem.Allocator, length: usize) ![]const i64 {
    const items = try arena.alloc(i64, length);
    var next: i64 = shared_key_base;
    for (items) |*item| {
        next += 1 + reader.intRangeAtMost(i64, 0, 2);
        item.* = next * key_stride + reader.intRangeAtMost(i64, 0, key_stride - 1);
    }
    if (length > 1) {
        const rotation = reader.intRangeAtMost(usize, 0, length - 1);
        if (rotation != 0) std.mem.rotate(i64, items, rotation);
    }
    return items;
}

/// Generates the children of one element: text, each sites, wrapper elements
/// and whens, the last two nesting more of the same one level down. Shared
/// sites are drawn wherever they fall until the program's budget is spent, so
/// they land under one parent, under several, and inside when branches.
fn generateChildren(generator: *Generator, wrapper_depth: u8) error{OutOfMemory}![]const Child {
    const reader = generator.reader;
    const limit: u8 = if (wrapper_depth == 0) max_children else 4;
    const child_count = reader.intRangeAtMost(u8, 0, limit);
    const children = try generator.arena.alloc(Child, child_count);
    for (children) |*child| {
        const choice = reader.intRangeAtMost(u8, 0, 6);
        child.* = if (choice == 0)
            .text
        else if (choice == 1 and wrapper_depth + 1 < max_wrapper_depth)
            .{ .wrapper = try generateChildren(generator, wrapper_depth + 1) }
        else if (choice == 2 and wrapper_depth + 1 < max_wrapper_depth)
            .{ .when = try generateWhen(generator, wrapper_depth + 1) }
        else
            .{ .site = try generateSite(generator, 0, generator.shared_budget != 0) };
        switch (child.*) {
            .site => |spec| if (spec.shared) {
                generator.shared_budget -= 1;
            },
            else => {},
        }
    }
    return children;
}

/// Generates a `when` whose branches sit at `wrapper_depth`: a branch with
/// content is a wrapper element, so it counts as one wrapper level.
fn generateWhen(generator: *Generator, wrapper_depth: u8) error{OutOfMemory}!*const WhenSpec {
    const spec = try generator.arena.create(WhenSpec);
    spec.* = .{
        .condition = generateCondition(generator.reader),
        .when_true = try generateBranch(generator, wrapper_depth),
        .when_false = try generateBranch(generator, wrapper_depth),
    };
    return spec;
}

fn generateBranch(generator: *Generator, wrapper_depth: u8) error{OutOfMemory}!Branch {
    if (generator.reader.intRangeAtMost(u8, 0, 2) == 0) return .empty;
    return .{ .children = try generateChildren(generator, wrapper_depth) };
}

/// Draws a predicate whose truth moves with the generated lists: a length bound
/// inside the list-length range, or a key inside the shared key range.
fn generateCondition(reader: *FuzzReader) WhenCondition {
    return if (reader.boolean())
        .{ .predicate = .length_at_least, .operand = reader.intRangeAtMost(i64, 0, max_rows + 1) }
    else
        .{ .predicate = .contains, .operand = reader.intRangeAtMost(i64, shared_key_base + 1, shared_key_limit) * key_stride + reader.intRangeAtMost(i64, 0, key_stride - 1) };
}

fn generateSite(generator: *Generator, depth: u8, allow_shared: bool) error{OutOfMemory}!*const SiteSpec {
    const reader = generator.reader;
    const spec = try generator.arena.create(SiteSpec);
    var kind: RowKind = @enumFromInt(reader.intRangeAtMost(u8, 0, 3));
    if (kind == .nested_each and depth + 1 >= max_depth) kind = .stateful;
    // Only top-level sites read the shared cell: a nested site is instantiated
    // once per outer row, and pointing every one of them at the same signal
    // would multiply row counts rather than add coverage.
    const shared = depth == 0 and allow_shared and reader.boolean();
    spec.* = .{
        .id = std.math.cast(u16, generator.sites.items.len) orelse return error.OutOfMemory,
        .row_count = reader.intRangeAtMost(u8, 0, max_rows),
        .row_kind = kind,
        .depth = depth,
        .shared = shared,
        .condition = generateCondition(reader),
        .inner = null,
    };
    try generator.sites.append(generator.arena, spec);
    if (kind == .nested_each) spec.inner = try generateSite(generator, depth + 1, false);
    return spec;
}

fn countSharedSites(program: Program) usize {
    var count: usize = 0;
    for (program.sites) |spec| count += @intFromBool(spec.shared);
    return count;
}

fn printProgram(program: Program) void {
    std.debug.print("program: {d} top-level children, {d} sites, {d} shared\n", .{ program.children.len, program.sites.len, countSharedSites(program) });
    for (program.lists, 0..) |list, index| {
        std.debug.print("  list[{d}] len={d}:", .{ index, list.len });
        for (list) |item| std.debug.print(" {d}v{d}", .{ @divTrunc(item, key_stride), @mod(item, key_stride) });
        const expected = Expected.of(program, list);
        std.debug.print(" -> sites={d} whens={d} rows={d} states={d}\n", .{ expected.sites, expected.whens, expected.rows, expected.states });
    }
    printChildren(program.children, 1);
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
                std.debug.print("[{d}] each#{d} shared={} rows={d} kind={t}", .{ index, spec.id, spec.shared, spec.row_count, spec.row_kind });
                if (spec.row_kind == .when) {
                    std.debug.print(" ", .{});
                    printCondition(spec.condition);
                }
                std.debug.print("\n", .{});
                if (spec.inner) |inner| {
                    for (0..indent + 1) |_| std.debug.print("  ", .{});
                    std.debug.print("inner each#{d} rows={d} kind={t}\n", .{ inner.id, inner.row_count, inner.row_kind });
                }
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

/// One faulted run of a generated program: which transaction to break, and where.
const Plan = struct {
    /// Preparation attempt to fail during the initial mount. When set, the run
    /// stops after proving the mount recovered; edits belong to their own runs.
    mount_failure: ?usize = null,
    /// Index into `program.lists[1..]` of the edit to break.
    faulted_edit: ?usize = null,
    edit_failure: ?usize = null,
    /// Filled with each edit's transaction attempt count on an unfaulted run.
    edit_attempts: ?[]usize = null,
};

/// Mounts the program on a fresh host and replays its edits under `plan`,
/// returning the mount's preparation attempt count.
fn run(program: Program, plan: Plan) usize {
    var host = fixtures.createHost();
    var roc_host = fixtures.bindHost(&host);
    host.engine.roc_host = &roc_host;
    defer if (fixtures.destroyHost(&host)) fail("host allocator leaked", .{});

    const shared = SharedSource{
        .token = fixtures.newBinderToken(&roc_host),
        .cap = fixtures.valueCapability(&roc_host),
    };
    const root = buildRoot(program, &roc_host, &shared);
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
        expectPublished(&host, program, program.lists[0]);
        return attempts;
    }

    _ = result catch |err| fail("unfaulted mount failed: {t}", .{err});
    expectPublished(&host, program, program.lists[0]);
    runEdits(&host, &roc_host, program, plan, &fault, shared.cap);
    return attempts;
}

/// Publishes every generated item list into the live root state cell in turn,
/// applying `plan`'s injected failure to one of them.
fn runEdits(host: *Host, roc_host: *abi.RocHost, program: Program, plan: Plan, fault: *FaultAllocator, cap: ValueCapability) void {
    if (program.lists.len < 2) return;
    const state_node_id = rootStateNodeId(host);

    for (program.lists[1..], 0..) |next_list, edit_index| {
        const previous = program.lists[edit_index];
        const faulted = plan.edit_failure != null and plan.faulted_edit != null and plan.faulted_edit.? == edit_index;

        const allocations_before = host.roc_allocations.snapshot();
        const retains_before = host.engine.pending_roc_metrics.closure_retains;
        const releases_before = host.engine.pending_roc_metrics.closure_releases;
        const value_before = fixtures.stateValue(host, state_node_id);

        fault.configure(if (faulted) plan.edit_failure else null);
        phase = if (faulted) "faulted edit" else "unfaulted edit";
        const dispatch = fixtures.dispatchStateValue(host, roc_host, state_node_id, listValue(roc_host, next_list), cap);
        if (plan.edit_attempts) |slots| slots[edit_index] = fault.attempts;

        if (faulted) {
            const number = plan.edit_failure.?;
            expectRefusal(dispatch, "edit", number);
            // A refused edit must leave exactly the topology the previous list
            // models, down to the visible labels.
            expectPublished(host, program, previous);
            if (fixtures.stateValue(host, state_node_id) != value_before) {
                fail("edit {d} refused at attempt {d} but replaced the state cell value", .{ edit_index, number });
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
            _ = fixtures.dispatchStateValue(host, roc_host, state_node_id, listValue(roc_host, next_list), cap) catch |err| {
                fail("retry of edit {d} after refusal at attempt {d} failed: {t}", .{ edit_index, number, err });
            };
        } else {
            _ = dispatch catch |err| fail("unfaulted edit {d} failed: {t}", .{ edit_index, err });
        }

        expectPublished(host, program, next_list);
    }
}

/// Reports the node id of the root state cell every generated program wraps.
///
/// Collection walks the root Elem first, so the root cell is the first scope site
/// in the committed stream; stateful rows contribute later ones. Asserting the
/// kind keeps a change in collection order from silently retargeting the edits at
/// a row's cell instead of the shared one.
fn rootStateNodeId(host: *const Host) u64 {
    const sites = host.engine.active_stream.scope_sites.items;
    if (sites.len == 0) fail("mount published no scope sites, so there is no root state cell", .{});
    if (sites[0].kind != .state) fail("first published scope site is {t}, not the root state cell", .{sites[0].kind});
    return sites[0].node_id.raw();
}

/// Asserts an injected allocation failure was refused, and refused honestly.
///
/// `OutOfMemory` is the only answer a fault sweep may accept. Every other
/// `CollectionError` describes a contract the generator did not break -
/// `ResourceLimit` means a configured bound rejected a program built inside its
/// limits, and the `Invalid*` variants mean staging disagreed with the committed
/// tree - so those are staging bugs to report, never acceptable refusals.
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

fn buildRoot(program: Program, roc_host: *abi.RocHost, shared: *const SharedSource) abi.Elem {
    const body = buildChildren(program.children, roc_host, shared);
    return fixtures.stateWithTokenInitialAndCapability(roc_host, shared.token, listValue(roc_host, program.lists[0]), body, shared.cap);
}

fn buildChildren(children: []const Child, roc_host: *abi.RocHost, shared: *const SharedSource) abi.Elem {
    var built: [max_children]abi.Elem = undefined;
    for (children, 0..) |child, index| {
        built[index] = switch (child) {
            .text => fixtures.text(roc_host, separator_text),
            .site => |spec| buildSite(spec, roc_host, shared, 0),
            .wrapper => |nested| buildChildren(nested, roc_host, shared),
            .when => |when| fixtures.whenOnListPredicate(roc_host, shared.token, when.condition.predicate, when.condition.operand, buildBranch(when.when_true, roc_host, shared), buildBranch(when.when_false, roc_host, shared)),
        };
    }
    return attributedElement(roc_host, built[0..children.len]);
}

const wrapper_attr_names = [_][]const u8{ "data-a", "data-b", "data-c", "data-d", "data-e", "data-f" };

fn attributedElement(roc_host: *abi.RocHost, children: []const abi.Elem) abi.Elem {
    var attrs: [wrapper_attr_names.len]abi.NodeAttr = undefined;
    for (wrapper_attr_names, &attrs) |name, *attr| attr.* = fixtures.customTextAttr(roc_host, name, "present");
    return fixtures.elementWith(roc_host, "div", &attrs, children);
}

fn buildBranch(branch: Branch, roc_host: *abi.RocHost, shared: *const SharedSource) abi.Elem {
    return switch (branch) {
        .empty => fixtures.emptyEach(roc_host),
        .children => |nested| buildChildren(nested, roc_host, shared),
    };
}

/// Builds one `each` fixture for `spec`. Only a top-level site reads the
/// shared cell as its items; every site's rows still carry the source so a
/// `when` row can bind its condition to it from inside the row scope.
/// Builds one `each` fixture for `spec`. A shared site keys its rows by item
/// bucket; a constant one, mounted for an outer row at `version`, holds
/// `innerRowKeys` in that order.
fn buildSite(spec: *const SiteSpec, roc_host: *abi.RocHost, shared: *const SharedSource, version: i64) abi.Elem {
    const capture = RowCapture{ .spec = spec, .shared = shared };
    if (spec.shared) {
        if (spec.depth != 0) fail("a nested each site was generated as shared", .{});
        return fixtures.eachOverStateListKeyOfRowAndCapture(RowCapture, roc_host, shared.token, shared.cap, &fixtures.bucketKeyCallable, .{ .amount = key_stride }, &rowCallable, capture);
    }
    var keys: [max_rows]i64 = undefined;
    const inner_keys = innerRowKeys(spec, version, &keys);
    var items: [max_rows]HostValue = undefined;
    for (items[0..inner_keys.len], inner_keys) |*item, key| item.* = fixtures.i64Value(key);
    return fixtures.eachWithItemsRowAndCapture(RowCapture, roc_host, items[0..inner_keys.len], &rowCallable, capture);
}

fn rowCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const capture = fixtures.captureAs(RowCapture, capture_ptr);
    const spec = capture.spec;
    const key = fixtures.eachRowKeyI64(roc_host, args);
    const item = if (spec.shared) key * key_stride else key;
    var buffer: [32]u8 = undefined;
    const label = rowLabel(&buffer, spec, key);
    const elem = switch (spec.row_kind) {
        .text => fixtures.text(roc_host, label),
        .stateful => fixtures.state(roc_host, fixtures.text(roc_host, label)),
        .when => fixtures.whenOnListPredicate(roc_host, capture.shared.token, spec.condition.predicate, spec.condition.operand, fixtures.text(roc_host, label), fixtures.text(roc_host, hidden_text)),
        .nested_each => blk: {
            const children = [_]abi.Elem{ fixtures.text(roc_host, label), buildSite(spec.inner.?, roc_host, capture.shared, rowVersion(spec, item)) };
            break :blk attributedElement(roc_host, &children);
        },
    };
    fixtures.writeResult(abi.Elem, ret, elem);
}

fn rowLabel(buffer: []u8, spec: *const SiteSpec, key: i64) []const u8 {
    return std.fmt.bufPrint(buffer, "row-{d}-{d}", .{ spec.id, key }) catch unreachable;
}

fn ownedRowLabel(arena: std.mem.Allocator, spec: *const SiteSpec, key: i64) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(arena, "row-{d}-{d}", .{ spec.id, key });
}

fn expectUnpublished(host: *const Host, failure_number: usize) void {
    const engine = &host.engine;
    const counts = [_]struct { name: []const u8, len: usize }{
        .{ .name = "scopes", .len = engine.scopes.items.len },
        .{ .name = "node identities", .len = engine.node_identities.items.len },
        .{ .name = "dom identities", .len = engine.dom_identities.items.len },
        .{ .name = "states", .len = engine.states.items.len },
        .{ .name = "each row sites", .len = engine.each_row_sites.items.len },
        .{ .name = "each row site indexes", .len = engine.each_row_site_indexes.count() },
        .{ .name = "active render nodes", .len = engine.active_stream.render_nodes.items.len },
        .{ .name = "active eaches", .len = engine.active_stream.eaches.items.len },
        .{ .name = "active whens", .len = engine.active_stream.whens.items.len },
        .{ .name = "active events", .len = engine.active_events.items.len },
        .{ .name = "active signal graph", .len = engine.active_signal_graph.items.len },
        .{ .name = "dom elements", .len = host.dom_elements.items.len },
    };
    for (counts) |count| {
        if (count.len != 0) fail("refusal at attempt {d} published {d} {s}", .{ failure_number, count.len, count.name });
    }
    if (engine.render_cache.hasRoot()) fail("refusal at attempt {d} published a render root", .{failure_number});
}

fn expectPublished(host: *const Host, program: Program, items: []const i64) void {
    const engine = &host.engine;
    const expected = Expected.of(program, items);
    if (!engine.render_cache.hasRoot()) fail("no render root is committed", .{});
    if (engine.each_row_sites.items.len != expected.sites) {
        fail("engine owns {d} each sites, model expects {d}", .{ engine.each_row_sites.items.len, expected.sites });
    }
    if (engine.each_row_site_indexes.count() != expected.sites) {
        fail("engine indexes {d} each sites, model expects {d}", .{ engine.each_row_site_indexes.count(), expected.sites });
    }
    if (engine.active_stream.eaches.items.len != expected.sites) {
        fail("active stream holds {d} each descriptors, model expects {d}", .{ engine.active_stream.eaches.items.len, expected.sites });
    }
    if (engine.active_stream.whens.items.len != expected.whens) {
        fail("active stream holds {d} when descriptors, model expects {d}", .{ engine.active_stream.whens.items.len, expected.whens });
    }
    var rows: usize = 0;
    for (engine.each_row_sites.items) |site| rows += site.scope_ids.items.len;
    if (rows != expected.rows) fail("engine owns {d} each rows, model expects {d}", .{ rows, expected.rows });
    if (engine.states.items.len != expected.states) {
        fail("engine owns {d} states, model expects {d}", .{ engine.states.items.len, expected.states });
    }
    expectLabels(host, program, items);
    expectDocumentOrder(host, program, items);
    for (host.dom_elements.items) |elem| {
        if (!elem.active or elem.id == fixtures.render_root.raw() or !std.mem.eql(u8, elem.tag, "div")) continue;
        if (elem.attrs.items.len != wrapper_attr_names.len) fail("wrapper {d} has {d} custom attributes, expected {d}", .{ elem.id, elem.attrs.items.len, wrapper_attr_names.len });
        for (wrapper_attr_names) |name| {
            const value = for (elem.attrs.items) |attr| {
                if (std.mem.eql(u8, attr.name, name)) break attr.value;
            } else fail("wrapper {d} lost attribute {s}", .{ elem.id, name });
            if (!std.mem.eql(u8, value, "present")) fail("wrapper {d} changed attribute {s}", .{ elem.id, name });
        }
    }
    host.engine.validateActiveScopeSiteInsertIndexes();
}

/// Asserts every label the model shows is an active DOM text node and every
/// label the program could ever show but the model hides is gone.
///
/// A row splice that creates without retiring leaves the old label behind, and
/// a branch flip that disposes nothing leaves the old branch's rows, and a
/// count-based oracle cannot see either once the counts happen to agree again.
/// Labels carry the site id, so a surviving label can only have come from the
/// one row that should have been disposed or hidden.
fn expectLabels(host: *const Host, program: Program, items: []const i64) void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var shown: std.ArrayListUnmanaged([]const u8) = .empty;
    modelTexts(&shown, arena, program.children, items) catch fail("oracle arena exhausted", .{});
    for (shown.items) |label| {
        if (fixtures.findActiveText(host, label) == null) fail("modelled text '{s}' is not an active DOM text node", .{label});
    }
    var buffer: [32]u8 = undefined;
    for (program.sites) |spec| {
        for (0..max_rows) |row| expectLabelHidden(host, shown.items, rowLabel(&buffer, spec, @intCast(row)));
        for (program.lists) |list| for (list) |item| expectLabelHidden(host, shown.items, rowLabel(&buffer, spec, @divTrunc(item, key_stride)));
    }
}

fn expectLabelHidden(host: *const Host, shown: []const []const u8, label: []const u8) void {
    for (shown) |visible| if (std.mem.eql(u8, visible, label)) return;
    if (fixtures.findActiveText(host, label) != null) fail("hidden row label '{s}' is still an active DOM text node", .{label});
}

/// Asserts the committed render tree reads exactly as the model does: walking
/// the render cache from its root visits the modelled text nodes in document
/// order, and no parent on the way holds a child twice.
///
/// Counts and labels cannot tell a branch spliced under the right parent at
/// the wrong index from a correct one; the order can. The duplicate check is
/// the shape a splice produces when one parent is registered through two
/// staging passes in the same transaction.
fn expectDocumentOrder(host: *const Host, program: Program, items: []const i64) void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var expected: std.ArrayListUnmanaged([]const u8) = .empty;
    modelTexts(&expected, arena, program.children, items) catch fail("oracle arena exhausted", .{});
    var actual: std.ArrayListUnmanaged([]const u8) = .empty;
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

fn collectRenderTexts(host: *const Host, arena: std.mem.Allocator, out: *std.ArrayListUnmanaged([]const u8), parent: signals.ids.ElemId) error{OutOfMemory}!void {
    const children = fixtures.renderChildren(host, parent);
    for (children, 0..) |child, index| {
        for (children[index + 1 ..]) |other| {
            if (child.raw() == other.raw()) fail("render parent {d} holds child {d} more than once", .{ parent.raw(), child.raw() });
        }
        if (fixtures.renderText(host, child)) |text| try out.append(arena, text);
        try collectRenderTexts(host, arena, out, child);
    }
}

/// Which transaction of the current run the oracles are judging, named in
/// every failure so a replay says where the model and engine parted.
var phase: []const u8 = "before the mount";

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("structural fuzz oracle failed ({s}): " ++ fmt ++ "\n", .{phase} ++ args);
    @panic("structural fuzz oracle failed");
}
