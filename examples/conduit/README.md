# Conduit

Conduit is the RealWorld evidence app for `roc-signals`. It is intentionally
larger than the focused examples: the app exercises history routing, persisted
sessions, authenticated HTTP tasks, paginated feeds, profiles, markdown article
bodies, comments, favorites, follows, settings, and server-confirmed write
paths.

The browser build uses the in-page deterministic RealWorld-style backend in
`www/static/conduit_backend.mjs`. That backend provides seeded users, articles,
comments, validation envelopes, authorization checks, pagination, and in-memory
mutations. Unknown task routes fall through to the normal browser fetch path, so
the same app structure can be tested against a conformant external backend when
the API base is swapped.

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
On 2026-07-12 the old compiler SIGSEGV was fixed and direct Conduit artifacts
were produced, but the native script failed during initial mount with a retained
`HostValue` capability mismatch. Final verification on the same compiler version
now panics earlier in postcheck. Keep the feature assertions current, but do not
treat them as verified until both failures are resolved and the script passes
end to end.
