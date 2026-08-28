//! Nominal identities owned by the shared Signals engine.
//!
//! Integer representations are exposed only through explicit constructors and
//! accessors so unrelated identity domains cannot be mixed accidentally. The
//! non-exhaustive enums preserve the dense integer layout required by runtime
//! tables and boundary protocols without making those integers interchangeable.

const std = @import("std");

const Domain = enum {
    node,
    elem,
    scope,
    event,
    task_request,
    interval,
    generation,
    site_ordinal,
};

fn Identity(comptime domain: Domain, comptime Repr: type) type {
    return enum(Repr) {
        _,

        const Self = @This();
        pub const identity_domain = domain;

        /// Constructs an identity from its representation at an ABI or wire boundary.
        pub fn fromRaw(raw_value: Repr) Self {
            return @enumFromInt(raw_value);
        }

        /// Returns the integer representation for an ABI or wire boundary.
        pub fn raw(self: Self) Repr {
            return @intFromEnum(self);
        }

        /// Constructs a dense identity from a host table index.
        pub fn fromIndex(table_index: usize) Self {
            return @enumFromInt(std.math.cast(Repr, table_index) orelse @panic("identity index exceeds its representation"));
        }

        /// Returns the dense host table index represented by this identity.
        pub fn index(self: Self) usize {
            return std.math.cast(usize, @intFromEnum(self)) orelse @panic("identity does not fit the host address space");
        }
    };
}

/// Dense identity of a reactive node in the engine node table.
pub const NodeId = Identity(.node, u64);

/// Dense identity of a rendered node shared with a host render surface.
pub const ElemId = Identity(.elem, u64);

/// Dense identity of a lifetime scope in the engine scope forest.
pub const ScopeId = Identity(.scope, u64);

/// Dense identity of an event route minted by the engine.
pub const EventId = Identity(.event, u64);

/// Dense identity of an in-flight task request minted by the engine.
pub const TaskRequestId = Identity(.task_request, u64);

/// Dense identity of an active interval registration minted by the engine.
pub const IntervalToken = Identity(.interval, u64);

/// Monotonic transaction generation used for dirty work and reuse barriers.
pub const Generation = Identity(.generation, u64);

/// Construction-site position within one explicit scope.
pub const SiteOrdinal = Identity(.site_ordinal, u64);

pub const root_elem = ElemId.fromRaw(0);
pub const root_scope = ScopeId.fromRaw(0);
pub const initial_generation = Generation.fromRaw(0);

/// Reinterprets dense raw element IDs after their producer has validated the identity domain.
pub fn elemSliceFromRaw(raw_ids: []const u64) []const ElemId {
    return @ptrCast(raw_ids);
}

/// Exposes dense element IDs to a wire encoder or integer-indexed host surface.
pub fn elemSliceRaw(elem_ids: []const ElemId) []const u64 {
    return @ptrCast(elem_ids);
}

/// Converts an optional raw element identity at a host-boundary adapter.
pub fn optionalElemFromRaw(raw_id: ?u64) ?ElemId {
    return if (raw_id) |value| ElemId.fromRaw(value) else null;
}

/// Converts an optional raw event identity at a host-boundary adapter.
pub fn optionalEventFromRaw(raw_id: ?u64) ?EventId {
    return if (raw_id) |value| EventId.fromRaw(value) else null;
}

/// Exposes an optional element identity to an integer-indexed host surface.
pub fn optionalElemRaw(elem_id: ?ElemId) ?u64 {
    return if (elem_id) |value| value.raw() else null;
}

/// Exposes an optional event identity to a host harness or wire encoder.
pub fn optionalEventRaw(event_id: ?EventId) ?u64 {
    return if (event_id) |value| value.raw() else null;
}

test "semantic identities retain dense integer representation" {
    try std.testing.expect(NodeId != ElemId);
    try std.testing.expect(ScopeId != SiteOrdinal);
    try std.testing.expect(EventId != TaskRequestId);
    try std.testing.expectEqual(@sizeOf(u64), @sizeOf(NodeId));
    try std.testing.expectEqual(@alignOf(u64), @alignOf(NodeId));
    try std.testing.expectEqual(@as(u64, 42), NodeId.fromRaw(42).raw());
    try std.testing.expectEqual(@as(usize, 42), ElemId.fromIndex(42).index());
}
