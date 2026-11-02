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
document at `/roc-signals/examples-web/conduit/` and puts app routes in the URL hash,
for example `#/article/keyed-lists-without-tears` and `#/?page=2`. Refreshing a
deep link always requests the one real HTML page. A standalone deployment should
change `Route.demo_base_path` (and can switch back to clean history paths when
its server provides an SPA fallback).

## Verification

Useful focused checks while working on this app:

```sh
roc check --no-cache examples-web/conduit/main.roc
roc build --no-cache --target=arm64mac --opt=dev --output=/tmp/conduit examples-web/conduit/main.roc
python3 scripts/spec_driver.py /tmp/conduit examples-web/conduit/specs
node --test scripts/browser/conduit_backend.test.mjs
zig build run-test-browser
git diff --check
zig build run-check-tidy
```

The native `examples-web/conduit/specs/` suite covers application response,
navigation, stale-result handling and confirmed mutations. Browser contract
tests exercise the fetch boundary separately.

`Api.response_state` converts the opaque HTTP response to a plain record before
domain decoding, keeping that boundary separate from Conduit's larger unions.
