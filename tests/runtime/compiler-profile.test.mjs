import assert from "node:assert/strict";
import { effectiveProfile, profileNotice, parseProfiles } from "../compiler-profile.mjs";

const affected = { compiler: "nightly-2026-11-18-a520eed", target: "wasm32", requested: "dev" };
assert.equal(effectiveProfile(affected), "size");
assert.equal(effectiveProfile({ ...affected, compiler: "nightly-2026-11-19-future" }), "dev");
for (const target of ["arm64mac", "x64musl", "x64mac", "x64win"]) assert.equal(effectiveProfile({ ...affected, target }), "dev");
for (const requested of ["size", "speed"]) assert.equal(effectiveProfile({ ...affected, requested }), requested);
assert.equal(profileNotice(affected), "SKIP wasm32 --opt=dev on nightly-2026-11-18-a520eed: https://github.com/roc-lang/roc/issues/13195; using --opt=size, with every behavior check retained.");
assert.equal(profileNotice({ ...affected, compiler: "nightly-2026-11-19-future" }), "");
for (const invalid of ["a\tb\tc\td", "a\tb\tc\td\t", "a\tb\tc\t\tissue", "a\tb\tc\td\tissue\na\tb\tc\te\tissue"]) assert.throws(() => parseProfiles(invalid));
assert.deepEqual(parseProfiles(""), []);
console.log("compiler profiles: exact-version scope, effective mode and explicit fallback notice passed");
