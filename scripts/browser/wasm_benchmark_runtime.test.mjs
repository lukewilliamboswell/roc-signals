import assert from "node:assert/strict";
import test from "node:test";

import { BenchmarkPhaseRecorder } from "./wasm_benchmark_runtime.mjs";

function steppedClock(values) {
  let index = 0;
  return () => BigInt(values[index++]);
}

test("phase recorder computes mutually exclusive residual timing", () => {
  const recorder = new BenchmarkPhaseRecorder(steppedClock([0, 10, 20, 30, 40, 50, 60, 70]));
  recorder.begin();
  recorder.measure("wasm_event_ns", () => {});
  recorder.measure("command_read_ns", () => {});
  recorder.measure("command_snapshot_ns", () => {});
  recorder.measure("command_execute_ns", () => {});
  // Supply the marked total directly because the phase calls above are a seam
  // test rather than a nested real event.
  recorder.eventCalls = 1;
  recorder.event_total_ns = 100n;
  const result = recorder.finish();
  assert.equal(result.wasm_event_ns, 10n);
  assert.equal(result.command_read_ns, 10n);
  assert.equal(result.command_snapshot_ns, 10n);
  assert.equal(result.command_execute_ns, 10n);
  assert.equal(result.event_residual_js_ns, 60n);
});

test("phase recorder rejects missing, duplicated, and overlapping phases", () => {
  const missing = new BenchmarkPhaseRecorder(() => 0n);
  missing.begin();
  missing.eventCalls = 1;
  assert.throws(() => missing.finish(), /wasm_event_ns must execute once/);

  const duplicate = new BenchmarkPhaseRecorder(steppedClock([0, 1, 2, 3, 4, 5, 6, 7]));
  duplicate.begin();
  duplicate.measure("wasm_event_ns", () => {});
  duplicate.measure("wasm_event_ns", () => {});
  duplicate.measure("command_read_ns", () => {});
  duplicate.measure("command_execute_ns", () => {});
  duplicate.eventCalls = 1;
  duplicate.event_total_ns = 20n;
  assert.throws(() => duplicate.finish(), /wasm_event_ns must execute once/);

  const overlap = new BenchmarkPhaseRecorder(() => 10n);
  overlap.begin();
  overlap.calls.wasm_event_ns = 1;
  overlap.calls.command_read_ns = 1;
  overlap.calls.command_execute_ns = 1;
  overlap.timings.wasm_event_ns = 8n;
  overlap.timings.command_read_ns = 8n;
  overlap.timings.command_execute_ns = 8n;
  overlap.eventCalls = 1;
  overlap.event_total_ns = 20n;
  assert.throws(() => overlap.finish(), /nested phases exceed event total/);
});
