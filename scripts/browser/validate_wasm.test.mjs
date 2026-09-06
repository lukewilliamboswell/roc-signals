import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

test("artifact validation accepts a module and rejects malformed generated code", async () => {
  const directory = await mkdtemp(join(tmpdir(), "signals-wasm-validation-"));
  try {
    const valid = join(directory, "valid.wasm");
    const invalid = join(directory, "invalid.wasm");
    const badStack = join(directory, "bad-stack.wasm");
    await writeFile(valid, new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0]));
    await writeFile(invalid, new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0, 10, 1, 1]));
    // A well-formed void function that leaves an i32 on its stack: parsing
    // succeeds, but WebAssembly's type validator must reject the function.
    await writeFile(badStack, new Uint8Array([
      0, 97, 115, 109, 1, 0, 0, 0,
      1, 4, 1, 96, 0, 0,
      3, 2, 1, 0,
      10, 6, 1, 4, 0, 65, 0, 11,
    ]));
    const run = (...paths) => spawnSync(process.execPath, [new URL("./validate_wasm.mjs", import.meta.url).pathname, ...paths], { encoding: "utf8" });
    assert.equal(run(valid).status, 0);
    const rejected = run(valid, invalid);
    assert.equal(rejected.status, 1);
    assert.match(rejected.stderr, /Invalid Wasm artifact/);
    assert.ok(rejected.stderr.includes(invalid));
    const stackRejected = run(badStack);
    assert.equal(stackRejected.status, 1);
    assert.ok(stackRejected.stderr.includes(badStack));
    assert.equal(run().status, 2);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
