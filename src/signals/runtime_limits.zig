//! Shared bounded-runtime and diagnostic capacities.

/// Maximum recently freed Roc allocations retained for misuse diagnostics.
pub const recent_freed_allocation_count: usize = 4096;

/// Maximum ancestor path supported by native event propagation.
pub const event_propagation_depth: usize = 128;
