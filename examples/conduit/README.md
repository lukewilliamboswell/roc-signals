# Conduit

Conduit is the RealWorld evidence app for `roc-signals`. It is intentionally
larger than the focused examples: the app exercises hash routing, persisted
sessions, authenticated HTTP tasks, paginated feeds, profiles, markdown article
bodies, comments, favorites, follows, settings, and server-confirmed write
paths.

The browser build uses the in-page deterministic RealWorld-style backend in
`www/static/conduit_backend.mjs`. That backend provides seeded users, articles,
comments, validation envelopes, authorization checks, pagination, and in-memory
mutations. Unknown task routes fall through to the normal browser fetch path, so
the same app structure can be tested against a conformant external backend when
the API base is swapped.

The published demo is a static GitHub Pages app. `Route.roc` therefore keeps the
document at `/roc-signals/examples/conduit/` and puts app routes in the URL hash,
for example `#/article/keyed-lists-without-tears` and `#/?page=2`. Refreshing a
deep link always requests the one real HTML page. A standalone deployment should
change `Route.demo_base_path` (and can switch back to clean history paths when
its server provides an SPA fallback).

## Verification

Useful focused checks while working on this app:

```sh
roc check --no-cache examples/conduit/app.roc
roc build --no-cache --target=arm64mac --opt=dev --output=/tmp/conduit examples/conduit/app.roc
/tmp/conduit examples/conduit/spec.txt
node --test scripts/browser/conduit_backend.test.mjs
zig build run-test-browser
git diff --check
zig build run-check-tidy
```

The native `examples/conduit/spec.txt` is the authoritative behavior script.
On 2026-07-20 it passed end to end with the PATH Roc
`release-fast-8eaa9abd`, including loading, empty, validation, network-error,
stale-response, navigation, and server-confirmed mutation paths. The full
repository gate and public dev/size site builds pass with the same compiler.

`Api.response_state` deliberately materializes the package's opaque HTTP
response into a small plain record before page-specific domain decoding. This
keeps the package-aligned HTTP API while avoiding a compiler stack overflow
caused by folding the opaque response directly into Conduit's large domain
unions. A real-backend pass and the long soak remain closeout evidence rather
than feature gaps in the script.
