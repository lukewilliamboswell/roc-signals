import { decodePictureEnvelope } from "../platform/runtime.mjs";
import { pictureEnvelopeCases } from "./browser/picture-envelope-cases.mjs";
const checks = pictureEnvelopeCases(decodePictureEnvelope);
for (const [name, ok] of checks) console.log(`${ok ? "ok  " : "FAIL"} ${name}`);
if (checks.some(([, ok]) => !ok)) process.exitCode = 1;
