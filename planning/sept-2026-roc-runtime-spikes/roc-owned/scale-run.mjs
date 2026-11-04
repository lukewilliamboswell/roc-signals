import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
const n = Number(process.argv[2]);
const bytes = readFileSync(new URL(`./scale-${n}.wasm`,import.meta.url));
const {instance} = await WebAssembly.instantiate(bytes,{});
const e = instance.exports;
const names = ['allocs','frees','allocated_bytes','realloc_copied_bytes','live_allocs','live_bytes'];
const report = phase => console.log(JSON.stringify({n,phase,build:'Debug',...Object.fromEntries(names.map((k,i)=>[k,Number(e.metric(i))]))}));
try {
  e.start(); report('mount');
  e.reset_metrics(); e.step(0n); report('update');
  assert.ok(e.metric(0) <= 32n, 'sparse update allocation budget');
  assert.ok(e.metric(2) <= 2048n, 'sparse update byte budget');
  e.reset_metrics(); e.step(1n); report('clear');
  assert.ok(e.metric(0) <= 12n, 'clear allocation budget');
  assert.ok(e.metric(2) <= 1024n, 'clear must not copy growing graph tables');
  e.reset_metrics(); e.finish(); report('teardown');
  assert.equal(e.metric(4),0n); assert.equal(e.metric(5),0n);
} catch (err) {
  console.error(new TextDecoder().decode(new Uint8Array(e.memory.buffer,e.error_ptr(),e.error_len())));
  throw err;
}
