import { readFile } from 'node:fs/promises';
import assert from 'node:assert/strict';
import { createBoundedEffectRunner } from '../../www/static/bounded_effect_runner.mjs';

const pending = new Map();
let wasm;
let mainStack;
const { instance } = await WebAssembly.instantiate(await readFile(process.argv[2]), {
  env: {
    set_limits: (top, bottom) => wasm.__set_stack_limits(top, bottom),
    suspend_effect: new WebAssembly.Suspending(id => {
      return new Promise(resolve => pending.set(id, resolve));
    }),
  },
});
wasm = instance.exports;
mainStack = wasm.__stack_pointer.value;
wasm.__set_stack_limits(mainStack, 0);
const run = createBoundedEffectRunner({ stack_pointer: wasm.__stack_pointer, stack_top: wasm.effect_stack_top, stack_bottom: wasm.effect_stack_bottom, set_limits: wasm.__set_stack_limits, set_main: wasm.set_main, run: wasm.run_effect });
const first = run(0);
assert.equal(wasm.stack_pointer(), mainStack, "suspension restores the original main stack");
assert.equal(wasm.event(99), 99);
const second = run(1);
assert.equal(wasm.stack_pointer(), mainStack, "overlap does not accumulate main-stack frames");
wasm.memory.grow(1);
assert.equal(wasm.event(77), 77);
pending.get(1)(5);
queueMicrotask(() => assert.equal(wasm.event(123), 123));
await second;
assert.equal(wasm.result(1), 512 * 20 + 511 * 512 / 2 + 5);
assert.equal(wasm.event(88), 88);
pending.get(0)(7);
await first;
assert.equal(wasm.result(0), 512 * 10 + 511 * 512 / 2 + 7);
assert.equal(wasm.stack_pointer(), mainStack);
for (let iteration = 0; iteration < 20; iteration++) {
  const a = run(0);
  const b = run(1);
  pending.get(0)(7);
  pending.get(1)(5);
  await Promise.all([a, b]);
  assert.equal(wasm.result(0), 512 * 10 + 511 * 512 / 2 + 7);
  assert.equal(wasm.result(1), 512 * 20 + 511 * 512 / 2 + 5);
  assert.equal(wasm.stack_pointer(), mainStack, "repeated overlaps restore the main stack exactly");
}
console.log('Overlapping suspended Zig effects preserve stack locals and allow ordinary events.');
