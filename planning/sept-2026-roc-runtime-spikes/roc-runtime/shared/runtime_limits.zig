//! Shared bounded-runtime and diagnostic capacities.

/// Maximum recently freed Roc allocations retained for misuse diagnostics.
pub const recent_freed_allocation_count: usize = 4096;

/// Maximum ancestor path supported by native event propagation.
pub const event_propagation_depth: usize = 128;

/// Each drained Wasm command bank may retain at most 64 KiB for small updates.
/// Larger publications are accepted normally and release their bank on drain.
pub const retained_command_bytes_per_bank: usize = 64 * 1024;
