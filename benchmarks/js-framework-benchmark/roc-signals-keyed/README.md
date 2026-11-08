# Roc Signals keyed browser benchmark adapter

The Roc Signals entry for the official
[`js-framework-benchmark`](https://github.com/krausest/js-framework-benchmark).
`app/` is an ordinary app on the web platform (`platform/main.roc`, by
relative path): one keyed `each` with a state for the rows and one for the
selected key. `src/main.mjs` mounts it with `platform/runtime.mjs`, which only
applies the engine's command stream.

Build and check it from the repository root:

```sh
blueprint run jfb      # dist/: app.wasm (--opt=speed), runtime.mjs, main.mjs, then the DOM checks
```

`jfb` builds the Wasm host, compiles `app/main.roc` with `--opt=speed`, writes
`dist/` here, and runs `tests/browser/jfb-check.mjs` in headless Chrome: run,
update every 10th row, select, swap, remove, clear, run lots, add, and keyed
row identity across update and swap.

For an upstream comparison, copy this directory with its built `dist/` to
`frameworks/keyed/roc-signals` in a `krausest/js-framework-benchmark`
checkout. `npm run build-prod` there only checks that `dist/` is present: the
engine, platform and host live in this repository.

`package-lock.json` has no dependencies but must stay: the upstream server
lists only framework directories that have both `package.json` and
`package-lock.json`, and skips the others without an error. Regenerate it
with `npm install --package-lock-only` when `package.json` changes.
