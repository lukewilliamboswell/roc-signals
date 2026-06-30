# Roc Signals

Roc Signals is a Roc platform for building small reactive interfaces that can
run in a browser or under the native test host.

An app describes its UI with values, signals, and event handlers. The host keeps
that description alive, owns retained state, runs tasks, and patches only the
parts of the interface that changed.

## Start Here

The GitHub Pages site is the intended front door. Until that is published, the
site source includes the maintained user docs:

- [Guide](www/content/docs/guide.md) introduces the programming model.
- [Contributing](www/content/docs/contributing.md) covers local setup, tests,
  host artifacts, bundles, and release-site builds.

The platform architecture and host boundary notes live in [design.md](design.md).

## Try It Locally

Build and serve the static site with the examples:

```sh
python3 scripts/serve.py
```

Then open:

```text
http://127.0.0.1:8000/
```

The examples live under [examples/](examples/). Each public example has its own
directory with `app.roc`, any supporting modules, and a native test spec.

To run the validation suite:

```sh
python3 scripts/test.py
```

The scripts use `roc` from `PATH` by default. Override it with `ROC_BIN`, `ROC`,
or `--roc-bin /path/to/roc`.

## Repository Layout

- [platform/](platform/) contains the Roc platform package and target host
  artifacts used by Roc builds.
- [src/](src/) contains the Zig engine, native host, wasm host, specs, and
  benchmark support.
- [examples/](examples/) contains maintained Roc example apps and native specs.
- [www/](www/) contains the Zola site, static JavaScript runtime, user docs, and
  example-page metadata.
- [scripts/](scripts/) contains the Python drivers and repository checks.
- [wip/](wip/) contains historical notes and design-prep documents.
