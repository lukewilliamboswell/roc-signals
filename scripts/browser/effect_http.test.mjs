import test from "node:test";
import assert from "node:assert/strict";
import { createHttpEffectImports, fetchHttpEffect, HttpEffectLimits } from "../../www/static/effect_http.mjs";
import { createPublicExampleFetch } from "../../www/static/example_tasks.mjs";

const request = () => ({ method: "GET", uri: "/example", headers: [], body: new Uint8Array(), timeoutMs: null });

test("flight example uses HTTP responses and forwards unrelated requests", async () => {
  const forwarded = [];
  const fetchImpl = createPublicExampleFetch(async (...args) => {
    forwarded.push(args);
    return new Response("external");
  });
  const uri = "/api/flights/MEL-SYD|2026-09-01|any|any|any";
  const first = await fetchImpl(uri);
  const second = await fetchImpl(uri);
  assert.equal(first.status, 200);
  assert.equal(await first.text(), await second.text(), "the timetable is deterministic");
  assert.equal((await fetchImpl("/api/flights/MEL-MEL|2026-09-01")).status, 422);
  assert.equal((await fetchImpl(uri, { method: "POST" })).status, 405);
  assert.equal(await (await fetchImpl("/elsewhere")).text(), "external");
  assert.deepEqual(forwarded, [["/elsewhere", {}]]);
});

test("equal HTTP occurrences execute independently and preserve HTTP failures as responses", async () => {
  let calls = 0;
  const fetchImpl = async () => { calls++; return new Response("missing", { status: 404 }); };
  const values = await Promise.all([fetchHttpEffect(request(), { fetchImpl }), fetchHttpEffect(request(), { fetchImpl })]);
  assert.equal(calls, 2);
  assert.equal(values[0].status, 404);
  assert.equal(new TextDecoder().decode(values[1].body), "missing");
});

test("onboarding example exposes conflict and successful retry as HTTP responses", async () => {
  const fetchImpl = createPublicExampleFetch(() => { throw new Error("unexpected external request"); });
  assert.equal((await fetchImpl("/api/onboarding/submit-1")).status, 409);
  const retry = await fetchImpl("/api/onboarding/submit-2");
  assert.equal(retry.status, 200);
  assert.equal(await retry.text(), "acme-42");
  assert.equal((await fetchImpl("/api/onboarding/submit-invalid")).status, 400);
  assert.equal((await fetchImpl("/api/onboarding/submit-2", { method: "DELETE" })).status, 405);
});

test("status HTTP scripts advance independently and reset for each mount", async () => {
  const external = () => { throw new Error("unexpected external request"); };
  const fetchImpl = createPublicExampleFetch(external);
  const read = async (service) => (await fetchImpl(`/api/status/${service}`)).text();
  assert.equal(await read("api"), "operational|99.98");
  assert.equal(await read("api"), "degraded|97.40");
  assert.equal(await read("web"), "operational|99.99");
  assert.equal(await read("incidents"), "");
  assert.match(await read("incidents"), /^inc-42~/);
  assert.equal(await read("api"), "degraded|96.80");
  await assert.rejects(read("api"), /check timed out after 5s/);
  assert.equal(await read("api"), "degraded|98.60");
  assert.equal((await fetchImpl("/api/status/unknown")).status, 404);
  assert.equal((await fetchImpl("/api/status/api", { method: "POST" })).status, 405);
  const fresh = createPublicExampleFetch(external);
  assert.equal(await (await fresh("/api/status/api")).text(), "operational|99.98");
});

test("package HTTP endpoints preserve independent panels and decoded search text", async () => {
  const fetchImpl = createPublicExampleFetch(() => { throw new Error("unexpected external request"); });
  const read = async (path) => (await fetchImpl(`/api/packages/${path}`)).text();
  assert.equal(await read("search?q=JSON%20codec"), "roc-json|JSON codec for Roc");
  assert.equal(await read("detail?q=roc-json"), "roc-json|JSON codec for Roc|Apache-2.0|18422");
  assert.match(await read("versions?q=roc-json"), /^1.2.0\|/);
  assert.equal(await read("deps?q=roc-parser"), "");
  await assert.rejects(read("detail?q=missing"), /overview service unavailable/);
  assert.equal(await read("versions?q=missing"), "");
  assert.equal(await read("deps?q=missing"), "");
  await assert.rejects(read("search?q=offline"), /registry unreachable/);
  assert.equal((await fetchImpl("/api/packages/unknown")).status, 404);
  assert.equal((await fetchImpl("/api/packages/search", { method: "POST" })).status, 405);
});

test("note sync uses POST bytes and an independent per-mount retry sequence", async () => {
  const external = () => { throw new Error("unexpected external request"); };
  const fetchImpl = createPublicExampleFetch(external);
  const send = (token) => fetchImpl("/api/notes/sync", { method: "POST", body: new TextEncoder().encode(token) });
  assert.equal((await fetchImpl("/api/notes/sync")).status, 405);
  assert.equal(await (await send("note-1#1")).text(), "note-1#1");
  assert.equal(await (await send("note-2#1")).text(), "note-2#1");
  assert.equal((await send("note-3#1")).status, 503);
  assert.equal(await (await send("note-3#2")).text(), "note-3#2");
  const fresh = createPublicExampleFetch(external);
  assert.equal((await fresh("/api/notes/sync", { method: "POST", body: "note-1#1" })).status, 200);
});

test("inbox HTTP polls retain server state and sends echo client identity", async () => {
  const fetchImpl = createPublicExampleFetch(() => { throw new Error("unexpected external request"); });
  const post = (uri, body) => fetchImpl(uri, { method: "POST", body });
  assert.match(await (await post("/api/inbox", "poll")).text(), /Login loop on mobile\|new/);
  assert.match(await (await post("/api/inbox", "read:c2")).text(), /Login loop on mobile\|read/);
  assert.equal(await (await post("/api/inbox/send", "client-1|c1|Hello")).text(), "client-1");
  assert.equal((await post("/api/inbox/send", "client-2|c1|Second")).status, 503);
  const snapshot = await (await post("/api/inbox", "poll")).text();
  assert.match(snapshot, /agent\|Hello\|read\|client-1/);
  assert.doesNotMatch(snapshot, /client-2/);
  assert.equal((await post("/api/inbox", "poll")).status, 503);
  assert.equal((await post("/api/inbox", "poll")).status, 200);
  assert.equal((await post("/api/inbox", "invalid")).status, 400);
});

test("response limit cancels the stream before retaining an oversized body", async () => {
  let canceled = false;
  const body = new ReadableStream({
    start(controller) { controller.enqueue(new Uint8Array(HttpEffectLimits.bodyBytes + 1)); },
    cancel() { canceled = true; },
  });
  await assert.rejects(fetchHttpEffect(request(), { fetchImpl: async () => new Response(body) }), { kind: "TooLarge" });
  assert.equal(canceled, true);
});

test("invalid request limits refuse before fetch", async () => {
  let called = false;
  await assert.rejects(fetchHttpEffect({ ...request(), timeoutMs: 2147483648 }, { fetchImpl: async () => { called = true; } }), { kind: "InvalidRequest" });
  assert.equal(called, false);
});

test("timeout aborts the request and reports a typed timeout", async () => {
  const fetchImpl = (_uri, { signal }) => new Promise((_resolve, reject) => {
    signal.addEventListener("abort", () => reject(new Error("aborted")), { once: true });
  });
  await assert.rejects(fetchHttpEffect({ ...request(), timeoutMs: 1 }, { fetchImpl }), { kind: "Timeout" });
});

test("network rejection stays a typed failure", async () => {
  await assert.rejects(fetchHttpEffect(request(), { fetchImpl: async () => { throw new Error("offline"); } }), { kind: "Network", message: "offline" });
});

test("poisoned suspended HTTP never allocates a response in the host", async () => {
  // Capture the import body without needing JSPI in this primitive-only suite.
  // The linked Wasm tests separately exercise the actual suspension wrapper.
  const original = Object.getOwnPropertyDescriptor(WebAssembly, "Suspending");
  let execute;
  Object.defineProperty(WebAssembly, "Suspending", {
    configurable: true,
    value: function (body) { execute = body; },
  });
  try {
    for (const outcome of ["success", "failure"]) {
      let poisoned = false;
      let complete;
      let allocations = 0;
      const memory = new WebAssembly.Memory({ initial: 1 });
      new Uint8Array(memory.buffer).set(new TextEncoder().encode("GET/example"), 16);
      createHttpEffectImports(() => ({
        memory,
        roc_alloc() { allocations++; throw new Error("unexpected host re-entry"); },
      }), {
        isPoisoned: () => poisoned,
        fetchImpl: () => new Promise((resolve, reject) => {
          complete = () => outcome === "success" ? resolve(new Response("late")) : reject(new Error("late failure"));
        }),
      });
      const pending = execute(16, 3, 19, 8, 0xffffffffffffffffn, 0, 0, 0, 0, 64);
      poisoned = true;
      complete();
      await assert.rejects(pending, /cannot resume a poisoned Signals instance/);
      assert.equal(allocations, 0, outcome);
      assert.equal(new DataView(memory.buffer).getUint32(64, true), 0);
    }
  } finally {
    if (original) Object.defineProperty(WebAssembly, "Suspending", original);
    else delete WebAssembly.Suspending;
  }
});
