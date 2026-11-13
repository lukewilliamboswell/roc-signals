import fs from "node:fs";
import { createHash } from "node:crypto";
import * as api from "../platform/runtime.mjs";
import { pictureMeasurementCases, buildMeasurementFacts } from "./browser/picture-measurement-cases.mjs";
const vectors = JSON.parse(fs.readFileSync(new URL("./picture-hash-vectors.json", import.meta.url), "utf8"));
const checks = await pictureMeasurementCases(api, buildMeasurementFacts, vectors);
for (const vector of [...vectors.picture, ...vectors.mount]) {
  const bytes = Buffer.from(vector.canonical_hex, "hex");
  checks.push([`independent canonical bytes SHA-256 ${vector.name ?? vector.batch_hex}`, bytes.length === vector.canonical_bytes && createHash("sha256").update(bytes).digest("hex") === vector.sha256]);
}
for (const [name, ok] of checks) console.log(`${ok ? "ok  " : "FAIL"} ${name}`);
if (checks.some(([, ok]) => !ok)) process.exitCode = 1;
