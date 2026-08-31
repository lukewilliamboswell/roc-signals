# Roc Signals keyed browser benchmark adapter

This directory is the repository-native form of the Roc Signals entry for the
official [`js-framework-benchmark`](https://github.com/krausest/js-framework-benchmark).
It mounts the ordinary Roc fixture through the production Wasm host and
`signals.mjs`; JavaScript only instantiates the app and executes the shared
engine's already-decided DOM command stream.

Build from this directory with:

```sh
npm ci
ROC_BIN=/path/to/roc npm run build-prod
npm run verify
```

The build uses a `ReleaseSmall` host and Roc `--opt=size`, matching the public
browser artifact. It writes `dist/app.wasm`, `dist/main.mjs`, and the production
runtime modules. Serve the repository root, then open
`/benchmarks/js-framework-benchmark/roc-signals-keyed/`.

For an upstream comparison, copy this directory to
`frameworks/keyed/roc-signals` in a checkout of `krausest/js-framework-benchmark`.
Because the canonical fixture, platform, host, and runtime remain owned by this
repository, point the copied adapter back to this checkout when building:

```sh
ROC_SIGNALS_ROOT=/path/to/roc-signals ROC_BIN=/path/to/roc npm run build-prod
```

Then run the official driver's `isKeyed` and benchmark commands against
`keyed/roc-signals`. This adapter is intentionally an integration artifact, not
yet a standalone upstream submission: producing a self-contained upstream
folder requires a pinned Roc Signals release artifact and toolchain policy.

The benchmark UI and rows are rendered by
`examples/_fixtures/js-framework-benchmark/main.roc`. Its stable string keys
back `Ui.each_str`, so replacement creates new row nodes, removal detaches the
identified node, and swaps move the existing keyed nodes.

The current upstream structural checker accepts the fixture's accessibility and
semantic-test attributes (`aria-label`, `data-testid`, and `data-row-id`); it
checks descendant tags, table-cell classes, the remove icon, and keyed node
movement/removal. Those extra attributes remain part of the measured render
cost. Labels use upstream's adjective/colour/noun vocabulary but choose entries
deterministically from the monotonically increasing row id because the platform
does not yet expose a browser entropy source. Resolve that policy with upstream
before presenting this directory as a submission-ready implementation.
