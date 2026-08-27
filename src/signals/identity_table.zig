//! Active identity tables for stable scope-local node and DOM element ids.

const std = @import("std");

pub const Error = error{
    OutOfMemory,
};

pub const NodeIdentity = struct {
    node_id: u64,
    scope_id: u64,
    ordinal: u64,
    active: bool,
    retired_at: u64 = 0,
};

pub const DomIdentity = struct {
    elem_id: u64,
    scope_id: u64,
    ordinal: u64,
    active: bool,
    retired_at: u64 = 0,
};

pub fn appendFreshNode(allocator: std.mem.Allocator, identities: *std.ArrayListUnmanaged(NodeIdentity), scope_id: u64, ordinal: u64) Error!u64 {
    const node_id: u64 = @intCast(identities.items.len);
    identities.append(allocator, .{ .node_id = node_id, .scope_id = scope_id, .ordinal = ordinal, .active = true }) catch return Error.OutOfMemory;
    return node_id;
}

pub fn appendFreshDom(allocator: std.mem.Allocator, identities: *std.ArrayListUnmanaged(DomIdentity), scope_id: u64, ordinal: u64) Error!u64 {
    const elem_id: u64 = @intCast(identities.items.len + 1);
    identities.append(allocator, .{ .elem_id = elem_id, .scope_id = scope_id, .ordinal = ordinal, .active = true }) catch return Error.OutOfMemory;
    return elem_id;
}

pub fn internNode(allocator: std.mem.Allocator, identities: *std.ArrayListUnmanaged(NodeIdentity), scope_id: u64, ordinal: u64, reuse_barrier: u64) Error!u64 {
    for (identities.items) |identity| {
        if (!identity.active) continue;
        if (identity.scope_id == scope_id and identity.ordinal == ordinal) {
            return identity.node_id;
        }
    }

    for (identities.items) |*identity| {
        if (identity.active) continue;
        // Ids retired during the current dirty generation stay unusable until
        // the next one: dirty structural entries collected earlier in the
        // flush reference descriptors by node id, and reusing an id spliced
        // away mid-flush would silently re-point those entries at a fresh
        // descriptor.
        if (identity.retired_at != 0 and identity.retired_at == reuse_barrier) continue;
        const node_id = identity.node_id;
        identity.* = .{
            .node_id = node_id,
            .scope_id = scope_id,
            .ordinal = ordinal,
            .active = true,
        };
        return node_id;
    }

    const node_id: u64 = @intCast(identities.items.len);
    identities.append(allocator, .{
        .node_id = node_id,
        .scope_id = scope_id,
        .ordinal = ordinal,
        .active = true,
    }) catch return Error.OutOfMemory;
    return node_id;
}

pub const NoActiveDomIds = struct {
    pub fn elemIdIsActive(_: @This(), _: u64) bool {
        return false;
    }
};

pub fn internDom(allocator: std.mem.Allocator, identities: *std.ArrayListUnmanaged(DomIdentity), scope_id: u64, ordinal: u64, reuse_barrier: u64, active_dom_ids: anytype) Error!u64 {
    for (identities.items) |identity| {
        if (!identity.active) continue;
        if (identity.scope_id == scope_id and identity.ordinal == ordinal) {
            return identity.elem_id;
        }
    }

    for (identities.items) |*identity| {
        if (identity.active) continue;
        if (identity.retired_at != 0 and identity.retired_at == reuse_barrier) continue;
        if (active_dom_ids.elemIdIsActive(identity.elem_id)) continue;
        const elem_id = identity.elem_id;
        identity.* = .{
            .elem_id = elem_id,
            .scope_id = scope_id,
            .ordinal = ordinal,
            .active = true,
        };
        return elem_id;
    }

    const elem_id: u64 = @intCast(identities.items.len + 1);
    identities.append(allocator, .{
        .elem_id = elem_id,
        .scope_id = scope_id,
        .ordinal = ordinal,
        .active = true,
    }) catch return Error.OutOfMemory;
    return elem_id;
}

pub fn deactivateNodesInScope(identities: *std.ArrayListUnmanaged(NodeIdentity), scope_id: u64, generation: u64, hooks: anytype) void {
    for (identities.items) |*identity| {
        if (identity.active and identity.scope_id == scope_id) {
            hooks.deactivateNode(identity.node_id);
            identity.active = false;
            identity.retired_at = generation;
        }
    }
}

pub fn deactivateDomsInScope(identities: *std.ArrayListUnmanaged(DomIdentity), scope_id: u64, generation: u64) void {
    for (identities.items) |*identity| {
        if (identity.active and identity.scope_id == scope_id) {
            identity.active = false;
            identity.retired_at = generation;
        }
    }
}

test "node identities reuse active scope ordinal pairs" {
    var identities: std.ArrayListUnmanaged(NodeIdentity) = .empty;
    defer identities.deinit(std.testing.allocator);

    const first = try internNode(std.testing.allocator, &identities, 7, 0, 0);
    const same = try internNode(std.testing.allocator, &identities, 7, 0, 0);
    const next = try internNode(std.testing.allocator, &identities, 7, 1, 0);

    try std.testing.expectEqual(@as(u64, 0), first);
    try std.testing.expectEqual(first, same);
    try std.testing.expectEqual(@as(u64, 1), next);

    identities.items[@intCast(first)].active = false;
    const recreated = try internNode(std.testing.allocator, &identities, 7, 0, 0);
    try std.testing.expectEqual(first, recreated);
}

test "node ids retired in a dirty generation are not reused until the next one" {
    var identities: std.ArrayListUnmanaged(NodeIdentity) = .empty;
    defer identities.deinit(std.testing.allocator);

    const first = try internNode(std.testing.allocator, &identities, 7, 0, 0);

    var hook = TestDeactivateHook{};
    defer hook.deinit(std.testing.allocator);
    deactivateNodesInScope(&identities, 7, 5, &hook);

    const during_flush = try internNode(std.testing.allocator, &identities, 8, 0, 5);
    try std.testing.expect(during_flush != first);

    const next_flush = try internNode(std.testing.allocator, &identities, 9, 0, 6);
    try std.testing.expectEqual(first, next_flush);
}

test "dom identities are one-based and reuse active and inactive slots" {
    var identities: std.ArrayListUnmanaged(DomIdentity) = .empty;
    defer identities.deinit(std.testing.allocator);

    const first = try internDom(std.testing.allocator, &identities, 2, 0, 0, NoActiveDomIds{});
    const same = try internDom(std.testing.allocator, &identities, 2, 0, 0, NoActiveDomIds{});
    const next = try internDom(std.testing.allocator, &identities, 2, 1, 0, NoActiveDomIds{});

    try std.testing.expectEqual(@as(u64, 1), first);
    try std.testing.expectEqual(first, same);
    try std.testing.expectEqual(@as(u64, 2), next);

    identities.items[@intCast(first - 1)].active = false;
    const recreated = try internDom(std.testing.allocator, &identities, 2, 0, 0, NoActiveDomIds{});
    try std.testing.expectEqual(first, recreated);
}

test "dom ids retired in a dirty generation are not reused until the next one" {
    var identities: std.ArrayListUnmanaged(DomIdentity) = .empty;
    defer identities.deinit(std.testing.allocator);

    const first = try internDom(std.testing.allocator, &identities, 7, 0, 0, NoActiveDomIds{});
    deactivateDomsInScope(&identities, 7, 5);

    const during_flush = try internDom(std.testing.allocator, &identities, 8, 0, 5, NoActiveDomIds{});
    try std.testing.expect(during_flush != first);

    const next_flush = try internDom(std.testing.allocator, &identities, 9, 0, 6, NoActiveDomIds{});
    try std.testing.expectEqual(first, next_flush);
}

const TestActiveDomIds = struct {
    elem_id: u64,

    pub fn elemIdIsActive(self: @This(), elem_id: u64) bool {
        return elem_id == self.elem_id;
    }
};

test "dom ids still present in the active descriptor stream are not reused" {
    var identities: std.ArrayListUnmanaged(DomIdentity) = .empty;
    defer identities.deinit(std.testing.allocator);

    const first = try internDom(std.testing.allocator, &identities, 7, 0, 0, NoActiveDomIds{});
    identities.items[@intCast(first - 1)].active = false;

    const occupied = try internDom(std.testing.allocator, &identities, 8, 0, 0, TestActiveDomIds{ .elem_id = first });
    try std.testing.expect(occupied != first);

    identities.items[@intCast(occupied - 1)].active = false;
    const available = try internDom(std.testing.allocator, &identities, 9, 0, 0, NoActiveDomIds{});
    try std.testing.expectEqual(first, available);
}

const TestDeactivateHook = struct {
    deactivated_nodes: std.ArrayListUnmanaged(u64) = .empty,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.deactivated_nodes.deinit(allocator);
    }

    pub fn deactivateNode(self: *@This(), node_id: u64) void {
        self.deactivated_nodes.append(std.testing.allocator, node_id) catch @panic("out of memory");
    }
};

test "identities deactivate active entries in a disposed scope" {
    var node_identities: std.ArrayListUnmanaged(NodeIdentity) = .empty;
    defer node_identities.deinit(std.testing.allocator);
    var dom_identities: std.ArrayListUnmanaged(DomIdentity) = .empty;
    defer dom_identities.deinit(std.testing.allocator);

    const node_scope_a = try internNode(std.testing.allocator, &node_identities, 3, 0, 0);
    const node_scope_b = try internNode(std.testing.allocator, &node_identities, 4, 0, 0);
    const dom_scope_a = try internDom(std.testing.allocator, &dom_identities, 3, 0, 0, NoActiveDomIds{});
    const dom_scope_b = try internDom(std.testing.allocator, &dom_identities, 4, 0, 0, NoActiveDomIds{});

    var hook = TestDeactivateHook{};
    defer hook.deinit(std.testing.allocator);

    deactivateNodesInScope(&node_identities, 3, 1, &hook);
    deactivateDomsInScope(&dom_identities, 3, 1);

    try std.testing.expectEqualSlices(u64, &.{node_scope_a}, hook.deactivated_nodes.items);
    try std.testing.expect(!node_identities.items[@intCast(node_scope_a)].active);
    try std.testing.expect(node_identities.items[@intCast(node_scope_b)].active);
    try std.testing.expect(!dom_identities.items[@intCast(dom_scope_a - 1)].active);
    try std.testing.expect(dom_identities.items[@intCast(dom_scope_b - 1)].active);
}
