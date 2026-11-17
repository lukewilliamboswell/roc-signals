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
const declarations = Uint8Array.from([...section(2, word(0)), ...section(5, word(0)), ...section(6, word(0)), ...section(10, [110, 1]), ...section(11, word(0)), ...protocolFixtureSection]);
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
    runtime, calls, x, minted: () => minted, room: count => { room = count; },
    releases: tokens => { released = tokens.map(BigInt); },
    apply(bytes) { new Uint8Array(memory.buffer).set(bytes); commandLength = bytes.length; quiet(() => runtime.guard(() => runtime.apply())); },
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
  return fixtureValue.runtime.keys.get(100);
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
    [batch(5, [3, ...block([])]), [30, 2]],
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
  f.runtime.keys.set(101, {}); f.releases([100]); f.runtime.releaseKeys();
  assert.equal(f.runtime.keys.has(100), false); assert.equal(f.runtime.keys.has(101), true);
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
