import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { SignalsRuntime, Protocol, ProtocolFeature } from "../../www/static/signals.mjs";
import { installDomDouble } from "./dom_double.mjs";

// Separate instances keep intentional corruption out of the protected run.
for (const [path, protectedStack] of [[process.argv[2], false], [process.argv[3], true]]) {
  const { instance } = await WebAssembly.instantiate(await readFile(path));
  const wasm = instance.exports;
  const main = wasm.__stack_pointer.value;
  if (protectedStack) wasm.__set_stack_limits(main, 0);
  wasm.prepare();
  assert.equal(wasm.sentinel(), 42);
  const top = wasm.effect_stack_top();
  if (protectedStack) wasm.__set_stack_limits(top, top - 65536);
  wasm.__stack_pointer.value = top;
  try {
    if (protectedStack) assert.throws(() => wasm.overflow(), WebAssembly.RuntimeError);
    else assert.equal(wasm.overflow(), 99);
  } finally {
    if (protectedStack) wasm.__set_stack_limits(main, 0);
    wasm.__stack_pointer.value = main;
  }
  assert.equal(wasm.sentinel(), protectedStack ? 42 : 99,
    protectedStack ? "overflow must trap before corrupting adjacent storage" :
      "the control must demonstrate the corruption this check prevents");
}
console.log("Stack instrumentation traps before an oversized frame corrupts adjacent storage.");

// Exercise the actual bounded trampoline and runtime failure path. Only the
// protocol/queue adapter is synthetic; the overflowing frame is compiled Zig.
const { instance } = await WebAssembly.instantiate(await readFile(process.argv[3]));
const wasm = instance.exports;
wasm.__set_stack_limits(wasm.__stack_pointer.value, 0);
wasm.prepare();
let entries = 0;
const forbidden = () => { throw new Error("host re-entry after stack trap"); };
const errors = [];
const runtime = new SignalsRuntime({
  memory: wasm.memory,
  __stack_pointer: wasm.__stack_pointer,
  __set_stack_limits: wasm.__set_stack_limits,
  roc_ui_effect_stack_top: wasm.runtime_stack_top,
  roc_ui_effect_stack_bottom: wasm.runtime_stack_bottom,
  roc_ui_effect_stack_main: wasm.runtime_set_main,
  roc_ui_effect_run: wasm.runtime_run,
  roc_ui_effect_next: () => ++entries <= 2 ? entries : 0,
  roc_ui_effect_complete: forbidden,
  roc_ui_unmount: forbidden,
  roc_ui_last_error_ptr: forbidden,
  roc_ui_protocol_version: () => Protocol.version,
  roc_ui_protocol_features: () => ProtocolFeature.dynamicAttrs | ProtocolFeature.dynamicEvents,
  roc_ui_dynamic_buffer_ptr: () => 0,
  roc_ui_dynamic_buffer_len: () => 0,
}, installDomDouble(), { onError: error => errors.push(error) });
runtime.mounted = true;
runtime.scheduleEffects();
await new Promise(resolve => setTimeout(resolve, 0));
assert.equal(entries, 1);
assert.ok(runtime.failedError instanceof WebAssembly.RuntimeError);
assert.equal(errors.length, 1);
assert.equal(runtime.runningEffects.size, 0);
runtime.unmount();
assert.throws(() => runtime.dispatchUnit(1), WebAssembly.RuntimeError);
console.log("An actual effect-stack trap stops queue entry and makes shutdown host-call-free.");
