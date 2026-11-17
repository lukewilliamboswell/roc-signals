// Production CSPRNG and SubtleCrypto against independent Node vectors. Raw
// wire requests and fake staging exports isolate the runtime from the Roc
// producer; paired app specs separately drive real host handles.
import assert from "node:assert/strict";
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { createCipheriv, createHash, pbkdf2Sync } from "node:crypto";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";
import { protocolFixtureSection } from "./protocol-fixture.mjs";

const options = parseArgs(process.argv.slice(2), [], ["runtime"]);
const files = runtimeFiles(options.runtime);
const server = http.createServer((request, response) => {
  const route = new URL(request.url, "http://x").pathname;
  const file = files[path.basename(route)];
  response.writeHead(200, { "content-type": file ? "text/javascript" : "text/html" });
  response.end(file ? fs.readFileSync(file) : "<!doctype html><meta charset=utf-8><title>WebCrypto contracts</title>");
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
let browser;
try {
  browser = await launch({ executablePath: options.chrome });
  const page = await browser.newPage();
  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  const password = "password\u0000with UTF-8 é";
  const salt = Array.from({ length: 16 }, (_, index) => index);
  const iv = Array.from({ length: 12 }, (_, index) => 11 - index);
  const plain = [0, 255, 128, 10, 0, 3, 4], associated = [41, 0, 255, 22];
  const vectors = ["sha256", "sha512"].map(hash => {
    const key = pbkdf2Sync(password, Buffer.from(salt), 50, 32, hash);
    const cipher = createCipheriv("aes-256-gcm", key, Buffer.from(iv)); cipher.setAAD(Buffer.from(associated));
    return [...Buffer.concat([cipher.update(Buffer.from(plain)), cipher.final(), cipher.getAuthTag()])];
  });
  const result = await page.evaluate(async ({ fixtureSection, password, salt, iv, plain, associated, vectors }) => {
    const { RocEngineRuntime, PROTOCOL_VERSION, readDeclarations } = await import("/runtime.mjs");
    const word = value => [value & 255, value >>> 8 & 255, value >>> 16 & 255, value >>> 24];
    const wide = value => { const bytes = new Uint8Array(8); new DataView(bytes.buffer).setBigUint64(0, BigInt(value), true); return [...bytes]; };
    const block = bytes => [...word(bytes.length), ...bytes];
    const section = (tag, bytes) => [tag, ...word(bytes.length), ...bytes];
    const declarations = Uint8Array.from([...section(2, word(0)), ...section(5, word(0)), ...section(6, word(0)), ...section(10, [110, 1]), ...section(11, word(0)), ...fixtureSection]);
    const memory = new WebAssembly.Memory({ initial: 3 });
    const keyBase = 18446744073709551614n;
    let length = 0, staged = 0, token = keyBase, release = [], keyStages = 0;
    const calls = [];
    const x = {
      memory, protocol_version: () => PROTOCOL_VERSION, dbg_ptr: () => 0, dbg_len: () => 0,
      boot_keys() { new Uint8Array(memory.buffer).set(declarations); length = declarations.length; },
      cmd_ptr: () => 0, cmd_len: () => length,
      payload_reserve(count) { staged = count; memory.grow(1); return 65536; },
      event(node, id) { calls.push({ node, id, payload: [...new Uint8Array(memory.buffer, 65536, staged)], key: false }); length = 0; return 0; },
      event_key(node, id) { calls.push({ node, id, payload: [...new Uint8Array(memory.buffer, 65536, staged)], key: true }); length = 0; return 0; },
      keys_stage() { memory.grow(1); new DataView(memory.buffer).setBigUint64(32768, token++, true); keyStages++; return 1; },
      keys_tokens: () => 32768,
      keys_released() { const count = release.length; release.forEach((value, index) => new DataView(memory.buffer).setBigUint64(32768 + index * 8, BigInt(value), true)); release = []; return count; },
      files_released: () => 0, work_len: () => 0, metric: () => 0n, fault: () => 0, drop() {},
    };
    const root = document.createElement("div"); document.body.append(root);
    const runtime = new RocEngineRuntime(x, root, { manualEffects: true });
    runtime.protocol = readDeclarations(x).bindings;
    let next = 1;
    const run = async (operation, operands, production = false) => {
      const id = next++;
      const batch = Uint8Array.from([0, 13, ...word(id), 21, operation, ...operands]);
      runtime.manual = true; new Uint8Array(memory.buffer).set(batch); length = batch.length;
      runtime.guard(() => runtime.apply());
      if (runtime.poisoned) throw new Error(runtime.poisoned.message);
      runtime.manual = !production;
      await runtime.runEffect(id);
      return calls.at(-1).payload;
    };
    const checks = [], check = (name, condition) => { if (!condition) throw new Error(name); checks.push(name); };
    for (const [place, hash] of [1, 3].entries()) {
      const answer = await run(2, [hash, ...word(50), ...block(new TextEncoder().encode(password)), ...block(salt)], true);
      const keyToken = keyBase + BigInt(place), key = runtime.keys.get(keyToken);
      check(`PBKDF2 hash ${hash} stages exactly one opaque key`, answer.length === 1 && answer[0] === 27 && keyStages === place + 1);
      check(`PBKDF2 hash ${hash} creates non-extractable AES-256-GCM`, key instanceof CryptoKey && !key.extractable && key.algorithm.name === "AES-GCM" && key.algorithm.length === 256 && key.usages.join(",") === "encrypt,decrypt");
      let denied = false;
      try { await crypto.subtle.exportKey("raw", key); } catch { denied = true; }
      check(`PBKDF2 hash ${hash} cannot export raw key bytes`, denied);
      const opened = await run(4, [...wide(keyToken), ...block(iv), ...block(vectors[place]), ...block(associated)], true);
      check(`PBKDF2 hash ${hash} decrypts the independent AES vector`, JSON.stringify(opened) === JSON.stringify([28, ...plain]));
    }
    const sealed = await run(3, [...wide(keyBase), ...block(plain), ...block(associated)], true);
    const again = await run(3, [...wide(keyBase), ...block(plain), ...block(associated)], true);
    check("encryption generates fresh 96-bit IVs", sealed[0] === 29 && sealed.length === 29 + plain.length && JSON.stringify(sealed.slice(1, 13)) !== JSON.stringify(again.slice(1, 13)));
    const opened = await run(4, [...wide(keyBase), ...block(sealed.slice(1, 13)), ...block(sealed.slice(13)), ...block(associated)], true);
    check("production AES-GCM preserves all binary bytes", JSON.stringify(opened) === JSON.stringify([28, ...plain]));
    const damaged = sealed.slice(13); damaged[0] ^= 1;
    const bad = await run(4, [...wide(keyBase), ...block(sealed.slice(1, 13)), ...block(damaged), ...block(associated)], true);
    const wrongContext = await run(4, [...wide(keyBase), ...block(sealed.slice(1, 13)), ...block(sealed.slice(13)), ...block([99])], true);
    const wrongKey = await run(4, [...wide(keyBase + 1n), ...block(sealed.slice(1, 13)), ...block(sealed.slice(13)), ...block(associated)], true);
    check("damaged data, associated data and a wrong key are NotAuthentic", [bad, wrongContext, wrongKey].every(answer => answer.length === 2 && answer[0] === 30 && answer[1] === 4));
    const random = await run(1, wide(65537), true);
    check("production randomness exceeds one getRandomValues call safely", random[0] === 28 && random.length === 65538);
    const digests = [];
    for (const hash of [1, 2, 3]) digests.push(await run(5, [hash, ...block([97, 98, 99])], true));
    // A request can use a key whose final Roc reference went in this batch.
    release = [keyBase];
    const kept = await run(3, [...wide(keyBase), ...block(plain), ...block([])], true);
    check("a performed request retains its key after the handle release", kept[0] === 29 && !runtime.keys.has(keyBase) && runtime.keys.has(keyBase + 1n));
    runtime.unmount(); root.remove();
    check("unmount drops every remaining browser key", runtime.keys.size === 0);
    return { checks, digests };
  }, { fixtureSection: [...protocolFixtureSection], password, salt, iv, plain, associated, vectors });
  for (const name of result.checks) console.log(`ok   ${name}`);
  for (const [index, name] of ["sha256", "sha384", "sha512"].entries()) {
    assert.deepEqual(result.digests[index], [28, ...createHash(name).update("abc").digest()]);
    console.log(`ok   ${name} matches the independent known vector`);
  }
} finally {
  if (browser) await browser.close();
  await new Promise(resolve => server.close(resolve));
}
