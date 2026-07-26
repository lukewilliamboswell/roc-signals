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

test("POST and DELETE /api/articles/:slug/comments mutate authenticated comments", () => {
  const backend = createConduitBackend();
  const handler = createConduitTaskHandler({ backend });
  const slug = backend.articles[0].slug;

  const invalid = jsonResponse(
    conduitRequest(handler, {
      method: "POST",
      uri: `/api/articles/${slug}/comments`,
      headers: [kimAuth],
      body: JSON.stringify({ comment: { body: "" } }),
    }),
  );
  assert.equal(invalid.status, 422);
  assert.deepEqual(invalid.json.errors, { body: ["can't be blank"] });

  const anonymous = jsonResponse(
    conduitRequest(handler, {
      method: "POST",
      uri: `/api/articles/${slug}/comments`,
      body: JSON.stringify({ comment: { body: "Nope" } }),
    }),
  );
  assert.equal(anonymous.status, 401);

  const created = jsonResponse(
    conduitRequest(handler, {
      method: "POST",
      uri: `/api/articles/${slug}/comments`,
      headers: [kimAuth],
      body: JSON.stringify({ comment: { body: "Server-confirmed comment." } }),
    }),
  );
  assert.equal(created.status, 201);
  assert.equal(created.json.comment.body, "Server-confirmed comment.");
  assert.equal(created.json.comment.author.username, "kim");

  const listed = jsonResponse(conduitRequest(handler, { uri: `/api/articles/${slug}/comments`, headers: [kimAuth] }));
  assert.equal(listed.json.comments.at(-1).body, "Server-confirmed comment.");

  const forbidden = jsonResponse(
    conduitRequest(handler, {
      method: "DELETE",
      uri: `/api/articles/${slug}/comments/${created.json.comment.id}`,
      headers: [["authorization", "Token jwt.conduit.anna"]],
    }),
  );
  assert.equal(forbidden.status, 403);

  const deleted = jsonResponse(
    conduitRequest(handler, {
      method: "DELETE",
      uri: `/api/articles/${slug}/comments/${created.json.comment.id}`,
      headers: [kimAuth],
    }),
  );
  assert.equal(deleted.status, 200);
  assert.equal(deleted.json.comment.id, created.json.comment.id);

  const afterDelete = jsonResponse(conduitRequest(handler, { uri: `/api/articles/${slug}/comments`, headers: [kimAuth] }));
  assert.equal(afterDelete.json.comments.some((comment) => comment.id === created.json.comment.id), false);
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

test("POST and DELETE /api/profiles/:username/follow update profile and feed state", () => {
  const backend = createConduitBackend();
  const handler = createConduitTaskHandler({ backend });

  const unfollowed = jsonResponse(
    conduitRequest(handler, {
      method: "DELETE",
      uri: "/api/profiles/anna/follow",
      headers: [kimAuth],
    }),
  );
  assert.equal(unfollowed.status, 200);
  assert.equal(unfollowed.json.profile.following, false);

  const emptyFeed = jsonResponse(conduitRequest(handler, { uri: "/api/articles/feed", headers: [kimAuth] }));
  assert.equal(emptyFeed.status, 200);
  assert.equal(emptyFeed.json.articlesCount, 0);

  const followed = jsonResponse(
    conduitRequest(handler, {
      method: "POST",
      uri: "/api/profiles/anna/follow",
      headers: [kimAuth],
    }),
  );
  assert.equal(followed.status, 200);
  assert.equal(followed.json.profile.following, true);

  const restoredFeed = jsonResponse(conduitRequest(handler, { uri: "/api/articles/feed", headers: [kimAuth] }));
  assert.ok(restoredFeed.json.articlesCount > 0);
  assert.ok(restoredFeed.json.articles.every((article) => article.author.username === "anna"));

  const anonymous = jsonResponse(conduitRequest(handler, { method: "POST", uri: "/api/profiles/anna/follow" }));
  assert.equal(anonymous.status, 401);

  const missing = jsonResponse(
    conduitRequest(handler, {
      method: "POST",
      uri: "/api/profiles/nobody/follow",
      headers: [kimAuth],
    }),
  );
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

test("POST /api/users registers users and validates required fields", () => {
  const handler = createConduitTaskHandler();

  const blank = jsonResponse(
    conduitRequest(handler, {
      method: "POST",
      uri: "/api/users",
      body: JSON.stringify({ user: { username: "", email: "", password: "" } }),
    }),
  );
  assert.equal(blank.status, 422);
  assert.deepEqual(blank.json.errors, {
    username: ["can't be blank"],
    email: ["can't be blank"],
    password: ["can't be blank"],
  });

  const created = jsonResponse(
    conduitRequest(handler, {
      method: "POST",
      uri: "/api/users",
      body: JSON.stringify({ user: { username: "new-reader", email: "new@conduit.test", password: "secret" } }),
    }),
  );
  assert.equal(created.status, 200);
  assert.equal(created.json.user.username, "new-reader");
  assert.equal(created.json.user.token, "jwt.conduit.new-reader");

  const duplicate = jsonResponse(
    conduitRequest(handler, {
      method: "POST",
      uri: "/api/users",
      body: JSON.stringify({ user: { username: "new-reader", email: "again@conduit.test", password: "secret" } }),
    }),
  );
  assert.equal(duplicate.status, 422);
  assert.deepEqual(duplicate.json.errors, { username: ["has already been taken"] });
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

test("PUT /api/user updates the viewer and validates empty updates", () => {
  const handler = createConduitTaskHandler();

  const empty = jsonResponse(
    conduitRequest(handler, {
      method: "PUT",
      uri: "/api/user",
      headers: [kimAuth],
      body: JSON.stringify({ user: { image: "", bio: "", email: "", password: "" } }),
    }),
  );
  assert.equal(empty.status, 422);
  assert.deepEqual(empty.json.errors, { body: ["must update at least one field"] });

  const updated = jsonResponse(
    conduitRequest(handler, {
      method: "PUT",
      uri: "/api/user",
      headers: [kimAuth],
      body: JSON.stringify({ user: { image: "", bio: "Updated bio", email: "kim@new.test", password: "" } }),
    }),
  );
  assert.equal(updated.status, 200);
  assert.equal(updated.json.user.email, "kim@new.test");
  assert.equal(updated.json.user.bio, "Updated bio");

  const anonymous = jsonResponse(
    conduitRequest(handler, {
      method: "PUT",
      uri: "/api/user",
      body: JSON.stringify({ user: { bio: "Nope" } }),
    }),
  );
  assert.equal(anonymous.status, 401);
});

test("POST /api/articles creates an authenticated article and validates required fields", () => {
  const backend = createConduitBackend();
  const handler = createConduitTaskHandler({ backend });

  const created = jsonResponse(
    conduitRequest(handler, {
      method: "POST",
      uri: "/api/articles",
      headers: [kimAuth],
      body: JSON.stringify({
        article: {
          title: "Conduit write path",
          description: "Server-confirmed mutation",
          body: "Published only after the task resolves.",
          tagList: ["signals", "realworld"],
        },
      }),
    }),
  );
  assert.equal(created.status, 201);
  assert.equal(created.json.article.slug, "conduit-write-path");
  assert.equal(created.json.article.author.username, "kim");
  assert.deepEqual(created.json.article.tagList, ["signals", "realworld"]);

  const listed = jsonResponse(conduitRequest(handler, { uri: "/api/articles?author=kim" }));
  assert.equal(listed.json.articlesCount, 1);
  assert.equal(listed.json.articles[0].slug, "conduit-write-path");

  const invalid = jsonResponse(
    conduitRequest(handler, {
      method: "POST",
      uri: "/api/articles",
      headers: [kimAuth],
      body: JSON.stringify({ article: { title: "", description: "", body: "" } }),
    }),
  );
  assert.equal(invalid.status, 422);
  assert.deepEqual(invalid.json.errors, {
    title: ["can't be blank"],
    description: ["can't be blank"],
    body: ["can't be blank"],
  });

  const anonymous = jsonResponse(
    conduitRequest(handler, {
      method: "POST",
      uri: "/api/articles",
      body: JSON.stringify({ article: { title: "Nope", description: "Nope", body: "Nope" } }),
    }),
  );
  assert.equal(anonymous.status, 401);
});

test("PUT /api/articles/:slug updates only the author's article", () => {
  const backend = createConduitBackend();
  const handler = createConduitTaskHandler({ backend });

  const created = jsonResponse(
    conduitRequest(handler, {
      method: "POST",
      uri: "/api/articles",
      headers: [kimAuth],
      body: JSON.stringify({
        article: {
          title: "Mutable draft",
          description: "Original description",
          body: "Original body.",
          tagList: ["draft"],
        },
      }),
    }),
  );
  const slug = created.json.article.slug;

  const invalid = jsonResponse(
    conduitRequest(handler, {
      method: "PUT",
      uri: `/api/articles/${slug}`,
      headers: [kimAuth],
      body: JSON.stringify({ article: { title: "", description: "", body: "", tagList: [] } }),
    }),
  );
  assert.equal(invalid.status, 422);
  assert.deepEqual(invalid.json.errors, { body: ["must change at least one field"] });

  const anonymous = jsonResponse(
    conduitRequest(handler, {
      method: "PUT",
      uri: `/api/articles/${slug}`,
      body: JSON.stringify({ article: { title: "Nope" } }),
    }),
  );
  assert.equal(anonymous.status, 401);

  const forbidden = jsonResponse(
    conduitRequest(handler, {
      method: "PUT",
      uri: `/api/articles/${slug}`,
      headers: [["authorization", "Token jwt.conduit.anna"]],
      body: JSON.stringify({ article: { title: "Nope" } }),
    }),
  );
  assert.equal(forbidden.status, 403);

  const updated = jsonResponse(
    conduitRequest(handler, {
      method: "PUT",
      uri: `/api/articles/${slug}`,
      headers: [kimAuth],
      body: JSON.stringify({
        article: {
          title: "Edited conduit article",
          description: "Updated description",
          body: "",
          tagList: ["edited", "signals"],
        },
      }),
    }),
  );
  assert.equal(updated.status, 200);
  assert.equal(updated.json.article.slug, "edited-conduit-article");
  assert.equal(updated.json.article.title, "Edited conduit article");
  assert.equal(updated.json.article.description, "Updated description");
  assert.equal(updated.json.article.body, "Original body.");
  assert.deepEqual(updated.json.article.tagList, ["edited", "signals"]);

  const oldSlug = jsonResponse(conduitRequest(handler, { uri: `/api/articles/${slug}` }));
  assert.equal(oldSlug.status, 404);

  const newSlug = jsonResponse(conduitRequest(handler, { uri: "/api/articles/edited-conduit-article" }));
  assert.equal(newSlug.status, 200);
  assert.equal(newSlug.json.article.title, "Edited conduit article");
});

test("DELETE /api/articles/:slug removes only the author's article", () => {
  const backend = createConduitBackend();
  const handler = createConduitTaskHandler({ backend });

  const created = jsonResponse(
    conduitRequest(handler, {
      method: "POST",
      uri: "/api/articles",
      headers: [kimAuth],
      body: JSON.stringify({
        article: {
          title: "Temporary draft",
          description: "Delete me",
          body: "Short lived.",
          tagList: ["cleanup"],
        },
      }),
    }),
  );
  const slug = created.json.article.slug;

  const anonymous = jsonResponse(conduitRequest(handler, { method: "DELETE", uri: `/api/articles/${slug}` }));
  assert.equal(anonymous.status, 401);

  const forbidden = jsonResponse(
    conduitRequest(handler, {
      method: "DELETE",
      uri: `/api/articles/${slug}`,
      headers: [["authorization", "Token jwt.conduit.anna"]],
    }),
  );
  assert.equal(forbidden.status, 403);

  const deleted = jsonResponse(
    conduitRequest(handler, {
      method: "DELETE",
      uri: `/api/articles/${slug}`,
      headers: [kimAuth],
    }),
  );
  assert.equal(deleted.status, 200);
  assert.equal(deleted.json.article.slug, slug);

  const missing = jsonResponse(conduitRequest(handler, { uri: `/api/articles/${slug}` }));
  assert.equal(missing.status, 404);

  const listed = jsonResponse(conduitRequest(handler, { uri: "/api/articles?author=kim" }));
  assert.equal(listed.json.articlesCount, 0);
});

test("POST and DELETE /api/articles/:slug/favorite update counts and favorited lists", () => {
  const backend = createConduitBackend();
  const handler = createConduitTaskHandler({ backend });
  const slug = backend.articles[1].slug;

  const favorite = jsonResponse(
    conduitRequest(handler, {
      method: "POST",
      uri: `/api/articles/${slug}/favorite`,
      headers: [kimAuth],
    }),
  );
  assert.equal(favorite.status, 200);
  assert.equal(favorite.json.article.favorited, true);
  assert.equal(favorite.json.article.favoritesCount, 1);

  const favorited = jsonResponse(conduitRequest(handler, { uri: "/api/articles?favorited=kim", headers: [kimAuth] }));
  assert.ok(favorited.json.articles.some((article) => article.slug === slug));

  const unfavorite = jsonResponse(
    conduitRequest(handler, {
      method: "DELETE",
      uri: `/api/articles/${slug}/favorite`,
      headers: [kimAuth],
    }),
  );
  assert.equal(unfavorite.status, 200);
  assert.equal(unfavorite.json.article.favorited, false);
  assert.equal(unfavorite.json.article.favoritesCount, 0);

  const after = jsonResponse(conduitRequest(handler, { uri: "/api/articles?favorited=kim", headers: [kimAuth] }));
  assert.equal(after.json.articles.some((article) => article.slug === slug), false);

  const anonymous = jsonResponse(conduitRequest(handler, { method: "POST", uri: `/api/articles/${slug}/favorite` }));
  assert.equal(anonymous.status, 401);

  const missing = jsonResponse(
    conduitRequest(handler, {
      method: "POST",
      uri: "/api/articles/missing/favorite",
      headers: [kimAuth],
    }),
  );
  assert.equal(missing.status, 404);
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
