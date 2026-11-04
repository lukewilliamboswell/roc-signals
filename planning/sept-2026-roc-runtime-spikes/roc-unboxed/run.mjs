import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
const module = await WebAssembly.compile(readFileSync(new URL('./app.wasm', import.meta.url)));
for (let iteration = 0; iteration < 3; iteration++) {
  const e = (await WebAssembly.instantiate(module, {})).exports;
  const guarded = fn => {
    try { return fn(); } catch (err) {
      console.error(new TextDecoder().decode(new Uint8Array(e.memory.buffer,e.error_ptr(),e.error_len())));
      throw err;
    }
  };
  guarded(()=>e.start());
  console.log(JSON.stringify({iteration,phase:'mounted',live_allocations:Number(e.metric(4))}));
  for (let action = 0; action < 6; action++) {
    guarded(()=>e.step(BigInt(action)));
    console.log(JSON.stringify({iteration,phase:'action',action,live_allocations:Number(e.metric(4))}));
  }
  guarded(()=>e.finish());
  assert.equal(e.metric(4),0n); assert.equal(e.metric(5),0n);
  console.log(JSON.stringify({iteration,phase:'teardown',live_allocations:0}));
}

for (const [action, expected] of [[6,'disposed event'],[7,'CapabilityMismatch'],[8,'CapabilityMismatch']]) {
  const e = (await WebAssembly.instantiate(module, {})).exports;
  e.start();
  assert.throws(()=>e.step(BigInt(action)),WebAssembly.RuntimeError);
  const message = new TextDecoder().decode(new Uint8Array(e.memory.buffer,e.error_ptr(),e.error_len()));
  assert.equal(message,expected);
  console.log(JSON.stringify({phase:'contract_rejection',action,message}));
}
