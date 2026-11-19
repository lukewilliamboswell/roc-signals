// Tooling only: the Roc CLI and scripts read this same complete match table.
// No runtime/worker policy or import vocabulary changes with the build mode.
import assert from "node:assert/strict";
import fs from "node:fs";

export function parseProfiles(text) {
  const profiles = text.trim().split("\n").filter(Boolean).map(line => {
    const fields = line.split("\t");
    assert.equal(fields.length, 5, "compiler profile row needs five fields");
    assert.ok(fields.every(Boolean), "compiler profile fields must not be empty");
    const [compiler, target, requested, effective, issue] = fields;
    return { compiler, target, requested, effective, issue };
  });
  assert.equal(new Set(profiles.map(({ compiler, target, requested }) => JSON.stringify([compiler, target, requested]))).size, profiles.length, "compiler profile matches must be unique");
  return profiles;
}
const rows = parseProfiles(fs.readFileSync(new URL("../cli/compiler-profiles.tsv", import.meta.url), "utf8"));

export function effectiveProfile({ compiler, target, requested }) {
  return rows.find(row => row.compiler === compiler && row.target === target && row.requested === requested)?.effective ?? requested;
}

export function profileNotice(given) {
  const row = rows.find(row => row.compiler === given.compiler && row.target === given.target && row.requested === given.requested);
  return !row || row.effective === given.requested ? "" : `SKIP ${given.target} --opt=${given.requested} on ${given.compiler}: ${row.issue}; using --opt=${row.effective}, with every behavior check retained.`;
}
