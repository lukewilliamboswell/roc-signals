import assert from "node:assert/strict";
import test from "node:test";

import { BenchmarkPhaseRecorder, BenchmarkSignalsRuntime } from "./wasm_benchmark_runtime.mjs";

function steppedClock(values) {
  let index = 0;
  return () => BigInt(values[index++]);
}

test("phase recorder computes mutually exclusive residual timing", () => {
  const recorder = new BenchmarkPhaseRecorder(steppedClock([0, 10, 20, 30, 40, 50, 60, 70, 80, 90]));
  recorder.begin();
  recorder.measure("wasm_event_ns", () => {});
  recorder.measure("command_read_ns", () => {});
  recorder.measure("command_snapshot_ns", () => {});
  recorder.measure("command_acknowledge_ns", () => {});
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
  assert.equal(result.command_acknowledge_ns, 10n);
  assert.equal(result.event_residual_js_ns, 50n);
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
  overlap.calls.command_acknowledge_ns = 1;
  overlap.calls.command_execute_ns = 1;
  overlap.timings.wasm_event_ns = 8n;
  overlap.timings.command_read_ns = 8n;
  overlap.timings.command_execute_ns = 8n;
  overlap.eventCalls = 1;
  overlap.event_total_ns = 20n;
  assert.throws(() => overlap.finish(), /nested phases exceed event total/);
});

// Run the actual executor lifecycle: a benchmark must count suspended effects,
// then observe each completion, without knowing the runtime's registry layout.
test("benchmark state observes suspended effects and their completion", async () => {
  class RegistryRuntime extends BenchmarkSignalsRuntime {
    checkProtocol() {} // Protocol/stack negotiation has separate linked tests.
    applyPendingCommands() {} // This fixture's completed effects publish no commands.
  }
  const queued = [1, 2];
  const completed = [];
  const runtime = new RegistryRuntime({
    memory: new WebAssembly.Memory({ initial: 1 }),
    roc_ui_effect_next: () => queued.shift() ?? 0,
    roc_ui_effect_complete: token => completed.push(token),
    roc_ui_unmount: () => {},
  }, { replaceChildren() {} }, { onError: error => { throw error; } });
  const settle = new Map();
  runtime.runEffect = token => new Promise(resolve => settle.set(token, resolve));
  runtime.mounted = true;
  assert.equal(runtime.benchmarkRuntimeState().running_effects, 0);
  runtime.scheduleEffects();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(runtime.benchmarkRuntimeState().running_effects, 2);
  settle.get(2)();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(runtime.benchmarkRuntimeState().running_effects, 1);
  settle.get(1)();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(runtime.benchmarkRuntimeState().running_effects, 0);
  assert.deepEqual(completed, [2, 1]);
  runtime.unmount();
  assert.equal(runtime.benchmarkRuntimeState().running_effects, 0);
  assert.equal(runtime.unmountFinished, true);
});
