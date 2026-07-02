import test from "node:test";
import assert from "node:assert/strict";

import {
  createHttpTaskRouter,
  decodeHttpResponsePayload,
  encodeHttpRequestPayload,
  httpFetchTaskHandler,
  httpHeaderValue,
  httpJsonResponse,
  httpTaskError,
  httpTextResponse,
} from "../../www/static/signals.mjs";

const decoder = new TextDecoder();

function textBody(responsePayload) {
  return decoder.decode(decodeHttpResponsePayload(responsePayload).body);
}

test("HTTP task router passes through non-HTTP tasks", () => {
  const router = createHttpTaskRouter({
    "GET /api/widgets": () => httpTextResponse("ok"),
  });

  assert.equal(router({ name: "lookup", request: "roc" }), null);
});

test("HTTP task router decodes requests and encodes JSON responses", () => {
  const signal = new AbortController().signal;
  const router = createHttpTaskRouter({
    "POST /api/widgets": (req) => {
      assert.equal(req.method, "POST");
      assert.equal(req.uri, "/api/widgets");
      assert.equal(req.timeoutMs, 250);
      assert.equal(req.bodyText(), "hello");
      assert.equal(req.signal, signal);
      assert.equal(req.name, "http:send:widgets");
      assert.equal(req.requestId, 42);
      assert.equal(httpHeaderValue(req.headers, "x-mode"), "test");
      return httpJsonResponse({ status: "created" }, { status: 201, headers: [["x-result", "ok"]] });
    },
  });

  const responsePayload = router({
    requestId: 42,
    name: "http:send:widgets",
    signal,
    request: encodeHttpRequestPayload({
      method: "POST",
      uri: "/api/widgets",
      timeoutMs: 250,
      headers: [["x-mode", "test"]],
      body: "hello",
    }),
  });
  const response = decodeHttpResponsePayload(responsePayload);
  assert.equal(response.status, 201);
  assert.deepEqual(response.headers, [
    ["content-type", "application/json; charset=utf-8"],
    ["x-result", "ok"],
  ]);
  assert.equal(decoder.decode(response.body), '{"status":"created"}');
});

test("HTTP text response helper sets custom content type", () => {
  const response = decodeHttpResponsePayload(
    httpTextResponse("plain", {
      contentType: "text/custom",
      headers: [["x-extra", "1"]],
    }),
  );

  assert.equal(response.status, 200);
  assert.deepEqual(response.headers, [
    ["content-type", "text/custom"],
    ["x-extra", "1"],
  ]);
  assert.equal(decoder.decode(response.body), "plain");
});

test("HTTP task router rejects method mismatch on known URIs", () => {
  const router = createHttpTaskRouter({
    "GET /api/widgets": () => httpTextResponse("ok"),
  });

  assert.throws(
    () =>
      router({
        name: "http:send:widgets",
        request: encodeHttpRequestPayload({ method: "POST", uri: "/api/widgets" }),
      }),
    /roc-http-error-v1\nunsupported/,
  );
});

test("HTTP task router returns null for unknown URIs so fetch fallback can handle them", async () => {
  const router = createHttpTaskRouter({
    "GET /api/local": () => httpTextResponse("local"),
  });
  const args = {
    name: "http:send:remote",
    request: encodeHttpRequestPayload({ method: "GET", uri: "/api/remote" }),
    signal: new AbortController().signal,
  };

  assert.equal(router(args), null);
  const fallback = await (router(args) ??
    httpFetchTaskHandler({
      ...args,
      fetchImpl: async () => ({
        status: 200,
        headers: new Map([["content-type", "text/plain"]]),
        arrayBuffer: async () => new TextEncoder().encode("remote").buffer,
      }),
    }));

  assert.equal(textBody(fallback), "remote");
});

test("HTTP task router maps malformed request payloads to unsupported errors", () => {
  const router = createHttpTaskRouter({
    "GET /api/widgets": () => httpTextResponse("ok"),
  });

  assert.throws(
    () => router({ name: "http:send:widgets", request: "bad-payload" }),
    /roc-http-error-v1\nunsupported/,
  );
});

test("HTTP task router preserves pre-encoded HTTP task errors", () => {
  const router = createHttpTaskRouter({
    "GET /api/widgets": () => {
      throw httpTaskError("network", "offline");
    },
  });

  assert.throws(
    () =>
      router({
        name: "http:send:widgets",
        request: encodeHttpRequestPayload({ method: "GET", uri: "/api/widgets" }),
      }),
    /roc-http-error-v1\nnetwork/,
  );
});

test("HTTP task router wraps ordinary handler errors as unsupported", () => {
  const router = createHttpTaskRouter({
    "GET /api/widgets": () => {
      throw new Error("bad route");
    },
  });

  assert.throws(
    () =>
      router({
        name: "http:send:widgets",
        request: encodeHttpRequestPayload({ method: "GET", uri: "/api/widgets" }),
      }),
    /roc-http-error-v1\nunsupported/,
  );
});

test("HTTP task router supports async route handlers", async () => {
  const router = createHttpTaskRouter({
    "GET /api/widgets": async () => httpTextResponse("async ok"),
  });

  const response = await router({
    name: "http:send:widgets",
    request: encodeHttpRequestPayload({ method: "GET", uri: "/api/widgets" }),
  });

  assert.equal(textBody(response), "async ok");
});

test("HTTP task router maps async handler rejections", async () => {
  const router = createHttpTaskRouter({
    "GET /api/widgets": async () => {
      throw new Error("async bad route");
    },
  });

  await assert.rejects(
    () =>
      router({
        name: "http:send:widgets",
        request: encodeHttpRequestPayload({ method: "GET", uri: "/api/widgets" }),
      }),
    /roc-http-error-v1\nunsupported/,
  );
});
