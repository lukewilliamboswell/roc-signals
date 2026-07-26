# Browser Fetch Policy Evidence

Captured: 2026-07-05.

Purpose: record the validation outcome for the HTTP hardening candidate
"browser fetch-policy controls." The question is whether maintained apps or
focused browser tests currently need public Roc controls for `credentials`,
`redirect`, `mode`, `cache`, or referrer policy beyond the package-aligned
request fields already carried through the HTTP task envelope.

## Focused Gates

For edits to this note:

```sh
git diff --check
zig build run-check-tidy
```

If HTTP runtime, task-router, or browser fetch-policy claims change, also run:

```sh
node --test scripts/browser/http_task_router.test.mjs
node --test --test-name-pattern "HTTP|API request|ops API|public example task" scripts/browser/runtime_contract.test.mjs
```

Refresh check: re-run on 2026-07-05. `node --test
scripts/browser/http_task_router.test.mjs` passed 11/11, and
`node --test --test-name-pattern "HTTP|API request|ops API|public example task"
scripts/browser/runtime_contract.test.mjs` passed 7/7. The focused runtime
coverage includes the guard that browser `fetch` receives only `body`,
`headers`, `method`, and `signal`.

Refresh check: 2026-07-08, conduit Phase 0 cross-origin canary. Previously
every consumer was same-origin and cross-origin was the one unproven path.
A real-browser canary (headless Chrome 144, page served from
`http://localhost` importing the shipped `signals.mjs`, requests issued
through `httpFetchTaskHandler` with an `Authorization: Token ...` header,
`timeoutMs` 8000) observed:

- Cross-origin HTTPS GET to a CORS-enabled endpoint
  (`https://httpbin.org/headers`): the Authorization header makes the
  request non-simple, so the browser preflights; the preflight passed under
  browser defaults, the response materialized as status 200 through the
  normal envelope, and the echoed request headers confirm
  `Authorization: Token canary-jwt-not-a-secret` was transmitted on the
  actual GET. Header-based auth works cross-origin with zero policy knobs.
- Cross-origin HTTPS GET to an endpoint with no CORS headers
  (`https://example.com/`): the blocked fetch surfaced as
  `roc-http-error-v1` / `network` / "Failed to fetch" — the documented
  `Http.Network` classification, renderable by the app, no hang and no
  silent console-only failure.

Boundary of this canary: it proves preflighted header-authenticated GETs
and CORS-denial error surfacing. It does not exercise cookie-credentialed
cross-origin requests (still a reopen trigger) or a full RealWorld backend
pass (that manual pass is conduit MoE-2, planned for its Phase 5).

## Current Surface

`platform/Http.roc` wraps the pinned `roc-lang/http` request and response
values. The public request path carries method, URI, headers, body, and timeout.
It does not expose Signals-specific request policy fields.

`www/static/signals.mjs` decodes the same envelope and calls browser `fetch`
with only:

- `method`,
- `headers`,
- `body` when non-empty,
- `signal`, where the runtime-owned `AbortController` relays scope disposal,
  request replacement, and timeout cancellation.

The runtime contract test for HTTP fetch maps request envelopes to response
envelopes and asserts the option key set is exactly `body`, `headers`, `method`,
and `signal`. That test is the current guard against accidentally widening the
browser fetch policy surface.

## Current Consumers

`api-request-console` uses the full-response request path for same-origin POST
requests. It sets `content-type`, an app-specific scenario header, a JSON byte
body, and a timeout. This covers header-based request customization without
requiring a browser policy knob.

`service-ops-center` uses `Http.get_text_task` for same-origin dashboard
refreshes, interval refreshes, and manual refresh. Visibility-driven scope
changes and request replacement already exercise cancellation through the abort
signal; they do not need redirect, cache, credential, mode, or referrer control.

The public example task handler serves maintained demo endpoints with
`createHttpTaskRouter`. Unknown HTTP routes deliberately return `null` so the
runtime can fall back to real browser `fetch`, still under browser defaults.

The current docs and design explicitly describe this policy: browser defaults
apply for credentials, redirects, mode, cache, CORS, and referrer behavior.
HTTP statuses materialize as responses; rejected fetches, including CORS
denials and network failures, become `Http.Network`.

## Decision

Do not promote browser fetch-policy controls from the current evidence.

Keep the public HTTP surface package-aligned:

- method,
- URI,
- headers,
- body,
- timeout,
- response status,
- response headers,
- response body,
- transport errors.

Browser `fetch` defaults remain the policy layer for credentials, redirects,
mode, cache, and referrer behavior. If an app needs auth, header-based auth is
expressible today with `Http.add_header` / `Http.with_headers`; same-origin
cookies ride the browser default credential behavior.

A public fetch-policy API would either duplicate browser-only `RequestInit`
fields outside the pinned package-aligned request model, or require designing a
host transport extension with cross-host semantics. Current maintained apps and
focused tests do not justify that extra surface.

## Reopen Triggers

Reopen only with a maintained app or focused browser canary that proves browser
defaults are insufficient. Examples:

- cross-origin credentialed requests that require explicit `include` or
  `omit` credentials semantics;
- redirect behavior where the app must distinguish `manual`, `error`, or
  default follow behavior;
- cache control that cannot be expressed by HTTP headers or URL versioning and
  needs browser `RequestInit.cache`;
- referrer or referrer-policy behavior that changes a maintained app outcome;
- `mode` behavior such as `same-origin` or `no-cors` that a real app needs and
  can test meaningfully.

If promoted, the controls should extend the package-aligned HTTP transport path
with focused JS contract tests. They should not create a second Signals-only
request model.
