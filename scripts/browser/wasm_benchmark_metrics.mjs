export const BENCHMARK_METRICS_SCHEMA_VERSION = 3;

const ALLOCATION_FIELDS = [
  "alloc_calls",
  "realloc_calls",
  "dealloc_calls",
  "allocated_bytes",
  "deallocated_bytes",
  "realloc_copied_bytes",
  "live_count",
  "live_bytes",
  "peak_live_count",
  "peak_live_bytes",
];

export const RUNTIME_METRIC_FIELDS = [
  "active_graph_records_rebuilt", "append_child", "active_intervals_synced",
  "allocs_this_event", "bind_event", "closure_releases", "closure_retains",
  "create_element", "deallocs_this_event", "derived_calls_into_roc",
  "each_key_compares", "each_key_hashes", "each_key_reuse_compares",
  "each_key_duplicate_compares", "each_item_compares", "each_syncs",
  "each_sync_keys", "each_sync_existing_rows", "events_processed",
  "host_alloc_bytes_this_event", "host_allocs_this_event",
  "host_dealloc_bytes_this_event", "host_deallocs_this_event",
  "host_retained_alloc_delta", "host_retained_bytes_delta", "move_before",
  "dirty_source_roots", "patches_emitted", "propagation_prunes",
  "recompute_batches", "remove_node", "render_indexes_refreshed",
  "retained_alloc_delta", "reset_dom", "rows_created",
  "rows_order_links_touched", "rows_removed", "rows_render_roots_moved",
  "rows_reused", "selector_members_dirtied", "scopes_created",
  "scopes_disposed", "set_checked", "set_disabled", "set_metadata",
  "set_text", "set_value", "signal_record_table_rebuilt",
  "stale_task_results_ignored", "stream_nodes_scanned",
  "stream_nodes_scanned_apply", "stream_nodes_scanned_children",
  "stream_nodes_scanned_dirty_scope", "stream_nodes_scanned_events",
  "stream_nodes_scanned_mounts", "stream_nodes_scanned_on_change",
  "stream_nodes_scanned_remove_target", "stream_nodes_scanned_render_scope",
  "stream_nodes_scanned_splice",
];

const SIGNED_FIELDS = new Set([
  "roc_retained_count_delta", "roc_retained_bytes_delta",
  "host_retained_count_delta", "host_retained_bytes_delta",
  "runtime_host_retained_alloc_delta", "runtime_host_retained_bytes_delta",
  "runtime_retained_alloc_delta",
]);

export const BENCHMARK_METRIC_FIELDS = [
  ...ALLOCATION_FIELDS.map((name) => `roc_${name}`),
  ...ALLOCATION_FIELDS.map((name) => `host_${name}`),
  "roc_retained_count_delta", "roc_retained_bytes_delta",
  "host_retained_count_delta", "host_retained_bytes_delta",
  "roc_live_count_before", "roc_live_bytes_before",
  "host_live_count_before", "host_live_bytes_before",
  "command_buffer_growth_bytes", "wasm_pages_before", "wasm_pages_after",
  ...RUNTIME_METRIC_FIELDS.map((name) => `runtime_${name}`),
];

export const BENCHMARK_METRICS_BYTE_LENGTH = BENCHMARK_METRIC_FIELDS.length * 8;

function requireExport(exports, name) {
  const value = exports[name];
  if (typeof value !== "function") {
    throw new Error(`benchmark Wasm module is missing required export ${name}`);
  }
  return value;
}

export function validateBenchmarkMetricsExports(exports) {
  const schema = requireExport(exports, "roc_ui_benchmark_metrics_schema_version")();
  if (schema !== BENCHMARK_METRICS_SCHEMA_VERSION) {
    throw new Error(`benchmark metrics schema mismatch: runtime=${schema} expected=${BENCHMARK_METRICS_SCHEMA_VERSION}`);
  }
  const length = requireExport(exports, "roc_ui_benchmark_metrics_len")();
  if (length !== BENCHMARK_METRICS_BYTE_LENGTH) {
    throw new Error(`benchmark metrics byte length mismatch: runtime=${length} expected=${BENCHMARK_METRICS_BYTE_LENGTH}`);
  }
  requireExport(exports, "roc_ui_benchmark_metrics_ptr");
  requireExport(exports, "roc_ui_benchmark_metrics_reset");
}

export function resetBenchmarkMetrics(exports) {
  validateBenchmarkMetricsExports(exports);
  exports.roc_ui_benchmark_metrics_reset();
}

export function readBenchmarkMetrics(exports) {
  validateBenchmarkMetricsExports(exports);
  if (!(exports.memory instanceof WebAssembly.Memory)) {
    throw new Error("benchmark Wasm module is missing exported linear memory");
  }
  const pointer = exports.roc_ui_benchmark_metrics_ptr();
  if (pointer % 8 !== 0 || pointer < 0 || pointer + BENCHMARK_METRICS_BYTE_LENGTH > exports.memory.buffer.byteLength) {
    throw new Error(`benchmark metrics block is outside linear memory: ptr=${pointer} len=${BENCHMARK_METRICS_BYTE_LENGTH}`);
  }
  const view = new DataView(exports.memory.buffer, pointer, BENCHMARK_METRICS_BYTE_LENGTH);
  return Object.fromEntries(BENCHMARK_METRIC_FIELDS.map((name, index) => {
    const offset = index * 8;
    const value = SIGNED_FIELDS.has(name)
      ? view.getBigInt64(offset, true)
      : view.getBigUint64(offset, true);
    return [name, value];
  }));
}
