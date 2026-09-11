import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { SignalsRuntime, instantiateSignalsBytes } from "../../www/static/signals.mjs";
import { createPublicExampleFetch } from "../../www/static/example_tasks.mjs";
import { installDomDouble, findTextNode, findNode, fireEvent } from "./dom_double.mjs";

let requests = 0;
const backend = createPublicExampleFetch(() => { throw new Error("unexpected external fetch"); });
const { instance } = await instantiateSignalsBytes(await readFile(process.argv[2]), {
  fetchImpl: (...args) => { requests++; return backend(...args); },
});
const root = installDomDouble();
const runtime = new SignalsRuntime(instance.exports, root);
runtime.mount();
const deadline = Date.now() + 3000;
while (!findTextNode(root, "Results ready") && Date.now() < deadline) {
  if (runtime.failedError) throw runtime.failedError;
  await new Promise(resolve => setTimeout(resolve, 10));
}
assert.ok(findTextNode(root, "Results ready"), "initial observer effect publishes the flight results");
assert.equal(requests, 1, "publishing result state does not retrigger the request");
const sort = findNode(root, node => node.getAttribute?.("aria-label") === "Sort by");
assert.ok(sort);
sort.value = "duration";
fireEvent(sort, "change", { bubbles: true });
await new Promise(resolve => setTimeout(resolve, 0));
assert.ok(findTextNode(root, "Sorted by: duration"));
assert.equal(requests, 1, "sorting is a derived view, not a new effect");
runtime.unmount();
assert.equal(instance.exports.roc_ui_live_host_values(), 0);

const pending = [];
const overlap = await instantiateSignalsBytes(await readFile(process.argv[2]), {
  fetchImpl: (uri, options) => new Promise(resolve => pending.push({ uri, options, resolve })),
});
const overlapRoot = installDomDouble();
const overlapRuntime = new SignalsRuntime(overlap.instance.exports, overlapRoot);
const waitFor = async predicate => {
  const deadline = Date.now() + 3000;
  while (!predicate() && Date.now() < deadline) {
    if (overlapRuntime.failedError) throw overlapRuntime.failedError;
    await new Promise(resolve => setTimeout(resolve, 0));
  }
  assert.ok(predicate(), "expected asynchronous flight-search state");
};
overlapRuntime.mount();
await waitFor(() => pending.length === 1);
assert.ok(findTextNode(overlapRoot, "Searching"));
assert.ok(findTextNode(overlapRoot, "Fetching flights"));
assert.ok(findTextNode(overlapRoot, "Result order: none"));
assert.ok(findTextNode(overlapRoot, "Top result: none"));
const pendingSort = findNode(overlapRoot, node => node.getAttribute?.("aria-label") === "Sort by");
pendingSort.value = "duration";
fireEvent(pendingSort, "change", { bubbles: true });
await new Promise(resolve => setTimeout(resolve, 0));
assert.equal(pending.length, 1, "sorting during a pending request does not refetch");
assert.equal(pending[0].options.signal.aborted, false);
assert.ok(findTextNode(overlapRoot, "Sorted by: duration"));
assert.ok(findTextNode(overlapRoot, "Searching"));
assert.ok(findTextNode(overlapRoot, "Fetching flights"));
const origin = findNode(overlapRoot, node => node.getAttribute?.("aria-label") === "From");
assert.ok(origin);
for (const [index, value] of ["MEL", "SYD"].entries()) {
  origin.value = value;
  fireEvent(origin, "change", { bubbles: true });
  await waitFor(() => pending.length === index + 2);
  assert.ok(findTextNode(overlapRoot, "Searching"), "changing a filter starts a pending search");
  assert.ok(findTextNode(overlapRoot, "Fetching flights"));
  assert.ok(findTextNode(overlapRoot, "Result order: none"));
}
assert.equal(pending[0].uri, pending[2].uri, "the newest request repeats the first URI");
assert.ok(pending.every(item => !item.options.signal.aborted), "new intent does not cancel old effects");
pending[1].resolve(new Response("MIDDLE,Qantas,06:00,100,0,90"));
await waitFor(() => overlapRuntime.runningEffects.size === 2);
assert.ok(findTextNode(overlapRoot, "Searching"), "stale completion leaves the newest request loading");
assert.ok(findTextNode(overlapRoot, "Fetching flights"));
assert.ok(findTextNode(overlapRoot, "Result order: none"));
assert.equal(overlapRuntime.lastCommands.length, 0, "a stale generation publishes no rendering work");
pending[2].resolve(new Response("NEW,Qantas,06:00,100,0,90"));
await waitFor(() => !!findTextNode(overlapRoot, "Top result: NEW"));
pending[0].resolve(new Response("OLD,Qantas,06:00,100,0,90"));
await waitFor(() => overlapRuntime.runningEffects.size === 0);
assert.ok(findTextNode(overlapRoot, "Top result: NEW"), "older generations cannot replace the newest equal URI");
assert.equal(pending.length, 3, "settlement never starts another request");
overlapRuntime.unmount();
assert.equal(overlap.instance.exports.roc_ui_live_host_values(), 0);
console.log("Flight search mounts, fetches once, renders results, and releases retained values.");
