//! Model-based fuzzing for keyed-list identity and scope lifecycle.
//!
//! # Why this target exists
//!
//! Keyed rows and scopes are where the engine's identity contract is most
//! exposed to *sequence*. Every individual operation here is easy to get right;
//! what breaks is the seventh remove after a reorder that followed a branch flip
//! within the same dirty generation. Example-based tests encode the sequences
//! someone already thought of, which is exactly the wrong shape for this bug
//! class. Of the five targets in this directory, this is the one where stateful
//! fuzzing should beat example-based testing by the widest margin.
//!
//! design.md, "Scopes and lifecycle", states the contract being checked:
//! disposal must remove ids from active indexes and adjacency, release
//! capability-owned state, run cleanup, and detach the rendered subtree; reorder
//! must move surviving rows rather than rebuild them; and disposed scopes must
//! become reusable slots without unbounded growth of inactive ones.
//!
//! # What is driven
//!
//! Not the whole engine. `scope_tree.zig`, `each_runtime.zig`, and
//! `scope_runtime.zig`'s disposal are comptime-generic over a `Row` type and
//! reach the rest of the world through a hook struct, so this target supplies its
//! own `Row`, its own hooks, and its own key/item ownership ledger, and drives
//! the identity machinery with no host, no Roc, and no render tree in the way.
//! That is what makes long generated histories worth running: a program here is
//! hundreds of reconciliations, not hundreds of mounts.
//!
//! The scope forest it builds is the smallest one that still has every shape the
//! contract talks about:
//!
//!     root
//!     |-- component ---- each site A   (long-lived; every list edit lands here)
//!     `-- when branch -- each site B   (retired and re-interned by every flip)
//!
//! # What is generated
//!
//! The input decodes into a *program*, never into raw bytes handed to the
//! engine: a hash-bucket count, then a sequence of operations drawn from insert,
//! remove, update-in-place, swap, reorder (including full reversal and rotation,
//! which are the shapes that break longest-stable-subsequence move planning),
//! remove-then-reinsert of the same key, `when` branch flips over a subtree, and
//! generation advances, followed by teardown. Keys come from a fixed pool so that
//! remove/reinsert genuinely revisits an identity rather than always minting a
//! fresh one - reusing a key after its scope retired is the interesting case, not
//! an edge case.
//!
//! The hash-bucket count is generated rather than fixed, and one is a legal
//! value. At one bucket every key in the list collides, so every lookup walks a
//! full chain and every duplicate decision is made by `nextKeysEqual` rather than
//! by the hash. Keys that collide but differ are therefore not a special case
//! bolted on beside the program; on a good fraction of inputs they are the whole
//! program.
//!
//! # The reference model
//!
//! A plain `ArrayList` of keys with a parallel list of versions, spliced and
//! permuted by the same operation sequence. It is deliberately slow and obviously
//! correct: it recomputes row order from scratch, shares no data structure with
//! the row tables it judges, and never reuses a slot.
//!
//! # Both paths, one program
//!
//! Every operation is applied to two independent worlds built from the same
//! model list. The **eager** world reconciles with `each_runtime.syncRows` and
//! retires subtrees with `scope_runtime.disposeSubtree`. The **prepared** world
//! reconciles with `PreparedExistingRows.prepare` / `commit` and retires with
//! `scope_runtime.prepareSubtreeRetirement` / `applyMetadata`. Their scope ids,
//! row order, site tables, memberships, hash indexes, and disposal order must
//! agree exactly after every operation. A divergence is a bug even when neither
//! path crashes.
//!
//! # Oracles
//!
//! After each operation, for each world:
//!
//!  - **Order.** `Site.scope_ids` is exactly the model's key order: row `i` owns
//!    key `i` at version `i`.
//!  - **Membership.** `activeEachRows` returns exactly the site's live row set.
//!    It returns them in *scope-array* order rather than row order, so it is a
//!    set oracle and the row-order oracle above is the ordering one. (The first
//!    sketch of this file claimed `activeEachRows` returns key order; the code
//!    disagrees, and the code is right.)
//!  - **Surviving identity.** A key present before and after an operation keeps
//!    its scope id. This is the property that makes per-row local state work,
//!    and the one a rebuild-instead-of-move regression silently breaks.
//!  - **Unique live ownership.** No scope id appears at two row positions, every
//!    live row's `Membership{site_index, row_index}` agrees with its position in
//!    `Site.scope_ids`, and no membership survives that no site row claims.
//!  - **Hash index coherence.** Walking `Site.hash_heads`/`hash_links` reaches
//!    every live row exactly once and terminates, and each row is reachable from
//!    the bucket its *own* key hashes to. The chained index is maintained
//!    incrementally by `appendRowToSiteIndex` and `removeRowFromSiteIndex`, so a
//!    desync here is invisible until a later lookup silently misses a survivor
//!    and rebuilds a row that should have been reused.
//!  - **Incoming ownership balances exactly once.** Every key and item handed to
//!    a reconciliation carries a ledger token, and the hooks that consume it -
//!    `dropIncoming*`, `replaceRow*`, `createRow`, `prepareCreatedRow` - each
//!    mark it. At the end of the reconciliation every token must be consumed
//!    exactly once. This is the sharp form of "no leak, no double release": a
//!    reconciler that drops a value it also stored, or stores one it also
//!    dropped, is caught even though the two mistakes cancel in any count.
//!  - **Row-owned values track liveness.** Every live row scope owns exactly one
//!    key and one item; every retired scope owns neither.
//!  - **Duplicate keys are errors, not aliases.** A duplicate must be reported
//!    with the two colliding input indexes, and must be reported on the *hash
//!    collision* path too - the probe drives a fresh site with lists whose keys
//!    all share one bucket, both with and without a genuine duplicate. The
//!    negative half is what separates a real typed-equality check from a
//!    hash-only one: colliding but distinct keys must be accepted, and each must
//!    still get its own row.
//!  - **Reuse barrier.** `Lifecycle.blocksReuse` compares `generation ==
//!    barrier`. Rather than sample the two directions, the target predicts the
//!    *exact* id every intern will return - the lowest-indexed inactive slot the
//!    barrier does not block, or a fresh append when there is none - and checks
//!    it at every row creation, component intern, and branch intern. Over- and
//!    under-blocking are equally reachable from an equality, and one prediction
//!    catches both.
//!
//!    The engine only ever retires *at* the current barrier, so an input where
//!    the retirement generation is newer than the barrier is unreachable through
//!    the engine yet is exactly what separates `==` from `>=`. `checkBarrier`
//!    therefore drives `scope_tree` directly with generated (retired, barrier)
//!    pairs on both sides of the equality, which is a contract probe on
//!    `blocksReuse` rather than a claim about a reachable engine state.
//!  - **No stale-id aliasing.** `ids.ScopeId` carries no generation tag, so once
//!    the barrier advances a recycled slot hands the same id to a new scope. The
//!    model holds every retired id and asserts no live membership, site row, or
//!    row-value entry still refers to one.
//!  - **Retirement is not disposal.** `prepareSubtreeRetirement` +
//!    `applyMetadata` flips lifecycle *without* releasing step-owned resources,
//!    so the prepared world asserts the row-value ledger is untouched across
//!    `applyMetadata` and releases separately. The two are never conflated when
//!    asserting balance. The prepared post-order journal must also equal the
//!    order `disposeSubtree` visited scopes in the eager world.
//!  - **Bounded inactive slots.** A disposed scope must become a reusable slot,
//!    not garbage. The scope array may therefore never be longer than the
//!    high-water mark of *simultaneous demand* - live scopes plus the ones the
//!    barrier is currently blocking - which is a bound in the shape of the
//!    program's concurrency rather than its length. Over-blocking shows up here
//!    as growth even when the predicted-id oracle happens to agree.
//!  - **Complete reclamation.** After teardown every scope is retired, every
//!    membership is null, every row value is released, the site table is empty,
//!    and the run's allocator reports no leak.
//!
//! Three probes run beside the program because the shapes they need are ones a
//! well-formed program never reaches:
//!
//!  - `checkDuplicates` drives the duplicate detector in both directions.
//!  - `checkRowRemovals` removes a generated *subset* of one site's rows through
//!    `prepareRowRemovals`/`apply`. The program only ever empties a site whose
//!    owning branch is being retired, and a hash index corrupted on the way out
//!    of a site nobody will consult again is invisible; a partial removal leaves
//!    the site live, so the swap-move that fills the hole and the hash unlink and
//!    re-file around it all have to be right. It also asserts that re-presenting
//!    a consumed removal is refused with `InvalidScope`.
//!  - `checkBarrier` probes `blocksReuse` on both sides of its equality.
//!
//! # Seams
//!
//! `scope_tree.zig`: `internRoot`, `internComponent`, `internWhenBranch`,
//! `appendEachRow`, `activeEachRows`, `validate` (through every intern).
//! `each_runtime.zig`: `syncRows`, `PreparedExistingRows.prepare`/`commit`,
//! `ensureSiteIndex`, `activeSiteIndex`, `ensureMembershipSlot`,
//! `prepareRowRemovals` / `PreparedRowRemovals.apply`, `removeRowFromSiteIndex`,
//! `replaceSiteRows` (through `syncRows`), `clearSites`.
//! `scope_runtime.zig`: `disposeSubtree`, `prepareSubtreeRetirement`,
//! `PreparedSubtreeRetirement.applyMetadata`.
//!
//! # Two deliberate deviations from the engine's own callers
//!
//! `hooks.failDuplicateEachKey` is `noreturn` for the native host, which
//! terminates the process on a duplicate key. A fuzz target cannot assert
//! anything about a process that has exited, so this target's hook *records* the
//! duplicate and returns, and the probe that provoked it runs against a scratch
//! world that is torn down immediately afterwards and never compared to the
//! model. What is asserted is the detection and its reported indexes, which is
//! the whole content of the contract; the process exit belongs to the host.
//!
//! `hooks.removeEachRow`, called from `disposeSubtree`, unlinks a row from the
//! site index only when the row still holds a membership. `syncRows` and
//! `PreparedExistingRows.commit` rebuild the whole site row table themselves, so
//! a disposal they drive must not also unlink; a standalone subtree disposal
//! must. The membership check is what distinguishes the two, and it doubles as an
//! oracle, since a row reaching disposal twice would trip the index panics.
//!
//! # A defect this target is currently working around
//!
//! `PreparedExistingRows.commit` grows `memberships` up to `highest_scope_id`
//! unconditionally, but `prepare` reserves that capacity only when the incoming
//! row list is non-empty. With an empty list `highest_scope_id` stays at the root
//! scope, so a site reconciled to nothing while the membership table has never
//! held anything reaches `appendAssumeCapacity` with no capacity at all - a safety
//! panic in a checked build and an out-of-bounds write in a fast one. Every
//! generated program here starts from an empty list, so `World.mount` seeds the
//! root's membership slot; without that one crash would mask every other oracle.
//! Remove the seed once the reservation covers the empty case.
//!
//! # Not covered
//!
//! `applyMetadata` releasing step-owned resources is asserted but cannot be
//! falsified by mutating the engine: `PreparedSubtreeRetirement` has no hooks and
//! so has nothing to release with. That oracle is a guard on the harness's own
//! discipline - it fails if someone later lets prepared retirement stand in for
//! disposal - rather than a property of the engine that could regress.
//!
//! No allocation-failure sweep. `fuzz-structural.zig` owns fault placement, and
//! the prepared paths here are driven only on their success path; `prepare`'s
//! `abort` path is implemented in the hooks but never reached, because nothing
//! injects a failure. A sweep belongs in this file eventually.
//!
//! Nothing renders. Row render segments, move planning, and
//! `diffPreservesSurvivorRenderOrder` are structural-splice concerns; this target
//! stops at identity, membership, and lifecycle.
//!
//! To replay a crash:
//!   python3 scripts/fuzz.py repro keyed-scopes <crash-file> --verbose

const std = @import("std");
const signals = @import("signals");
const FuzzReader = @import("FuzzReader.zig");

const each = signals.each_runtime;
const ids = signals.ids;
const scope_runtime = signals.scope_runtime;
const scope_tree = signals.scope_tree;

const Generation = ids.Generation;
const ScopeId = ids.ScopeId;
const SiteOrdinal = ids.SiteOrdinal;

/// Keys the generator may ever mint. Small on purpose: a pool this size
/// guarantees remove-then-reinsert revisits an identity whose scope has already
/// retired, instead of always minting a key nobody has seen.
const key_pool_size: u32 = 10;
const max_ops = 24;

const component_ordinal = SiteOrdinal.fromRaw(1);
const when_ordinal = SiteOrdinal.fromRaw(2);
/// The long-lived site under the component scope: every list operation lands here.
const site_a_ordinal = SiteOrdinal.fromRaw(7);
/// The site under the `when` branch: retired and re-interned by every flip.
const site_b_ordinal = SiteOrdinal.fromRaw(8);

const Key = u32;

/// The `Row` payload `scope_tree` and `scope_runtime` are instantiated over.
///
/// `site_ordinal` is the field `activeEachRows` requires; the rest is what a real
/// row step owns, reduced to values a fuzz harness can account for exactly.
const Row = struct {
    site_ordinal: SiteOrdinal,
    key: Key,
    key_hash: u64,
};

const Scope = scope_tree.Scope(Row);

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

    const program = generate(&reader, arena_state.allocator()) catch fail("program arena exhausted", .{});
    if (debug) printProgram(program);

    var gpa_state = std.heap.DebugAllocator(.{}){};
    const gpa = gpa_state.allocator();

    run(gpa, program, debug);
    checkDuplicates(gpa, program.hash_buckets, debug);
    checkRowRemovals(gpa, &reader, program.hash_buckets, debug);
    checkRowRemovals(gpa, &reader, 1, debug);
    checkBarrier(gpa, &reader, debug);

    if (gpa_state.deinit() != .ok) fail("keyed-scope run leaked memory", .{});
}

// -------------------------------------------------------------------------
// Program
// -------------------------------------------------------------------------

const Op = union(enum) {
    /// Inserts `key` at `position`, or updates it in place when it is already live.
    insert: struct { key: Key, position: u8, version: u8 },
    remove: u8,
    update: struct { index: u8, version: u8 },
    swap: struct { left: u8, right: u8 },
    reverse,
    rotate: u8,
    /// Removes the key at `index` and reinserts the same key at `position`,
    /// which revisits one identity inside a single reconciliation.
    reinsert: struct { index: u8, position: u8 },
    /// Retires the `when` branch subtree, including site B and every row it owns,
    /// then interns the opposite branch.
    flip_branch,
    /// Advances the dirty generation, which is what makes slots retired in an
    /// earlier generation reusable again.
    advance_generation,
};

const Program = struct {
    /// Buckets `hashKey` folds keys into. One means every key collides.
    hash_buckets: u32,
    ops: []const Op,
};

fn generate(reader: *FuzzReader, arena: std.mem.Allocator) std.mem.Allocator.Error!Program {
    const hash_buckets = reader.intRangeAtMost(u32, 1, key_pool_size);
    const ops = try arena.alloc(Op, reader.intRangeAtMost(usize, 0, max_ops));
    for (ops) |*op| op.* = generateOp(reader);
    return .{ .hash_buckets = hash_buckets, .ops = ops };
}

fn generateOp(reader: *FuzzReader) Op {
    return switch (reader.intRangeAtMost(u8, 0, 11)) {
        // Insert is drawn three times as often as anything else so a program
        // starting from an empty list still reaches interesting lengths before it
        // spends its operations permuting nothing.
        0, 1, 2 => .{ .insert = .{
            .key = reader.intRangeLessThan(Key, 0, key_pool_size),
            .position = reader.readByte(),
            .version = reader.readByte(),
        } },
        3, 4 => .{ .remove = reader.readByte() },
        5 => .{ .update = .{ .index = reader.readByte(), .version = reader.readByte() } },
        6 => .{ .swap = .{ .left = reader.readByte(), .right = reader.readByte() } },
        7 => .reverse,
        8 => .{ .rotate = reader.readByte() },
        9 => .{ .reinsert = .{ .index = reader.readByte(), .position = reader.readByte() } },
        10 => .flip_branch,
        else => .advance_generation,
    };
}

fn printProgram(program: Program) void {
    std.debug.print("hash buckets: {d}\n", .{program.hash_buckets});
    std.debug.print("operations: {d}\n", .{program.ops.len});
    for (program.ops, 0..) |op, index| switch (op) {
        .insert => |step| std.debug.print("  {d}: insert key {d} at {d} version {d}\n", .{ index, step.key, step.position, step.version }),
        .remove => |at| std.debug.print("  {d}: remove {d}\n", .{ index, at }),
        .update => |step| std.debug.print("  {d}: update {d} to version {d}\n", .{ index, step.index, step.version }),
        .swap => |step| std.debug.print("  {d}: swap {d} and {d}\n", .{ index, step.left, step.right }),
        .reverse => std.debug.print("  {d}: reverse\n", .{index}),
        .rotate => |by| std.debug.print("  {d}: rotate by {d}\n", .{ index, by }),
        .reinsert => |step| std.debug.print("  {d}: reinsert {d} at {d}\n", .{ index, step.index, step.position }),
        .flip_branch => std.debug.print("  {d}: flip branch\n", .{index}),
        .advance_generation => std.debug.print("  {d}: advance generation\n", .{index}),
    };
}

// -------------------------------------------------------------------------
// Reference model
// -------------------------------------------------------------------------

/// The slow, obviously correct list the engine is judged against.
///
/// Keys and versions live in plain parallel lists spliced from scratch, so the
/// model shares no code and no data structure with the row tables it checks.
const Model = struct {
    keys: std.ArrayListUnmanaged(Key) = .empty,
    versions: std.ArrayListUnmanaged(u32) = .empty,

    fn deinit(self: *Model, allocator: std.mem.Allocator) void {
        self.keys.deinit(allocator);
        self.versions.deinit(allocator);
    }

    fn find(self: *const Model, key: Key) ?usize {
        for (self.keys.items, 0..) |item, index| if (item == key) return index;
        return null;
    }

    fn wrap(self: *const Model, raw: u8, extra: usize) usize {
        return @as(usize, raw) % (self.keys.items.len + extra);
    }

    /// Applies one operation, keeping the list free of duplicate keys.
    ///
    /// Duplicates are a Roc-side diagnostic that terminates the host, so they are
    /// never generated into the live program; they are probed separately against
    /// a scratch world. An `insert` naming a live key therefore becomes an
    /// in-place version update, which is itself a shape worth reaching often.
    fn apply(self: *Model, allocator: std.mem.Allocator, op: Op) std.mem.Allocator.Error!void {
        switch (op) {
            .insert => |step| {
                if (self.find(step.key)) |index| {
                    self.versions.items[index] = step.version;
                    return;
                }
                const at = self.wrap(step.position, 1);
                try self.keys.insert(allocator, at, step.key);
                try self.versions.insert(allocator, at, step.version);
            },
            .remove => |raw| {
                if (self.keys.items.len == 0) return;
                const at = self.wrap(raw, 0);
                _ = self.keys.orderedRemove(at);
                _ = self.versions.orderedRemove(at);
            },
            .update => |step| {
                if (self.keys.items.len == 0) return;
                self.versions.items[self.wrap(step.index, 0)] = step.version;
            },
            .swap => |step| {
                if (self.keys.items.len < 2) return;
                const left = self.wrap(step.left, 0);
                const right = self.wrap(step.right, 0);
                std.mem.swap(Key, &self.keys.items[left], &self.keys.items[right]);
                std.mem.swap(u32, &self.versions.items[left], &self.versions.items[right]);
            },
            .reverse => {
                std.mem.reverse(Key, self.keys.items);
                std.mem.reverse(u32, self.versions.items);
            },
            .rotate => |raw| {
                if (self.keys.items.len < 2) return;
                const by = self.wrap(raw, 0);
                std.mem.rotate(Key, self.keys.items, by);
                std.mem.rotate(u32, self.versions.items, by);
            },
            .reinsert => |step| {
                if (self.keys.items.len == 0) return;
                const from = self.wrap(step.index, 0);
                const key = self.keys.orderedRemove(from);
                const version = self.versions.orderedRemove(from);
                const to = self.wrap(step.position, 1);
                try self.keys.insert(allocator, to, key);
                try self.versions.insert(allocator, to, version);
            },
            .flip_branch, .advance_generation => {},
        }
    }
};

// -------------------------------------------------------------------------
// Worlds
// -------------------------------------------------------------------------

const Mode = enum { eager, prepared };

/// One incoming key, carrying the ledger token that proves it was consumed once.
const IncomingKey = struct { key: Key, token: usize };
/// One incoming item, carrying the ledger token that proves it was consumed once.
const IncomingItem = struct { version: u32, token: usize };

/// The key and item a live row scope owns. `null` means the scope owns nothing,
/// which is the only legal state for a retired scope.
const RowValues = struct { key: Key, version: u32, hash: u64 };

const Provisional = struct { scope_id: ScopeId, values: RowValues };

/// One instantiation of the identity machinery, and the hook surface every
/// engine seam calls back into.
///
/// Two of these run side by side over the same generated program - one eager, one
/// prepared - and their observable state is compared after every operation.
/// Because every hook lives here, the harness is also the ownership ledger:
/// nothing can be created, replaced, dropped, or disposed without passing
/// through this struct, which is what makes "consumed exactly once" assertable.
const World = struct {
    allocator: std.mem.Allocator,
    mode: Mode,
    hash_buckets: u32,

    scopes: std.ArrayListUnmanaged(Scope) = .empty,
    sites: std.ArrayListUnmanaged(each.Site) = .empty,
    site_indexes: each.SiteIndexMap = .empty,
    memberships: std.ArrayListUnmanaged(?each.Membership) = .empty,
    /// Row-owned values indexed by scope index, parallel to `scopes`.
    row_values: std.ArrayListUnmanaged(?RowValues) = .empty,

    root: ScopeId = ids.root_scope,
    component: ScopeId = ids.root_scope,
    branch_scope: ScopeId = ids.root_scope,
    branch: scope_tree.Branch = .true_branch,

    generation: Generation = ids.initial_generation,

    /// Consumption count per incoming key/item token for the reconciliation in
    /// flight. Exactly one is the only acceptable final value for every entry.
    ledger: std.ArrayListUnmanaged(u8) = .empty,
    /// Rows `prepare` created that `commit` has not yet published.
    provisional: std.ArrayListUnmanaged(Provisional) = .empty,
    /// Scope ids the last subtree retirement visited, in the order it visited
    /// them, so the eager and prepared post-orders can be compared.
    disposal_order: std.ArrayListUnmanaged(ScopeId) = .empty,
    /// The site whose owning descriptor is going away, so `siteRemainsActive`
    /// answers for it rather than for the sites that are staying.
    retiring_site: ?each.SiteKey = null,
    /// Scope ids retired in `generation`, which the barrier must keep blocked.
    retired_here: std.ArrayListUnmanaged(ScopeId) = .empty,
    /// Retired scope ids not yet handed back out, for the stale-aliasing oracle.
    retired_ever: std.ArrayListUnmanaged(ScopeId) = .empty,
    duplicate: ?each.DuplicateKeyInfo = null,
    live_scopes: usize = 0,
    /// High-water mark of live scopes plus barrier-blocked ones, which is the
    /// exact bound the scope array is allowed to grow to.
    slot_high_water: usize = 0,

    fn init(allocator: std.mem.Allocator, mode: Mode, hash_buckets: u32) World {
        return .{ .allocator = allocator, .mode = mode, .hash_buckets = hash_buckets };
    }

    fn deinit(self: *World) void {
        each.clearSites(self.allocator, &self.sites, &self.site_indexes, &self.memberships);
        self.scopes.deinit(self.allocator);
        self.row_values.deinit(self.allocator);
        self.ledger.deinit(self.allocator);
        self.provisional.deinit(self.allocator);
        self.disposal_order.deinit(self.allocator);
        self.retired_here.deinit(self.allocator);
        self.retired_ever.deinit(self.allocator);
    }

    fn name(self: *const World) []const u8 {
        return @tagName(self.mode);
    }

    // --- scope forest -----------------------------------------------------

    /// Predicts the scope id the next intern must return.
    ///
    /// `scope_tree` reuses the lowest-indexed inactive slot the barrier does not
    /// block and appends only when there is none. Predicting the id rather than
    /// sampling "was it fresh?" is what makes both directions of the reuse
    /// barrier one oracle: over-blocking shows up as an unexpected append and
    /// under-blocking as an unexpected reuse.
    ///
    /// The comparison is re-spelled here rather than delegated to `blocksReuse`
    /// on purpose. A model that called the function it is checking would agree
    /// with any change to it.
    fn expectedInternId(self: *const World) ScopeId {
        for (self.scopes.items) |scope| {
            if (scope.lifecycle.isActive()) continue;
            if (scope.lifecycle.retiredGeneration()) |retired| {
                if (retired == self.generation) continue;
            }
            return scope.scope_id;
        }
        return ScopeId.fromIndex(self.scopes.items.len);
    }

    fn noteInterned(self: *World, expected: ScopeId, actual: ScopeId, what: []const u8) void {
        if (expected != actual) fail(
            "{s} world interned {s} as scope {d}, but the reuse barrier at generation {d} predicts scope {d}",
            .{ self.name(), what, actual.raw(), self.generation.raw(), expected.raw() },
        );
        while (self.row_values.items.len <= actual.index()) {
            self.row_values.append(self.allocator, null) catch fail("out of memory", .{});
        }
        self.live_scopes += 1;
        removeId(&self.retired_ever, actual);
        self.noteSlotDemand();
    }

    fn noteSlotDemand(self: *World) void {
        self.slot_high_water = @max(self.slot_high_water, self.live_scopes + self.retired_here.items.len);
    }

    /// Builds the scope forest this target reconciles into.
    fn mount(self: *World) void {
        const root = scope_tree.internRoot(Row, self.allocator, &self.scopes) catch fail("root intern failed", .{});
        self.root = root.scope_id;
        self.noteInterned(self.root, self.root, "the root");

        const expected = self.expectedInternId();
        const component = scope_tree.internComponent(Row, self.allocator, &self.scopes, self.root, component_ordinal, self.generation) catch
            fail("component intern failed", .{});
        self.component = component.scope_id;
        self.noteInterned(expected, self.component, "the component");

        self.internBranch();
        _ = each.ensureSiteIndex(self.allocator, &self.sites, &self.site_indexes, self.component, site_a_ordinal);

        // Works around a live defect rather than hiding one. `PreparedExistingRows.commit`
        // grows `memberships` up to `highest_scope_id` unconditionally, but `prepare`
        // reserves that capacity only when the incoming row list is non-empty; with an
        // empty list `highest_scope_id` stays at the root scope, so a site reconciled to
        // nothing while the membership table has never held anything reaches
        // `appendAssumeCapacity` with no capacity at all. Every generated program starts
        // from an empty list, so leaving it unseeded would mask every other oracle behind
        // that one crash. Seeding the root's slot is what the engine's own membership
        // table looks like the moment any row has ever existed.
        _ = each.ensureMembershipSlot(self.allocator, &self.memberships, self.root);
    }

    fn internBranch(self: *World) void {
        const expected = self.expectedInternId();
        const result = scope_tree.internWhenBranch(Row, self.allocator, &self.scopes, self.root, when_ordinal, self.branch, self.generation) catch
            fail("branch intern failed", .{});
        self.branch_scope = result.scope_id;
        self.noteInterned(expected, self.branch_scope, "the when branch");
        _ = each.ensureSiteIndex(self.allocator, &self.sites, &self.site_indexes, self.branch_scope, site_b_ordinal);
    }

    fn siteIndex(self: *const World, parent: ScopeId, ordinal: SiteOrdinal) usize {
        return each.activeSiteIndex(&self.site_indexes, parent, ordinal) orelse
            fail("{s} world lost the site index for parent {d} ordinal {d}", .{ self.name(), parent.raw(), ordinal.raw() });
    }

    fn rowScopeIds(self: *const World, parent: ScopeId, ordinal: SiteOrdinal) []const ScopeId {
        return self.sites.items[self.siteIndex(parent, ordinal)].scope_ids.items;
    }

    /// Returns the scope currently holding `key` at one site, or null.
    fn rowScopeForKey(self: *const World, parent: ScopeId, ordinal: SiteOrdinal, key: Key) ?ScopeId {
        for (self.rowScopeIds(parent, ordinal)) |scope_id| {
            const values = self.row_values.items[scope_id.index()] orelse continue;
            if (values.key == key) return scope_id;
        }
        return null;
    }

    // --- reconciliation ---------------------------------------------------

    /// Reconciles one site to `keys`/`versions` through whichever seam this world
    /// owns, with the incoming ownership ledger armed across the call.
    fn sync(self: *World, parent: ScopeId, ordinal: SiteOrdinal, keys: []const Key, versions: []const u32) void {
        const incoming_keys = self.allocator.alloc(IncomingKey, keys.len) catch fail("out of memory", .{});
        defer self.allocator.free(incoming_keys);
        const incoming_items = self.allocator.alloc(IncomingItem, versions.len) catch fail("out of memory", .{});
        defer self.allocator.free(incoming_items);

        self.ledger.clearRetainingCapacity();
        self.ledger.appendNTimes(self.allocator, 0, keys.len * 2) catch fail("out of memory", .{});
        for (keys, versions, 0..) |key, version, index| {
            incoming_keys[index] = .{ .key = key, .token = index };
            incoming_items[index] = .{ .version = version, .token = keys.len + index };
        }

        const site_index = self.siteIndex(parent, ordinal);
        switch (self.mode) {
            .eager => {
                var result = each.syncRows(self.allocator, &self.sites, &self.memberships, site_index, parent, ordinal, incoming_keys, incoming_items, self);
                result.deinit(self.allocator);
            },
            .prepared => {
                var prepared = each.PreparedExistingRows.prepare(self.allocator, &self.sites, &self.memberships, site_index, parent, ordinal, incoming_keys, incoming_items, self) catch |err|
                    fail("{s} world could not prepare a reconciliation: {s}", .{ self.name(), @errorName(err) });
                var result = prepared.commit(&self.sites, &self.memberships, incoming_keys, incoming_items, self);
                prepared.deinit();
                result.deinit(self.allocator);
            },
        }

        for (self.ledger.items, 0..) |count, token| {
            if (count != 1) fail(
                "{s} world consumed incoming value {d} of {d} exactly {d} times",
                .{ self.name(), token, self.ledger.items.len, count },
            );
        }
        if (self.provisional.items.len != 0) {
            fail("{s} world left {d} prepared rows unpublished", .{ self.name(), self.provisional.items.len });
        }
    }

    /// Retires the `when` branch subtree and interns the opposite branch.
    ///
    /// Rows leave the site index through `prepareRowRemovals`/`apply`, which is
    /// the engine's own path and the one that compacts the emptied site out of
    /// the site table with a `swapRemove` and repairs the moved site's row
    /// memberships. Lifecycle then retires through whichever disposal seam this
    /// world owns.
    fn flipBranch(self: *World) void {
        self.removeSiteRows(self.branch_scope, site_b_ordinal);
        if (each.activeSiteIndex(&self.site_indexes, self.branch_scope, site_b_ordinal) != null) {
            fail("{s} world kept the site table entry of the branch it is retiring", .{self.name()});
        }
        self.retireSubtree(self.branch_scope);
        self.branch = self.branch.opposite();
        self.internBranch();
    }

    /// Takes every row of one site out of the row index because the descriptor
    /// that owned the site is going away.
    ///
    /// This is the engine's own path: `prepareRowRemovals` validates the exact
    /// removals against live memberships, and `apply` unlinks them and then
    /// compacts the emptied site out of the site table with a `swapRemove`,
    /// repairing the moved site's row memberships as it goes. Subtree retirement
    /// is a separate step afterwards, because retirement is not disposal.
    fn removeSiteRows(self: *World, parent: ScopeId, ordinal: SiteOrdinal) void {
        const site_index = self.siteIndex(parent, ordinal);
        const rows = self.sites.items[site_index].scope_ids.items;
        const removals = self.allocator.alloc(each.RowRemoval, rows.len) catch fail("out of memory", .{});
        defer self.allocator.free(removals);
        for (rows, removals) |scope_id, *removal| {
            removal.* = .{ .scope_id = scope_id, .key_hash = self.rowKeyHash(scope_id) };
        }

        self.retiring_site = .{ .parent_scope_id = parent, .site_ordinal = ordinal };
        var prepared_removals = each.prepareRowRemovals(self.allocator, self.sites.items, self.memberships.items, removals) catch |err|
            fail("{s} world could not prepare row removals: {s}", .{ self.name(), @errorName(err) });
        prepared_removals.apply(self.allocator, &self.sites, &self.site_indexes, &self.memberships, self);
        prepared_removals.deinit(self.allocator);
        self.retiring_site = null;
    }

    /// Retires one subtree through whichever seam this world owns, leaving the
    /// visited order in `disposal_order`.
    fn retireSubtree(self: *World, root_scope_id: ScopeId) void {
        self.disposal_order.clearRetainingCapacity();
        switch (self.mode) {
            .eager => scope_runtime.disposeSubtree(Row, self.scopes.items, root_scope_id, self.generation, self),
            .prepared => self.retirePrepared(root_scope_id),
        }
    }

    /// Retires a subtree through the prepared path, asserting that flipping
    /// lifecycle released nothing.
    ///
    /// This is the distinction the prepared world exists to keep honest:
    /// `applyMetadata` is allocation-free metadata only, so a harness that let it
    /// stand in for disposal would report a balanced ledger for an engine that
    /// leaked every step it retired this way.
    fn retirePrepared(self: *World, root_scope_id: ScopeId) void {
        var retirement = scope_runtime.prepareSubtreeRetirement(Row, self.allocator, self.scopes.items, root_scope_id) catch |err|
            fail("{s} world could not prepare subtree retirement: {s}", .{ self.name(), @errorName(err) });
        defer retirement.deinit(self.allocator);

        self.disposal_order.appendSlice(self.allocator, retirement.scope_ids) catch fail("out of memory", .{});

        const owned_before = self.countOwnedRowValues();
        retirement.applyMetadata(Row, self.scopes.items, self.generation);
        const owned_after = self.countOwnedRowValues();
        if (owned_before != owned_after) fail(
            "{s} world saw applyMetadata release {d} row values; it must only flip lifecycle",
            .{ self.name(), owned_before - owned_after },
        );

        for (retirement.scope_ids) |scope_id| {
            self.releaseRowValues(scope_id);
            self.recordRetired(scope_id);
        }
    }

    fn countOwnedRowValues(self: *const World) usize {
        var owned: usize = 0;
        for (self.row_values.items) |values| {
            if (values != null) owned += 1;
        }
        return owned;
    }

    fn releaseRowValues(self: *World, scope_id: ScopeId) void {
        if (scope_id.index() < self.row_values.items.len) self.row_values.items[scope_id.index()] = null;
    }

    fn recordRetired(self: *World, scope_id: ScopeId) void {
        self.live_scopes -= 1;
        self.retired_here.append(self.allocator, scope_id) catch fail("out of memory", .{});
        self.retired_ever.append(self.allocator, scope_id) catch fail("out of memory", .{});
        self.noteSlotDemand();
    }

    fn advanceGeneration(self: *World) void {
        self.generation = Generation.fromRaw(self.generation.raw() + 1);
        self.retired_here.clearRetainingCapacity();
    }

    fn teardown(self: *World) void {
        self.removeSiteRows(self.component, site_a_ordinal);
        self.removeSiteRows(self.branch_scope, site_b_ordinal);
        self.retireSubtree(self.root);
    }

    // --- hooks: keys and items -------------------------------------------

    fn consume(self: *World, token: usize) void {
        if (token >= self.ledger.items.len) fail("{s} world was handed an unknown ownership token {d}", .{ self.name(), token });
        self.ledger.items[token] += 1;
    }

    /// Reports whether h key is present in maintained state.
    pub fn hashKey(self: *World, key: IncomingKey) u64 {
        return self.hashOf(key.key);
    }

    fn hashOf(self: *const World, key: Key) u64 {
        return @as(u64, key % self.hash_buckets);
    }

    /// Compares candidate row keys exactly after hash lookup, preserving collision correctness.
    pub fn nextKeysEqual(_: *World, left: IncomingKey, right: IncomingKey) bool {
        return left.key == right.key;
    }

    /// Confirms an indexed key match through the key capability to handle hash collisions exactly.
    pub fn existingKeyEquals(self: *World, scope_id: ScopeId, key: IncomingKey) bool {
        return self.rowValues(scope_id).key == key.key;
    }

    /// Performs row item equals through the keyed-row capabilities that own key and item values.
    pub fn rowItemEquals(self: *World, scope_id: ScopeId, item: IncomingItem) bool {
        return self.rowValues(scope_id).version == item.version;
    }

    /// Performs row key hash through the keyed-row capabilities that own key and item values.
    pub fn rowKeyHash(self: *World, scope_id: ScopeId) u64 {
        return self.rowValues(scope_id).hash;
    }

    fn rowValues(self: *const World, scope_id: ScopeId) RowValues {
        if (scope_id.index() >= self.row_values.items.len) {
            fail("{s} world was asked for row values of unknown scope {d}", .{ self.name(), scope_id.raw() });
        }
        return self.row_values.items[scope_id.index()] orelse
            fail("{s} world was asked for row values of scope {d}, which owns none", .{ self.name(), scope_id.raw() });
    }

    /// Drops the provisional incoming key through its owning capability.
    pub fn dropIncomingKey(self: *World, key: IncomingKey) void {
        self.consume(key.token);
    }

    /// Drops the provisional incoming item through its owning capability.
    pub fn dropIncomingItem(self: *World, item: IncomingItem) void {
        self.consume(item.token);
    }

    /// Replaces row key while releasing displaced ownership exactly once.
    pub fn replaceRowKey(self: *World, scope_id: ScopeId, hash: u64, key: IncomingKey) void {
        self.consume(key.token);
        if (hash != self.hashOf(key.key)) {
            fail("{s} world was handed hash {d} for a replaced row key that hashes to {d}", .{ self.name(), hash, self.hashOf(key.key) });
        }
        var values = self.rowValues(scope_id);
        values.key = key.key;
        values.hash = hash;
        self.row_values.items[scope_id.index()] = values;
    }

    /// Replaces row item while releasing displaced ownership exactly once.
    pub fn replaceRowItem(self: *World, scope_id: ScopeId, item: IncomingItem) void {
        self.consume(item.token);
        var values = self.rowValues(scope_id);
        values.version = item.version;
        self.row_values.items[scope_id.index()] = values;
    }

    // --- hooks: row lifecycle --------------------------------------------

    fn appendRowScope(self: *World, parent_scope_id: ScopeId, site_ordinal: SiteOrdinal, hash: u64, key: Key) ScopeId {
        const expected = self.expectedInternId();
        const result = scope_tree.appendEachRow(Row, self.allocator, &self.scopes, parent_scope_id, .{
            .site_ordinal = site_ordinal,
            .key = key,
            .key_hash = hash,
        }, self.generation) catch |err| fail("{s} world could not append a row scope: {s}", .{ self.name(), @errorName(err) });
        self.noteInterned(expected, result.scope_id, "a keyed row");
        return result.scope_id;
    }

    /// Creates a new keyed row scope and transfers the incoming key and item into its ownership.
    pub fn createRow(self: *World, parent_scope_id: ScopeId, site_ordinal: SiteOrdinal, hash: u64, key: IncomingKey, item: IncomingItem) ScopeId {
        self.consume(key.token);
        self.consume(item.token);
        const scope_id = self.appendRowScope(parent_scope_id, site_ordinal, hash, key.key);
        self.row_values.items[scope_id.index()] = .{ .key = key.key, .version = item.version, .hash = hash };
        return scope_id;
    }

    /// Owns a provisional created row without publishing key/item tables.
    pub fn prepareCreatedRow(self: *World, allocator: std.mem.Allocator, parent_scope_id: ScopeId, site_ordinal: SiteOrdinal, input_index: usize, hash: u64, key: IncomingKey, item: IncomingItem) std.mem.Allocator.Error!ScopeId {
        _ = allocator;
        _ = input_index;
        self.consume(key.token);
        self.consume(item.token);
        const scope_id = self.appendRowScope(parent_scope_id, site_ordinal, hash, key.key);
        try self.provisional.append(self.allocator, .{
            .scope_id = scope_id,
            .values = .{ .key = key.key, .version = item.version, .hash = hash },
        });
        return scope_id;
    }

    /// Publishes one previously prepared created row without allocation.
    pub fn commitCreatedRow(self: *World, scope_id: ScopeId) void {
        for (self.provisional.items) |entry| if (entry.scope_id == scope_id) {
            self.row_values.items[scope_id.index()] = entry.values;
            return;
        };
        fail("{s} world was asked to commit an unprepared row scope {d}", .{ self.name(), scope_id.raw() });
    }

    /// Reserves disposal journal capacity before prepared row publication.
    pub fn prepareExistingRowsCommit(self: *World, allocator: std.mem.Allocator, removed_count: usize) std.mem.Allocator.Error!void {
        try self.disposal_order.ensureUnusedCapacity(allocator, removed_count);
        try self.retired_here.ensureUnusedCapacity(self.allocator, removed_count);
        try self.retired_ever.ensureUnusedCapacity(self.allocator, removed_count);
    }

    /// Drops all provisional created rows without changing persistent key/item tables.
    pub fn abortPreparedRows(self: *World) void {
        for (self.provisional.items) |entry| {
            self.scopes.items[entry.scope_id.index()].lifecycle = .{ .retired = self.generation };
            self.recordRetired(entry.scope_id);
        }
        self.provisional.clearRetainingCapacity();
    }

    /// Clears provisional bookkeeping after ownership transfers to persistent rows.
    pub fn finishPreparedRowsCommit(self: *World) void {
        self.provisional.clearRetainingCapacity();
    }

    /// Disposes a removed row scope and every render, effect, callable, and value it owns.
    pub fn disposeScope(self: *World, scope_id: ScopeId) void {
        self.retireSubtree(scope_id);
    }

    // --- hooks: metrics and diagnostics ----------------------------------

    /// Records each sync in the metrics or lifecycle state owned by this operation.
    pub fn recordEachSync(_: *World, _: usize, _: usize) void {}

    /// Records rows in the metrics or lifecycle state owned by this operation.
    pub fn recordRows(_: *World, _: u64, _: u64, _: u64) void {}

    /// Reports whether a site's owning descriptor is still live, which is what
    /// decides whether an emptied site keeps its place in the site table.
    pub fn siteRemainsActive(self: *World, key: each.SiteKey) bool {
        const retiring = self.retiring_site orelse return true;
        return !(retiring.parent_scope_id == key.parent_scope_id and retiring.site_ordinal == key.site_ordinal);
    }

    /// Rejects a duplicate keyed row at the narrow reconciliation boundary with a bounded diagnostic.
    ///
    /// The engine's real caller is `noreturn` and terminates the host. A fuzz
    /// target has to survive in order to assert anything, so this records the
    /// diagnostic and returns; the scratch world that provoked it is discarded
    /// rather than reconciled further. See the module comment.
    pub fn failDuplicateEachKey(self: *World, parent_scope_id: ScopeId, site_ordinal: SiteOrdinal, first_index: usize, second_index: usize, key: IncomingKey) void {
        _ = parent_scope_id;
        _ = site_ordinal;
        _ = key;
        if (self.duplicate != null) return;
        self.duplicate = .{ .first_index = first_index, .second_index = second_index };
    }

    // --- hooks: subtree disposal -----------------------------------------

    /// Retires node identities so disposed scope identity cannot be routed again.
    pub fn deactivateNodeIdentities(_: *World, _: ScopeId) void {}

    /// Appends cleanup events using capacity that must already satisfy the caller's transaction contract.
    pub fn appendCleanupEvents(_: *World, _: ScopeId) void {}

    /// Cancels pending tasks and releases its bounded host-retained work.
    pub fn cancelPendingTasks(_: *World, _: ScopeId) void {}

    /// Retires dom identities so disposed scope identity cannot be routed again.
    pub fn deactivateDomIdentities(_: *World, _: ScopeId) void {}

    /// Removes each row and releases the ownership attached to that live entry.
    ///
    /// A row still holding a membership is one this disposal owns unlinking; a
    /// row whose membership is already gone was unlinked by the reconciler that
    /// is rebuilding the whole row table, or by a prepared removal, and unlinking
    /// it twice would corrupt the index.
    pub fn removeEachRow(self: *World, scope_id: ScopeId, key_hash: u64) void {
        if (scope_id.index() >= self.memberships.items.len) return;
        if (self.memberships.items[scope_id.index()] == null) return;
        each.removeRowFromSiteIndex(&self.sites, &self.memberships, scope_id, key_hash, self);
    }

    /// Releases scope step and all host registrations or retained values it owns.
    ///
    /// `disposeSubtree` hands over the step by pointer and not the scope id, so
    /// the owner is recovered by pointer identity into this world's own scope
    /// array. Matching on the row's contents would not do: two rows may carry the
    /// same key at different times, and a retired row carries stale contents.
    pub fn deinitScopeStep(self: *World, step: *scope_tree.Step(Row)) void {
        const scope: *Scope = @fieldParentPtr("step", step);
        const offset = @intFromPtr(scope) - @intFromPtr(self.scopes.items.ptr);
        const index = offset / @sizeOf(Scope);
        if (index >= self.scopes.items.len or offset % @sizeOf(Scope) != 0) {
            fail("{s} world was asked to release a step outside its scope array", .{self.name()});
        }
        const scope_id = self.scopes.items[index].scope_id;
        self.disposal_order.append(self.allocator, scope_id) catch fail("out of memory", .{});
        self.releaseRowValues(scope_id);
        self.recordRetired(scope_id);
    }

    /// Records scope disposed in the metrics or lifecycle state owned by this operation.
    pub fn recordScopeDisposed(_: *World) void {}
};

fn removeId(list: *std.ArrayListUnmanaged(ScopeId), scope_id: ScopeId) void {
    var index: usize = 0;
    while (index < list.items.len) {
        if (list.items[index] == scope_id) {
            _ = list.orderedRemove(index);
        } else {
            index += 1;
        }
    }
}

// -------------------------------------------------------------------------
// The run
// -------------------------------------------------------------------------

/// Scope ids one site held before an operation, indexed by key, so a survivor
/// can be asked whether it kept its identity.
const Survivors = [key_pool_size]?ScopeId;

fn snapshotSurvivors(world: *const World, parent: ScopeId, ordinal: SiteOrdinal) Survivors {
    var survivors: Survivors = @splat(null);
    for (0..key_pool_size) |key| survivors[key] = world.rowScopeForKey(parent, ordinal, @intCast(key));
    return survivors;
}

fn run(gpa: std.mem.Allocator, program: Program, debug: bool) void {
    var model = Model{};
    defer model.deinit(gpa);

    var eager = World.init(gpa, .eager, program.hash_buckets);
    defer eager.deinit();
    var prepared = World.init(gpa, .prepared, program.hash_buckets);
    defer prepared.deinit();

    setPhase("at the mount", .{});
    eager.mount();
    prepared.mount();
    checkWorlds(gpa, &model, &eager, &prepared);

    for (program.ops, 0..) |op, index| {
        setPhase("after operation {d} ({s})", .{ index, @tagName(op) });
        if (debug) std.debug.print("running operation {d} ({s})\n", .{ index, @tagName(op) });

        const before_a = [_]Survivors{ snapshotSurvivors(&eager, eager.component, site_a_ordinal), snapshotSurvivors(&prepared, prepared.component, site_a_ordinal) };
        const before_b = [_]Survivors{ snapshotSurvivors(&eager, eager.branch_scope, site_b_ordinal), snapshotSurvivors(&prepared, prepared.branch_scope, site_b_ordinal) };

        model.apply(gpa, op) catch fail("model ran out of memory", .{});
        switch (op) {
            .flip_branch => {
                eager.flipBranch();
                prepared.flipBranch();
                checkDisposalOrder(&eager, &prepared);
            },
            .advance_generation => {
                eager.advanceGeneration();
                prepared.advanceGeneration();
            },
            else => {},
        }

        for ([_]*World{ &eager, &prepared }) |world| {
            world.sync(world.component, site_a_ordinal, model.keys.items, model.versions.items);
            world.sync(world.branch_scope, site_b_ordinal, model.keys.items, model.versions.items);
        }

        checkWorlds(gpa, &model, &eager, &prepared);
        for ([_]*World{ &eager, &prepared }, before_a) |world, before| {
            checkSurvivors(world, world.component, site_a_ordinal, before);
        }
        // A flip discards site B entirely, so its rows are expected to be new.
        if (op != .flip_branch) {
            for ([_]*World{ &eager, &prepared }, before_b) |world, before| {
                checkSurvivors(world, world.branch_scope, site_b_ordinal, before);
            }
        }
    }

    setPhase("at teardown", .{});
    eager.teardown();
    prepared.teardown();
    checkDisposalOrder(&eager, &prepared);
    for ([_]*World{ &eager, &prepared }) |world| checkTeardown(world);
}

/// Asserts a key live before and after an operation kept its scope id.
///
/// A reconciler that rebuilds instead of moving still produces the right order
/// and the right counts; only identity says it happened.
fn checkSurvivors(world: *const World, parent: ScopeId, ordinal: SiteOrdinal, before: Survivors) void {
    for (before, 0..) |maybe_scope_id, key| {
        const previous = maybe_scope_id orelse continue;
        const current = world.rowScopeForKey(parent, ordinal, @intCast(key)) orelse continue;
        if (previous != current) fail(
            "{s} world rebuilt surviving key {d} as scope {d}; it held scope {d}",
            .{ world.name(), key, current.raw(), previous.raw() },
        );
    }
}

/// Asserts both worlds retired the same scopes in the same post-order.
fn checkDisposalOrder(eager: *const World, prepared: *const World) void {
    const left = eager.disposal_order.items;
    const right = prepared.disposal_order.items;
    if (left.len != right.len) fail(
        "disposeSubtree visited {d} scopes but the prepared retirement journal holds {d}",
        .{ left.len, right.len },
    );
    for (left, right, 0..) |eager_id, prepared_id, index| {
        if (eager_id != prepared_id) fail(
            "disposal order diverges at position {d}: eager retired scope {d}, prepared retired scope {d}",
            .{ index, eager_id.raw(), prepared_id.raw() },
        );
    }
}

fn checkWorlds(gpa: std.mem.Allocator, model: *const Model, eager: *World, prepared: *World) void {
    for ([_]*World{ eager, prepared }) |world| {
        checkSite(gpa, world, model, world.component, site_a_ordinal);
        checkSite(gpa, world, model, world.branch_scope, site_b_ordinal);
        checkMemberships(world);
        checkRetiredIds(world);
        checkBoundedSlots(world);
    }
    checkWorldsAgree(eager, prepared);
}

/// Asserts one site's row order, membership, hash index, and row values.
fn checkSite(gpa: std.mem.Allocator, world: *World, model: *const Model, parent: ScopeId, ordinal: SiteOrdinal) void {
    const site_index = world.siteIndex(parent, ordinal);
    const site = &world.sites.items[site_index];
    const rows = site.scope_ids.items;

    if (rows.len != model.keys.items.len) fail(
        "{s} world site {d} holds {d} rows; the model holds {d} keys",
        .{ world.name(), ordinal.raw(), rows.len, model.keys.items.len },
    );

    for (rows, 0..) |scope_id, row_index| {
        for (rows[row_index + 1 ..]) |other| {
            if (other == scope_id) fail("{s} world site {d} holds scope {d} at two row positions", .{ world.name(), ordinal.raw(), scope_id.raw() });
        }
        if (!world.scopes.items[scope_id.index()].lifecycle.isActive()) {
            fail("{s} world site {d} row {d} is retired scope {d}", .{ world.name(), ordinal.raw(), row_index, scope_id.raw() });
        }
        const values = world.row_values.items[scope_id.index()] orelse
            fail("{s} world site {d} row {d} (scope {d}) owns no key or item", .{ world.name(), ordinal.raw(), row_index, scope_id.raw() });
        if (values.key != model.keys.items[row_index]) fail(
            "{s} world site {d} row {d} holds key {d}; the model holds key {d}",
            .{ world.name(), ordinal.raw(), row_index, values.key, model.keys.items[row_index] },
        );
        if (values.version != model.versions.items[row_index]) fail(
            "{s} world site {d} row {d} holds version {d}; the model holds version {d}",
            .{ world.name(), ordinal.raw(), row_index, values.version, model.versions.items[row_index] },
        );
        if (values.hash != world.hashOf(values.key)) fail(
            "{s} world site {d} row {d} carries hash {d} for a key that hashes to {d}",
            .{ world.name(), ordinal.raw(), row_index, values.hash, world.hashOf(values.key) },
        );

        const membership = world.memberships.items[scope_id.index()] orelse
            fail("{s} world site {d} row {d} (scope {d}) has no membership", .{ world.name(), ordinal.raw(), row_index, scope_id.raw() });
        if (membership.site_index != site_index or membership.row_index != row_index) fail(
            "{s} world scope {d} claims membership site {d} row {d} but sits at site {d} row {d}",
            .{ world.name(), scope_id.raw(), membership.site_index, membership.row_index, site_index, row_index },
        );
    }

    checkHashIndex(gpa, world, site, ordinal);
    checkActiveEachRows(gpa, world, parent, ordinal, rows);
}

/// Asserts the chained hash index reaches every row exactly once, terminates,
/// and files each row under the bucket its own key hashes to.
///
/// The index is maintained incrementally, so a desync is silent until some later
/// lookup misses a survivor and rebuilds a row it should have reused - which
/// still produces the right order, and would pass every other oracle here.
fn checkHashIndex(gpa: std.mem.Allocator, world: *World, site: *const each.Site, ordinal: SiteOrdinal) void {
    const rows = site.scope_ids.items;
    if (site.hash_links.items.len != rows.len) fail(
        "{s} world site {d} has {d} hash links for {d} rows",
        .{ world.name(), ordinal.raw(), site.hash_links.items.len, rows.len },
    );

    const seen = gpa.alloc(bool, rows.len) catch fail("out of memory", .{});
    defer gpa.free(seen);
    @memset(seen, false);

    var reached: usize = 0;
    var buckets = site.hash_heads.iterator();
    while (buckets.next()) |bucket| {
        var row_index = bucket.value_ptr.*;
        var steps: usize = 0;
        while (row_index != each.missing_row_index) {
            if (row_index >= rows.len) fail(
                "{s} world site {d} hash bucket {d} links to row {d} of {d}",
                .{ world.name(), ordinal.raw(), bucket.key_ptr.*, row_index, rows.len },
            );
            if (seen[row_index]) fail(
                "{s} world site {d} reaches row {d} twice through its hash index",
                .{ world.name(), ordinal.raw(), row_index },
            );
            seen[row_index] = true;
            reached += 1;
            const row_hash = world.rowKeyHash(rows[row_index]);
            if (row_hash != bucket.key_ptr.*) fail(
                "{s} world site {d} files row {d} under bucket {d}; its key hashes to {d}",
                .{ world.name(), ordinal.raw(), row_index, bucket.key_ptr.*, row_hash },
            );
            row_index = site.hash_links.items[row_index];
            steps += 1;
            if (steps > rows.len) fail("{s} world site {d} has a cyclic hash chain", .{ world.name(), ordinal.raw() });
        }
    }

    if (reached != rows.len) fail(
        "{s} world site {d} reaches {d} of its {d} rows through the hash index",
        .{ world.name(), ordinal.raw(), reached, rows.len },
    );
}

/// Asserts `activeEachRows` returns exactly the site's live row set.
///
/// It walks the scope forest rather than the row table, so it is the independent
/// witness that a row's scope is active, parented where the site says, and
/// tagged with the site's ordinal. It returns scope-array order, not row order,
/// so this is a set comparison and `checkSite` owns the ordering.
fn checkActiveEachRows(gpa: std.mem.Allocator, world: *World, parent: ScopeId, ordinal: SiteOrdinal, rows: []const ScopeId) void {
    const active = scope_tree.activeEachRows(Row, gpa, world.scopes.items, parent, ordinal) catch |err|
        fail("{s} world could not list active rows: {s}", .{ world.name(), @errorName(err) });
    defer gpa.free(active);

    if (active.len != rows.len) fail(
        "{s} world site {d}: the scope forest holds {d} active rows, the row table holds {d}",
        .{ world.name(), ordinal.raw(), active.len, rows.len },
    );
    for (active) |scope_id| {
        for (rows) |row| {
            if (row == scope_id) break;
        } else fail(
            "{s} world site {d}: scope {d} is an active row in the forest but not in the row table",
            .{ world.name(), ordinal.raw(), scope_id.raw() },
        );
    }
}

/// Asserts no membership outlives the row it described.
///
/// The forward direction is checked per site; this is the reverse one, and it is
/// the direction a removal that forgot to null a membership fails.
fn checkMemberships(world: *World) void {
    for (world.memberships.items, 0..) |maybe_membership, scope_index| {
        const membership = maybe_membership orelse continue;
        if (membership.site_index >= world.sites.items.len) fail(
            "{s} world scope {d} claims membership of site {d} of {d}",
            .{ world.name(), scope_index, membership.site_index, world.sites.items.len },
        );
        const rows = world.sites.items[membership.site_index].scope_ids.items;
        if (membership.row_index >= rows.len or rows[membership.row_index].index() != scope_index) fail(
            "{s} world scope {d} claims site {d} row {d}, which does not hold it",
            .{ world.name(), scope_index, membership.site_index, membership.row_index },
        );
    }
}

/// Asserts no retired id is still reachable through any live table.
///
/// `ScopeId` carries no generation tag, so a table that kept a retired id does
/// not fail loudly: it silently starts describing whatever new scope recycles
/// that slot.
fn checkRetiredIds(world: *World) void {
    for (world.retired_ever.items) |scope_id| {
        if (scope_id.index() < world.memberships.items.len and world.memberships.items[scope_id.index()] != null) {
            fail("{s} world kept a membership for retired scope {d}", .{ world.name(), scope_id.raw() });
        }
        if (scope_id.index() < world.row_values.items.len and world.row_values.items[scope_id.index()] != null) {
            fail("{s} world kept row values for retired scope {d}", .{ world.name(), scope_id.raw() });
        }
        for (world.sites.items) |site| {
            for (site.scope_ids.items) |row| {
                if (row == scope_id) fail("{s} world kept retired scope {d} as a live row", .{ world.name(), scope_id.raw() });
            }
        }
    }
}

/// Asserts inactive scopes are reusable slots rather than accumulated garbage.
///
/// A fresh append only happens when every inactive slot is barrier-blocked, so
/// the scope array can never exceed the high-water mark of simultaneous demand:
/// live scopes plus the ones the current generation is blocking. That bound is
/// shaped by the program's concurrency, not its length, which is exactly the
/// distinction design.md draws.
fn checkBoundedSlots(world: *World) void {
    if (world.scopes.items.len > world.slot_high_water) fail(
        "{s} world holds {d} scope slots for a peak demand of {d}",
        .{ world.name(), world.scopes.items.len, world.slot_high_water },
    );
}

/// Asserts the eager and prepared paths reached identical state.
///
/// The two seams share almost no code below the hook surface: `syncRows` mutates
/// as it matches, `prepare`/`commit` reserves everything first and publishes in
/// one pass. Handing them the same program is the cheapest way to notice one of
/// them drifting, and a divergence is a bug even when neither path crashes.
fn checkWorldsAgree(eager: *World, prepared: *World) void {
    if (eager.scopes.items.len != prepared.scopes.items.len) fail(
        "eager world holds {d} scope slots, prepared world holds {d}",
        .{ eager.scopes.items.len, prepared.scopes.items.len },
    );
    if (eager.branch_scope != prepared.branch_scope) fail(
        "eager world's branch is scope {d}, prepared world's is scope {d}",
        .{ eager.branch_scope.raw(), prepared.branch_scope.raw() },
    );
    if (eager.sites.items.len != prepared.sites.items.len) fail(
        "eager world holds {d} sites, prepared world holds {d}",
        .{ eager.sites.items.len, prepared.sites.items.len },
    );

    for (eager.scopes.items, prepared.scopes.items, 0..) |left, right, index| {
        if (left.lifecycle.isActive() != right.lifecycle.isActive()) fail(
            "scope {d} is {s} in the eager world and {s} in the prepared world",
            .{ index, if (left.lifecycle.isActive()) "active" else "retired", if (right.lifecycle.isActive()) "active" else "retired" },
        );
    }

    checkSitesAgree(eager, prepared, eager.component, prepared.component, site_a_ordinal);
    checkSitesAgree(eager, prepared, eager.branch_scope, prepared.branch_scope, site_b_ordinal);
}

fn checkSitesAgree(eager: *World, prepared: *World, eager_parent: ScopeId, prepared_parent: ScopeId, ordinal: SiteOrdinal) void {
    const left = eager.rowScopeIds(eager_parent, ordinal);
    const right = prepared.rowScopeIds(prepared_parent, ordinal);
    if (left.len != right.len) fail(
        "site {d} holds {d} rows in the eager world and {d} in the prepared world",
        .{ ordinal.raw(), left.len, right.len },
    );
    for (left, right, 0..) |eager_id, prepared_id, row_index| {
        if (eager_id != prepared_id) fail(
            "site {d} row {d} is scope {d} in the eager world and scope {d} in the prepared world",
            .{ ordinal.raw(), row_index, eager_id.raw(), prepared_id.raw() },
        );
    }
}

/// Asserts the world reclaimed everything it ever owned.
fn checkTeardown(world: *World) void {
    if (world.live_scopes != 0) fail("{s} world left {d} scopes live after teardown", .{ world.name(), world.live_scopes });
    for (world.scopes.items) |scope| {
        if (scope.lifecycle.isActive()) fail("{s} world left scope {d} active after teardown", .{ world.name(), scope.scope_id.raw() });
    }
    for (world.row_values.items, 0..) |values, index| {
        if (values != null) fail("{s} world left scope {d} owning a key and item after teardown", .{ world.name(), index });
    }
    for (world.memberships.items, 0..) |membership, index| {
        if (membership != null) fail("{s} world left a membership for scope {d} after teardown", .{ world.name(), index });
    }
    for (world.sites.items) |site| {
        if (site.scope_ids.items.len != 0) fail("{s} world left {d} rows in a site after teardown", .{ world.name(), site.scope_ids.items.len });
    }
}

// -------------------------------------------------------------------------
// Duplicate keys
// -------------------------------------------------------------------------

/// Drives the duplicate-key detector on the hash-collision path in both
/// directions and through both reconciliation seams.
///
/// The positive half is the contract design.md states directly: duplicate keys
/// are errors, not aliases. The negative half is the one that has teeth against
/// a plausible implementation, because a detector that compared hashes and
/// skipped `nextKeysEqual` would pass every positive test ever written and would
/// reject a perfectly valid list the moment two keys collided. Bucket count one
/// makes every key in the list collide, so the negative probe is exactly that
/// list.
fn checkDuplicates(gpa: std.mem.Allocator, program_buckets: u32, debug: bool) void {
    var distinct: [5]Key = undefined;
    for (&distinct, 0..) |*key, index| key.* = @intCast(index);

    // Two keys apart in the list, so detection has to walk the collision chain
    // rather than compare neighbours.
    const duplicated = [_]Key{ 0, 1, 2, 0, 3 };

    for ([_]u32{ 1, program_buckets }) |buckets| {
        for ([_]Mode{ .eager, .prepared }) |mode| {
            if (debug) std.debug.print("duplicate probe: {d} buckets, {s} mode\n", .{ buckets, @tagName(mode) });
            setPhase("probing distinct colliding keys ({d} buckets, {s})", .{ buckets, @tagName(mode) });
            probeKeys(gpa, mode, buckets, &distinct, null);
            setPhase("probing a duplicate key ({d} buckets, {s})", .{ buckets, @tagName(mode) });
            probeKeys(gpa, mode, buckets, &duplicated, .{ .first_index = 0, .second_index = 3 });
        }
    }
}

/// Reconciles a fresh site with `keys` and asserts the expected duplicate verdict.
///
/// The world is discarded afterwards rather than compared to the model: on the
/// positive path the reconciliation continued past a diagnostic that terminates
/// the real host, so its resulting state means nothing.
fn probeKeys(gpa: std.mem.Allocator, mode: Mode, buckets: u32, keys: []const Key, expected: ?each.DuplicateKeyInfo) void {
    var world = World.init(gpa, mode, buckets);
    defer world.deinit();
    world.mount();

    const versions = gpa.alloc(u32, keys.len) catch fail("out of memory", .{});
    defer gpa.free(versions);
    @memset(versions, 0);

    world.sync(world.component, site_a_ordinal, keys, versions);

    const reported = world.duplicate;
    if (expected) |want| {
        const got = reported orelse fail("a duplicate key at input {d} was not reported", .{want.second_index});
        if (got.first_index != want.first_index or got.second_index != want.second_index) fail(
            "the duplicate key was reported at inputs {d} and {d}; it is at {d} and {d}",
            .{ got.first_index, got.second_index, want.first_index, want.second_index },
        );
    } else {
        if (reported) |got| fail(
            "distinct keys colliding in one hash bucket were reported as a duplicate at inputs {d} and {d}",
            .{ got.first_index, got.second_index },
        );
        // A hash-only match would also have collapsed the colliding keys onto one
        // row, so the row count is the second half of the negative oracle.
        const rows = world.rowScopeIds(world.component, site_a_ordinal);
        if (rows.len != keys.len) fail(
            "{d} distinct keys sharing one hash bucket produced {d} rows",
            .{ keys.len, rows.len },
        );
    }

    // The world is deliberately not torn down through `teardown`: on the positive
    // path it holds rows the engine would never have published.
    for (world.scopes.items) |*scope| scope.lifecycle = .{ .retired = world.generation };
}

// -------------------------------------------------------------------------
// Partial row removal
// -------------------------------------------------------------------------

/// Drives `prepareRowRemovals`/`apply` over a generated *subset* of one site's
/// rows, which is the only way to reach `removeRowFromSiteIndex`'s repair logic.
///
/// The program above only ever removes a site's rows all at once, when the
/// branch that owned them is being retired - and a hash index corrupted on the
/// way out of a site nobody will look at again is invisible. Removing a subset
/// leaves the site live, so the swap-move that fills the hole, the
/// `replaceHashIndex` that re-files the moved row, and the `unlinkHashIndex`
/// that drops the removed one all have to be right or the next lookup misses a
/// survivor.
///
/// The expected row order is modelled explicitly, because removal is a
/// swap-remove: the last row fills the hole rather than the tail shifting down.
fn checkRowRemovals(gpa: std.mem.Allocator, reader: *FuzzReader, buckets: u32, debug: bool) void {
    setPhase("probing partial row removal ({d} buckets)", .{buckets});

    const row_count = reader.intRangeAtMost(usize, 1, key_pool_size);
    var keys: [key_pool_size]Key = undefined;
    var versions: [key_pool_size]u32 = undefined;
    for (0..row_count) |index| {
        keys[index] = @intCast(index);
        versions[index] = 0;
    }

    var world = World.init(gpa, .eager, buckets);
    defer world.deinit();
    world.mount();
    world.sync(world.component, site_a_ordinal, keys[0..row_count], versions[0..row_count]);

    var expected: std.ArrayListUnmanaged(ScopeId) = .empty;
    defer expected.deinit(gpa);
    expected.appendSlice(gpa, world.rowScopeIds(world.component, site_a_ordinal)) catch fail("out of memory", .{});

    var removals: std.ArrayListUnmanaged(each.RowRemoval) = .empty;
    defer removals.deinit(gpa);
    for (expected.items) |scope_id| {
        if (!reader.boolean()) continue;
        removals.append(gpa, .{ .scope_id = scope_id, .key_hash = world.rowKeyHash(scope_id) }) catch fail("out of memory", .{});
    }
    if (debug) std.debug.print("removal probe: {d} of {d} rows, {d} buckets\n", .{ removals.items.len, row_count, buckets });

    for (removals.items) |removal| swapRemoveId(&expected, removal.scope_id);

    var prepared = each.prepareRowRemovals(gpa, world.sites.items, world.memberships.items, removals.items) catch |err|
        fail("a valid set of row removals was refused: {s}", .{@errorName(err)});
    prepared.apply(gpa, &world.sites, &world.site_indexes, &world.memberships, &world);
    prepared.deinit(gpa);

    // Every removal has now consumed its row's membership, so re-presenting one
    // must be refused rather than repeated. That is the narrow boundary check
    // stopping a doubled removal from corrupting the row table.
    if (removals.items.len != 0) {
        if (each.prepareRowRemovals(gpa, world.sites.items, world.memberships.items, removals.items[0..1])) |_| {
            fail("a row removal was accepted twice", .{});
        } else |err| if (err != error.InvalidScope) {
            fail("re-presenting a consumed row removal produced {s} rather than InvalidScope", .{@errorName(err)});
        }
    }

    const rows = world.rowScopeIds(world.component, site_a_ordinal);
    if (rows.len != expected.items.len) fail(
        "the site holds {d} rows after removal; swap-removal predicts {d}",
        .{ rows.len, expected.items.len },
    );
    for (rows, expected.items, 0..) |actual, want, row_index| {
        if (actual != want) fail(
            "row {d} after removal is scope {d}; swap-removal predicts scope {d}",
            .{ row_index, actual.raw(), want.raw() },
        );
    }

    const site_index = world.siteIndex(world.component, site_a_ordinal);
    checkHashIndex(gpa, &world, &world.sites.items[site_index], site_a_ordinal);
    checkMemberships(&world);
    for (rows, 0..) |scope_id, row_index| {
        const membership = world.memberships.items[scope_id.index()] orelse
            fail("scope {d} survived removal without a membership", .{scope_id.raw()});
        if (membership.row_index != row_index) fail(
            "scope {d} claims row {d} after removal but sits at row {d}",
            .{ scope_id.raw(), membership.row_index, row_index },
        );
    }

    for (removals.items) |removal| world.retireSubtree(removal.scope_id);
    world.teardown();
    checkTeardown(&world);
}

fn swapRemoveId(list: *std.ArrayListUnmanaged(ScopeId), scope_id: ScopeId) void {
    for (list.items, 0..) |item, index| {
        if (item != scope_id) continue;
        _ = list.swapRemove(index);
        return;
    }
    fail("the removal model was asked to remove scope {d}, which it does not hold", .{scope_id.raw()});
}

// -------------------------------------------------------------------------
// The reuse barrier contract
// -------------------------------------------------------------------------

/// Drives `scope_tree`'s reuse barrier directly at generated generation pairs.
///
/// `Lifecycle.blocksReuse` compares `generation == barrier`. The engine only ever
/// retires *at* the current barrier, so the case that separates `==` from `>=` -
/// a slot retired in a generation newer than the barrier presented - is not
/// reachable through the engine's own generation discipline, and the program
/// oracles above cannot see it. This is therefore a contract probe on
/// `blocksReuse` itself, driven through `internComponent` so it is the real
/// intern path being asked and not the predicate in isolation.
fn checkBarrier(gpa: std.mem.Allocator, reader: *FuzzReader, debug: bool) void {
    const retired = Generation.fromRaw(reader.intRangeAtMost(u64, 0, 4));
    for (0..5) |raw_barrier| {
        const barrier = Generation.fromRaw(raw_barrier);
        setPhase("probing the reuse barrier at generation {d} for a slot retired at {d}", .{ raw_barrier, retired.raw() });
        if (debug) std.debug.print("barrier probe: retired {d}, barrier {d}\n", .{ retired.raw(), raw_barrier });

        var scopes: std.ArrayListUnmanaged(Scope) = .empty;
        defer scopes.deinit(gpa);

        const root = (scope_tree.internRoot(Row, gpa, &scopes) catch fail("root intern failed", .{})).scope_id;
        const first = (scope_tree.internComponent(Row, gpa, &scopes, root, component_ordinal, retired) catch
            fail("component intern failed", .{})).scope_id;
        scopes.items[first.index()].lifecycle = .{ .retired = retired };

        const next = (scope_tree.internComponent(Row, gpa, &scopes, root, SiteOrdinal.fromRaw(99), barrier) catch
            fail("component intern failed", .{})).scope_id;

        const reused = next == first;
        const should_reuse = retired != barrier;
        if (reused != should_reuse) fail(
            "a slot retired in generation {d} was {s} at barrier {d}; the barrier blocks reuse only in its own generation",
            .{ retired.raw(), if (reused) "reused" else "left blocked", raw_barrier },
        );
    }
}

// -------------------------------------------------------------------------

/// Which operation of the current program the oracles are judging, named in
/// every failure so a replay says where the model and engine parted.
var phase: []const u8 = "before the mount";
var phase_buffer: [128]u8 = undefined;

fn setPhase(comptime fmt: []const u8, args: anytype) void {
    phase = std.fmt.bufPrint(&phase_buffer, fmt, args) catch "in an unnamed operation";
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("keyed-scope fuzz oracle failed ({s}): " ++ fmt ++ "\n", .{phase} ++ args);
    @panic("keyed-scope fuzz oracle failed");
}
