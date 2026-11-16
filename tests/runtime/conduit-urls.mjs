// The example's real service reads encoded names once and refuses dot usernames.
import assert from "node:assert/strict";
import createBackend from "../../examples/conduit/backend.mjs";
const handle = createBackend();
const call = (method, uri, body = {}, token = null) => handle({ method, uri, body: JSON.stringify(body), headers: token ? [["authorization", `Token ${token}`]] : [] });
for (const username of ["anna?x", "a/b", "%41", "x&favorited=anna"]) {
  const added = call("POST", "/api/users", { user: { username, email: `${username}@test.invalid`, password: "secret" } });
  assert.equal(added.status, 200);
  const profile = call("GET", `/api/profiles/${encodeURIComponent(username)}`);
  assert.equal(profile.status, 200);
  assert.equal(JSON.parse(profile.body).profile.username, username);
}
const signed = JSON.parse(call("POST", "/api/users/login", { user: { email: "anna?x@test.invalid", password: "secret" } }).body).user;
for (const [tag, encoded] of [["c&c", "c%26c"], ["a?b", "a%3Fb"], ["c++", "c%2B%2B"], ["c#", "c%23"], ["%41", "%2541"], ["a b", "a+b"]]) {
  const created = call("POST", "/api/articles", { article: { title: `Exact ${tag}`, description: "URL test", body: "body", tagList: [tag] } }, signed.token);
  assert.equal(created.status, 201);
  const listed = call("GET", `/api/articles?limit=20&offset=0&tag=${encoded}`);
  const rows = JSON.parse(listed.body).articles;
  assert.equal(rows.length, 1);
  assert.deepEqual(rows[0].tagList, [tag]);
}
for (const username of [".", ".."]) {
  assert.equal(call("POST", "/api/users", { user: { username, email: "dot@test.invalid", password: "secret" } }).status, 422);
  assert.equal(call("PUT", "/api/user", { user: { username } }, signed.token).status, 422);
}
assert.equal(JSON.parse(call("GET", "/api/profiles/anna%3Fx").body).profile.username, "anna?x");
console.log("Conduit encoded names, six tag values, and dot-name refusals passed");
