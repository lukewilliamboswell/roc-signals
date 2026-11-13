import fs from "node:fs";
import { createHash } from "node:crypto";
import { decodePictureEnvelope } from "../platform/runtime.mjs";
import { pictureEnvelopeCases, pictureEnvelopeVectors } from "./browser/picture-envelope-cases.mjs";
const vectors = JSON.parse(fs.readFileSync(new URL("./picture-envelope-vectors.json", import.meta.url)));
const checks = [...pictureEnvelopeCases(decodePictureEnvelope), ...pictureEnvelopeVectors(decodePictureEnvelope, vectors)];
for (const vector of vectors) checks.push([`independent rich bytes SHA256 ${vector.name}`, createHash("sha256").update(Buffer.from(vector.hex, "hex")).digest("hex") === vector.sha256]);
for (const [name, ok] of checks) console.log(`${ok ? "ok  " : "FAIL"} ${name}`);
if (checks.some(([, ok]) => !ok)) process.exitCode = 1;
