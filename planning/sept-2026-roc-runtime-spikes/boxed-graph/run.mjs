import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
const bytes = readFileSync(new URL('./app.wasm', import.meta.url));
const module = await WebAssembly.compile(bytes);
console.error('imports', WebAssembly.Module.imports(module));
const names = ['allocs', 'frees', 'allocated_bytes', 'realloc_copied_bytes', 'live_allocs', 'live_bytes'];
for (const n of [1000, 10000, 100000]) {
  for (const retain of [0, 1, 2, 3]) {
    const { exports: e } = await WebAssembly.instantiate(module, {});
    const report = phase => console.log(JSON.stringify({ n, retain, phase, ...Object.fromEntries(names.map((name, i) => [name, Number(e.metric(i))])) }));
    e.start(BigInt(n), BigInt(retain));
    report('create');
    e.reset_metrics();
    for (let i = 0; i < 100; i++) e.handoff();
    report('100_handoffs');
    assert.equal(e.metric(0), 0n);
    assert.equal(e.metric(1), 0n);
    e.reset_metrics();
    e.update(0n, 1n);
    report('first_update');
    e.reset_metrics();
    for (let i = 0; i < 100; i++) e.update(0n, 1n);
    report('next_100_updates');
    e.reset_metrics();
    e.update(0n, 100n);
    report('batch_100_updates');
    assert.equal(Number(e.metric(0)), 2);
    e.reset_metrics();
    assert.equal(e.finish(201n), 201n);
    report('validate_and_drop');
    assert.equal(e.metric(4), 0n);
    assert.equal(e.metric(5), 0n);
    e.start(BigInt(n), BigInt(retain));
    e.reset_metrics();
    e.drop_state();
    report('drop_only');
    assert.equal(e.metric(0), 0n);
    assert.equal(e.metric(4), 0n);
    assert.equal(e.metric(5), 0n);
  }
}
