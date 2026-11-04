import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
const module = await WebAssembly.compile(readFileSync(new URL('./app.wasm', import.meta.url)));
const names = ['allocs','frees','allocated_bytes','realloc_copied_bytes','live_allocs','live_bytes'];
for (const n of [1000, 10000, 100000]) {
  const e = (await WebAssembly.instantiate(module, {})).exports;
  const report = phase => console.log(JSON.stringify({n, phase, ...Object.fromEntries(names.map((k,i)=>[k,Number(e.metric(i))]))}));
  const check = (...args) => e.check(...args.map(BigInt));
  const event = (phase, op, row, value, expected) => {
    e.reset_metrics();
    e.event(BigInt(op), BigInt(row), BigInt(value));
    report(phase);
    if (op !== 2) assert.ok(e.metric(2) <= 512n, 'sparse operation allocated more than its fixed budget');
    check(...expected);
  };
  e.start(BigInt(n)); report('create');
  event('diamond', 0, 0, 6, [0,6,n,3,0,1]);
  event('equal_source', 0, 0, 6, [0,6,n,0,1,0]);
  event('derived_cutoff', 0, 0, 7, [0,7,n,2,2,0]);
  event('one_branch_changes', 0, 0, 8, [0,8,n,3,1,1]);
  event('last_row', 0, n-1, 9, [n-1,9,n,3,0,1]);
  check(0,8,n,3,0,1);
  event('remove_first', 1, 0, 0, [n-1,9,n-1,0,0,1]);
  event('survivor', 0, n-1, 12, [n-1,12,n-1,3,0,1]);
  event('clear_remaining', 2, 0, 0, [0,0,0,0,0,n-1]);
  e.reset_metrics(); e.drop_state(); report('drop');
  assert.equal(e.metric(4),0n); assert.equal(e.metric(5),0n);
}

// Deterministic history against a separate numeric reference model.
for (const seed of [1, 42, 98765]) {
  const e = (await WebAssembly.instantiate(module, {})).exports;
  const values = Array(64).fill(0);
  const alive = Array(64).fill(true);
  let rng = seed, live = 64;
  const random = () => (rng = (Math.imul(rng, 1664525) + 1013904223) >>> 0);
  e.start(64n);
  for (let step = 0; step < 2000; step++) {
    const candidates = alive.flatMap((yes, i) => yes ? [i] : []);
    const row = candidates[random() % candidates.length];
    const old = values[row], value = random() % 100;
    let calls = 0, prunes = 0, commands = 0, checkRow = row;
    e.reset_metrics();
    if (live > 1 && random() % 31 === 0) {
      e.event(1n, BigInt(row), 0n);
      alive[row] = false; live--; commands = 1;
      checkRow = alive.indexOf(true);
    } else {
      if (old === value) prunes = 1;
      else {
        const halfSame = Math.floor(old / 2) === Math.floor(value / 2);
        const thirdSame = Math.floor(old / 3) === Math.floor(value / 3);
        calls = 2 + Number(!halfSame || !thirdSame);
        prunes = Number(halfSame) + Number(thirdSame);
        commands = Number(!halfSame || !thirdSame);
      }
      e.event(0n, BigInt(row), BigInt(value)); values[row] = value;
    }
    assert.ok(e.metric(2) <= 512n);
    for (const r of [checkRow, ...alive.flatMap((yes, i) => yes ? [i] : [])]) {
      e.check(...[r, values[r], live, calls, prunes, commands].map(BigInt));
    }
  }
  e.event(2n, 0n, 0n);
  e.check(...[0, 0, 0, 0, 0, live].map(BigInt));
  e.drop_state();
  assert.equal(e.metric(4), 0n); assert.equal(e.metric(5), 0n);
  console.log(JSON.stringify({phase: 'reference_history', seed, turns: 2000, passed: true}));
}

// Contract rejection uses disposable instances: a trap is terminal in this spike.
for (const invalid of ['disposed_write', 'duplicate_remove', 'unknown_op']) {
  const e = (await WebAssembly.instantiate(module, {})).exports;
  e.start(2n);
  e.event(1n, 0n, 0n);
  assert.throws(() => {
    if (invalid === 'disposed_write') e.event(0n, 0n, 6n);
    else if (invalid === 'duplicate_remove') e.event(1n, 0n, 0n);
    else e.event(99n, 0n, 0n);
  }, WebAssembly.RuntimeError);
  console.log(JSON.stringify({phase: 'contract_rejection', invalid, passed: true}));
}
