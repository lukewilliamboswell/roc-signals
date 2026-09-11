import test from "node:test";
import assert from "node:assert/strict";
import { createHttpEffectImports, HttpEffectLimits } from "../../www/static/effect_http.mjs";

// Exercise the real import body without requiring JSPI in this primitive suite.
// The linked Roc/Wasm contracts separately test suspension and effect lifetime.
function captureImport(host, options) {
  const original = Object.getOwnPropertyDescriptor(WebAssembly, "Suspending");
  Object.defineProperty(WebAssembly, "Suspending", {
    configurable: true,
    value: function (body) { return body; },
  });
  try {
    return createHttpEffectImports(() => host, options).roc_ui_http_send;
  } finally {
    if (original) Object.defineProperty(WebAssembly, "Suspending", original);
    else delete WebAssembly.Suspending;
  }
}

function requestFrame({ method = "PATCH", uri = "/api/widgets/λ", headers = [["x-mode", "first"], ["x-mode", "second"]], body = new Uint8Array([0, 82, 255]) } = {}) {
  const memory = new WebAssembly.Memory({ initial: 1 });
  let next = 512;
  const bytes = value => {
    const ptr = next;
    new Uint8Array(memory.buffer, ptr, value.length).set(value);
    next += value.length;
    return [ptr, value.length];
  };
  const text = value => bytes(new TextEncoder().encode(value));
  const [methodPtr, methodLen] = text(method);
  const [uriPtr, uriLen] = text(uri);
  const view = new DataView(memory.buffer);
  headers.forEach(([name, value], index) => {
    const fields = [...text(name), ...text(value)];
    fields.forEach((field, word) => view.setUint32(256 + index * 16 + word * 4, field, true));
  });
  const [bodyPtr, bodyLen] = bytes(body);
  return { memory, args: [methodPtr, methodLen, uriPtr, uriLen, 500n, 256, headers.length, bodyPtr, bodyLen, 64] };
}

function readResponse(memory, ptr) {
  const length = new DataView(memory.buffer).getUint32(64, true);
  const view = new DataView(memory.buffer, ptr, length);
  let offset = 0;
  const word = () => { const result = view.getUint32(offset, true); offset += 4; return result; };
  const bytes = () => {
    const length = word();
    const result = new Uint8Array(memory.buffer, ptr + offset, length).slice();
    offset += length;
    return result;
  };
  const text = () => new TextDecoder("utf-8", { fatal: true }).decode(bytes());
  const kind = word();
  let result;
  if (kind === 0) {
    const status = word();
    const count = word();
    const headers = Array.from({ length: count }, () => [text(), text()]);
    result = { kind, status, headers, body: bytes() };
  } else {
    result = { kind, detail: text() };
  }
  assert.equal(offset, length, "the response must be exactly one complete frame");
  return result;
}

test("HTTP import snapshots request fields and preserves binary responses across memory growth", async () => {
  const { memory, args } = requestFrame();
  let complete;
  let captured;
  const before = memory.buffer;
  let allocations = 0;
  const execute = captureImport({
    memory,
    roc_alloc(length, alignment) {
      allocations++;
      assert.equal(alignment, 1);
      assert.ok(length > 0);
      memory.grow(1);
      return 4096;
    },
  }, {
    fetchImpl: (uri, options) => {
      captured = { uri, ...options };
      return new Promise(resolve => { complete = resolve; });
    },
  });
  const pending = execute(...args);
  // The suspended call may not retain borrowed request memory.
  new Uint8Array(memory.buffer, 256, 2048).fill(0);
  assert.equal(captured.uri, "/api/widgets/λ");
  assert.equal(captured.method, "PATCH");
  assert.deepEqual(captured.headers, [["x-mode", "first"], ["x-mode", "second"]]);
  assert.deepEqual(captured.body, new Uint8Array([0, 82, 255]));
  assert.ok(captured.signal instanceof AbortSignal);
  assert.equal(captured.signal.aborted, false);
  const headers = [["content-type", "application/octet-stream"], ["x-reply", "one"], ["x-reply", "two"]];
  complete({
    status: 202,
    headers: { entries: () => headers[Symbol.iterator]() },
    body: new ReadableStream({
      start(controller) {
        controller.enqueue(new Uint8Array([1, 2]));
        controller.enqueue(new Uint8Array([255, 0]));
        controller.close();
      },
    }),
  });
  const ptr = await pending;
  assert.equal(allocations, 1);
  assert.notEqual(memory.buffer, before);
  assert.deepEqual(readResponse(memory, ptr), { kind: 0, status: 202, headers, body: new Uint8Array([1, 2, 255, 0]) });
});

test("HTTP import rejects oversized request declarations before reading their buffers", async () => {
  for (const [field, value] of [[1, 65537], [3, 65537], [6, HttpEffectLimits.headers + 1], [8, HttpEffectLimits.bodyBytes + 1]]) {
    const { memory, args } = requestFrame();
    args[field] = value;
    let calls = 0;
    const execute = captureImport({ memory, roc_alloc: () => 4096 }, {
      fetchImpl: () => { calls++; throw new Error("must not fetch"); },
    });
    const response = readResponse(memory, await execute(...args));
    assert.equal(response.kind, 4);
    assert.match(response.detail, /exceeds browser limits/);
    assert.equal(calls, 0);
  }
});

test("HTTP import refuses malformed borrowed memory without publishing a result", async () => {
  for (const malformed of ["utf8", "pointer"]) {
    const { memory, args } = requestFrame();
    if (malformed === "utf8") new Uint8Array(memory.buffer)[args[0]] = 255;
    else args[0] = memory.buffer.byteLength;
    let allocations = 0;
    let calls = 0;
    const execute = captureImport({ memory, roc_alloc: () => { allocations++; return 4096; } }, {
      fetchImpl: () => { calls++; throw new Error("must not fetch"); },
    });
    await assert.rejects(execute(...args), malformed === "utf8" ? TypeError : RangeError);
    assert.equal(allocations, 0);
    assert.equal(calls, 0);
    assert.equal(new DataView(memory.buffer).getUint32(64, true), 0);
  }
});

test("HTTP import encodes synchronous and asynchronous network rejection identically", async () => {
  for (const fetchImpl of [
    () => { throw new Error("offline λ"); },
    async () => { throw new Error("offline λ"); },
  ]) {
    const { memory, args } = requestFrame();
    const execute = captureImport({ memory, roc_alloc: () => 4096 }, { fetchImpl });
    assert.deepEqual(readResponse(memory, await execute(...args)), { kind: 2, detail: "offline λ" });
  }
});

test("poisoned suspended HTTP effects never allocate or publish late results", async () => {
  for (const outcome of ["response", "rejection"]) {
    const { memory, args } = requestFrame();
    let poisoned = false;
    let resolve;
    let reject;
    let allocations = 0;
    const execute = captureImport({
      memory,
      roc_alloc: () => { allocations++; return 4096; },
    }, {
      isPoisoned: () => poisoned,
      fetchImpl: () => new Promise((yes, no) => { resolve = yes; reject = no; }),
    });
    const pending = execute(...args);
    poisoned = true;
    const before = new Uint8Array(memory.buffer).slice();
    if (outcome === "response") resolve(new Response("late result"));
    else reject(new Error("late failure"));
    await assert.rejects(pending, /cannot resume a poisoned Signals instance/);
    assert.equal(allocations, 0);
    assert.deepEqual(new Uint8Array(memory.buffer), before);
  }
});

test("HTTP import preserves an HTTP error status as a response, not a transport failure", async () => {
  const { memory, args } = requestFrame({ headers: [], body: new Uint8Array() });
  const execute = captureImport({ memory, roc_alloc: () => 4096 }, {
    fetchImpl: async (_uri, options) => {
      assert.equal(options.body, undefined);
      return new Response("missing λ", { status: 404, headers: { "content-type": "text/custom", "x-result": "missing" } });
    },
  });
  assert.deepEqual(readResponse(memory, await execute(...args)), {
    kind: 0, status: 404,
    headers: [["content-type", "text/custom"], ["x-result", "missing"]],
    body: new TextEncoder().encode("missing λ"),
  });
});
