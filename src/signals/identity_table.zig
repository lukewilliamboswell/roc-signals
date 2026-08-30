//! Active identity tables for stable scope-local node and DOM element ids.

const std = @import("std");
const ids = @import("ids.zig");

pub const NodeId = ids.NodeId;
pub const ElemId = ids.ElemId;
pub const ScopeId = ids.ScopeId;
pub const Generation = ids.Generation;
pub const SiteOrdinal = ids.SiteOrdinal;

pub const Error = error{
    OutOfMemory,
};

pub const Lifecycle = union(enum) {
    active,
    retired: Generation,

    /// Reports whether this identity remains live and routable.
    /// Reports whether the identity currently belongs to the active runtime.
    pub fn isActive(self: Lifecycle) bool {
        return self == .active;
    }

    /// Reports whether this lifecycle prevents slot reuse at the supplied barrier.
    /// Reports whether this state prevents reuse in the supplied generation.
    pub fn blocksReuse(self: Lifecycle, barrier: Generation) bool {
        return switch (self) {
            .active => true,
            .retired => |generation| generation == barrier,
        };
    }
};

pub const NodeIdentity = struct {
    node_id: NodeId,
    scope_id: ScopeId,
    ordinal: SiteOrdinal,
    lifecycle: Lifecycle = .active,
};

pub const DomIdentity = struct {
    elem_id: ElemId,
    scope_id: ScopeId,
    ordinal: SiteOrdinal,
    lifecycle: Lifecycle = .active,
};

/// Appends fresh node using capacity that must already satisfy the caller's transaction contract.
pub fn appendFreshNode(allocator: std.mem.Allocator, identities: *std.ArrayListUnmanaged(NodeIdentity), scope_id: ScopeId, ordinal: SiteOrdinal) Error!NodeId {
    const node_id = NodeId.fromIndex(identities.items.len);
    identities.append(allocator, .{ .node_id = node_id, .scope_id = scope_id, .ordinal = ordinal }) catch return Error.OutOfMemory;
    return node_id;
}

/// Appends fresh dom using capacity that must already satisfy the caller's transaction contract.
pub fn appendFreshDom(allocator: std.mem.Allocator, identities: *std.ArrayListUnmanaged(DomIdentity), scope_id: ScopeId, ordinal: SiteOrdinal) Error!ElemId {
    const elem_id = ElemId.fromIndex(identities.items.len + 1);
    identities.append(allocator, .{ .elem_id = elem_id, .scope_id = scope_id, .ordinal = ordinal }) catch return Error.OutOfMemory;
    return elem_id;
}

/// Assigns or reuses a dense node id for explicit construction-site identity.
pub fn internNode(allocator: std.mem.Allocator, identities: *std.ArrayListUnmanaged(NodeIdentity), scope_id: ScopeId, ordinal: SiteOrdinal, reuse_barrier: Generation) Error!NodeId {
    for (identities.items) |identity| {
        if (!identity.lifecycle.isActive()) continue;
        if (identity.scope_id == scope_id and identity.ordinal == ordinal) {
            return identity.node_id;
        }
    }

    for (identities.items) |*identity| {
        if (identity.lifecycle.isActive()) continue;
        // Ids retired during the current dirty generation stay unusable until
        // the next one: dirty structural entries collected earlier in the
        // flush reference descriptors by node id, and reusing an id spliced
        // away mid-flush would silently re-point those entries at a fresh
        // descriptor.
        if (identity.lifecycle.blocksReuse(reuse_barrier)) continue;
        const node_id = identity.node_id;
        identity.* = .{
            .node_id = node_id,
            .scope_id = scope_id,
            .ordinal = ordinal,
            .lifecycle = .active,
        };
        return node_id;
    }

    const node_id = NodeId.fromIndex(identities.items.len);
    identities.append(allocator, .{
        .node_id = node_id,
        .scope_id = scope_id,
        .ordinal = ordinal,
        .lifecycle = .active,
    }) catch return Error.OutOfMemory;
    return node_id;
}

pub const NoActiveDomIds = struct {
    /// Checks the maintained active-element table without scanning the rendered tree.
    pub fn elemIdIsActive(_: @This(), _: ElemId) bool {
        return false;
    }
};

/// Assigns or reuses a dense DOM id for an engine-selected render node.
pub fn internDom(allocator: std.mem.Allocator, identities: *std.ArrayListUnmanaged(DomIdentity), scope_id: ScopeId, ordinal: SiteOrdinal, reuse_barrier: Generation, active_dom_ids: anytype) Error!ElemId {
    for (identities.items) |identity| {
        if (!identity.lifecycle.isActive()) continue;
        if (identity.scope_id == scope_id and identity.ordinal == ordinal) {
            return identity.elem_id;
        }
    }

    for (identities.items) |*identity| {
        if (identity.lifecycle.isActive()) continue;
        if (identity.lifecycle.blocksReuse(reuse_barrier)) continue;
        if (active_dom_ids.elemIdIsActive(identity.elem_id)) continue;
        const elem_id = identity.elem_id;
        identity.* = .{
            .elem_id = elem_id,
            .scope_id = scope_id,
            .ordinal = ordinal,
            .lifecycle = .active,
        };
        return elem_id;
    }

    const elem_id = ElemId.fromIndex(identities.items.len + 1);
    identities.append(allocator, .{
        .elem_id = elem_id,
        .scope_id = scope_id,
        .ordinal = ordinal,
        .lifecycle = .active,
    }) catch return Error.OutOfMemory;
    return elem_id;
}

/// Retires nodes in scope so disposed scope identity cannot be routed again.
pub fn deactivateNodesInScope(identities: *std.ArrayListUnmanaged(NodeIdentity), scope_id: ScopeId, generation: Generation, hooks: anytype) void {
    for (identities.items) |*identity| {
        if (identity.lifecycle.isActive() and identity.scope_id == scope_id) {
            hooks.deactivateNode(identity.node_id);
            identity.lifecycle = .{ .retired = generation };
        }
    }
}

/// Retires doms in scope so disposed scope identity cannot be routed again.
pub fn deactivateDomsInScope(identities: *std.ArrayListUnmanaged(DomIdentity), scope_id: ScopeId, generation: Generation) void {
    for (identities.items) |*identity| {
        if (identity.lifecycle.isActive() and identity.scope_id == scope_id) {
            identity.lifecycle = .{ .retired = generation };
        }
    }
}

test "node identities reuse active scope ordinal pairs" {
    var identities: std.ArrayListUnmanaged(NodeIdentity) = .empty;
    defer identities.deinit(std.testing.allocator);

    const first = try internNode(std.testing.allocator, &identities, ScopeId.fromRaw(7), SiteOrdinal.fromRaw(0), ids.initial_generation);
    const same = try internNode(std.testing.allocator, &identities, ScopeId.fromRaw(7), SiteOrdinal.fromRaw(0), ids.initial_generation);
    const next = try internNode(std.testing.allocator, &identities, ScopeId.fromRaw(7), SiteOrdinal.fromRaw(1), ids.initial_generation);

    try std.testing.expectEqual(NodeId.fromRaw(0), first);
    try std.testing.expectEqual(first, same);
    try std.testing.expectEqual(NodeId.fromRaw(1), next);

    identities.items[first.index()].lifecycle = .{ .retired = Generation.fromRaw(1) };
    const recreated = try internNode(std.testing.allocator, &identities, ScopeId.fromRaw(7), SiteOrdinal.fromRaw(0), ids.initial_generation);
    try std.testing.expectEqual(first, recreated);
}

test "node ids retired in a dirty generation are not reused until the next one" {
    var identities: std.ArrayListUnmanaged(NodeIdentity) = .empty;
    defer identities.deinit(std.testing.allocator);

    const first = try internNode(std.testing.allocator, &identities, ScopeId.fromRaw(7), SiteOrdinal.fromRaw(0), ids.initial_generation);

    var hook = TestDeactivateHook{};
    defer hook.deinit(std.testing.allocator);
    deactivateNodesInScope(&identities, ScopeId.fromRaw(7), Generation.fromRaw(5), &hook);

    const during_flush = try internNode(std.testing.allocator, &identities, ScopeId.fromRaw(8), SiteOrdinal.fromRaw(0), Generation.fromRaw(5));
    try std.testing.expect(during_flush != first);

    const next_flush = try internNode(std.testing.allocator, &identities, ScopeId.fromRaw(9), SiteOrdinal.fromRaw(0), Generation.fromRaw(6));
    try std.testing.expectEqual(first, next_flush);
}

test "dom identities are one-based and reuse active and inactive slots" {
    var identities: std.ArrayListUnmanaged(DomIdentity) = .empty;
    defer identities.deinit(std.testing.allocator);

    const first = try internDom(std.testing.allocator, &identities, ScopeId.fromRaw(2), SiteOrdinal.fromRaw(0), ids.initial_generation, NoActiveDomIds{});
    const same = try internDom(std.testing.allocator, &identities, ScopeId.fromRaw(2), SiteOrdinal.fromRaw(0), ids.initial_generation, NoActiveDomIds{});
    const next = try internDom(std.testing.allocator, &identities, ScopeId.fromRaw(2), SiteOrdinal.fromRaw(1), ids.initial_generation, NoActiveDomIds{});

    try std.testing.expectEqual(ElemId.fromRaw(1), first);
    try std.testing.expectEqual(first, same);
    try std.testing.expectEqual(ElemId.fromRaw(2), next);

    identities.items[first.index() - 1].lifecycle = .{ .retired = Generation.fromRaw(1) };
    const recreated = try internDom(std.testing.allocator, &identities, ScopeId.fromRaw(2), SiteOrdinal.fromRaw(0), ids.initial_generation, NoActiveDomIds{});
    try std.testing.expectEqual(first, recreated);
}

test "dom ids retired in a dirty generation are not reused until the next one" {
    var identities: std.ArrayListUnmanaged(DomIdentity) = .empty;
    defer identities.deinit(std.testing.allocator);

    const first = try internDom(std.testing.allocator, &identities, ScopeId.fromRaw(7), SiteOrdinal.fromRaw(0), ids.initial_generation, NoActiveDomIds{});
    deactivateDomsInScope(&identities, ScopeId.fromRaw(7), Generation.fromRaw(5));

    const during_flush = try internDom(std.testing.allocator, &identities, ScopeId.fromRaw(8), SiteOrdinal.fromRaw(0), Generation.fromRaw(5), NoActiveDomIds{});
    try std.testing.expect(during_flush != first);

    const next_flush = try internDom(std.testing.allocator, &identities, ScopeId.fromRaw(9), SiteOrdinal.fromRaw(0), Generation.fromRaw(6), NoActiveDomIds{});
    try std.testing.expectEqual(first, next_flush);
}

const TestActiveDomIds = struct {
    elem_id: ElemId,

    /// Checks the maintained active-element table without scanning the rendered tree.
    pub fn elemIdIsActive(self: @This(), elem_id: ElemId) bool {
        return elem_id == self.elem_id;
    }
};

test "dom ids still present in the active descriptor stream are not reused" {
    var identities: std.ArrayListUnmanaged(DomIdentity) = .empty;
    defer identities.deinit(std.testing.allocator);

    const first = try internDom(std.testing.allocator, &identities, ScopeId.fromRaw(7), SiteOrdinal.fromRaw(0), ids.initial_generation, NoActiveDomIds{});
    identities.items[first.index() - 1].lifecycle = .{ .retired = Generation.fromRaw(1) };

    const occupied = try internDom(std.testing.allocator, &identities, ScopeId.fromRaw(8), SiteOrdinal.fromRaw(0), ids.initial_generation, TestActiveDomIds{ .elem_id = first });
    try std.testing.expect(occupied != first);

    identities.items[occupied.index() - 1].lifecycle = .{ .retired = Generation.fromRaw(1) };
    const available = try internDom(std.testing.allocator, &identities, ScopeId.fromRaw(9), SiteOrdinal.fromRaw(0), ids.initial_generation, NoActiveDomIds{});
    try std.testing.expectEqual(first, available);
}

const TestDeactivateHook = struct {
    deactivated_nodes: std.ArrayListUnmanaged(NodeId) = .empty,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.deactivated_nodes.deinit(allocator);
    }

    /// Retires node so disposed scope identity cannot be routed again.
    pub fn deactivateNode(self: *@This(), node_id: NodeId) void {
        self.deactivated_nodes.append(std.testing.allocator, node_id) catch @panic("out of memory");
    }
};

test "identities deactivate active entries in a disposed scope" {
    var node_identities: std.ArrayListUnmanaged(NodeIdentity) = .empty;
    defer node_identities.deinit(std.testing.allocator);
    var dom_identities: std.ArrayListUnmanaged(DomIdentity) = .empty;
    defer dom_identities.deinit(std.testing.allocator);

    const node_scope_a = try internNode(std.testing.allocator, &node_identities, ScopeId.fromRaw(3), SiteOrdinal.fromRaw(0), ids.initial_generation);
    const node_scope_b = try internNode(std.testing.allocator, &node_identities, ScopeId.fromRaw(4), SiteOrdinal.fromRaw(0), ids.initial_generation);
    const dom_scope_a = try internDom(std.testing.allocator, &dom_identities, ScopeId.fromRaw(3), SiteOrdinal.fromRaw(0), ids.initial_generation, NoActiveDomIds{});
    const dom_scope_b = try internDom(std.testing.allocator, &dom_identities, ScopeId.fromRaw(4), SiteOrdinal.fromRaw(0), ids.initial_generation, NoActiveDomIds{});

    var hook = TestDeactivateHook{};
    defer hook.deinit(std.testing.allocator);

    deactivateNodesInScope(&node_identities, ScopeId.fromRaw(3), Generation.fromRaw(1), &hook);
    deactivateDomsInScope(&dom_identities, ScopeId.fromRaw(3), Generation.fromRaw(1));

    try std.testing.expectEqualSlices(NodeId, &.{node_scope_a}, hook.deactivated_nodes.items);
    try std.testing.expect(!node_identities.items[node_scope_a.index()].lifecycle.isActive());
    try std.testing.expect(node_identities.items[node_scope_b.index()].lifecycle.isActive());
    try std.testing.expect(!dom_identities.items[dom_scope_a.index() - 1].lifecycle.isActive());
    try std.testing.expect(dom_identities.items[dom_scope_b.index() - 1].lifecycle.isActive());
}
