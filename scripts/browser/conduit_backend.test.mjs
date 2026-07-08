import test from "node:test";
import assert from "node:assert/strict";

import {
  decodeHttpResponsePayload,
  encodeHttpRequestPayload,
} from "../../www/static/signals.mjs";
import {
  createConduitBackend,
  createConduitTaskHandler,
} from "../../www/static/conduit_backend.mjs";

const decoder = new TextDecoder();

function conduitRequest(handler, { method = "GET", uri, headers = [], body = [] }) {
  return handler({
    requestId: 1,
    name: "http:send:conduit-test",
    request: encodeHttpRequestPayload({ method, uri, headers, body }),
  });
}

function jsonResponse(payload) {
  const response = decodeHttpResponsePayload(payload);
  return { status: response.status, json: JSON.parse(decoder.decode(response.body)) };
}

const kimAuth = ["authorization", "Token jwt.conduit.kim"];

test("conduit backend ignores non-HTTP tasks and non-conduit URIs", () => {
  const handler = createConduitTaskHandler();
  assert.equal(handler({ name: "lookup", request: "roc" }), null);
  assert.equal(conduitRequest(handler, { uri: "/api/ops/dashboard" }), null);
});

test("GET /api/articles defaults to 20 most-recent articles with total count", () => {
  const handler = createConduitTaskHandler();
  const { status, json } = jsonResponse(conduitRequest(handler, { uri: "/api/articles" }));

  assert.equal(status, 200);
  assert.equal(json.articlesCount, 23);
  assert.equal(json.articles.length, 20);

  const dates = json.articles.map((article) => article.createdAt);
  assert.deepEqual(dates, [...dates].sort().reverse());

  const first = json.articles[0];
  assert.equal(typeof first.slug, "string");
  assert.equal(typeof first.title, "string");
  assert.equal(typeof first.description, "string");
  assert.ok(Array.isArray(first.tagList));
  assert.equal(typeof first.favorited, "boolean");
  assert.equal(typeof first.favoritesCount, "number");
  assert.equal(typeof first.author.username, "string");
  assert.equal(typeof first.author.following, "boolean");
  assert.equal(first.body, undefined);
});

test("GET /api/articles honors limit and offset while keeping the total", () => {
  const handler = createConduitTaskHandler();
  const { json } = jsonResponse(
    conduitRequest(handler, { uri: "/api/articles?limit=10&offset=20" }),
  );

  assert.equal(json.articlesCount, 23);
  assert.equal(json.articles.length, 3);
});

test("GET /api/articles filters by tag, author, and favorited", () => {
  const handler = createConduitTaskHandler();

  const tagged = jsonResponse(conduitRequest(handler, { uri: "/api/articles?tag=testing" })).json;
  assert.ok(tagged.articlesCount > 0);
  assert.ok(tagged.articles.every((article) => article.tagList.includes("testing")));

  const authored = jsonResponse(conduitRequest(handler, { uri: "/api/articles?author=max" })).json;
  assert.ok(authored.articlesCount > 0);
  assert.ok(authored.articles.every((article) => article.author.username === "max"));

  const favorited = jsonResponse(
    conduitRequest(handler, { uri: "/api/articles?favorited=kim" }),
  ).json;
  assert.ok(favorited.articlesCount > 0);
  assert.ok(favorited.articles.every((article) => article.favoritesCount >= 1));
});

test("GET /api/articles marks favorited flags for the authenticated viewer", () => {
  const handler = createConduitTaskHandler();
  const anonymous = jsonResponse(conduitRequest(handler, { uri: "/api/articles?favorited=kim" })).json;
  assert.ok(anonymous.articles.every((article) => article.favorited === false));

  const asKim = jsonResponse(
    conduitRequest(handler, { uri: "/api/articles?favorited=kim", headers: [kimAuth] }),
  ).json;
  assert.ok(asKim.articles.every((article) => article.favorited === true));
});

test("GET /api/articles/:slug returns the full article and 404s on unknown slugs", () => {
  const handler = createConduitTaskHandler();
  const listed = jsonResponse(conduitRequest(handler, { uri: "/api/articles?limit=1" })).json;
  const slug = listed.articles[0].slug;

  const single = jsonResponse(conduitRequest(handler, { uri: `/api/articles/${slug}` }));
  assert.equal(single.status, 200);
  assert.equal(single.json.article.slug, slug);
  assert.equal(typeof single.json.article.body, "string");
  assert.ok(single.json.article.body.includes("```"));

  const missing = jsonResponse(conduitRequest(handler, { uri: "/api/articles/not-a-real-slug" }));
  assert.equal(missing.status, 404);
  assert.deepEqual(missing.json, { errors: { body: ["not found"] } });
});

test("GET /api/articles/:slug/comments returns seeded comments", () => {
  const backend = createConduitBackend();
  const handler = createConduitTaskHandler({ backend });
  const slug = backend.articles[0].slug;

  const { status, json } = jsonResponse(
    conduitRequest(handler, { uri: `/api/articles/${slug}/comments` }),
  );
  assert.equal(status, 200);
  assert.equal(json.comments.length, 2);
  assert.equal(json.comments[0].author.username, "kim");
  assert.equal(typeof json.comments[0].id, "number");
});

test("GET /api/tags returns popular tags most-frequent first", () => {
  const handler = createConduitTaskHandler();
  const { json } = jsonResponse(conduitRequest(handler, { uri: "/api/tags" }));
  assert.ok(Array.isArray(json.tags));
  assert.ok(json.tags.includes("signals"));
  assert.equal(json.tags[0], "signals");
});

test("GET /api/articles/feed requires auth and returns followed authors only", () => {
  const handler = createConduitTaskHandler();

  const anonymous = jsonResponse(conduitRequest(handler, { uri: "/api/articles/feed" }));
  assert.equal(anonymous.status, 401);
  assert.deepEqual(anonymous.json, { errors: { body: ["unauthorized"] } });

  const asKim = jsonResponse(
    conduitRequest(handler, { uri: "/api/articles/feed", headers: [kimAuth] }),
  );
  assert.equal(asKim.status, 200);
  assert.ok(asKim.json.articlesCount > 0);
  assert.ok(asKim.json.articles.every((article) => article.author.username === "anna"));
});

test("GET /api/profiles/:username reflects the viewer's follow state", () => {
  const handler = createConduitTaskHandler();

  const anonymous = jsonResponse(conduitRequest(handler, { uri: "/api/profiles/anna" }));
  assert.equal(anonymous.status, 200);
  assert.equal(anonymous.json.profile.username, "anna");
  assert.equal(anonymous.json.profile.following, false);

  const asKim = jsonResponse(
    conduitRequest(handler, { uri: "/api/profiles/anna", headers: [kimAuth] }),
  );
  assert.equal(asKim.json.profile.following, true);

  const missing = jsonResponse(conduitRequest(handler, { uri: "/api/profiles/nobody" }));
  assert.equal(missing.status, 404);
});

test("POST /api/users/login returns the user envelope or a 422 validation envelope", () => {
  const handler = createConduitTaskHandler();

  const ok = jsonResponse(
    conduitRequest(handler, {
      method: "POST",
      uri: "/api/users/login",
      body: JSON.stringify({ user: { email: "kim@conduit.test", password: "secret-kim" } }),
    }),
  );
  assert.equal(ok.status, 200);
  assert.equal(ok.json.user.username, "kim");
  assert.equal(ok.json.user.token, "jwt.conduit.kim");

  const wrong = jsonResponse(
    conduitRequest(handler, {
      method: "POST",
      uri: "/api/users/login",
      body: JSON.stringify({ user: { email: "kim@conduit.test", password: "nope" } }),
    }),
  );
  assert.equal(wrong.status, 422);
  assert.deepEqual(wrong.json, { errors: { "email or password": ["is invalid"] } });

  const blank = jsonResponse(
    conduitRequest(handler, {
      method: "POST",
      uri: "/api/users/login",
      body: JSON.stringify({ user: { email: "kim@conduit.test" } }),
    }),
  );
  assert.equal(blank.status, 422);
  assert.deepEqual(blank.json, { errors: { password: ["can't be blank"] } });
});

test("GET /api/user returns the viewer or 401 without a valid token", () => {
  const handler = createConduitTaskHandler();

  const asKim = jsonResponse(conduitRequest(handler, { uri: "/api/user", headers: [kimAuth] }));
  assert.equal(asKim.status, 200);
  assert.equal(asKim.json.user.email, "kim@conduit.test");

  const anonymous = jsonResponse(conduitRequest(handler, { uri: "/api/user" }));
  assert.equal(anonymous.status, 401);

  const badToken = jsonResponse(
    conduitRequest(handler, {
      uri: "/api/user",
      headers: [["authorization", "Token jwt.conduit.forged"]],
    }),
  );
  assert.equal(badToken.status, 401);
});

test("latency injection resolves after the delay and honors aborts", async () => {
  const handler = createConduitTaskHandler({ latencyMs: 5 });
  const payload = await handler({
    requestId: 7,
    name: "http:send:conduit-test",
    request: encodeHttpRequestPayload({ method: "GET", uri: "/api/tags" }),
  });
  assert.equal(decodeHttpResponsePayload(payload).status, 200);

  const controller = new AbortController();
  const pending = handler({
    requestId: 8,
    name: "http:send:conduit-test",
    request: encodeHttpRequestPayload({ method: "GET", uri: "/api/tags" }),
    signal: controller.signal,
  });
  controller.abort();
  await assert.rejects(pending, /canceled/);
});
