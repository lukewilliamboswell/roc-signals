import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  readBenchmarkMetrics,
  resetBenchmarkMetrics,
  validateBenchmarkMetricsExports,
} from "./wasm_benchmark_metrics.mjs";

async function instantiate(path) {
  const bytes = await readFile(path);
  return (await WebAssembly.instantiate(bytes, { env: { roc_ui_init: () => 0 } })).instance.exports;
}

test("linked benchmark host resets and reports exact Roc allocator traffic", async () => {
  const host = await instantiate(".test-out/wasm-benchmark/host-fixture.wasm");
  resetBenchmarkMetrics(host);
  const pointer = host.roc_alloc(32, 8);
  const replacement = host.roc_realloc(pointer, 48, 8);
  host.roc_dealloc(replacement, 8);
  host.roc_ui_benchmark_metrics_checkpoint();
  const metrics = readBenchmarkMetrics(host);
  assert.equal(metrics.roc_alloc_calls, 1n);
  assert.equal(metrics.roc_realloc_calls, 1n);
  assert.equal(metrics.roc_dealloc_calls, 1n);
  assert.equal(metrics.roc_allocated_bytes, 80n);
  assert.equal(metrics.roc_deallocated_bytes, 80n);
  assert.equal(metrics.roc_realloc_copied_bytes, 32n);
  assert.equal(metrics.roc_retained_count_delta, 0n);
  assert.equal(metrics.roc_retained_bytes_delta, 0n);
});

test("linked benchmark host reports command capacity and linear-memory growth separately", async () => {
  const host = await instantiate(".test-out/wasm-benchmark/host-fixture.wasm");
  resetBenchmarkMetrics(host);
  host.roc_ui_debug_mount_fixture();
  const metrics = readBenchmarkMetrics(host);
  assert.ok(metrics.command_buffer_growth_bytes > 0n);
  assert.ok(metrics.wasm_pages_after >= metrics.wasm_pages_before);
  assert.ok(metrics.runtime_patches_emitted > 0n);
  assert.ok(metrics.host_alloc_calls > 0n);
});

test("fresh benchmark instances do not inherit prior samples", async () => {
  const first = await instantiate(".test-out/wasm-benchmark/host-fixture.wasm");
  resetBenchmarkMetrics(first);
  first.roc_ui_debug_mount_fixture();
  assert.ok(readBenchmarkMetrics(first).runtime_patches_emitted > 0n);

  const second = await instantiate(".test-out/wasm-benchmark/host-fixture.wasm");
  resetBenchmarkMetrics(second);
  assert.equal(readBenchmarkMetrics(second).runtime_patches_emitted, 0n);
  assert.equal(readBenchmarkMetrics(second).roc_alloc_calls, 0n);
});

test("ordinary Wasm hosts do not expose benchmark instrumentation", async () => {
  const host = await instantiate(".test-out/oom/host-fixture.wasm");
  assert.throws(() => validateBenchmarkMetricsExports(host), /missing required export/);
});
