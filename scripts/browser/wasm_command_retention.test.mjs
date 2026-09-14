import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { SignalsRuntime, instantiateSignalsBytes } from "../../www/static/signals.mjs";
import { findAll, findNode, fireEvent, installDomDouble } from "./dom_double.mjs";
import { readBenchmarkMetrics } from "./wasm_benchmark_metrics.mjs";

// Reuse one linked instance: fresh-instance benchmarks cannot detect storage
// accumulated across publications or a failed release/reset on remount.
const { instance } = await instantiateSignalsBytes(await readFile(process.argv[2]));
const root = installDomDouble();
const runtime = new SignalsRuntime(instance.exports, root, {
  onError: (error) => { throw error; },
});
const rowCount = () => findAll(root, node => node.getAttribute?.("data-row-id") != null).length;
const action = id => {
  const node = findNode(root, entry => id === "select-first"
    ? entry.getAttribute?.("aria-label")?.startsWith("Select row ")
    : entry.getAttribute?.("id") === id);
  assert.ok(node, `missing action ${id}`);
  fireEvent(node, "click", { bubbles: true });
  assert.ok(readBenchmarkMetrics(instance.exports).command_buffer_capacity_bytes <= 128n * 1024n,
    "acknowledged command banks stay within the combined retention budget");
};
for (let mount = 0; mount < 2; mount++) {
  runtime.mount();
  for (let cycle = 0; cycle < 3; cycle++) {
    action("runlots");
    assert.equal(rowCount(), 10000);
    action("select-first");
    assert.equal(findAll(root, node => node.className === "danger").length, 1);
    action("clear");
    assert.equal(rowCount(), 0);
  }
  runtime.unmount();
  const metrics = readBenchmarkMetrics(instance.exports);
  assert.equal(metrics.command_buffer_capacity_bytes, 0n);
  assert.equal(metrics.roc_live_bytes, 0n);
  assert.equal(instance.exports.roc_ui_live_host_values(), 0);
}
