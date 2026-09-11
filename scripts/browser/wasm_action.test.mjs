import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { SignalsRuntime, instantiateSignalsBytes } from "../../www/static/signals.mjs";
import { installDomDouble, findByText, findTextNode, fireEvent } from "./dom_double.mjs";

const { instance } = await instantiateSignalsBytes(await readFile(process.argv[2]));
const host = instance.exports;
const root = installDomDouble();
const runtime = new SignalsRuntime(host, root);
runtime.mount();
assert.ok(findTextNode(root, "Count: 0"));

let expected = 0;
let warmedMemoryBytes;
for (let iteration = 0; iteration < 12; iteration++) {
  expected = (expected + 1) * 4;
  fireEvent(findByText(root, "button", "Run"), "click", { bubbles: true });
  await new Promise(resolve => setTimeout(resolve, 0));
  assert.equal(runtime.runningEffects.size, 0);
  assert.ok(findTextNode(root, `Count: ${expected}`));
  if (iteration === 2) warmedMemoryBytes = host.memory.buffer.byteLength;
  if (iteration > 2) assert.equal(host.memory.buffer.byteLength, warmedMemoryBytes, "completed effect stacks are reused without growing Wasm memory");
}
runtime.unmount();
assert.equal(host.roc_ui_live_host_values(), 0);

const abandoned = await instantiateSignalsBytes(await readFile(process.argv[2]));
const abandonedRoot = installDomDouble();
const abandonedRuntime = new SignalsRuntime(abandoned.instance.exports, abandonedRoot);
abandonedRuntime.mount();
fireEvent(findByText(abandonedRoot, "button", "Run"), "click", { bubbles: true });
abandonedRuntime.unmount();
await new Promise(resolve => setTimeout(resolve, 0));
assert.equal(abandonedRuntime.runningEffects.size, 0);
assert.equal(abandoned.instance.exports.roc_ui_live_host_values(), 0);
assert.equal(abandonedRuntime.failedError, null);
console.log("Linked web actions commit fresh effect snapshots and release all host values.");
