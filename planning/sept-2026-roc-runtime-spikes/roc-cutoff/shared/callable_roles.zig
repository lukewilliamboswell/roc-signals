//! Nominal semantic roles layered above the raw Roc erased-callable ABI.
//!
//! Only independently routed callables belong here. Readers, event reducers,
//! and each-row operations already cross the typed boundary in distinct
//! generated capability-bearing handle bundles, so duplicating their inner
//! callable fields here would provide no additional routing safety.

const std = @import("std");
const abi = @import("roc_platform_abi.zig");

pub const Role = enum {
    initializer,
    transform,
    command_builder,
    capability_clone,
    capability_eq,
    capability_drop,
    capability_split,
};

/// Produces a nominal wrapper for one semantic erased-callable role.
pub fn ErasedCallable(comptime role: Role) type {
    return struct {
        raw: abi.RocErasedCallable,

        pub const semantic_role = role;

        /// Assigns semantic meaning while importing a raw descriptor field.
        pub fn fromAbi(raw: abi.RocErasedCallable) @This() {
            return .{ .raw = raw };
        }

        /// Lowers a role-checked callable only at an ABI or invocation seam.
        pub fn toAbi(self: @This()) abi.RocErasedCallable {
            return self.raw;
        }
    };
}

pub const Initializer = ErasedCallable(.initializer);
pub const Transform = ErasedCallable(.transform);
pub const CommandBuilder = ErasedCallable(.command_builder);
pub const CapabilityClone = ErasedCallable(.capability_clone);
pub const CapabilityEq = ErasedCallable(.capability_eq);
pub const CapabilityDrop = ErasedCallable(.capability_drop);
pub const CapabilitySplit = ErasedCallable(.capability_split);

comptime {
    for (.{ Initializer, Transform, CommandBuilder, CapabilityClone, CapabilityEq, CapabilityDrop, CapabilitySplit }) |Callable| {
        if (@sizeOf(Callable) != @sizeOf(abi.RocErasedCallable)) @compileError("callable role wrapper must remain pointer-sized");
        if (@alignOf(Callable) != @alignOf(abi.RocErasedCallable)) @compileError("callable role wrapper must preserve pointer alignment");
    }
}

test "erased callable roles are nominal and zero cost" {
    try std.testing.expect(Initializer != Transform);
    try std.testing.expect(Transform != CommandBuilder);
    try std.testing.expect(CapabilityClone != CapabilityDrop);
    try std.testing.expect(CapabilityDrop != CapabilitySplit);
    const raw: abi.RocErasedCallable = @ptrFromInt(0x1000);
    try std.testing.expectEqual(raw, Initializer.fromAbi(raw).toAbi());
}
