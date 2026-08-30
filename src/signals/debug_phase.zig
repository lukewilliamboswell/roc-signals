//! Typed allocation-diagnostic phases shared by the engine and both hosts.

pub const Phase = enum(u32) {
    idle = 0,

    task_payload = 10,
    task_transform = 20,
    task_dispatch = 30,

    host_value_clone = 101,
    host_value_get_with_split = 103,
    host_value_take_with_split = 107,
    host_value_get = 108,
    host_value_store = 109,
    host_value_take = 110,

    event_drop_payload = 201,
    event_drop_state = 202,
    event_drop_read = 203,

    dispatch_effect_source = 300,
    effect_cache_initialize = 301,
    effect_cache_compare = 310,
    effect_cache_drop_equal = 311,
    effect_cache_replace = 312,
    propagate_record_before_eval = 331,
    propagate_record_before_drop = 332,
    dispatch_effect_propagate = 330,
    dispatch_effect_apply = 340,
    collect_dirty_sinks = 350,
    collect_dirty_structure = 360,
    apply_dirty_commands = 361,
    flush_deferred_effects = 362,
    dirty_batch_complete = 363,
    apply_dirty_structure = 370,

    eval_dirty_signal = 400,
    eval_dirty_ref = 401,
    eval_dirty_const_initialize = 402,
    eval_dirty_const_cached = 403,
    clone_cached_signal = 409,
    eval_dirty_task_source = 410,
    eval_dirty_interval_source = 411,
    eval_dirty_location_source = 412,
    eval_dirty_storage_source = 413,
    eval_dirty_visibility_source = 414,
    eval_dirty_online_source = 415,
    eval_dirty_map_input = 420,
    eval_dirty_map_transform = 421,
    eval_dirty_map_cache = 422,
    eval_dirty_map_cached = 423,
    eval_dirty_map2_left = 430,
    eval_dirty_map2_right = 431,
    eval_dirty_map2_transform = 432,
    eval_dirty_map2_cache = 433,
    eval_dirty_map2_cached = 434,
    eval_dirty_combine_child = 440,
    eval_dirty_combine_transform = 441,
    eval_dirty_combine_cache = 442,
    eval_dirty_combine_cached = 443,
    dirty_cache_initialize = 450,
    dirty_cache_compare = 451,
    dirty_cache_drop_equal = 452,
    dirty_cache_clone_equal = 453,
    dirty_cache_replace = 454,
    dirty_cache_clone_changed = 455,
};

/// Encodes a typed phase for an external diagnostic or ABI boundary.
pub fn encode(phase: Phase) u32 {
    return @intFromEnum(phase);
}
