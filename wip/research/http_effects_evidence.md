# HTTP Effects Evidence

Captured: 2026-07-03.

Purpose: keep shipped HTTP evidence out of the active backlog. Promote new HTTP
surface only when a maintained app or focused canary proves a remaining
production gap.

Refresh check: re-run on 2026-07-05 with the focused HTTP router/runtime
contract gates after validating the browser fetch-policy candidate.
`node --test scripts/browser/http_task_router.test.mjs` passed 11/11, and
`node --test --test-name-pattern "task|HTTP|API request|ops API|public example task" scripts/browser/runtime_contract.test.mjs`
passed 13/13. The current surface and coverage below remained green.

## Focused Gates

For evidence-only edits that do not change current-state or coverage claims, run:

```sh
git diff --check
zig build run-check-tidy
```

For current HTTP surface, browser contract, or task-routing coverage claims, run:

```sh
node --test scripts/browser/http_task_router.test.mjs
node --test --test-name-pattern "task|HTTP|API request|ops API|public example task" scripts/browser/runtime_contract.test.mjs
```

For app/native spec coverage, include the native spec gate:

```sh
python3 scripts/test.py native --native always
```

## Current Shipped Surface

- `platform/main.roc` pins `roc-lang/http` 0.1 in the platform package header.
- `platform/Http.roc` exposes package-aligned request/response wrappers for
  method, URI, headers, body, timeout, status, and response body/headers.
- `Http.request_task` / `Http.start` and `Http.get` carry full
  `roc-lang/http` request and response values through explicit task envelopes.
- `Http.get_text_task` / `Http.get_text` are convenience wrappers that decode
  successful response bytes as UTF-8 for examples; they are not a general body
  codec family.
- `Http.HttpError` classifies network, timeout, canceled, unsupported, and
  response-materialization failures.
- The current routing convention is still the `http:send:` task-name prefix.
  Replace it with a typed effect capability registry only when a promoted
  subscription/app-interop slice proves the shared task/subscription routing
  model.

## JS And Browser Contract Coverage

- `scripts/browser/runtime_contract.test.mjs` covers task start/cancel telemetry,
  request-id resolution, stale/unknown task settlements, aborting stale async
  work, and handler rejection through the task failure path.
- Runtime HTTP contract tests cover request payload encoding/decoding for method,
  URI, timeout, ordered headers, and body bytes.
- Runtime HTTP contract tests cover response payload encoding/decoding for status,
  ordered duplicate header pairs, and body bytes.
- Runtime HTTP fetch tests cover mapping request envelopes to `fetch`, preserving
  response headers/body, relaying an abort signal, preserving the intentionally
  narrow browser fetch option set (`method`, `headers`, `body`, and `signal`
  only), and reporting rejected fetches as HTTP network errors.
- Public example task-handler tests cover the service-ops HTTP endpoints,
  `api-request-console`, and fallback to non-HTTP lookup tasks.
- `scripts/browser/http_task_router.test.mjs` covers non-HTTP pass-through,
  request decoding, JSON/text helper responses, ordered duplicate response-header
  pairs, route method mismatch, unknown-URI fetch fallback, malformed request
  payloads, pre-encoded HTTP task errors, ordinary handler errors, and async
  handler success/failure.

## Native And App Spec Coverage

- `examples/api-request-console/spec.txt` proves full-response HTTP task behavior
  for success, 404 materialized response, network error, and repeated request
  starts under the current `http:send:api-request-console` route name.
- `examples/service-ops-center/spec.txt` proves the dashboard HTTP text task starts
  on mount and refresh, resolves a UTF-8 JSON body, and stays pending across
  overlapping refresh triggers.
- `examples/_fixtures/task-to-utf8-lifetime/spec.txt` proves decoded HTTP text
  task results own UTF-8 beyond the response-envelope lifetime.
- `examples/_fixtures/task-latest-wins/spec.txt` proves replacement cancels the
  older pending task, stale completion is counted as ignored, and the fresh result
  remains current.

## Result

The shipped HTTP slice is package-aligned and covered for the current browser and
native semantics: explicit request/response envelopes, ordered header pairs,
fetch mapping with browser-default credentials/redirect/mode/cache/referrer
policy, task cancellation/stale-result behavior, HTTP error envelopes, UTF-8 text
convenience, and maintained app canaries.

Remaining HTTP work should stay gated:

Promotion trigger: name one maintained app or focused canary and one specific
production gap that the shipped HTTP task surface does not cover.

- Add explicit user-driven abort only when a maintained app or focused canary
  needs cancellation distinct from scope disposal or request replacement.
- Replace `http:send:` prefix routing only after a promoted
  subscription/app-interop slice proves the shared typed effect capability
  registry and task/subscription routing model.
- Keep JSON/body helper sugar closed for current evidence. The spike outcome in
  `wip/research/json_codec_evidence.md` found that builtin `Json` plus
  app-local mappers cover the maintained examples; the remaining
  `service-ops-center` split parse is a Roc wide-record derivation workaround,
  not an HTTP surface gap.
- Keep browser fetch-policy controls closed for current evidence. The validation
  outcome in `wip/research/fetch_policy_evidence.md` found that maintained apps
  use the package-aligned method/URI/header/body/timeout path plus browser
  defaults; reopen only when a maintained app or focused canary needs host
  control beyond those defaults.
