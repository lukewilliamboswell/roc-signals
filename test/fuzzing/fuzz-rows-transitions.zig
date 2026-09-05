//! Model-based fuzzing for canonical stable-slot `Rows` transitions.
//!
//! Arbitrary bytes become a bounded sequence of valid snapshot descendants.
//! Each descendant uses one canonical insert, remove range, move range, update,
//! or clear operation. The engine-owned sparse transition is checked against a
//! deliberately simple ordered-array model after every abort and commit.
//!
//! The target specifically exercises generation lineage, stable slots, exact
//! keys, range boundaries, abort-without-publication, and retry. Invalid sink
//! framing is tested at the lower-level sink unit seam rather than generated
//! here, because this generator promises valid programs.

const std = @import("std");
const signals = @import("signals");
const FuzzReader = @import("FuzzReader.zig");

const rows = signals.rows_transition;
const OwnerToken = rows.OwnerToken;
const StableEdit = rows.StableEdit;

const max_rows = 24;
const max_steps = 64;

const ModelRow = struct {
    slot: u64,
    key_id: u64,
    value: u64,
};

pub export fn zig_fuzz_init() void {}

pub export fn zig_fuzz_test(buf: [*]u8, len: isize) void {
    zig_fuzz_test_inner(buf, len, false);
}

/// Decodes and checks one bounded transition history.
pub fn zig_fuzz_test_inner(buf: [*]u8, len: isize, debug: bool) void {
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer if (gpa_impl.deinit() == .leak) @panic("Rows transition fuzz target leaked memory");
    const allocator = gpa_impl.allocator();

    checkLineageFork(allocator, debug);
    checkSharedGenerationAtTwoSites(allocator, debug);

    var reader = FuzzReader.init(buf[0..@intCast(len)]);
    var store = rows.Store.init(allocator);
    defer store.deinit();

    var owner_raw: u64 = 1;
    const site = store.createSite(OwnerToken.fromRaw(owner_raw) catch unreachable) catch @panic("Rows fuzz site allocation failed");
    var model: std.ArrayList(ModelRow) = .empty;
    defer model.deinit(allocator);
    var next_slot: u64 = 1;
    var next_key: u64 = 1;
    var next_scope: u64 = 1;

    const step_count = reader.intRangeAtMost(usize, 1, max_steps);
    for (0..step_count) |step| {
        var key_buffer: [32]u8 = undefined;
        var edit: StableEdit = undefined;
        var candidate: std.ArrayList(ModelRow) = .empty;
        defer candidate.deinit(allocator);
        candidate.appendSlice(allocator, model.items) catch @panic("Rows fuzz model allocation failed");

        const operation = if (candidate.items.len == 0) @as(u8, 0) else reader.readByte() % 5;
        switch (operation) {
            0 => {
                if (candidate.items.len >= max_rows) continue;
                const position = reader.intRangeAtMost(usize, 0, candidate.items.len);
                const before_slot = if (position == candidate.items.len) 0 else candidate.items[position].slot;
                _ = reader.readByte();
                const row = ModelRow{ .slot = next_slot, .key_id = next_key, .value = next_scope };
                const key = formatKey(&key_buffer, row.key_id);
                edit = .{ .insert = .{
                    .slot = row.slot,
                    .before_slot = before_slot,
                    .key = key,
                    .metadata = .{ .item_slot = row.slot, .scope_id = row.value },
                } };
                candidate.insert(allocator, position, row) catch @panic("Rows fuzz model allocation failed");
                next_slot += 1;
                next_key += 1;
                next_scope += 1;
            },
            1 => {
                const first = reader.intRangeLessThan(usize, 0, candidate.items.len);
                const count = reader.intRangeAtMost(usize, 1, candidate.items.len - first);
                edit = .{ .remove = .{ .first_slot = candidate.items[first].slot, .count = @intCast(count) } };
                _ = candidate.orderedRemove(first);
                var remaining = count - 1;
                while (remaining != 0) : (remaining -= 1) _ = candidate.orderedRemove(first);
            },
            2 => {
                if (candidate.items.len < 2) continue;
                const first = reader.intRangeLessThan(usize, 0, candidate.items.len);
                const count = reader.intRangeAtMost(usize, 1, candidate.items.len - first);
                if (count == candidate.items.len) continue;
                var moved: [max_rows]ModelRow = undefined;
                @memcpy(moved[0..count], candidate.items[first .. first + count]);
                var remaining = count;
                while (remaining != 0) : (remaining -= 1) _ = candidate.orderedRemove(first);
                const destination = reader.intRangeAtMost(usize, 0, candidate.items.len);
                const before_slot = if (destination == candidate.items.len) 0 else candidate.items[destination].slot;
                edit = .{ .move = .{
                    .first_slot = moved[0].slot,
                    .count = @intCast(count),
                    .before_slot = before_slot,
                } };
                candidate.insertSlice(allocator, destination, moved[0..count]) catch @panic("Rows fuzz model allocation failed");
            },
            3 => {
                const index = reader.intRangeLessThan(usize, 0, candidate.items.len);
                _ = reader.readByte();
                const key = formatKey(&key_buffer, candidate.items[index].key_id);
                edit = .{ .update = .{
                    .slot = candidate.items[index].slot,
                    .key = key,
                    .metadata = .{ .item_slot = candidate.items[index].slot, .scope_id = candidate.items[index].value },
                } };
            },
            4 => {
                edit = .clear;
                candidate.clearRetainingCapacity();
            },
            else => unreachable,
        }

        const parent = OwnerToken.fromRaw(owner_raw) catch unreachable;
        const child = OwnerToken.fromRaw(owner_raw + 1) catch unreachable;
        var prepared = rows.PreparedTransition.prepareStable(allocator, &store, site, parent, child, &.{edit}) catch |err| fail(debug, step, "prepare", err);

        if (reader.boolean()) {
            prepared.deinit();
            checkState(&store, site, parent, model.items, debug, step, "abort");
            prepared = rows.PreparedTransition.prepareStable(allocator, &store, site, parent, child, &.{edit}) catch |err| fail(debug, step, "retry", err);
        }

        prepared.commit();
        prepared.deinit();
        owner_raw += 1;
        model.clearRetainingCapacity();
        model.appendSlice(allocator, candidate.items) catch @panic("Rows fuzz model allocation failed");
        checkState(&store, site, child, model.items, debug, step, "commit");
    }
}

/// Exercises the runtime's required direct-delta, stale-sibling snapshot, then
/// resumed-delta lineage shape with concrete generation owners.
fn checkLineageFork(allocator: std.mem.Allocator, debug: bool) void {
    var store = rows.Store.init(allocator);
    defer store.deinit();
    const first = OwnerToken.fromRaw(100) catch unreachable;
    const direct = OwnerToken.fromRaw(101) catch unreachable;
    const sibling = OwnerToken.fromRaw(102) catch unreachable;
    const resumed = OwnerToken.fromRaw(103) catch unreachable;
    const site = store.createSite(first) catch @panic("Rows lineage fixture allocation failed");

    var initial = rows.PreparedTransition.prepareStable(allocator, &store, site, first, direct, &.{
        .{ .insert = .{ .slot = 1, .before_slot = 0, .key = "direct", .metadata = .{ .item_slot = 1, .scope_id = 1 } } },
    }) catch |err| fail(debug, 0, "lineage direct delta", err);
    initial.commit();
    initial.deinit();

    if (rows.PreparedTransition.prepareStable(allocator, &store, site, first, sibling, &.{})) |unexpected| {
        var prepared = unexpected;
        prepared.deinit();
        fail(debug, 0, "lineage stale sibling", error.ModelMismatch);
    } else |err| if (err != error.ParentMismatch) fail(debug, 0, "lineage stale sibling", err);

    // A stale sibling is applied through the counted full-snapshot path. At the
    // transition seam that is represented by an authenticated clear/rebuild
    // from the currently committed owner; it must publish the sibling owner.
    var snapshot = rows.PreparedTransition.prepareStable(allocator, &store, site, direct, sibling, &.{
        .clear,
        .{ .insert = .{ .slot = 2, .before_slot = 0, .key = "sibling", .metadata = .{ .item_slot = 2, .scope_id = 2 } } },
    }) catch |err| fail(debug, 0, "lineage sibling snapshot", err);
    snapshot.commit();
    snapshot.deinit();

    var next = rows.PreparedTransition.prepareStable(allocator, &store, site, sibling, resumed, &.{
        .{ .update = .{ .slot = 2, .key = "sibling", .metadata = .{ .item_slot = 2, .scope_id = 2 } } },
    }) catch |err| fail(debug, 0, "lineage resumed delta", err);
    next.commit();
    next.deinit();
    const malformed_owner = OwnerToken.fromRaw(104) catch unreachable;
    if (rows.PreparedTransition.prepareStable(allocator, &store, site, resumed, malformed_owner, &.{
        .{ .update = .{ .slot = 2, .key = "changed-identity", .metadata = .{ .item_slot = 2, .scope_id = 4 } } },
    })) |unexpected| {
        var prepared = unexpected;
        prepared.deinit();
        fail(debug, 0, "lineage malformed rekey", error.ModelMismatch);
    } else |err| if (err != error.KeyMismatch) fail(debug, 0, "lineage malformed rekey", err);
    checkState(&store, site, resumed, &.{.{ .slot = 2, .key_id = 0, .value = 2 }}, debug, 0, "lineage final");
}

/// The same immutable Rows owner may feed multiple construction sites. Their
/// host identities and row storage must remain site-local.
fn checkSharedGenerationAtTwoSites(allocator: std.mem.Allocator, debug: bool) void {
    var store = rows.Store.init(allocator);
    defer store.deinit();
    const shared = OwnerToken.fromRaw(200) catch unreachable;
    const first_owner = OwnerToken.fromRaw(201) catch unreachable;
    const second_owner = OwnerToken.fromRaw(202) catch unreachable;
    const first_site = store.createSite(shared) catch @panic("Rows shared-generation fixture allocation failed");
    const second_site = store.createSite(shared) catch @panic("Rows shared-generation fixture allocation failed");
    const first_edit = StableEdit{ .insert = .{ .slot = 7, .before_slot = 0, .key = "shared", .metadata = .{ .item_slot = 7, .scope_id = 9 } } };
    const second_edit = StableEdit{ .insert = .{ .slot = 7, .before_slot = 0, .key = "shared", .metadata = .{ .item_slot = 7, .scope_id = 10 } } };
    var first = rows.PreparedTransition.prepareStable(allocator, &store, first_site, shared, first_owner, &.{first_edit}) catch |err| fail(debug, 0, "shared first site", err);
    first.commit();
    first.deinit();
    var second = rows.PreparedTransition.prepareStable(allocator, &store, second_site, shared, second_owner, &.{second_edit}) catch |err| fail(debug, 0, "shared second site", err);
    second.commit();
    second.deinit();
    const first_row = (store.findItemSlot(first_site, 7) catch fail(debug, 0, "shared first lookup", error.ModelMismatch)) orelse fail(debug, 0, "shared first lookup", error.ModelMismatch);
    const second_row = (store.findItemSlot(second_site, 7) catch fail(debug, 0, "shared second lookup", error.ModelMismatch)) orelse fail(debug, 0, "shared second lookup", error.ModelMismatch);
    if (first_row == second_row) fail(debug, 0, "shared site identity", error.ModelMismatch);
}

fn formatKey(buffer: []u8, key_id: u64) []const u8 {
    return std.fmt.bufPrint(buffer, "key-{d}", .{key_id}) catch unreachable;
}

fn checkState(store: *const rows.Store, site: rows.SiteId, owner: OwnerToken, expected: []const ModelRow, debug: bool, step: usize, phase: []const u8) void {
    const actual_site = store.getSiteConst(site) catch fail(debug, step, phase, error.InvalidSite);
    if (actual_site.owner_token != owner or actual_site.len != expected.len) fail(debug, step, phase, error.ModelMismatch);
    var current = actual_site.head;
    for (expected) |model_row| {
        const row_id = current orelse fail(debug, step, phase, error.ModelMismatch);
        const actual = store.getRowConst(site, row_id) catch fail(debug, step, phase, error.ModelMismatch);
        var key_buffer: [32]u8 = undefined;
        const expected_key = if (model_row.key_id == 0) "sibling" else formatKey(&key_buffer, model_row.key_id);
        if (!std.mem.eql(u8, actual.key, expected_key)) fail(debug, step, phase, error.ModelMismatch);
        if (actual.metadata.item_slot != model_row.slot or actual.metadata.scope_id != model_row.value) fail(debug, step, phase, error.ModelMismatch);
        if ((store.findItemSlot(site, model_row.slot) catch fail(debug, step, phase, error.ModelMismatch)) != row_id) fail(debug, step, phase, error.ModelMismatch);
        current = actual.next;
    }
    if (current != null) fail(debug, step, phase, error.ModelMismatch);
}

fn fail(debug: bool, step: usize, phase: []const u8, err: anyerror) noreturn {
    if (debug) std.debug.print("Rows transition fuzz failure at step {d} ({s}): {s}\n", .{ step, phase, @errorName(err) });
    @panic("Rows transition fuzz oracle failed");
}
