import assert from "node:assert/strict";
import test from "node:test";

import {
  BENCHMARK_METRIC_FIELDS,
  BENCHMARK_METRICS_BYTE_LENGTH,
  BENCHMARK_METRICS_SCHEMA_VERSION,
  readBenchmarkMetrics,
  resetBenchmarkMetrics,
  validateBenchmarkMetricsExports,
} from "./wasm_benchmark_metrics.mjs";

function fixture(overrides = {}) {
  const memory = new WebAssembly.Memory({ initial: 1 });
  let resets = 0;
  return {
    exports: {
      memory,
      roc_ui_benchmark_metrics_schema_version: () => BENCHMARK_METRICS_SCHEMA_VERSION,
      roc_ui_benchmark_metrics_len: () => BENCHMARK_METRICS_BYTE_LENGTH,
      roc_ui_benchmark_metrics_ptr: () => 8,
      roc_ui_benchmark_metrics_reset: () => { resets += 1; },
      ...overrides,
    },
    resets: () => resets,
  };
}

test("benchmark metrics reader preserves every fixed-layout integer exactly", () => {
  const { exports } = fixture();
  const view = new DataView(exports.memory.buffer, 8, BENCHMARK_METRICS_BYTE_LENGTH);
  BENCHMARK_METRIC_FIELDS.forEach((_, index) => view.setBigUint64(index * 8, BigInt(index + 1), true));
  assert.deepEqual(Object.keys(readBenchmarkMetrics(exports)), BENCHMARK_METRIC_FIELDS);
  assert.equal(readBenchmarkMetrics(exports)[BENCHMARK_METRIC_FIELDS.at(-1)], BigInt(BENCHMARK_METRIC_FIELDS.length));
});

test("benchmark metrics reset validates the schema before entering Wasm", () => {
  const state = fixture();
  resetBenchmarkMetrics(state.exports);
  assert.equal(state.resets(), 1);
});

test("benchmark metrics reject missing exports, schema drift, and layout drift", () => {
  const missing = fixture({ roc_ui_benchmark_metrics_ptr: undefined }).exports;
  assert.throws(() => validateBenchmarkMetricsExports(missing), /missing required export roc_ui_benchmark_metrics_ptr/);
  const schema = fixture({ roc_ui_benchmark_metrics_schema_version: () => BENCHMARK_METRICS_SCHEMA_VERSION + 1 }).exports;
  assert.throws(() => validateBenchmarkMetricsExports(schema), /schema mismatch/);
  const length = fixture({ roc_ui_benchmark_metrics_len: () => BENCHMARK_METRICS_BYTE_LENGTH + 8 }).exports;
  assert.throws(() => validateBenchmarkMetricsExports(length), /byte length mismatch/);
});

test("benchmark metrics reject malformed pointers and missing memory", () => {
  assert.throws(() => readBenchmarkMetrics(fixture({ roc_ui_benchmark_metrics_ptr: () => 3 }).exports), /outside linear memory/);
  assert.throws(() => readBenchmarkMetrics(fixture({ memory: undefined }).exports), /missing exported linear memory/);
});
