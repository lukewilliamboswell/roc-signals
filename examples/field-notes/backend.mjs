// Field Notes' simulated service: the sync endpoint its outbox drains into.
//
// This is the example's own JavaScript, not the platform's or the site's.
// Its default export follows the contract every example backend keeps
// (www/data/examples.toml, `backend`): `createBackend()` returns
// `handle({ method, uri, headers, body, signal })`, which answers
// `{ status, body, headers }` (or a promise of one) for a request it serves,
// rejects for a network failure, and returns null for any other URI so the
// caller sends that request on to the real network. The site's site.mjs
// turns it into the mount's `fetch`; the browser soak serves it over HTTP.
//
// House rules: no `Math.random()`, no wall-clock input. The backend owns a
// small counter that advances once per request, so successive requests tell
// the same story every time. Payload formats are copied from the literal
// payloads in the example's `specs/*.scm`, the ground truth the Roc parse
// functions were written against.

// Answers settle after a short delay so loading state is visible; an abort
// (the request cancelled) rejects at once.
function settle(value, { signal, delayMs = 140 } = {}) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(new Error("canceled"));
      return;
    }
    const timer = setTimeout(() => resolve(value), delayMs);
    signal?.addEventListener?.(
      "abort",
      () => {
        clearTimeout(timer);
        reject(new Error("canceled"));
      },
      { once: true },
    );
  });
}

const plain = (status, body) => ({ status, body, headers: { "content-type": "text/plain; charset=utf-8" } });

// POST /api/notes/sync carries the settlement token, "<id>#<rev>", as text.
// Success echoes it. The calling effect retains its own token on failure.
//
// Every third sync request fails, so the outbox demonstrates a failed row and
// the Retry button; retrying mints a new revision, which produces a new token
// and (usually) a clean settlement on the next attempt.
export default function createBackend() {
  let attempts = 0;
  return function fieldNotesHandler({ method = "GET", uri, body = "", signal }) {
    if (String(uri) !== "/api/notes/sync") return null;
    if (method !== "POST") return plain(405, "method not allowed");
    attempts = (attempts + 1) % 3;
    if (attempts === 0) return settle(plain(503, "sync temporarily unavailable"), { signal });
    return settle(plain(200, body), { signal });
  };
}
