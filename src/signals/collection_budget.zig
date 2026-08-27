//! Incremental, allocation-free limits for descriptor collection.

const std = @import("std");

pub const hard_max_nodes: usize = std.math.maxInt(u32);
pub const hard_max_descriptor_bytes: usize = std.math.maxInt(u32);

pub const Limits = struct {
    nodes: usize = hard_max_nodes,
    descriptor_bytes: usize = hard_max_descriptor_bytes,

    /// Rejects malformed boundary data before it can enter committed engine state.
    pub fn validate(self: Limits) error{ResourceLimit}!void {
        if (self.nodes > hard_max_nodes or self.descriptor_bytes > hard_max_descriptor_bytes) {
            return error.ResourceLimit;
        }
    }
};

pub const StreamBudget = struct {
    limits: Limits = .{},
    nodes: usize = 0,
    descriptor_bytes: usize = 0,

    /// Creates an initialized value with the ownership and capacity invariants required by this module.
    pub fn init(limits: Limits) error{ResourceLimit}!StreamBudget {
        try limits.validate();
        return .{ .limits = limits };
    }

    /// Charges one logical append atomically. Overflow and configured-limit
    /// failures leave both counters unchanged, so the caller can discard or
    /// retry staging without repairing budget state.
    pub fn charge(self: *StreamBudget, additional_nodes: usize, additional_bytes: usize) error{ResourceLimit}!void {
        const next_nodes = std.math.add(usize, self.nodes, additional_nodes) catch return error.ResourceLimit;
        const next_bytes = std.math.add(usize, self.descriptor_bytes, additional_bytes) catch return error.ResourceLimit;
        if (next_nodes > self.limits.nodes or next_bytes > self.limits.descriptor_bytes) {
            return error.ResourceLimit;
        }
        self.nodes = next_nodes;
        self.descriptor_bytes = next_bytes;
    }
};

test "stream budget rejects limits and overflow without partial charge" {
    var budget = try StreamBudget.init(.{ .nodes = 2, .descriptor_bytes = 12 });
    try budget.charge(1, 5);
    try std.testing.expectError(error.ResourceLimit, budget.charge(2, 1));
    try std.testing.expectEqual(@as(usize, 1), budget.nodes);
    try std.testing.expectEqual(@as(usize, 5), budget.descriptor_bytes);
    try std.testing.expectError(error.ResourceLimit, budget.charge(1, 8));
    try std.testing.expectEqual(@as(usize, 1), budget.nodes);
    try std.testing.expectEqual(@as(usize, 5), budget.descriptor_bytes);
    try std.testing.expectError(error.ResourceLimit, budget.charge(0, std.math.maxInt(usize)));
    try std.testing.expectEqual(@as(usize, 5), budget.descriptor_bytes);
}

test "stream budget hard maxima reject invalid configuration" {
    try std.testing.expectError(error.ResourceLimit, StreamBudget.init(.{ .nodes = hard_max_nodes + 1 }));
    try std.testing.expectError(error.ResourceLimit, StreamBudget.init(.{ .descriptor_bytes = hard_max_descriptor_bytes + 1 }));
}
