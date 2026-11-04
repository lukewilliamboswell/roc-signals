import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
const module = await WebAssembly.compile(readFileSync(new URL(process.argv[2] ?? './app.wasm', import.meta.url)));
const names = ['allocs','frees','allocated_bytes','realloc_copied_bytes','live_allocs','live_bytes'];
for (const n of [1000, 10000, 100000]) {
  const e = (await WebAssembly.instantiate(module, {})).exports;
  const metrics = () => Object.fromEntries(names.map((k,i)=>[k,Number(e.metric(i))]));
  const check = (...args) => e.check(...args.map(BigInt));
  const turn = (phase, kind, row, value, calls, prunes, emitted) => {
    e.reset_metrics(); e.event(...[kind,row,value].map(BigInt));
    console.log(JSON.stringify({n,phase,...metrics()}));
    check(kind,row,value,calls,prunes,emitted);
  };
  e.start(BigInt(n)); console.log(JSON.stringify({n,phase:'create',...metrics()}));
  turn('task_toggle',0,0,1,3,1,1);
  turn('task_equal',0,0,1,0,1,0);
  turn('task_revision_cutoff',0,0,3,2,2,0);
  turn('cart_quantity',1,n-1,10,3,1,1);
  turn('cart_free_shipping',1,n-1,30,3,0,1);
  turn('cart_equal',1,n-1,30,0,1,0);
  check(0,0,3,2,2,0);
  check(0,n-1,0,2,2,0);
  check(1,0,0,0,1,0);
  e.reset_metrics();e.drop_state();console.log(JSON.stringify({n,phase:'drop',...metrics()}));
  assert.equal(e.metric(4),0n); assert.equal(e.metric(5),0n);
}
