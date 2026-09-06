#!/usr/bin/env node
// Exercise real linked Roc code: a write turn followed by an observer task turn.
// Fatal containment must discard the entire host call, including earlier seals.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { SignalsRuntime, instantiateSignalsBytes } from "../../www/static/signals.mjs";
import { findByText, findNode, fireEvent, installDomDouble } from "./dom_double.mjs";

const bytes = await readFile(process.argv[2] ?? ".test-out/coordinated-writes.wasm");
const settle = () => new Promise((resolve) => setImmediate(resolve));

async function run(failureNumber) {
  const { instance } = await instantiateSignalsBytes(bytes);
  const host = instance.exports;
  const root = installDomDouble();
  const errors = [];
  const requests = [];
  const runtime = new SignalsRuntime(host, root, {
    onError: (error) => errors.push(error),
    taskHandler: (request) => {
      requests.push(request);
      return new Promise(() => {});
    },
  });
  runtime.mount();
  await settle();
  const original = root.textContent;
  const swap = findByText(root, "button", "Swap");
  assert.ok(swap);
  host.roc_ui_debug_fail_allocation(failureNumber);
  try {
    fireEvent(swap, "click", { bubbles: true });
  } catch (error) {
    // Real DOM dispatch reports listener exceptions; the DOM double rethrows.
    if (failureNumber === 0 || !errors.includes(error)) throw error;
  }
  await settle();
  const attempts = host.roc_ui_debug_allocation_attempts();
  if (failureNumber === 0) {
    assert.deepEqual(errors, []);
    assert.equal(host.roc_ui_is_poisoned(), 0);
    assert.equal(findNode(root, (node) => node.getAttribute?.("data-testid") === "pair").textContent, "B:A");
    assert.equal(requests.length, 1);
    assert.equal(requests[0].request, "B:A");
    runtime.unmount();
    return attempts;
  }
  assert.equal(host.roc_ui_is_poisoned(), 1, `allocation ${failureNumber} did not poison`);
  assert.equal(errors.length, 1, `allocation ${failureNumber} did not report exactly one fatal error`);
  assert.ok(runtime.lastHostError().length > 0);
  assert.equal(root.textContent, original, `allocation ${failureNumber} exposed a partial DOM update`);
  assert.equal(requests.length, 0, `allocation ${failureNumber} executed an unpublished task`);
  assert.equal(host.roc_ui_command_buffer_len(), 0);
  assert.equal(host.roc_ui_string_buffer_len(), 0);
  assert.equal(host.roc_ui_dynamic_buffer_len(), 0);
  // The old DOM remains fallback UI, but its listeners cannot resume the host.
  fireEvent(swap, "click", { bubbles: true });
  await settle();
  assert.equal(host.roc_ui_debug_allocation_attempts(), attempts);
  assert.equal(errors.length, 1);
  assert.throws(() => runtime.mount());
  host.roc_ui_unmount();
  host.roc_ui_unmount();
  assert.equal(host.roc_ui_debug_allocation_attempts(), attempts, "containment allocated");
  return attempts;
}

const attempts = await run(0);
assert.ok(attempts > 0);
for (let coordinate = 1; coordinate <= attempts; coordinate += 1) {
  await run(coordinate);
}
await run(0); // Recovery is a fresh instance, never resumption of poisoned state.
console.log(`coordinated writes: ${attempts} allocation failures contained without partial publication`);
