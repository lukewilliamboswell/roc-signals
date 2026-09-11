import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { SignalsRuntime, instantiateSignalsBytes } from "../../www/static/signals.mjs";
import { installDomDouble, findByText, findTextNode, fireEvent } from "./dom_double.mjs";

const requests = [];
const { instance } = await instantiateSignalsBytes(await readFile(process.argv[2]), {
  fetchImpl: (uri, options) => new Promise(resolve => requests.push({ uri, options, resolve })),
});
const root = installDomDouble();
const runtime = new SignalsRuntime(instance.exports, root);
const settle = () => new Promise(resolve => setTimeout(resolve, 0));
const expectText = async text => {
  const deadline = Date.now() + 1000;
  while (!findTextNode(root, text) && Date.now() < deadline) {
    if (runtime.failedError) throw runtime.failedError;
    await settle();
  }
  assert.ok(findTextNode(root, text), `expected ${text}`);
};
runtime.mount();
fireEvent(findByText(root, "button", "Oversized"), "click", { bubbles: true });
await expectText("Too large");
assert.equal(requests.length, 0, "header admission refuses before fetch");
assert.equal(runtime.failedError, null, "a typed refusal must not poison the runtime");
fireEvent(findByText(root, "button", "Too long"), "click", { bubbles: true });
await expectText("Invalid timeout");
assert.equal(requests.length, 0, "an explicit max-u64 timeout must not alias NoTimeout");
assert.equal(runtime.failedError, null, "an invalid duration is a typed refusal");
fireEvent(findByText(root, "button", "Fetch"), "click", { bubbles: true });
await settle();
assert.equal(requests.length, 1);
assert.ok(findTextNode(root, "Loading"));
fireEvent(findByText(root, "button", "Fetch"), "click", { bubbles: true });
await settle();
assert.equal(requests.length, 2, "an equal request is a separate occurrence while the first is suspended");
requests[1].resolve(new Response("second λ"));
await expectText("second λ");
requests[0].resolve(new Response("first λ"));
await expectText("first λ");
runtime.unmount();
assert.equal(instance.exports.roc_ui_live_host_values(), 0);

let aborted = false;
const shutdown = await instantiateSignalsBytes(await readFile(process.argv[2]), {
  fetchImpl: (_uri, { signal }) => new Promise((_resolve, reject) => {
    signal.addEventListener("abort", () => { aborted = true; reject(new Error("stopped")); }, { once: true });
  }),
});
const shutdownRoot = installDomDouble();
const shutdownRuntime = new SignalsRuntime(shutdown.instance.exports, shutdownRoot);
shutdownRuntime.mount();
fireEvent(findByText(shutdownRoot, "button", "Fetch"), "click", { bubbles: true });
await settle();
assert.equal(shutdownRuntime.runningEffects.size, 1);
shutdownRuntime.unmount();
shutdownRuntime.unmount();
for (const dispatch of [
  () => shutdownRuntime.dispatchUnit(1),
  () => shutdownRuntime.dispatchBool(1, true),
  () => shutdownRuntime.dispatchString(1, "late"),
  () => shutdownRuntime.dispatchBytes(1, new Uint8Array([1])),
]) assert.throws(dispatch, /requires a mounted runtime/);
assert.equal(shutdownRuntime.failedError, null, "rejected late input does not poison suspended cleanup");
assert.equal(aborted, true);
assert.equal(findByText(shutdownRoot, "button", "Fetch"), null, "input is detached immediately");
for (let attempt = 0; attempt < 100 && !shutdownRuntime.unmountFinished; attempt++) await settle();
assert.equal(shutdownRuntime.unmountFinished, true);
assert.equal(shutdownRuntime.failedError, null);
assert.equal(shutdownRuntime.runningEffects.size, 0);
assert.equal(shutdown.instance.exports.roc_ui_live_host_values(), 0);
shutdownRuntime.mount();
fireEvent(findByText(shutdownRoot, "button", "Fetch"), "click", { bubbles: true });
shutdownRuntime.unmount();
shutdownRuntime.mount();
fireEvent(findByText(shutdownRoot, "button", "Fetch"), "click", { bubbles: true });
await settle();
assert.equal(shutdownRuntime.runningEffects.size, 1, "a stale pump cannot strand the next mount's effect");
shutdownRuntime.unmount();
for (let attempt = 0; attempt < 100 && !shutdownRuntime.unmountFinished; attempt++) await settle();
assert.equal(shutdownRuntime.unmountFinished, true);
assert.equal(shutdown.instance.exports.roc_ui_live_host_values(), 0);
console.log("Linked HTTP effects overlap, settle in completion order, and release retained values.");
