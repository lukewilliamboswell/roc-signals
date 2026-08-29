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
//! # What is generated
//!
//! A program is a root state cell holding a list of `i64` items, wrapping a tree
//! of elements, plus a sequence of replacement item lists to publish into that
//! cell after the mount.
//!
//! The element tree is a `div` whose children are a mix of static text, `each`
//! sites, and nested wrapper elements holding more of the same. Wrappers matter:
//! they are what puts sibling sites under *distinct render parents*, which is
//! the shape the multi-parent suppression bug needed.
//!
//! An `each` site is either **constant** - its own frozen item list, with its own
//! generated row count - or **shared**, reading the root state cell through a
//! `Signal.map` copy of its list. Every shared site therefore re-diffs its rows
//! inside the single transaction one state dispatch opens, so one edit can splice
//! several sites under several parents at once. A program holds at most
//! `max_shared_sites` of them, and any number of those may share one parent;
//! that bound is a generator budget rather than an engine limit.
//!
//! Every site has a row kind that decides what a row renders: plain text, a
//! state cell, a `when` branch, or a nested constant `each` site with its own
//! generated shape. Nesting is bounded at two levels, wrappers at two levels.
//! Keys are the row's item value, and generated lists are strictly increasing
//! before an optional rotation, so no site ever carries a duplicate key: that is
//! a Roc-side diagnostic and terminates the host, not something to fuzz here.
//! Constant sites key rows from a low range and shared sites from a high one, so
//! a label says which list it came from.
//!
//! The row callable receives its `SiteSpec` through the erased-callable capture,
//! which is how the engine ends up asking the generated program what to render
//! for each row without the harness knowing when it will be asked.
//!
//! Edits are drawn as fresh strictly-increasing lists of independently chosen
//! length with an optional rotation, so successive lists exercise reorder,
//! replacement, growth, and shrink - across every shared site at once, since
//! they all read the same cell.
//!
//! # Reference model
//!
//! `Expected.of(program, items)` walks the generated element tree against one
//! item list and derives the committed topology from scratch: how many each sites
//! the engine must own (including nested ones instantiated once per outer row, so
//! a shared outer site's site count moves with the list), how many row scopes
//! they hold in total, and how many state cells exist - one for the root cell
//! plus one per stateful row. The visible label set is derived the same way, and
//! every key the program ever mentions but the current list omits is modelled as
//! *absent* from the DOM.
//!
//! The model is a pure function of the shape and the current list, so one oracle
//! judges the mount, every committed edit, and the state left behind by a refused
//! edit.
//!
//! # Oracles
//!
//!  - **Published topology matches the model, at the mount and after every
//!    edit.** Site count, total row count, state count, and the descriptor
//!    stream's `eaches` all equal the derived totals; every modelled row label is
//!    an active DOM text node; every retired key's label is gone.
//!  - **No render parent holds a child twice.** Every live `each` site's parent
//!    is read out of the render cache and checked for duplicate children, which
//!    is where a splice that registered one parent through two staging passes
//!    shows up and where no count-based oracle would notice.
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
//!    configured bound rejected a transaction built inside its limits,
//!    `InvalidRenderTopology` means the staged render topology disagreed with
//!    the committed tree, and `InvalidSignalGraphAppend` means a staged
//!    `prepareGraphAppend` disagreed with the committed signal graph. All are
//!    oracle failures, and `expectRefusal` rejects them generically so a newly
//!    added variant is caught rather than silently accepted.
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
//! One shape is deliberately withheld because the engine cannot yet survive
//! it. It is a real open bug rather than a property of the generator, and the
//! note says which guard to delete once it is fixed.
//!
//!  - **A bare `Ref` as an `each`'s items signal.** Shared sites read the state
//!    cell through a `Signal.map` copy instead. The staged initial mount reaches
//!    `PreparedEachInputs.prepareWithOverlay`, which resolves the items
//!    capability with `hostSignalBindingCapability` - no provisional-state
//!    overlay - so a `Ref` to the cell the same transaction is creating finds no
//!    active state and terminates the host, even though the enclosing
//!    `collectInitialEach` used the provisional variant two lines earlier.
//!    Delete `eachOverStateListRowAndCapture`'s map once collection resolves
//!    that capability provisionally.
//!
//! Three further gaps are simply unwritten rather than blocked:
//!
//!  - **Live `when` branch flips.** Generated `when` conditions are constant, so a
//!    branch is chosen at collection and never switches. Driving the condition
//!    from a shared bool signal would put branch disposal and re-instantiation
//!    inside the same transaction as the row splices.
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
/// reaches the multi-parent composite splice this target exists to cover, and
/// it is also the count at which the open `prepareMultiRemoval` interval bug
/// starts firing; see "Not yet covered".
const max_shared_sites = 4;
/// Keys a shared site's rows start from. Constant sites key from zero, so a label
/// always says which list produced it and an "absent" assertion about a retired
/// shared key cannot be satisfied by an unrelated constant row.
const shared_key_base: i64 = 100;
/// Full sweeps are quadratic in the attempt count, so past this bound one attempt
/// per input keeps the fuzzer fast and lets coverage pick the position.
const max_full_sweep_attempts = 40;

const RowKind = enum(u8) {
    text,
    stateful,
    when,
    nested_each,
};

const SiteSpec = struct {
    /// Row count for a constant site. Shared sites take their count from the item
    /// list the root state cell currently holds.
    row_count: u8,
    row_kind: RowKind,
    depth: u8,
    /// Rows come from the root state signal rather than a frozen list, so this
    /// site re-diffs inside every live edit.
    shared: bool,
    /// The site every row instantiates when `row_kind` is `nested_each`.
    inner: ?*const SiteSpec,
};

const Child = union(enum) {
    text,
    site: *const SiteSpec,
    /// A generated wrapper element, which gives the sites beneath it a render
    /// parent of their own.
    wrapper: []const Child,
};

const Program = struct {
    children: []const Child,
    /// Item lists the root state cell holds over time. Index zero is the mount;
    /// each later entry is one live edit.
    lists: []const []const i64,
};

/// The shared state cell a `Ref`-driven site binds to.
const SharedSource = struct {
    token: BinderToken,
    cap: ValueCapability,
};

/// Capture handed to every generated row callable.
const RowCapture = extern struct {
    spec: *const SiteSpec,
};

const Expected = struct {
    sites: usize = 0,
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
        };
    }

    fn addSite(self: *Expected, spec: *const SiteSpec, items: []const i64) void {
        const rows = rowCount(spec, items);
        self.sites += 1;
        self.rows += rows;
        switch (spec.row_kind) {
            .text, .when => {},
            .stateful => self.states += rows,
            .nested_each => {
                for (0..rows) |_| self.addSite(spec.inner.?, items);
            },
        }
    }
};

fn rowCount(spec: *const SiteSpec, items: []const i64) usize {
    return if (spec.shared) items.len else spec.row_count;
}

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

fn generate(reader: *FuzzReader, arena: std.mem.Allocator) !Program {
    var shared_budget: usize = max_shared_sites;
    const children = try generateChildren(reader, arena, 0, &shared_budget);

    const list_count = 1 + @as(usize, reader.intRangeAtMost(u8, 0, max_edits));
    const lists = try arena.alloc([]const i64, list_count);
    for (lists) |*list| list.* = try generateList(reader, arena, reader.intRangeAtMost(usize, 0, max_rows));
    return .{ .children = children, .lists = lists };
}

/// Builds one strictly increasing key list, then rotates it.
///
/// Increasing values keep every key in a list distinct, which is a hard contract
/// rather than a fuzzing dimension: duplicate keys are a Roc-side diagnostic that
/// terminates the host. The rotation is what turns an otherwise monotonically
/// ordered list into a genuine reorder for the row differ.
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

/// Generates the children of one element.
///
/// At most one of them reads the shared cell. Sibling shared sites under a
/// *single* render parent are not generated because the engine cannot yet splice
/// them: two sites removing rows from the same parent in one transaction reach
/// `structural_splice.prepareMultiRemoval` with overlapping intervals. Wrappers
/// are how a program gets several shared sites anyway - one per parent - which is
/// also the shape the multi-parent suppression bug needed.
fn generateChildren(reader: *FuzzReader, arena: std.mem.Allocator, wrapper_depth: u8, shared_budget: *usize) error{OutOfMemory}![]const Child {
    const limit: u8 = if (wrapper_depth == 0) max_children else 4;
    const child_count = reader.intRangeAtMost(u8, 0, limit);
    const children = try arena.alloc(Child, child_count);
    for (children) |*child| {
        const choice = reader.intRangeAtMost(u8, 0, 5);
        child.* = if (choice == 0)
            .text
        else if (choice == 1 and wrapper_depth + 1 < max_wrapper_depth)
            .{ .wrapper = try generateChildren(reader, arena, wrapper_depth + 1, shared_budget) }
        else
            .{ .site = try generateSite(reader, arena, 0, shared_budget.* != 0) };
        switch (child.*) {
            .site => |spec| if (spec.shared) {
                shared_budget.* -= 1;
            },
            else => {},
        }
    }
    return children;
}

fn generateSite(reader: *FuzzReader, arena: std.mem.Allocator, depth: u8, allow_shared: bool) error{OutOfMemory}!*const SiteSpec {
    const spec = try arena.create(SiteSpec);
    var kind: RowKind = @enumFromInt(reader.intRangeAtMost(u8, 0, 3));
    if (kind == .nested_each and depth + 1 >= max_depth) kind = .stateful;
    // Only top-level sites read the shared cell: a nested site is instantiated
    // once per outer row, and pointing every one of them at the same signal
    // would multiply row counts rather than add coverage.
    const shared = depth == 0 and allow_shared and reader.boolean();
    spec.* = .{
        .row_count = reader.intRangeAtMost(u8, 0, max_rows),
        .row_kind = kind,
        .depth = depth,
        .shared = shared,
        .inner = if (kind == .nested_each) try generateSite(reader, arena, depth + 1, false) else null,
    };
    return spec;
}

fn countSharedSites(children: []const Child) usize {
    var count: usize = 0;
    for (children) |child| switch (child) {
        .text => {},
        .site => |spec| count += @intFromBool(spec.shared),
        .wrapper => |nested| count += countSharedSites(nested),
    };
    return count;
}

fn printProgram(program: Program) void {
    std.debug.print("program: {d} top-level children, {d} shared sites\n", .{ program.children.len, countSharedSites(program.children) });
    for (program.lists, 0..) |list, index| {
        std.debug.print("  list[{d}] len={d}:", .{ index, list.len });
        for (list) |item| std.debug.print(" {d}", .{item});
        const expected = Expected.of(program, list);
        std.debug.print(" -> sites={d} rows={d} states={d}\n", .{ expected.sites, expected.rows, expected.states });
    }
    printChildren(program.children, 1);
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
            .site => |spec| {
                std.debug.print("[{d}] each shared={} rows={d} kind={t}\n", .{ index, spec.shared, spec.row_count, spec.row_kind });
                if (spec.inner) |inner| {
                    for (0..indent + 1) |_| std.debug.print("  ", .{});
                    std.debug.print("inner each rows={d} kind={t}\n", .{ inner.row_count, inner.row_kind });
                }
            },
        }
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
    const root = buildRoot(program, &roc_host, shared);
    defer root.decref(&roc_host);
    const refs_before = host.roc_allocations.snapshot();

    var fault = FaultAllocator.init(host.gpa.allocator());
    host.engine_allocator_override = fault.allocator();

    fault.configure(plan.mount_failure);
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

fn buildRoot(program: Program, roc_host: *abi.RocHost, shared: SharedSource) abi.Elem {
    const body = buildChildren(program.children, roc_host, shared);
    return fixtures.stateWithTokenInitialAndCapability(roc_host, shared.token, listValue(roc_host, program.lists[0]), body, shared.cap);
}

fn buildChildren(children: []const Child, roc_host: *abi.RocHost, shared: ?SharedSource) abi.Elem {
    var built: [max_children]abi.Elem = undefined;
    for (children, 0..) |child, index| {
        built[index] = switch (child) {
            .text => fixtures.text(roc_host, "separator"),
            .site => |spec| buildSite(spec, roc_host, shared),
            .wrapper => |nested| buildChildren(nested, roc_host, shared),
        };
    }
    return fixtures.element(roc_host, built[0..children.len]);
}

/// Builds one `each` fixture for `spec`.
///
/// `shared` is absent inside a row callable, which is why only top-level sites
/// may bind the state cell: by the time a nested site is built the harness is
/// already inside an erased call and has no token to hand it.
fn buildSite(spec: *const SiteSpec, roc_host: *abi.RocHost, shared: ?SharedSource) abi.Elem {
    const capture = RowCapture{ .spec = spec };
    if (spec.shared) {
        const source = shared orelse fail("a nested each site was generated as shared", .{});
        return fixtures.eachOverStateListRowAndCapture(RowCapture, roc_host, source.token, &rowCallable, capture);
    }
    var items: [max_rows]HostValue = undefined;
    for (items[0..spec.row_count], 0..) |*item, index| item.* = fixtures.i64Value(@intCast(index));
    return fixtures.eachWithItemsRowAndCapture(RowCapture, roc_host, items[0..spec.row_count], &rowCallable, capture);
}

fn rowCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const spec = fixtures.captureAs(RowCapture, capture_ptr).spec;
    const call_args = fixtures.argsAs(fixtures.BinaryArgs, args);
    const key = fixtures.readI64(roc_host, call_args.arg0);
    var buffer: [32]u8 = undefined;
    const label = rowLabel(&buffer, spec.depth, key);
    const elem = switch (spec.row_kind) {
        .text => fixtures.text(roc_host, label),
        .stateful => fixtures.state(roc_host, fixtures.text(roc_host, label)),
        .when => fixtures.when(roc_host, fixtures.text(roc_host, label), fixtures.text(roc_host, "hidden")),
        .nested_each => blk: {
            const children = [_]abi.Elem{ fixtures.text(roc_host, label), buildSite(spec.inner.?, roc_host, null) };
            break :blk fixtures.element(roc_host, &children);
        },
    };
    fixtures.writeResult(abi.Elem, ret, elem);
}

fn rowLabel(buffer: []u8, depth: u8, key: i64) []const u8 {
    return std.fmt.bufPrint(buffer, "row-{d}-{d}", .{ depth, key }) catch unreachable;
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
    var rows: usize = 0;
    for (engine.each_row_sites.items) |site| rows += site.scope_ids.items.len;
    if (rows != expected.rows) fail("engine owns {d} each rows, model expects {d}", .{ rows, expected.rows });
    if (engine.states.items.len != expected.states) {
        fail("engine owns {d} states, model expects {d}", .{ engine.states.items.len, expected.states });
    }
    expectChildText(host, program.children, items);
    expectRetiredKeysGone(host, program, items);
    expectNoDuplicateRenderChildren(host);
    host.engine.validateActiveScopeSiteInsertIndexes();
}

fn expectChildText(host: *const Host, children: []const Child, items: []const i64) void {
    for (children) |child| switch (child) {
        .text => {},
        .site => |spec| expectSiteText(host, spec, items),
        .wrapper => |nested| expectChildText(host, nested, items),
    };
}

fn expectSiteText(host: *const Host, spec: *const SiteSpec, items: []const i64) void {
    var buffer: [32]u8 = undefined;
    if (spec.shared) {
        for (items) |item| {
            const label = rowLabel(&buffer, spec.depth, item);
            if (fixtures.findActiveText(host, label) == null) fail("shared row label '{s}' is not an active DOM text node", .{label});
        }
    } else {
        for (0..spec.row_count) |row| {
            const label = rowLabel(&buffer, spec.depth, @intCast(row));
            if (fixtures.findActiveText(host, label) == null) fail("row label '{s}' is not an active DOM text node", .{label});
        }
    }
    if (spec.row_kind == .nested_each and rowCount(spec, items) != 0) expectSiteText(host, spec.inner.?, items);
}

/// Asserts every key the program ever publishes but the current list omits has
/// left the DOM.
///
/// A row splice that creates without retiring leaves the old label behind, and a
/// count-based oracle cannot see that once the counts happen to agree again. Keys
/// come from a range no constant site uses, so a surviving label can only have
/// come from a shared row that should have been disposed.
fn expectRetiredKeysGone(host: *const Host, program: Program, items: []const i64) void {
    if (countSharedSites(program.children) == 0) return;
    var buffer: [32]u8 = undefined;
    for (program.lists) |list| {
        for (list) |key| {
            if (std.mem.indexOfScalar(i64, items, key) != null) continue;
            const label = rowLabel(&buffer, 0, key);
            if (fixtures.findActiveText(host, label) != null) fail("retired row label '{s}' is still an active DOM text node", .{label});
        }
    }
}

/// Asserts no live `each` site's render parent holds the same child twice.
///
/// This is the shape a splice produces when one parent is registered through two
/// staging passes in the same transaction: the counts stay plausible and the
/// labels are all present, but the committed render tree is corrupt.
fn expectNoDuplicateRenderChildren(host: *const Host) void {
    for (host.engine.active_stream.scope_sites.items) |site| {
        if (site.kind != .each) continue;
        const children = fixtures.renderChildren(host, site.parent_elem_id);
        for (children, 0..) |child, index| {
            for (children[index + 1 ..]) |other| {
                if (child.raw() == other.raw()) {
                    fail("render parent {d} holds child {d} more than once", .{ site.parent_elem_id.raw(), child.raw() });
                }
            }
        }
    }
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("structural fuzz oracle failed: " ++ fmt ++ "\n", args);
    @panic("structural fuzz oracle failed");
}
