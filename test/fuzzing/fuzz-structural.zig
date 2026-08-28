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
//! The first bug this target was built against (issue #22) is the canonical
//! example: a root with several sibling initial `each` sites trapped at commit
//! because every site reserved one engine slot against a length that does not
//! move until publication. Two sites passed - `ensureUnusedCapacity(1)` leaves
//! slack - and the trap needed a site count nobody had written down.
//!
//! # What is generated
//!
//! An initial root: a `div` whose children are a mix of static text and keyed
//! `each` sites. Every site has a row count and a row kind, and the row kind
//! decides what each row renders - plain text, a state cell, a `when` branch, or
//! a nested `each` site with its own generated shape. Nesting is bounded at two
//! levels. Keys are the row index, so no site ever carries a duplicate key: that
//! is a Roc-side diagnostic and terminates the host, not something to fuzz here.
//!
//! The row callable receives its `SiteSpec` through the erased-callable capture,
//! which is how the engine ends up asking the generated program what to render
//! for each row without the harness knowing when it will be asked.
//!
//! # Reference model
//!
//! The program's shape determines the committed topology exactly: how many each
//! sites the engine must own (including nested ones instantiated once per outer
//! row), how many row scopes they hold in total, how many state cells exist, and
//! which text nodes are visible in the simulated DOM. `Expected.of` walks the
//! generated program to derive those totals from scratch.
//!
//! # Oracles
//!
//!  - **Published topology matches the model.** Site count, total row count,
//!    state count, and the descriptor stream's `eaches` all equal the derived
//!    totals, and every generated row's label is an active DOM text node.
//!  - **A refused transaction publishes nothing.** After an injected
//!    preparation failure the engine's scopes, identities, states, row sites,
//!    active stream, event table, signal graph, render cache, and simulated DOM
//!    are all empty, the closure retain/release counters balance, and the Roc
//!    allocation ledger holds nothing allocated since the root was built.
//!  - **The engine is still usable.** Disarming the fault and retrying the same
//!    root *on the same host* must publish the full model topology.
//!  - **Publication never allocates.** Commit and teardown run with the fault
//!    armed on the very next attempt; an allocation there is a panic, not a
//!    refusal.
//!  - **Nothing leaks.** The host's safety-checked debug allocator reports a
//!    leak on teardown as a failure.
//!
//! # Fault placement
//!
//! Every input first mounts unfaulted to learn the preparation attempt count.
//! When that count is small the whole `1..count` sweep runs; otherwise the input
//! selects one attempt, and coverage guidance spreads the choice. Faults are
//! injected through the host's engine allocator override, the same seam the
//! hand-written native sweeps use.
//!
//! # Seams
//!
//! The transaction is `PreparedRootCollection.prepare` ->
//! `PreparedRootDownstream.prepare` -> `commit` -> `runLifecycle` -> `deinit`,
//! driven through `native_host.fuzz_fixtures`, which also supplies the element
//! and keyed-list fixtures.
//!
//! Two properties of `FaultAllocator` shape the model. It is *sticky*: attempt
//! `N` and every later attempt fail until reconfigured, so it cannot express
//! "fail once, then succeed" - and `configure` resets `attempts`. `free` never
//! counts and never fails, which is what makes teardown guaranteed
//! allocation-failure-free.
//!
//! # Not yet covered
//!
//! Live structural edits after the initial mount - branch flips, row splices,
//! reorders, descriptor replacements - and `ResourceLimit` rejection driven
//! through `collection_budget` bounds. Those extend this generator rather than
//! replacing it, and the first live edit is the obvious next step: once the
//! multi-site mount fix landed, the native `kanban-board` and
//! `spreadsheet-lite` specs got past mounting and their first state dispatch
//! failed in `PreparedCompositeRows.prepareDownstream` ->
//! `prepareFinalRenderTopology`, where `PreparedRenderSplice.addChildren`
//! reports a `DuplicateChild`/`ConflictingParent` intent that the engine then
//! reports as `ResourceLimit`. A generated state edit across sibling sites
//! should reach that in seconds.
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

const max_children = 24;
const max_rows = 6;
const max_depth = 2;
/// Full sweeps are quadratic in the attempt count, so past this bound one
/// attempt per input keeps the fuzzer fast and lets coverage pick the position.
const max_full_sweep_attempts = 40;

const RowKind = enum(u8) {
    text,
    stateful,
    when,
    nested_each,
};

const SiteSpec = struct {
    row_count: u8,
    row_kind: RowKind,
    depth: u8,
    /// The site every row instantiates when `row_kind` is `nested_each`.
    inner: ?*const SiteSpec,
};

const Child = union(enum) {
    text,
    site: *const SiteSpec,
};

const Program = struct {
    children: []const Child,
};

/// Capture handed to every generated row callable.
const RowCapture = extern struct {
    spec: *const SiteSpec,
};

const Expected = struct {
    sites: usize = 0,
    rows: usize = 0,
    states: usize = 0,

    fn of(program: Program) Expected {
        var expected = Expected{};
        for (program.children) |child| switch (child) {
            .text => {},
            .site => |spec| expected.addSite(spec),
        };
        return expected;
    }

    fn addSite(self: *Expected, spec: *const SiteSpec) void {
        self.sites += 1;
        self.rows += spec.row_count;
        switch (spec.row_kind) {
            .text, .when => {},
            .stateful => self.states += spec.row_count,
            .nested_each => {
                for (0..spec.row_count) |_| self.addSite(spec.inner.?);
            },
        }
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

    const program = Program{ .children = generate(&reader, arena) catch fail("program arena exhausted", .{}) };
    const expected = Expected.of(program);
    if (debug) {
        std.debug.print("program: {d} children, model sites={d} rows={d} states={d}\n", .{ program.children.len, expected.sites, expected.rows, expected.states });
        for (program.children, 0..) |child, index| switch (child) {
            .text => std.debug.print("  [{d}] text\n", .{index}),
            .site => |spec| printSite(spec, index),
        };
    }

    const attempts = run(program, expected, null);
    if (debug) std.debug.print("preparation attempts: {d}\n", .{attempts});
    if (attempts == 0) return;

    if (attempts <= max_full_sweep_attempts and reader.boolean()) {
        if (debug) std.debug.print("sweeping every attempt\n", .{});
        for (1..attempts + 1) |failure_number| _ = run(program, expected, failure_number);
    } else {
        const failure_number = 1 + reader.intRangeAtMost(usize, 0, attempts - 1);
        if (debug) std.debug.print("injecting failure at attempt {d}\n", .{failure_number});
        _ = run(program, expected, failure_number);
    }
}

fn generate(reader: *FuzzReader, arena: std.mem.Allocator) ![]const Child {
    const child_count = reader.intRangeAtMost(u8, 0, max_children);
    const children = try arena.alloc(Child, child_count);
    for (children) |*child| {
        child.* = if (reader.intRangeAtMost(u8, 0, 4) == 0)
            .text
        else
            .{ .site = try generateSite(reader, arena, 0) };
    }
    return children;
}

fn generateSite(reader: *FuzzReader, arena: std.mem.Allocator, depth: u8) !*const SiteSpec {
    const spec = try arena.create(SiteSpec);
    var kind: RowKind = @enumFromInt(reader.intRangeAtMost(u8, 0, 3));
    if (kind == .nested_each and depth + 1 >= max_depth) kind = .stateful;
    spec.* = .{
        .row_count = reader.intRangeAtMost(u8, 0, max_rows),
        .row_kind = kind,
        .depth = depth,
        .inner = if (kind == .nested_each) try generateSite(reader, arena, depth + 1) else null,
    };
    return spec;
}

fn printSite(spec: *const SiteSpec, index: usize) void {
    var current: ?*const SiteSpec = spec;
    while (current) |site| {
        for (0..site.depth + 1) |_| std.debug.print("  ", .{});
        std.debug.print("[{d}] each rows={d} kind={t}\n", .{ index, site.row_count, site.row_kind });
        current = site.inner;
    }
}

/// Mounts the program once on a fresh host, optionally refusing at
/// `failure_number`, and returns the preparation attempt count.
fn run(program: Program, expected: Expected, failure_number: ?usize) usize {
    var host = fixtures.createHost();
    var roc_host = fixtures.bindHost(&host);
    host.engine.roc_host = &roc_host;
    defer if (fixtures.destroyHost(&host)) fail("host allocator leaked", .{});

    const root = buildRoot(program, &roc_host);
    defer root.decref(&roc_host);
    const refs_before = host.roc_allocations.snapshot();

    var fault = FaultAllocator.init(host.gpa.allocator());
    fault.configure(failure_number);
    host.engine_allocator_override = fault.allocator();
    const result = fixtures.renderInitialRootWithArmedPublication(&host, &roc_host, root, &fault);
    const attempts = fault.attempts;

    if (failure_number) |number| {
        if (result) |_| {
            fail("failure at attempt {d} did not refuse preparation", .{number});
        } else |err| switch (err) {
            error.OutOfMemory => {},
            error.ResourceLimit => fail("failure at attempt {d} was reported as a resource limit", .{number}),
        }
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
    } else {
        _ = result catch |err| fail("unfaulted mount failed: {t}", .{err});
    }

    expectPublished(&host, program, expected);
    return attempts;
}

fn buildRoot(program: Program, roc_host: *abi.RocHost) abi.Elem {
    var children: [max_children]abi.Elem = undefined;
    for (program.children, 0..) |child, index| {
        children[index] = switch (child) {
            .text => fixtures.text(roc_host, "separator"),
            .site => |spec| buildSite(spec, roc_host),
        };
    }
    return fixtures.element(roc_host, children[0..program.children.len]);
}

fn buildSite(spec: *const SiteSpec, roc_host: *abi.RocHost) abi.Elem {
    var items: [max_rows]HostValue = undefined;
    for (items[0..spec.row_count], 0..) |*item, index| item.* = fixtures.i64Value(@intCast(index));
    return fixtures.eachWithItemsRowAndCapture(RowCapture, roc_host, items[0..spec.row_count], &rowCallable, .{ .spec = spec });
}

fn rowCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const spec = fixtures.captureAs(RowCapture, capture_ptr).spec;
    const call_args = fixtures.argsAs(fixtures.BinaryArgs, args);
    const key = fixtures.readI64(roc_host, call_args.arg0);
    var buffer: [32]u8 = undefined;
    const label = rowLabel(&buffer, spec.depth, @intCast(key));
    const elem = switch (spec.row_kind) {
        .text => fixtures.text(roc_host, label),
        .stateful => fixtures.state(roc_host, fixtures.text(roc_host, label)),
        .when => fixtures.when(roc_host, fixtures.text(roc_host, label), fixtures.text(roc_host, "hidden")),
        .nested_each => blk: {
            const children = [_]abi.Elem{ fixtures.text(roc_host, label), buildSite(spec.inner.?, roc_host) };
            break :blk fixtures.element(roc_host, &children);
        },
    };
    fixtures.writeResult(abi.Elem, ret, elem);
}

fn rowLabel(buffer: []u8, depth: u8, row: usize) []const u8 {
    return std.fmt.bufPrint(buffer, "row-{d}-{d}", .{ depth, row }) catch unreachable;
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

fn expectPublished(host: *const Host, program: Program, expected: Expected) void {
    const engine = &host.engine;
    if (!engine.render_cache.hasRoot()) fail("mount published no render root", .{});
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
    for (program.children) |child| switch (child) {
        .text => {},
        .site => |spec| expectSiteText(host, spec),
    };
}

fn expectSiteText(host: *const Host, spec: *const SiteSpec) void {
    var buffer: [32]u8 = undefined;
    for (0..spec.row_count) |row| {
        const label = rowLabel(&buffer, spec.depth, row);
        if (fixtures.findActiveText(host, label) == null) fail("row label '{s}' is not an active DOM text node", .{label});
    }
    if (spec.row_kind == .nested_each and spec.row_count != 0) expectSiteText(host, spec.inner.?);
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("structural fuzz oracle failed: " ++ fmt ++ "\n", args);
    @panic("structural fuzz oracle failed");
}
