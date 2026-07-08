// Dev helper for authoring native specs: turn a JSON (or text) body into a
// resolve_task HTTP wire payload with escaped newlines, ready to paste into
// a spec.txt line.
//
//   node scripts/browser/http_spec_payload.mjs '<body text>' [status]
//
// Prints: roc-http-response-v1\n<status>\n0\n<comma-joined body bytes>
import { encodeHttpResponsePayload } from "../../www/static/signals.mjs";

const [, , bodyText, statusRaw] = process.argv;
if (bodyText === undefined) {
  console.error("usage: node scripts/browser/http_spec_payload.mjs '<body text>' [status]");
  process.exit(1);
}

const payload = encodeHttpResponsePayload({
  status: Number(statusRaw ?? 200),
  headers: [],
  body: new TextEncoder().encode(bodyText),
});
console.log(payload.split("\n").join("\\n"));
