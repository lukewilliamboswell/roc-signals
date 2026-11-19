// Real WebCrypto primitives behind independently encoded FX requests. The
// fake host models only staging/release; it never supplies crypto answers.
import assert from "node:assert/strict";
import { createCipheriv, createHash, pbkdf2Sync, webcrypto } from "node:crypto";
import { RocEngineRuntime, PROTOCOL_VERSION, readDeclarations, MAX_CRYPTO_BYTES, MAX_CRYPTO_ITERATIONS } from "../../platform/runtime.mjs";
import { protocolFixtureFacts, protocolFixtureSection } from "../browser/protocol-fixture.mjs";

const check = async (name, run) => {
  try { await run(); console.log(`ok   ${name}`); }
  catch (error) { console.error(`FAIL ${name}: ${error.stack}`); process.exitCode = 1; }
};
const encoder = new TextEncoder();
const text = value => encoder.encode(value);
const word = value => [value & 255, (value >>> 8) & 255, (value >>> 16) & 255, value >>> 24];
const wide = value => { const bytes = new Uint8Array(8); new DataView(bytes.buffer).setBigUint64(0, BigInt(value), true); return [...bytes]; };
const block = bytes => [...word(bytes.length), ...bytes];
const section = (tag, bytes) => [tag, ...word(bytes.length), ...bytes];
const declarations = Uint8Array.from([...section(2, word(0)), ...section(5, word(0)), ...section(6, word(0)), ...section(10, [110, 1]), ...section(11, word(0)), ...protocolFixtureSection, ...section(14, [0])]);
const FX = protocolFixtureFacts.ops.find(row => row.name === "FX").code;
const batch = (operation, operands, id = 1) => Uint8Array.from([0, FX, ...word(id), 21, operation, ...operands]);
const flatten = payload => payload.parts ? Buffer.concat(payload.parts.map(part => Buffer.from(part))) : Buffer.from(payload);
const settle = async () => { for (let index = 0; index < 8; index += 1) await Promise.resolve(); };
const quiet = run => { const original = console.error; console.error = () => {}; try { return run(); } finally { console.error = original; } };

function fixture(options = {}) {
  const memory = new WebAssembly.Memory({ initial: 4 });
  let commandLength = 0, stagedLength = 0, minted = 0, nextToken = 100n, released = [];
  const calls = [];
  let room = 64;
  const x = {
    memory, protocol_version: () => PROTOCOL_VERSION, dbg_ptr: () => 0, dbg_len: () => 0,
    boot_keys() { new Uint8Array(memory.buffer).set(declarations); commandLength = declarations.length; },
    cmd_ptr: () => 0, cmd_len: () => commandLength,
    payload_reserve(length) { stagedLength = length; memory.grow(1); return 65536; },
    event(node, handler) { calls.push({ node, handler, payload: new Uint8Array(memory.buffer, 65536, stagedLength).slice(), keyed: false }); commandLength = 0; return 0; },
    event_key(node, handler) { calls.push({ node, handler, payload: new Uint8Array(memory.buffer, 65536, stagedLength).slice(), keyed: true }); commandLength = 0; return 0; },
    keys_stage(count) { memory.grow(1); minted += Math.min(count, room); if (count && room) { new DataView(memory.buffer).setBigUint64(32768, nextToken++, true); room -= 1; return 1; } return 0; },
    keys_tokens: () => 32768,
    keys_released() { const count = released.length; released.forEach((token, index) => new DataView(memory.buffer).setBigUint64(32768 + index * 8, token, true)); released = []; return count; },
    files_released: () => 0, fault: () => 0, err_ptr: () => 0, err_len: () => 0, work_len: () => 0, metric: () => 0n, drop() {},
  };
  const root = { nodeType: 1, hasAttributeNS: () => false, addEventListener() {}, removeEventListener() {}, textContent: "" };
  const window = { crypto: webcrypto, addEventListener() {}, removeEventListener() {}, navigator: {} };
  const runtime = new RocEngineRuntime(x, root, { manualEffects: true, window, ...options });
  runtime.protocol = readDeclarations(x).bindings;
  return {
    runtime, calls, x, minted: () => minted, room: count => { room = count; }, nextToken: value => { nextToken = BigInt(value); },
    releases: tokens => { released = tokens.map(BigInt); },
    apply(bytes, mode = "normal") { new Uint8Array(memory.buffer).set(bytes); commandLength = bytes.length; quiet(() => runtime.guard(() => mode === "preflight" ? runtime.applyBatch("preflight", { definitions: new Map() }) : runtime.apply())); },
  };
}
const derive = (hash = 1, password = text("correct horse"), salt = new Uint8Array(16).fill(7), iterations = 10) => batch(2, [hash, ...word(iterations), ...block(password), ...block(salt)]);
async function keyOf(fixtureValue, hash = 1) {
  fixtureValue.apply(derive(hash));
  assert.equal(fixtureValue.runtime.poisoned, null);
  assert.equal(fixtureValue.runtime.pendingEffects().length, 1);
  assert.equal(await fixtureValue.runtime.runEffect(1), true);
  assert.deepEqual([...fixtureValue.calls.at(-1).payload], [27]);
  assert.equal(fixtureValue.calls.at(-1).keyed, true);
  return fixtureValue.runtime.keys.get(100n);
}

await check("PBKDF2 SHA-256 and SHA-512 yield non-extractable AES-256-GCM keys", async () => {
  for (const [hash, name] of [[1, "sha256"], [3, "sha512"]]) {
    const f = fixture();
    const key = await keyOf(f, hash);
    assert.equal(key.extractable, false);
    assert.deepEqual(key.usages, ["encrypt", "decrypt"]);
    assert.deepEqual(key.algorithm, { name: "AES-GCM", length: 256 });
    await assert.rejects(webcrypto.subtle.exportKey("raw", key), { name: "InvalidAccessException" });
    assert.equal(key.extractable, false);
    assert.deepEqual(key.algorithm, { name: "AES-GCM", length: 256 });
    assert.deepEqual(key.usages, ["encrypt", "decrypt"]);
    await assert.rejects(webcrypto.subtle.exportKey("raw", key), /extractable/);
    const expected = pbkdf2Sync("correct horse", Buffer.alloc(16, 7), 10, 32, name);
    const iv = Buffer.alloc(12, 3), plaintext = text("secret"), associated = text("project-7");
    const cipher = createCipheriv("aes-256-gcm", expected, iv); cipher.setAAD(associated);
    const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final(), cipher.getAuthTag()]);
    f.apply(batch(4, [...wide(100), ...block(iv), ...block(ciphertext), ...block(associated)], 2));
    await f.runtime.runEffect(2);
    assert.deepEqual(flatten(f.calls.at(-1).payload), Buffer.concat([Buffer.from([28]), Buffer.from(plaintext)]));
    f.runtime.unmount();
  }
});

await check("fresh IVs, exact binary round trip and authentication failures", async () => {
  const f = fixture({ manualEffects: false });
  // Acquire a key in manual mode so the staging path is exercised.
  f.runtime.manual = true; await keyOf(f); f.runtime.manual = false;
  const plaintext = Uint8Array.from([0, 255, 128, 1, 0, 13, 10]), associated = text("a project id");
  f.runtime.manual = true;
  f.apply(batch(3, [...wide(100), ...block(plaintext), ...block(associated)], 2));
  f.runtime.manual = false;
  await f.runtime.runEffect(2);
  const sealed = f.calls.at(-1).payload;
  const first = flatten(sealed);
  assert.equal(first[0], 29); assert.equal(first.length, 1 + 12 + plaintext.length + 16);
  f.runtime.manual = true;
  f.apply(batch(3, [...wide(100), ...block(plaintext), ...block(associated)], 3));
  f.runtime.manual = false; await f.runtime.runEffect(3);
  const second = flatten(f.calls.at(-1).payload);
  assert.notDeepEqual(first.subarray(1, 13), second.subarray(1, 13));
  const iv = first.subarray(1, 13), ciphertext = first.subarray(13);
  const runDecrypt = async (body, context, id) => {
    f.runtime.manual = true; f.apply(batch(4, [...wide(100), ...block(iv), ...block(body), ...block(context)], id));
    await f.runtime.runEffect(id); return flatten(f.calls.at(-1).payload);
  };
  assert.deepEqual(await runDecrypt(ciphertext, associated, 4), Buffer.concat([Buffer.from([28]), Buffer.from(plaintext)]));
  assert.deepEqual(await runDecrypt(ciphertext, text("another project"), 5), Buffer.from([30, 4]));
  const damaged = Buffer.from(ciphertext); damaged[0] ^= 1;
  assert.deepEqual(await runDecrypt(damaged, associated, 6), Buffer.from([30, 4]));
  f.runtime.unmount();
});

await check("all digest algorithms match known SHA vectors", async () => {
  const f = fixture();
  for (const [hash, name] of [[1, "sha256"], [2, "sha384"], [3, "sha512"]]) {
    f.apply(batch(5, [hash, ...block(text("abc"))], hash));
    await f.runtime.runEffect(hash);
    assert.deepEqual(flatten(f.calls.at(-1).payload), Buffer.concat([Buffer.from([28]), createHash(name).update("abc").digest()]));
  }
});

await check("manual random bytes consume the specified SHA-256 stream including leftovers", async () => {
  const f = fixture();
  const wanted = Buffer.concat([0, 1, 2].map(counter => createHash("sha256").update(Buffer.concat([Buffer.from("roc-signals spec crypto\0"), Buffer.from(wide(counter))])).digest()));
  const got = [];
  for (const [id, count] of [[1, 5], [2, 41], [3, 30]]) {
    f.apply(batch(1, wide(count), id)); await f.runtime.runEffect(id);
    const answer = flatten(f.calls.at(-1).payload); assert.equal(answer[0], 28); got.push(answer.subarray(1));
  }
  assert.deepEqual(Buffer.concat(got), wanted.subarray(0, 76));
});

await check("production randomness chunks CSPRNG calls and never falls back", async () => {
  const lengths = [];
  const f = fixture({ window: { crypto: { getRandomValues(bytes) { lengths.push(bytes.length); bytes.fill(lengths.length); } } } });
  f.apply(batch(1, wide(65537))); f.runtime.manual = false; await f.runtime.runEffect(1);
  assert.deepEqual(lengths, [65536, 1]);
  const answer = flatten(f.calls.at(-1).payload); assert.equal(answer.length, 65538); assert.equal(answer.at(-1), 2);
  const absent = fixture({ window: { crypto: {} } });
  absent.apply(batch(1, wide(1))); absent.runtime.manual = false; await absent.runtime.runEffect(1);
  assert.deepEqual([...absent.calls.at(-1).payload], [30, 1]);
  const failed = fixture({ window: { crypto: { getRandomValues() { throw new Error("no entropy"); } } } });
  failed.apply(batch(1, wide(1))); failed.runtime.manual = false; await failed.runtime.runEffect(1);
  assert.deepEqual([...failed.calls.at(-1).payload], [30, 1]);
  const encrypting = fixture(); await keyOf(encrypting);
  encrypting.runtime.win = { crypto: { subtle: webcrypto.subtle, getRandomValues() { throw new Error("no entropy"); } } };
  encrypting.apply(batch(3, [...wide(100), ...block([]), ...block([])], 2));
  encrypting.runtime.manual = false; await encrypting.runtime.runEffect(2);
  assert.deepEqual([...encrypting.calls.at(-1).payload], [30, 1]);
});

await check("invalid parameters and deployment bounds refuse without browser work", async () => {
  const f = fixture({ maxCryptoBytes: 32, maxCryptoIterations: 100, window: { crypto: { subtle: {} } } });
  const cases = [
    [batch(1, wide(33)), [30, 2]],
    [batch(1, wide(2n ** 63n)), [30, 2]],
    [derive(1, text("password"), new Uint8Array(16), 101), [30, 2]],
    [derive(1, text("password"), new Uint8Array(15), 1), [30, 3]],
    [derive(1, text("password"), new Uint8Array(16), 0), [30, 3]],
    [derive(1, text("password that exceeds the combined input bound")), [30, 2]],
    [batch(5, [3, ...block(new Uint8Array(33))]), [30, 2]],
  ];
  for (const [bytes, expected] of cases) {
    f.apply(bytes); assert.equal(f.runtime.poisoned, null); await f.runtime.runEffect(1);
    assert.deepEqual([...f.calls.at(-1).payload], expected);
  }
  for (const value of [-1, 1.5, MAX_CRYPTO_BYTES + 1, NaN, Infinity]) assert.throws(() => fixture({ maxCryptoBytes: value }), /maxCryptoBytes/);
  for (const value of [0, 1.5, MAX_CRYPTO_ITERATIONS + 1, NaN, Infinity]) assert.throws(() => fixture({ maxCryptoIterations: value }), /maxCryptoIterations/);
});

await check("unknown and truncated crypto wire operands are classified contract faults", () => {
  for (const bytes of [batch(0, []), batch(2, [2, ...word(1), ...block([]), ...block(new Uint8Array(16))]), batch(5, [4, ...block([])]), batch(3, [...wide(999), ...block([]), ...block([])]), batch(3, [...wide(2n ** 63n), ...block([]), ...block([])])]) {
    const f = fixture(); f.apply(bytes); assert.equal(f.runtime.poisoned?.class, "contract");
  }
  const full = derive();
  for (let length = 7; length < full.length; length += 1) {
    const f = fixture(); f.apply(full.subarray(0, length)); assert.equal(f.runtime.poisoned?.class, "contract", `accepted truncation at ${length}`);
  }
});

await check("key slots refuse atomically and released tokens drop only their own object", async () => {
  const f = fixture(); await keyOf(f);
  f.room(0); f.apply(derive()); await f.runtime.runEffect(1);
  assert.equal(f.runtime.keys.size, 1); assert.equal(f.minted(), 1);
  assert.deepEqual([...f.calls.at(-1).payload], [30, 5]); assert.equal(f.calls.at(-1).keyed, false);
  f.runtime.keys.set(101n, {}); f.releases([100]); f.runtime.releaseKeys();
  assert.equal(f.runtime.keys.has(100n), false); assert.equal(f.runtime.keys.has(101n), true);
  f.runtime.unmount(); assert.equal(f.runtime.keys.size, 0);
});

await check("a request captures its key before its last handle is released", async () => {
  const f = fixture(); await keyOf(f);
  f.releases([100]);
  f.apply(batch(3, [...wide(100), ...block(text("kept for this operation")), ...block([])], 2));
  assert.equal(f.runtime.keys.size, 0);
  await f.runtime.runEffect(2);
  assert.equal(flatten(f.calls.at(-1).payload)[0], 29);
  assert.equal(f.runtime.poisoned, null);
});

await check("cancellation retains bounded browser slots until underlying promises settle", async () => {
  const resolvers = [];
  const f = fixture({ window: { crypto: { subtle: { importKey: async () => ({}), deriveKey: () => new Promise(resolve => resolvers.push(resolve)) } } } });
  for (let id = 1; id <= 32; id += 1) {
    f.apply(batch(2, [1, ...word(1), ...block([]), ...block(new Uint8Array(16))], id));
    const completed = f.runtime.runEffect(id); await settle(); f.runtime.cancel(id); assert.equal(await completed, true);
  }
  assert.equal(f.runtime.cryptoActive, 32); assert.equal(f.minted(), 0); assert.equal(f.calls.length, 0);
  f.apply(batch(1, wide(1), 33)); await f.runtime.runEffect(33);
  assert.deepEqual([...f.calls.at(-1).payload], [30, 5]);
  for (const resolve of resolvers) resolve({ opaque: "cancelled key" });
  await settle(); assert.equal(f.runtime.cryptoActive, 0); assert.equal(f.minted(), 0); assert.equal(f.calls.length, 1);
  f.runtime.unmount();
});

await check("a late key after unmount never stages a handle or delivers a result", async () => {
  let resolveKey;
  const f = fixture({ window: { crypto: { subtle: { importKey: async () => ({}), deriveKey: () => new Promise(resolve => { resolveKey = resolve; }) } } } });
  f.apply(derive()); const completed = f.runtime.runEffect(1); await settle();
  f.runtime.unmount(); assert.equal(await completed, true); assert.equal(f.runtime.cryptoActive, 1);
  resolveKey({ opaque: "late key" }); await settle();
  assert.equal(f.minted(), 0); assert.equal(f.calls.length, 0); assert.equal(f.runtime.cryptoActive, 0);
});

await check("combined byte ceilings accept exactly the native contract and refuse one byte more", async () => {
  const f = fixture({ maxCryptoBytes: 32, maxCryptoIterations: 100 });
  const run = async bytes => { f.apply(bytes); await f.runtime.runEffect(1); return flatten(f.calls.at(-1).payload); };
  // Password plus salt, rather than either independently, is the input cost.
  assert.deepEqual(await run(derive(1, new Uint8Array(16), new Uint8Array(16), 100)), Buffer.from([27]));
  assert.deepEqual(await run(derive(1, new Uint8Array(17), new Uint8Array(16), 100)), Buffer.from([30, 2]));
  const plaintext = new Uint8Array(8).fill(11), associated = new Uint8Array(8).fill(22);
  const sealed = await run(batch(3, [...wide(100), ...block(plaintext), ...block(associated)]));
  assert.equal(sealed[0], 29); assert.equal(sealed.length, 37);
  assert.deepEqual(await run(batch(3, [...wide(100), ...block(new Uint8Array(9)), ...block(associated)])), Buffer.from([30, 2]));
  assert.deepEqual(await run(batch(3, [...wide(100), ...block(plaintext), ...block(new Uint8Array(9))])), Buffer.from([30, 2]));
  const iv = sealed.subarray(1, 13), ciphertext = sealed.subarray(13);
  assert.deepEqual(await run(batch(4, [...wide(100), ...block(iv), ...block(ciphertext), ...block(associated)])), Buffer.concat([Buffer.from([28]), plaintext]));
  assert.deepEqual(await run(batch(4, [...wide(100), ...block(iv), ...block(ciphertext), ...block(new Uint8Array(9))])), Buffer.from([30, 2]));
  assert.deepEqual(await run(batch(4, [...wide(100), ...block(new Uint8Array(11)), ...block(ciphertext), ...block(associated)])), Buffer.from([30, 3]));
  assert.deepEqual(await run(batch(4, [...wide(100), ...block(iv), ...block(new Uint8Array(15)), ...block([])])), Buffer.from([30, 3]));
  assert.equal((await run(batch(5, [3, ...block(new Uint8Array(32))]))).length, 65);
  assert.deepEqual(await run(batch(5, [3, ...block(new Uint8Array(33))])), Buffer.from([30, 2]));
  assert.equal((await run(batch(1, wide(32)))).length, 33);
  assert.deepEqual(await run(batch(1, wide(33))), Buffer.from([30, 2]));
  f.runtime.unmount();
  const zero = fixture({ maxCryptoBytes: 0 });
  zero.apply(batch(5, [3, ...block([])])); await zero.runtime.runEffect(1);
  assert.equal(flatten(zero.calls.at(-1).payload).length, 65, "fixed SHA-512 output does not consume the bulk input limit");
});

await check("manual admission and refusal stay fixed until their explicit execution step", async () => {
  const f = fixture();
  for (let id = 1; id <= 33; id++) f.apply(batch(1, wide(1), id));
  await settle();
  assert.equal(f.runtime.cryptoActive, 32);
  assert.equal(f.runtime.pendingEffects().length, 33);
  assert.equal(f.calls.length, 0, "manual refusal waits for runEffect");
  await f.runtime.runEffect(1); assert.equal(f.runtime.cryptoActive, 31);
  assert.deepEqual([...f.calls.at(-1).payload].slice(0, 1), [28]);
  await f.runtime.runEffect(33);
  assert.deepEqual([...f.calls.at(-1).payload], [30, 5], "freeing a slot cannot turn an earlier refusal into admission");
  assert.equal(f.runtime.cryptoActive, 31);
  f.runtime.cancel(2); assert.equal(f.runtime.cryptoActive, 30);
  f.apply(batch(1, wide(1), 34)); assert.equal(f.runtime.cryptoActive, 31);
  assert.equal(f.runtime.pendingEffects().at(-1).id, 34);
  await f.runtime.runEffect(34); assert.equal(f.runtime.cryptoActive, 30);
  f.runtime.unmount(); assert.equal(f.runtime.cryptoActive, 0);
});

await check("64 retained keys remain usable while sequential derivations release executor slots", async () => {
  const f = fixture();
  for (let index = 0; index < 64; index++) {
    f.apply(derive()); await f.runtime.runEffect(1);
    assert.deepEqual([...f.calls.at(-1).payload], [27]);
    assert.equal(f.runtime.keys.size, index + 1);
    assert.equal(f.runtime.cryptoActive, 0);
  }
  f.apply(derive()); await f.runtime.runEffect(1);
  assert.deepEqual([...f.calls.at(-1).payload], [30, 5]);
  assert.equal(f.runtime.keys.size, 64);
  f.releases([100]); f.runtime.releaseKeys(); f.room(1);
  f.apply(derive()); await f.runtime.runEffect(1);
  assert.deepEqual([...f.calls.at(-1).payload], [27]);
  assert.equal(f.runtime.keys.size, 64); assert.equal(f.runtime.keys.has(100n), false);
  f.runtime.unmount(); assert.equal(f.runtime.keys.size, 0);
});

await check("zero random bytes succeeds without requiring a secure source", async () => {
  const f = fixture({ window: { crypto: {}, addEventListener() {}, removeEventListener() {}, navigator: {} } });
  f.apply(batch(1, wide(0), 1));
  await f.runtime.runEffect(1);
  assert.deepEqual(flatten(f.calls.at(-1).payload), Buffer.from([28]));
  f.runtime.unmount();
});

await check("full U64 key tokens stay distinct through staging, lookup, release and in-flight capture", async () => {
  const f = fixture();
  const first = 18446744073709551614n, second = first + 1n;
  f.nextToken(first);
  f.apply(derive(1)); await f.runtime.runEffect(1);
  f.apply(derive(3)); await f.runtime.runEffect(1);
  assert.equal(f.runtime.keys.size, 2);
  assert.equal(f.runtime.keys.has(first), true); assert.equal(f.runtime.keys.has(second), true);
  assert.notEqual(f.runtime.keys.get(first), f.runtime.keys.get(second));
  f.releases([first]);
  f.apply(batch(3, [...wide(first), ...block(text("first key")), ...block([])], 3));
  assert.equal(f.runtime.keys.has(first), false); assert.equal(f.runtime.keys.has(second), true);
  await f.runtime.runEffect(3); assert.equal(flatten(f.calls.at(-1).payload)[0], 29);
  f.releases([second]);
  f.apply(batch(3, [...wide(second), ...block(text("second key")), ...block([])], 4));
  assert.equal(f.runtime.keys.size, 0);
  await f.runtime.runEffect(4); assert.equal(flatten(f.calls.at(-1).payload)[0], 29);
  assert.equal(f.runtime.poisoned, null);
  f.runtime.unmount();
});


await check("manual entropy refuses U64 byte-count exhaustion without advancing its stream", async () => {
  const f = fixture();
  f.runtime.cryptoEntropy.used = (1n << 64n) - 1n;
  f.apply(batch(1, wide(1), 1)); await f.runtime.runEffect(1);
  assert.deepEqual(flatten(f.calls.at(-1).payload), Buffer.from([30, 6]));
  assert.equal(f.runtime.cryptoEntropy.counter, 0n);
  assert.equal(f.runtime.cryptoEntropy.used, (1n << 64n) - 1n);
  f.runtime.unmount();
});

await check("malformed password UTF-8 is a contract fault before work, including oversize and preflight requests", () => {
  const malformed = [[255], [128], [0xc0, 0x80], [0xe2, 0x82], [0xed, 0xa0, 0x80], [0xf4, 0x90, 0x80, 0x80], [...new Uint8Array(65535).fill(97), 0xc3]];
  for (const mode of ["normal", "preflight"]) {
    for (const maxCryptoBytes of [0, 131072]) {
      for (const password of malformed) {
        let calls = 0;
        const f = fixture({ manualEffects: false, maxCryptoBytes, window: { crypto: { subtle: { importKey() { calls++; }, deriveKey() { calls++; } } } } });
        f.apply(derive(1, Uint8Array.from(password)), mode);
        assert.equal(f.runtime.poisoned?.class, "contract");
        assert.match(f.runtime.poisoned.message, /crypto password.*UTF-8/);
        assert.equal(calls, 0);
        assert.equal(f.runtime.cryptoActive, 0);
      }
    }
  }
});

await check("empty, BOM and NUL passwords and UTF-8 spanning validation chunks keep their exact bytes", async () => {
  for (const password of [new Uint8Array(0), text("\uFEFFp\0é"), Uint8Array.from([...new Uint8Array(65535).fill(97), 0xc3, 0xa9])]) {
    const f = fixture();
    f.apply(derive(1, password));
    assert.equal(f.runtime.poisoned, null);
    assert.deepEqual(f.runtime.pendingEffects()[0].password, password);
    await f.runtime.runEffect(1);
    assert.deepEqual([...f.calls.at(-1).payload], [27]);
    f.runtime.unmount();
  }
});

await check("an earlier queued cancellation drops a completed key before any handle is minted", async () => {
  const f = fixture(), order = [];
  const deliver = f.runtime.deliver.bind(f.runtime);
  f.runtime.deliver = (node, handler, payload) => {
    if (node === 42) { order.push("cancel"); f.runtime.cancel(1); }
    else { order.push("key"); deliver(node, handler, payload); }
  };
  f.apply(derive());
  const completed = f.runtime.runEffect(1);
  // A waiting batch holds ordinary FIFO ingress while the browser finishes.
  f.runtime.busy = true;
  f.runtime.dispatch(42, 0, new Uint8Array(0));
  await completed;
  assert.equal(f.runtime.queue.length, 2);
  assert.equal(f.runtime.cryptoActive, 0);
  assert.equal(f.minted(), 0);
  f.runtime.busy = false;
  f.runtime.drainQueue();
  assert.deepEqual(order, ["cancel"]);
  assert.equal(f.minted(), 0);
  assert.equal(f.calls.length, 0);
  assert.equal(f.runtime.live.size, 0);
  f.runtime.unmount();
});

await check("a live completed key keeps its ordinary FIFO position until delivery", async () => {
  const f = fixture(), order = [];
  const deliver = f.runtime.deliver.bind(f.runtime);
  f.runtime.deliver = (node, handler, payload) => {
    if (node === 42) order.push("first");
    else { order.push("key"); deliver(node, handler, payload); }
  };
  f.apply(derive());
  const completed = f.runtime.runEffect(1);
  f.runtime.busy = true;
  f.runtime.dispatch(42, 0, new Uint8Array(0));
  await completed;
  assert.equal(f.runtime.queue.length, 2);
  assert.equal(f.minted(), 0);
  f.runtime.busy = false;
  f.runtime.drainQueue();
  assert.deepEqual(order, ["first", "key"]);
  assert.equal(f.minted(), 1);
  assert.equal(f.calls.length, 1);
  assert.equal(f.runtime.live.size, 0);
  f.runtime.unmount();
});
